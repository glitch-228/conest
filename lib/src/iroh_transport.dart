import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';
import 'transport_models.dart';

class IrohBridgeStatus {
  const IrohBridgeStatus({
    required this.endpointId,
    required this.directAddresses,
    required this.relayEnabled,
    this.relayUrl,
  });

  final String endpointId;
  final List<String> directAddresses;
  final String? relayUrl;
  final bool relayEnabled;
}

class IrohBridgeReceipt {
  const IrohBridgeReceipt({
    required this.endpointId,
    required this.relayed,
    required this.accepted,
  });

  final String endpointId;
  final bool relayed;
  final bool accepted;
}

class IrohBridgeInbound {
  const IrohBridgeInbound({
    required this.senderEndpointId,
    required this.bytes,
    required this.relayed,
  });

  final String senderEndpointId;
  final Uint8List bytes;
  final bool relayed;
}

/// Narrow seam around generated flutter_rust_bridge bindings. Keeping this
/// interface hand-written makes routing and identity tests deterministic and
/// isolates generated-code churn from the rest of the application.
abstract interface class NativeIrohBridge {
  Future<IrohBridgeStatus> start({
    required Uint8List secretKeySeed,
    required bool relayEnabled,
    required List<String> relayUrls,
  });
  Future<IrohBridgeReceipt> sendEnvelope({
    required String remoteEndpointId,
    required Uint8List bytes,
  });
  Stream<IrohBridgeInbound> get inbound;
  Future<void> close();
}

class IrohTransportAdapter implements TransportAdapter {
  IrohTransportAdapter({
    required NativeIrohBridge bridge,
    required Uint8List secretKeySeed,
    required bool relayEnabled,
    this.relayUrls = const [],
    this.expectedEndpointId,
  }) : _bridge = bridge,
       _secretKeySeed = Uint8List.fromList(secretKeySeed),
       _relayEnabled = relayEnabled;

  final NativeIrohBridge _bridge;
  final Uint8List _secretKeySeed;
  final bool _relayEnabled;
  final List<String> relayUrls;
  final String? expectedEndpointId;
  final StreamController<RouteCandidate> _pathChanges =
      StreamController<RouteCandidate>.broadcast();
  final StreamController<TransportInboundEnvelope> _inbound =
      StreamController<TransportInboundEnvelope>.broadcast();
  StreamSubscription<IrohBridgeInbound>? _inboundSubscription;
  IrohBridgeStatus? _status;
  final Map<String, TransportPathKind> _lastPathByEndpoint = {};

  IrohBridgeStatus? get status => _status;

  @override
  TransportKind get kind => TransportKind.iroh;

  @override
  TransportCapabilities get capabilities => const TransportCapabilities(
    requiresPeerOnline: true,
    supportsStoreForward: false,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: true,
    reportsPath: true,
  );

  @override
  Stream<RouteCandidate> get pathChanges => _pathChanges.stream;

  @override
  Stream<TransportInboundEnvelope> get inboundEnvelopes => _inbound.stream;

  @override
  Future<void> start() async {
    if (_status != null) return;
    final status = await _bridge.start(
      secretKeySeed: _secretKeySeed,
      relayEnabled: _relayEnabled,
      relayUrls: relayUrls,
    );
    if (expectedEndpointId != null && status.endpointId != expectedEndpointId) {
      await _bridge.close();
      throw StateError(
        'Native Iroh endpoint identity does not match the pinned installation key.',
      );
    }
    _status = status;
    _inboundSubscription = _bridge.inbound.listen((event) {
      final path = event.relayed
          ? TransportPathKind.relayed
          : TransportPathKind.direct;
      _lastPathByEndpoint[event.senderEndpointId] = path;
      _inbound.add(
        TransportInboundEnvelope(
          transport: TransportKind.iroh,
          path: path,
          senderTransportIdentity: event.senderEndpointId,
          bytes: event.bytes,
          receivedAt: DateTime.now().toUtc(),
        ),
      );
    });
  }

  @override
  Future<void> stop() async {
    await _inboundSubscription?.cancel();
    _inboundSubscription = null;
    if (_status != null) await _bridge.close();
    _status = null;
  }

  @override
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer) async {
    if (_status == null ||
        !peer.identityPinned ||
        peer.transportIdentity?.isNotEmpty != true) {
      return const [];
    }
    final endpoint = peer.transportIdentity!;
    final lastPath = _lastPathByEndpoint[endpoint] ?? TransportPathKind.direct;
    if (lastPath == TransportPathKind.relayed &&
        (!_relayEnabled || !peer.allowRelay)) {
      return const [];
    }
    return [
      RouteCandidate(
        transport: TransportKind.iroh,
        path: lastPath,
        routeId: 'iroh:$endpoint',
        label: lastPath == TransportPathKind.relayed
            ? 'Iroh relay'
            : 'Direct online',
        trust: TransportTrustState.pinnedTransport,
        detail: endpoint,
      ),
    ];
  }

  @override
  Future<DeliveryReceipt> sendEnvelope({
    required TransportPeer peer,
    required RouteCandidate route,
    required TransportEnvelope envelope,
  }) async {
    final endpoint = peer.transportIdentity;
    if (!peer.identityPinned || endpoint == null || endpoint.isEmpty) {
      throw StateError('Iroh transport identity is not pinned.');
    }
    final result = await _bridge.sendEnvelope(
      remoteEndpointId: endpoint,
      bytes: envelope.bytes,
    );
    if (result.endpointId != endpoint) {
      throw StateError('Iroh peer identity changed during delivery.');
    }
    final path = result.relayed
        ? TransportPathKind.relayed
        : TransportPathKind.direct;
    if (path == TransportPathKind.relayed &&
        (!_relayEnabled || !peer.allowRelay)) {
      throw StateError('Iroh relay use is disabled for this contact.');
    }
    _lastPathByEndpoint[endpoint] = path;
    final actualRoute = RouteCandidate(
      transport: TransportKind.iroh,
      path: path,
      routeId: 'iroh:$endpoint',
      label: path == TransportPathKind.relayed ? 'Iroh relay' : 'Direct online',
      trust: TransportTrustState.pinnedTransport,
      detail: endpoint,
    );
    _pathChanges.add(actualRoute);
    return DeliveryReceipt(
      state: result.accepted
          ? DeliveryReceiptState.deliveredToPeer
          : DeliveryReceiptState.failed,
      route: actualRoute,
      at: DateTime.now().toUtc(),
      detail: result.accepted ? 'Peer acknowledged Iroh stream.' : 'Rejected.',
    );
  }

  @override
  Future<DeliveryReceipt> sendAttachmentRange({
    required TransportPeer peer,
    required RouteCandidate route,
    required AttachmentRange range,
  }) {
    final operation = TransportEnvelope(
      id: '${range.attachmentId}:${range.offset}',
      recipientDeviceId: peer.deviceId,
      bytes: range.bytes,
      createdAt: DateTime.now().toUtc(),
    );
    return sendEnvelope(peer: peer, route: route, envelope: operation);
  }

  @override
  Future<void> cancel(String operationId) async {
    // QUIC stream cancellation is scoped to an in-flight generated bridge
    // call. The controller stops issuing ranges; already-acknowledged ranges
    // remain valid and resume safely on another transport.
  }
}
