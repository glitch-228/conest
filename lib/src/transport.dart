import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'limits/network_limiter.dart';
import 'path_stats.dart';
import 'transport_models.dart';

class TransportCapabilities {
  const TransportCapabilities({
    required this.requiresPeerOnline,
    required this.supportsStoreForward,
    required this.duplex,
    required this.requiresUserAction,
    required this.supportsAttachmentStreaming,
    required this.reportsPath,
    this.maximumPayloadBytes,
    this.sendAttemptTimeout,
  });

  final bool requiresPeerOnline;
  final bool supportsStoreForward;
  final bool duplex;
  final bool requiresUserAction;
  final bool supportsAttachmentStreaming;
  final bool reportsPath;
  final int? maximumPayloadBytes;

  /// How long one send may take before the registry tries the next route.
  /// Carriers that send several frames in sequence need longer than a
  /// single socket write.
  final Duration? sendAttemptTimeout;
}

class TransportPeer {
  const TransportPeer({
    required this.deviceId,
    this.transportIdentity,
    this.identityPinned = false,
    this.allowRelay = true,
    this.directAddresses = const <String>[],
    this.transportAddresses = const <TransportKind, String>{},
  });

  final String deviceId;

  /// Per-transport peer addresses, for example the Matrix device a carrier
  /// route sends to.
  final Map<TransportKind, String> transportAddresses;
  final String? transportIdentity;
  final bool identityPinned;
  final bool allowRelay;
  final List<String> directAddresses;
}

class RouteCandidate {
  const RouteCandidate({
    required this.transport,
    required this.path,
    required this.routeId,
    required this.label,
    required this.trust,
    this.healthy = true,
    this.maximumPayloadBytes,
    this.detail,
  });

  final TransportKind transport;
  final TransportPathKind path;
  final String routeId;
  final String label;
  final TransportTrustState trust;
  final bool healthy;
  final int? maximumPayloadBytes;
  final String? detail;

  bool permitsPayload(int byteLength) =>
      maximumPayloadBytes == null || byteLength <= maximumPayloadBytes!;
}

class TransportEnvelope {
  const TransportEnvelope({
    required this.id,
    required this.recipientDeviceId,
    required this.bytes,
    required this.createdAt,
    this.expiresAt,
  });

  final String id;
  final String recipientDeviceId;
  final Uint8List bytes;
  final DateTime createdAt;
  final DateTime? expiresAt;
}

class TransportInboundEnvelope {
  const TransportInboundEnvelope({
    required this.transport,
    required this.path,
    required this.senderTransportIdentity,
    required this.bytes,
    required this.receivedAt,
  });

  final TransportKind transport;
  final TransportPathKind path;
  final String senderTransportIdentity;
  final Uint8List bytes;
  final DateTime receivedAt;
}

class AttachmentRange {
  const AttachmentRange({
    required this.attachmentId,
    required this.offset,
    required this.bytes,
    required this.sha256Base64,
  });

  final String attachmentId;
  final int offset;
  final Uint8List bytes;
  final String sha256Base64;
}

class DeliveryReceipt {
  const DeliveryReceipt({
    required this.state,
    required this.route,
    required this.at,
    this.detail,
  });

  final DeliveryReceiptState state;
  final RouteCandidate route;
  final DateTime at;
  final String? detail;

  bool get accepted => state != DeliveryReceiptState.failed;
}

class DeliveryAttempt {
  const DeliveryAttempt({
    required this.route,
    required this.startedAt,
    required this.completedAt,
    this.error,
  });

  final RouteCandidate route;
  final DateTime startedAt;
  final DateTime completedAt;
  final Object? error;
}

class TransportDeliveryResult {
  const TransportDeliveryResult({
    required this.receipt,
    required this.attempts,
  });

  final DeliveryReceipt receipt;
  final List<DeliveryAttempt> attempts;
}

/// What [TransportAdapter.cancel] takes: one envelope to one device.
String transportOperationId(String deviceId, String envelopeId) =>
    '$deviceId|$envelopeId';

abstract interface class TransportAdapter {
  TransportKind get kind;
  TransportCapabilities get capabilities;

  Future<void> start();
  Future<void> stop();
  Stream<RouteCandidate> get pathChanges;
  Stream<TransportInboundEnvelope> get inboundEnvelopes;
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer);
  Future<DeliveryReceipt> sendEnvelope({
    required TransportPeer peer,
    required RouteCandidate route,
    required TransportEnvelope envelope,
  });
  Future<DeliveryReceipt> sendAttachmentRange({
    required TransportPeer peer,
    required RouteCandidate route,
    required AttachmentRange range,
  });
  Future<void> cancel(String operationId);
}

/// What the registry has seen of one transport to one contact: how fast
/// sends complete and whether it has been failing.
/// A send stopped on purpose (its message arrived another way): not a
/// failure of the route, and no other route should take over.
class TransportSendCancelled implements Exception {
  const TransportSendCancelled(this.message);
  final String message;
  @override
  String toString() => message;
}

class TransportRegistry {
  TransportRegistry(
    Iterable<TransportAdapter> adapters, {
    DateTime Function()? now,
  }) : _adapters = {for (final adapter in adapters) adapter.kind: adapter},
       _now = now ?? DateTime.now;

  final Map<TransportKind, TransportAdapter> _adapters;

  /// Told of every send's outcome (for the network history).
  void Function(TransportKind kind, bool ok, Object? error)? onOutcome;
  final DateTime Function() _now;

  /// Statistics by `deviceId|transport`, least recently used first. The one
  /// set of numbers per path ([PathStats]) that ranking and the wait before
  /// another copy read.
  final PathStatsBook<String> _stats = PathStatsBook<String>();

  /// Envelopes up to this size time the route rather than the payload.
  static const int _latencySampleBytes = 64 * 1024;

  PathStats? statsFor(String deviceId, TransportKind kind) =>
      _stats.peek('$deviceId|${kind.name}');

  PathStats _statsEntry(String deviceId, TransportKind kind) =>
      _stats.touch('$deviceId|${kind.name}');

  /// Whether every transport that sent to [deviceId] within [within] failed
  /// the last time (none worked since): the connection map shows such a
  /// link as failing. False when nothing has been tried.
  bool failingToReach(
    String deviceId, {
    Duration within = const Duration(minutes: 30),
  }) {
    final now = _now();
    var tried = false;
    for (final kind in _adapters.keys) {
      final stats = statsFor(deviceId, kind);
      if (stats == null) continue;
      final failedAt = stats.lastFailureAt;
      final workedAt = stats.lastSuccessAt;
      final recent = [
        failedAt,
        workedAt,
      ].whereType<DateTime>().any((at) => now.difference(at) <= within);
      if (!recent) continue;
      if (stats.failureStreak == 0) return false;
      tried = true;
    }
    return tried;
  }

  Iterable<TransportAdapter> get adapters => _adapters.values;
  TransportAdapter? adapterFor(TransportKind kind) => _adapters[kind];

  /// Adds an adapter that becomes available after startup (for example
  /// Matrix after sign-in). The caller starts it.
  void register(TransportAdapter adapter) => _adapters[adapter.kind] = adapter;

  TransportAdapter? unregister(TransportKind kind) => _adapters.remove(kind);

  Future<void> start() => Future.wait(_adapters.values.map((a) => a.start()));
  Future<void> stop() => Future.wait(_adapters.values.map((a) => a.stop()));

  Future<List<RouteCandidate>> routesFor(
    TransportPeer peer, {
    required Map<TransportKind, TransportPolicy> policies,
    bool includeManual = false,
  }) async {
    final batches = await Future.wait(
      _adapters.values.map((adapter) async {
        final policy = policies[adapter.kind] ?? TransportPolicy.automatic;
        if (policy == TransportPolicy.disabled ||
            (!includeManual && policy == TransportPolicy.askBeforeUse) ||
            (!includeManual && adapter.capabilities.requiresUserAction)) {
          return const <RouteCandidate>[];
        }
        try {
          return await adapter.discoverRoutes(peer);
        } catch (_) {
          return const <RouteCandidate>[];
        }
      }),
    );
    final routes = batches
        .expand((entries) => entries)
        .where((route) {
          if (!route.healthy) return false;
          if (!peer.allowRelay && route.path == TransportPathKind.relayed) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
    // The user's policy first; then routes that have not just failed; then
    // the kind of path (local, direct, relayed, stored); then, within a
    // kind, the measured (or expected) speed for this contact.
    final now = _now();
    bool cooling(RouteCandidate route) =>
        statsFor(peer.deviceId, route.transport)?.coolingAt(now) ?? false;
    // A route whose account is near its rate limit goes behind routes that
    // are not: better another route now than a queue (or a ban) there.
    bool throttled(RouteCandidate route) {
      final Object? adapter = _adapters[route.transport];
      return adapter is RateLimited && (adapter.limiter?.nearLimit ?? false);
    }

    double speed(RouteCandidate route) =>
        statsFor(peer.deviceId, route.transport)?.rttMs ??
        _expectedLatencyMs(route);
    routes.sort((left, right) {
      final leftPolicy = policies[left.transport] ?? TransportPolicy.automatic;
      final rightPolicy =
          policies[right.transport] ?? TransportPolicy.automatic;
      final policyOrder = _policyPriority(
        leftPolicy,
      ).compareTo(_policyPriority(rightPolicy));
      if (policyOrder != 0) return policyOrder;
      final coolingOrder = (cooling(left) ? 1 : 0).compareTo(
        cooling(right) ? 1 : 0,
      );
      if (coolingOrder != 0) return coolingOrder;
      final throttledOrder = (throttled(left) ? 1 : 0).compareTo(
        throttled(right) ? 1 : 0,
      );
      if (throttledOrder != 0) return throttledOrder;
      final pathOrder = _routePriority(left).compareTo(_routePriority(right));
      if (pathOrder != 0) return pathOrder;
      final speedOrder = speed(left).compareTo(speed(right));
      if (speedOrder != 0) return speedOrder;
      return left.transport.routeRank.compareTo(right.transport.routeRank);
    });
    return routes;
  }

  Future<TransportDeliveryResult> deliverEnvelope({
    required TransportPeer peer,
    required TransportEnvelope envelope,
    required Map<TransportKind, TransportPolicy> policies,
    // A fresh Iroh connection includes discovery/NAT traversal (the native
    // dial alone permits ten seconds). The adapter may first discard a stale
    // direct hint and retry endpoint-only, so thirty seconds can cut off the
    // recovery path while the native send is still healthy.
    Duration? attemptTimeout,
    // Routes not to use this time (they took earlier messages no receipt
    // confirmed); the caller tries them last.
    Set<String> skipRouteIds = const {},
    // False once the envelope is no longer needed (its receipt came while
    // a slow route was still trying): no further route is tried.
    bool Function()? stillWanted,
  }) async {
    final routes = [
      for (final route in await routesFor(peer, policies: policies))
        if (!skipRouteIds.contains(route.routeId)) route,
    ];
    final attempts = <DeliveryAttempt>[];
    Object? lastError;
    for (final route in routes) {
      if (!route.permitsPayload(envelope.bytes.length)) continue;
      final adapter = _adapters[route.transport];
      if (adapter == null) continue;
      if (stillWanted != null && !stillWanted()) {
        throw const TransportSendCancelled('Its receipt already came.');
      }
      final startedAt = DateTime.now().toUtc();
      // A send that waits for its turn behind the account's limiter would
      // measure the queue, not the route: no sample from it.
      final NetworkLimiter? turns = switch (adapter) {
        RateLimited(:final limiter) => limiter,
        _ => null,
      };
      final queued = turns != null && turns.projectedWait > Duration.zero;
      // Raised by the limiter while THIS send waits for its turn.
      final waiting = LimiterWaitProbe();
      try {
        final receipt =
            await runZoned(
              () => adapter.sendEnvelope(
                peer: peer,
                route: route,
                envelope: envelope,
              ),
              zoneValues: {LimiterWaitProbe.zoneKey: waiting},
            ).timeout(
              attemptTimeout ??
                  adapter.capabilities.sendAttemptTimeout ??
                  (route.transport == TransportKind.iroh
                      ? const Duration(seconds: 60)
                      : const Duration(seconds: 4)),
            );
        final completedAt = DateTime.now().toUtc();
        attempts.add(
          DeliveryAttempt(
            route: route,
            startedAt: startedAt,
            completedAt: completedAt,
          ),
        );
        if (receipt.accepted) {
          final took = completedAt.difference(startedAt);
          final small = envelope.bytes.length <= _latencySampleBytes;
          _recordSuccess(
            peer.deviceId,
            route.transport,
            small && !queued ? took : null,
            bytes: small || queued ? null : envelope.bytes.length,
            transferTook: small || queued ? null : took,
          );
          return TransportDeliveryResult(
            receipt: receipt,
            attempts: List.unmodifiable(attempts),
          );
        }
        lastError = receipt.detail ?? 'Transport rejected the envelope.';
        _recordFailure(peer.deviceId, route.transport, lastError);
      } on TransportSendCancelled {
        rethrow;
      } catch (error) {
        lastError = error;
        var limiterHeld = error is LimiterRefused;
        if (error is TimeoutException) {
          // The attempt ran out: stop the send, so it does not go on
          // sending frames the caller has given up on.
          unawaited(
            adapter
                .cancel(transportOperationId(peer.deviceId, envelope.id))
                .catchError((Object _) {}),
          );
          // Only this send still waiting for its turn behind the account's
          // limiter says nothing about the route; other chats queued there
          // do not excuse a network call that hung.
          limiterHeld = waiting.isWaiting;
        }
        // The account's own limiter holding a send back says nothing about
        // the route: the next route goes, and this one is not marked failed.
        if (!limiterHeld) {
          _recordFailure(peer.deviceId, route.transport, error);
        }
        attempts.add(
          DeliveryAttempt(
            route: route,
            startedAt: startedAt,
            completedAt: DateTime.now().toUtc(),
            error: error,
          ),
        );
      }
    }
    throw StateError(
      routes.isEmpty
          ? 'No eligible transport route.'
          : 'All transport routes failed: ${lastError ?? 'unknown error'}',
    );
  }

  /// A round trip measured outside a delivery (a route test).
  void noteRoundTrip(String deviceId, TransportKind kind, Duration took) =>
      _recordSuccess(deviceId, kind, took);

  void _recordSuccess(
    String deviceId,
    TransportKind kind,
    Duration? took, {
    int? bytes,
    Duration? transferTook,
  }) {
    onOutcome?.call(kind, true, null);
    _statsEntry(
      deviceId,
      kind,
    ).recordSuccess(_now(), rtt: took, bytes: bytes, took: transferTook);
  }

  void _recordFailure(String deviceId, TransportKind kind, [Object? error]) {
    onOutcome?.call(kind, false, error);
    _statsEntry(deviceId, kind).recordFailure(_now());
  }

  /// Rough send time before anything is measured: the path kind, and how
  /// slow the network behind the transport usually is.
  static double _expectedLatencyMs(RouteCandidate route) =>
      switch (route.path) {
        TransportPathKind.local => 30.0,
        TransportPathKind.direct => 250.0,
        TransportPathKind.relayed => 700.0,
        TransportPathKind.storeForward => 1500.0,
        TransportPathKind.manual => 60000.0,
      } +
      switch (route.transport) {
        TransportKind.tor => 2500.0,
        TransportKind.deltaChat => 3000.0,
        TransportKind.bitchat => 2000.0,
        TransportKind.reticulum ||
        TransportKind.meshtastic ||
        TransportKind.meshCore => 20000.0,
        _ => 0.0,
      };

  static int _policyPriority(TransportPolicy policy) => switch (policy) {
    TransportPolicy.preferred => 0,
    TransportPolicy.automatic => 1,
    TransportPolicy.askBeforeUse => 2,
    TransportPolicy.disabled => 3,
  };

  /// Tor reaches the contact directly but through three relays each way,
  /// so it ranks with relayed routes rather than ahead of them.
  static int _routePriority(RouteCandidate route) =>
      route.transport == TransportKind.tor
      ? max(_pathPriority(route.path), _pathPriority(TransportPathKind.relayed))
      : _pathPriority(route.path);

  static int _pathPriority(TransportPathKind path) => switch (path) {
    TransportPathKind.local => 0,
    TransportPathKind.direct => 1,
    TransportPathKind.relayed => 2,
    TransportPathKind.storeForward => 3,
    TransportPathKind.manual => 4,
  };
}
