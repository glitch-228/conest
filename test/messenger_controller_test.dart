import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/main.dart' as app;
import 'package:conest/src/build_info.dart';
import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/messenger_controller.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/relay_client.dart';
import 'package:conest/src/storage.dart';
import 'package:conest/src/update_service.dart';

class _MemoryVaultStore extends VaultStore {
  VaultSnapshot _snapshot = VaultSnapshot.empty();
  int saveCount = 0;

  @override
  Future<VaultSnapshot> load() async => _snapshot;

  @override
  Future<void> save(VaultSnapshot snapshot) async {
    saveCount++;
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
    Set<String>? allowedHosts,
    Set<String>? storeAllowedHosts,
    Map<String, String>? relayInstanceIds,
    bool Function(
      String host,
      int port,
      PeerRouteProtocol protocol,
      String recipientDeviceId,
      RelayEnvelope envelope,
    )?
    shouldBlackholeStore,
  }) : _healthFailingHosts = failingHosts ?? <String>{},
       _storeFailingHosts = storeFailingHosts ?? failingHosts ?? <String>{},
       _allowedHosts = allowedHosts,
       _storeAllowedHosts = storeAllowedHosts ?? allowedHosts,
       _relayInstanceIds = relayInstanceIds ?? const <String, String>{},
       _shouldBlackholeStore = shouldBlackholeStore;

  final Set<String> _healthFailingHosts;
  final Set<String> _storeFailingHosts;
  final Set<String>? _allowedHosts;
  final Set<String>? _storeAllowedHosts;
  final Map<String, String> _relayInstanceIds;
  final bool Function(
    String host,
    int port,
    PeerRouteProtocol protocol,
    String recipientDeviceId,
    RelayEnvelope envelope,
  )?
  _shouldBlackholeStore;
  final List<String> storeAttempts = <String>[];
  final List<String> fetchAttempts = <String>[];
  final List<String> inspectHealthAttempts = <String>[];
  final List<RelayEnvelope> storedEnvelopes = <RelayEnvelope>[];
  final Map<String, List<RelayEnvelope>> _queues =
      <String, List<RelayEnvelope>>{};

  String _key(String host, int port, PeerRouteProtocol protocol) =>
      '${protocol.name}://$host:$port';
  bool _isRouteAllowed(
    Set<String>? values,
    String host,
    int port,
    PeerRouteProtocol protocol,
  ) {
    if (values == null || values.isEmpty) {
      return true;
    }
    return _containsRoute(values, host, port, protocol);
  }

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
    if (!_isRouteAllowed(_storeAllowedHosts, host, port, protocol)) {
      throw StateError('Route unavailable for $key');
    }
    if (_containsRoute(_storeFailingHosts, host, port, protocol)) {
      throw StateError('Route unavailable for $key');
    }
    if (_shouldBlackholeStore?.call(
          host,
          port,
          protocol,
          recipientDeviceId,
          envelope,
        ) ??
        false) {
      storedEnvelopes.add(envelope);
      return true;
    }
    storedEnvelopes.add(envelope);
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
    fetchAttempts.add('$host:$port');
    if (!_isRouteAllowed(_storeAllowedHosts, host, port, protocol)) {
      throw StateError('Route unavailable for ${_key(host, port, protocol)}');
    }
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
    return _isRouteAllowed(_allowedHosts, host, port, protocol) &&
        !_containsRoute(_healthFailingHosts, host, port, protocol);
  }

  @override
  Future<RelayHealthInfo> inspectHealth({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    inspectHealthAttempts.add('$host:$port');
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

UpdateService _createUpdateService() {
  return UpdateService(
    buildInfo: ConestBuildInfo(
      appName: 'Conest',
      packageName: 'dev.conest.conest',
      version: '0.1.0',
      buildNumber: '1',
      channel: UpdateChannel.nightly,
      isDebugBuild: true,
    ),
    targetPlatform: UpdateTargetPlatform.unsupported,
    applicationSupportDirectoryProvider: () async => Directory.systemTemp,
    tempDirectoryProvider: () async => Directory.systemTemp,
    exitCallback: (_) {},
  );
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
  DateTime Function()? nowProvider,
}) async {
  final controller = MessengerController(
    vaultStore: _MemoryVaultStore(),
    relayClient: relayClient,
    localRelayNode: _FakeLocalRelayNode(),
    lanAddressProvider: () async => lanAddresses,
    nowProvider: nowProvider,
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

  test('hotspot gateway addresses are treated as LAN discovery addresses', () {
    expect(isLanDiscoveryAddress('172.20.10.1'), isTrue);
    expect(isLanDiscoveryAddress('192.168.43.1'), isTrue);
    expect(isIgnoredLanInterfaceName('wlan0'), isFalse);
    expect(isIgnoredLanInterfaceName('docker0'), isTrue);
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

  test(
    'checking paths and sendMessage rediscover a hotspot-host LAN peer',
    () async {
      final relayClient = _FakeRelayClient(
        allowedHosts: <String>{'172.20.10.1:7667'},
      );
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Client',
        lanAddresses: const <String>['172.20.10.2'],
        internetRelayHost: null,
      );
      addTearDown(controller.dispose);

      final staleInvite = ContactInvite(
        version: 4,
        accountId: 'acc-hotspot',
        deviceId: 'dev-hotspot',
        displayName: 'Hotspot host',
        bio: 'mobile hotspot',
        pairingNonce: 'hotspot-nonce',
        pairingEpochMs: 1760000000000,
        relayCapable: false,
        publicKeyBase64: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
        routeHints: const <PeerEndpoint>[
          PeerEndpoint(
            kind: PeerRouteKind.lan,
            host: '172.20.10.9',
            port: defaultRelayPort,
          ),
        ],
      );
      await controller.addContactFromInvite(
        alias: 'Hotspot host',
        payload: staleInvite.encodePayload(),
        codephrase: '',
      );

      var contact = controller.contacts.single;
      final checks = await controller.checkContactRoutes(
        contact,
        persist: false,
        exchangeRouteUpdate: false,
        fast: true,
      );

      expect(
        checks.any(
          (check) => check.available && check.route.host == '172.20.10.1',
        ),
        isTrue,
      );
      contact = controller.contacts.single;
      expect(
        contact.routeHints.any((route) => route.host == '172.20.10.1'),
        isTrue,
      );

      relayClient.storeAttempts.clear();
      await controller.sendMessage(
        contact: contact,
        body: 'hello hotspot host',
      );

      expect(relayClient.storeAttempts, contains('172.20.10.1:7667'));
      expect(
        controller.messagesFor(contact.deviceId).single.state,
        DeliveryState.local,
      );
    },
  );

  test('path rediscovery keeps same-subnet route expansion bounded', () async {
    final relayClient = _FakeRelayClient(
      allowedHosts: <String>{'192.168.3.245:7667', 'relay.example:7667'},
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      lanAddresses: const <String>['192.168.3.9'],
    );
    addTearDown(controller.dispose);

    final invite = ContactInvite(
      version: 4,
      accountId: 'acc-bob',
      deviceId: 'dev-bob',
      displayName: 'Bob',
      bio: 'same subnet peer',
      pairingNonce: 'bob-nonce',
      pairingEpochMs: 1760000000000,
      relayCapable: true,
      publicKeyBase64: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
      routeHints: const <PeerEndpoint>[
        PeerEndpoint(
          kind: PeerRouteKind.lan,
          host: '192.168.3.245',
          port: defaultRelayPort,
        ),
        PeerEndpoint(
          kind: PeerRouteKind.relay,
          host: 'relay.example',
          port: defaultRelayPort,
        ),
      ],
    );
    await controller.addContactFromInvite(
      alias: 'Bob',
      payload: invite.encodePayload(),
      codephrase: '',
    );

    final checks = await controller.checkContactRoutes(
      controller.contacts.single,
      persist: false,
      exchangeRouteUpdate: false,
      fast: true,
    );

    expect(checks.length, lessThanOrEqualTo(13));
    expect(checks.first.route.host, '192.168.3.245');
    expect(controller.contacts.single.routeHints.length, lessThanOrEqualTo(10));
  });

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
        allowedHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
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
        allowedHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
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
    final relayClient = _FakeRelayClient(
      allowedHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
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
    await controller.sendMessage(contact: contact, body: 'hello over LAN');

    expect(relayClient.storeAttempts, <String>['192.168.1.25:7667']);
    expect(
      controller.messagesFor(contact.deviceId).single.state,
      DeliveryState.local,
    );
  });

  test('sendMessage skips unavailable LAN and uses relay', () async {
    final relayClient = _FakeRelayClient(
      allowedHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
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
    'sendMessage keeps using relay while a failed LAN route is still backed off',
    () async {
      final relayClient = _FakeRelayClient(
        allowedHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
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

      expect(relayClient.storeAttempts, <String>['relay.example:7667']);
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
      allowedHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
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

    expect(relayClient.storeAttempts, isEmpty);
    expect(
      controller.messagesFor(contact.deviceId).single.state,
      DeliveryState.pending,
    );
  });

  test(
    'failed route backoff expires and delivery retries the LAN path',
    () async {
      var now = DateTime.utc(2026, 4, 21, 9);
      final relayClient = _FakeRelayClient(
        allowedHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
        storeFailingHosts: <String>{'192.168.1.25:7667'},
      );
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        nowProvider: () => now,
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
      await controller.sendMessage(contact: contact, body: 'after-backoff');
      expect(relayClient.storeAttempts, <String>['relay.example:7667']);

      now = now.add(const Duration(seconds: 6));
      relayClient.storeAttempts.clear();
      await controller.sendMessage(contact: contact, body: 'lan-again');

      expect(relayClient.storeAttempts.first, '192.168.1.25:7667');
    },
  );

  test('pending messages can be canceled before retry', () async {
    final relayClient = _FakeRelayClient(
      allowedHosts: <String>{'192.168.1.25:7667', 'relay.example:7667'},
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

  test(
    'unacknowledged messages retry and duplicate receives replay the ack',
    () async {
      var blackholedAckCount = 0;
      final relayClient = _FakeRelayClient(
        shouldBlackholeStore:
            (host, port, protocol, recipientDeviceId, envelope) {
              final routeKey =
                  '$host:$port:${protocol.name}:$recipientDeviceId';
              if (routeKey.isEmpty) {
                return false;
              }
              if (envelope.kind == 'ack' && blackholedAckCount == 0) {
                blackholedAckCount++;
                return true;
              }
              return false;
            },
      );
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final bobContactForAlice = bob.contacts.single;
      final aliceContactForBob = alice.contacts.single;

      await alice.sendMessage(contact: aliceContactForBob, body: 'hello');
      await bob.pollNow();

      expect(bob.messagesFor(bobContactForAlice.deviceId), hasLength(1));
      expect(
        alice.messagesFor(aliceContactForBob.deviceId).single.state,
        DeliveryState.local,
      );

      await alice.retryUnacknowledgedMessagesNow();
      await bob.pollNow();
      await alice.pollNow();

      expect(
        alice.messagesFor(aliceContactForBob.deviceId).single.state,
        DeliveryState.delivered,
      );
      expect(blackholedAckCount, 1);
    },
  );

  test(
    'receiving an inbound message without a returned ack only marks seen recently',
    () async {
      var blackholedAckCount = 0;
      final relayClient = _FakeRelayClient(
        shouldBlackholeStore:
            (host, port, protocol, recipientDeviceId, envelope) {
              if (envelope.kind == 'ack' && blackholedAckCount == 0) {
                blackholedAckCount++;
                return true;
              }
              return false;
            },
      );
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

      await alice.sendMessage(contact: alice.contacts.single, body: 'hello');
      await bob.pollNow();

      expect(
        bob.reachabilityStateFor(bobContactForAlice.deviceId),
        ContactReachabilityState.seenRecently,
      );
      expect(
        bob
            .reachabilityRecordFor(bobContactForAlice.deviceId)
            ?.lastTwoWaySuccessAt,
        isNull,
      );
      expect(
        bob.reachabilityRecordFor(bobContactForAlice.deviceId)?.lastAnySignalAt,
        isNotNull,
      );
      expect(blackholedAckCount, 1);
    },
  );

  test('heartbeat round-trip marks a contact online', () async {
    var now = DateTime.utc(2026, 4, 18, 12);
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      nowProvider: () => now,
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
      nowProvider: () => now,
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final aliceContactForBob = alice.contacts.single;

    await alice.runHeartbeatPassNow();
    await bob.pollNow();
    await alice.pollNow();

    expect(
      alice.reachabilityStateFor(aliceContactForBob.deviceId),
      ContactReachabilityState.online,
    );
    final record = alice.reachabilityRecordFor(aliceContactForBob.deviceId);
    expect(record?.lastHeartbeatAttemptAt, isNotNull);
    expect(record?.lastHeartbeatReplyAt, isNotNull);
  });

  test('outbound ack marks a contact online', () async {
    var now = DateTime.utc(2026, 4, 18, 13);
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      nowProvider: () => now,
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
      nowProvider: () => now,
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final aliceContactForBob = alice.contacts.single;

    await alice.sendMessage(contact: aliceContactForBob, body: 'ping');
    await bob.pollNow();
    await alice.pollNow();

    expect(
      alice.reachabilityStateFor(aliceContactForBob.deviceId),
      ContactReachabilityState.online,
    );
  });

  test(
    'reachability decays from online to seen recently to known to unknown',
    () async {
      var now = DateTime.utc(2026, 4, 18, 14);
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        nowProvider: () => now,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        nowProvider: () => now,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final aliceContactForBob = alice.contacts.single;

      await alice.sendMessage(contact: aliceContactForBob, body: 'fresh');
      await bob.pollNow();
      await alice.pollNow();

      expect(
        alice.reachabilityStateFor(aliceContactForBob.deviceId),
        ContactReachabilityState.online,
      );

      now = now.add(const Duration(minutes: 3));
      expect(
        alice.reachabilityStateFor(aliceContactForBob.deviceId),
        ContactReachabilityState.seenRecently,
      );

      now = now.add(const Duration(minutes: 8));
      expect(
        alice.reachabilityStateFor(aliceContactForBob.deviceId),
        ContactReachabilityState.known,
      );

      now = now.add(const Duration(hours: 24, minutes: 1));
      expect(
        alice.reachabilityStateFor(aliceContactForBob.deviceId),
        ContactReachabilityState.unknown,
      );
    },
  );

  test('checking paths upgrades an unknown contact to seen recently', () async {
    var now = DateTime.utc(2026, 4, 18, 15);
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      nowProvider: () => now,
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
      nowProvider: () => now,
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final aliceContactForBob = alice.contacts.single;

    await alice.sendMessage(contact: aliceContactForBob, body: 'hello');
    await bob.pollNow();
    await alice.pollNow();
    now = now.add(const Duration(hours: 24, minutes: 1));

    expect(
      alice.reachabilityStateFor(aliceContactForBob.deviceId),
      ContactReachabilityState.unknown,
    );

    await alice.checkContactRoutes(
      aliceContactForBob,
      persist: false,
      exchangeRouteUpdate: false,
      fast: true,
    );

    expect(
      alice.reachabilityStateFor(aliceContactForBob.deviceId),
      ContactReachabilityState.seenRecently,
    );
  });

  test(
    'heartbeat failure does not falsely mark a known contact online',
    () async {
      var now = DateTime.utc(2026, 4, 18, 16);
      final failingRoutes = <String>{};
      final relayClient = _FakeRelayClient(
        failingHosts: failingRoutes,
        storeFailingHosts: failingRoutes,
      );
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        nowProvider: () => now,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        nowProvider: () => now,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final aliceContactForBob = alice.contacts.single;

      await alice.sendMessage(contact: aliceContactForBob, body: 'known');
      await bob.pollNow();
      await alice.pollNow();
      now = now.add(const Duration(hours: 1));

      failingRoutes.addAll(<String>{'192.168.1.25:7667', 'relay.example:7667'});
      await alice.runHeartbeatPassNow();

      expect(
        alice.reachabilityStateFor(aliceContactForBob.deviceId),
        ContactReachabilityState.seenRecently,
      );
      expect(
        alice
            .reachabilityRecordFor(aliceContactForBob.deviceId)
            ?.lastHeartbeatAttemptAt,
        isNotNull,
      );
      expect(
        alice
            .reachabilityRecordFor(aliceContactForBob.deviceId)
            ?.lastHeartbeatReplyAt,
        isNull,
      );
    },
  );

  test(
    'heartbeat pass skips contacts with very recent two-way traffic',
    () async {
      var now = DateTime.utc(2026, 4, 18, 17);
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        nowProvider: () => now,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        nowProvider: () => now,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final aliceContactForBob = alice.contacts.single;

      await alice.sendMessage(contact: aliceContactForBob, body: 'fresh');
      await bob.pollNow();
      await alice.pollNow();

      relayClient.storedEnvelopes.clear();
      await alice.pollNow();

      expect(
        relayClient.storedEnvelopes.where((envelope) {
          if (envelope.kind != 'route_update' ||
              envelope.recipientDeviceId != aliceContactForBob.deviceId ||
              envelope.payloadBase64 == null) {
            return false;
          }
          final payload = String.fromCharCodes(
            base64Decode(envelope.payloadBase64!),
          );
          return payload.contains('"reason":"heartbeat"');
        }),
        isEmpty,
      );
    },
  );

  test(
    'legacy direct-message payload still decodes as a normal message',
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

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final bobContactForAlice = bob.contacts.single;
      final aliceContactForBob = alice.contacts.single;

      await alice.sendMessage(contact: aliceContactForBob, body: 'legacy body');
      await bob.pollNow();

      final received = bob.messagesFor(bobContactForAlice.deviceId).single;
      expect(received.body, 'legacy body');
      expect(received.replyToMessageId, isNull);
      expect(received.replySnippet, isNull);
    },
  );

  test('reply-capable direct messages preserve quoted metadata', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final bobContactForAlice = bob.contacts.single;
    final aliceContactForBob = alice.contacts.single;

    await bob.sendMessage(contact: bobContactForAlice, body: 'original line');
    await alice.pollNow();
    final inboundOriginal = alice
        .messagesFor(aliceContactForBob.deviceId)
        .single;

    await alice.sendMessage(
      contact: aliceContactForBob,
      body: 'reply line',
      replyTo: inboundOriginal,
    );
    await bob.pollNow();

    final receivedReply = bob.messagesFor(bobContactForAlice.deviceId).last;
    expect(receivedReply.body, 'reply line');
    expect(receivedReply.replyToMessageId, inboundOriginal.id);
    expect(receivedReply.replySenderDeviceId, bob.identity!.deviceId);
    expect(receivedReply.replySnippet, 'original line');
    expect(receivedReply.hasReplyPreview, isTrue);
  });

  test(
    'incoming messages stay unread until the conversation is marked read',
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

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final bobContactForAlice = bob.contacts.single;
      final aliceContactForBob = alice.contacts.single;

      await bob.sendMessage(contact: bobContactForAlice, body: 'unread text');
      await alice.pollNow();

      expect(alice.unreadCountFor(aliceContactForBob.deviceId), 1);
      expect(
        alice.isUnreadMessage(
          aliceContactForBob.deviceId,
          alice.messagesFor(aliceContactForBob.deviceId).single,
        ),
        isTrue,
      );

      await alice.markConversationRead(aliceContactForBob.deviceId);

      expect(alice.unreadCountFor(aliceContactForBob.deviceId), 0);
      expect(
        alice.isUnreadMessage(
          aliceContactForBob.deviceId,
          alice.messagesFor(aliceContactForBob.deviceId).single,
        ),
        isFalse,
      );
    },
  );

  test(
    'markConversationReadThroughMessage only clears unread messages through the visible cutoff',
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

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final bobContactForAlice = bob.contacts.single;
      final aliceContactForBob = alice.contacts.single;

      await bob.sendMessage(contact: bobContactForAlice, body: 'one');
      await bob.sendMessage(contact: bobContactForAlice, body: 'two');
      await bob.sendMessage(contact: bobContactForAlice, body: 'three');
      await alice.pollNow();
      await bob.pollNow();

      final aliceMessages = alice.messagesFor(aliceContactForBob.deviceId);
      expect(alice.unreadCountFor(aliceContactForBob.deviceId), 3);

      await alice.markConversationReadThroughMessage(
        aliceContactForBob.deviceId,
        aliceMessages[1],
      );

      expect(alice.unreadCountFor(aliceContactForBob.deviceId), 1);
      expect(
        alice.isUnreadMessage(aliceContactForBob.deviceId, aliceMessages[0]),
        isFalse,
      );
      expect(
        alice.isUnreadMessage(aliceContactForBob.deviceId, aliceMessages[1]),
        isFalse,
      );
      expect(
        alice.isUnreadMessage(aliceContactForBob.deviceId, aliceMessages[2]),
        isTrue,
      );
    },
  );

  test('read receipts upgrade delivered outbound messages to read', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final bobContactForAlice = bob.contacts.single;
    final aliceContactForBob = alice.contacts.single;

    await alice.sendMessage(contact: aliceContactForBob, body: 'first');
    await alice.sendMessage(contact: aliceContactForBob, body: 'second');
    await bob.pollNow();
    await alice.pollNow();

    var aliceMessages = alice.messagesFor(aliceContactForBob.deviceId);
    expect(aliceMessages[0].state, DeliveryState.delivered);
    expect(aliceMessages[1].state, DeliveryState.delivered);

    final bobMessages = bob.messagesFor(bobContactForAlice.deviceId);
    await bob.markConversationReadThroughMessage(
      bobContactForAlice.deviceId,
      bobMessages.last,
    );
    await alice.pollNow();

    aliceMessages = alice.messagesFor(aliceContactForBob.deviceId);
    expect(aliceMessages[0].state, DeliveryState.read);
    expect(aliceMessages[1].state, DeliveryState.read);
  });

  test(
    "debug suppress-read-receipts toggle keeps sending only delivery acknowledgements",
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

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final bobContactForAlice = bob.contacts.single;
      final aliceContactForBob = alice.contacts.single;

      await bob.updateSuppressReadReceipts(true);

      await alice.sendMessage(contact: aliceContactForBob, body: 'no read');
      await bob.pollNow();
      await alice.pollNow();

      var aliceMessage = alice.messagesFor(aliceContactForBob.deviceId).single;
      expect(aliceMessage.state, DeliveryState.delivered);

      final bobMessage = bob.messagesFor(bobContactForAlice.deviceId).single;
      await bob.markConversationReadThroughMessage(
        bobContactForAlice.deviceId,
        bobMessage,
      );
      await alice.pollNow();

      aliceMessage = alice.messagesFor(aliceContactForBob.deviceId).single;
      expect(aliceMessage.state, DeliveryState.delivered);
    },
  );

  testWidgets(
    'double tap incoming message opens reply preview and can cancel',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final bobContactForAlice = bob.contacts.single;
      await bob.sendMessage(contact: bobContactForAlice, body: 'incoming text');
      await alice.pollNow();

      await tester.pumpWidget(
        MaterialApp(
          home: app.HomeScreen(
            controller: alice,
            updateService: _createUpdateService(),
            palette: app.ConestPalette(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.ensureVisible(find.text('Bob').first);
      await tester.tap(find.text('Bob').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('incoming text').last);
      await tester.tap(find.text('incoming text').last);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('incoming text').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Replying to Bob'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Replying to Bob'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      alice.dispose();
      bob.dispose();
      await tester.pump();
    },
    skip: true,
  );

  testWidgets('double tap outgoing message opens the edit dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final aliceContactForBob = alice.contacts.single;
    await alice.sendMessage(contact: aliceContactForBob, body: 'outgoing text');
    await bob.pollNow();
    await alice.pollNow();

    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: _createUpdateService(),
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.ensureVisible(find.text('Bob').first);
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('outgoing text').last);
    await tester.tap(find.text('outgoing text').last);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('outgoing text').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Edit message'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    alice.dispose();
    bob.dispose();
    await tester.pump();
  }, skip: true);

  testWidgets('message bubbles support selection and copy message actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final relayClient = _FakeRelayClient();
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final arguments = call.arguments;
            if (arguments is Map) {
              copiedText = arguments['text'] as String?;
            }
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final aliceContactForBob = alice.contacts.single;
    await alice.sendMessage(
      contact: aliceContactForBob,
      body: 'copyable outgoing text',
    );
    await bob.pollNow();
    await alice.pollNow();

    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: _createUpdateService(),
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.ensureVisible(find.text('Bob').first);
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('copyable outgoing text').last);

    expect(
      find.ancestor(
        of: find.text('copyable outgoing text').last,
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );

    final popupFinder = find.byWidgetPredicate(
      (widget) => widget is PopupMenuButton<String>,
    );
    final popupState = tester.state<PopupMenuButtonState<String>>(
      popupFinder.last,
    );
    popupState.showButtonMenu();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Copy message'), findsOneWidget);
    await tester.tap(find.text('Copy message'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(copiedText, 'copyable outgoing text');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    alice.dispose();
    bob.dispose();
    await tester.pump();
  }, skip: true);

  testWidgets(
    'contact list and chat header show the current reachability chip',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 4, 18, 18);
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        nowProvider: () => now,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        nowProvider: () => now,
      );

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      final aliceContactForBob = alice.contacts.single;

      await alice.sendMessage(
        contact: aliceContactForBob,
        body: 'reachability',
      );
      await bob.pollNow();
      await alice.pollNow();

      expect(
        alice.reachabilityStateFor(aliceContactForBob.deviceId),
        ContactReachabilityState.online,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: app.HomeScreen(
            controller: alice,
            updateService: _createUpdateService(),
            palette: app.ConestPalette(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('online'), findsWidgets);

      await tester.ensureVisible(find.text('Bob').first);
      await tester.tap(find.text('Bob').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('online'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      alice.dispose();
      bob.dispose();
      await tester.pump();
    },
    skip: true,
  );

  testWidgets('sidebar unread badge clears after opening a conversation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final bobContactForAlice = bob.contacts.single;
    final aliceContactForBob = alice.contacts.single;
    await bob.sendMessage(contact: bobContactForAlice, body: 'fresh unread');
    await alice.pollNow();

    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: _createUpdateService(),
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(alice.unreadCountFor(aliceContactForBob.deviceId), 1);
    expect(find.text('fresh unread'), findsOneWidget);
    expect(find.byKey(const Key('unread-badge-1')), findsOneWidget);

    await tester.ensureVisible(find.text('Bob').first);
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(alice.unreadCountFor(aliceContactForBob.deviceId), 0);
    expect(find.byKey(const Key('unread-badge-1')), findsNothing);
    expect(find.text('new'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    alice.dispose();
    bob.dispose();
    await tester.pump();
  }, skip: true);

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
            result.name == 'Background heartbeat policy' &&
            result.status == DebugCheckStatus.pass,
      ),
      isTrue,
    );
    expect(
      report.results.any(
        (result) =>
            result.name == 'Auto contact relays' &&
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
              result.name == 'Heartbeat exchange' &&
              result.status == DebugCheckStatus.pass,
        ),
        isTrue,
      );
      expect(
        report.results.any(
          (result) =>
              result.name == 'Delivery path coverage' &&
              result.status == DebugCheckStatus.pass,
        ),
        isTrue,
      );
      expect(
        report.results.any(
          (result) =>
              result.name == 'Two-way debug replies' &&
              result.status == DebugCheckStatus.pass,
        ),
        isTrue,
      );
      expect(report.peerReports, hasLength(1));
      expect(report.peerReports.single.alias, 'Bob');
      expect(report.peerReports.single.probeAcknowledged, isTrue);
      expect(report.peerReports.single.twoWayReplyReceived, isTrue);
      expect(report.notes, isNotEmpty);
    },
  );

  test(
    'debug self test waits for all peer acknowledgements and replies',
    () async {
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        lanAddresses: const <String>['192.168.1.21'],
      );
      final carol = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
        lanAddresses: const <String>['192.168.1.22'],
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await alice.addContactFromInvite(
        alias: 'Carol',
        payload: (await carol.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await bob.pollNow();
      await carol.pollNow();

      final delayedPeerPolls = Future<void>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        await bob.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        await carol.pollNow();
      });

      final report = await alice.runDebugSelfTest();
      await delayedPeerPolls;

      expect(report.peerReports, hasLength(2));
      expect(
        report.peerReports.every(
          (peer) => peer.probeAcknowledged && peer.twoWayReplyReceived,
        ),
        isTrue,
      );
      expect(
        report.results.any(
          (result) =>
              result.name == 'Debug probe acknowledgements' &&
              result.status == DebugCheckStatus.pass &&
              result.detail.contains('2/2'),
        ),
        isTrue,
      );
      expect(
        report.results.any(
          (result) =>
              result.name == 'Two-way debug replies' &&
              result.status == DebugCheckStatus.pass &&
              result.detail.contains('2/2'),
        ),
        isTrue,
      );
    },
  );

  test('debug analysis text includes peer matrix and notes', () async {
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
    final analysis = alice.buildDebugAnalysisText(report: report);

    expect(analysis, contains('Conest debug analysis'));
    expect(analysis, contains('peer alias=Bob'));
    expect(analysis, contains('peerSummary Bob'));
    expect(analysis, contains('notes='));
  });

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

  test(
    'adaptive scheduler switches between active and idle intervals',
    () async {
      var now = DateTime.utc(2026, 4, 21, 11);
      final relayClient = _FakeRelayClient();
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        nowProvider: () => now,
      );
      addTearDown(controller.dispose);

      await controller.addContactFromInvite(
        alias: 'Bob',
        payload: _bobInvite().encodePayload(),
        codephrase: '',
      );
      final contact = controller.contacts.single;

      expect(
        controller.currentScheduledPollInterval,
        const Duration(seconds: 15),
      );

      await controller.checkContactRoutes(
        contact,
        persist: false,
        exchangeRouteUpdate: false,
        fast: true,
      );
      expect(
        controller.currentScheduledPollInterval,
        const Duration(seconds: 5),
      );

      now = now.add(const Duration(seconds: 21));
      expect(
        controller.currentScheduledPollInterval,
        const Duration(seconds: 15),
      );

      controller.setAppForegroundState(false);
      expect(
        controller.currentScheduledPollInterval,
        const Duration(seconds: 15),
      );
    },
  );

  test(
    'pollNow fetches directly without a health probe on known poll routes',
    () async {
      final relayClient = _FakeRelayClient();
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        internetRelayHost: null,
      );
      addTearDown(controller.dispose);

      relayClient.fetchAttempts.clear();
      relayClient.inspectHealthAttempts.clear();
      await controller.pollNow();

      expect(relayClient.fetchAttempts, isNotEmpty);
      expect(relayClient.inspectHealthAttempts, isEmpty);
    },
  );

  test(
    'pairing session activates for invite actions and expires after two minutes',
    () async {
      var now = DateTime.utc(2026, 4, 21, 12);
      final relayClient = _FakeRelayClient();
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        nowProvider: () => now,
      );
      addTearDown(controller.dispose);

      expect(controller.pairingSessionActive, isFalse);

      await controller.buildInvite();
      expect(controller.pairingSessionActive, isTrue);

      now = now.add(const Duration(minutes: 3));
      expect(controller.pairingSessionActive, isFalse);

      await controller.rotatePairingCodeNow();
      expect(controller.pairingSessionActive, isTrue);
    },
  );

  test(
    'transient relay checks do not force a vault save when the snapshot is unchanged',
    () async {
      final vaultStore = _MemoryVaultStore();
      final relayClient = _FakeRelayClient();
      final controller = MessengerController(
        vaultStore: vaultStore,
        relayClient: relayClient,
        localRelayNode: _FakeLocalRelayNode(),
        lanAddressProvider: () async => <String>['192.168.1.20'],
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createIdentity(
        displayName: 'Alice',
        internetRelayHost: null,
        internetRelayPort: defaultRelayPort,
        localRelayPort: defaultRelayPort,
      );

      final saveCountBefore = vaultStore.saveCount;
      await controller.checkRelayAvailability();

      expect(vaultStore.saveCount, saveCountBefore);
    },
  );

  test('debug snapshot reports adaptive runtime diagnostics', () async {
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      internetRelayHost: null,
    );
    addTearDown(controller.dispose);

    final snapshot = controller.buildDebugSnapshotText();

    expect(snapshot, contains('runtimeMode='));
    expect(snapshot, contains('nextScheduledPollAt='));
    expect(snapshot, contains('pairingSessionActive='));
    expect(snapshot, contains('fetchCalls='));
    expect(snapshot, contains('vaultSaveCount='));
    expect(snapshot, contains('routeBackoffSummary='));
  });
}
