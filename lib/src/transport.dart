import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

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
class TransportRouteStats {
  /// Moving average of accepted sends of small envelopes, in milliseconds.
  double? latencyMs;
  int failureStreak = 0;
  DateTime? lastFailureAt;
  DateTime? lastSuccessAt;

  /// While a route that just failed cools down, working routes go first.
  bool coolingAt(DateTime now) {
    final failedAt = lastFailureAt;
    if (failureStreak == 0 || failedAt == null) return false;
    final seconds = min(15 * (1 << min(failureStreak - 1, 10)), 600);
    return now.difference(failedAt) < Duration(seconds: seconds);
  }
}

class TransportRegistry {
  TransportRegistry(
    Iterable<TransportAdapter> adapters, {
    DateTime Function()? now,
  }) : _adapters = {for (final adapter in adapters) adapter.kind: adapter},
       _now = now ?? DateTime.now;

  final Map<TransportKind, TransportAdapter> _adapters;
  final DateTime Function() _now;

  /// Route statistics by `deviceId|transport`, oldest first.
  final Map<String, TransportRouteStats> _stats = {};
  static const int _maxStats = 4096;

  /// Envelopes up to this size time the route rather than the payload.
  static const int _latencySampleBytes = 64 * 1024;

  TransportRouteStats? statsFor(String deviceId, TransportKind kind) =>
      _stats['$deviceId|${kind.name}'];

  TransportRouteStats _statsEntry(String deviceId, TransportKind kind) {
    final key = '$deviceId|${kind.name}';
    final entry = _stats.remove(key) ?? TransportRouteStats();
    _stats[key] = entry;
    if (_stats.length > _maxStats) _stats.remove(_stats.keys.first);
    return entry;
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
    double speed(RouteCandidate route) =>
        statsFor(peer.deviceId, route.transport)?.latencyMs ??
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
  }) async {
    final routes = await routesFor(peer, policies: policies);
    final attempts = <DeliveryAttempt>[];
    Object? lastError;
    for (final route in routes) {
      if (!route.permitsPayload(envelope.bytes.length)) continue;
      final adapter = _adapters[route.transport];
      if (adapter == null) continue;
      final startedAt = DateTime.now().toUtc();
      try {
        final receipt = await adapter
            .sendEnvelope(peer: peer, route: route, envelope: envelope)
            .timeout(
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
          _recordSuccess(
            peer.deviceId,
            route.transport,
            envelope.bytes.length <= _latencySampleBytes
                ? completedAt.difference(startedAt)
                : null,
          );
          return TransportDeliveryResult(
            receipt: receipt,
            attempts: List.unmodifiable(attempts),
          );
        }
        lastError = receipt.detail ?? 'Transport rejected the envelope.';
        _recordFailure(peer.deviceId, route.transport);
      } catch (error) {
        lastError = error;
        _recordFailure(peer.deviceId, route.transport);
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

  void _recordSuccess(String deviceId, TransportKind kind, Duration? took) {
    final stats = _statsEntry(deviceId, kind)
      ..failureStreak = 0
      ..lastSuccessAt = _now();
    if (took == null) return;
    final sample = took.inMicroseconds / 1000;
    final previous = stats.latencyMs;
    stats.latencyMs = previous == null ? sample : previous * 0.7 + sample * 0.3;
  }

  void _recordFailure(String deviceId, TransportKind kind) {
    _statsEntry(deviceId, kind)
      ..failureStreak += 1
      ..lastFailureAt = _now();
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
