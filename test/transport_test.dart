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
    'Iroh delivery can finish after four seconds and explicit timeouts still apply',
    () async {
      final adapter = _FakeAdapter(
        kind: TransportKind.iroh,
        route: _route(TransportKind.iroh, TransportPathKind.direct),
        sendDelay: const Duration(milliseconds: 4100),
      );
      final registry = TransportRegistry([adapter]);
      final result = await registry.deliverEnvelope(
        peer: peer,
        envelope: _envelope(),
        policies: const {TransportKind.iroh: TransportPolicy.automatic},
      );
      expect(result.receipt.accepted, isTrue);
      await expectLater(
        registry.deliverEnvelope(
          peer: peer,
          envelope: _envelope(),
          policies: const {TransportKind.iroh: TransportPolicy.automatic},
          attemptTimeout: const Duration(milliseconds: 1),
        ),
        throwsStateError,
      );
    },
  );

  test('Iroh transfer limit defaults on and persists an explicit opt-out', () {
    expect(
      const GlobalConnectivityPreferences().irohTransferLimitEnabled,
      isTrue,
    );
    expect(
      GlobalConnectivityPreferences.fromJson({}).irohTransferLimitEnabled,
      isTrue,
    );
    final disabled = const GlobalConnectivityPreferences().copyWith(
      irohTransferLimitEnabled: false,
    );
    final loaded = GlobalConnectivityPreferences.fromJson(disabled.toJson());
    expect(loaded.irohTransferLimitEnabled, isFalse);
    expect(
      loaded.copyWith(lanEnabled: false).irohTransferLimitEnabled,
      isFalse,
    );
  });

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

  test('a route that just failed waits behind working ones', () async {
    var now = DateTime.utc(2026, 10, 6, 9);
    final lan = _FakeAdapter(
      kind: TransportKind.lan,
      route: _route(TransportKind.lan, TransportPathKind.local),
      fail: true,
    );
    final iroh = _FakeAdapter(
      kind: TransportKind.iroh,
      route: _route(TransportKind.iroh, TransportPathKind.direct),
    );
    final registry = TransportRegistry([lan, iroh], now: () => now);
    Future<TransportKind> deliver() async => (await registry.deliverEnvelope(
      peer: peer,
      envelope: _envelope(),
      policies: const {},
    )).receipt.route.transport;

    // LAN is tried first and fails; Iroh delivers.
    expect(await deliver(), TransportKind.iroh);
    expect(lan.sendCount, 1);
    // Right after, the failed LAN route is not tried first.
    expect(await deliver(), TransportKind.iroh);
    expect(lan.sendCount, 1);
    // Once it has cooled down it gets its turn again, and works.
    lan.fail = false;
    now = now.add(const Duration(seconds: 16));
    expect(await deliver(), TransportKind.lan);
    expect(
      registry.statsFor(peer.deviceId, TransportKind.lan)!.failureStreak,
      0,
    );
  });

  test(
    'within a path kind the faster route for a contact goes first',
    () async {
      final iroh = _FakeAdapter(
        kind: TransportKind.iroh,
        route: _route(TransportKind.iroh, TransportPathKind.relayed),
        sendDelay: const Duration(milliseconds: 200),
      );
      final relay = _FakeAdapter(
        kind: TransportKind.conestRelay,
        route: _route(TransportKind.conestRelay, TransportPathKind.relayed),
      );
      final registry = TransportRegistry([iroh, relay]);
      // Unmeasured, the usual order holds.
      expect(
        (await registry.routesFor(peer, policies: const {})).first.transport,
        TransportKind.iroh,
      );
      // One send over each measures them.
      for (final kind in [TransportKind.iroh, TransportKind.conestRelay]) {
        await registry.deliverEnvelope(
          peer: peer,
          envelope: _envelope(),
          policies: {kind: TransportPolicy.preferred},
        );
      }
      expect(
        (await registry.routesFor(peer, policies: const {})).first.transport,
        TransportKind.conestRelay,
      );
      // Another contact has no measurements, so keeps the usual order.
      expect(
        (await registry.routesFor(
          const TransportPeer(deviceId: 'someone-else'),
          policies: const {},
        )).first.transport,
        TransportKind.iroh,
      );
    },
  );

  test('Tor ranks after relayed routes despite its direct path', () async {
    final registry = TransportRegistry([
      for (final (kind, path) in [
        (TransportKind.tor, TransportPathKind.direct),
        (TransportKind.conestRelay, TransportPathKind.relayed),
        (TransportKind.iroh, TransportPathKind.direct),
        (TransportKind.matrix, TransportPathKind.storeForward),
      ])
        _FakeAdapter(kind: kind, route: _route(kind, path)),
    ]);
    final routes = await registry.routesFor(peer, policies: const {});
    expect(routes.map((route) => route.transport), [
      TransportKind.iroh,
      TransportKind.conestRelay,
      TransportKind.tor,
      TransportKind.matrix,
    ]);
  });

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
    'Iroh retries endpoint discovery after stale direct hint failure',
    () async {
      final bridge = _FakeIrohBridge(endpointId: 'endpoint-peer')
        ..failWhenDirectAddressesProvided = true;
      final adapter = IrohTransportAdapter(
        bridge: bridge,
        secretKeySeed: Uint8List(32),
        relayEnabled: true,
        expectedEndpointId: 'endpoint-peer',
      );
      await adapter.start();
      addTearDown(adapter.stop);
      final hintedPeer = const TransportPeer(
        deviceId: 'peer',
        transportIdentity: 'endpoint-peer',
        identityPinned: true,
        directAddresses: ['10.0.0.8:40000'],
      );

      final receipt = await adapter.sendEnvelope(
        peer: hintedPeer,
        route: _route(TransportKind.iroh, TransportPathKind.direct),
        envelope: _envelope(),
      );

      expect(receipt.accepted, isTrue);
      expect(bridge.sendCalls, 2);
      expect(bridge.lastDirectAddresses, isEmpty);
    },
  );

  test(
    'Iroh retries endpoint-only discovery after a transient first failure',
    () async {
      final bridge = _FakeIrohBridge(endpointId: 'endpoint-peer')
        ..failFirstSend = true;
      final adapter = IrohTransportAdapter(
        bridge: bridge,
        secretKeySeed: Uint8List(32),
        relayEnabled: true,
        expectedEndpointId: 'endpoint-peer',
      );
      await adapter.start();
      addTearDown(adapter.stop);

      final receipt = await adapter.sendEnvelope(
        peer: peer,
        route: _route(TransportKind.iroh, TransportPathKind.direct),
        envelope: _envelope(),
      );

      expect(receipt.accepted, isTrue);
      expect(bridge.sendCalls, 2);
      expect(bridge.lastDirectAddresses, isEmpty);
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
  _FakeAdapter({
    required this.kind,
    required this.route,
    this.fail = false,
    this.sendDelay = Duration.zero,
  });

  @override
  final TransportKind kind;
  final RouteCandidate route;
  bool fail;
  final Duration sendDelay;
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
    if (sendDelay > Duration.zero) await Future<void>.delayed(sendDelay);
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
  bool failWhenDirectAddressesProvided = false;
  bool failFirstSend = false;
  int sendCalls = 0;

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
    sendCalls++;
    lastAllowRelay = allowRelay;
    lastDirectAddresses = List<String>.from(directAddresses);
    lastBytes = Uint8List.fromList(bytes);
    if (failFirstSend && sendCalls == 1) {
      throw TimeoutException('transient endpoint discovery failure');
    }
    if (failWhenDirectAddressesProvided && directAddresses.isNotEmpty) {
      throw TimeoutException('stale direct hint');
    }
    return IrohBridgeReceipt(
      endpointId: remoteEndpointId,
      relayed: relayed,
      accepted: true,
    );
  }

  @override
  Future<void> close() async => closed = true;
}
