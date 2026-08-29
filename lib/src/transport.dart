import 'dart:async';
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
  });

  final bool requiresPeerOnline;
  final bool supportsStoreForward;
  final bool duplex;
  final bool requiresUserAction;
  final bool supportsAttachmentStreaming;
  final bool reportsPath;
  final int? maximumPayloadBytes;
}

class TransportPeer {
  const TransportPeer({
    required this.deviceId,
    this.transportIdentity,
    this.identityPinned = false,
    this.allowRelay = true,
    this.directAddresses = const <String>[],
  });

  final String deviceId;
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

class TransportRegistry {
  TransportRegistry(Iterable<TransportAdapter> adapters)
    : _adapters = {for (final adapter in adapters) adapter.kind: adapter};

  final Map<TransportKind, TransportAdapter> _adapters;

  Iterable<TransportAdapter> get adapters => _adapters.values;
  TransportAdapter? adapterFor(TransportKind kind) => _adapters[kind];

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
    routes.sort((left, right) {
      final leftPolicy = policies[left.transport] ?? TransportPolicy.automatic;
      final rightPolicy =
          policies[right.transport] ?? TransportPolicy.automatic;
      final policyOrder = _policyPriority(
        leftPolicy,
      ).compareTo(_policyPriority(rightPolicy));
      if (policyOrder != 0) return policyOrder;
      return _pathPriority(left.path).compareTo(_pathPriority(right.path));
    });
    return routes;
  }

  Future<TransportDeliveryResult> deliverEnvelope({
    required TransportPeer peer,
    required TransportEnvelope envelope,
    required Map<TransportKind, TransportPolicy> policies,
    Duration attemptTimeout = const Duration(seconds: 4),
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
            .timeout(attemptTimeout);
        attempts.add(
          DeliveryAttempt(
            route: route,
            startedAt: startedAt,
            completedAt: DateTime.now().toUtc(),
          ),
        );
        if (receipt.accepted) {
          return TransportDeliveryResult(
            receipt: receipt,
            attempts: List.unmodifiable(attempts),
          );
        }
        lastError = receipt.detail ?? 'Transport rejected the envelope.';
      } catch (error) {
        lastError = error;
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

  static int _policyPriority(TransportPolicy policy) => switch (policy) {
    TransportPolicy.preferred => 0,
    TransportPolicy.automatic => 1,
    TransportPolicy.askBeforeUse => 2,
    TransportPolicy.disabled => 3,
  };

  static int _pathPriority(TransportPathKind path) => switch (path) {
    TransportPathKind.local => 0,
    TransportPathKind.direct => 1,
    TransportPathKind.relayed => 2,
    TransportPathKind.storeForward => 3,
    TransportPathKind.manual => 4,
  };
}
