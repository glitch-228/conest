import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/iroh_transport.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final peer = const TransportPeer(
    deviceId: 'peer',
    transportIdentity: 'endpoint-peer',
    identityPinned: true,
  );

  test(
    'registry prefers configured routes and falls back sequentially',
    () async {
      final failed = _FakeAdapter(
        kind: TransportKind.lan,
        route: _route(TransportKind.lan, TransportPathKind.local),
        fail: true,
      );
      final accepted = _FakeAdapter(
        kind: TransportKind.iroh,
        route: _route(TransportKind.iroh, TransportPathKind.direct),
      );
      final registry = TransportRegistry([failed, accepted]);
      final result = await registry.deliverEnvelope(
        peer: peer,
        envelope: _envelope(),
        policies: const {
          TransportKind.lan: TransportPolicy.preferred,
          TransportKind.iroh: TransportPolicy.automatic,
        },
      );
      expect(result.receipt.route.transport, TransportKind.iroh);
      expect(result.attempts.map((entry) => entry.route.transport), [
        TransportKind.lan,
        TransportKind.iroh,
      ]);
    },
  );

  test(
    'ask-before-use routes never participate in automatic delivery',
    () async {
      final adapter = _FakeAdapter(
        kind: TransportKind.iroh,
        route: _route(TransportKind.iroh, TransportPathKind.direct),
      );
      final registry = TransportRegistry([adapter]);
      expect(
        () => registry.deliverEnvelope(
          peer: peer,
          envelope: _envelope(),
          policies: const {TransportKind.iroh: TransportPolicy.askBeforeUse},
        ),
        throwsStateError,
      );
      expect(adapter.sendCount, 0);
    },
  );

  test('route payload cap skips relay without attempting it', () async {
    final relay = _FakeAdapter(
      kind: TransportKind.conestRelay,
      route: RouteCandidate(
        transport: TransportKind.conestRelay,
        path: TransportPathKind.storeForward,
        routeId: 'relay',
        label: 'Conest relay',
        trust: TransportTrustState.pinnedTransport,
        maximumPayloadBytes: 2,
      ),
    );
    final direct = _FakeAdapter(
      kind: TransportKind.iroh,
      route: _route(TransportKind.iroh, TransportPathKind.direct),
    );
    final result = await TransportRegistry([relay, direct]).deliverEnvelope(
      peer: peer,
      envelope: _envelope(),
      policies: const {
        TransportKind.conestRelay: TransportPolicy.preferred,
        TransportKind.iroh: TransportPolicy.automatic,
      },
    );
    expect(relay.sendCount, 0);
    expect(result.receipt.route.transport, TransportKind.iroh);
  });

  test(
    'custom Iroh relay URLs persist, deduplicate, and reject insecure URLs',
    () {
      final urls = normalizeIrohRelayUrls([
        ' https://relay.example.test ',
        'https://relay.example.test',
        'https://backup.example.test/',
      ]);
      final prefs = GlobalConnectivityPreferences(
        irohRelayUrls: urls,
        irohCustomRelaysBulkCapable: true,
      );
      final restored = GlobalConnectivityPreferences.fromJson(prefs.toJson());
      expect(restored.irohRelayUrls, [
        'https://relay.example.test',
        'https://backup.example.test/',
      ]);
      expect(restored.irohCustomRelaysBulkCapable, isTrue);
      expect(
        () => normalizeIrohRelayUrls(['http://relay.example.test']),
        throwsArgumentError,
      );
    },
  );

  test('Iroh startup rejects an endpoint identity mismatch', () async {
    final bridge = _FakeIrohBridge(endpointId: 'unexpected');
    final adapter = IrohTransportAdapter(
      bridge: bridge,
      secretKeySeed: Uint8List(32),
      relayEnabled: true,
      expectedEndpointId: 'expected',
    );
    await expectLater(adapter.start(), throwsStateError);
    expect(bridge.closed, isTrue);
  });

  test(
    'Iroh attachment ranges use a bounded binary authenticated frame',
    () async {
      final bridge = _FakeIrohBridge(endpointId: 'endpoint-peer');
      final adapter = IrohTransportAdapter(
        bridge: bridge,
        secretKeySeed: Uint8List(32),
        relayEnabled: false,
        expectedEndpointId: 'endpoint-peer',
      );
      await adapter.start();
      final hash = Uint8List.fromList(List<int>.generate(32, (index) => index));
      await adapter.sendAttachmentRange(
        peer: peer,
        route: _route(TransportKind.iroh, TransportPathKind.direct),
        range: AttachmentRange(
          attachmentId: 'attachment-1',
          offset: 8 * 1024 * 1024,
          bytes: Uint8List.fromList([4, 5, 6, 7]),
          sha256Base64: base64Encode(hash),
        ),
      );
      final decoded = decodeIrohAttachmentRangeFrame(bridge.lastBytes!);
      expect(decoded, isNotNull);
      expect(decoded!.attachmentId, 'attachment-1');
      expect(decoded.offset, 8 * 1024 * 1024);
      expect(decoded.bytes, [4, 5, 6, 7]);
      expect(decoded.sha256, hash);
      expect(
        decodeIrohAttachmentRangeFrame(Uint8List.fromList([0x7b, 0x7d])),
        isNull,
      );
      await adapter.stop();
    },
  );

  test(
    'Iroh relay result is rejected when contact relay use is disabled',
    () async {
      final bridge = _FakeIrohBridge(
        endpointId: 'endpoint-peer',
        relayed: true,
      );
      final adapter = IrohTransportAdapter(
        bridge: bridge,
        secretKeySeed: Uint8List(32),
        relayEnabled: true,
        expectedEndpointId: 'endpoint-peer',
      );
      await adapter.start();
      final route = _route(TransportKind.iroh, TransportPathKind.direct);
      await expectLater(
        adapter.sendEnvelope(
          peer: const TransportPeer(
            deviceId: 'peer',
            transportIdentity: 'endpoint-peer',
            identityPinned: true,
            allowRelay: false,
            directAddresses: ['192.0.2.10:45837'],
          ),
          route: route,
          envelope: _envelope(),
        ),
        throwsStateError,
      );
      expect(bridge.lastAllowRelay, isFalse);
      expect(bridge.lastDirectAddresses, ['192.0.2.10:45837']);
      await adapter.stop();
    },
  );

  test(
    'Iroh retries a direct path after a previous relayed delivery',
    () async {
      final bridge = _FakeIrohBridge(endpointId: 'peer', relayed: true);
      final adapter = IrohTransportAdapter(
        bridge: bridge,
        secretKeySeed: Uint8List(32),
        relayEnabled: true,
      );
      await adapter.start();
      addTearDown(adapter.stop);
      const relayedPeer = TransportPeer(
        deviceId: 'peer',
        transportIdentity: 'peer',
        identityPinned: true,
      );
      await adapter.sendEnvelope(
        peer: relayedPeer,
        route: (await adapter.discoverRoutes(relayedPeer)).single,
        envelope: _envelope(),
      );
      const directPeer = TransportPeer(
        deviceId: 'peer',
        transportIdentity: 'peer',
        identityPinned: true,
        allowRelay: false,
      );
      final routes = await adapter.discoverRoutes(directPeer);
      expect(routes.single.path, TransportPathKind.direct);
      bridge.relayed = false;
      final receipt = await adapter.sendEnvelope(
        peer: directPeer,
        route: routes.single,
        envelope: _envelope(),
      );
      expect(receipt.accepted, isTrue);
      expect(bridge.lastAllowRelay, isFalse);
    },
  );
}

TransportEnvelope _envelope() => TransportEnvelope(
  id: 'message-1',
  recipientDeviceId: 'peer',
  bytes: Uint8List.fromList([1, 2, 3]),
  createdAt: DateTime.utc(2026, 8, 15),
);

RouteCandidate _route(TransportKind kind, TransportPathKind path) =>
    RouteCandidate(
      transport: kind,
      path: path,
      routeId: '${kind.name}:${path.name}',
      label: kind.label,
      trust: TransportTrustState.pinnedTransport,
    );

class _FakeAdapter implements TransportAdapter {
  _FakeAdapter({required this.kind, required this.route, this.fail = false});

  @override
  final TransportKind kind;
  final RouteCandidate route;
  final bool fail;
  int sendCount = 0;

  @override
  TransportCapabilities get capabilities => const TransportCapabilities(
    requiresPeerOnline: false,
    supportsStoreForward: false,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: true,
    reportsPath: true,
  );

  @override
  Stream<TransportInboundEnvelope> get inboundEnvelopes => const Stream.empty();
  @override
  Stream<RouteCandidate> get pathChanges => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel(String operationId) async {}
  @override
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer) async => [
    route,
  ];

  @override
  Future<DeliveryReceipt> sendEnvelope({
    required TransportPeer peer,
    required RouteCandidate route,
    required TransportEnvelope envelope,
  }) async {
    sendCount++;
    if (fail) throw StateError('unavailable');
    return DeliveryReceipt(
      state: DeliveryReceiptState.deliveredToPeer,
      route: route,
      at: DateTime.now().toUtc(),
    );
  }

  @override
  Future<DeliveryReceipt> sendAttachmentRange({
    required TransportPeer peer,
    required RouteCandidate route,
    required AttachmentRange range,
  }) => throw UnimplementedError();
}

class _FakeIrohBridge implements NativeIrohBridge {
  _FakeIrohBridge({required this.endpointId, this.relayed = false});

  final String endpointId;
  bool relayed;
  bool closed = false;
  bool? lastAllowRelay;
  List<String> lastDirectAddresses = const <String>[];
  Uint8List? lastBytes;

  @override
  Stream<IrohBridgeInbound> get inbound => const Stream.empty();

  @override
  Future<IrohBridgeStatus> start({
    required Uint8List secretKeySeed,
    required bool relayEnabled,
    required List<String> relayUrls,
  }) async => IrohBridgeStatus(
    endpointId: endpointId,
    directAddresses: const [],
    relayEnabled: relayEnabled,
  );

  @override
  Future<IrohBridgeReceipt> sendEnvelope({
    required String remoteEndpointId,
    required Uint8List bytes,
    required bool allowRelay,
    List<String> directAddresses = const <String>[],
  }) async {
    lastAllowRelay = allowRelay;
    lastDirectAddresses = List<String>.from(directAddresses);
    lastBytes = Uint8List.fromList(bytes);
    return IrohBridgeReceipt(
      endpointId: remoteEndpointId,
      relayed: relayed,
      accepted: true,
    );
  }

  @override
  Future<void> close() async => closed = true;
}
