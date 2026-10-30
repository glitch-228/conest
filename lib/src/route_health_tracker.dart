import 'models.dart';
import 'path_stats.dart';

const Duration kLanHealthCacheTtl = Duration(seconds: 15);
const Duration kInternetHealthCacheTtl = Duration(seconds: 45);
const Duration kLanRecentRouteSuccessTtl = Duration(seconds: 30);
const Duration kInternetRecentRouteSuccessTtl = Duration(minutes: 2);

/// Per-route runtime state: when the route last worked and its numbers
/// ([stats]: round trip, failure streak, backoff). Exposed publicly because
/// the controller's debug snapshot reads its fields when printing route
/// diagnostics.
class RouteRuntimeState {
  RouteRuntimeState([PathStats? stats]) : stats = stats ?? PathStats();

  DateTime? lastFetchSuccessAt;
  DateTime? lastStoreSuccessAt;

  /// The same figures ranking, escalation and file striping read.
  final PathStats stats;

  DateTime? get lastFailureAt => stats.lastFailureAt;
  set lastFailureAt(DateTime? value) => stats.lastFailureAt = value;
  int get failureStreak => stats.failureStreak;
  set failureStreak(int value) => stats.failureStreak = value;
  DateTime? get backoffUntil => stats.cooldownUntil;
  set backoffUntil(DateTime? value) => stats.cooldownUntil = value;

  RouteRuntimeState clone() {
    return RouteRuntimeState(stats.clone())
      ..lastFetchSuccessAt = lastFetchSuccessAt
      ..lastStoreSuccessAt = lastStoreSuccessAt;
  }
}

/// Owns per-route health caches, runtime state, and backoff scheduling.
///
/// The controller still owns the [PeerEndpoint]/[ContactRecord] graph and
/// the polling loop; this tracker is purely a record of what worked when
/// and how long to back off after failures. The `[]` operator on
/// [healthMap]/[runtimeMap] is exposed so existing callers in
/// [MessengerController] can keep direct map access (debug snapshots,
/// pruning on contact removal); higher-level decisions go through the
/// named methods below so the policy lives in one place.
class RouteHealthTracker {
  RouteHealthTracker({required DateTime Function() nowProvider})
    : _nowProvider = nowProvider;

  final DateTime Function() _nowProvider;

  /// Told of every outcome (for the network history).
  void Function(PeerEndpoint route, bool ok, String? error)? onOutcome;

  /// Until when [route] waits out a relay's rate limit, if it does. Such a
  /// failure is the relay asking for a pause, not a broken route: it backs
  /// off just that long, and its failure streak does not grow.
  DateTime? Function(PeerEndpoint route)? rateLimitedUntil;
  final Map<String, PeerRouteHealth> _health = <String, PeerRouteHealth>{};
  final Map<String, RouteRuntimeState> _runtime = <String, RouteRuntimeState>{};

  Map<String, PeerRouteHealth> get healthMap => _health;
  Map<String, RouteRuntimeState> get runtimeMap => _runtime;

  PeerRouteHealth? healthFor(PeerEndpoint route) => _health[route.routeKey];
  RouteRuntimeState? runtimeFor(PeerEndpoint route) => _runtime[route.routeKey];

  RouteRuntimeState ensureRuntime(String routeKey) {
    return _runtime.putIfAbsent(routeKey, RouteRuntimeState.new);
  }

  void clear() {
    _health.clear();
    _runtime.clear();
  }

  /// A network-interface transition invalidates old retry delays. Preserve
  /// latency and success history, but allow every route to be tried
  /// immediately on the new interface.
  void clearBackoffWindows() {
    for (final state in _runtime.values) {
      state.stats.clearCooldown();
    }
  }

  /// Drops everything known about LAN routes, after a network change.
  void forgetLanRoutes() {
    _health.removeWhere((_, health) => health.route.kind == PeerRouteKind.lan);
    _runtime.removeWhere(
      (key, _) => key.startsWith('${PeerRouteKind.lan.name}:'),
    );
  }

  void replaceHealth(PeerRouteHealth health) {
    _health[health.route.routeKey] = health;
  }

  /// Static comparator: routes that have established lower latency win.
  /// Routes that never reported a latency sort last.
  int compareHealth(PeerRouteHealth left, PeerRouteHealth right) {
    return _rankMicros(left).compareTo(_rankMicros(right));
  }

  /// [compareHealth]'s figure for [route] (last in line when unknown).
  int rankMicrosFor(PeerEndpoint route) {
    final health = _health[route.routeKey];
    return health == null ? 1 << 62 : _rankMicros(health);
  }

  /// The round trip a route is ranked by: its smoothed figure from
  /// [RouteRuntimeState.stats] while its last check answered, otherwise the
  /// check's own time; a route that never answered goes last.
  int _rankMicros(PeerRouteHealth health) {
    final latency = health.latency;
    if (latency == null) return 1 << 62;
    final smoothed = _runtime[health.route.routeKey]?.stats.rttMs;
    return smoothed == null
        ? latency.inMicroseconds
        : (smoothed * 1000).round();
  }

  /// The smoothed round trip of [route], if it has answered.
  Duration? rttOf(PeerEndpoint route) {
    final ms = _runtime[route.routeKey]?.stats.rttMs;
    return ms == null ? null : Duration(microseconds: (ms * 1000).round());
  }

  int kindDeliveryPriority(PeerEndpoint route) {
    return switch (route.kind) {
      PeerRouteKind.lan => 0,
      PeerRouteKind.directInternet => 1,
      PeerRouteKind.relay => 2,
    };
  }

  Duration healthCacheTtlFor(PeerEndpoint route) {
    return route.kind == PeerRouteKind.lan
        ? kLanHealthCacheTtl
        : kInternetHealthCacheTtl;
  }

  Duration recentRouteSuccessTtlFor(PeerEndpoint route) {
    return route.kind == PeerRouteKind.lan
        ? kLanRecentRouteSuccessTtl
        : kInternetRecentRouteSuccessTtl;
  }

  bool hasFreshHealthyCache(PeerEndpoint route) {
    final health = _health[route.routeKey];
    if (health == null || !health.available) {
      return false;
    }
    return _nowProvider().difference(health.checkedAt) <=
        healthCacheTtlFor(route);
  }

  bool hasRecentRouteSuccess(PeerEndpoint route) {
    final successAt = lastSuccessAt(route);
    if (successAt == null) {
      return false;
    }
    return _nowProvider().difference(successAt) <=
        recentRouteSuccessTtlFor(route);
  }

  DateTime? lastSuccessAt(PeerEndpoint route) {
    final state = _runtime[route.routeKey];
    if (state == null) {
      return null;
    }
    DateTime? latest;
    for (final success in <DateTime?>[
      state.lastFetchSuccessAt,
      state.lastStoreSuccessAt,
    ]) {
      if (success == null) {
        continue;
      }
      if (latest == null || success.isAfter(latest)) {
        latest = success;
      }
    }
    return latest;
  }

  bool isBackedOff(PeerEndpoint route) {
    final backoffUntil = _runtime[route.routeKey]?.backoffUntil;
    return backoffUntil != null && backoffUntil.isAfter(_nowProvider());
  }

  bool isEligibleNow(PeerEndpoint route) => !isBackedOff(route);

  Duration backoffDurationFor(
    PeerEndpoint route, {
    required int failureStreak,
  }) {
    if (route.kind == PeerRouteKind.lan) {
      if (failureStreak <= 1) {
        return const Duration(seconds: 5);
      }
      if (failureStreak == 2) {
        return const Duration(seconds: 15);
      }
      if (failureStreak == 3) {
        return const Duration(seconds: 30);
      }
      return const Duration(seconds: 60);
    }
    if (failureStreak <= 1) {
      return const Duration(seconds: 15);
    }
    if (failureStreak == 2) {
      return const Duration(seconds: 60);
    }
    if (failureStreak == 3) {
      return const Duration(seconds: 300);
    }
    return const Duration(seconds: 600);
  }

  void recordSuccess(
    PeerEndpoint route, {
    bool? fetch,
    Duration? latency,
    String? relayInstanceId,
    DateTime? at,
  }) {
    final timestamp = (at ?? _nowProvider()).toUtc();
    onOutcome?.call(route, true, null);
    final state = ensureRuntime(route.routeKey);
    if (fetch != null) {
      if (fetch) {
        state.lastFetchSuccessAt = timestamp;
      } else {
        state.lastStoreSuccessAt = timestamp;
      }
    }
    state.stats.recordSuccess(timestamp, rtt: latency);
    _health[route.routeKey] = PeerRouteHealth(
      route: route,
      available: true,
      latency: latency ?? _health[route.routeKey]?.latency,
      checkedAt: timestamp,
      relayInstanceId:
          relayInstanceId ?? _health[route.routeKey]?.relayInstanceId,
    );
  }

  void recordFailure(PeerEndpoint route, {DateTime? at, String? error}) {
    final timestamp = (at ?? _nowProvider()).toUtc();
    onOutcome?.call(route, false, error);
    final relayInstanceId = _health[route.routeKey]?.relayInstanceId;
    final state = ensureRuntime(route.routeKey);
    final pausedUntil = rateLimitedUntil?.call(route);
    if (pausedUntil != null && pausedUntil.isAfter(timestamp)) {
      state.stats.recordFailure(timestamp, until: pausedUntil, grow: false);
    } else {
      state.stats.recordFailure(
        timestamp,
        cooldown: backoffDurationFor(
          route,
          failureStreak: state.stats.failureStreak + 1,
        ),
      );
    }
    _health[route.routeKey] = PeerRouteHealth(
      route: route,
      available: false,
      latency: null,
      checkedAt: timestamp,
      error: error,
      relayInstanceId: relayInstanceId,
    );
  }
}
