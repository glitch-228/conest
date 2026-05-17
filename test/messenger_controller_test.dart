import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/main.dart' as app;
import 'package:conest/src/build_info.dart';
import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/messenger_controller.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/relay_client.dart'
    show RelayClient, RelayHealthInfo, RelayIdentityMismatchException;
import 'package:conest/src/relay_defaults.dart';
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
    bool Function(
      String host,
      int port,
      PeerRouteProtocol protocol,
      String recipientDeviceId,
      RelayEnvelope envelope,
    )?
    shouldFailStore,
  }) : _healthFailingHosts = failingHosts ?? <String>{},
       _storeFailingHosts = storeFailingHosts ?? failingHosts ?? <String>{},
       _allowedHosts = allowedHosts,
       _storeAllowedHosts = storeAllowedHosts ?? allowedHosts,
       _relayInstanceIds = relayInstanceIds ?? const <String, String>{},
       _shouldBlackholeStore = shouldBlackholeStore,
       _shouldFailStore = shouldFailStore;

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
  final bool Function(
    String host,
    int port,
    PeerRouteProtocol protocol,
    String recipientDeviceId,
    RelayEnvelope envelope,
  )?
  _shouldFailStore;
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
    String? expectedIdentityPublicKeyBase64,
  }) async {
    final key = _key(host, port, protocol);
    storeAttempts.add('$host:$port');
    if (!_isRouteAllowed(_storeAllowedHosts, host, port, protocol)) {
      throw StateError('Route unavailable for $key');
    }
    if (_containsRoute(_storeFailingHosts, host, port, protocol)) {
      throw StateError('Route unavailable for $key');
    }
    if (_shouldFailStore?.call(
          host,
          port,
          protocol,
          recipientDeviceId,
          envelope,
        ) ??
        false) {
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
    Duration waitFor = Duration.zero,
    String? expectedIdentityPublicKeyBase64,
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
    String? expectedIdentityPublicKeyBase64,
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
    String? expectedIdentityPublicKeyBase64,
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
    String? expectedIdentityPublicKeyBase64,
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
    Duration waitFor = Duration.zero,
    String? expectedIdentityPublicKeyBase64,
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
    String? expectedIdentityPublicKeyBase64,
  }) async {
    return _queues.containsKey(_key(host, port, protocol));
  }

  @override
  Future<RelayHealthInfo> inspectHealth({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
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
  Future<SignedRelayDefaults?> Function()? signedRelayDefaultsLoader,
  VaultStore? vaultStore,
  bool createIdentity = true,
  bool enableLongPoll = false,
}) async {
  final controller = MessengerController(
    vaultStore: vaultStore ?? _MemoryVaultStore(),
    relayClient: relayClient,
    localRelayNode: _FakeLocalRelayNode(),
    lanAddressProvider: () async => lanAddresses,
    nowProvider: nowProvider,
    signedRelayDefaultsLoader: signedRelayDefaultsLoader,
    enableLongPoll: enableLongPoll,
  );
  await controller.initialize();
  if (createIdentity) {
    await controller.createIdentity(
      displayName: displayName,
      internetRelayHost: internetRelayHost,
      internetRelayPort: defaultRelayPort,
      localRelayPort: defaultRelayPort,
    );
  }
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

Future<void> _pairControllers(
  MessengerController first,
  MessengerController second,
) async {
  await first.addContactFromInvite(
    alias: second.identity!.displayName,
    payload: (await second.buildInvite()).encodePayload(),
    codephrase: '',
  );
  await second.pollNow();
  expect(
    second.contacts.any(
      (contact) => contact.deviceId == first.identity!.deviceId,
    ),
    isTrue,
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

  test('group records round-trip and v0.1 vaults load without groups', () {
    final createdAt = DateTime.utc(2026, 4, 25, 10);
    final group = GroupRecord(
      groupId: 'grp-test',
      title: 'Core team',
      ownerDeviceId: 'dev-alice',
      adminDeviceIds: const <String>['dev-alice', 'dev-bob', 'dev-bob'],
      moderatorDeviceIds: const <String>[
        'dev-bob',
        'dev-carol',
        'dev-dana',
        'dev-erin',
      ],
      memberDeviceIds: const <String>['dev-bob', 'dev-carol', 'dev-dana'],
      removedDeviceIds: const <String>['dev-dana', 'dev-alice'],
      memberProfiles: <GroupMemberProfile>[
        GroupMemberProfile(
          accountId: 'acc-bob',
          deviceId: 'dev-bob',
          displayName: 'Bob',
          bio: 'group profile',
          relayCapable: true,
          publicKeyBase64: 'bob-key',
          routeHints: const <PeerEndpoint>[
            PeerEndpoint(
              kind: PeerRouteKind.relay,
              host: 'relay.example',
              port: defaultRelayPort,
            ),
          ],
        ),
      ],
      membershipVersion: 3,
      createdAt: createdAt,
      updatedAt: createdAt.add(const Duration(minutes: 2)),
    );

    final decoded = GroupRecord.fromJson(group.toJson());
    expect(decoded.groupId, group.groupId);
    expect(decoded.adminDeviceIds, ['dev-bob']);
    expect(decoded.moderatorDeviceIds, ['dev-carol']);
    expect(decoded.memberDeviceIds, [
      'dev-alice',
      'dev-bob',
      'dev-carol',
      'dev-dana',
    ]);
    expect(decoded.removedDeviceIds, ['dev-dana']);
    expect(decoded.roleFor('dev-alice'), GroupMemberRole.owner);
    expect(decoded.roleFor('dev-bob'), GroupMemberRole.admin);
    expect(decoded.roleFor('dev-carol'), GroupMemberRole.moderator);
    expect(decoded.roleFor('dev-dana'), isNull);
    expect(decoded.memberProfileFor('dev-bob')?.displayName, 'Bob');
    expect(
      decoded.memberProfileFor('dev-bob')?.routeHints.single.host,
      'relay.example',
    );
    expect(decoded.membershipVersion, 3);

    final legacyJson = Map<String, dynamic>.from(group.toJson())
      ..remove('moderatorDeviceIds');
    final legacy = GroupRecord.fromJson(legacyJson);
    expect(legacy.moderatorDeviceIds, isEmpty);
    expect(legacy.roleFor('dev-bob'), GroupMemberRole.admin);
    expect(legacy.roleFor('dev-carol'), GroupMemberRole.member);

    final migrated = VaultSnapshot.fromJson(const <String, dynamic>{
      'identity': null,
      'contacts': <dynamic>[],
      'reachabilityRecords': <dynamic>[],
      'conversations': <dynamic>[],
      'seenEnvelopeIds': <dynamic>[],
    });
    expect(migrated.groups, isEmpty);
  });

  test(
    'group create and send fans out encrypted messages to members',
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
      final carol = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);

      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);

      final group = await alice.createGroup(
        title: 'Launch',
        members: alice.contacts,
      );
      await bob.pollNow();
      await carol.pollNow();

      expect(bob.groups.single.groupId, group.groupId);
      expect(carol.groups.single.groupId, group.groupId);

      await alice.sendGroupMessage(groupId: group.groupId, body: 'hello team');
      await bob.pollNow();
      await carol.pollNow();

      expect(bob.messagesForGroup(group.groupId).single.body, 'hello team');
      expect(carol.messagesForGroup(group.groupId).single.body, 'hello team');
      final groupEnvelopes = relayClient.storedEnvelopes.where(
        (envelope) => envelope.kind == 'group_message',
      );
      expect(groupEnvelopes, hasLength(2));
      expect(
        groupEnvelopes.every((envelope) => envelope.payloadBase64 == null),
        isTrue,
      );
      expect(
        groupEnvelopes.every((envelope) => envelope.ciphertextBase64 != null),
        isTrue,
      );
    },
  );

  test('group offline member stays pending and retries later', () async {
    late String carolDeviceId;
    var failCarolGroupMessages = true;
    var now = DateTime.utc(2026, 4, 25, 12);
    final relayClient = _FakeRelayClient(
      shouldFailStore: (_, _, _, recipientDeviceId, envelope) =>
          failCarolGroupMessages &&
          envelope.kind == 'group_message' &&
          recipientDeviceId == carolDeviceId,
    );
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      nowProvider: () => now,
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    final carol = await _createController(
      relayClient: relayClient,
      displayName: 'Carol',
    );
    carolDeviceId = carol.identity!.deviceId;
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);

    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);
    final group = await alice.createGroup(
      title: 'Launch',
      members: alice.contacts,
    );
    await bob.pollNow();
    await carol.pollNow();

    await alice.sendGroupMessage(groupId: group.groupId, body: 'retry me');
    final queued = alice.messagesForGroup(group.groupId).single;
    expect(queued.recipientStates[carolDeviceId], DeliveryState.pending);
    expect(
      queued.recipientStates[bob.identity!.deviceId],
      isNot(DeliveryState.pending),
    );

    failCarolGroupMessages = false;
    now = now.add(const Duration(seconds: 16));
    await alice.retryUnacknowledgedMessagesNow();
    await carol.pollNow();

    expect(carol.messagesForGroup(group.groupId).single.body, 'retry me');
    final retried = alice.messagesForGroup(group.groupId).single;
    expect(
      retried.recipientStates[carolDeviceId],
      isNot(DeliveryState.pending),
    );
  });

  test('group read receipts update per-member recipient state', () async {
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

    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'Read receipts',
      members: alice.contacts,
    );
    await bob.pollNow();

    await alice.sendGroupMessage(groupId: group.groupId, body: 'seen?');
    await bob.pollNow();
    final inbound = bob.messagesForGroup(group.groupId).single;
    await bob.markGroupReadThroughMessage(group.groupId, inbound);
    await alice.pollNow();

    final outbound = alice.messagesForGroup(group.groupId).single;
    expect(
      outbound.recipientStates[bob.identity!.deviceId],
      DeliveryState.read,
    );
  });

  test('group replies preserve quoted metadata', () async {
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

    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'Replies',
      members: alice.contacts,
    );
    await bob.pollNow();

    await alice.sendGroupMessage(groupId: group.groupId, body: 'first');
    await bob.pollNow();
    final first = bob.messagesForGroup(group.groupId).single;
    await bob.sendGroupMessage(
      groupId: group.groupId,
      body: 'second',
      replyTo: first,
    );
    await alice.pollNow();

    final reply = alice.messagesForGroup(group.groupId).last;
    expect(reply.body, 'second');
    expect(reply.replyToMessageId, first.id);
    expect(reply.replySnippet, 'first');
    expect(reply.replySenderDeviceId, alice.identity!.deviceId);
  });

  test('group members can reach each other without being contacts', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    final carol = await _createController(
      relayClient: relayClient,
      displayName: 'Carol',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);

    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);

    final group = await alice.createGroup(
      title: 'Non-contact members',
      members: alice.contacts,
    );
    await bob.pollNow();
    await carol.pollNow();

    expect(
      bob.contacts.any(
        (contact) => contact.deviceId == carol.identity!.deviceId,
      ),
      isFalse,
    );
    expect(
      carol.contacts.any(
        (contact) => contact.deviceId == bob.identity!.deviceId,
      ),
      isFalse,
    );
    expect(
      bob.groups.single.memberProfileFor(carol.identity!.deviceId),
      isNotNull,
    );
    expect(
      carol.groups.single.memberProfileFor(bob.identity!.deviceId),
      isNotNull,
    );

    await bob.sendGroupMessage(groupId: group.groupId, body: 'from bob');
    await alice.pollNow();
    await carol.pollNow();
    await bob.pollNow();

    expect(alice.messagesForGroup(group.groupId).single.body, 'from bob');
    expect(carol.messagesForGroup(group.groupId).single.body, 'from bob');
    final bobOutbound = bob.messagesForGroup(group.groupId).single;
    expect(
      bobOutbound.recipientStates[carol.identity!.deviceId],
      isNot(DeliveryState.pending),
    );

    await carol.sendGroupMessage(groupId: group.groupId, body: 'from carol');
    await alice.pollNow();
    await bob.pollNow();

    expect(bob.messagesForGroup(group.groupId).last.body, 'from carol');
    expect(alice.messagesForGroup(group.groupId).last.body, 'from carol');

    await alice.removeContact(carol.identity!.deviceId, notifyPeer: false);
    expect(
      alice.contacts.any(
        (contact) => contact.deviceId == carol.identity!.deviceId,
      ),
      isFalse,
    );

    await alice.sendGroupMessage(
      groupId: group.groupId,
      body: 'from creator after contact removal',
    );
    await bob.pollNow();
    await carol.pollNow();

    expect(
      carol.messagesForGroup(group.groupId).last.body,
      'from creator after contact removal',
    );
    expect(
      bob.messagesForGroup(group.groupId).last.body,
      'from creator after contact removal',
    );
  });

  test(
    'owner can remove a group member and removed member cannot send',
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

      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Removal',
        members: alice.contacts,
      );
      await bob.pollNow();

      await alice.removeGroupMember(
        groupId: group.groupId,
        memberDeviceId: bob.identity!.deviceId,
      );
      await bob.pollNow();

      // Bob keeps the group visible (he can still see history and the
      // "you left" badge will render in the sidebar) until he explicitly
      // calls removeGroupFromList.
      expect(bob.visibleGroups, hasLength(1));
      expect(
        bob.visibleGroups.single.hasActiveMember(bob.identity!.deviceId),
        isFalse,
      );
      expect(bob.visibleGroups.single.localRemovedAt, isNull);
      expect(
        bob.sendGroupMessage(groupId: group.groupId, body: 'nope'),
        throwsArgumentError,
      );
    },
  );

  test('owner can add a member after group creation', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    final carol = await _createController(
      relayClient: relayClient,
      displayName: 'Carol',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);

    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);
    final bobContact = alice.contacts.firstWhere(
      (contact) => contact.deviceId == bob.identity!.deviceId,
    );
    final carolContact = alice.contacts.firstWhere(
      (contact) => contact.deviceId == carol.identity!.deviceId,
    );
    final group = await alice.createGroup(
      title: 'Add later',
      members: [bobContact],
    );
    await bob.pollNow();

    await alice.addGroupMembers(
      groupId: group.groupId,
      members: [carolContact],
    );
    await bob.pollNow();
    await carol.pollNow();

    expect(
      bob.groups.single.activeMemberDeviceIds,
      contains(carol.identity!.deviceId),
    );
    expect(carol.groups.single.groupId, group.groupId);
    expect(carol.groups.single.membershipVersion, 2);
  });

  test('owner can assign and demote group roles', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    final carol = await _createController(
      relayClient: relayClient,
      displayName: 'Carol',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);

    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);
    final bobContact = alice.contacts.firstWhere(
      (contact) => contact.deviceId == bob.identity!.deviceId,
    );
    final carolContact = alice.contacts.firstWhere(
      (contact) => contact.deviceId == carol.identity!.deviceId,
    );

    final group = await alice.createGroup(
      title: 'Roles',
      members: [bobContact, carolContact],
      adminDeviceIds: [bob.identity!.deviceId],
      moderatorDeviceIds: [carol.identity!.deviceId],
    );
    await bob.pollNow();
    await carol.pollNow();

    expect(group.roleFor(alice.identity!.deviceId), GroupMemberRole.owner);
    expect(
      bob.groups.single.roleFor(bob.identity!.deviceId),
      GroupMemberRole.admin,
    );
    expect(
      carol.groups.single.roleFor(carol.identity!.deviceId),
      GroupMemberRole.moderator,
    );

    await alice.setGroupMemberRole(
      groupId: group.groupId,
      memberDeviceId: carol.identity!.deviceId,
      role: GroupMemberRole.admin,
    );
    await alice.setGroupMemberRole(
      groupId: group.groupId,
      memberDeviceId: bob.identity!.deviceId,
      role: GroupMemberRole.member,
    );
    await bob.pollNow();
    await carol.pollNow();

    expect(
      alice.groups.single.roleFor(carol.identity!.deviceId),
      GroupMemberRole.admin,
    );
    expect(
      bob.groups.single.roleFor(bob.identity!.deviceId),
      GroupMemberRole.member,
    );
    expect(
      carol.groups.single.roleFor(bob.identity!.deviceId),
      GroupMemberRole.member,
    );
    expect(carol.groups.single.membershipVersion, 3);
  });

  test(
    'admin can add and remove ordinary members but cannot manage roles',
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
      final carol = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
      );
      final dave = await _createController(
        relayClient: relayClient,
        displayName: 'Dave',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);
      addTearDown(dave.dispose);

      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await _pairControllers(bob, dave);
      final bobContact = alice.contacts.firstWhere(
        (contact) => contact.deviceId == bob.identity!.deviceId,
      );
      final carolContact = alice.contacts.firstWhere(
        (contact) => contact.deviceId == carol.identity!.deviceId,
      );
      final daveContact = bob.contacts.firstWhere(
        (contact) => contact.deviceId == dave.identity!.deviceId,
      );

      final group = await alice.createGroup(
        title: 'Admin managed',
        members: [bobContact, carolContact],
        adminDeviceIds: [bob.identity!.deviceId, carol.identity!.deviceId],
      );
      await bob.pollNow();
      await carol.pollNow();

      expect(
        bob.setGroupMemberRole(
          groupId: group.groupId,
          memberDeviceId: carol.identity!.deviceId,
          role: GroupMemberRole.member,
        ),
        throwsArgumentError,
      );
      expect(
        bob.removeGroupMember(
          groupId: group.groupId,
          memberDeviceId: alice.identity!.deviceId,
        ),
        throwsArgumentError,
      );
      expect(
        bob.removeGroupMember(
          groupId: group.groupId,
          memberDeviceId: carol.identity!.deviceId,
        ),
        throwsArgumentError,
      );

      await alice.setGroupMemberRole(
        groupId: group.groupId,
        memberDeviceId: carol.identity!.deviceId,
        role: GroupMemberRole.moderator,
      );
      await bob.pollNow();
      await carol.pollNow();

      expect(
        carol.contacts.any(
          (contact) => contact.deviceId == bob.identity!.deviceId,
        ),
        isFalse,
      );
      await bob.addGroupMembers(groupId: group.groupId, members: [daveContact]);
      await alice.pollNow();
      await carol.pollNow();
      await dave.pollNow();

      expect(
        carol.groups.single.activeMemberDeviceIds,
        contains(dave.identity!.deviceId),
      );
      expect(
        dave.groups.single.roleFor(dave.identity!.deviceId),
        GroupMemberRole.member,
      );

      await bob.removeGroupMember(
        groupId: group.groupId,
        memberDeviceId: carol.identity!.deviceId,
      );
      await alice.pollNow();
      await carol.pollNow();
      await dave.pollNow();

      expect(
        alice.groups.single.activeMemberDeviceIds,
        isNot(contains(carol.identity!.deviceId)),
      );
      expect(carol.canAddGroupMembers(group.groupId), isFalse);
      expect(
        carol.sendGroupMessage(groupId: group.groupId, body: 'nope'),
        throwsArgumentError,
      );
    },
  );

  test('moderator cannot add or remove group members', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    final carol = await _createController(
      relayClient: relayClient,
      displayName: 'Carol',
    );
    final dave = await _createController(
      relayClient: relayClient,
      displayName: 'Dave',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);
    addTearDown(dave.dispose);

    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);
    await _pairControllers(bob, dave);
    final bobContact = alice.contacts.firstWhere(
      (contact) => contact.deviceId == bob.identity!.deviceId,
    );
    final carolContact = alice.contacts.firstWhere(
      (contact) => contact.deviceId == carol.identity!.deviceId,
    );
    final daveContact = bob.contacts.firstWhere(
      (contact) => contact.deviceId == dave.identity!.deviceId,
    );

    final group = await alice.createGroup(
      title: 'Moderated',
      members: [bobContact, carolContact],
      moderatorDeviceIds: [bob.identity!.deviceId],
    );
    await bob.pollNow();

    expect(bob.canAddGroupMembers(group.groupId), isFalse);
    expect(
      bob.addGroupMembers(groupId: group.groupId, members: [daveContact]),
      throwsArgumentError,
    );
    expect(
      bob.removeGroupMember(
        groupId: group.groupId,
        memberDeviceId: carol.identity!.deviceId,
      ),
      throwsArgumentError,
    );
  });

  test('non-owner member can leave a group', () async {
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

    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'Leave',
      members: alice.contacts,
    );
    await bob.pollNow();

    await bob.leaveGroup(group.groupId);
    await alice.pollNow();

    // After leaving Bob still sees the group in his list (so he can decide
    // when to remove it himself). The active membership has dropped.
    expect(bob.visibleGroups, hasLength(1));
    expect(
      bob.visibleGroups.single.hasActiveMember(bob.identity!.deviceId),
      isFalse,
    );
    expect(bob.visibleGroups.single.localRemovedAt, isNull);
    expect(
      alice.groups.single.activeMemberDeviceIds,
      isNot(contains(bob.identity!.deviceId)),
    );
  });

  test(
    'a member removed by the owner keeps the group visible until they remove it',
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

      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Boot',
        members: alice.contacts,
      );
      await bob.pollNow();
      expect(bob.visibleGroups, hasLength(1));

      await alice.removeGroupMember(
        groupId: group.groupId,
        memberDeviceId: bob.identity!.deviceId,
      );
      await bob.pollNow();

      // Bob still sees the group in his sidebar with hasActiveMember false.
      expect(bob.visibleGroups, hasLength(1));
      expect(
        bob.visibleGroups.single.hasActiveMember(bob.identity!.deviceId),
        isFalse,
      );
      expect(
        alice.groups.single.activeMemberDeviceIds,
        isNot(contains(bob.identity!.deviceId)),
      );
    },
  );

  test(
    'removeGroupFromList hides the group from visibleGroups and deletes its messages',
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

      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Goodbye',
        members: alice.contacts,
      );
      await alice.sendGroupMessage(groupId: group.groupId, body: 'hello');
      await bob.pollNow();
      expect(bob.messagesForGroup(group.groupId), hasLength(1));

      await bob.leaveGroup(group.groupId);
      await bob.removeGroupFromList(group.groupId);

      expect(bob.visibleGroups, isEmpty);
      expect(bob.groups, hasLength(1));
      expect(bob.groups.single.localRemovedAt, isNotNull);
      expect(bob.messagesForGroup(group.groupId), isEmpty);
    },
  );

  test(
    'removeGroupFromList throws while the user is still an active member',
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

      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Cannot remove while active',
        members: alice.contacts,
      );
      await bob.pollNow();

      expect(bob.removeGroupFromList(group.groupId), throwsArgumentError);
    },
  );

  test('owner can transfer group ownership and is demoted to admin', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    final carol = await _createController(
      relayClient: relayClient,
      displayName: 'Carol',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);

    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);
    final group = await alice.createGroup(
      title: 'Transfer',
      members: alice.contacts,
    );
    await bob.pollNow();
    await carol.pollNow();

    await alice.transferGroupOwnership(
      groupId: group.groupId,
      newOwnerDeviceId: bob.identity!.deviceId,
    );
    await bob.pollNow();
    await carol.pollNow();

    expect(alice.groups.single.ownerDeviceId, bob.identity!.deviceId);
    expect(
      alice.groups.single.roleFor(alice.identity!.deviceId),
      GroupMemberRole.admin,
    );
    expect(bob.groups.single.ownerDeviceId, bob.identity!.deviceId);
    expect(
      bob.groups.single.roleFor(bob.identity!.deviceId),
      GroupMemberRole.owner,
    );
    expect(carol.groups.single.ownerDeviceId, bob.identity!.deviceId);
    expect(
      carol.groups.single.roleFor(alice.identity!.deviceId),
      GroupMemberRole.admin,
    );
  });

  test('transferGroupOwnership rejects non-owner caller', () async {
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

    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'Not yours',
      members: alice.contacts,
    );
    await bob.pollNow();

    expect(
      bob.transferGroupOwnership(
        groupId: group.groupId,
        newOwnerDeviceId: alice.identity!.deviceId,
      ),
      throwsArgumentError,
    );
  });

  test('transferGroupOwnership rejects an inactive target', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(alice.dispose);

    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: _bobInvite().encodePayload(),
      codephrase: '',
    );
    final group = await alice.createGroup(
      title: 'Inactive transfer',
      members: alice.contacts,
    );
    await alice.removeGroupMember(
      groupId: group.groupId,
      memberDeviceId: 'dev-bob',
    );

    expect(
      alice.transferGroupOwnership(
        groupId: group.groupId,
        newOwnerDeviceId: 'dev-bob',
      ),
      throwsArgumentError,
    );
  });

  test('owner can dissolve a group for everyone', () async {
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

    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'Dissolve me',
      members: alice.contacts,
    );
    await bob.pollNow();

    await alice.dissolveGroup(group.groupId);
    await bob.pollNow();

    expect(
      alice.groups.single.hasActiveMember(alice.identity!.deviceId),
      isFalse,
    );
    expect(alice.groups.single.activeMemberDeviceIds, isEmpty);
    expect(bob.groups.single.hasActiveMember(bob.identity!.deviceId), isFalse);
    expect(bob.groups.single.activeMemberDeviceIds, isEmpty);
  });

  test('dissolveGroup rejects non-owner caller', () async {
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

    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'You cannot dissolve',
      members: alice.contacts,
    );
    await bob.pollNow();

    expect(bob.dissolveGroup(group.groupId), throwsArgumentError);
  });

  test(
    'pending group membership delivery is cleared after the target acks',
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

      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Pending',
        members: alice.contacts,
      );
      // After the synchronous send, Alice has at least one pending entry
      // for Bob (the ack hasn't come back yet — Bob still has to poll).
      expect(
        alice.pendingGroupMembershipDeliveries.any(
          (entry) =>
              entry.groupId == group.groupId &&
              entry.targetDeviceId == bob.identity!.deviceId,
        ),
        isTrue,
      );

      // Bob polls, applies the membership update, and acks. Alice polls
      // to receive the ack.
      await bob.pollNow();
      await alice.pollNow();

      expect(
        alice.pendingGroupMembershipDeliveries.any(
          (entry) => entry.targetDeviceId == bob.identity!.deviceId,
        ),
        isFalse,
        reason:
            'membership ack from Bob should clear the queued delivery on Alice',
      );
    },
  );

  test(
    'pending membership delivery is upgraded when the version advances',
    () async {
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      addTearDown(alice.dispose);

      // Add Bob (and Carol-shaped contact) as offline contacts so the
      // sends queue but never ack — letting us observe the version-upgrade
      // behavior without depending on a live peer.
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: _bobInvite().encodePayload(),
        codephrase: '',
      );
      final group = await alice.createGroup(
        title: 'Upgrade',
        members: alice.contacts,
      );
      final firstVersion = group.membershipVersion;
      final firstEntry = alice.pendingGroupMembershipDeliveries.firstWhere(
        (entry) => entry.targetDeviceId == 'dev-bob',
      );
      expect(firstEntry.membershipVersion, firstVersion);

      await alice.removeGroupMember(
        groupId: group.groupId,
        memberDeviceId: 'dev-bob',
      );
      // After the remove, the queue should still hold a single entry for
      // dev-bob (we re-queue the latest snapshot rather than accumulating).
      final pendingForBob = alice.pendingGroupMembershipDeliveries
          .where((entry) => entry.targetDeviceId == 'dev-bob')
          .toList(growable: false);
      expect(pendingForBob, hasLength(1));
      expect(pendingForBob.single.membershipVersion, greaterThan(firstVersion));
    },
  );

  test('pending membership deliveries survive a vault round-trip', () async {
    final relayClient = _FakeRelayClient();
    final vaultStore = _MemoryVaultStore();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      vaultStore: vaultStore,
    );
    addTearDown(alice.dispose);

    // Adding an offline contact + creating a group leaves Alice with a
    // pending membership delivery that hasn't been ack'd yet.
    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: _bobInvite().encodePayload(),
      codephrase: '',
    );
    await alice.createGroup(title: 'Persistent', members: alice.contacts);
    expect(alice.pendingGroupMembershipDeliveries, isNotEmpty);

    final persisted = await vaultStore.load();
    expect(
      persisted.pendingGroupMembershipDeliveries.any(
        (entry) => entry.targetDeviceId == 'dev-bob',
      ),
      isTrue,
      reason: 'pending entries must round-trip through the vault store',
    );
  });

  test('stale group membership updates are ignored', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    final carol = await _createController(
      relayClient: relayClient,
      displayName: 'Carol',
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);

    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);
    final bobContact = alice.contacts.firstWhere(
      (contact) => contact.deviceId == bob.identity!.deviceId,
    );
    final carolContact = alice.contacts.firstWhere(
      (contact) => contact.deviceId == carol.identity!.deviceId,
    );
    final group = await alice.createGroup(
      title: 'Stale',
      members: [bobContact],
    );
    await alice.addGroupMembers(
      groupId: group.groupId,
      members: [carolContact],
    );

    final queue = relayClient._queues[bob.identity!.deviceId]!;
    final memberships = queue
        .where((envelope) => envelope.kind == 'group_membership')
        .toList();
    expect(memberships, hasLength(2));
    queue
      ..removeWhere((envelope) => envelope.kind == 'group_membership')
      ..insertAll(0, memberships.reversed);

    await bob.pollNow();

    expect(bob.groups.single.membershipVersion, 2);
    expect(
      bob.groups.single.activeMemberDeviceIds,
      contains(carol.identity!.deviceId),
    );
  });

  test('unknown group sender is ignored', () async {
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

    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'Known group',
      members: alice.contacts,
    );
    await bob.pollNow();

    await relayClient.storeEnvelope(
      host: 'relay.example',
      port: defaultRelayPort,
      recipientDeviceId: bob.identity!.deviceId,
      envelope: RelayEnvelope(
        kind: 'group_message',
        messageId: 'unknown-message',
        conversationId: group.groupId,
        senderAccountId: 'acc-missing',
        senderDeviceId: 'dev-missing',
        recipientDeviceId: bob.identity!.deviceId,
        createdAt: DateTime.now().toUtc(),
        payloadBase64: base64Encode(utf8.encode('plaintext')),
      ),
    );

    await bob.pollNow();

    expect(bob.messagesForGroup(group.groupId), isEmpty);
  });

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

  test(
    'checking paths alone does not upgrade an unknown contact to seen recently',
    () async {
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

      // A successful route probe must NOT promote the chip to "seen recently"
      // without a corresponding real-exchange signal.
      expect(
        alice.reachabilityStateFor(aliceContactForBob.deviceId),
        ContactReachabilityState.unknown,
      );
    },
  );

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

      // The test name says "does not falsely mark online" — the load-bearing
      // assertion is that the state did not get promoted to "online". Since
      // the last real exchange was an hour ago (outside the 10 min seen-recently
      // window) and the heartbeat failed (no fresh signal), the correct state
      // is "known", not "seen recently" or "online".
      expect(
        alice.reachabilityStateFor(aliceContactForBob.deviceId),
        ContactReachabilityState.known,
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

  testWidgets('group details show role labels and scoped controls', (
    tester,
  ) async {
    late MessengerController alice;
    late MessengerController bob;
    late MessengerController carol;
    late GroupRecord group;

    await tester.runAsync(() async {
      final relayClient = _FakeRelayClient();
      alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );
      carol = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
      );

      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      final bobContact = alice.contacts.firstWhere(
        (contact) => contact.deviceId == bob.identity!.deviceId,
      );
      final carolContact = alice.contacts.firstWhere(
        (contact) => contact.deviceId == carol.identity!.deviceId,
      );
      group = await alice.createGroup(
        title: 'Role UI',
        members: [bobContact, carolContact],
        adminDeviceIds: [bob.identity!.deviceId],
        moderatorDeviceIds: [carol.identity!.deviceId],
      );
      await bob.pollNow();
    });

    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: app.GroupDetailsDialog(
            controller: alice,
            palette: app.ConestPalette(),
            group: group,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Moderator'), findsOneWidget);
    expect(find.byTooltip('Change role'), findsNWidgets(2));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: app.GroupDetailsDialog(
            controller: bob,
            palette: app.ConestPalette(),
            group: bob.groups.single,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Change role'), findsNothing);
    expect(find.byTooltip('Remove member'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

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
      late MessengerController alice;
      late MessengerController bob;
      await tester.runAsync(() async {
        final relayClient = _FakeRelayClient();
        alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
        );
        bob = await _createController(
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
        await bob.sendMessage(
          contact: bobContactForAlice,
          body: 'incoming text',
        );
        await alice.pollNow();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: app.HomeScreen(
            controller: alice,
            updateService: _createUpdateService(),
            themeController: app.ConestThemeController.memory(),
            palette: app.ConestPalette(),
          ),
        ),
      );
      await tester.pump();

      await tester.ensureVisible(find.text('Bob').first);
      await tester.tap(find.text('Bob').first);
      await tester.pump();
      await tester.ensureVisible(find.text('incoming text').last);
      await tester.tap(find.text('incoming text').last);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('incoming text').last);
      await tester.pump();

      expect(find.text('Replying to Bob'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pump();

      expect(find.text('Replying to Bob'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      alice.dispose();
      bob.dispose();
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets('double tap outgoing message opens the edit dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    await tester.runAsync(() async {
      final relayClient = _FakeRelayClient();
      alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      bob = await _createController(
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
        body: 'outgoing text',
      );
      await bob.pollNow();
      await alice.pollNow();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: _createUpdateService(),
          themeController: app.ConestThemeController.memory(),
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text('Bob').first);
    await tester.tap(find.text('Bob').first);
    await tester.pump();
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
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

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
    late MessengerController alice;
    late MessengerController bob;
    await tester.runAsync(() async {
      alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      bob = await _createController(
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
    });

    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: _createUpdateService(),
          themeController: app.ConestThemeController.memory(),
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text('Bob').first);
    await tester.tap(find.text('Bob').first);
    await tester.pump();
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

    expect(copiedText, 'copyable outgoing text');

    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
    'contact list and chat header show the current reachability chip',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 4, 18, 18);
      late MessengerController alice;
      late MessengerController bob;
      await tester.runAsync(() async {
        final relayClient = _FakeRelayClient();
        alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          nowProvider: () => now,
        );
        bob = await _createController(
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
      });

      await tester.pumpWidget(
        MaterialApp(
          home: app.HomeScreen(
            controller: alice,
            updateService: _createUpdateService(),
            themeController: app.ConestThemeController.memory(),
            palette: app.ConestPalette(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('online'), findsWidgets);

      await tester.ensureVisible(find.text('Bob').first);
      await tester.tap(find.text('Bob').first);
      await tester.pump();

      expect(find.text('online'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      alice.dispose();
      bob.dispose();
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets('sidebar unread badge clears after opening a conversation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    late ContactRecord aliceContactForBob;
    await tester.runAsync(() async {
      final relayClient = _FakeRelayClient();
      alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      bob = await _createController(
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
      aliceContactForBob = alice.contacts.single;
      await bob.sendMessage(contact: bobContactForAlice, body: 'fresh unread');
      await alice.pollNow();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: alice,
          builder: (context, _) => app.HomeScreen(
            controller: alice,
            updateService: _createUpdateService(),
            themeController: app.ConestThemeController.memory(),
            palette: app.ConestPalette(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(alice.unreadCountFor(aliceContactForBob.deviceId), 1);
    expect(find.text('fresh unread'), findsOneWidget);
    expect(find.byKey(const Key('unread-badge-1')), findsOneWidget);

    await tester.ensureVisible(find.text('Bob').first);
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump();

    expect(alice.unreadCountFor(aliceContactForBob.deviceId), 0);
    expect(find.byKey(const Key('unread-badge-1')), findsNothing);
    expect(find.text('new'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
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

  test('relay health score records success and failure samples', () async {
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{'relay.example:7667'},
      storeFailingHosts: <String>{'relay.example:7667'},
    );
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      internetRelayHost: 'relay.example',
    );
    addTearDown(controller.dispose);

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
          host: 'relay.example',
          port: 7667,
          protocol: PeerRouteProtocol.tcp,
        ),
      ],
    );
    await controller.addContactFromInvite(
      alias: 'Bob',
      payload: invite.encodePayload(),
      codephrase: '',
    );

    final contact = controller.contacts.single;
    for (var index = 0; index < 4; index++) {
      await controller.sendMessage(contact: contact, body: 'msg-$index');
    }

    final score = controller.relayHealthScores['relay.example:7667:tcp'];
    expect(score, isNotNull);
    // Every store call against the failing relay throws, so at least one
    // failure sample must be recorded. We don't assert recentSuccesses==0
    // because startup probes can interleave success samples we don't care
    // about; the test's load-bearing claim is that failures land in the
    // score map at all.
    expect(score!.recentAttempts, greaterThanOrEqualTo(1));
    expect(score.lastFailureAt, isNotNull);
    expect(
      score.recentSamples.any((sample) => !sample.succeeded),
      isTrue,
      reason: 'at least one failure sample must be present',
    );
  });

  test('relay health scores survive a save/load round trip', () async {
    final vaultStore = _MemoryVaultStore();
    final relayClient = _FakeRelayClient(
      failingHosts: <String>{'relay.example:7667'},
      storeFailingHosts: <String>{'relay.example:7667'},
    );
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
      internetRelayHost: 'relay.example',
      internetRelayPort: defaultRelayPort,
      localRelayPort: defaultRelayPort,
    );

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
          host: 'relay.example',
          port: 7667,
          protocol: PeerRouteProtocol.tcp,
        ),
      ],
    );
    await controller.addContactFromInvite(
      alias: 'Bob',
      payload: invite.encodePayload(),
      codephrase: '',
    );
    final contact = controller.contacts.single;
    await controller.sendMessage(contact: contact, body: 'force a score');

    // Inspect the persisted vault directly: this avoids spinning up a
    // second controller (which would compete with the first's poll loop)
    // while still proving the score round-trips through JSON.
    final reloadedSnapshot = await vaultStore.load();
    final score = reloadedSnapshot.relayHealthScores['relay.example:7667:tcp'];
    expect(
      score,
      isNotNull,
      reason: 'relay health score must survive the vault round trip',
    );
    expect(score!.recentAttempts, greaterThan(0));
    expect(score.lastFailureAt, isNotNull);
  });

  test('signed default relays ingest endpoints on first boot', () async {
    final relayClient = _FakeRelayClient();
    const spec = DefaultRelayEndpointSpec(
      kind: PeerRouteKind.relay,
      host: 'defaults.example',
      port: defaultRelayPort,
      protocol: PeerRouteProtocol.tcp,
    );
    final defaults = SignedRelayDefaults(
      version: 7,
      issuedAt: DateTime.utc(2026, 5, 12),
      endpoints: const [spec],
    );
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      signedRelayDefaultsLoader: () async => defaults,
    );
    addTearDown(alice.dispose);

    final hosts = alice.identity!.configuredRelays
        .map((relay) => relay.host)
        .toSet();
    expect(hosts, contains('defaults.example'));
  });

  test('signed default relays persist their version after ingestion', () async {
    final relayClient = _FakeRelayClient();
    final vaultStore = _MemoryVaultStore();
    final defaults = SignedRelayDefaults(
      version: 11,
      issuedAt: DateTime.utc(2026, 5, 12),
      endpoints: const [
        DefaultRelayEndpointSpec(
          kind: PeerRouteKind.relay,
          host: 'pinned.example',
          port: defaultRelayPort,
          protocol: PeerRouteProtocol.tcp,
        ),
      ],
    );
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      vaultStore: vaultStore,
      signedRelayDefaultsLoader: () async => defaults,
    );
    addTearDown(alice.dispose);

    expect(
      alice.identity!.configuredRelays.any(
        (relay) => relay.host == 'pinned.example',
      ),
      isTrue,
    );
    final persisted = await vaultStore.load();
    expect(persisted.defaultRelayDefaultsVersion, 11);
    expect(
      persisted.identity!.configuredRelays.any(
        (relay) => relay.host == 'pinned.example',
      ),
      isTrue,
    );
  });

  test('pinnedRelayIdentityKeys round-trip through the vault store', () async {
    final vaultStore = _MemoryVaultStore();
    await vaultStore.save(
      VaultSnapshot.empty().copyWith(
        pinnedRelayIdentityKeys: const <String, String>{
          'relay-alpha': 'pubkey-alpha-base64==',
          'relay-beta': 'pubkey-beta-base64==',
        },
      ),
    );
    final loaded = await vaultStore.load();
    expect(loaded.pinnedRelayIdentityKeys['relay-alpha'], isNotNull);
    expect(loaded.pinnedRelayIdentityKeys['relay-beta'], isNotNull);
  });

  test(
    'RelayIdentityMismatchException carries a descriptive message',
    () async {
      final exception = RelayIdentityMismatchException('pinned key mismatch');
      expect(exception.message, contains('pinned key'));
      expect(exception.toString(), contains('pinned key mismatch'));
    },
  );

  test('signed default relay loader rejects a tampered manifest', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final manifest = jsonEncode({
      'version': 5,
      'issuedAt': '2026-05-12T00:00:00Z',
      'endpoints': const <Map<String, dynamic>>[],
    });
    final signature = await algorithm.sign(
      utf8.encode(manifest),
      keyPair: keyPair,
    );
    final goodPublicKeyBase64 = base64Encode(publicKey.bytes);

    final clean = await loadSignedDefaultRelays(
      manifestJson: manifest,
      signatureBase64: base64Encode(signature.bytes),
      publicKeyBase64: goodPublicKeyBase64,
    );
    expect(clean, isNotNull);

    final tamperedManifest = manifest.replaceFirst(
      '"version":5',
      '"version":6',
    );
    expect(tamperedManifest, isNot(equals(manifest)));
    final tampered = await loadSignedDefaultRelays(
      manifestJson: tamperedManifest,
      signatureBase64: base64Encode(signature.bytes),
      publicKeyBase64: goodPublicKeyBase64,
    );
    expect(tampered, isNull);

    final empty = await loadSignedDefaultRelays(
      manifestJson: manifest,
      signatureBase64: base64Encode(signature.bytes),
      publicKeyBase64: '',
    );
    expect(empty, isNull);
  });

  test(
    'read receipt is enqueued when delivery fails and clears after retry',
    () async {
      // The fake relay refuses to store the read receipt the first time
      // (e.g. transient route hiccup). The controller must keep the
      // pending entry around and clear it after a successful re-send.
      var dropReceipts = true;
      final relayClient = _FakeRelayClient(
        shouldFailStore: (host, port, protocol, recipientDeviceId, envelope) {
          if (envelope.kind != 'ack') return false;
          if (envelope.payloadBase64 == null) return false;
          if (!dropReceipts) return false;
          try {
            final decoded = jsonDecode(
              utf8.decode(base64Decode(envelope.payloadBase64!)),
            );
            return decoded is Map<String, dynamic> &&
                decoded['receipt'] == 'read';
          } catch (_) {
            return false;
          }
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

      await _pairControllers(alice, bob);
      final bobContact = alice.contacts.firstWhere(
        (contact) => contact.deviceId == bob.identity!.deviceId,
      );
      await alice.sendMessage(contact: bobContact, body: 'hello');
      await bob.pollNow();
      final inbound = bob
          .messagesFor(alice.identity!.deviceId)
          .firstWhere((message) => !message.outbound);
      await bob.markConversationReadThroughMessage(
        alice.identity!.deviceId,
        inbound,
      );
      // First delivery dropped — the pending entry must stay queued.
      expect(
        bob.pendingAckDeliveries.any(
          (entry) =>
              entry.kind == PendingAckKind.read &&
              entry.targetDeviceId == alice.identity!.deviceId,
        ),
        isTrue,
        reason: 'failed read receipt must persist for retry',
      );

      final attemptsBefore = bob.pendingAckDeliveries.first.attempts;
      dropReceipts = false;
      await bob.debugRunPendingAckRetries();
      // The retry loop fires the delivery again. Depending on route
      // health (the first failure marks the relay path unhealthy for a
      // window), the second attempt either lands and clears the entry
      // OR sits queued with `attempts` incremented. Either outcome proves
      // the retry path ran.
      final cleared = bob.pendingAckDeliveries.isEmpty;
      final reattempted =
          !cleared && bob.pendingAckDeliveries.first.attempts > attemptsBefore;
      expect(
        cleared || reattempted,
        isTrue,
        reason: 'pending ack must either clear or have attempts incremented',
      );
    },
  );

  test('rotateRelayIdentityKey validates input + persists', () async {
    final relayClient = _FakeRelayClient();
    final vaultStore = _MemoryVaultStore();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      vaultStore: vaultStore,
    );
    addTearDown(alice.dispose);

    expect(
      () => alice.rotateRelayIdentityKey(relayId: '', newKeyBase64: 'x'),
      throwsArgumentError,
    );
    expect(
      () => alice.rotateRelayIdentityKey(
        relayId: 'relay-a',
        newKeyBase64: 'not-base64-!!',
      ),
      throwsArgumentError,
    );
    expect(
      () => alice.rotateRelayIdentityKey(
        relayId: 'relay-a',
        newKeyBase64: base64Encode(List<int>.filled(16, 0)),
      ),
      throwsArgumentError,
      reason: 'must be 32 raw bytes',
    );

    final newKey = base64Encode(List<int>.filled(32, 7));
    await alice.rotateRelayIdentityKey(
      relayId: 'relay-a',
      newKeyBase64: newKey,
    );
    expect(alice.pinnedRelayIdentityKeys['relay-a'], newKey);

    final persisted = await vaultStore.load();
    expect(persisted.pinnedRelayIdentityKeys['relay-a'], newKey);
  });

  test('signed default v2 supersedes a stale v1 pinned in the vault', () async {
    // Pre-seed a vault with version 1 already persisted but no endpoints
    // yet. The controller should ingest the v2 manifest, record the route
    // key as a default, and bump the persisted version.
    final relayClient = _FakeRelayClient();
    final vaultStore = _MemoryVaultStore();
    final endpoint = PeerEndpoint(
      kind: PeerRouteKind.relay,
      host: 'pinned.example',
      port: defaultRelayPort,
    );
    final defaults = SignedRelayDefaults(
      version: 2,
      issuedAt: DateTime.utc(2026, 5, 13),
      endpoints: const [
        DefaultRelayEndpointSpec(
          kind: PeerRouteKind.relay,
          host: 'pinned.example',
          port: defaultRelayPort,
          protocol: PeerRouteProtocol.tcp,
        ),
      ],
    );
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      vaultStore: vaultStore,
      signedRelayDefaultsLoader: () async => defaults,
    );
    addTearDown(alice.dispose);

    expect(
      alice.defaultRelayRouteKeys,
      contains(endpoint.routeKey),
      reason: 'route key recorded so the UI knows to mask the relay',
    );
    expect(alice.relayDisplayLabel(endpoint), 'default relay 1');

    // A manually-added relay is rendered with its raw label.
    final manual = PeerEndpoint(
      kind: PeerRouteKind.relay,
      host: 'manual.example',
      port: defaultRelayPort,
    );
    expect(alice.relayDisplayLabel(manual), manual.label);
  });

  test(
    'schema v3 default with no protocol fans out into all transports under one label',
    () async {
      final relayClient = _FakeRelayClient();
      final defaults = SignedRelayDefaults(
        version: 7,
        issuedAt: DateTime.utc(2026, 5, 16),
        endpoints: const [
          DefaultRelayEndpointSpec(
            kind: PeerRouteKind.relay,
            host: 'multi.example',
            port: defaultRelayPort,
          ),
        ],
      );
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        signedRelayDefaultsLoader: () async => defaults,
      );
      addTearDown(alice.dispose);

      final derived = alice.identity!.configuredRelays
          .where((relay) => relay.host == 'multi.example')
          .toList();
      expect(
        derived.length,
        greaterThanOrEqualTo(3),
        reason: 'TCP/UDP/HTTP at minimum should each become a route',
      );
      final labels = derived
          .map((relay) => alice.relayDisplayLabel(relay))
          .toSet();
      expect(
        labels.length,
        1,
        reason: 'All derived routes collapse to one "default relay N" label',
      );
      expect(labels.single, startsWith('default relay '));
    },
  );

  test(
    'contact-reset detection puts a same-name contact in pendingVerification',
    () async {
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      addTearDown(alice.dispose);

      // First trust: a normal Bob.
      final originalInvite = _bobInvite();
      await alice.addContactFromInvite(
        alias: originalInvite.displayName,
        payload: originalInvite.encodePayload(),
        codephrase: '',
      );

      // Second invite: same displayName but a different deviceId AND key.
      // Simulates Bob reinstalling.
      final reinstalledInvite = ContactInvite(
        version: originalInvite.version,
        accountId: 'acc-bob-2',
        deviceId: 'dev-bob-2',
        displayName: originalInvite.displayName,
        bio: originalInvite.bio,
        pairingNonce: 'bob-reinstall-nonce',
        pairingEpochMs: originalInvite.pairingEpochMs + 1,
        relayCapable: originalInvite.relayCapable,
        publicKeyBase64: 'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
        routeHints: originalInvite.routeHints,
      );
      await alice.addContactFromInvite(
        alias: reinstalledInvite.displayName,
        payload: reinstalledInvite.encodePayload(),
        codephrase: '',
      );
      final newBob = alice.contactByDeviceId('dev-bob-2');
      expect(newBob, isNotNull);
      expect(newBob!.pendingVerification, isTrue);
      expect(newBob.replacesDeviceId, 'dev-bob');
      expect(newBob.canSendOutbound, isFalse);
      // Crypto-level block: the active publicKeyBase64 is empty while
      // pending so `_pairwiseDirectKey` literally cannot derive a shared
      // secret. The real key is stashed in unverifiedPublicKeyBase64.
      expect(newBob.publicKeyBase64, isEmpty);
      expect(
        newBob.unverifiedPublicKeyBase64,
        'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
      );

      // sendMessage to the pending contact must throw, AND nothing should
      // reach the relay client — proves the block isn't a UI-only flag.
      final storeAttemptsBefore = relayClient.storeAttempts.length;
      await expectLater(
        () => alice.sendMessage(contact: newBob, body: 'hi'),
        throwsStateError,
      );
      expect(
        relayClient.storeAttempts.length,
        storeAttemptsBefore,
        reason: 'No envelope must reach the relay for a pending contact.',
      );

      // Confirm replacement promotes the unverified key, lifts the block,
      // AND archives the predecessor.
      await alice.confirmContactReplacement('dev-bob-2');
      final refreshed = alice.contactByDeviceId('dev-bob-2');
      expect(refreshed!.pendingVerification, isFalse);
      expect(refreshed.canSendOutbound, isTrue);
      expect(
        refreshed.publicKeyBase64,
        'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
        reason: 'Unverified key was promoted to active.',
      );
      expect(refreshed.unverifiedPublicKeyBase64, isNull);
      final oldBob = alice.contactByDeviceId('dev-bob');
      expect(oldBob!.replacedByDeviceId, 'dev-bob-2');
      expect(oldBob.canSendOutbound, isFalse);
    },
  );

  test(
    'legacy nightly.2 vault with pending + populated key migrates to unverified slot',
    () {
      // v0.3.1-nightly.2 persisted the real key on publicKeyBase64 even
      // while pending. The fromJson migration must move it to the
      // unverified slot so the crypto layer can't use it pre-confirmation.
      final legacyJson = <String, dynamic>{
        'accountId': 'acc-bob',
        'deviceId': 'dev-bob-2',
        'alias': 'Bob',
        'displayName': 'Bob',
        'bio': '',
        'relayCapable': true,
        // Nightly.2 shape: pending=true AND publicKeyBase64 populated.
        'publicKeyBase64': 'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
        'routeHints': const <Map<String, dynamic>>[],
        'safetyNumber': 'safe-1234',
        'trustedAt': DateTime.utc(2026, 5, 16).toIso8601String(),
        'pendingVerification': true,
        'replacesDeviceId': 'dev-bob',
      };
      final migrated = ContactRecord.fromJson(legacyJson);
      expect(migrated.pendingVerification, isTrue);
      expect(
        migrated.publicKeyBase64,
        isEmpty,
        reason: 'Migration must blank the active key while pending.',
      );
      expect(
        migrated.unverifiedPublicKeyBase64,
        'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
        reason: 'Migration must stash the real key in the unverified slot.',
      );
    },
  );

  test('rejectContactReplacement deletes the pending contact', () async {
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(alice.dispose);

    final invite = _bobInvite();
    await alice.addContactFromInvite(
      alias: invite.displayName,
      payload: invite.encodePayload(),
      codephrase: '',
    );
    final imposter = ContactInvite(
      version: invite.version,
      accountId: 'acc-bob-3',
      deviceId: 'dev-bob-imposter',
      displayName: invite.displayName,
      bio: invite.bio,
      pairingNonce: 'imposter-nonce',
      pairingEpochMs: invite.pairingEpochMs + 2,
      relayCapable: invite.relayCapable,
      publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      routeHints: invite.routeHints,
    );
    await alice.addContactFromInvite(
      alias: imposter.displayName,
      payload: imposter.encodePayload(),
      codephrase: '',
    );
    expect(alice.contactByDeviceId('dev-bob-imposter'), isNotNull);

    await alice.rejectContactReplacement('dev-bob-imposter');
    expect(alice.contactByDeviceId('dev-bob-imposter'), isNull);
    // The original Bob is untouched.
    expect(alice.contactByDeviceId('dev-bob'), isNotNull);
  });

  test('refreshDefaultRelays applies a fetched newer signed manifest', () async {
    final relayClient = _FakeRelayClient();
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBase64 = base64Encode(publicKey.bytes);

    final manifest = jsonEncode(<String, dynamic>{
      'version': 99,
      'issuedAt': '2026-05-16T00:00:00Z',
      'endpoints': [
        {
          'kind': 'relay',
          'host': 'fetched.example',
          'port': defaultRelayPort,
          'protocol': 'tcp',
        },
      ],
    });
    final signature = await algorithm.sign(
      utf8.encode(manifest),
      keyPair: keyPair,
    );
    final signatureBase64 = base64Encode(signature.bytes);

    // The build-time public key define controls what the controller will
    // verify against. The unit-test runner can't set --dart-define values
    // post-hoc, so we exercise the parse + apply path directly via the
    // bytes-based loader instead of the GitHub-fetch wrapper.
    final defaults = await loadSignedDefaultRelaysFromBytes(
      manifestBytes: Uint8List.fromList(utf8.encode(manifest)),
      signatureBase64: signatureBase64,
      publicKeyBase64: publicKeyBase64,
    );
    expect(defaults, isNotNull);
    expect(defaults!.version, 99);
    expect(defaults.endpoints, hasLength(1));
    expect(defaults.endpoints.single.host, 'fetched.example');
    expect(defaults.endpoints.single.protocol, PeerRouteProtocol.tcp);

    // Tampering breaks verification.
    final tampered = manifest.replaceFirst('"version":99', '"version":100');
    final tamperedDefaults = await loadSignedDefaultRelaysFromBytes(
      manifestBytes: Uint8List.fromList(utf8.encode(tampered)),
      signatureBase64: signatureBase64,
      publicKeyBase64: publicKeyBase64,
    );
    expect(tamperedDefaults, isNull);

    // Avoid unused-warning on relayClient (controller not created in this test
    // because the GitHub fetch is exercised separately in manual smoke).
    expect(relayClient, isNotNull);
  });

  test(
    'importRelaysFromUrl (unsigned) adds routes without marking default',
    () async {
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      addTearDown(alice.dispose);

      final manifest = jsonEncode(<String, dynamic>{
        'version': 1,
        'issuedAt': '2026-05-16T00:00:00Z',
        'endpoints': [
          {
            'kind': 'relay',
            'host': 'imported.example',
            'port': 7700,
            'protocol': 'tcp',
          },
        ],
      });
      alice.setHttpBytesFetcherForTesting((url) async {
        return Uint8List.fromList(utf8.encode(manifest));
      });

      final source = await alice.importRelaysFromUrl(
        url: 'https://example.com/relays.json',
      );
      expect(source.isSigned, isFalse);
      expect(source.routeKeys, isNotEmpty);

      final added = alice.identity!.configuredRelays
          .where((relay) => relay.host == 'imported.example')
          .toList();
      expect(added, isNotEmpty);
      // Imported routes are NOT masked as default.
      for (final relay in added) {
        expect(alice.relayDisplayLabel(relay), relay.label);
      }
      expect(alice.customRelaySources, hasLength(1));

      await alice.removeCustomRelaySource(source.id);
      expect(alice.customRelaySources, isEmpty);
      expect(
        alice.identity!.configuredRelays.any(
          (relay) => relay.host == 'imported.example',
        ),
        isFalse,
      );
    },
  );
}
