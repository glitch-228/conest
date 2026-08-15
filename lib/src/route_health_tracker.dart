import 'models.dart';

const Duration kLanHealthCacheTtl = Duration(seconds: 15);
const Duration kInternetHealthCacheTtl = Duration(seconds: 45);
const Duration kLanRecentRouteSuccessTtl = Duration(seconds: 30);
const Duration kInternetRecentRouteSuccessTtl = Duration(minutes: 2);

/// Per-route runtime state: timestamps + failure streak + backoff. Exposed
/// publicly because the controller's debug snapshot reads its fields when
/// printing route diagnostics.
class RouteRuntimeState {
  DateTime? lastFetchSuccessAt;
  DateTime? lastStoreSuccessAt;
  DateTime? lastFailureAt;
  int failureStreak = 0;
  DateTime? backoffUntil;

  RouteRuntimeState clone() {
    return RouteRuntimeState()
      ..lastFetchSuccessAt = lastFetchSuccessAt
      ..lastStoreSuccessAt = lastStoreSuccessAt
      ..lastFailureAt = lastFailureAt
      ..failureStreak = failureStreak
      ..backoffUntil = backoffUntil;
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
      state.failureStreak = 0;
      state.backoffUntil = null;
    }
  }

  void replaceHealth(PeerRouteHealth health) {
    _health[health.route.routeKey] = health;
  }

  /// Static comparator: routes that have established lower latency win.
  /// Routes that never reported a latency sort last.
  int compareHealth(PeerRouteHealth left, PeerRouteHealth right) {
    final leftLatency = left.latency?.inMicroseconds ?? 1 << 62;
    final rightLatency = right.latency?.inMicroseconds ?? 1 << 62;
    return leftLatency.compareTo(rightLatency);
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
    final state = ensureRuntime(route.routeKey);
    if (fetch != null) {
      if (fetch) {
        state.lastFetchSuccessAt = timestamp;
      } else {
        state.lastStoreSuccessAt = timestamp;
      }
    }
    state.lastFailureAt = null;
    state.failureStreak = 0;
    state.backoffUntil = null;
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
    final state = ensureRuntime(route.routeKey);
    state.lastFailureAt = timestamp;
    state.failureStreak += 1;
    final backoff = backoffDurationFor(
      route,
      failureStreak: state.failureStreak,
    );
    state.backoffUntil = timestamp.add(backoff);
    _health[route.routeKey] = PeerRouteHealth(
      route: route,
      available: false,
      latency: null,
      checkedAt: timestamp,
      error: error,
    );
  }
}
