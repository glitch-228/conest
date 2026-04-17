import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'local_relay_node.dart';
import 'models.dart';
import 'platform_bridge.dart';
import 'relay_client.dart';
import 'storage.dart';

List<int> _secureRandomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

const int _maxInviteRouteHints = 12;
const int _pairingBeaconPort = defaultRelayPort + 1;
const Duration _pairingBeaconTtl = Duration(seconds: 45);
const String _lanLobbyMailboxId = 'lan-lobby-v1';
const String _lanLobbyConversationId = 'conv-lan-lobby';
const Duration _slowPollInterval = Duration(seconds: 5);
const Duration _fastLocalPollInterval = Duration(milliseconds: 900);

class MessengerController extends ChangeNotifier {
  MessengerController({
    required VaultStore vaultStore,
    required RelayClient relayClient,
    LocalRelayNode? localRelayNode,
    PlatformBridge? platformBridge,
    Future<List<String>> Function()? lanAddressProvider,
  }) : _vaultStore = vaultStore,
       _relayClient = relayClient,
       _localRelayNode = localRelayNode ?? LocalRelayNode(),
       _platformBridge = platformBridge ?? PlatformBridge(),
       _lanAddressProvider = lanAddressProvider ?? discoverLanAddresses {
    _localRelayNode.onEnvelopeStored = _handleLocalEnvelopeStored;
  }

  final VaultStore _vaultStore;
  final RelayClient _relayClient;
  final LocalRelayNode _localRelayNode;
  final PlatformBridge _platformBridge;
  final Future<List<String>> Function() _lanAddressProvider;
  VaultSnapshot _snapshot = VaultSnapshot.empty();
  Timer? _pollTimer;
  Timer? _fastLocalPollTimer;
  bool _ready = false;
  bool _polling = false;
  bool _fastLocalPolling = false;
  String? _statusMessage;
  String _lastRelayStatus = 'relay not checked yet';
  String? _lastPairingAnnouncementMailboxId;
  DateTime? _lastPairingAnnouncementAt;
  final Map<String, PeerRouteHealth> _routeHealth = {};
  final Set<String> _debugProbeAcknowledgements = <String>{};
  final Set<String> _debugTwoWayReplies = <String>{};
  final Set<String> _locallyDeletedMessageIds = <String>{};
  final Map<String, _PairingBeaconRoute> _pairingBeaconRoutes = {};
  RawDatagramSocket? _pairingBeaconSocket;
  StreamSubscription<RawSocketEvent>? _pairingBeaconSubscription;
  Timer? _pairingBeaconTimer;
  SimpleKeyPairData? _lanLobbySigningKeyPair;
  String? _lanLobbyPublicKeyBase64;

  bool get isReady => _ready;
  bool get hasIdentity => _snapshot.identity != null;
  IdentityRecord? get identity => _snapshot.identity;
  List<ContactRecord> get contacts => List.unmodifiable(_snapshot.contacts);
  List<PeerEndpoint> get configuredRelays => List.unmodifiable(
    _snapshot.identity?.configuredRelays ?? const <PeerEndpoint>[],
  );
  String? get statusMessage => _statusMessage;
  String get lastRelayStatus => _lastRelayStatus;
  bool get localRelayRunning => _localRelayNode.isRunning;
  bool get pairingBeaconRunning => _pairingBeaconSocket != null;
  List<PeerEndpoint> get recentPairingBeaconRoutes =>
      _recentPairingBeaconRoutes();
  List<ChatMessage> get lanLobbyMessages => _lanLobbyMessages();
  bool get supportsScanner => !kIsWeb && Platform.isAndroid;
  List<PeerEndpoint> get discoveredContactRelayRoutes => _contactRelayRoutes();
  int get totalMessageCount => _snapshot.conversations.fold<int>(
    0,
    (count, conversation) => count + conversation.messages.length,
  );
  int get pendingOutboundCount => _snapshot.conversations.fold<int>(
    0,
    (count, conversation) =>
        count +
        conversation.messages
            .where(
              (message) =>
                  message.outbound && message.state == DeliveryState.pending,
            )
            .length,
  );
  int get seenEnvelopeCount => _snapshot.seenEnvelopeIds.length;
  PeerRouteHealth? routeHealthFor(PeerEndpoint route) =>
      _routeHealth[route.routeKey];
  @visibleForTesting
  void rememberPairingBeaconRouteForTesting(PeerEndpoint route) {
    _pairingBeaconRoutes[route.routeKey] = _PairingBeaconRoute(
      route: route,
      seenAt: DateTime.now().toUtc(),
    );
  }

  RelayCapabilityReport? get relayCapabilityReport {
    final me = identity;
    if (me == null) {
      return null;
    }
    final contactRelayCount = discoveredContactRelayRoutes.length;
    final notes = <String>[
      me.relayModeEnabled ? 'Relay mode enabled.' : 'Relay mode disabled.',
      localRelayRunning
          ? 'Local relay listening on :${me.localRelayPort}.'
          : 'Local relay is not running.',
      me.lanAddresses.isEmpty
          ? 'No LAN address detected.'
          : 'LAN addresses: ${me.lanAddresses.join(', ')}.',
      ...me.lanAddresses.map((address) {
        final summaries = _protocolRoutes(
          kind: PeerRouteKind.lan,
          host: address,
          port: me.localRelayPort,
        ).map((route) => _routeHealth[route.routeKey]?.summary).nonNulls;
        return summaries.isEmpty
            ? 'LAN reachability for $address not checked yet.'
            : summaries.join(' | ');
      }),
      me.configuredRelays.isEmpty
          ? 'No manually configured relay.'
          : '${me.configuredRelays.length} configured relay(s).',
      ...me.configuredRelays.map(
        (route) =>
            _routeHealth[route.routeKey]?.summary ??
            'Relay ${route.label} not checked yet.',
      ),
      if (_relayInstanceDebugSummary(minEndpoints: 2).isNotEmpty)
        'Same relay aliases: ${_relayInstanceDebugSummary(minEndpoints: 2)}.',
      me.autoUseContactRelays
          ? 'Using $contactRelayCount relay route(s) learned from contacts.'
          : 'Contact relays are not used automatically.',
      me.notificationsEnabled
          ? 'Message notifications are enabled.'
          : 'Message notifications are disabled.',
      me.androidBackgroundRuntimeEnabled
          ? 'Android background runtime is requested; system battery/background policy can still delay or block notifications.'
          : 'Android background runtime is off.',
      'Availability checks test local/LAN reachability plus configured internet relays. Public inbound reachability still requires a remote client or relay route to confirm.',
      if (!kIsWeb && Platform.isAndroid)
        'Android starts with relay mode off; enable it only when you want this device to relay.',
    ];
    final effectiveRelayCount = _effectiveRelayRoutesForIdentity(me).length;
    final canUseAsRelay =
        me.relayModeEnabled &&
        localRelayRunning &&
        me.lanAddresses.isNotEmpty &&
        me.lanAddresses.any((address) {
          return _protocolRoutes(
            kind: PeerRouteKind.lan,
            host: address,
            port: me.localRelayPort,
          ).any((route) => _routeHealth[route.routeKey]?.available ?? false);
        });
    final summary = !me.relayModeEnabled
        ? 'Relay mode is off.'
        : !localRelayRunning
        ? 'Relay mode is enabled but the local relay is not running.'
        : canUseAsRelay
        ? 'This device can relay traffic on the current LAN.'
        : effectiveRelayCount > 0
        ? 'This device can use relays, but it is not a strong relay candidate itself.'
        : 'No reachable relay path is configured yet.';
    return RelayCapabilityReport(
      canUseAsRelay: canUseAsRelay,
      summary: summary,
      notes: notes,
    );
  }

  Future<void> initialize() async {
    try {
      _snapshot = await _vaultStore.load();
      if (_snapshot.identity != null) {
        await _refreshLanAddresses(persist: false);
        await _ensureLocalRelayRunning();
        await _ensurePairingBeaconRunning();
        _applyAndroidBackgroundPreference();
        _startPolling();
        _startFastLocalPolling();
        unawaited(_sendPairingRouteBeacon());
        unawaited(_announcePairingAvailabilityIfNeeded(force: true));
        unawaited(pollNow());
      }
    } catch (error) {
      _statusMessage = 'Vault unlock failed: $error';
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  void setStatus(String? value) {
    _statusMessage = value;
    notifyListeners();
  }

  Future<void> refreshPairingAdvertisement() async {
    if (!hasIdentity) {
      return;
    }
    await _refreshLanAddresses(persist: false);
    await _ensureLocalRelayRunning();
    await _ensurePairingBeaconRunning();
    await _sendPairingRouteBeacon();
    await _announcePairingAvailabilityIfNeeded();
  }

  Future<ContactInvite> rotatePairingCodeNow() async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(
        pairingNonce: _randomId('pairnonce'),
        pairingEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      ),
    );
    _lastPairingAnnouncementMailboxId = null;
    _lastPairingAnnouncementAt = null;
    await _refreshLanAddresses(persist: false);
    await _ensureLocalRelayRunning();
    await _ensurePairingBeaconRunning();
    await _sendPairingRouteBeacon();
    await _announcePairingAvailabilityIfNeeded(force: true);
    await _persist('Pairing code rotated and advertised.');
    return _inviteForIdentity(_requireIdentity());
  }

  String buildDebugSnapshotText({DebugRunReport? report}) {
    final buffer = StringBuffer();
    final me = identity;
    buffer.writeln('Conest debug snapshot');
    buffer.writeln('generatedAt=${DateTime.now().toUtc().toIso8601String()}');
    buffer.writeln('buildMode=${kDebugMode ? 'debug' : 'release'}');
    buffer.writeln('platform=${kIsWeb ? 'web' : Platform.operatingSystem}');
    buffer.writeln('ready=$isReady');
    buffer.writeln('hasIdentity=$hasIdentity');
    buffer.writeln('status=${statusMessage ?? '(none)'}');
    buffer.writeln('lastRelayStatus=$lastRelayStatus');
    buffer.writeln('localRelayRunning=$localRelayRunning');
    if (me != null) {
      buffer.writeln('accountId=${me.accountId}');
      buffer.writeln('deviceId=${me.deviceId}');
      buffer.writeln('displayName=${me.displayName}');
      buffer.writeln('bioLength=${me.bio.length}');
      buffer.writeln('pairingEpochMs=${me.pairingEpochMs}');
      buffer.writeln('relayModeEnabled=${me.relayModeEnabled}');
      buffer.writeln('autoUseContactRelays=${me.autoUseContactRelays}');
      buffer.writeln('notificationsEnabled=${me.notificationsEnabled}');
      buffer.writeln(
        'androidBackgroundRuntimeEnabled=${me.androidBackgroundRuntimeEnabled}',
      );
      buffer.writeln('localRelayPort=${me.localRelayPort}');
      buffer.writeln('lanAddresses=${me.lanAddresses.join(', ')}');
      buffer.writeln('pairingBeaconRunning=$pairingBeaconRunning');
      buffer.writeln(
        'pairingBeaconRoutes=${recentPairingBeaconRoutes.map((route) => route.label).join(', ')}',
      );
      buffer.writeln(
        'configuredRelays=${me.configuredRelays.map((route) => '${route.kind.name}:${route.label}').join(', ')}',
      );
      final relayInstances = _relayInstanceDebugSummary(minEndpoints: 2);
      if (relayInstances.isNotEmpty) {
        buffer.writeln('relayAliases=$relayInstances');
      }
      buffer.writeln('safety=${me.safetyNumber}');
    }
    buffer.writeln('contacts=${contacts.length}');
    for (final contact in contacts) {
      buffer.writeln(
        'contact alias=${contact.alias} device=${contact.deviceId} relayCapable=${contact.relayCapable} routes=${contact.prioritizedRouteHints.map((route) => '${route.kind.name}:${route.label}:${routeHealthFor(route)?.summary ?? 'not checked'}').join(' | ')}',
      );
    }
    buffer.writeln('totalMessages=$totalMessageCount');
    buffer.writeln('pendingOutbound=$pendingOutboundCount');
    buffer.writeln('lanLobbyMessages=${lanLobbyMessages.length}');
    buffer.writeln('seenEnvelopes=$seenEnvelopeCount');
    buffer.writeln('debugProbeAcks=${_debugProbeAcknowledgements.length}');
    buffer.writeln('debugTwoWayReplies=${_debugTwoWayReplies.length}');
    if (report != null) {
      buffer.writeln(
        'lastDebugRunStarted=${report.startedAt.toIso8601String()}',
      );
      buffer.writeln(
        'lastDebugRunCompleted=${report.completedAt.toIso8601String()}',
      );
      buffer.writeln(
        'lastDebugRunSummary=pass:${report.passed} warn:${report.warned} fail:${report.failed} skip:${report.skipped}',
      );
      for (final result in report.results) {
        buffer.writeln(
          'check status=${result.status.name} name=${result.name} detail=${result.detail}',
        );
      }
    }
    return buffer.toString();
  }

  Future<void> checkRelayAvailability() async {
    var me = _requireIdentity();
    await _ensureLocalRelayRunning();
    await _refreshLanAddresses(persist: false);
    final protocolRefresh = await _refreshConfiguredRelayProtocols(me);
    me = _requireIdentity();
    final routes = <PeerEndpoint>[
      if (_localRelayNode.isRunning)
        ..._protocolRoutes(
          kind: PeerRouteKind.lan,
          host: '127.0.0.1',
          port: me.localRelayPort,
        ),
      for (final address in me.lanAddresses)
        ..._protocolRoutes(
          kind: PeerRouteKind.lan,
          host: address,
          port: me.localRelayPort,
        ),
      ..._diagnosticRelayRoutesForIdentity(me),
    ];
    final checks = await Future.wait(
      dedupePeerEndpoints(routes).map(_checkRouteHealth),
    );
    final available = checks.where((check) => check.available).length;
    await _persist(
      'Checked ${checks.length} route(s); $available available. '
      '${protocolRefresh.addedRoutes.isEmpty ? 'No new relay protocols detected.' : 'Added ${protocolRefresh.addedRoutes.map((route) => route.label).join(', ')}.'}',
    );
  }

  Future<List<PeerRouteHealth>> checkContactRoutes(
    ContactRecord contact, {
    bool persist = true,
  }) async {
    await _refreshLanAddresses(persist: false);
    await _ensureLocalRelayRunning();
    await _ensurePairingBeaconRunning();
    final pingSent = await _sendPairingDiscoveryPing();
    if (pingSent) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final current = _contactByDeviceId(contact.deviceId) ?? contact;
    final checks = await _rankRouteHealthForDelivery(
      current.prioritizedRouteHints,
    );
    final routeUpdateSent = await _sendRouteUpdate(current, requestReply: true);
    if (persist) {
      final available = checks.where((check) => check.available).length;
      await _persist(
        checks.isEmpty
            ? 'No paths are advertised for ${current.alias}.'
            : 'Checked ${checks.length} path(s) for ${current.alias}; $available available. ${routeUpdateSent ? 'Route info exchange requested.' : 'Route info exchange could not be sent yet.'}',
      );
    } else {
      notifyListeners();
    }
    return checks;
  }

  Future<DebugRunReport> runDebugSelfTest() async {
    final startedAt = DateTime.now().toUtc();
    final results = <DebugCheckResult>[];

    void add(String name, DebugCheckStatus status, String detail) {
      results.add(DebugCheckResult(name: name, status: status, detail: detail));
    }

    if (!kDebugMode) {
      add(
        'Debug build gate',
        DebugCheckStatus.skip,
        'Debug diagnostics are disabled in release builds.',
      );
      return DebugRunReport(
        startedAt: startedAt,
        completedAt: DateTime.now().toUtc(),
        deviceCount: 0,
        results: results,
      );
    }

    final me = _snapshot.identity;
    if (me == null) {
      add(
        'Identity',
        DebugCheckStatus.fail,
        'No identity exists; create a device first.',
      );
      return DebugRunReport(
        startedAt: startedAt,
        completedAt: DateTime.now().toUtc(),
        deviceCount: 0,
        results: results,
      );
    }

    final platform = kIsWeb ? 'web' : Platform.operatingSystem;
    add(
      'Debug build gate',
      DebugCheckStatus.pass,
      'Debug diagnostics are available on $platform.',
    );
    add(
      'Identity',
      DebugCheckStatus.pass,
      'Account ${me.accountId}, device ${me.deviceIdShort}, safety ${me.shortSafetyNumber}.',
    );

    try {
      await _vaultStore.save(_snapshot);
      add(
        'Encrypted vault write',
        DebugCheckStatus.pass,
        'Current vault snapshot was encrypted and written successfully.',
      );
    } catch (error) {
      add(
        'Encrypted vault write',
        DebugCheckStatus.fail,
        'Vault save failed: $error',
      );
    }

    try {
      final payload = _inviteForIdentity(me).encodePayload();
      final decoded = ContactInvite.decodePayload(payload);
      final code = currentPairingCodeSnapshotForPayload(payload).codephrase;
      add(
        'Invite codec',
        decoded.deviceId == me.deviceId
            ? DebugCheckStatus.pass
            : DebugCheckStatus.fail,
        'Invite payload round-tripped; current codephrase is $code.',
      );
    } catch (error) {
      add('Invite codec', DebugCheckStatus.fail, 'Invite failed: $error');
    }

    final pairingLoopback = await _runPairingAnnouncementLoopbackCheck(
      _requireIdentity(),
    );
    add(pairingLoopback.name, pairingLoopback.status, pairingLoopback.detail);

    try {
      await _refreshLanAddresses(persist: false);
      final current = _requireIdentity();
      add(
        'LAN addresses',
        current.lanAddresses.isEmpty
            ? DebugCheckStatus.warn
            : DebugCheckStatus.pass,
        current.lanAddresses.isEmpty
            ? 'No LAN addresses were detected.'
            : current.lanAddresses.join(', '),
      );
    } catch (error) {
      add('LAN addresses', DebugCheckStatus.fail, 'LAN scan failed: $error');
    }

    final pairingBeacon = await _runPairingBeaconCheck();
    add(pairingBeacon.name, pairingBeacon.status, pairingBeacon.detail);

    try {
      await _ensureLocalRelayRunning();
      final current = _requireIdentity();
      add(
        'Local relay runtime',
        localRelayRunning ? DebugCheckStatus.pass : DebugCheckStatus.fail,
        localRelayRunning
            ? 'LAN/direct listener is on :${current.localRelayPort}; relay-capable advertisement is ${current.relayModeEnabled ? 'on' : 'off'}.'
            : 'LAN/direct listener is not running.',
      );
    } catch (error) {
      add(
        'Local relay runtime',
        DebugCheckStatus.fail,
        'Local relay failed: $error',
      );
    }

    final relayProtocolRefresh = await _runRelayProtocolRediscoveryCheck(
      _requireIdentity(),
    );
    add(
      relayProtocolRefresh.name,
      relayProtocolRefresh.status,
      relayProtocolRefresh.detail,
    );

    final notificationRuntime = _runNotificationRuntimeCheck(
      _requireIdentity(),
    );
    add(
      notificationRuntime.name,
      notificationRuntime.status,
      notificationRuntime.detail,
    );

    final routeProtocolCoverage = _runRouteProtocolCoverageCheck(
      _requireIdentity(),
    );
    add(
      routeProtocolCoverage.name,
      routeProtocolCoverage.status,
      routeProtocolCoverage.detail,
    );

    final relayRoutes = _diagnosticRelayRoutesForIdentity(
      _requireIdentity(),
    ).where((route) => route.kind == PeerRouteKind.relay).toList();
    if (relayRoutes.isEmpty) {
      add(
        'Internet relay availability',
        DebugCheckStatus.skip,
        'No configured or contact-provided internet relay routes.',
      );
    } else {
      final checks = await _rankRouteHealthForDelivery(relayRoutes);
      final available = checks.where((check) => check.available).toList();
      add(
        'Internet relay availability',
        available.isEmpty ? DebugCheckStatus.warn : DebugCheckStatus.pass,
        checks.map((check) => check.summary).join(' | '),
      );
    }
    final relayAliasGrouping = _runRelayAliasGroupingCheck();
    add(
      relayAliasGrouping.name,
      relayAliasGrouping.status,
      relayAliasGrouping.detail,
    );

    if (contacts.isEmpty) {
      add(
        'Contact graph',
        DebugCheckStatus.skip,
        'No contacts. Only single-device checks can run.',
      );
    } else {
      add(
        'Contact graph',
        DebugCheckStatus.pass,
        'This device has ${contacts.length} trusted contact(s), so multi-device probes can run.',
      );
      var contactsWithPath = 0;
      for (final contact in contacts) {
        final checks = await checkContactRoutes(contact, persist: false);
        final available = checks.where((check) => check.available).toList();
        if (available.isNotEmpty) {
          contactsWithPath++;
        }
        add(
          'Paths to ${contact.alias}',
          available.isEmpty ? DebugCheckStatus.warn : DebugCheckStatus.pass,
          checks.isEmpty
              ? 'No advertised paths.'
              : checks.map((check) => check.summary).join(' | '),
        );
      }
      add(
        'Two-device readiness',
        contactsWithPath == contacts.length
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        '$contactsWithPath/${contacts.length} contact(s) have at least one currently available path.',
      );

      var probesAccepted = 0;
      var relayProbesAccepted = 0;
      var twoWayAccepted = 0;
      for (final contact in contacts) {
        if (await _sendDebugProbe(contact: contact)) {
          probesAccepted++;
        }
        if (await _sendDebugProbe(contact: contact, relayOnly: true)) {
          relayProbesAccepted++;
        }
        if (await _sendDebugTwoWayMessage(contact)) {
          twoWayAccepted++;
        }
      }
      if ((probesAccepted > 0 && _debugProbeAcknowledgements.isEmpty) ||
          (twoWayAccepted > 0 && _debugTwoWayReplies.isEmpty)) {
        await _waitForDebugResponses();
      }
      add(
        'Debug peer probes',
        probesAccepted == 0 ? DebugCheckStatus.warn : DebugCheckStatus.pass,
        'Accepted $probesAccepted/${contacts.length} probe send(s). Remote debug builds answer when they poll.',
      );
      add(
        'Debug probe acknowledgements',
        _debugProbeAcknowledgements.isEmpty
            ? DebugCheckStatus.warn
            : DebugCheckStatus.pass,
        _debugProbeAcknowledgements.isEmpty
            ? 'No debug probe acknowledgements received yet.'
            : '${_debugProbeAcknowledgements.length} debug acknowledgement(s) received.',
      );
      add(
        'Two-way debug messaging',
        twoWayAccepted == 0 ? DebugCheckStatus.warn : DebugCheckStatus.pass,
        'Sent $twoWayAccepted/${contacts.length} debug message request(s). Remote debug builds send a reply when they poll.',
      );
      add(
        'Two-way debug replies',
        _debugTwoWayReplies.isEmpty
            ? DebugCheckStatus.warn
            : DebugCheckStatus.pass,
        _debugTwoWayReplies.isEmpty
            ? 'No two-way debug replies received yet.'
            : '${_debugTwoWayReplies.length} two-way reply/replies received.',
      );

      if (contacts.length >= 2) {
        add(
          'Three-device relay scenario',
          relayProbesAccepted == 0
              ? DebugCheckStatus.warn
              : DebugCheckStatus.pass,
          'Relay-forced probes accepted for $relayProbesAccepted/${contacts.length} contact(s). This covers relay store/send; remote poll covers final delivery.',
        );
      } else {
        add(
          'Three-device relay scenario',
          DebugCheckStatus.skip,
          'Need at least two contacts on this device to approximate a 3+ device relay scenario.',
        );
      }
    }

    final relayLoopback = await _runRelayLoopbackCheck(_requireIdentity());
    add(relayLoopback.name, relayLoopback.status, relayLoopback.detail);
    final relayPairingReuse = await _runRelayPairingReuseCheck(
      _requireIdentity(),
    );
    add(
      relayPairingReuse.name,
      relayPairingReuse.status,
      relayPairingReuse.detail,
    );

    final canceledVisible = _snapshot.conversations.fold<int>(
      0,
      (count, conversation) =>
          count +
          conversation.messages
              .where((message) => message.state == DeliveryState.canceled)
              .length,
    );
    final deletedVisible = _snapshot.conversations.fold<int>(
      0,
      (count, conversation) =>
          count +
          conversation.messages
              .where(
                (message) => _locallyDeletedMessageIds.contains(message.id),
              )
              .length,
    );
    add(
      'Message action state',
      canceledVisible == 0 && deletedVisible == 0
          ? DebugCheckStatus.pass
          : DebugCheckStatus.warn,
      'Visible canceled messages: $canceledVisible; visible deleted tombstones: $deletedVisible. Cancel/delete should remove messages from the local conversation.',
    );

    add(
      'Message queue',
      pendingOutboundCount == 0 ? DebugCheckStatus.pass : DebugCheckStatus.warn,
      '$pendingOutboundCount pending outbound message(s), $totalMessageCount total message(s).',
    );

    await _persist(
      'Debug test finished: ${results.where((result) => result.status == DebugCheckStatus.fail).length} failed, ${results.where((result) => result.status == DebugCheckStatus.warn).length} warning(s).',
    );

    return DebugRunReport(
      startedAt: startedAt,
      completedAt: DateTime.now().toUtc(),
      deviceCount: contacts.length + 1,
      results: results,
    );
  }

  Future<void> updateDisplayName(String displayName) async {
    final me = _requireIdentity();
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Display name is required.');
    }
    _snapshot = _snapshot.copyWith(identity: me.copyWith(displayName: trimmed));
    await _announcePairingAvailabilityIfNeeded(force: true);
    await _persist('Display name updated.');
  }

  Future<void> updateBio(String bio) async {
    final me = _requireIdentity();
    final trimmed = bio.trim();
    _snapshot = _snapshot.copyWith(identity: me.copyWith(bio: trimmed));
    await _announcePairingAvailabilityIfNeeded(force: true);
    await _persist(trimmed.isEmpty ? 'Bio cleared.' : 'Bio updated.');
  }

  Future<void> updateContactProfile({
    required String deviceId,
    required String alias,
    required String bio,
  }) async {
    final index = _snapshot.contacts.indexWhere(
      (contact) => contact.deviceId == deviceId,
    );
    if (index == -1) {
      throw ArgumentError('Contact no longer exists.');
    }
    final current = _snapshot.contacts[index];
    final trimmedAlias = alias.trim();
    final contacts = List<ContactRecord>.from(_snapshot.contacts);
    contacts[index] = current.copyWith(
      alias: trimmedAlias.isEmpty ? current.displayName : trimmedAlias,
      bio: bio.trim(),
    );
    _snapshot = _snapshot.copyWith(contacts: contacts);
    await _persist('Contact profile updated.');
  }

  Future<void> updateRelayModeEnabled(bool enabled) async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(relayModeEnabled: enabled),
    );
    await _ensureLocalRelayRunning();
    await _announcePairingAvailabilityIfNeeded(force: true);
    await _persist(enabled ? 'Relay mode enabled.' : 'Relay mode disabled.');
  }

  Future<void> updateAutoUseContactRelays(bool enabled) async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(autoUseContactRelays: enabled),
    );
    await _announcePairingAvailabilityIfNeeded(force: true);
    await _persist(
      enabled
          ? 'Contacts can now contribute relay routes automatically.'
          : 'Automatic contact relay usage disabled.',
    );
  }

  Future<void> updateNotificationsEnabled(bool enabled) async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(notificationsEnabled: enabled),
    );
    if (enabled) {
      await _platformBridge.requestNotificationPermission();
    }
    await _persist(
      enabled
          ? 'Notifications enabled.'
          : 'Notifications disabled for this device.',
    );
  }

  Future<void> updateAndroidBackgroundRuntimeEnabled(bool enabled) async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(androidBackgroundRuntimeEnabled: enabled),
    );
    if (enabled) {
      await _platformBridge.requestNotificationPermission();
    }
    await _platformBridge.setAndroidBackgroundRuntimeEnabled(enabled);
    await _persist(
      enabled
          ? 'Android background runtime enabled. If system battery/background access is blocked, notifications can still be late or never arrive.'
          : 'Android background runtime disabled.',
    );
  }

  Future<void> updateLocalRelayPort(int port) async {
    if (port <= 0 || port > 65535) {
      throw ArgumentError('Relay port must be between 1 and 65535.');
    }
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(identity: me.copyWith(localRelayPort: port));
    await _ensureLocalRelayRunning();
    await _announcePairingAvailabilityIfNeeded(force: true);
    await _persist('Local relay port updated to $port.');
  }

  Future<void> addRelay({required String host, required int port}) async {
    final me = _requireIdentity();
    final relays = await _relayRoutesFromInput(
      host: host,
      port: port,
      detectProtocols: true,
    );
    if (relays.isEmpty) {
      throw ArgumentError('Relay host is required.');
    }
    final updated = dedupePeerEndpoints([...me.configuredRelays, ...relays]);
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(configuredRelays: updated),
    );
    await _announcePairingAvailabilityIfNeeded(force: true);
    await _persist(
      relays.length == 1
          ? 'Relay ${relays.first.label} added.'
          : 'Relay ${relays.first.host}:${relays.first.port} added for ${_protocolSummary(relays)}.',
    );
  }

  Future<List<PeerEndpoint>> _relayRoutesFromInput({
    required String host,
    required int port,
    bool detectProtocols = false,
  }) async {
    final parsed = parsePeerEndpointInput(host: host, fallbackPort: port);
    if (parsed.host.isEmpty) {
      return const <PeerEndpoint>[];
    }
    if (parsed.port <= 0 || parsed.port > 65535) {
      throw ArgumentError('Relay port must be between 1 and 65535.');
    }
    if (parsed.hasExplicitProtocol) {
      return <PeerEndpoint>[
        PeerEndpoint(
          kind: PeerRouteKind.relay,
          host: parsed.host,
          port: parsed.port,
          protocol: parsed.protocol,
        ),
      ];
    }
    final candidates = <PeerEndpoint>[
      PeerEndpoint(
        kind: PeerRouteKind.relay,
        host: parsed.host,
        port: parsed.port,
      ),
      PeerEndpoint(
        kind: PeerRouteKind.relay,
        host: parsed.host,
        port: parsed.port,
        protocol: PeerRouteProtocol.udp,
      ),
    ];
    if (!detectProtocols) {
      return candidates;
    }
    final checks = await Future.wait(
      candidates.map((route) => _checkRouteHealth(route)),
    );
    final detected = checks
        .where((check) => check.available)
        .map((check) => check.route)
        .toList(growable: false);
    if (detected.isEmpty) {
      throw ArgumentError(
        'Relay ${parsed.host}:${parsed.port} did not answer over TCP or UDP. '
        'Check the tunnel/origin, or use tcp://host:port or udp://host:port to force a protocol.',
      );
    }
    return detected;
  }

  String _protocolSummary(List<PeerEndpoint> routes) {
    final protocols = routes.map((route) => route.protocol.name.toUpperCase());
    return protocols.join('+');
  }

  Future<_RelayProtocolRefreshResult> _refreshConfiguredRelayProtocols(
    IdentityRecord me,
  ) async {
    final candidates = _relayProtocolCandidatesFor(me.configuredRelays);
    if (candidates.isEmpty) {
      return const _RelayProtocolRefreshResult(
        checkedRoutes: 0,
        availableRoutes: 0,
        addedRoutes: <PeerEndpoint>[],
      );
    }
    final checks = await Future.wait(candidates.map(_checkRouteHealth));
    final available = checks
        .where((check) => check.available)
        .map((check) => check.route)
        .toList(growable: false);
    final existingKeys = me.configuredRelays
        .map((route) => route.routeKey)
        .toSet();
    final added = available
        .where((route) => !existingKeys.contains(route.routeKey))
        .toList(growable: false);
    if (added.isNotEmpty) {
      final updated = dedupePeerEndpoints([...me.configuredRelays, ...added]);
      _snapshot = _snapshot.copyWith(
        identity: me.copyWith(configuredRelays: updated),
      );
      await _announcePairingAvailabilityIfNeeded(force: true);
    }
    return _RelayProtocolRefreshResult(
      checkedRoutes: checks.length,
      availableRoutes: available.length,
      addedRoutes: added,
    );
  }

  List<PeerEndpoint> _relayProtocolCandidatesFor(
    Iterable<PeerEndpoint> routes,
  ) {
    final hostPorts = <String, ({String host, int port})>{};
    for (final route in routes) {
      if (route.kind != PeerRouteKind.relay) {
        continue;
      }
      hostPorts['${route.host}:${route.port}'] = (
        host: route.host,
        port: route.port,
      );
    }
    return dedupePeerEndpoints(
      hostPorts.values.expand(
        (endpoint) => _protocolRoutes(
          kind: PeerRouteKind.relay,
          host: endpoint.host,
          port: endpoint.port,
        ),
      ),
    );
  }

  List<PeerEndpoint> _protocolRoutes({
    required PeerRouteKind kind,
    required String host,
    required int port,
  }) {
    return <PeerEndpoint>[
      PeerEndpoint(kind: kind, host: host, port: port),
      PeerEndpoint(
        kind: kind,
        host: host,
        port: port,
        protocol: PeerRouteProtocol.udp,
      ),
    ];
  }

  Future<void> removeRelay(PeerEndpoint relay) async {
    final me = _requireIdentity();
    final updated = me.configuredRelays
        .where((candidate) => candidate.routeKey != relay.routeKey)
        .toList();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(configuredRelays: updated),
    );
    await _announcePairingAvailabilityIfNeeded(force: true);
    await _persist('Relay ${relay.label} removed.');
  }

  Future<void> removeContact(String deviceId, {bool notifyPeer = true}) async {
    ContactRecord? removed;
    for (final contact in _snapshot.contacts) {
      if (contact.deviceId == deviceId) {
        removed = contact;
        break;
      }
    }
    var remoteNotified = false;
    if (notifyPeer && removed != null) {
      remoteNotified = await _sendContactRemoval(removed);
    }
    final contacts = _snapshot.contacts
        .where((contact) => contact.deviceId != deviceId)
        .toList();
    final conversations = _snapshot.conversations
        .where((conversation) => conversation.peerDeviceId != deviceId)
        .toList();
    _snapshot = _snapshot.copyWith(
      contacts: contacts,
      conversations: conversations,
    );
    _routeHealth.removeWhere((key, _) {
      final contact = removed;
      if (contact == null) {
        return false;
      }
      return contact.routeHints.any((route) => route.routeKey == key);
    });
    await _persist(
      notifyPeer && removed != null
          ? remoteNotified
                ? 'Contact removed here and removal was sent to the other side.'
                : 'Contact removed here. The other side could not be notified yet.'
          : 'Contact removed.',
    );
  }

  Future<void> resetIdentity() async {
    _pollTimer?.cancel();
    _fastLocalPollTimer?.cancel();
    await _platformBridge.setAndroidBackgroundRuntimeEnabled(false);
    await _stopPairingBeacon();
    await _localRelayNode.stop();
    await _vaultStore.clear();
    _snapshot = VaultSnapshot.empty();
    _polling = false;
    _lastPairingAnnouncementMailboxId = null;
    _lastPairingAnnouncementAt = null;
    _lastRelayStatus = 'relay not checked yet';
    _statusMessage = null;
    notifyListeners();
  }

  Future<void> createIdentity({
    required String displayName,
    String? internetRelayHost,
    int? internetRelayPort,
    int localRelayPort = defaultRelayPort,
    bool detectRelayProtocols = false,
  }) async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final keyPairData = await keyPair.extract();
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBase64 = base64Encode(publicKey.bytes);
    final accountId = _randomId('acc');
    final deviceId = _randomId('dev');
    final lanAddresses = await _lanAddressProvider();
    final safetyNumber = await _deriveSafetyNumber([publicKey.bytes]);
    final normalizedRelayHost = internetRelayHost?.trim().isEmpty ?? true
        ? null
        : internetRelayHost!.trim();
    final configuredRelays = normalizedRelayHost == null
        ? const <PeerEndpoint>[]
        : await _relayRoutesFromInput(
            host: normalizedRelayHost,
            port: internetRelayPort ?? defaultRelayPort,
            detectProtocols: detectRelayProtocols,
          );
    final relayModeEnabled = _defaultRelayModeEnabled();
    final created = IdentityRecord(
      accountId: accountId,
      deviceId: deviceId,
      displayName: displayName,
      bio: '',
      pairingNonce: _randomId('pairnonce'),
      pairingEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      publicKeyBase64: publicKeyBase64,
      privateKeyBase64: base64Encode(keyPairData.bytes),
      configuredRelays: configuredRelays,
      localRelayPort: localRelayPort,
      relayModeEnabled: relayModeEnabled,
      autoUseContactRelays: true,
      notificationsEnabled: true,
      androidBackgroundRuntimeEnabled: false,
      lanAddresses: lanAddresses,
      safetyNumber: safetyNumber,
      createdAt: DateTime.now().toUtc(),
    );
    _snapshot = _snapshot.copyWith(identity: created);
    await _ensureLocalRelayRunning();
    await _ensurePairingBeaconRunning();
    await _sendPairingRouteBeacon();
    await _announcePairingAvailabilityIfNeeded(force: true);
    _applyAndroidBackgroundPreference();
    await _persist(
      'Device created. Share a QR invite or the current codephrase to add this contact.',
    );
    _startPolling();
    _startFastLocalPolling();
    await pollNow();
  }

  Future<ContactInvite> buildInvite() async {
    await _refreshLanAddresses();
    await _ensurePairingBeaconRunning();
    await _sendPairingRouteBeacon();
    await _announcePairingAvailabilityIfNeeded(force: true);
    return _inviteForIdentity(_requireIdentity());
  }

  Future<ContactAdditionResult> addContactFromInvite({
    required String alias,
    required String payload,
    required String codephrase,
  }) async {
    final normalizedPayload = payload.trim();
    final normalizedCodephrase = codephrase.trim();
    late final ContactInvite invite;
    if (normalizedPayload.isNotEmpty) {
      if (normalizedCodephrase.isNotEmpty &&
          !matchesDynamicCodephraseForPayload(
            normalizedPayload,
            normalizedCodephrase,
          )) {
        throw ArgumentError(
          'Codephrase mismatch. Clear it and trust the QR invite alone, or compare the current code again.',
        );
      }
      invite = ContactInvite.decodePayload(normalizedPayload);
    } else {
      if (normalizedCodephrase.isEmpty) {
        throw ArgumentError(
          'Scan a QR / paste a payload, or enter a codephrase.',
        );
      }
      invite = await _resolveInviteByCodephrase(normalizedCodephrase);
    }
    return _trustInvite(invite: invite, alias: alias);
  }

  Future<ContactAdditionResult> _trustInvite({
    required ContactInvite invite,
    required String alias,
    bool attemptReciprocalExchange = true,
  }) async {
    final me = _requireIdentity();
    if (invite.deviceId == me.deviceId) {
      throw ArgumentError('This invite belongs to the current device.');
    }
    if (_snapshot.contacts.any(
      (contact) => contact.deviceId == invite.deviceId,
    )) {
      throw ArgumentError('This contact is already trusted.');
    }

    final safetyNumber = await _deriveSafetyNumber([
      base64Decode(me.publicKeyBase64),
      base64Decode(invite.publicKeyBase64),
    ]);
    final contact = ContactRecord(
      accountId: invite.accountId,
      deviceId: invite.deviceId,
      alias: alias.trim().isEmpty ? invite.displayName : alias.trim(),
      displayName: invite.displayName,
      bio: invite.bio,
      relayCapable: invite.relayCapable,
      publicKeyBase64: invite.publicKeyBase64,
      routeHints: invite.routeHints,
      safetyNumber: safetyNumber,
      trustedAt: DateTime.now().toUtc(),
    );
    final conversations = List<ConversationRecord>.from(_snapshot.conversations)
      ..add(
        ConversationRecord(
          id: _conversationIdFor(contact.deviceId),
          kind: ConversationKind.direct,
          peerDeviceId: contact.deviceId,
          messages: const [],
        ),
      );
    final contacts = List<ContactRecord>.from(_snapshot.contacts)..add(contact);
    _snapshot = _snapshot.copyWith(
      contacts: contacts,
      conversations: conversations,
    );
    var exchangeStatus = ContactExchangeStatus.manualActionRequired;
    if (attemptReciprocalExchange) {
      exchangeStatus = await _sendReciprocalContactExchange(contact)
          ? ContactExchangeStatus.automatic
          : ContactExchangeStatus.manualActionRequired;
    }
    await _persist(
      exchangeStatus == ContactExchangeStatus.automatic
          ? 'Contact ${contact.alias} added. Your invite was sent back automatically.'
          : 'Contact ${contact.alias} added, but the other side still needs your invite from their side.',
    );
    return ContactAdditionResult(
      contact: contact,
      exchangeStatus: exchangeStatus,
    );
  }

  Future<void> sendMessage({
    required ContactRecord contact,
    required String body,
  }) async {
    final me = _requireIdentity();
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final message = ChatMessage(
      id: _randomId('msg'),
      conversationId: _conversationIdFor(contact.deviceId),
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      body: trimmed,
      outbound: true,
      state: DeliveryState.pending,
      createdAt: DateTime.now().toUtc(),
    );
    _upsertMessage(contact.deviceId, message);
    await _persist('Trying LAN first, then relay for ${contact.alias}.');

    final delivered = await _tryDeliverExistingMessage(
      contact: contact,
      message: message,
    );
    if (!delivered) {
      _updateMessageState(contact.deviceId, message.id, DeliveryState.pending);
      _lastRelayStatus = 'queued for retry';
      await _persist(
        'Message queued. The app will retry direct routes and relays while polling.',
      );
    }
  }

  Future<void> cancelPendingMessage({
    required ContactRecord contact,
    required String messageId,
  }) async {
    final message = _messageById(contact.deviceId, messageId);
    if (message == null || !message.outbound) {
      throw ArgumentError('Message not found.');
    }
    if (message.state != DeliveryState.pending) {
      throw ArgumentError('Only pending messages can be canceled.');
    }
    _deleteMessage(contact.deviceId, messageId);
    await _persist('Canceled and deleted pending message to ${contact.alias}.');
  }

  Future<void> deleteMessage({
    required ContactRecord contact,
    required String messageId,
  }) async {
    final message = _messageById(contact.deviceId, messageId);
    if (message == null) {
      throw ArgumentError('Message not found.');
    }
    _deleteMessage(contact.deviceId, messageId);
    await _persist('Message deleted locally.');

    if (!message.outbound || message.state == DeliveryState.pending) {
      return;
    }
    final sent = await _sendMessageDeletion(
      contact: contact,
      targetMessageId: messageId,
    );
    await _persist(
      sent
          ? 'Message deleted here and deletion was sent to ${contact.alias}.'
          : 'Message deleted here. Remote deletion could not be sent yet.',
    );
  }

  Future<void> editMessage({
    required ContactRecord contact,
    required String messageId,
    required String body,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Edited message cannot be empty.');
    }
    final message = _messageById(contact.deviceId, messageId);
    if (message == null || !message.outbound) {
      throw ArgumentError('Only your own messages can be edited.');
    }
    if (message.state == DeliveryState.canceled) {
      throw ArgumentError('Canceled messages cannot be edited.');
    }
    final editedAt = DateTime.now().toUtc();
    _updateMessageBody(
      contact.deviceId,
      messageId,
      body: trimmed,
      editedAt: editedAt,
    );
    await _persist('Message edited locally.');

    if (message.state == DeliveryState.pending) {
      return;
    }
    final me = _requireIdentity();
    final payload = jsonEncode({
      'targetMessageId': messageId,
      'body': trimmed,
      'editedAt': editedAt.toIso8601String(),
    });
    final envelope = await _encryptPayloadEnvelope(
      kind: 'message_edit',
      messageId: _randomId('edit'),
      conversationId: _conversationIdFor(contact.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: payload,
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: envelope,
      );
      await _persist('Message edit sent to ${contact.alias}.');
    } catch (error) {
      _statusMessage =
          'Edit saved locally; remote edit pending path failed: $error';
      notifyListeners();
    }
  }

  Future<bool> _sendMessageDeletion({
    required ContactRecord contact,
    required String targetMessageId,
  }) async {
    final me = _requireIdentity();
    final payload = jsonEncode({
      'targetMessageId': targetMessageId,
      'deletedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final envelope = await _encryptPayloadEnvelope(
      kind: 'message_delete',
      messageId: _randomId('del'),
      conversationId: _conversationIdFor(contact.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: payload,
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: envelope,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> sendLanLobbyMessage(String body) async {
    final me = _requireIdentity();
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return 0;
    }
    await _refreshLanAddresses(persist: false);
    await _ensureLocalRelayRunning();
    await _ensurePairingBeaconRunning();
    final pingSent = await _sendPairingDiscoveryPing();
    if (pingSent) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final messageId = _randomId('lanmsg');
    final createdAt = DateTime.now().toUtc();
    final keyPair = await _lanLobbyKeyPair();
    final publicKeyBase64 = _lanLobbyPublicKeyBase64!;
    final signablePayload = _lanLobbySignablePayload(
      messageId: messageId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      senderDisplayName: me.displayName,
      createdAt: createdAt,
      body: trimmed,
      publicKeyBase64: publicKeyBase64,
    );
    final signature = await Ed25519().sign(
      _lanLobbySignableBytes(signablePayload),
      keyPair: keyPair,
    );
    final payload = Map<String, dynamic>.from(signablePayload)
      ..['signatureBase64'] = base64Encode(signature.bytes);
    final envelope = RelayEnvelope(
      kind: 'lan_lobby_message',
      messageId: messageId,
      conversationId: _lanLobbyConversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: _lanLobbyMailboxId,
      createdAt: createdAt,
      payloadBase64: base64Encode(utf8.encode(jsonEncode(payload))),
    );
    final localMessage = ChatMessage(
      id: messageId,
      conversationId: _lanLobbyConversationId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: _lanLobbyMailboxId,
      body: trimmed,
      outbound: true,
      state: DeliveryState.local,
      createdAt: createdAt,
      senderDisplayName: me.displayName,
      untrusted: true,
    );
    _upsertLanLobbyMessage(localMessage);

    var accepted = 0;
    for (final route in _lanLobbyBroadcastRoutes()) {
      try {
        final stored = await _relayClient.storeEnvelope(
          host: route.host,
          port: route.port,
          protocol: route.protocol,
          recipientDeviceId: _lanLobbyMailboxId,
          envelope: envelope,
          timeout: const Duration(milliseconds: 900),
        );
        if (stored) {
          accepted++;
        }
      } catch (_) {
        // LAN lobby is opportunistic and never falls back to internet relays.
      }
    }
    await _persist(
      accepted == 0
          ? 'LAN lobby message saved locally; no nearby LAN participants were reachable.'
          : 'LAN lobby message sent to $accepted nearby route(s).',
    );
    return accepted;
  }

  Future<bool> _sendReciprocalContactExchange(ContactRecord contact) async {
    final me = _requireIdentity();
    final payload = _inviteForIdentity(me).encodePayload();
    final exchange = RelayEnvelope(
      kind: 'contact_exchange',
      messageId: _randomId('xchg'),
      conversationId: 'contact-exchange-${contact.deviceId}',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(utf8.encode(payload)),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: exchange,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _sendContactRemoval(ContactRecord contact) async {
    final me = _requireIdentity();
    final removal = RelayEnvelope(
      kind: 'contact_remove',
      messageId: _randomId('rm'),
      conversationId: _conversationIdFor(contact.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: removal,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _sendRouteUpdate(
    ContactRecord contact, {
    required bool requestReply,
  }) async {
    final me = _requireIdentity();
    final payload = jsonEncode({
      'invitePayload': _inviteForIdentity(me).encodePayload(),
      'requestReply': requestReply,
    });
    final update = RelayEnvelope(
      kind: 'route_update',
      messageId: _randomId('route'),
      conversationId: 'route-update-${contact.deviceId}',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(utf8.encode(payload)),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: update,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> pollNow() async {
    if (_polling || !hasIdentity) {
      return;
    }
    _polling = true;
    notifyListeners();
    try {
      await _ensureLocalRelayRunning();
      await _refreshLanAddresses(persist: false);
      await _ensurePairingBeaconRunning();
      await _sendPairingRouteBeacon();
      unawaited(_announcePairingAvailabilityIfNeeded());
      final me = _requireIdentity();
      final pollRoutes = _pollRoutesForIdentity(me);
      var processed = 0;
      bool? internetRelayHealthy;
      final routeNotes = <String>[];

      for (final route in pollRoutes) {
        try {
          if (_shouldSkipSlowPollRoute(route)) {
            continue;
          }
          final health = await _checkRouteHealth(route);
          if (route.kind == PeerRouteKind.relay) {
            internetRelayHealthy = health.available;
          }
          if (!health.available) {
            continue;
          }
          final envelopes = await _relayClient.fetchEnvelopes(
            host: route.host,
            port: route.port,
            protocol: route.protocol,
            recipientDeviceId: me.deviceId,
            timeout: route.kind == PeerRouteKind.lan
                ? const Duration(milliseconds: 900)
                : const Duration(seconds: 4),
          );
          processed += await _processEnvelopes(envelopes);
          if (envelopes.isNotEmpty) {
            routeNotes.add('${route.kind.name}:${route.host}');
          }
        } catch (_) {
          if (route.kind == PeerRouteKind.relay) {
            internetRelayHealthy = false;
          }
        }
      }
      processed += await _pollLanLobbyMailbox();
      await _retryPendingMessages();

      _lastRelayStatus = _networkSummary(
        me,
        internetRelayHealthy: internetRelayHealthy,
      );
      if (processed > 0) {
        await _persist(
          'Received $processed item(s) via ${routeNotes.isEmpty ? 'known routes' : routeNotes.join(', ')}.',
        );
      } else {
        notifyListeners();
      }
    } catch (error) {
      _lastRelayStatus = 'poll failed';
      _statusMessage = 'Route poll failed: $error';
      notifyListeners();
    } finally {
      _polling = false;
      notifyListeners();
    }
  }

  bool _shouldSkipSlowPollRoute(PeerEndpoint route) {
    if (route.kind == PeerRouteKind.lan) {
      return false;
    }
    final cached = _routeHealth[route.routeKey];
    if (cached == null || cached.available) {
      return false;
    }
    return DateTime.now().toUtc().difference(cached.checkedAt) <
        const Duration(seconds: 30);
  }

  List<ChatMessage> messagesFor(String peerDeviceId) {
    final conversation = _conversationFor(peerDeviceId);
    return List<ChatMessage>.from(conversation.messages)
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
  }

  ChatMessage? _messageById(String peerDeviceId, String messageId) {
    for (final message in _conversationFor(peerDeviceId).messages) {
      if (message.id == messageId) {
        return message;
      }
    }
    return null;
  }

  List<ChatMessage> _lanLobbyMessages() {
    for (final conversation in _snapshot.conversations) {
      if (conversation.kind == ConversationKind.lanLobby) {
        return List<ChatMessage>.from(conversation.messages)
          ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
      }
    }
    return const <ChatMessage>[];
  }

  ChatMessage? lastMessageFor(String peerDeviceId) {
    final messages = messagesFor(peerDeviceId);
    if (messages.isEmpty) {
      return null;
    }
    return messages.last;
  }

  ContactRecord? _contactByDeviceId(String deviceId) {
    for (final contact in _snapshot.contacts) {
      if (contact.deviceId == deviceId) {
        return contact;
      }
    }
    return null;
  }

  Future<int> _pollLanLobbyMailbox() async {
    final me = _snapshot.identity;
    if (me == null || !_localRelayNode.isRunning) {
      return 0;
    }
    try {
      final envelopes = await _relayClient.fetchEnvelopes(
        host: '127.0.0.1',
        port: me.localRelayPort,
        protocol: PeerRouteProtocol.tcp,
        recipientDeviceId: _lanLobbyMailboxId,
        timeout: const Duration(milliseconds: 900),
      );
      return _processEnvelopes(envelopes);
    } catch (_) {
      return 0;
    }
  }

  Future<void> _ensureLocalRelayRunning() async {
    final me = _snapshot.identity;
    if (me == null) {
      return;
    }
    if (_localRelayNode.isRunning &&
        _localRelayNode.port == me.localRelayPort) {
      return;
    }
    await _localRelayNode.start(me.localRelayPort);
  }

  Future<void> _ensurePairingBeaconRunning() async {
    if (kIsWeb || _pairingBeaconSocket != null) {
      return;
    }
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _pairingBeaconPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      _pairingBeaconSocket = socket;
      _pairingBeaconSubscription = socket.listen(
        (event) {
          if (event != RawSocketEvent.read) {
            return;
          }
          Datagram? datagram;
          while ((datagram = socket.receive()) != null) {
            _handlePairingBeaconDatagram(datagram!);
          }
        },
        onError: (_) {
          unawaited(_stopPairingBeacon());
        },
        cancelOnError: false,
      );
      _pairingBeaconTimer?.cancel();
      _pairingBeaconTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_sendPairingRouteBeacon()),
      );
    } catch (_) {
      _pairingBeaconSocket = null;
    }
  }

  Future<void> _stopPairingBeacon() async {
    _pairingBeaconTimer?.cancel();
    _pairingBeaconTimer = null;
    final subscription = _pairingBeaconSubscription;
    _pairingBeaconSubscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
    _pairingBeaconSocket?.close();
    _pairingBeaconSocket = null;
    _pairingBeaconRoutes.clear();
  }

  void _handlePairingBeaconDatagram(Datagram datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      if (decoded['app'] != 'conest') {
        return;
      }
      final kind = decoded['kind'] as String?;
      final senderDeviceId = decoded['deviceId'] as String?;
      final me = _snapshot.identity;
      if (senderDeviceId != null && senderDeviceId == me?.deviceId) {
        return;
      }
      if (kind == 'pairing_ping') {
        unawaited(
          _sendPairingRouteBeacon(
            targetAddress: datagram.address,
            targetPort: datagram.port,
          ),
        );
        return;
      }
      if (kind != 'pairing_route') {
        return;
      }
      final port = decoded['relayPort'] as int?;
      if (port == null || port <= 0 || port > 65535) {
        return;
      }
      final host = datagram.address.address;
      if (!_isUsableLanBeaconHost(host)) {
        return;
      }
      final routes = <PeerEndpoint>[
        PeerEndpoint(kind: PeerRouteKind.lan, host: host, port: port),
        PeerEndpoint(
          kind: PeerRouteKind.lan,
          host: host,
          port: port,
          protocol: PeerRouteProtocol.udp,
        ),
      ];
      final seenAt = DateTime.now().toUtc();
      for (final route in routes) {
        _pairingBeaconRoutes[route.routeKey] = _PairingBeaconRoute(
          route: route,
          seenAt: seenAt,
        );
        if (senderDeviceId != null) {
          unawaited(
            _rememberContactLanRouteFromBeacon(
              deviceId: senderDeviceId,
              route: route,
            ),
          );
        }
      }
    } catch (_) {
      // LAN beacons are opportunistic; malformed datagrams are ignored.
    }
  }

  Future<void> _rememberContactLanRouteFromBeacon({
    required String deviceId,
    required PeerEndpoint route,
  }) async {
    final index = _snapshot.contacts.indexWhere(
      (contact) => contact.deviceId == deviceId,
    );
    if (index == -1) {
      return;
    }
    final contacts = List<ContactRecord>.from(_snapshot.contacts);
    final contact = contacts[index];
    if (contact.routeHints.any(
      (candidate) => candidate.routeKey == route.routeKey,
    )) {
      return;
    }
    contacts[index] = contact.copyWith(
      routeHints: dedupePeerEndpoints([route, ...contact.routeHints]),
    );
    _snapshot = _snapshot.copyWith(contacts: contacts);
    await _persist(
      'Rediscovered LAN route ${route.label} for ${contact.alias}.',
    );
  }

  Future<void> _sendPairingRouteBeacon({
    InternetAddress? targetAddress,
    int? targetPort,
  }) async {
    final me = _snapshot.identity;
    final socket = _pairingBeaconSocket;
    if (me == null || socket == null || !_localRelayNode.isRunning) {
      return;
    }
    final bytes = utf8.encode(
      jsonEncode({
        'app': 'conest',
        'kind': 'pairing_route',
        'version': 2,
        'deviceId': me.deviceId,
        'relayPort': me.localRelayPort,
        'protocols': ['tcp', 'udp'],
      }),
    );
    if (targetAddress != null) {
      try {
        socket.send(bytes, targetAddress, targetPort ?? _pairingBeaconPort);
      } catch (_) {
        // Best-effort only.
      }
      return;
    }
    for (final target in _pairingBroadcastTargets(me)) {
      try {
        socket.send(bytes, target, _pairingBeaconPort);
      } catch (_) {
        // Best-effort only.
      }
    }
  }

  Future<bool> _sendPairingDiscoveryPing() async {
    await _ensurePairingBeaconRunning();
    final me = _snapshot.identity;
    final socket = _pairingBeaconSocket;
    if (me == null || socket == null) {
      return false;
    }
    final bytes = utf8.encode(
      jsonEncode({
        'app': 'conest',
        'kind': 'pairing_ping',
        'version': 1,
        'deviceId': me.deviceId,
      }),
    );
    var sent = false;
    for (final target in _pairingBroadcastTargets(me)) {
      try {
        socket.send(bytes, target, _pairingBeaconPort);
        sent = true;
      } catch (_) {
        // Best-effort only.
      }
    }
    return sent;
  }

  List<PeerEndpoint> _recentPairingBeaconRoutes() {
    final cutoff = DateTime.now().toUtc().subtract(_pairingBeaconTtl);
    _pairingBeaconRoutes.removeWhere(
      (_, beacon) => beacon.seenAt.isBefore(cutoff),
    );
    return dedupePeerEndpoints(
      _pairingBeaconRoutes.values.map((beacon) => beacon.route),
    );
  }

  List<InternetAddress> _pairingBroadcastTargets(IdentityRecord me) {
    final targets = <String>{'255.255.255.255'};
    for (final address in me.lanAddresses) {
      final broadcast = _directedBroadcastAddress(address);
      if (broadcast != null) {
        targets.add(broadcast);
      }
    }
    return targets.map(InternetAddress.new).toList(growable: false);
  }

  String? _directedBroadcastAddress(String address) {
    final parts = address.split('.');
    if (parts.length != 4) {
      return null;
    }
    final octets = parts.map(int.tryParse).toList(growable: false);
    if (octets.any((octet) => octet == null || octet < 0 || octet > 255)) {
      return null;
    }
    return '${octets[0]}.${octets[1]}.${octets[2]}.255';
  }

  bool _isUsableLanBeaconHost(String host) {
    if (host == '127.0.0.1' || host == '0.0.0.0') {
      return false;
    }
    final parts = host.split('.');
    if (parts.length != 4) {
      return false;
    }
    final octets = parts.map(int.tryParse).toList(growable: false);
    if (octets.any((octet) => octet == null || octet < 0 || octet > 255)) {
      return false;
    }
    return true;
  }

  Future<void> _refreshLanAddresses({bool persist = true}) async {
    final me = _snapshot.identity;
    if (me == null) {
      return;
    }
    late final List<String> lanAddresses;
    try {
      lanAddresses = await _lanAddressProvider();
    } catch (error) {
      if (persist) {
        await _persist('LAN discovery unavailable: $error');
      }
      return;
    }
    final changed = !_sameAddresses(lanAddresses, me.lanAddresses);
    if (!changed) {
      return;
    }
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(lanAddresses: lanAddresses),
    );
    if (persist) {
      await _persist('Updated nearby LAN routes.');
    }
  }

  Future<int> _processEnvelopes(List<RelayEnvelope> envelopes) async {
    var processed = 0;
    final orderedEnvelopes = List<RelayEnvelope>.from(envelopes)
      ..sort((left, right) {
        final leftPriority = _processingPriority(left.kind);
        final rightPriority = _processingPriority(right.kind);
        return leftPriority.compareTo(rightPriority);
      });
    for (final envelope in orderedEnvelopes) {
      if (_snapshot.seenEnvelopeIds.contains(envelope.messageId)) {
        continue;
      }
      if (_locallyDeletedMessageIds.contains(envelope.messageId)) {
        _markSeen(envelope.messageId);
        continue;
      }
      processed++;
      if (envelope.kind == 'ack') {
        _updateMessageState(
          envelope.senderDeviceId,
          envelope.acknowledgedMessageId ?? '',
          DeliveryState.delivered,
        );
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'contact_exchange') {
        await _handleContactExchange(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'route_update') {
        await _handleRouteUpdate(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'lan_lobby_message') {
        await _handleLanLobbyMessage(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'contact_remove') {
        await _handleContactRemoval(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'message_edit') {
        await _handleMessageEdit(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'message_delete') {
        await _handleMessageDelete(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (kDebugMode && envelope.kind == 'debug_probe') {
        await _handleDebugProbe(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (kDebugMode && envelope.kind == 'debug_probe_ack') {
        _debugProbeAcknowledgements.add(
          envelope.acknowledgedMessageId ?? envelope.messageId,
        );
        _markSeen(envelope.messageId);
        continue;
      }

      if (kDebugMode && envelope.kind == 'debug_two_way_message') {
        await _handleDebugTwoWayMessage(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (kDebugMode && envelope.kind == 'debug_two_way_reply') {
        _debugTwoWayReplies.add(
          envelope.acknowledgedMessageId ?? envelope.messageId,
        );
        _markSeen(envelope.messageId);
        continue;
      }

      ContactRecord? contact;
      for (final candidate in _snapshot.contacts) {
        if (candidate.deviceId == envelope.senderDeviceId) {
          contact = candidate;
          break;
        }
      }
      if (contact == null) {
        continue;
      }

      final body = await _decryptMessage(contact: contact, envelope: envelope);
      final existingConversation = _conversationFor(contact.deviceId);
      final alreadyKnown = existingConversation.messages.any(
        (message) => message.id == envelope.messageId,
      );
      if (!alreadyKnown) {
        final inbound = ChatMessage(
          id: envelope.messageId,
          conversationId: envelope.conversationId,
          senderDeviceId: envelope.senderDeviceId,
          recipientDeviceId: envelope.recipientDeviceId,
          body: body,
          outbound: false,
          state: DeliveryState.delivered,
          createdAt: envelope.createdAt,
        );
        _upsertMessage(contact.deviceId, inbound);
        _showInboundMessageNotification(contact: contact, body: body);
        await _sendAck(contact: contact, envelope: envelope);
      }
      _markSeen(envelope.messageId);
    }
    return processed;
  }

  int _processingPriority(String kind) {
    switch (kind) {
      case 'contact_exchange':
        return 0;
      case 'route_update':
        return 0;
      case 'lan_lobby_message':
        return 0;
      case 'contact_remove':
        return 0;
      case 'message_edit':
        return 3;
      case 'message_delete':
        return 3;
      case 'ack':
        return 1;
      case 'debug_probe':
      case 'debug_probe_ack':
      case 'debug_two_way_message':
      case 'debug_two_way_reply':
        return 1;
      default:
        return 2;
    }
  }

  Future<void> _handleContactExchange(RelayEnvelope envelope) async {
    final rawPayload = envelope.payloadBase64;
    if (rawPayload == null || rawPayload.isEmpty) {
      return;
    }
    final payload = utf8.decode(base64Decode(rawPayload));
    final invite = ContactInvite.tryDecodePayload(payload);
    if (invite == null) {
      return;
    }
    final updated = await _updateExistingContactFromInvite(
      invite,
      statusBuilder: (contact) =>
          'Updated ${contact.alias} profile and route hints.',
    );
    if (updated != null) {
      return;
    }
    try {
      final result = await _trustInvite(
        invite: invite,
        alias: invite.displayName,
        attemptReciprocalExchange: false,
      );
      await _persist(
        '${result.contact.alias} appeared automatically after they added you.',
      );
    } catch (_) {
      // Ignore malformed or duplicate reciprocal contact exchange requests.
    }
  }

  Future<void> _handleRouteUpdate(RelayEnvelope envelope) async {
    final sender = _contactByDeviceId(envelope.senderDeviceId);
    if (sender == null) {
      return;
    }
    final rawPayload = envelope.payloadBase64;
    if (rawPayload == null || rawPayload.isEmpty) {
      return;
    }
    final decodedPayload = utf8.decode(base64Decode(rawPayload));
    String? invitePayload;
    var requestReply = false;
    try {
      final decoded = jsonDecode(decodedPayload);
      if (decoded is Map<String, dynamic>) {
        invitePayload = decoded['invitePayload'] as String?;
        requestReply = decoded['requestReply'] == true;
      }
    } catch (_) {
      invitePayload = decodedPayload;
    }
    if (invitePayload == null || invitePayload.isEmpty) {
      return;
    }
    final invite = ContactInvite.tryDecodePayload(invitePayload);
    if (invite == null || invite.deviceId != envelope.senderDeviceId) {
      return;
    }
    final updated = await _updateExistingContactFromInvite(
      invite,
      statusBuilder: (contact) =>
          'Updated ${contact.alias} route info after path rediscovery.',
    );
    final replyContact = updated ?? sender;
    if (requestReply) {
      await _sendRouteUpdate(replyContact, requestReply: false);
    }
  }

  Future<void> _handleLanLobbyMessage(RelayEnvelope envelope) async {
    try {
      final me = _snapshot.identity;
      if (me == null || envelope.senderDeviceId == me.deviceId) {
        return;
      }
      final rawPayload = envelope.payloadBase64;
      if (rawPayload == null || rawPayload.isEmpty) {
        return;
      }
      final decoded = jsonDecode(utf8.decode(base64Decode(rawPayload)));
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final body = decoded['body'] as String?;
      final senderDisplayName = decoded['senderDisplayName'] as String?;
      final publicKeyBase64 = decoded['publicKeyBase64'] as String?;
      final signatureBase64 = decoded['signatureBase64'] as String?;
      if (body == null ||
          body.trim().isEmpty ||
          senderDisplayName == null ||
          publicKeyBase64 == null ||
          signatureBase64 == null) {
        return;
      }
      final createdAt =
          DateTime.tryParse(decoded['createdAt'] as String? ?? '') ??
          envelope.createdAt;
      final signablePayload = _lanLobbySignablePayload(
        messageId: envelope.messageId,
        senderAccountId: envelope.senderAccountId,
        senderDeviceId: envelope.senderDeviceId,
        senderDisplayName: senderDisplayName,
        createdAt: createdAt,
        body: body,
        publicKeyBase64: publicKeyBase64,
      );
      final verified = await Ed25519().verify(
        _lanLobbySignableBytes(signablePayload),
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey: SimplePublicKey(
            base64Decode(publicKeyBase64),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!verified) {
        return;
      }
      _upsertLanLobbyMessage(
        ChatMessage(
          id: envelope.messageId,
          conversationId: _lanLobbyConversationId,
          senderDeviceId: envelope.senderDeviceId,
          recipientDeviceId: _lanLobbyMailboxId,
          body: body,
          outbound: false,
          state: DeliveryState.delivered,
          createdAt: createdAt,
          senderDisplayName: senderDisplayName,
          untrusted: true,
        ),
      );
    } catch (_) {
      // LAN lobby accepts untrusted LAN input; malformed messages are ignored.
    }
  }

  Future<ContactRecord?> _updateExistingContactFromInvite(
    ContactInvite invite, {
    required String Function(ContactRecord contact) statusBuilder,
  }) async {
    final existingIndex = _snapshot.contacts.indexWhere(
      (contact) => contact.deviceId == invite.deviceId,
    );
    if (existingIndex == -1) {
      return null;
    }
    final contacts = List<ContactRecord>.from(_snapshot.contacts);
    final existing = contacts[existingIndex];
    final updated = existing.copyWith(
      displayName: invite.displayName,
      bio: invite.bio.isEmpty ? existing.bio : invite.bio,
      relayCapable: invite.relayCapable,
      routeHints: invite.routeHints,
    );
    contacts[existingIndex] = updated;
    _snapshot = _snapshot.copyWith(contacts: contacts);
    await _persist(statusBuilder(updated));
    return updated;
  }

  Future<void> _handleContactRemoval(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) {
      return;
    }
    await removeContact(contact.deviceId, notifyPeer: false);
    await _persist('${contact.alias} removed you, so the contact was removed.');
  }

  Future<void> _handleMessageEdit(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) {
      return;
    }
    final decoded = await _decryptMessage(contact: contact, envelope: envelope);
    final payload = jsonDecode(decoded);
    if (payload is! Map<String, dynamic>) {
      return;
    }
    final targetMessageId = payload['targetMessageId'] as String?;
    final body = payload['body'] as String?;
    final editedAt =
        DateTime.tryParse(payload['editedAt'] as String? ?? '') ??
        envelope.createdAt;
    if (targetMessageId == null || targetMessageId.isEmpty || body == null) {
      return;
    }
    final existing = _messageById(contact.deviceId, targetMessageId);
    if (existing == null || existing.outbound) {
      return;
    }
    _updateMessageBody(
      contact.deviceId,
      targetMessageId,
      body: body,
      editedAt: editedAt,
    );
    await _persist('Updated edited message from ${contact.alias}.');
  }

  Future<void> _handleMessageDelete(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) {
      return;
    }
    final decoded = await _decryptMessage(contact: contact, envelope: envelope);
    final payload = jsonDecode(decoded);
    if (payload is! Map<String, dynamic>) {
      return;
    }
    final targetMessageId = payload['targetMessageId'] as String?;
    if (targetMessageId == null || targetMessageId.isEmpty) {
      return;
    }
    final existing = _messageById(contact.deviceId, targetMessageId);
    if (existing == null) {
      _locallyDeletedMessageIds.add(targetMessageId);
      _markSeen(targetMessageId);
      return;
    }
    if (existing.outbound) {
      return;
    }
    _deleteMessage(contact.deviceId, targetMessageId);
    await _persist('Deleted message removed by ${contact.alias}.');
  }

  void _showInboundMessageNotification({
    required ContactRecord contact,
    required String body,
  }) {
    final me = identity;
    if (me == null || !me.notificationsEnabled) {
      return;
    }
    unawaited(
      _platformBridge.showMessageNotification(
        title: contact.alias,
        body: body,
        conversationId: _conversationIdFor(contact.deviceId),
      ),
    );
  }

  Future<void> _handleDebugProbe(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) {
      return;
    }
    final me = _requireIdentity();
    final ack = RelayEnvelope(
      kind: 'debug_probe_ack',
      messageId: _randomId('dbgack'),
      conversationId: envelope.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
      acknowledgedMessageId: envelope.messageId,
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: ack,
      );
    } catch (_) {
      // Debug probes are diagnostic only.
    }
  }

  Future<void> _handleDebugTwoWayMessage(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) {
      return;
    }
    final me = _requireIdentity();
    final reply = RelayEnvelope(
      kind: 'debug_two_way_reply',
      messageId: _randomId('dbgreply'),
      conversationId: envelope.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
      acknowledgedMessageId: envelope.messageId,
      payloadBase64: base64Encode(
        utf8.encode(
          jsonEncode({
            'replyFrom': me.deviceId,
            'displayName': me.displayName,
            'receivedMessageId': envelope.messageId,
            'sentAt': DateTime.now().toUtc().toIso8601String(),
          }),
        ),
      ),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: reply,
      );
    } catch (_) {
      // Two-way debug replies are diagnostic only.
    }
  }

  Future<void> _sendAck({
    required ContactRecord contact,
    required RelayEnvelope envelope,
  }) async {
    final me = _requireIdentity();
    final ack = RelayEnvelope(
      kind: 'ack',
      messageId: _randomId('ack'),
      conversationId: envelope.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
      acknowledgedMessageId: envelope.messageId,
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: ack,
      );
    } catch (_) {
      // Best effort acking. Missed acks only affect sender-side state display.
    }
  }

  Future<bool> _sendDebugProbe({
    required ContactRecord contact,
    bool relayOnly = false,
  }) async {
    if (!kDebugMode) {
      return false;
    }
    final me = _requireIdentity();
    final probe = RelayEnvelope(
      kind: 'debug_probe',
      messageId: _randomId('dbg'),
      conversationId: 'debug-${me.deviceId}-${contact.deviceId}',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(
        utf8.encode(
          jsonEncode({
            'deviceId': me.deviceId,
            'displayName': me.displayName,
            'sentAt': DateTime.now().toUtc().toIso8601String(),
          }),
        ),
      ),
    );
    final checks = await _rankRouteHealthForDelivery(
      contact.prioritizedRouteHints,
    );
    final routes = checks
        .where(
          (check) =>
              check.available &&
              (!relayOnly ||
                  check.route.kind == PeerRouteKind.relay ||
                  contact.relayCapable),
        )
        .map((check) => check.route)
        .toList(growable: false);
    if (routes.isEmpty) {
      return false;
    }
    try {
      await _deliverAcrossRoutes(
        routes: routes,
        recipientDeviceId: contact.deviceId,
        envelope: probe,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _sendDebugTwoWayMessage(ContactRecord contact) async {
    if (!kDebugMode) {
      return false;
    }
    final me = _requireIdentity();
    final probe = RelayEnvelope(
      kind: 'debug_two_way_message',
      messageId: _randomId('dbgtwoway'),
      conversationId: 'debug-two-way-${me.deviceId}-${contact.deviceId}',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(
        utf8.encode(
          jsonEncode({
            'from': me.deviceId,
            'displayName': me.displayName,
            'sentAt': DateTime.now().toUtc().toIso8601String(),
            'expectReply': true,
          }),
        ),
      ),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: probe,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitForDebugResponses() async {
    final deadline = DateTime.now().toUtc().add(const Duration(seconds: 3));
    while (DateTime.now().toUtc().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 750));
      await pollNow();
      if (_debugProbeAcknowledgements.isNotEmpty &&
          _debugTwoWayReplies.isNotEmpty) {
        return;
      }
    }
  }

  Future<DebugCheckResult> _runRelayProtocolRediscoveryCheck(
    IdentityRecord me,
  ) async {
    if (me.configuredRelays.isEmpty) {
      return const DebugCheckResult(
        name: 'Relay protocol rediscovery',
        status: DebugCheckStatus.skip,
        detail: 'No configured relay hosts to probe for TCP/UDP variants.',
      );
    }
    final refresh = await _refreshConfiguredRelayProtocols(me);
    final added = refresh.addedRoutes.map((route) => route.label).join(', ');
    return DebugCheckResult(
      name: 'Relay protocol rediscovery',
      status: refresh.availableRoutes == 0
          ? DebugCheckStatus.warn
          : DebugCheckStatus.pass,
      detail: refresh.addedRoutes.isEmpty
          ? 'Checked ${refresh.checkedRoutes} TCP/UDP relay route(s); ${refresh.availableRoutes} available; no new protocol routes detected.'
          : 'Checked ${refresh.checkedRoutes} TCP/UDP relay route(s); ${refresh.availableRoutes} available; added $added.',
    );
  }

  DebugCheckResult _runNotificationRuntimeCheck(IdentityRecord me) {
    final platform = kIsWeb ? 'web' : Platform.operatingSystem;
    if (!me.notificationsEnabled) {
      return DebugCheckResult(
        name: 'Notifications and background',
        status: DebugCheckStatus.warn,
        detail:
            'Notifications are disabled on $platform. Incoming messages are still stored locally.',
      );
    }
    if (!kIsWeb && Platform.isAndroid && !me.androidBackgroundRuntimeEnabled) {
      return const DebugCheckResult(
        name: 'Notifications and background',
        status: DebugCheckStatus.warn,
        detail:
            'Notifications are enabled, but Android background runtime is off. If the app is backgrounded or battery-restricted, notifications can be late or never arrive.',
      );
    }
    return DebugCheckResult(
      name: 'Notifications and background',
      status: DebugCheckStatus.pass,
      detail:
          'Notifications are enabled on $platform${!kIsWeb && Platform.isAndroid ? ' and Android background runtime is requested.' : '.'}',
    );
  }

  DebugCheckResult _runRouteProtocolCoverageCheck(IdentityRecord me) {
    final inviteRoutes = _inviteRouteHintsForIdentity(me);
    final lanProtocols = inviteRoutes
        .where((route) => route.kind == PeerRouteKind.lan)
        .map((route) => route.protocol.name)
        .toSet();
    final relayGroups = <String, Set<String>>{};
    for (final route in _diagnosticRelayRoutesForIdentity(me)) {
      if (route.kind != PeerRouteKind.relay) {
        continue;
      }
      relayGroups
          .putIfAbsent('${route.host}:${route.port}', () => <String>{})
          .add(route.protocol.name);
    }
    final relayProtocolSummary = relayGroups.entries
        .map((entry) => '${entry.key}=${entry.value.join('+')}')
        .toList(growable: false);
    final lanHasBoth =
        lanProtocols.contains(PeerRouteProtocol.tcp.name) &&
        lanProtocols.contains(PeerRouteProtocol.udp.name);
    final status = !lanHasBoth ? DebugCheckStatus.fail : DebugCheckStatus.pass;
    final relayDetail = relayGroups.isEmpty
        ? 'No configured relay routes.'
        : 'Relay host protocols: ${relayProtocolSummary.join(', ')}.';
    return DebugCheckResult(
      name: 'Route protocol coverage',
      status: status,
      detail:
          'LAN advertises ${lanProtocols.isEmpty ? 'none' : lanProtocols.join('+')}. $relayDetail',
    );
  }

  DebugCheckResult _runRelayAliasGroupingCheck() {
    final relayRoutes = identity == null
        ? const <PeerEndpoint>[]
        : _diagnosticRelayRoutesForIdentity(identity!)
              .where((route) => route.kind == PeerRouteKind.relay)
              .toList(growable: false);
    if (relayRoutes.isEmpty) {
      return const DebugCheckResult(
        name: 'Relay alias grouping',
        status: DebugCheckStatus.skip,
        detail: 'No relay routes are configured or learned.',
      );
    }
    final knownRelayRoutes = _routeHealth.values
        .where(
          (health) =>
              health.available &&
              health.route.kind == PeerRouteKind.relay &&
              health.relayInstanceId != null,
        )
        .map((health) => health.route)
        .toList(growable: false);
    if (knownRelayRoutes.isEmpty) {
      return const DebugCheckResult(
        name: 'Relay alias grouping',
        status: DebugCheckStatus.warn,
        detail:
            'No reachable relay returned an instance id; same-relay aliases cannot be detected yet.',
      );
    }
    final groups = _relayInstanceGroups(minEndpoints: 2);
    if (groups.isEmpty) {
      return DebugCheckResult(
        name: 'Relay alias grouping',
        status: DebugCheckStatus.pass,
        detail:
            'No same-relay aliases detected across ${knownRelayRoutes.length} reachable relay endpoint(s).',
      );
    }
    return DebugCheckResult(
      name: 'Relay alias grouping',
      status: DebugCheckStatus.pass,
      detail: groups.entries
          .map(
            (entry) =>
                '${entry.key}: ${entry.value.map((route) => route.label).join(', ')}',
          )
          .join(' | '),
    );
  }

  Future<DebugCheckResult> _runRelayLoopbackCheck(IdentityRecord me) async {
    final relayRoutes = _diagnosticRelayRoutesForIdentity(
      me,
    ).where((route) => route.kind == PeerRouteKind.relay).toList();
    if (relayRoutes.isEmpty) {
      return const DebugCheckResult(
        name: 'Relay store/fetch loopback',
        status: DebugCheckStatus.skip,
        detail: 'No internet relay route is configured.',
      );
    }
    final checks = await _rankRouteHealthForDelivery(relayRoutes);
    PeerRouteHealth? selected;
    for (final check in checks) {
      if (check.available) {
        selected = check;
        break;
      }
    }
    if (selected == null) {
      return DebugCheckResult(
        name: 'Relay store/fetch loopback',
        status: DebugCheckStatus.warn,
        detail: checks.map((check) => check.summary).join(' | '),
      );
    }

    final mailbox = 'debug-${me.deviceId}-${_randomId('loop')}';
    final messageId = _randomId('dbgloop');
    final envelope = RelayEnvelope(
      kind: 'debug_loopback',
      messageId: messageId,
      conversationId: 'debug-loopback',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: mailbox,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(utf8.encode('relay loopback')),
    );
    try {
      await _relayClient.storeEnvelope(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        envelope: envelope,
        timeout: const Duration(seconds: 4),
      );
      final fetched = await _relayClient.fetchEnvelopes(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        limit: 8,
        timeout: const Duration(seconds: 4),
      );
      final delivered = fetched.any(
        (candidate) => candidate.messageId == messageId,
      );
      return DebugCheckResult(
        name: 'Relay store/fetch loopback',
        status: delivered ? DebugCheckStatus.pass : DebugCheckStatus.fail,
        detail: delivered
            ? 'Relay ${selected.route.label} accepted and returned a debug envelope.'
            : 'Relay ${selected.route.label} accepted store but did not return the envelope.',
      );
    } catch (error) {
      return DebugCheckResult(
        name: 'Relay store/fetch loopback',
        status: DebugCheckStatus.fail,
        detail: 'Relay ${selected.route.label} loopback failed: $error',
      );
    }
  }

  Future<DebugCheckResult> _runRelayPairingReuseCheck(IdentityRecord me) async {
    final relayRoutes = _diagnosticRelayRoutesForIdentity(
      me,
    ).where((route) => route.kind == PeerRouteKind.relay).toList();
    if (relayRoutes.isEmpty) {
      return const DebugCheckResult(
        name: 'Relay pairing announcement reuse',
        status: DebugCheckStatus.skip,
        detail: 'No internet relay route is configured.',
      );
    }
    final checks = await _rankRouteHealthForDelivery(relayRoutes);
    PeerRouteHealth? selected;
    for (final check in checks) {
      if (check.available) {
        selected = check;
        break;
      }
    }
    if (selected == null) {
      return DebugCheckResult(
        name: 'Relay pairing announcement reuse',
        status: DebugCheckStatus.warn,
        detail: checks.map((check) => check.summary).join(' | '),
      );
    }

    final mailbox = 'pair-debug-${_randomId('mail')}';
    final messageId = _randomId('pairdbg');
    final envelope = RelayEnvelope(
      kind: 'pairing_announcement',
      messageId: messageId,
      conversationId: 'debug-pairing-reuse',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: mailbox,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(
        utf8.encode(_inviteForIdentity(me).encodePayload()),
      ),
    );
    try {
      await _relayClient.storeEnvelope(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        envelope: envelope,
        timeout: const Duration(seconds: 4),
      );
      final first = await _relayClient.fetchEnvelopes(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        limit: 4,
        timeout: const Duration(seconds: 4),
      );
      final second = await _relayClient.fetchEnvelopes(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        limit: 4,
        timeout: const Duration(seconds: 4),
      );
      final firstDelivered = first.any(
        (candidate) => candidate.messageId == messageId,
      );
      final secondDelivered = second.any(
        (candidate) => candidate.messageId == messageId,
      );
      final reusable = firstDelivered && secondDelivered;
      return DebugCheckResult(
        name: 'Relay pairing announcement reuse',
        status: reusable ? DebugCheckStatus.pass : DebugCheckStatus.fail,
        detail: reusable
            ? 'Relay ${selected.route.label} keeps pairing announcements reusable across discovery fetches.'
            : 'Relay ${selected.route.label} consumed or lost a pairing announcement after first fetch.',
      );
    } catch (error) {
      return DebugCheckResult(
        name: 'Relay pairing announcement reuse',
        status: DebugCheckStatus.fail,
        detail:
            'Relay ${selected.route.label} pairing announcement reuse failed: $error',
      );
    }
  }

  Future<DebugCheckResult> _runPairingAnnouncementLoopbackCheck(
    IdentityRecord me,
  ) async {
    try {
      await _refreshLanAddresses(persist: false);
      await _ensureLocalRelayRunning();
      await _announcePairingAvailabilityIfNeeded(force: true);
      final current = _requireIdentity();
      final payload = _inviteForIdentity(current).encodePayload();
      final codephrase = currentPairingCodeSnapshotForPayload(
        payload,
      ).codephrase;
      final mailboxId = pairingMailboxIdForCodephrase(codephrase);
      final routes = _pairingLoopbackCheckRoutesForIdentity(current);
      if (routes.isEmpty) {
        return const DebugCheckResult(
          name: 'Pairing announcement loopback',
          status: DebugCheckStatus.fail,
          detail:
              'No local or relay route is available for pairing announcements.',
        );
      }
      final checked = <String>[];
      PeerEndpoint? loopbackHit;
      for (final route in routes.take(24)) {
        checked.add('${route.kind.name}:${route.label}');
        final invite = await _resolveInviteByRoute(
          route: route,
          mailboxId: mailboxId,
        );
        if (invite?.deviceId == current.deviceId) {
          if (route.host == '127.0.0.1') {
            loopbackHit = route;
            continue;
          }
          return DebugCheckResult(
            name: 'Pairing announcement loopback',
            status: DebugCheckStatus.pass,
            detail:
                'Current codephrase $codephrase is published on ${route.kind.name}:${route.label}.',
          );
        }
      }
      if (loopbackHit != null) {
        return DebugCheckResult(
          name: 'Pairing announcement loopback',
          status: DebugCheckStatus.warn,
          detail:
              'Current codephrase $codephrase is published on loopback (${loopbackHit.label}), but not on the checked LAN routes. Other devices may not reach this device; check firewall/private network permissions. Checked ${checked.join(', ')}.',
        );
      }
      return DebugCheckResult(
        name: 'Pairing announcement loopback',
        status: DebugCheckStatus.warn,
        detail:
            'Current codephrase $codephrase was announced, but loopback fetch did not return it. Checked ${checked.join(', ')}.',
      );
    } catch (error) {
      return DebugCheckResult(
        name: 'Pairing announcement loopback',
        status: DebugCheckStatus.fail,
        detail: 'Pairing announcement check failed: $error',
      );
    }
  }

  Future<DebugCheckResult> _runPairingBeaconCheck() async {
    if (kIsWeb) {
      return const DebugCheckResult(
        name: 'LAN pairing beacon',
        status: DebugCheckStatus.skip,
        detail: 'LAN UDP beacons are not available on web builds.',
      );
    }
    try {
      await _ensurePairingBeaconRunning();
      await _sendPairingRouteBeacon();
      final routes = recentPairingBeaconRoutes;
      final socket = _pairingBeaconSocket;
      if (socket == null) {
        return const DebugCheckResult(
          name: 'LAN pairing beacon',
          status: DebugCheckStatus.warn,
          detail:
              'UDP beacon listener could not start; codephrase discovery will fall back to known routes and nearby LAN scans.',
        );
      }
      return DebugCheckResult(
        name: 'LAN pairing beacon',
        status: DebugCheckStatus.pass,
        detail: routes.isEmpty
            ? 'UDP beacon listener is on :$_pairingBeaconPort. No remote pairing beacons cached yet.'
            : 'UDP beacon listener is on :$_pairingBeaconPort. Cached ${routes.length} route(s): ${routes.map((route) => route.label).join(', ')}.',
      );
    } catch (error) {
      return DebugCheckResult(
        name: 'LAN pairing beacon',
        status: DebugCheckStatus.warn,
        detail: 'LAN beacon check failed: $error',
      );
    }
  }

  Future<bool> _tryDeliverExistingMessage({
    required ContactRecord contact,
    required ChatMessage message,
  }) async {
    if (_locallyDeletedMessageIds.contains(message.id) ||
        _messageById(contact.deviceId, message.id) == null) {
      return true;
    }
    try {
      final envelope = await _encryptMessage(
        contact: contact,
        message: message,
      );
      if (_locallyDeletedMessageIds.contains(message.id) ||
          _messageById(contact.deviceId, message.id) == null) {
        return true;
      }
      final route = await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: envelope,
      );
      if (_locallyDeletedMessageIds.contains(message.id) ||
          _messageById(contact.deviceId, message.id) == null) {
        await _sendMessageDeletion(
          contact: contact,
          targetMessageId: message.id,
        );
        return true;
      }
      final state = route.kind == PeerRouteKind.lan
          ? DeliveryState.local
          : DeliveryState.relayed;
      _updateMessageState(contact.deviceId, message.id, state);
      _lastRelayStatus = route.kind == PeerRouteKind.lan
          ? 'LAN delivered via ${route.host}:${route.port}'
          : 'relay accepted via ${route.host}:${route.port}';
      await _persist(
        route.kind == PeerRouteKind.lan
            ? 'Delivered directly over LAN to ${contact.alias}.'
            : 'Encrypted message handed to relay for ${contact.alias}.',
      );
      return true;
    } catch (error) {
      _lastRelayStatus = 'delivery queued';
      _statusMessage = 'Delivery retry pending: $error';
      notifyListeners();
      return false;
    }
  }

  Future<void> _retryPendingMessages() async {
    for (final contact in contacts) {
      final pending = messagesFor(contact.deviceId)
          .where(
            (message) =>
                message.outbound && message.state == DeliveryState.pending,
          )
          .toList();
      for (final message in pending) {
        final delivered = await _tryDeliverExistingMessage(
          contact: contact,
          message: message,
        );
        if (!delivered) {
          break;
        }
      }
    }
  }

  Future<PeerEndpoint> _deliverToContact({
    required ContactRecord contact,
    required String recipientDeviceId,
    required RelayEnvelope envelope,
  }) async {
    final routes = await _rankRoutesForDelivery(contact.prioritizedRouteHints);
    return _deliverAcrossRoutes(
      routes: routes,
      recipientDeviceId: recipientDeviceId,
      envelope: envelope,
    );
  }

  Future<List<PeerEndpoint>> _rankRoutesForDelivery(
    List<PeerEndpoint> routes,
  ) async {
    final checks = await _rankRouteHealthForDelivery(routes);
    return checks.map((check) => check.route).toList(growable: false);
  }

  Future<List<PeerRouteHealth>> _rankRouteHealthForDelivery(
    List<PeerEndpoint> routes,
  ) async {
    final uniqueRoutes = dedupePeerEndpoints(routes);
    if (uniqueRoutes.isEmpty) {
      return const <PeerRouteHealth>[];
    }
    final checks = await Future.wait(uniqueRoutes.map(_checkRouteHealth));
    final aliasRoutes = await _sameRelayAliasRoutesFor(
      checks: checks,
      existingRoutes: uniqueRoutes,
    );
    if (aliasRoutes.isNotEmpty) {
      checks.addAll(await Future.wait(aliasRoutes.map(_checkRouteHealth)));
    }
    final healthyLan =
        checks
            .where(
              (check) =>
                  check.available && check.route.kind == PeerRouteKind.lan,
            )
            .toList()
          ..sort(_compareRouteHealth);
    final healthyDirectInternet =
        checks
            .where(
              (check) =>
                  check.available &&
                  check.route.kind == PeerRouteKind.directInternet,
            )
            .toList()
          ..sort(_compareRouteHealth);
    final unhealthyLan =
        checks
            .where(
              (check) =>
                  !check.available && check.route.kind == PeerRouteKind.lan,
            )
            .toList()
          ..sort(_compareRouteHealth);
    final unhealthyDirectInternet =
        checks
            .where(
              (check) =>
                  !check.available &&
                  check.route.kind == PeerRouteKind.directInternet,
            )
            .toList()
          ..sort(_compareRouteHealth);
    final healthyRelays =
        checks
            .where(
              (check) =>
                  check.available && check.route.kind == PeerRouteKind.relay,
            )
            .toList()
          ..sort(_compareRouteHealth);
    final unhealthyRelays =
        checks
            .where(
              (check) =>
                  !check.available && check.route.kind == PeerRouteKind.relay,
            )
            .toList()
          ..sort(_compareRouteHealth);

    return <PeerRouteHealth>[
      ...healthyLan,
      ...healthyDirectInternet,
      ...healthyRelays,
      ...unhealthyLan,
      ...unhealthyDirectInternet,
      ...unhealthyRelays,
    ];
  }

  Future<List<PeerEndpoint>> _sameRelayAliasRoutesFor({
    required List<PeerRouteHealth> checks,
    required List<PeerEndpoint> existingRoutes,
  }) async {
    final relayIds = checks
        .where(
          (check) =>
              check.available &&
              check.route.kind == PeerRouteKind.relay &&
              check.relayInstanceId != null,
        )
        .map((check) => check.relayInstanceId!)
        .toSet();
    if (relayIds.isEmpty || identity == null) {
      return const <PeerEndpoint>[];
    }
    final existingKeys = existingRoutes.map((route) => route.routeKey).toSet();
    final candidates = _diagnosticRelayRoutesForIdentity(identity!)
        .where(
          (route) =>
              route.kind == PeerRouteKind.relay &&
              !existingKeys.contains(route.routeKey),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      return const <PeerEndpoint>[];
    }
    final candidateChecks = await Future.wait(
      candidates.map(_checkRouteHealth),
    );
    return candidateChecks
        .where(
          (check) =>
              check.available &&
              check.relayInstanceId != null &&
              relayIds.contains(check.relayInstanceId),
        )
        .map((check) => check.route)
        .toList(growable: false);
  }

  int _compareRouteHealth(PeerRouteHealth left, PeerRouteHealth right) {
    final leftLatency = left.latency?.inMicroseconds ?? 1 << 62;
    final rightLatency = right.latency?.inMicroseconds ?? 1 << 62;
    return leftLatency.compareTo(rightLatency);
  }

  Future<PeerRouteHealth> _checkRouteHealth(PeerEndpoint route) async {
    final timeout = switch (route.kind) {
      PeerRouteKind.lan => const Duration(milliseconds: 800),
      PeerRouteKind.directInternet => const Duration(seconds: 2),
      PeerRouteKind.relay => const Duration(seconds: 3),
    };
    try {
      final stopwatch = Stopwatch()..start();
      final info = await _relayClient.inspectHealth(
        host: route.host,
        port: route.port,
        protocol: route.protocol,
        timeout: timeout,
      );
      stopwatch.stop();
      if (!info.ok) {
        throw StateError('Route health check failed.');
      }
      final health = PeerRouteHealth(
        route: route,
        available: true,
        latency: stopwatch.elapsed,
        checkedAt: DateTime.now().toUtc(),
        relayInstanceId: route.kind == PeerRouteKind.relay
            ? info.relayInstanceId
            : null,
      );
      _routeHealth[route.routeKey] = health;
      return health;
    } catch (error) {
      final health = PeerRouteHealth(
        route: route,
        available: false,
        latency: null,
        checkedAt: DateTime.now().toUtc(),
        error: error.toString(),
      );
      _routeHealth[route.routeKey] = health;
      return health;
    }
  }

  Future<PeerEndpoint> _deliverAcrossRoutes({
    required List<PeerEndpoint> routes,
    required String recipientDeviceId,
    required RelayEnvelope envelope,
  }) async {
    Object? lastError;
    for (final route in routes) {
      try {
        final stored = await _relayClient.storeEnvelope(
          host: route.host,
          port: route.port,
          protocol: route.protocol,
          recipientDeviceId: recipientDeviceId,
          envelope: envelope,
          timeout: route.kind == PeerRouteKind.lan
              ? const Duration(milliseconds: 900)
              : route.kind == PeerRouteKind.directInternet
              ? const Duration(seconds: 2)
              : const Duration(seconds: 4),
        );
        if (stored) {
          return route;
        }
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('No reachable route for recipient.');
  }

  Future<ContactInvite> _resolveInviteByCodephrase(String codephrase) async {
    final me = _requireIdentity();
    final mailboxId = pairingMailboxIdForCodephrase(codephrase);
    final pingSent = await _sendPairingDiscoveryPing();
    if (pingSent) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final relayRoutes = _internetPairingRoutesForIdentity(me);
    final relayInvite = await _resolveInviteByRoutes(
      mailboxId: mailboxId,
      routes: relayRoutes,
    );
    if (relayInvite != null) {
      return relayInvite;
    }

    final beaconRoutes = _recentPairingBeaconRoutes();
    final lanRoutes = _lanPairingRoutesForIdentity(
      me,
      beaconRoutes: beaconRoutes,
    );
    final lanInvite = await _resolveInviteByRoutes(
      mailboxId: mailboxId,
      routes: lanRoutes,
    );
    if (lanInvite != null) {
      return lanInvite;
    }
    throw ArgumentError(
      'No contact advertising that codephrase was found. Scanned ${relayRoutes.length} configured/contact route(s), ${beaconRoutes.length} LAN beacon route(s), and ${lanRoutes.length} nearby LAN route(s). Keep My invite open on the other device, press Rotate Codephrase Now, and verify its debug menu shows Pairing announcement loopback = pass on a LAN address, not only loopback.',
    );
  }

  Future<ContactInvite?> _resolveInviteByRoutes({
    required String mailboxId,
    required List<PeerEndpoint> routes,
  }) async {
    if (routes.isEmpty) {
      return null;
    }
    const batchSize = 24;
    for (var index = 0; index < routes.length; index += batchSize) {
      final batch = routes.skip(index).take(batchSize).toList(growable: false);
      final resolved = await Future.wait(
        batch.map(
          (route) => _resolveInviteByRoute(route: route, mailboxId: mailboxId),
        ),
      );
      for (final invite in resolved) {
        if (invite != null) {
          return invite;
        }
      }
    }
    return null;
  }

  Future<ContactInvite?> _resolveInviteByRoute({
    required PeerEndpoint route,
    required String mailboxId,
  }) async {
    try {
      final envelopes = await _relayClient.fetchEnvelopes(
        host: route.host,
        port: route.port,
        protocol: route.protocol,
        recipientDeviceId: mailboxId,
        limit: 4,
        timeout: route.kind == PeerRouteKind.lan
            ? const Duration(milliseconds: 800)
            : const Duration(seconds: 2),
      );
      for (final envelope in envelopes) {
        if (envelope.kind != 'pairing_announcement' ||
            envelope.payloadBase64 == null) {
          continue;
        }
        final payload = utf8.decode(base64Decode(envelope.payloadBase64!));
        final invite = ContactInvite.tryDecodePayload(payload);
        if (invite != null) {
          return invite;
        }
      }
    } catch (_) {
      // Pairing discovery is best-effort across many routes.
    }
    return null;
  }

  List<PeerEndpoint> _internetPairingRoutesForIdentity(IdentityRecord me) {
    return _diagnosticRelayRoutesForIdentity(me);
  }

  List<PeerEndpoint> _contactRelayRoutes() {
    final me = identity;
    if (me == null || !me.autoUseContactRelays) {
      return const <PeerEndpoint>[];
    }
    final routes = <PeerEndpoint>[];
    for (final contact in contacts) {
      for (final route in contact.prioritizedRouteHints) {
        if (route.kind == PeerRouteKind.relay || contact.relayCapable) {
          routes.add(route);
        }
      }
    }
    return dedupePeerEndpoints(routes);
  }

  List<PeerEndpoint> _trustedContactRelayRoutes() {
    final routes = <PeerEndpoint>[];
    for (final contact in contacts) {
      for (final route in contact.prioritizedRouteHints) {
        if (route.kind == PeerRouteKind.relay) {
          routes.add(route);
        }
      }
    }
    return dedupePeerEndpoints(routes);
  }

  List<PeerEndpoint> _effectiveRelayRoutesForIdentity(IdentityRecord me) {
    return dedupePeerEndpoints([
      ...me.configuredRelays,
      ..._contactRelayRoutes(),
    ]);
  }

  List<PeerEndpoint> _diagnosticRelayRoutesForIdentity(IdentityRecord me) {
    return dedupePeerEndpoints([
      ...me.configuredRelays,
      ..._trustedContactRelayRoutes(),
      ..._routeHealth.values
          .where((health) => health.route.kind == PeerRouteKind.relay)
          .map((health) => health.route),
    ]);
  }

  List<PeerEndpoint> _lanPairingRoutesForIdentity(
    IdentityRecord me, {
    List<PeerEndpoint>? beaconRoutes,
  }) {
    final ports = <int>{me.localRelayPort, defaultRelayPort};
    final ownAddresses = me.lanAddresses.toSet();
    final seen = <String>{};
    final routes = <PeerEndpoint>[];
    for (final route in beaconRoutes ?? _recentPairingBeaconRoutes()) {
      if (seen.add(route.routeKey)) {
        routes.add(route);
      }
    }
    for (final contact in contacts) {
      for (final route in contact.lanRouteHints) {
        if (seen.add(route.routeKey)) {
          routes.add(route);
        }
      }
    }
    for (final address in ownAddresses) {
      final lastDot = address.lastIndexOf('.');
      if (lastDot == -1) {
        continue;
      }
      final prefix = address.substring(0, lastDot);
      for (var hostSegment = 1; hostSegment < 255; hostSegment++) {
        final host = '$prefix.$hostSegment';
        if (ownAddresses.contains(host)) {
          continue;
        }
        for (final port in ports) {
          for (final route in _protocolRoutes(
            kind: PeerRouteKind.lan,
            host: host,
            port: port,
          )) {
            if (seen.add(route.routeKey)) {
              routes.add(route);
            }
          }
        }
      }
    }
    return routes;
  }

  List<PeerEndpoint> _pairingLoopbackCheckRoutesForIdentity(IdentityRecord me) {
    final routes = <PeerEndpoint>[];
    if (_localRelayNode.isRunning) {
      routes.addAll(
        _protocolRoutes(
          kind: PeerRouteKind.lan,
          host: '127.0.0.1',
          port: me.localRelayPort,
        ),
      );
      routes.addAll(
        me.lanAddresses.expand(
          (address) => _protocolRoutes(
            kind: PeerRouteKind.lan,
            host: address,
            port: me.localRelayPort,
          ),
        ),
      );
    }
    routes.addAll(_diagnosticRelayRoutesForIdentity(me));
    return dedupePeerEndpoints(routes);
  }

  List<PeerEndpoint> _pollRoutesForIdentity(IdentityRecord me) {
    final routes = <PeerEndpoint>[];
    if (_localRelayNode.isRunning) {
      routes.addAll(
        _protocolRoutes(
          kind: PeerRouteKind.lan,
          host: '127.0.0.1',
          port: me.localRelayPort,
        ),
      );
    }
    routes.addAll(_diagnosticRelayRoutesForIdentity(me));
    return dedupePeerEndpoints(routes);
  }

  ContactInvite _inviteForIdentity(IdentityRecord identity) {
    return ContactInvite(
      version: 4,
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      displayName: identity.displayName,
      bio: identity.bio,
      pairingNonce: identity.pairingNonce,
      pairingEpochMs: identity.pairingEpochMs,
      relayCapable: identity.relayModeEnabled,
      publicKeyBase64: identity.publicKeyBase64,
      routeHints: _inviteRouteHintsForIdentity(identity),
    );
  }

  List<PeerEndpoint> _inviteRouteHintsForIdentity(IdentityRecord identity) {
    return dedupePeerEndpoints([
      ...identity.advertisedRouteHints,
      ..._contactRelayRoutes().where(
        (route) => route.kind == PeerRouteKind.relay,
      ),
    ]).take(_maxInviteRouteHints).toList(growable: false);
  }

  Future<void> _announcePairingAvailabilityIfNeeded({
    bool force = false,
  }) async {
    final me = _snapshot.identity;
    if (me == null) {
      return;
    }
    final invite = _inviteForIdentity(me);
    final payload = invite.encodePayload();
    final pairingCode = currentPairingCodeSnapshotForPayload(
      payload,
    ).codephrase;
    final mailboxId = pairingMailboxIdForCodephrase(pairingCode);
    final now = DateTime.now().toUtc();
    final lastAnnouncementAt = _lastPairingAnnouncementAt;
    if (!force &&
        _lastPairingAnnouncementMailboxId == mailboxId &&
        lastAnnouncementAt != null &&
        now.difference(lastAnnouncementAt) < const Duration(seconds: 8)) {
      return;
    }

    final announcement = RelayEnvelope(
      kind: 'pairing_announcement',
      messageId: _randomId('pair'),
      conversationId: 'pairing',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: mailboxId,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(utf8.encode(payload)),
    );
    for (final route in _announcementRoutesForIdentity(me)) {
      try {
        await _relayClient.storeEnvelope(
          host: route.host,
          port: route.port,
          protocol: route.protocol,
          recipientDeviceId: mailboxId,
          envelope: announcement,
          timeout: route.kind == PeerRouteKind.lan
              ? const Duration(milliseconds: 800)
              : const Duration(seconds: 2),
        );
      } catch (_) {
        // Announcements are best-effort. Normal delivery continues to work.
      }
    }
    _lastPairingAnnouncementMailboxId = mailboxId;
    _lastPairingAnnouncementAt = now;
  }

  List<PeerEndpoint> _announcementRoutesForIdentity(IdentityRecord me) {
    final routes = <PeerEndpoint>[];
    if (_localRelayNode.isRunning) {
      routes.addAll(
        _protocolRoutes(
          kind: PeerRouteKind.lan,
          host: '127.0.0.1',
          port: me.localRelayPort,
        ),
      );
      routes.addAll(
        me.lanAddresses.expand(
          (address) => _protocolRoutes(
            kind: PeerRouteKind.lan,
            host: address,
            port: me.localRelayPort,
          ),
        ),
      );
    }
    routes.addAll(_diagnosticRelayRoutesForIdentity(me));
    return dedupePeerEndpoints(routes);
  }

  String _networkSummary(IdentityRecord me, {bool? internetRelayHealthy}) {
    final parts = <String>[
      _localRelayNode.isRunning
          ? 'LAN node :${me.localRelayPort} on'
          : 'LAN node unavailable',
    ];
    if (me.lanAddresses.isNotEmpty) {
      parts.add('LAN ${me.lanAddresses.take(2).join(', ')}');
    }
    final relayRoutes = _diagnosticRelayRoutesForIdentity(me);
    if (relayRoutes.isNotEmpty) {
      final relaySummary = relayRoutes
          .take(2)
          .map((route) => route.label)
          .join(', ');
      parts.add(
        internetRelayHealthy == false
            ? 'relay $relaySummary down'
            : 'relay $relaySummary',
      );
    } else {
      parts.add('no internet relay');
    }
    return parts.join(' • ');
  }

  Map<String, List<PeerEndpoint>> _relayInstanceGroups({int minEndpoints = 1}) {
    final groups = <String, List<PeerEndpoint>>{};
    final seen = <String, Set<String>>{};
    for (final health in _routeHealth.values) {
      final relayId = health.relayInstanceId;
      if (!health.available ||
          health.route.kind != PeerRouteKind.relay ||
          relayId == null ||
          relayId.isEmpty) {
        continue;
      }
      final relaySeen = seen.putIfAbsent(relayId, () => <String>{});
      if (relaySeen.add(health.route.routeKey)) {
        groups.putIfAbsent(relayId, () => <PeerEndpoint>[]).add(health.route);
      }
    }
    groups.removeWhere((_, routes) => routes.length < minEndpoints);
    for (final routes in groups.values) {
      routes.sort((left, right) => left.label.compareTo(right.label));
    }
    return groups;
  }

  String _relayInstanceDebugSummary({int minEndpoints = 1}) {
    final groups = _relayInstanceGroups(minEndpoints: minEndpoints);
    if (groups.isEmpty) {
      return '';
    }
    return groups.entries
        .map(
          (entry) =>
              '${entry.key}=${entry.value.map((route) => route.label).join(', ')}',
        )
        .join(' | ');
  }

  List<PeerEndpoint> _lanLobbyBroadcastRoutes() {
    return dedupePeerEndpoints(
      _recentPairingBeaconRoutes().where(
        (route) => route.kind == PeerRouteKind.lan,
      ),
    );
  }

  Future<SimpleKeyPairData> _lanLobbyKeyPair() async {
    final existing = _lanLobbySigningKeyPair;
    if (existing != null) {
      return existing;
    }
    final keyPair = await Ed25519().newKeyPair();
    final keyPairData = await keyPair.extract();
    final publicKey = await keyPair.extractPublicKey();
    _lanLobbySigningKeyPair = keyPairData;
    _lanLobbyPublicKeyBase64 = base64Encode(publicKey.bytes);
    return keyPairData;
  }

  Map<String, dynamic> _lanLobbySignablePayload({
    required String messageId,
    required String senderAccountId,
    required String senderDeviceId,
    required String senderDisplayName,
    required DateTime createdAt,
    required String body,
    required String publicKeyBase64,
  }) {
    return {
      'version': 1,
      'messageId': messageId,
      'senderAccountId': senderAccountId,
      'senderDeviceId': senderDeviceId,
      'senderDisplayName': senderDisplayName,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'body': body,
      'publicKeyBase64': publicKeyBase64,
    };
  }

  List<int> _lanLobbySignableBytes(Map<String, dynamic> payload) {
    return utf8.encode(jsonEncode(payload));
  }

  Future<RelayEnvelope> _encryptMessage({
    required ContactRecord contact,
    required ChatMessage message,
  }) async {
    final me = _requireIdentity();
    return _encryptPayloadEnvelope(
      kind: 'direct_message',
      messageId: message.id,
      conversationId: message.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: message.body,
      createdAt: message.createdAt,
    );
  }

  Future<RelayEnvelope> _encryptPayloadEnvelope({
    required String kind,
    required String messageId,
    required String conversationId,
    required String senderAccountId,
    required String senderDeviceId,
    required String recipientDeviceId,
    required ContactRecord contact,
    required String plaintext,
    DateTime? createdAt,
  }) async {
    final secretKey = await _sessionKeyFor(contact);
    final cipher = Chacha20.poly1305Aead();
    final nonce = _secureRandomBytes(cipher.nonceLength);
    final secretBox = await cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
      aad: utf8.encode(messageId),
    );
    return RelayEnvelope(
      kind: kind,
      messageId: messageId,
      conversationId: conversationId,
      senderAccountId: senderAccountId,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      createdAt: createdAt ?? DateTime.now().toUtc(),
      nonceBase64: base64Encode(secretBox.nonce),
      ciphertextBase64: base64Encode(secretBox.cipherText),
      macBase64: base64Encode(secretBox.mac.bytes),
    );
  }

  Future<String> _decryptMessage({
    required ContactRecord contact,
    required RelayEnvelope envelope,
  }) async {
    final cipher = Chacha20.poly1305Aead();
    final secretKey = await _sessionKeyFor(contact);
    final cleartext = await cipher.decrypt(
      SecretBox(
        base64Decode(envelope.ciphertextBase64!),
        nonce: base64Decode(envelope.nonceBase64!),
        mac: Mac(base64Decode(envelope.macBase64!)),
      ),
      secretKey: secretKey,
      aad: utf8.encode(envelope.messageId),
    );
    return utf8.decode(cleartext);
  }

  Future<SecretKey> _sessionKeyFor(ContactRecord contact) async {
    final me = _requireIdentity();
    final algorithm = X25519();
    final myKeyPair = SimpleKeyPairData(
      base64Decode(me.privateKeyBase64),
      publicKey: SimplePublicKey(
        base64Decode(me.publicKeyBase64),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
    final shared = await algorithm.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(
        base64Decode(contact.publicKeyBase64),
        type: KeyPairType.x25519,
      ),
    );
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode(_conversationIdFor(contact.deviceId)),
      info: utf8.encode('conest.direct.v1'),
    );
  }

  ConversationRecord _conversationFor(String peerDeviceId) {
    for (final conversation in _snapshot.conversations) {
      if (conversation.peerDeviceId == peerDeviceId) {
        return conversation;
      }
    }
    return ConversationRecord(
      id: _conversationIdFor(peerDeviceId),
      kind: ConversationKind.direct,
      peerDeviceId: peerDeviceId,
      messages: const [],
    );
  }

  void _upsertMessage(String peerDeviceId, ChatMessage message) {
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final index = conversations.indexWhere(
      (conversation) => conversation.peerDeviceId == peerDeviceId,
    );
    if (index == -1) {
      conversations.add(
        ConversationRecord(
          id: _conversationIdFor(peerDeviceId),
          kind: ConversationKind.direct,
          peerDeviceId: peerDeviceId,
          messages: [message],
        ),
      );
    } else {
      final updatedMessages =
          List<ChatMessage>.from(conversations[index].messages)
            ..removeWhere((candidate) => candidate.id == message.id)
            ..add(message);
      conversations[index] = conversations[index].copyWith(
        messages: updatedMessages,
      );
    }
    _snapshot = _snapshot.copyWith(conversations: conversations);
  }

  void _upsertLanLobbyMessage(ChatMessage message) {
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final index = conversations.indexWhere(
      (conversation) => conversation.kind == ConversationKind.lanLobby,
    );
    if (index == -1) {
      conversations.add(
        ConversationRecord(
          id: _lanLobbyConversationId,
          kind: ConversationKind.lanLobby,
          peerDeviceId: _lanLobbyMailboxId,
          messages: [message],
        ),
      );
    } else {
      final updatedMessages =
          List<ChatMessage>.from(conversations[index].messages)
            ..removeWhere((candidate) => candidate.id == message.id)
            ..add(message);
      conversations[index] = conversations[index].copyWith(
        messages: updatedMessages,
      );
    }
    _snapshot = _snapshot.copyWith(conversations: conversations);
  }

  void _updateMessageState(
    String peerDeviceId,
    String messageId,
    DeliveryState state,
  ) {
    if (messageId.isEmpty) {
      return;
    }
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final conversationIndex = conversations.indexWhere(
      (conversation) => conversation.peerDeviceId == peerDeviceId,
    );
    if (conversationIndex == -1) {
      return;
    }
    final updatedMessages = conversations[conversationIndex].messages
        .map(
          (message) => message.id == messageId
              ? message.copyWith(state: state)
              : message,
        )
        .toList();
    conversations[conversationIndex] = conversations[conversationIndex]
        .copyWith(messages: updatedMessages);
    _snapshot = _snapshot.copyWith(conversations: conversations);
  }

  void _updateMessageBody(
    String peerDeviceId,
    String messageId, {
    required String body,
    required DateTime editedAt,
  }) {
    if (messageId.isEmpty) {
      return;
    }
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final conversationIndex = conversations.indexWhere(
      (conversation) => conversation.peerDeviceId == peerDeviceId,
    );
    if (conversationIndex == -1) {
      return;
    }
    final updatedMessages = conversations[conversationIndex].messages
        .map(
          (message) => message.id == messageId
              ? message.copyWith(body: body, editedAt: editedAt)
              : message,
        )
        .toList();
    conversations[conversationIndex] = conversations[conversationIndex]
        .copyWith(messages: updatedMessages);
    _snapshot = _snapshot.copyWith(conversations: conversations);
  }

  void _deleteMessage(String peerDeviceId, String messageId) {
    if (messageId.isEmpty) {
      return;
    }
    _locallyDeletedMessageIds.add(messageId);
    _markSeen(messageId);
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final conversationIndex = conversations.indexWhere(
      (conversation) => conversation.peerDeviceId == peerDeviceId,
    );
    if (conversationIndex == -1) {
      return;
    }
    final updatedMessages = conversations[conversationIndex].messages
        .where((message) => message.id != messageId)
        .toList();
    conversations[conversationIndex] = conversations[conversationIndex]
        .copyWith(messages: updatedMessages);
    _snapshot = _snapshot.copyWith(conversations: conversations);
  }

  void _markSeen(String envelopeId) {
    if (_snapshot.seenEnvelopeIds.contains(envelopeId)) {
      return;
    }
    _snapshot = _snapshot.copyWith(
      seenEnvelopeIds: List<String>.from(_snapshot.seenEnvelopeIds)
        ..add(envelopeId),
    );
  }

  Future<void> _persist(String? status) async {
    _statusMessage = status;
    await _vaultStore.save(_snapshot);
    notifyListeners();
  }

  IdentityRecord _requireIdentity() {
    final me = _snapshot.identity;
    if (me == null) {
      throw StateError('Create a device identity first.');
    }
    return me;
  }

  String _conversationIdFor(String peerDeviceId) {
    final me = _requireIdentity();
    final ordered = [me.deviceId, peerDeviceId]..sort();
    return 'conv-${ordered.join('-')}';
  }

  String _randomId(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(10, (_) => random.nextInt(256));
    final suffix = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$prefix-$suffix';
  }

  Future<String> _deriveSafetyNumber(List<List<int>> values) async {
    final sorted = values.map(base64Encode).toList()..sort();
    final digest = await Sha256().hash(utf8.encode(sorted.join(':')));
    final hex = digest.bytes
        .take(18)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    final groups = <String>[];
    for (var index = 0; index < hex.length; index += 4) {
      final next = index + 4 > hex.length ? hex.length : index + 4;
      groups.add(hex.substring(index, next));
    }
    return groups.join(' ');
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_slowPollInterval, (_) => unawaited(pollNow()));
  }

  void _startFastLocalPolling() {
    _fastLocalPollTimer?.cancel();
    _fastLocalPollTimer = Timer.periodic(
      _fastLocalPollInterval,
      (_) => unawaited(_pollLocalInboxOnly()),
    );
  }

  void _handleLocalEnvelopeStored(
    String recipientDeviceId,
    RelayEnvelope envelope,
  ) {
    final me = identity;
    if (me == null) {
      return;
    }
    if (recipientDeviceId != me.deviceId &&
        recipientDeviceId != _lanLobbyMailboxId) {
      return;
    }
    unawaited(_processLocalStoredEnvelope(envelope));
  }

  Future<void> _processLocalStoredEnvelope(RelayEnvelope envelope) async {
    if (!hasIdentity) {
      return;
    }
    final processed = await _processEnvelopes([envelope]);
    if (processed > 0) {
      await _persist('Received $processed item(s) instantly via local relay.');
    } else {
      notifyListeners();
    }
  }

  Future<void> _pollLocalInboxOnly() async {
    if (_fastLocalPolling || !hasIdentity || !_localRelayNode.isRunning) {
      return;
    }
    _fastLocalPolling = true;
    try {
      final me = _requireIdentity();
      var processed = 0;
      final routes = <PeerEndpoint>[
        PeerEndpoint(
          kind: PeerRouteKind.lan,
          host: '127.0.0.1',
          port: me.localRelayPort,
        ),
      ];
      for (final route in routes) {
        try {
          final envelopes = await _relayClient.fetchEnvelopes(
            host: route.host,
            port: route.port,
            protocol: route.protocol,
            recipientDeviceId: me.deviceId,
            timeout: const Duration(milliseconds: 350),
          );
          processed += await _processEnvelopes(envelopes);
        } catch (_) {
          // Full polling handles status reporting; this path only reduces LAN latency.
        }
      }
      if (processed > 0) {
        await _persist('Received $processed item(s) via fast local inbox.');
      }
    } finally {
      _fastLocalPolling = false;
    }
  }

  void _applyAndroidBackgroundPreference() {
    final me = identity;
    if (me == null) {
      return;
    }
    unawaited(
      _platformBridge.setAndroidBackgroundRuntimeEnabled(
        me.androidBackgroundRuntimeEnabled,
      ),
    );
  }

  bool _sameAddresses(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  bool _defaultRelayModeEnabled() {
    if (kIsWeb) {
      return false;
    }
    return !Platform.isAndroid;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _fastLocalPollTimer?.cancel();
    _localRelayNode.onEnvelopeStored = null;
    unawaited(_stopPairingBeacon());
    unawaited(_platformBridge.setAndroidBackgroundRuntimeEnabled(false));
    unawaited(_localRelayNode.stop());
    super.dispose();
  }
}

class _PairingBeaconRoute {
  const _PairingBeaconRoute({required this.route, required this.seenAt});

  final PeerEndpoint route;
  final DateTime seenAt;
}

class _RelayProtocolRefreshResult {
  const _RelayProtocolRefreshResult({
    required this.checkedRoutes,
    required this.availableRoutes,
    required this.addedRoutes,
  });

  final int checkedRoutes;
  final int availableRoutes;
  final List<PeerEndpoint> addedRoutes;
}
