import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/messenger_controller.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/relay_client.dart';
import 'package:conest/src/storage.dart';

class _MemoryVaultStore extends VaultStore {
  VaultSnapshot _snapshot = VaultSnapshot.empty();

  @override
  Future<VaultSnapshot> load() async => _snapshot;

  @override
  Future<void> save(VaultSnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  Future<void> clear() async {
    _snapshot = VaultSnapshot.empty();
  }
}

class _FakeLocalRelayNode extends LocalRelayNode {
  int? _currentPort;
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  int? get port => _currentPort;

  @override
  Future<void> start(int port) async {
    _running = true;
    _currentPort = port;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _currentPort = null;
  }
}

class _FakeRelayClient extends RelayClient {
  _FakeRelayClient({
    Set<String>? failingHosts,
    Set<String>? storeFailingHosts,
    Map<String, String>? relayInstanceIds,
  }) : _healthFailingHosts = failingHosts ?? <String>{},
       _storeFailingHosts = storeFailingHosts ?? failingHosts ?? <String>{},
       _relayInstanceIds = relayInstanceIds ?? const <String, String>{};

  final Set<String> _healthFailingHosts;
  final Set<String> _storeFailingHosts;
  final Map<String, String> _relayInstanceIds;
  final List<String> storeAttempts = <String>[];
  final Map<String, List<RelayEnvelope>> _queues =
      <String, List<RelayEnvelope>>{};

  String _key(String host, int port, PeerRouteProtocol protocol) =>
      '${protocol.name}://$host:$port';
  bool _containsRoute(
    Set<String> values,
    String host,
    int port,
    PeerRouteProtocol protocol,
  ) {
    return values.contains(_key(host, port, protocol)) ||
        values.contains('$host:$port');
  }

  String _relayIdFor(String host, int port, PeerRouteProtocol protocol) {
    return _relayInstanceIds[_key(host, port, protocol)] ??
        _relayInstanceIds['$host:$port'] ??
        'fake-relay-$host:$port';
  }

  @override
  Future<bool> storeEnvelope({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    required RelayEnvelope envelope,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final key = _key(host, port, protocol);
    storeAttempts.add('$host:$port');
    if (_containsRoute(_storeFailingHosts, host, port, protocol)) {
      throw StateError('Route unavailable for $key');
    }
    final queue = _queues.putIfAbsent(
      recipientDeviceId,
      () => <RelayEnvelope>[],
    );
    if (envelope.kind == 'pairing_announcement') {
      queue.removeWhere(
        (candidate) =>
            candidate.kind == 'pairing_announcement' &&
            candidate.senderDeviceId == envelope.senderDeviceId,
      );
    }
    queue.add(envelope);
    return true;
  }

  @override
  Future<List<RelayEnvelope>> fetchEnvelopes({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    int limit = 64,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final queue = _queues[recipientDeviceId] ?? <RelayEnvelope>[];
    final result = queue.take(limit).toList();
    queue.removeWhere(
      (envelope) =>
          envelope.kind != 'pairing_announcement' && result.contains(envelope),
    );
    return result;
  }

  @override
  Future<bool> health({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    return !_containsRoute(_healthFailingHosts, host, port, protocol);
  }

  @override
  Future<RelayHealthInfo> inspectHealth({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final ok = await health(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
    );
    if (!ok) {
      throw StateError('Route unavailable for ${_key(host, port, protocol)}');
    }
    return RelayHealthInfo(
      ok: true,
      relayInstanceId: _relayIdFor(host, port, protocol),
    );
  }
}

class _HostScopedFakeRelayClient extends RelayClient {
  final Map<String, Map<String, List<RelayEnvelope>>> _queues =
      <String, Map<String, List<RelayEnvelope>>>{};

  String _key(String host, int port, PeerRouteProtocol protocol) =>
      '${protocol.name}://$host:$port';

  @override
  Future<bool> storeEnvelope({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    required RelayEnvelope envelope,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final hostQueues = _queues.putIfAbsent(
      _key(host, port, protocol),
      () => <String, List<RelayEnvelope>>{},
    );
    final queue = hostQueues.putIfAbsent(
      recipientDeviceId,
      () => <RelayEnvelope>[],
    );
    if (envelope.kind == 'pairing_announcement') {
      queue.removeWhere(
        (candidate) =>
            candidate.kind == 'pairing_announcement' &&
            candidate.senderDeviceId == envelope.senderDeviceId,
      );
    }
    queue.add(envelope);
    return true;
  }

  @override
  Future<List<RelayEnvelope>> fetchEnvelopes({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    int limit = 64,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final queue =
        _queues[_key(host, port, protocol)]?[recipientDeviceId] ??
        <RelayEnvelope>[];
    final result = queue.take(limit).toList();
    queue.removeWhere(
      (envelope) =>
          envelope.kind != 'pairing_announcement' && result.contains(envelope),
    );
    return result;
  }

  @override
  Future<bool> health({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    return _queues.containsKey(_key(host, port, protocol));
  }

  @override
  Future<RelayHealthInfo> inspectHealth({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final ok = await health(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
    );
    if (!ok) {
      throw StateError('Route unavailable for ${_key(host, port, protocol)}');
    }
    return RelayHealthInfo(ok: true, relayInstanceId: 'fake-relay-$host:$port');
  }
}

Future<MessengerController> _createController({
  required RelayClient relayClient,
  required String displayName,
  List<String> lanAddresses = const <String>['192.168.1.20'],
  String? internetRelayHost = 'relay.example',
}) async {
  final controller = MessengerController(
    vaultStore: _MemoryVaultStore(),
    relayClient: relayClient,
    localRelayNode: _FakeLocalRelayNode(),
    lanAddressProvider: () async => lanAddresses,
  );
  await controller.initialize();
  await controller.createIdentity(
    displayName: displayName,
    internetRelayHost: internetRelayHost,
    internetRelayPort: defaultRelayPort,
    localRelayPort: defaultRelayPort,
  );
  return controller;
}

ContactInvite _bobInvite() {
  return ContactInvite(
    version: 2,
    accountId: 'acc-bob',
    deviceId: 'dev-bob',
    displayName: 'Bob',
    bio: 'test peer',
    pairingNonce: 'bob-nonce',
    pairingEpochMs: 1760000000000,
    relayCapable: true,
    publicKeyBase64: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
    routeHints: const <PeerEndpoint>[
      PeerEndpoint(
        kind: PeerRouteKind.lan,
        host: '192.168.1.25',
        port: defaultRelayPort,
      ),
      PeerEndpoint(
        kind: PeerRouteKind.relay,
        host: 'relay.example',
        port: defaultRelayPort,
      ),
    ],
  );
}

void main() {
  test('payload alone adds a contact without a codephrase', () async {
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    final invite = _bobInvite();
    final result = await controller.addContactFromInvite(
      alias: 'Bob',
      payload: invite.encodePayload(),
      codephrase: '',
    );

    expect(controller.contacts.single.alias, 'Bob');
    expect(controller.contacts.single.deviceId, invite.deviceId);
    expect(result.exchangeStatus, ContactExchangeStatus.automatic);
  });

  test(
    'codephrase alone resolves a contact through the shared relay',
    () async {
      final relayClient = _FakeRelayClient();
      final sender = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final receiver = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
      );
      addTearDown(sender.dispose);
      addTearDown(receiver.dispose);

      final payload = (await sender.buildInvite()).encodePayload();
      final codephrase = currentPairingCodeSnapshotForPayload(
        payload,
      ).codephrase;
      final spacedCodephrase = codephrase.replaceAll('-', ' ');

      final result = await receiver.addContactFromInvite(
        alias: 'Alice',
        payload: '',
        codephrase: spacedCodephrase,
      );

      expect(receiver.contacts.single.deviceId, sender.identity!.deviceId);
      expect(receiver.contacts.single.alias, 'Alice');
      expect(result.exchangeStatus, ContactExchangeStatus.automatic);
    },
  );

  test(
    'codephrase resolution tolerates rotation while the other device pairs',
    () async {
      final relayClient = _FakeRelayClient();
      final sender = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final receiver = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
      );
      addTearDown(sender.dispose);
      addTearDown(receiver.dispose);

      final payload = (await sender.buildInvite()).encodePayload();
      final nextCodephrase = pairingCodephrasesForPayload(
        payload,
        slotOffsets: const <int>[1],
      ).single;

      final result = await receiver.addContactFromInvite(
        alias: 'Alice',
        payload: '',
        codephrase: nextCodephrase,
      );

      expect(receiver.contacts.single.deviceId, sender.identity!.deviceId);
      expect(result.exchangeStatus, ContactExchangeStatus.automatic);
    },
  );

  test(
    'relay-disabled peers still advertise direct routes for codephrase add',
    () async {
      final relayClient = _FakeRelayClient();
      final sender = await _createController(
        relayClient: relayClient,
        displayName: 'Android',
      );
      final receiver = await _createController(
        relayClient: relayClient,
        displayName: 'Windows',
      );
      addTearDown(sender.dispose);
      addTearDown(receiver.dispose);

      await sender.updateRelayModeEnabled(false);
      final invite = await sender.buildInvite();
      final payload = invite.encodePayload();
      final codephrase = currentPairingCodeSnapshotForPayload(
        payload,
      ).codephrase;

      expect(invite.relayCapable, isFalse);
      expect(
        invite.routeHints.any((route) => route.kind == PeerRouteKind.lan),
        isTrue,
      );

      final result = await receiver.addContactFromInvite(
        alias: '',
        payload: '',
        codephrase: codephrase,
      );

      expect(result.contact.deviceId, sender.identity!.deviceId);
      expect(result.contact.relayCapable, isFalse);
      expect(result.contact.routeHints, isNotEmpty);
    },
  );

  test('invite route hints stay compact across several networks', () async {
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      lanAddresses: const <String>['10.0.0.20', '172.16.0.20', '192.168.1.20'],
    );
    addTearDown(controller.dispose);

    final invite = await controller.buildInvite();
    final payload = invite.encodePayload();

    expect(invite.routeHints.length, lessThanOrEqualTo(4));
    expect(
      invite.routeHints.where((route) => route.kind == PeerRouteKind.lan),
      hasLength(2),
    );
    expect(
      invite.routeHints
          .where((route) => route.kind == PeerRouteKind.lan)
          .map((route) => route.host)
          .toSet(),
      {'192.168.1.20'},
    );
    expect(
      invite.routeHints.where((route) => route.kind == PeerRouteKind.relay),
      hasLength(lessThanOrEqualTo(2)),
    );
    expect(payload.length, lessThan(900));
    expect(payload, startsWith('ci5|'));
  });

  test(
    'pairing announcements can be fetched by more than one device',
    () async {
      final relayClient = _FakeRelayClient();
      final sender = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final receiverOne = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
      );
      final receiverTwo = await _createController(
        relayClient: relayClient,
        displayName: 'Dave',
      );
      addTearDown(sender.dispose);
      addTearDown(receiverOne.dispose);
      addTearDown(receiverTwo.dispose);

      final payload = (await sender.buildInvite()).encodePayload();
      final codephrase = currentPairingCodeSnapshotForPayload(
        payload,
      ).codephrase;

      final first = await receiverOne.addContactFromInvite(
        alias: 'Alice',
        payload: '',
        codephrase: codephrase,
      );
      final second = await receiverTwo.addContactFromInvite(
        alias: 'Alice',
        payload: '',
        codephrase: codephrase,
      );

      expect(first.contact.deviceId, sender.identity!.deviceId);
      expect(second.contact.deviceId, sender.identity!.deviceId);
    },
  );

  test(
    'codephrase LAN discovery uses cached beacon routes when subnet scan misses',
    () async {
      final relayClient = _HostScopedFakeRelayClient();
      final sender = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        lanAddresses: const <String>['192.168.50.22'],
        internetRelayHost: null,
      );
      final receiver = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
        lanAddresses: const <String>['10.10.10.7'],
        internetRelayHost: null,
      );
      addTearDown(sender.dispose);
      addTearDown(receiver.dispose);

      receiver.rememberPairingBeaconRouteForTesting(
        const PeerEndpoint(
          kind: PeerRouteKind.lan,
          host: '192.168.50.22',
          port: defaultRelayPort,
        ),
      );

      final payload = (await sender.buildInvite()).encodePayload();
      final codephrase = currentPairingCodeSnapshotForPayload(
        payload,
      ).codephrase;

      final result = await receiver.addContactFromInvite(
        alias: 'Alice',
        payload: '',
        codephrase: codephrase,
      );

      expect(result.contact.deviceId, sender.identity!.deviceId);
      expect(
        receiver.recentPairingBeaconRoutes.map((route) => route.host),
        contains('192.168.50.22'),
      );
    },
  );

  test('rotatePairingCodeNow changes the codephrase immediately', () async {
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    final firstPayload = (await controller.buildInvite()).encodePayload();
    final firstCode = currentPairingCodeSnapshotForPayload(
      firstPayload,
    ).codephrase;
    final secondPayload = (await controller.rotatePairingCodeNow())
        .encodePayload();
    final secondCode = currentPairingCodeSnapshotForPayload(
      secondPayload,
    ).codephrase;

    expect(secondPayload, isNot(firstPayload));
    expect(secondCode, isNot(firstCode));
  });

  test(
    'adding a contact auto-exchanges so the other side appears later',
    () async {
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);

      final result = await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );

      expect(result.exchangeStatus, ContactExchangeStatus.automatic);
      await bob.pollNow();
      expect(
        bob.contacts.any(
          (contact) => contact.deviceId == alice.identity!.deviceId,
        ),
        isTrue,
      );
    },
  );

  test(
    'checking paths exchanges refreshed route information both ways',
    () async {
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);

      await bob.addContactFromInvite(
        alias: 'Alice',
        payload: (await alice.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await alice.pollNow();

      await alice.updateLocalRelayPort(8777);
      expect(
        bob.contacts.single.routeHints.any((route) => route.port == 8777),
        isFalse,
      );

      await bob.checkContactRoutes(bob.contacts.single);
      await alice.pollNow();
      await bob.pollNow();

      expect(
        bob.contacts.single.routeHints.any((route) => route.port == 8777),
        isTrue,
      );
      expect(
        alice.contacts.single.routeHints.any(
          (route) => route.host == bob.identity!.lanAddresses.single,
        ),
        isTrue,
      );
    },
  );

  test('LAN lobby sends messages to nearby peers without contacts', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      lanAddresses: const <String>['192.168.1.20'],
      internetRelayHost: null,
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
      lanAddresses: const <String>['192.168.1.30'],
      internetRelayHost: null,
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    alice.rememberPairingBeaconRouteForTesting(
      const PeerEndpoint(
        kind: PeerRouteKind.lan,
        host: '192.168.1.30',
        port: defaultRelayPort,
      ),
    );

    final accepted = await alice.sendLanLobbyMessage('hello nearby');
    await bob.pollNow();

    expect(accepted, greaterThan(0));
    expect(alice.contacts, isEmpty);
    expect(bob.contacts, isEmpty);
    expect(alice.lanLobbyMessages.single.outbound, isTrue);
    expect(bob.lanLobbyMessages.single.outbound, isFalse);
    expect(bob.lanLobbyMessages.single.body, 'hello nearby');
    expect(bob.lanLobbyMessages.single.senderDisplayName, 'Alice');
    expect(bob.lanLobbyMessages.single.untrusted, isTrue);
  });

  test('removing a contact sends a reciprocal removal notice', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    expect(alice.contacts, hasLength(1));
    expect(bob.contacts, hasLength(1));

    await alice.removeContact(bob.identity!.deviceId);
    await bob.pollNow();

    expect(alice.contacts, isEmpty);
    expect(bob.contacts, isEmpty);
  });

  test(
    'contact profile bio can be stored and route checks are sorted',
    () async {
      final relayClient = _FakeRelayClient(
        failingHosts: <String>{'192.168.1.25:7667'},
      );
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      addTearDown(controller.dispose);

      await controller.addContactFromInvite(
        alias: 'Bob',
        payload: _bobInvite().encodePayload(),
        codephrase: '',
      );
      final contact = controller.contacts.single;
      expect(contact.bio, 'test peer');

      await controller.updateContactProfile(
        deviceId: contact.deviceId,
        alias: 'Bobby',
        bio: 'local profile note',
      );
      expect(controller.contacts.single.alias, 'Bobby');
      expect(controller.contacts.single.bio, 'local profile note');

      final checks = await controller.checkContactRoutes(
        controller.contacts.single,
      );
      expect(checks.first.route.kind, PeerRouteKind.relay);
      expect(checks.first.available, isTrue);
      expect(checks.last.route.kind, PeerRouteKind.lan);
      expect(checks.last.available, isFalse);
    },
  );

  test(
    'manual suggestion is returned when reciprocal exchange cannot be sent',
    () async {
      final relayClient = _FakeRelayClient(
        failingHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
      );
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      addTearDown(controller.dispose);

      final result = await controller.addContactFromInvite(
        alias: 'Bob',
        payload: _bobInvite().encodePayload(),
        codephrase: '',
      );

      expect(result.exchangeStatus, ContactExchangeStatus.manualActionRequired);
    },
  );

  test('sendMessage prefers LAN routes before relay routes', () async {
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    final invite = _bobInvite();
    final payload = invite.encodePayload();
    await controller.addContactFromInvite(
      alias: 'Bob',
      payload: payload,
      codephrase: currentPairingCodeSnapshotForPayload(payload).codephrase,
    );

    final contact = controller.contacts.single;
    relayClient.storeAttempts.clear();
    await controller.sendMessage(contact: contact, body: 'hello over LAN');

    expect(relayClient.storeAttempts, <String>['192.168.1.25:7667']);
    expect(
      controller.messagesFor(contact.deviceId).single.state,
      DeliveryState.local,
    );
  });

  test('sendMessage skips unavailable LAN and uses relay', () async {
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{'192.168.1.25:7667'},
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    final invite = _bobInvite();
    final payload = invite.encodePayload();
    await controller.addContactFromInvite(
      alias: 'Bob',
      payload: payload,
      codephrase: currentPairingCodeSnapshotForPayload(payload).codephrase,
    );

    final contact = controller.contacts.single;
    relayClient.storeAttempts.clear();
    await controller.sendMessage(contact: contact, body: 'hello via relay');

    expect(relayClient.storeAttempts, <String>['relay.example:7667']);
    expect(
      controller.messagesFor(contact.deviceId).single.state,
      DeliveryState.relayed,
    );
  });

  test(
    'sendMessage tries relay when direct store fails after health passes',
    () async {
      final relayClient = _FakeRelayClient(
        storeFailingHosts: <String>{'192.168.1.25:7667'},
      );
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      addTearDown(controller.dispose);

      final invite = _bobInvite();
      final payload = invite.encodePayload();
      await controller.addContactFromInvite(
        alias: 'Bob',
        payload: payload,
        codephrase: currentPairingCodeSnapshotForPayload(payload).codephrase,
      );

      final contact = controller.contacts.single;
      relayClient.storeAttempts.clear();
      await controller.sendMessage(contact: contact, body: 'direct then relay');

      expect(relayClient.storeAttempts, <String>[
        '192.168.1.25:7667',
        'relay.example:7667',
      ]);
      expect(
        controller.messagesFor(contact.deviceId).single.state,
        DeliveryState.relayed,
      );
    },
  );

  test(
    'sendMessage can use a faster configured alias for the same relay',
    () async {
      final relayClient = _FakeRelayClient(
        storeFailingHosts: <String>{'public.example:21639'},
        relayInstanceIds: const <String, String>{
          'public.example:21639': 'relay-shared',
          '192.168.3.9:7667': 'relay-shared',
        },
      );
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        internetRelayHost: null,
      );
      addTearDown(controller.dispose);
      await controller.addRelay(host: '192.168.3.9', port: defaultRelayPort);

      final invite = ContactInvite(
        version: 4,
        accountId: 'acc-bob',
        deviceId: 'dev-bob',
        displayName: 'Bob',
        bio: '',
        pairingNonce: 'bob-nonce',
        pairingEpochMs: 1760000000000,
        relayCapable: true,
        publicKeyBase64: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
        routeHints: const <PeerEndpoint>[
          PeerEndpoint(
            kind: PeerRouteKind.relay,
            host: 'public.example',
            port: 21639,
            protocol: PeerRouteProtocol.udp,
          ),
        ],
      );
      await controller.addContactFromInvite(
        alias: 'Bob',
        payload: invite.encodePayload(),
        codephrase: '',
      );

      final contact = controller.contacts.single;
      relayClient.storeAttempts.clear();
      await controller.sendMessage(contact: contact, body: 'same relay alias');

      expect(relayClient.storeAttempts, contains('192.168.3.9:7667'));
      expect(
        controller.messagesFor(contact.deviceId).single.state,
        DeliveryState.relayed,
      );
    },
  );

  test('sendMessage stays pending when every route is unavailable', () async {
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    final invite = _bobInvite();
    final payload = invite.encodePayload();
    await controller.addContactFromInvite(
      alias: 'Bob',
      payload: payload,
      codephrase: currentPairingCodeSnapshotForPayload(payload).codephrase,
    );

    final contact = controller.contacts.single;
    relayClient.storeAttempts.clear();
    await controller.sendMessage(contact: contact, body: 'queue this');

    expect(relayClient.storeAttempts, <String>[
      '192.168.1.25:7667',
      'relay.example:7667',
    ]);
    expect(
      controller.messagesFor(contact.deviceId).single.state,
      DeliveryState.pending,
    );
  });

  test('pending messages can be canceled before retry', () async {
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    final invite = _bobInvite();
    await controller.addContactFromInvite(
      alias: 'Bob',
      payload: invite.encodePayload(),
      codephrase: '',
    );
    final contact = controller.contacts.single;
    await controller.sendMessage(contact: contact, body: 'cancel this');
    final pending = controller.messagesFor(contact.deviceId).single;

    await controller.cancelPendingMessage(
      contact: contact,
      messageId: pending.id,
    );

    expect(controller.messagesFor(contact.deviceId), isEmpty);
    expect(controller.pendingOutboundCount, 0);
  });

  test('message edits update the remote copy', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final bobContactForAlice = bob.contacts.single;
    final aliceContactForBob = alice.contacts.single;

    await alice.sendMessage(contact: aliceContactForBob, body: 'original');
    await bob.pollNow();
    final sent = alice.messagesFor(aliceContactForBob.deviceId).single;

    await alice.editMessage(
      contact: aliceContactForBob,
      messageId: sent.id,
      body: 'edited',
    );
    await bob.pollNow();

    final received = bob.messagesFor(bobContactForAlice.deviceId).single;
    expect(received.body, 'edited');
    expect(received.isEdited, isTrue);
  });

  test('message delete removes local and remote sent copies', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final bobContactForAlice = bob.contacts.single;
    final aliceContactForBob = alice.contacts.single;

    await alice.sendMessage(contact: aliceContactForBob, body: 'remove me');
    await bob.pollNow();
    final sent = alice.messagesFor(aliceContactForBob.deviceId).single;
    expect(bob.messagesFor(bobContactForAlice.deviceId), hasLength(1));

    await alice.deleteMessage(contact: aliceContactForBob, messageId: sent.id);
    await bob.pollNow();

    expect(alice.messagesFor(aliceContactForBob.deviceId), isEmpty);
    expect(bob.messagesFor(bobContactForAlice.deviceId), isEmpty);
  });

  test('debug self test reports runnable checks', () async {
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    await controller.addContactFromInvite(
      alias: 'Bob',
      payload: _bobInvite().encodePayload(),
      codephrase: '',
    );

    final report = await controller.runDebugSelfTest();

    expect(report.deviceCount, 2);
    expect(report.results, isNotEmpty);
    expect(
      report.results.any(
        (result) =>
            result.name == 'Debug build gate' &&
            result.status == DebugCheckStatus.pass,
      ),
      isTrue,
    );
    expect(
      report.results.any(
        (result) =>
            result.name == 'Relay store/fetch loopback' &&
            result.status == DebugCheckStatus.pass,
      ),
      isTrue,
    );
    expect(
      report.results.any(
        (result) =>
            result.name == 'Route protocol coverage' &&
            result.status == DebugCheckStatus.pass,
      ),
      isTrue,
    );
    expect(
      report.results.any(
        (result) =>
            result.name == 'Relay alias grouping' &&
            result.status == DebugCheckStatus.pass,
      ),
      isTrue,
    );
    expect(
      report.results.any(
        (result) =>
            result.name == 'Relay pairing announcement reuse' &&
            result.status == DebugCheckStatus.pass,
      ),
      isTrue,
    );
  });

  test(
    'debug self test can verify two-way debug messaging after peer poll',
    () async {
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();

      await alice.runDebugSelfTest();
      await bob.pollNow();
      await alice.pollNow();
      final report = await alice.runDebugSelfTest();

      expect(
        report.results.any(
          (result) =>
              result.name == 'Two-way debug replies' &&
              result.status == DebugCheckStatus.pass,
        ),
        isTrue,
      );
    },
  );

  test('relay settings update and reset clears identity state', () async {
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    await controller.addRelay(host: 'backup.example', port: 9000);
    expect(
      controller.configuredRelays.any(
        (route) => route.host == 'backup.example' && route.port == 9000,
      ),
      isTrue,
    );

    expect(controller.identity!.autoUseContactRelays, isTrue);

    await controller.updateAutoUseContactRelays(false);
    expect(controller.identity!.autoUseContactRelays, isFalse);

    await controller.updateAutoUseContactRelays(true);
    expect(controller.identity!.autoUseContactRelays, isTrue);

    await controller.updateRelayModeEnabled(false);
    expect(controller.identity!.relayModeEnabled, isFalse);
    expect(controller.localRelayRunning, isTrue);

    await controller.resetIdentity();
    expect(controller.hasIdentity, isFalse);
    expect(controller.contacts, isEmpty);
  });

  test('addRelay auto-detects UDP-only bare relay hosts', () async {
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{
        'tcp://playit.example:21639',
        'http://playit.example:21639',
        'https://playit.example:21639',
      },
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      internetRelayHost: null,
    );
    addTearDown(controller.dispose);

    await controller.addRelay(host: 'playit.example:21639', port: 7667);

    final detected = controller.configuredRelays
        .where((route) => route.host == 'playit.example')
        .toList(growable: false);
    expect(detected, hasLength(1));
    expect(detected.single.port, 21639);
    expect(detected.single.protocol, PeerRouteProtocol.udp);

    final report = await controller.runDebugSelfTest();
    expect(
      report.results.any(
        (result) =>
            result.name == 'Route protocol coverage' &&
            result.status == DebugCheckStatus.pass &&
            result.detail.contains('playit.example:21639=udp'),
      ),
      isTrue,
    );
  });

  test('addRelay explicit protocol can be forced without detection', () async {
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{'udp://playit.example:21639'},
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      internetRelayHost: null,
    );
    addTearDown(controller.dispose);

    await controller.addRelay(host: 'udp://playit.example:21639', port: 7667);

    final forced = controller.configuredRelays.singleWhere(
      (route) => route.host == 'playit.example',
    );
    expect(forced.port, 21639);
    expect(forced.protocol, PeerRouteProtocol.udp);
  });

  test(
    'relay availability rediscovers a newly working sibling protocol',
    () async {
      final relayClient = _FakeRelayClient();
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        internetRelayHost: null,
      );
      addTearDown(controller.dispose);

      await controller.addRelay(host: 'udp://playit.example:21639', port: 7667);
      expect(
        controller.configuredRelays
            .where((route) => route.host == 'playit.example')
            .map((route) => route.protocol)
            .toList(),
        <PeerRouteProtocol>[PeerRouteProtocol.udp],
      );

      await controller.checkRelayAvailability();

      final protocols = controller.configuredRelays
          .where((route) => route.host == 'playit.example')
          .map((route) => route.protocol)
          .toSet();
      expect(protocols, {
        PeerRouteProtocol.tcp,
        PeerRouteProtocol.udp,
        PeerRouteProtocol.http,
        PeerRouteProtocol.https,
      });
    },
  );

  test('relay protocol health is tracked independently per endpoint', () async {
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{
        'tcp://playit.example:21639',
        'http://playit.example:21639',
        'https://playit.example:21639',
      },
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      internetRelayHost: null,
    );
    addTearDown(controller.dispose);

    await controller.addRelay(host: 'tcp://playit.example:21639', port: 7667);
    await controller.addRelay(host: 'udp://playit.example:21639', port: 7667);
    await controller.checkRelayAvailability();

    final tcp = const PeerEndpoint(
      kind: PeerRouteKind.relay,
      host: 'playit.example',
      port: 21639,
    );
    final udp = const PeerEndpoint(
      kind: PeerRouteKind.relay,
      host: 'playit.example',
      port: 21639,
      protocol: PeerRouteProtocol.udp,
    );
    expect(controller.routeHealthFor(tcp)?.available, isFalse);
    expect(controller.routeHealthFor(udp)?.available, isTrue);
  });

  test('addRelay accepts HTTPS tunnel URLs with default port', () async {
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{
        'tcp://silver-ghosts-jog.loca.lt:443',
        'udp://silver-ghosts-jog.loca.lt:443',
        'http://silver-ghosts-jog.loca.lt:443',
      },
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      internetRelayHost: null,
    );
    addTearDown(controller.dispose);

    await controller.addRelay(
      host: 'https://silver-ghosts-jog.loca.lt',
      port: 7667,
    );

    final detected = controller.configuredRelays.singleWhere(
      (route) => route.host == 'silver-ghosts-jog.loca.lt',
    );
    expect(detected.port, 443);
    expect(detected.protocol, PeerRouteProtocol.https);
  });
}
