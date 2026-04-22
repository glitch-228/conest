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

const int _maxInviteRouteHints = 4;
const int _maxInviteLanHosts = 1;
const int _maxInviteRelayRoutes = 2;
const int _maxLanPairingScanHostsPerAddress = 64;
const int _maxLanRediscoveryScanHostsPerAddress = 16;
const int _maxLanRediscoveryAdjacentHostsPerHint = 2;
const int _maxDebugRouteSummaryItems = 8;
const int _pairingBeaconPort = defaultRelayPort + 1;
const Duration _pairingBeaconTtl = Duration(seconds: 45);
const Duration _debugLanRouteTimeout = Duration(milliseconds: 250);
const Duration _debugInternetRouteTimeout = Duration(milliseconds: 900);
const Duration _debugRelayOperationTimeout = Duration(milliseconds: 900);
const String _lanLobbyMailboxId = 'lan-lobby-v1';
const String _lanLobbyConversationId = 'conv-lan-lobby';
const Duration _foregroundActivePollInterval = Duration(seconds: 5);
const Duration _foregroundIdlePollInterval = Duration(seconds: 15);
const Duration _backgroundEnabledPollInterval = Duration(seconds: 30);
const Duration _desktopBackgroundPollInterval = Duration(seconds: 15);
const Duration _runtimeActiveWindow = Duration(seconds: 20);
const Duration _pairingSessionDuration = Duration(minutes: 2);
const Duration _pairingRelayAnnouncementInterval = Duration(seconds: 15);
const Duration _saveDebounceWindow = Duration(seconds: 2);
const Duration _heartbeatInterval = Duration(seconds: 60);
const Duration _foregroundIdleHeartbeatInterval = Duration(minutes: 3);
const Duration _backgroundHeartbeatInterval = Duration(minutes: 10);
const Duration _resumeHeartbeatThreshold = Duration(seconds: 90);
const Duration _onlineReachabilityWindow = Duration(minutes: 2);
const Duration _seenRecentlyReachabilityWindow = Duration(minutes: 10);
const Duration _knownReachabilityWindow = Duration(hours: 24);
const Duration _pendingMessageRetryDelay = Duration(seconds: 5);
const Duration _acceptedMessageRetryDelay = Duration(seconds: 15);
const Duration _lanHealthCacheTtl = Duration(seconds: 15);
const Duration _internetHealthCacheTtl = Duration(seconds: 45);
const Duration _lanRecentRouteSuccessTtl = Duration(seconds: 30);
const Duration _internetRecentRouteSuccessTtl = Duration(minutes: 2);

class MessengerController extends ChangeNotifier {
  MessengerController({
    required VaultStore vaultStore,
    required RelayClient relayClient,
    LocalRelayNode? localRelayNode,
    PlatformBridge? platformBridge,
    Future<List<String>> Function()? lanAddressProvider,
    DateTime Function()? nowProvider,
  }) : _vaultStore = vaultStore,
       _relayClient = relayClient,
       _localRelayNode = localRelayNode ?? LocalRelayNode(),
       _platformBridge = platformBridge ?? PlatformBridge(),
       _lanAddressProvider = lanAddressProvider ?? discoverLanAddresses,
       _nowProvider = nowProvider ?? DateTime.now {
    _localRelayNode.onEnvelopeStored = _handleLocalEnvelopeStored;
  }

  final VaultStore _vaultStore;
  final RelayClient _relayClient;
  final LocalRelayNode _localRelayNode;
  final PlatformBridge _platformBridge;
  final Future<List<String>> Function() _lanAddressProvider;
  final DateTime Function() _nowProvider;
  VaultSnapshot _snapshot = VaultSnapshot.empty();
  Timer? _pollTimer;
  bool _ready = false;
  bool _polling = false;
  bool _appInForeground = true;
  String? _statusMessage;
  String _lastRelayStatus = 'relay not checked yet';
  String? _lastPairingAnnouncementMailboxId;
  DateTime? _lastPairingAnnouncementAt;
  DateTime? _pairingSessionActiveUntil;
  DateTime? _lastPairingBeaconSentAt;
  DateTime? _runtimeActiveUntil;
  DateTime? _nextScheduledPollAt;
  Timer? _pendingSaveTimer;
  Completer<void>? _pendingSaveCompleter;
  int _vaultSaveCount = 0;
  DateTime? _lastVaultSaveAt;
  int _fetchCallCount = 0;
  int _storeCallCount = 0;
  int _healthCallCount = 0;
  final Map<String, PeerRouteHealth> _routeHealth = {};
  final Map<String, _RouteRuntimeState> _routeRuntime = {};
  final Set<String> _debugProbeAcknowledgements = <String>{};
  final Set<String> _debugTwoWayReplies = <String>{};
  final Set<String> _locallyDeletedMessageIds = <String>{};
  final Map<String, DateTime> _outboundAttemptedAt = <String, DateTime>{};
  final Map<String, _PendingRouteUpdateProbe> _pendingRouteUpdateProbes =
      <String, _PendingRouteUpdateProbe>{};
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
  bool get isAppForeground => _appInForeground;
  String get runtimeModeLabel => _runtimeMode.name;
  DateTime? get nextScheduledPollAt => _nextScheduledPollAt;
  bool get pairingSessionActive => _isPairingSessionActive();
  DateTime? get pairingSessionActiveUntil => _pairingSessionActiveUntil;
  DateTime? get lastPairingBeaconSentAt => _lastPairingBeaconSentAt;
  int get fetchCallCount => _fetchCallCount;
  int get storeCallCount => _storeCallCount;
  int get healthCallCount => _healthCallCount;
  int get vaultSaveCount => _vaultSaveCount;
  DateTime? get lastVaultSaveAt => _lastVaultSaveAt;
  bool get localRelayRunning => _localRelayNode.isRunning;
  bool get pairingBeaconRunning => _pairingBeaconSocket != null;
  List<PeerEndpoint> get recentPairingBeaconRoutes =>
      _recentPairingBeaconRoutes();
  List<ChatMessage> get lanLobbyMessages => _lanLobbyMessages();
  bool get supportsScanner => !kIsWeb && Platform.isAndroid;
  List<PeerEndpoint> get discoveredContactRelayRoutes => _contactRelayRoutes();
  List<ContactReachabilityRecord> get reachabilityRecords =>
      List.unmodifiable(_snapshot.reachabilityRecords);
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
  int get awaitingRecipientAckCount => _snapshot.conversations.fold<int>(
    0,
    (count, conversation) =>
        count +
        conversation.messages
            .where(
              (message) => message.outbound && message.state.awaitsRecipientAck,
            )
            .length,
  );
  int unreadCountFor(String peerDeviceId) =>
      _unreadCountForConversation(_conversationFor(peerDeviceId));
  int get unreadLanLobbyCount =>
      _unreadCountForConversation(_lanLobbyConversation());
  int get seenEnvelopeCount => _snapshot.seenEnvelopeIds.length;
  PeerRouteHealth? routeHealthFor(PeerEndpoint route) =>
      _routeHealth[route.routeKey];
  ContactReachabilityRecord? reachabilityRecordFor(String deviceId) =>
      _reachabilityRecordByDeviceId(deviceId);
  ContactReachabilityState reachabilityStateFor(String deviceId) =>
      _reachabilityStateFor(deviceId);
  @visibleForTesting
  void rememberPairingBeaconRouteForTesting(PeerEndpoint route) {
    _pairingBeaconRoutes[route.routeKey] = _PairingBeaconRoute(
      route: route,
      seenAt: DateTime.now().toUtc(),
    );
  }

  @visibleForTesting
  Future<void> retryUnacknowledgedMessagesNow() =>
      _retryUnacknowledgedMessages(force: true);
  @visibleForTesting
  Future<int> runHeartbeatPassNow() async =>
      (await _runHeartbeatPass(force: true)).sentCount;
  @visibleForTesting
  Duration? get currentScheduledPollInterval => _currentPollInterval();

  DateTime _now() => _nowProvider().toUtc();

  void setAppForegroundState(bool value) {
    if (_appInForeground == value) {
      return;
    }
    _appInForeground = value;
    if (value && hasIdentity) {
      _markRuntimeActivity();
      unawaited(_pollLocalInboxOnly());
      unawaited(pollNow());
    }
    _reschedulePolling();
  }

  void activatePairingSession() {
    if (!hasIdentity) {
      return;
    }
    _pairingSessionActiveUntil = _now().add(_pairingSessionDuration);
    notifyListeners();
  }

  Future<void> refreshConversationReachabilityIfStale(String deviceId) async {
    if (!hasIdentity) {
      return;
    }
    final contact = _contactByDeviceId(deviceId);
    if (contact == null) {
      return;
    }
    final me = _requireIdentity();
    if (!_shouldRunAutomaticHeartbeats(me)) {
      return;
    }
    final now = _now();
    final record = _reachabilityRecordByDeviceId(deviceId);
    final lastTwoWaySuccessAt = record?.lastTwoWaySuccessAt;
    if (lastTwoWaySuccessAt != null &&
        now.difference(lastTwoWaySuccessAt) <= _resumeHeartbeatThreshold) {
      return;
    }
    final lastHeartbeatAttemptAt = record?.lastHeartbeatAttemptAt;
    if (lastHeartbeatAttemptAt != null &&
        now.difference(lastHeartbeatAttemptAt) < _resumeHeartbeatThreshold) {
      return;
    }
    final preferredRoutes = _preferredRoutesForContact(contact);
    PeerEndpoint? selectedRoute;
    if (preferredRoutes.isNotEmpty) {
      selectedRoute = preferredRoutes.first;
    } else {
      final checks = await _rankRouteHealthForDelivery(
        _candidateRoutesForContact(contact),
      );
      for (final check in checks) {
        if (check.available && _isRouteEligibleNow(check.route)) {
          selectedRoute = check.route;
          break;
        }
      }
    }
    if (selectedRoute == null) {
      _noteFailure(contact.deviceId, at: now);
      await _saveSnapshotSilently(debounce: true);
      return;
    }
    _noteAvailablePath(contact.deviceId, at: now);
    await _rememberLanRoutesForContact(
      deviceId: contact.deviceId,
      routes: selectedRoute.kind == PeerRouteKind.lan
          ? [selectedRoute]
          : const <PeerEndpoint>[],
    );
    final sent = await _sendRouteUpdate(
      contact,
      requestReply: true,
      reason: 'chat_resume',
      routes: [selectedRoute],
    );
    if (sent) {
      _markRuntimeActivity();
      await _saveSnapshotSilently(debounce: true);
    }
  }

  void _markRuntimeActivity() {
    _runtimeActiveUntil = _now().add(_runtimeActiveWindow);
    _reschedulePolling();
  }

  _RuntimeMode get _runtimeMode {
    final me = identity;
    if (me == null) {
      return _RuntimeMode.foregroundIdle;
    }
    final now = _now();
    if (!_appInForeground) {
      if (!kIsWeb &&
          Platform.isAndroid &&
          !me.androidBackgroundRuntimeEnabled) {
        return _RuntimeMode.backgroundDisabledAndroid;
      }
      return _RuntimeMode.backgroundEnabled;
    }
    if (_runtimeActiveUntil != null && !_runtimeActiveUntil!.isBefore(now)) {
      return _RuntimeMode.foregroundActive;
    }
    return _RuntimeMode.foregroundIdle;
  }

  Duration? _currentPollInterval() {
    final me = identity;
    if (me == null) {
      return null;
    }
    return switch (_runtimeMode) {
      _RuntimeMode.foregroundActive => _foregroundActivePollInterval,
      _RuntimeMode.foregroundIdle => _foregroundIdlePollInterval,
      _RuntimeMode.backgroundEnabled =>
        !kIsWeb && !Platform.isAndroid
            ? (awaitingRecipientAckCount > 0
                  ? _foregroundActivePollInterval
                  : _desktopBackgroundPollInterval)
            : _backgroundEnabledPollInterval,
      _RuntimeMode.backgroundDisabledAndroid => null,
    };
  }

  Duration _heartbeatIntervalForCurrentRuntime(IdentityRecord me) {
    if (!_appInForeground) {
      if (!kIsWeb && Platform.isAndroid) {
        return _backgroundHeartbeatInterval;
      }
      return _foregroundIdleHeartbeatInterval;
    }
    return switch (_runtimeMode) {
      _RuntimeMode.foregroundActive => _heartbeatInterval,
      _RuntimeMode.foregroundIdle => _foregroundIdleHeartbeatInterval,
      _RuntimeMode.backgroundEnabled => _backgroundHeartbeatInterval,
      _RuntimeMode.backgroundDisabledAndroid => _backgroundHeartbeatInterval,
    };
  }

  void _reschedulePolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _nextScheduledPollAt = null;
    if (!hasIdentity) {
      notifyListeners();
      return;
    }
    final interval = _currentPollInterval();
    if (interval == null) {
      notifyListeners();
      return;
    }
    _nextScheduledPollAt = _now().add(interval);
    _pollTimer = Timer(interval, () {
      _pollTimer = null;
      _nextScheduledPollAt = null;
      unawaited(pollNow());
    });
    notifyListeners();
  }

  bool _isPairingSessionActive() {
    final activeUntil = _pairingSessionActiveUntil;
    return activeUntil != null && !activeUntil.isBefore(_now());
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
      final normalized = _normalizeStoredContactRoutes();
      if (normalized) {
        await _saveSnapshotSilently(notify: false);
      }
      if (_snapshot.identity != null) {
        await _refreshLanAddresses(persist: false);
        await _ensureLocalRelayRunning();
        await _ensurePairingBeaconRunning();
        _applyAndroidBackgroundPreference();
        _reschedulePolling();
        unawaited(_pollLocalInboxOnly());
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

  ContactReachabilityRecord? _reachabilityRecordByDeviceId(String deviceId) {
    for (final record in _snapshot.reachabilityRecords) {
      if (record.deviceId == deviceId) {
        return record;
      }
    }
    return null;
  }

  ContactReachabilityRecord _ensureReachabilityRecord(String deviceId) {
    return _reachabilityRecordByDeviceId(deviceId) ??
        ContactReachabilityRecord(deviceId: deviceId);
  }

  void _upsertReachabilityRecord(
    String deviceId,
    ContactReachabilityRecord Function(ContactReachabilityRecord current)
    update,
  ) {
    final current = _ensureReachabilityRecord(deviceId);
    final updated = update(current);
    final records = List<ContactReachabilityRecord>.from(
      _snapshot.reachabilityRecords,
    );
    final index = records.indexWhere((record) => record.deviceId == deviceId);
    if (index == -1) {
      records.add(updated);
    } else {
      records[index] = updated;
    }
    _snapshot = _snapshot.copyWith(reachabilityRecords: records);
  }

  void _removeReachabilityRecord(String deviceId) {
    final records = _snapshot.reachabilityRecords
        .where((record) => record.deviceId != deviceId)
        .toList(growable: false);
    _snapshot = _snapshot.copyWith(reachabilityRecords: records);
  }

  void _noteAnySignal(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _now()).toUtc();
    _upsertReachabilityRecord(
      deviceId,
      (current) => current.copyWith(lastAnySignalAt: timestamp),
    );
  }

  void _noteTwoWaySuccess(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _now()).toUtc();
    _upsertReachabilityRecord(
      deviceId,
      (current) => current.copyWith(
        lastTwoWaySuccessAt: timestamp,
        lastAnySignalAt: timestamp,
      ),
    );
  }

  void _noteHeartbeatAttempt(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _now()).toUtc();
    _upsertReachabilityRecord(
      deviceId,
      (current) => current.copyWith(lastHeartbeatAttemptAt: timestamp),
    );
  }

  void _noteHeartbeatReply(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _now()).toUtc();
    _upsertReachabilityRecord(
      deviceId,
      (current) => current.copyWith(lastHeartbeatReplyAt: timestamp),
    );
  }

  void _noteAvailablePath(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _now()).toUtc();
    _upsertReachabilityRecord(
      deviceId,
      (current) => current.copyWith(lastAvailablePathAt: timestamp),
    );
  }

  void _noteFailure(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _now()).toUtc();
    _upsertReachabilityRecord(
      deviceId,
      (current) => current.copyWith(lastFailureAt: timestamp),
    );
  }

  ContactReachabilityState _reachabilityStateFor(
    String deviceId, {
    DateTime? now,
  }) {
    final record = _reachabilityRecordByDeviceId(deviceId);
    if (record == null) {
      return ContactReachabilityState.unknown;
    }
    final currentTime = (now ?? _now()).toUtc();
    final lastTwoWaySuccessAt = record.lastTwoWaySuccessAt;
    if (lastTwoWaySuccessAt != null &&
        currentTime.difference(lastTwoWaySuccessAt) <=
            _onlineReachabilityWindow) {
      return ContactReachabilityState.online;
    }
    final recentObservation = _latestTimestamp([
      record.lastAvailablePathAt,
      record.lastAnySignalAt,
    ]);
    if (recentObservation != null &&
        currentTime.difference(recentObservation) <=
            _seenRecentlyReachabilityWindow) {
      return ContactReachabilityState.seenRecently;
    }
    if (lastTwoWaySuccessAt != null &&
        currentTime.difference(lastTwoWaySuccessAt) <=
            _knownReachabilityWindow) {
      return ContactReachabilityState.known;
    }
    return ContactReachabilityState.unknown;
  }

  bool _shouldRunAutomaticHeartbeats(IdentityRecord me) {
    if (!Platform.isAndroid) {
      return true;
    }
    return _appInForeground || me.androidBackgroundRuntimeEnabled;
  }

  DateTime? _latestTimestamp(Iterable<DateTime?> values) {
    DateTime? latest;
    for (final value in values) {
      if (value == null) {
        continue;
      }
      if (latest == null || value.isAfter(latest)) {
        latest = value;
      }
    }
    return latest;
  }

  Future<void> refreshPairingAdvertisement() async {
    if (!hasIdentity) {
      return;
    }
    activatePairingSession();
    await _refreshLanAddresses(persist: false);
    await _ensureLocalRelayRunning();
    await _ensurePairingBeaconRunning();
    await _sendPairingRouteBeacon();
    await _announcePairingAvailabilityIfNeeded();
  }

  Future<ContactInvite> rotatePairingCodeNow() async {
    final me = _requireIdentity();
    activatePairingSession();
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
    buffer.writeln('runtimeMode=$runtimeModeLabel');
    buffer.writeln(
      'nextScheduledPollAt=${nextScheduledPollAt?.toIso8601String() ?? ''}',
    );
    buffer.writeln('lastRelayStatus=$lastRelayStatus');
    buffer.writeln('localRelayRunning=$localRelayRunning');
    buffer.writeln('pairingSessionActive=$pairingSessionActive');
    buffer.writeln(
      'pairingSessionActiveUntil=${pairingSessionActiveUntil?.toIso8601String() ?? ''}',
    );
    buffer.writeln(
      'lastPairingBeaconSentAt=${lastPairingBeaconSentAt?.toIso8601String() ?? ''}',
    );
    buffer.writeln('fetchCalls=$fetchCallCount');
    buffer.writeln('storeCalls=$storeCallCount');
    buffer.writeln('healthCalls=$healthCallCount');
    buffer.writeln('vaultSaveCount=$vaultSaveCount');
    buffer.writeln(
      'lastVaultSaveAt=${lastVaultSaveAt?.toIso8601String() ?? ''}',
    );
    buffer.writeln('routeBackoffSummary=${_globalRouteBackoffSummary()}');
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
      buffer.writeln('suppressReadReceipts=${me.suppressReadReceipts}');
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
      final reachability = _reachabilityRecordByDeviceId(contact.deviceId);
      buffer.writeln(
        'contact alias=${contact.alias} device=${contact.deviceId} relayCapable=${contact.relayCapable} reachability=${_reachabilityStateFor(contact.deviceId).name} lastTwoWaySuccessAt=${reachability?.lastTwoWaySuccessAt?.toIso8601String() ?? ''} lastHeartbeatAttemptAt=${reachability?.lastHeartbeatAttemptAt?.toIso8601String() ?? ''} lastHeartbeatReplyAt=${reachability?.lastHeartbeatReplyAt?.toIso8601String() ?? ''} lastAvailablePathAt=${reachability?.lastAvailablePathAt?.toIso8601String() ?? ''} lastAnySignalAt=${reachability?.lastAnySignalAt?.toIso8601String() ?? ''} lastFailureAt=${reachability?.lastFailureAt?.toIso8601String() ?? ''} routeBackoff=${_routeBackoffSummaryForRoutes(_candidateRoutesForContact(contact))} routes=${contact.prioritizedRouteHints.map((route) => '${route.kind.name}:${route.label}:${routeHealthFor(route)?.summary ?? 'not checked'}').join(' | ')}',
      );
    }
    buffer.writeln('totalMessages=$totalMessageCount');
    buffer.writeln('pendingOutbound=$pendingOutboundCount');
    buffer.writeln('awaitingRecipientAck=$awaitingRecipientAckCount');
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
      buffer.writeln('lastDebugRunPeerReports=${report.peerReports.length}');
      for (final peer in report.peerReports) {
        buffer.writeln(
          'peer alias=${peer.alias} device=${peer.deviceId} reachability=${peer.reachability.name} availablePaths=${peer.availablePathCount}/${peer.totalPathCount} lanPathAvailable=${peer.lanPathAvailable} directInternetPathAvailable=${peer.directInternetPathAvailable} relayPathAvailable=${peer.relayPathAvailable} expectedBestDeliveryState=${peer.expectedBestDeliveryState} heartbeatAttempted=${peer.heartbeatAttempted} heartbeatReplyReceived=${peer.heartbeatReplyReceived} bestPath=${peer.bestPathSummary} probeAccepted=${peer.probeAccepted} probeAcknowledged=${peer.probeAcknowledged} twoWayAccepted=${peer.twoWayAccepted} twoWayReplyReceived=${peer.twoWayReplyReceived} relayProbeAccepted=${peer.relayProbeAccepted} lastTwoWaySuccessAt=${peer.lastTwoWaySuccessAt?.toIso8601String() ?? ''} lastHeartbeatReplyAt=${peer.lastHeartbeatReplyAt?.toIso8601String() ?? ''} lastAvailablePathAt=${peer.lastAvailablePathAt?.toIso8601String() ?? ''} routes=${peer.routeSummary}',
        );
      }
      for (final note in report.notes) {
        buffer.writeln('note=$note');
      }
      for (final result in report.results) {
        buffer.writeln(
          'check status=${result.status.name} name=${result.name} detail=${result.detail}',
        );
      }
    }
    return buffer.toString();
  }

  String buildDebugAnalysisText({DebugRunReport? report}) {
    final buffer = StringBuffer();
    buffer.writeln(buildDebugSnapshotText(report: report));
    if (report == null) {
      return buffer.toString();
    }
    buffer.writeln();
    buffer.writeln('Conest debug analysis');
    buffer.writeln(
      'summary=pass:${report.passed} warn:${report.warned} fail:${report.failed} skip:${report.skipped}',
    );
    buffer.writeln('devicesInScope=${report.deviceCount}');
    if (report.peerReports.isNotEmpty) {
      buffer.writeln(
        'peerCoverage=available:${report.peersWithAvailablePaths}/${report.peerReports.length} probeAck:${report.peersWithProbeAck}/${report.peerReports.length} twoWayReply:${report.peersWithTwoWayReply}/${report.peerReports.length} relayProbe:${report.peersWithRelayProbe}/${report.peerReports.length}',
      );
      for (final peer in report.peerReports) {
        buffer.writeln(
          'peerSummary ${peer.alias} (${peer.deviceId}): reachability=${peer.reachability.label}, paths=${peer.availablePathCount}/${peer.totalPathCount}, heartbeat=${peer.heartbeatReplyReceived}, probeAck=${peer.probeAcknowledged}, twoWayReply=${peer.twoWayReplyReceived}, relayProbe=${peer.relayProbeAccepted}, bestState=${peer.expectedBestDeliveryState}, bestPath=${peer.bestPathSummary}',
        );
      }
    }
    if (report.notes.isNotEmpty) {
      buffer.writeln('notes=');
      for (final note in report.notes) {
        buffer.writeln('- $note');
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
    _setTransientStatus(
      'Checked ${checks.length} route(s); $available available. '
      '${protocolRefresh.addedRoutes.isEmpty ? 'No new relay protocols detected.' : 'Added ${protocolRefresh.addedRoutes.map((route) => route.label).join(', ')}.'}',
    );
    if (protocolRefresh.addedRoutes.isNotEmpty) {
      await _saveSnapshotSilently(debounce: true);
    }
  }

  Future<List<PeerRouteHealth>> checkContactRoutes(
    ContactRecord contact, {
    bool persist = true,
    bool exchangeRouteUpdate = true,
    bool fast = false,
  }) async {
    _markRuntimeActivity();
    await _refreshLanAddresses(persist: false);
    await _ensureLocalRelayRunning();
    await _ensurePairingBeaconRunning();
    final pingSent = await _sendPairingDiscoveryPing();
    if (pingSent) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final current = _contactByDeviceId(contact.deviceId) ?? contact;
    final candidateRoutes = _candidateRoutesForContact(current);
    final checks = fast
        ? await _rankRouteHealthForDebug(candidateRoutes)
        : await _rankRouteHealthForDelivery(candidateRoutes);
    final availableChecks = checks.where((check) => check.available).toList();
    if (availableChecks.isNotEmpty) {
      _noteAvailablePath(current.deviceId);
      await _rememberLanRoutesForContact(
        deviceId: current.deviceId,
        routes: availableChecks
            .map((check) => check.route)
            .where((route) => route.kind == PeerRouteKind.lan),
      );
    }
    final routeUpdateSent = exchangeRouteUpdate && availableChecks.isNotEmpty
        ? await _sendRouteUpdate(
            current,
            requestReply: true,
            reason: 'check_paths',
            routes: [availableChecks.first.route],
          )
        : false;
    if (persist) {
      final available = availableChecks.length;
      _setTransientStatus(
        checks.isEmpty
            ? 'No paths are advertised for ${current.alias}.'
            : 'Checked ${checks.length} path(s) for ${current.alias}; $available available. Reachability is ${_reachabilityStateFor(current.deviceId).label}. ${routeUpdateSent ? 'Route info exchange requested.' : 'Route info exchange could not be sent yet.'}',
      );
      await _saveSnapshotSilently(debounce: true);
    } else {
      await _saveSnapshotSilently(debounce: true);
    }
    return checks;
  }

  Future<DebugRunReport> runDebugSelfTest() async {
    final startedAt = DateTime.now().toUtc();
    final results = <DebugCheckResult>[];
    final peerReports = <DebugPeerReport>[];
    final notes = <String>[];
    _debugProbeAcknowledgements.clear();
    _debugTwoWayReplies.clear();
    activatePairingSession();
    _markRuntimeActivity();

    void add(String name, DebugCheckStatus status, String detail) {
      results.add(DebugCheckResult(name: name, status: status, detail: detail));
    }

    int peerCountWhere(bool Function(DebugPeerReport peer) predicate) {
      return peerReports.where(predicate).length;
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
        peerReports: peerReports,
        notes: notes,
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
        peerReports: peerReports,
        notes: notes,
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
      final pairingCodes = pairingCodephrasesForPayload(payload);
      final payloadBytes = utf8.encode(payload).length;
      add(
        'Invite codec',
        decoded.deviceId == me.deviceId
            ? DebugCheckStatus.pass
            : DebugCheckStatus.fail,
        'Invite payload round-tripped; current codephrase is $code.',
      );
      add(
        'Invite payload size',
        payloadBytes <= 900 && decoded.routeHints.length <= _maxInviteRouteHints
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        '$payloadBytes byte(s), ${decoded.routeHints.length}/$_maxInviteRouteHints route hint(s). QR stays compact by publishing only ranked LAN/relay hints.',
      );
      add(
        'Pairing code window',
        pairingCodeWindow >= const Duration(seconds: 90) &&
                pairingCodes.length >= 2
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        '${pairingCodeWindow.inSeconds}s visible window; ${pairingCodes.length} adjacent mailbox code(s) are announced to tolerate rotation during pairing.',
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
      final hotspotLikeAddresses = current.lanAddresses
          .where(_looksLikeHotspotGatewayAddress)
          .toList(growable: false);
      add(
        'Hotspot LAN handling',
        DebugCheckStatus.pass,
        hotspotLikeAddresses.isEmpty
            ? 'No hotspot-like gateway LAN address is active. Nearby LAN rediscovery is still enabled for LAN peers.'
            : 'Hotspot-like LAN gateway address(es): ${hotspotLikeAddresses.join(', ')}. Nearby hotspot clients will be probed on the same subnet for pairing and route rediscovery.',
      );
    } catch (error) {
      add('LAN addresses', DebugCheckStatus.fail, 'LAN scan failed: $error');
    }

    final pairingBeacon = await _runPairingBeaconCheck();
    add(pairingBeacon.name, pairingBeacon.status, pairingBeacon.detail);
    final pairingSessionPolicy = _runPairingSessionPolicyCheck();
    add(
      pairingSessionPolicy.name,
      pairingSessionPolicy.status,
      pairingSessionPolicy.detail,
    );

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
      fast: true,
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
    final backgroundHeartbeatPolicy = _runBackgroundHeartbeatPolicyCheck(
      _requireIdentity(),
    );
    add(
      backgroundHeartbeatPolicy.name,
      backgroundHeartbeatPolicy.status,
      backgroundHeartbeatPolicy.detail,
    );
    final runtimeSchedulerPolicy = _runAdaptiveRuntimeSchedulerCheck(
      _requireIdentity(),
    );
    add(
      runtimeSchedulerPolicy.name,
      runtimeSchedulerPolicy.status,
      runtimeSchedulerPolicy.detail,
    );

    final routeProtocolCoverage = _runRouteProtocolCoverageCheck(
      _requireIdentity(),
    );
    add(
      routeProtocolCoverage.name,
      routeProtocolCoverage.status,
      routeProtocolCoverage.detail,
    );
    final autoContactRelayCheck = await _runAutoContactRelayCheck(
      _requireIdentity(),
    );
    add(
      autoContactRelayCheck.name,
      autoContactRelayCheck.status,
      autoContactRelayCheck.detail,
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
      final checks = await _rankRouteHealthForDebug(relayRoutes);
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
      final contactChecks = <String, List<PeerRouteHealth>>{};
      for (final contact in contacts) {
        final checks = await checkContactRoutes(
          contact,
          persist: false,
          exchangeRouteUpdate: false,
          fast: true,
        );
        contactChecks[contact.deviceId] = checks;
        final available = checks.where((check) => check.available).toList();
        if (available.isNotEmpty) {
          contactsWithPath++;
        }
        add(
          'Paths to ${contact.alias}',
          available.isEmpty ? DebugCheckStatus.warn : DebugCheckStatus.pass,
          checks.isEmpty
              ? 'No advertised paths.'
              : _summarizeRouteChecks(checks),
        );
      }
      add(
        'Two-device readiness',
        contactsWithPath == contacts.length
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        '$contactsWithPath/${contacts.length} contact(s) have at least one currently available path.',
      );
      final heartbeatAttemptBaseline = <String, DateTime?>{};
      final heartbeatReplyBaseline = <String, DateTime?>{};
      for (final contact in contacts) {
        final record = _reachabilityRecordByDeviceId(contact.deviceId);
        heartbeatAttemptBaseline[contact.deviceId] =
            record?.lastHeartbeatAttemptAt;
        heartbeatReplyBaseline[contact.deviceId] = record?.lastHeartbeatReplyAt;
      }
      await _runHeartbeatPass(force: true);
      final heartbeatAttemptedIds = <String>{};
      for (final contact in contacts) {
        final record = _reachabilityRecordByDeviceId(contact.deviceId);
        final attemptAt = record?.lastHeartbeatAttemptAt;
        final baseline = heartbeatAttemptBaseline[contact.deviceId];
        if (attemptAt != null &&
            !attemptAt.isBefore(startedAt) &&
            (baseline == null || attemptAt.isAfter(baseline))) {
          heartbeatAttemptedIds.add(contact.deviceId);
        }
      }
      await _waitForHeartbeatResponses(
        heartbeatAttemptedIds,
        startedAt: startedAt,
      );
      final stateCounts = <ContactReachabilityState, int>{
        for (final state in ContactReachabilityState.values) state: 0,
      };
      for (final contact in contacts) {
        stateCounts[_reachabilityStateFor(contact.deviceId)] =
            (stateCounts[_reachabilityStateFor(contact.deviceId)] ?? 0) + 1;
      }
      final unknownReachability =
          stateCounts[ContactReachabilityState.unknown]!;
      add(
        'Heartbeat reachability',
        unknownReachability == 0
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        ContactReachabilityState.values
            .map((state) => '${state.label} ${stateCounts[state]}')
            .join(' • '),
      );

      var probesAccepted = 0;
      var relayProbesAccepted = 0;
      var twoWayAccepted = 0;
      final probeMessageIds = <String, String>{};
      final relayProbeMessageIds = <String, String>{};
      final twoWayMessageIds = <String, String>{};
      for (final contact in contacts) {
        final checks = contactChecks[contact.deviceId];
        final probeMessageId = await _sendDebugProbe(
          contact: contact,
          rankedChecks: checks,
        );
        if (probeMessageId != null) {
          probesAccepted++;
          probeMessageIds[contact.deviceId] = probeMessageId;
        }
        final relayProbeMessageId = await _sendDebugProbe(
          contact: contact,
          relayOnly: true,
          rankedChecks: checks,
        );
        if (relayProbeMessageId != null) {
          relayProbesAccepted++;
          relayProbeMessageIds[contact.deviceId] = relayProbeMessageId;
        }
        final twoWayMessageId = await _sendDebugTwoWayMessage(
          contact,
          rankedChecks: checks,
        );
        if (twoWayMessageId != null) {
          twoWayAccepted++;
          twoWayMessageIds[contact.deviceId] = twoWayMessageId;
        }
      }
      final expectedProbeAckIds = probeMessageIds.values.toSet();
      final expectedTwoWayReplyIds = twoWayMessageIds.values.toSet();
      if (expectedProbeAckIds.isNotEmpty || expectedTwoWayReplyIds.isNotEmpty) {
        await _waitForDebugResponses(
          expectedProbeAckIds: expectedProbeAckIds,
          expectedTwoWayReplyIds: expectedTwoWayReplyIds,
        );
      }
      final probeAcknowledgementsReceived = expectedProbeAckIds
          .where(_debugProbeAcknowledgements.contains)
          .length;
      final twoWayRepliesReceived = expectedTwoWayReplyIds
          .where(_debugTwoWayReplies.contains)
          .length;
      add(
        'Debug peer probes',
        probesAccepted == 0 ? DebugCheckStatus.warn : DebugCheckStatus.pass,
        'Accepted $probesAccepted/${contacts.length} probe send(s). Remote debug builds answer when they poll.',
      );
      add(
        'Debug probe acknowledgements',
        probesAccepted > 0 && probeAcknowledgementsReceived == probesAccepted
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        probesAccepted == 0
            ? 'No debug probes were accepted, so no acknowledgements were expected.'
            : 'Received $probeAcknowledgementsReceived/$probesAccepted debug acknowledgement(s).',
      );
      add(
        'Two-way debug messaging',
        twoWayAccepted == 0 ? DebugCheckStatus.warn : DebugCheckStatus.pass,
        'Sent $twoWayAccepted/${contacts.length} debug message request(s). Remote debug builds send a reply when they poll.',
      );
      add(
        'Two-way debug replies',
        twoWayAccepted > 0 && twoWayRepliesReceived == twoWayAccepted
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        twoWayAccepted == 0
            ? 'No two-way debug messages were accepted, so no replies were expected.'
            : 'Received $twoWayRepliesReceived/$twoWayAccepted two-way reply/replies.',
      );

      for (final contact in contacts) {
        final checks =
            contactChecks[contact.deviceId] ?? const <PeerRouteHealth>[];
        final availableChecks = checks
            .where((check) => check.available)
            .toList();
        final bestAvailableCheck = availableChecks.isNotEmpty
            ? availableChecks.first
            : null;
        final reachability = _reachabilityRecordByDeviceId(contact.deviceId);
        final heartbeatAttemptAt = reachability?.lastHeartbeatAttemptAt;
        final heartbeatReplyAt = reachability?.lastHeartbeatReplyAt;
        final probeMessageId = probeMessageIds[contact.deviceId];
        final relayProbeMessageId = relayProbeMessageIds[contact.deviceId];
        final twoWayMessageId = twoWayMessageIds[contact.deviceId];
        peerReports.add(
          DebugPeerReport(
            alias: contact.alias,
            deviceId: contact.deviceId,
            reachability: _reachabilityStateFor(contact.deviceId),
            availablePathCount: availableChecks.length,
            totalPathCount: checks.length,
            lanPathAvailable: availableChecks.any(
              (check) => check.route.kind == PeerRouteKind.lan,
            ),
            directInternetPathAvailable: availableChecks.any(
              (check) => check.route.kind == PeerRouteKind.directInternet,
            ),
            bestPathSummary: bestAvailableCheck == null
                ? 'No advertised paths.'
                : bestAvailableCheck.summary,
            expectedBestDeliveryState: bestAvailableCheck == null
                ? DeliveryState.pending.name
                : _expectedDeliveryStateLabelForRoute(bestAvailableCheck.route),
            routeSummary: checks.isEmpty
                ? 'No advertised paths.'
                : _summarizeRouteChecks(checks),
            heartbeatAttempted:
                heartbeatAttemptAt != null &&
                !heartbeatAttemptAt.isBefore(startedAt) &&
                (heartbeatAttemptBaseline[contact.deviceId] == null ||
                    heartbeatAttemptAt.isAfter(
                      heartbeatAttemptBaseline[contact.deviceId]!,
                    )),
            heartbeatReplyReceived:
                heartbeatReplyAt != null &&
                !heartbeatReplyAt.isBefore(startedAt) &&
                (heartbeatReplyBaseline[contact.deviceId] == null ||
                    heartbeatReplyAt.isAfter(
                      heartbeatReplyBaseline[contact.deviceId]!,
                    )),
            probeAccepted: probeMessageId != null,
            probeAcknowledged:
                probeMessageId != null &&
                _debugProbeAcknowledgements.contains(probeMessageId),
            twoWayAccepted: twoWayMessageId != null,
            twoWayReplyReceived:
                twoWayMessageId != null &&
                _debugTwoWayReplies.contains(twoWayMessageId),
            relayProbeAccepted: relayProbeMessageId != null,
            relayPathAvailable: checks.any(
              (check) =>
                  check.available && check.route.kind == PeerRouteKind.relay,
            ),
            lastTwoWaySuccessAt: reachability?.lastTwoWaySuccessAt,
            lastHeartbeatReplyAt: reachability?.lastHeartbeatReplyAt,
            lastAvailablePathAt: reachability?.lastAvailablePathAt,
          ),
        );
      }

      add(
        'Heartbeat exchange',
        peerReports.isNotEmpty &&
                peerReports
                    .where((peer) => peer.availablePathCount > 0)
                    .every(
                      (peer) =>
                          peer.heartbeatAttempted &&
                          peer.heartbeatReplyReceived,
                    )
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        peerReports.isEmpty
            ? 'No peer heartbeat data was collected.'
            : 'heartbeat attempts ${peerCountWhere((peer) => peer.heartbeatAttempted)}/${peerReports.length} • heartbeat replies ${peerCountWhere((peer) => peer.heartbeatReplyReceived)}/${peerReports.length}',
      );

      add(
        'Peer result matrix',
        peerReports.isNotEmpty &&
                peerReports.every(
                  (peer) =>
                      peer.availablePathCount > 0 &&
                      (!peer.probeAccepted || peer.probeAcknowledged) &&
                      (!peer.twoWayAccepted || peer.twoWayReplyReceived),
                )
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        peerReports.isEmpty
            ? 'No peer result data was collected.'
            : 'available paths ${peerCountWhere((peer) => peer.availablePathCount > 0)}/${peerReports.length} • probe ack ${peerCountWhere((peer) => peer.probeAcknowledged)}/${peerReports.length} • two-way replies ${peerCountWhere((peer) => peer.twoWayReplyReceived)}/${peerReports.length} • relay probes ${peerCountWhere((peer) => peer.relayProbeAccepted)}/${peerReports.length}',
      );
      add(
        'Delivery path coverage',
        peerReports.isNotEmpty &&
                peerReports
                    .where((peer) => peer.availablePathCount > 0)
                    .every(
                      (peer) =>
                          peer.expectedBestDeliveryState !=
                              DeliveryState.pending.name &&
                          (!peer.relayPathAvailable || peer.relayProbeAccepted),
                    )
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        peerReports.isEmpty
            ? 'No delivery path data was collected.'
            : 'LAN ${peerCountWhere((peer) => peer.lanPathAvailable)}/${peerReports.length} • direct internet ${peerCountWhere((peer) => peer.directInternetPathAvailable)}/${peerReports.length} • relay ${peerCountWhere((peer) => peer.relayPathAvailable)}/${peerReports.length} • relay fallback verified ${peerCountWhere((peer) => !peer.relayPathAvailable || peer.relayProbeAccepted)}/${peerReports.length}',
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
      if (contacts.length >= 2) {
        final fullMeshReady = peerReports.every(
          (peer) =>
              peer.availablePathCount > 0 &&
              peer.probeAcknowledged &&
              peer.twoWayReplyReceived &&
              peer.relayProbeAccepted,
        );
        add(
          'Three-device full mesh coverage',
          fullMeshReady ? DebugCheckStatus.pass : DebugCheckStatus.warn,
          'For 3 devices, this device currently sees ${peerCountWhere((peer) => peer.availablePathCount > 0)}/${peerReports.length} peers with paths, ${peerCountWhere((peer) => peer.probeAcknowledged)}/${peerReports.length} probe ack(s), ${peerCountWhere((peer) => peer.twoWayReplyReceived)}/${peerReports.length} two-way reply/replies, ${peerCountWhere((peer) => peer.relayProbeAccepted)}/${peerReports.length} relay probe acceptance(s).',
        );
      } else {
        add(
          'Three-device full mesh coverage',
          DebugCheckStatus.skip,
          'Need this device plus at least two contacts to judge a 3-device Windows/Linux/Android run from one report.',
        );
      }
    }

    final relayLoopback = await _runRelayLoopbackCheck(
      _requireIdentity(),
      fast: true,
    );
    add(relayLoopback.name, relayLoopback.status, relayLoopback.detail);
    final relayPairingReuse = await _runRelayPairingReuseCheck(
      _requireIdentity(),
      fast: true,
    );
    add(
      relayPairingReuse.name,
      relayPairingReuse.status,
      relayPairingReuse.detail,
    );
    if (relayRoutes.isEmpty) {
      add(
        'Offline relay readiness',
        DebugCheckStatus.skip,
        'No relay route is configured, so delayed/offline relay delivery cannot be exercised.',
      );
    } else {
      final relayReachablePeers = peerReports
          .where((peer) => peer.relayPathAvailable)
          .length;
      final relayOnlyPeers = peerReports
          .where(
            (peer) =>
                peer.relayPathAvailable &&
                !peer.lanPathAvailable &&
                !peer.directInternetPathAvailable,
          )
          .length;
      add(
        'Offline relay readiness',
        relayLoopback.status == DebugCheckStatus.pass
            ? DebugCheckStatus.pass
            : DebugCheckStatus.warn,
        'Relay loopback is ${relayLoopback.status.name}; peers with relay availability $relayReachablePeers/${peerReports.length}; relay-only peers $relayOnlyPeers. This covers queue/store readiness; final delivery still depends on the recipient polling or resuming.',
      );
    }

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
      pendingOutboundCount == 0 && awaitingRecipientAckCount == 0
          ? DebugCheckStatus.pass
          : DebugCheckStatus.warn,
      '$pendingOutboundCount pending retry message(s), $awaitingRecipientAckCount outbound message(s) still waiting for a recipient ack, $totalMessageCount total message(s).',
    );

    final elapsed = DateTime.now().toUtc().difference(startedAt);
    add(
      'Debug runtime',
      elapsed <= const Duration(seconds: 30)
          ? DebugCheckStatus.pass
          : DebugCheckStatus.warn,
      'Completed in ${elapsed.inMilliseconds}ms. Debug checks use shorter probe timeouts than production delivery.',
    );

    notes.add(
      'Automated checks cover invite/pairing codec, adaptive polling/runtime policy, pairing-session gating, LAN beaconing, local relay runtime, relay protocol availability, path health, heartbeat reachability, peer debug probes, two-way debug messaging, relay loopback, pairing reuse, queue state, and local message action cleanup.',
    );
    notes.add(
      'Relay transport checks are host-agnostic: a public relay uses the same TCP/UDP/HTTP/HTTPS health/store/fetch code paths as a LAN-hosted relay; only the configured host or domain changes.',
    );
    notes.add(
      'For a 3-device run, open Debug menu on Windows, Linux, and Android, tap Run Debug Tests on each device, then copy the analysis bundle from each one and compare the peer lines and summary counts.',
    );
    notes.add(
      'Manual-only validation still matters for QR camera scanning, OS-level notification display timing, Android battery/background restrictions, and public internet reachability from networks outside your LAN.',
    );

    await _persist(
      'Debug test finished: ${results.where((result) => result.status == DebugCheckStatus.fail).length} failed, ${results.where((result) => result.status == DebugCheckStatus.warn).length} warning(s).',
    );

    return DebugRunReport(
      startedAt: startedAt,
      completedAt: DateTime.now().toUtc(),
      deviceCount: contacts.length + 1,
      results: results,
      peerReports: peerReports,
      notes: notes,
    );
  }

  Future<void> updateDisplayName(String displayName) async {
    final me = _requireIdentity();
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Display name is required.');
    }
    _snapshot = _snapshot.copyWith(identity: me.copyWith(displayName: trimmed));
    await _announcePairingAvailabilityIfNeeded();
    await _persist('Display name updated.');
  }

  Future<void> updateBio(String bio) async {
    final me = _requireIdentity();
    final trimmed = bio.trim();
    _snapshot = _snapshot.copyWith(identity: me.copyWith(bio: trimmed));
    await _announcePairingAvailabilityIfNeeded();
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
    await _announcePairingAvailabilityIfNeeded();
    _markRuntimeActivity();
    await _persist(enabled ? 'Relay mode enabled.' : 'Relay mode disabled.');
  }

  Future<void> updateAutoUseContactRelays(bool enabled) async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(autoUseContactRelays: enabled),
    );
    await _announcePairingAvailabilityIfNeeded();
    _markRuntimeActivity();
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
    _reschedulePolling();
    await _persist(
      enabled
          ? 'Android background runtime enabled. If system battery/background access is blocked, notifications can still be late or never arrive.'
          : 'Android background runtime disabled.',
    );
  }

  Future<void> updateSuppressReadReceipts(bool enabled) async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(suppressReadReceipts: enabled),
    );
    await _persist(
      enabled
          ? 'Read confirmations disabled on this debug build. Only delivery acknowledgements will be sent.'
          : 'Read confirmations enabled on this debug build.',
    );
  }

  Future<void> updateLocalRelayPort(int port) async {
    if (port <= 0 || port > 65535) {
      throw ArgumentError('Relay port must be between 1 and 65535.');
    }
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(identity: me.copyWith(localRelayPort: port));
    await _ensureLocalRelayRunning();
    await _announcePairingAvailabilityIfNeeded();
    _markRuntimeActivity();
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
    await _announcePairingAvailabilityIfNeeded();
    _markRuntimeActivity();
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
      PeerEndpoint(
        kind: PeerRouteKind.relay,
        host: parsed.host,
        port: parsed.port,
        protocol: PeerRouteProtocol.http,
      ),
      PeerEndpoint(
        kind: PeerRouteKind.relay,
        host: parsed.host,
        port: parsed.port,
        protocol: PeerRouteProtocol.https,
      ),
      if (!parsed.hasExplicitPort && parsed.port != 80)
        PeerEndpoint(
          kind: PeerRouteKind.relay,
          host: parsed.host,
          port: 80,
          protocol: PeerRouteProtocol.http,
        ),
      if (!parsed.hasExplicitPort && parsed.port != 443)
        PeerEndpoint(
          kind: PeerRouteKind.relay,
          host: parsed.host,
          port: 443,
          protocol: PeerRouteProtocol.https,
        ),
    ];
    final dedupedCandidates = dedupePeerEndpoints(candidates);
    if (!detectProtocols) {
      return dedupedCandidates;
    }
    final checks = await Future.wait(
      dedupedCandidates.map((route) => _checkRouteHealth(route)),
    );
    final detected = checks
        .where((check) => check.available)
        .map((check) => check.route)
        .toList(growable: false);
    if (detected.isEmpty) {
      throw ArgumentError(
        'Relay ${parsed.host}:${parsed.port} did not answer over TCP, UDP, HTTP, or HTTPS. '
        'Check the tunnel/origin, or use tcp://, udp://, http://, or https:// to force a protocol.',
      );
    }
    return detected;
  }

  String _protocolSummary(List<PeerEndpoint> routes) {
    final protocols = routes.map((route) => route.protocol.name.toUpperCase());
    return protocols.join('+');
  }

  Future<_RelayProtocolRefreshResult> _refreshConfiguredRelayProtocols(
    IdentityRecord me, {
    bool fast = false,
  }) async {
    final candidates = _relayProtocolCandidatesFor(me.configuredRelays);
    if (candidates.isEmpty) {
      return const _RelayProtocolRefreshResult(
        checkedRoutes: 0,
        availableRoutes: 0,
        addedRoutes: <PeerEndpoint>[],
      );
    }
    final checks = fast
        ? await _rankRouteHealthForDebug(candidates)
        : await Future.wait(candidates.map(_checkRouteHealth));
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
      await _announcePairingAvailabilityIfNeeded();
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
    final routes = <PeerEndpoint>[
      PeerEndpoint(kind: kind, host: host, port: port),
      PeerEndpoint(
        kind: kind,
        host: host,
        port: port,
        protocol: PeerRouteProtocol.udp,
      ),
    ];
    if (kind == PeerRouteKind.relay) {
      routes.addAll([
        PeerEndpoint(
          kind: kind,
          host: host,
          port: port,
          protocol: PeerRouteProtocol.http,
        ),
        PeerEndpoint(
          kind: kind,
          host: host,
          port: port,
          protocol: PeerRouteProtocol.https,
        ),
      ]);
    }
    return routes;
  }

  Future<void> removeRelay(PeerEndpoint relay) async {
    final me = _requireIdentity();
    final updated = me.configuredRelays
        .where((candidate) => candidate.routeKey != relay.routeKey)
        .toList();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(configuredRelays: updated),
    );
    await _announcePairingAvailabilityIfNeeded();
    _markRuntimeActivity();
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
    _removeReachabilityRecord(deviceId);
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
    _pollTimer = null;
    _nextScheduledPollAt = null;
    _pendingSaveTimer?.cancel();
    _pendingSaveTimer = null;
    _pendingSaveCompleter = null;
    await _platformBridge.setAndroidBackgroundRuntimeEnabled(false);
    await _stopPairingBeacon();
    await _localRelayNode.stop();
    await _vaultStore.clear();
    _snapshot = VaultSnapshot.empty();
    _polling = false;
    _pairingSessionActiveUntil = null;
    _lastPairingBeaconSentAt = null;
    _runtimeActiveUntil = null;
    _lastPairingAnnouncementMailboxId = null;
    _lastPairingAnnouncementAt = null;
    _lastRelayStatus = 'relay not checked yet';
    _statusMessage = null;
    _routeHealth.clear();
    _routeRuntime.clear();
    _pendingRouteUpdateProbes.clear();
    _outboundAttemptedAt.clear();
    _debugProbeAcknowledgements.clear();
    _debugTwoWayReplies.clear();
    _locallyDeletedMessageIds.clear();
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
      suppressReadReceipts: false,
      lanAddresses: lanAddresses,
      safetyNumber: safetyNumber,
      createdAt: DateTime.now().toUtc(),
    );
    _snapshot = _snapshot.copyWith(identity: created);
    await _ensureLocalRelayRunning();
    await _ensurePairingBeaconRunning();
    _applyAndroidBackgroundPreference();
    await _persist(
      'Device created. Share a QR invite or the current codephrase to add this contact.',
    );
    _reschedulePolling();
    await _pollLocalInboxOnly();
    await pollNow();
  }

  Future<ContactInvite> buildInvite() async {
    activatePairingSession();
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
      routeHints: prunePeerEndpointsByKind(invite.routeHints),
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
          lastReadAt: _now(),
        ),
      );
    final contacts = List<ContactRecord>.from(_snapshot.contacts)..add(contact);
    final reachabilityRecords = List<ContactReachabilityRecord>.from(
      _snapshot.reachabilityRecords,
    )..add(ContactReachabilityRecord(deviceId: contact.deviceId));
    _snapshot = _snapshot.copyWith(
      contacts: contacts,
      reachabilityRecords: reachabilityRecords,
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
    ChatMessage? replyTo,
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
      replyToMessageId: replyTo?.id,
      replySnippet: replyTo == null ? null : _replySnippetForMessage(replyTo),
      replySenderDeviceId: replyTo?.senderDeviceId,
      replySenderDisplayName: replyTo == null
          ? null
          : _replySenderDisplayName(replyTo),
    );
    _upsertMessage(contact.deviceId, message);
    _markRuntimeActivity();
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
    _clearOutboundAttempt(contact.deviceId, messageId);
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
    _clearOutboundAttempt(contact.deviceId, messageId);
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
    String reason = 'rediscovery',
    List<PeerEndpoint>? routes,
    String? probeId,
    DateTime? sentAt,
  }) async {
    final me = _requireIdentity();
    final effectiveProbeId =
        probeId ?? (requestReply ? _randomId('probe') : null);
    final effectiveSentAt = sentAt ?? _now();
    final routeUpdatePayload = <String, dynamic>{
      'invitePayload': _inviteForIdentity(me).encodePayload(),
      'requestReply': requestReply,
      'reason': reason,
      'sentAt': effectiveSentAt.toIso8601String(),
    };
    if (effectiveProbeId != null) {
      routeUpdatePayload['probeId'] = effectiveProbeId;
    }
    final payload = jsonEncode(routeUpdatePayload);
    final update = RelayEnvelope(
      kind: 'route_update',
      messageId: _randomId('route'),
      conversationId: 'route-update-${contact.deviceId}',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: effectiveSentAt,
      payloadBase64: base64Encode(utf8.encode(payload)),
    );
    try {
      if (requestReply && effectiveProbeId != null) {
        _pendingRouteUpdateProbes[_pendingRouteUpdateProbeKey(
          contact.deviceId,
          effectiveProbeId,
        )] = _PendingRouteUpdateProbe(
          deviceId: contact.deviceId,
          reason: reason,
          sentAt: effectiveSentAt,
        );
      }
      if (routes != null && routes.isNotEmpty) {
        await _deliverAcrossRoutes(
          routes: routes,
          recipientDeviceId: contact.deviceId,
          envelope: update,
        );
      } else {
        await _deliverToContact(
          contact: contact,
          recipientDeviceId: contact.deviceId,
          envelope: update,
        );
      }
      if (reason == 'heartbeat' || reason == 'chat_resume') {
        _noteHeartbeatAttempt(contact.deviceId, at: effectiveSentAt);
      }
      return true;
    } catch (_) {
      if (effectiveProbeId != null) {
        _pendingRouteUpdateProbes.remove(
          _pendingRouteUpdateProbeKey(contact.deviceId, effectiveProbeId),
        );
      }
      if (reason == 'heartbeat' || reason == 'chat_resume') {
        _noteHeartbeatAttempt(contact.deviceId, at: effectiveSentAt);
        _noteFailure(contact.deviceId);
      }
      return false;
    }
  }

  String _pendingRouteUpdateProbeKey(String deviceId, String probeId) {
    return '$deviceId|$probeId';
  }

  Future<_HeartbeatPassResult> _runHeartbeatPass({bool force = false}) async {
    if (!hasIdentity) {
      return const _HeartbeatPassResult(sentCount: 0, changed: false);
    }
    final me = _requireIdentity();
    if (!force && !_shouldRunAutomaticHeartbeats(me)) {
      return const _HeartbeatPassResult(sentCount: 0, changed: false);
    }
    var sent = 0;
    var changed = false;
    for (final contact in contacts) {
      final record = _reachabilityRecordByDeviceId(contact.deviceId);
      final lastTwoWaySuccessAt = record?.lastTwoWaySuccessAt;
      final heartbeatInterval = _heartbeatIntervalForCurrentRuntime(me);
      if (!force &&
          lastTwoWaySuccessAt != null &&
          _now().difference(lastTwoWaySuccessAt) < heartbeatInterval) {
        continue;
      }
      final lastHeartbeatAttemptAt = record?.lastHeartbeatAttemptAt;
      if (!force &&
          lastHeartbeatAttemptAt != null &&
          _now().difference(lastHeartbeatAttemptAt) < heartbeatInterval) {
        continue;
      }
      final preferredRoutes = _preferredRoutesForContact(contact);
      PeerEndpoint? selectedRoute;
      if (preferredRoutes.isNotEmpty) {
        selectedRoute = preferredRoutes.first;
      } else {
        final checks = await _rankRouteHealthForDelivery(
          _candidateRoutesForContact(contact),
        );
        for (final check in checks) {
          if (check.available && _isRouteEligibleNow(check.route)) {
            selectedRoute = check.route;
            break;
          }
        }
      }
      if (selectedRoute == null) {
        _noteFailure(contact.deviceId);
        changed = true;
        continue;
      }
      _noteAvailablePath(contact.deviceId);
      await _rememberLanRoutesForContact(
        deviceId: contact.deviceId,
        routes: selectedRoute.kind == PeerRouteKind.lan
            ? [selectedRoute]
            : const <PeerEndpoint>[],
      );
      changed = true;
      final sentHeartbeat = await _sendRouteUpdate(
        contact,
        requestReply: true,
        reason: 'heartbeat',
        routes: [selectedRoute],
      );
      if (sentHeartbeat) {
        sent++;
      }
    }
    return _HeartbeatPassResult(sentCount: sent, changed: changed);
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
      var attemptedRelay = false;
      var relaySuccess = false;
      final routeNotes = <String>[];

      for (final route in pollRoutes) {
        try {
          if (_shouldSkipSlowPollRoute(route)) {
            continue;
          }
          if (route.kind == PeerRouteKind.relay) {
            attemptedRelay = true;
          }
          _fetchCallCount++;
          final stopwatch = Stopwatch()..start();
          final envelopes = await _relayClient.fetchEnvelopes(
            host: route.host,
            port: route.port,
            protocol: route.protocol,
            recipientDeviceId: me.deviceId,
            timeout: route.kind == PeerRouteKind.lan
                ? const Duration(milliseconds: 900)
                : const Duration(seconds: 4),
          );
          stopwatch.stop();
          _recordRouteSuccess(route, fetch: true, latency: stopwatch.elapsed);
          if (route.kind == PeerRouteKind.relay) {
            relaySuccess = true;
          }
          processed += await _processEnvelopes(envelopes);
          if (envelopes.isNotEmpty) {
            routeNotes.add('${route.kind.name}:${route.host}');
          }
        } catch (error) {
          _recordRouteFailure(route, error: error.toString());
          if (route.kind == PeerRouteKind.relay) {
            attemptedRelay = true;
          }
        }
      }
      processed += await _pollLanLobbyMailbox();
      await _retryUnacknowledgedMessages();
      final heartbeatResult = await _runHeartbeatPass();

      _lastRelayStatus = _networkSummary(
        me,
        internetRelayHealthy: attemptedRelay ? relaySuccess : null,
      );
      if (processed > 0) {
        _markRuntimeActivity();
        _setTransientStatus(
          'Received $processed item(s) via ${routeNotes.isEmpty ? 'known routes' : routeNotes.join(', ')}.',
        );
      } else if (heartbeatResult.changed) {
        await _saveSnapshotSilently(debounce: true);
      } else {
        notifyListeners();
      }
    } catch (error) {
      _lastRelayStatus = 'poll failed';
      _statusMessage = 'Route poll failed: $error';
      notifyListeners();
    } finally {
      _polling = false;
      _reschedulePolling();
      notifyListeners();
    }
  }

  bool _shouldSkipSlowPollRoute(PeerEndpoint route) {
    return !_isRouteEligibleNow(route);
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

  bool isUnreadMessage(String peerDeviceId, ChatMessage message) {
    return _isUnreadMessageInConversation(
      _conversationFor(peerDeviceId),
      message,
    );
  }

  bool isUnreadLanLobbyMessage(ChatMessage message) {
    return _isUnreadMessageInConversation(_lanLobbyConversation(), message);
  }

  Future<void> markConversationRead(String peerDeviceId) async {
    final conversation = _conversationFor(peerDeviceId);
    ChatMessage? latestInbound;
    for (final message in conversation.messages) {
      if (message.outbound) {
        continue;
      }
      if (latestInbound == null ||
          message.createdAt.isAfter(latestInbound.createdAt)) {
        latestInbound = message;
      }
    }
    if (latestInbound != null) {
      await markConversationReadThroughMessage(peerDeviceId, latestInbound);
      return;
    }
    await _markConversationReadWhere(
      (conversation) => conversation.peerDeviceId == peerDeviceId,
    );
  }

  Future<void> markConversationReadThroughMessage(
    String peerDeviceId,
    ChatMessage message,
  ) async {
    if (message.outbound) {
      return;
    }
    await _markConversationReadWhere(
      (conversation) => conversation.peerDeviceId == peerDeviceId,
      readThroughAt: message.createdAt,
      readThroughMessageId: message.id,
    );
  }

  Future<void> markLanLobbyRead() async {
    await _markConversationReadWhere(
      (conversation) => conversation.kind == ConversationKind.lanLobby,
    );
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
      _fetchCallCount++;
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
      _pairingBeaconTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_isPairingSessionActive()) {
          unawaited(_sendPairingRouteBeacon());
        }
      });
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
    _setTransientStatus(
      'Rediscovered LAN route ${route.label} for ${contact.alias}.',
    );
    await _saveSnapshotSilently(debounce: true);
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
        _lastPairingBeaconSentAt = _now();
      } catch (_) {
        // Best-effort only.
      }
      return;
    }
    if (!_isPairingSessionActive()) {
      return;
    }
    var sent = false;
    for (final target in _pairingBroadcastTargets(me)) {
      try {
        socket.send(bytes, target, _pairingBeaconPort);
        sent = true;
      } catch (_) {
        // Best-effort only.
      }
    }
    if (sent) {
      _lastPairingBeaconSentAt = _now();
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
        _setTransientStatus('LAN discovery unavailable: $error');
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
      _setTransientStatus('Updated nearby LAN routes.');
      await _saveSnapshotSilently(debounce: true);
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
        await _replayAckForSeenEnvelope(envelope);
        continue;
      }
      if (_locallyDeletedMessageIds.contains(envelope.messageId)) {
        _markSeen(envelope.messageId);
        continue;
      }
      processed++;
      if (envelope.kind == 'ack') {
        _noteTwoWaySuccess(envelope.senderDeviceId);
        if (_isReadReceiptAck(envelope)) {
          _markMessagesReadThroughMessage(
            envelope.senderDeviceId,
            envelope.acknowledgedMessageId ?? '',
          );
        } else {
          _updateMessageState(
            envelope.senderDeviceId,
            envelope.acknowledgedMessageId ?? '',
            DeliveryState.delivered,
          );
          _clearOutboundAttempt(
            envelope.senderDeviceId,
            envelope.acknowledgedMessageId ?? '',
          );
        }
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

      final decodedMessage = await _decryptDirectMessage(
        contact: contact,
        envelope: envelope,
      );
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
          body: decodedMessage.body,
          outbound: false,
          state: DeliveryState.delivered,
          createdAt: envelope.createdAt,
          replyToMessageId: decodedMessage.replyToMessageId,
          replySnippet: decodedMessage.replySnippet,
          replySenderDeviceId: decodedMessage.replySenderDeviceId,
          replySenderDisplayName: decodedMessage.replySenderDisplayName,
        );
        _upsertMessage(contact.deviceId, inbound);
        _showInboundMessageNotification(
          contact: contact,
          body: decodedMessage.body,
        );
      }
      _noteAnySignal(contact.deviceId, at: envelope.createdAt);
      await _sendAck(contact: contact, envelope: envelope);
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

  bool _isReadReceiptAck(RelayEnvelope envelope) {
    final rawPayload = envelope.payloadBase64;
    if (rawPayload == null || rawPayload.isEmpty) {
      return false;
    }
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(rawPayload)));
      return decoded is Map<String, dynamic> && decoded['receipt'] == 'read';
    } catch (_) {
      return false;
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
    var reason = 'rediscovery';
    String? probeId;
    DateTime? sentAt;
    try {
      final decoded = jsonDecode(decodedPayload);
      if (decoded is Map<String, dynamic>) {
        invitePayload = decoded['invitePayload'] as String?;
        requestReply = decoded['requestReply'] == true;
        reason = decoded['reason'] as String? ?? reason;
        probeId = decoded['probeId'] as String?;
        sentAt = DateTime.tryParse(decoded['sentAt'] as String? ?? '');
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
    _noteAnySignal(sender.deviceId, at: sentAt ?? envelope.createdAt);
    final updated = await _updateExistingContactFromInvite(
      invite,
      statusBuilder: (contact) =>
          'Updated ${contact.alias} route info after path rediscovery.',
      persistStatus: false,
    );
    final replyContact = updated ?? sender;
    if (!requestReply && probeId != null) {
      final pendingKey = _pendingRouteUpdateProbeKey(sender.deviceId, probeId);
      final pending = _pendingRouteUpdateProbes.remove(pendingKey);
      if (pending != null) {
        if (pending.reason == 'heartbeat' || pending.reason == 'chat_resume') {
          _noteHeartbeatReply(sender.deviceId, at: envelope.createdAt);
          _markRuntimeActivity();
        }
        _noteTwoWaySuccess(sender.deviceId, at: envelope.createdAt);
      }
    }
    if (requestReply) {
      await _sendRouteUpdate(
        replyContact,
        requestReply: false,
        reason: reason,
        probeId: probeId,
        sentAt: sentAt ?? envelope.createdAt,
      );
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
    bool persistStatus = true,
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
      routeHints: prunePeerEndpointsByKind(invite.routeHints),
    );
    contacts[existingIndex] = updated;
    _snapshot = _snapshot.copyWith(contacts: contacts);
    _upsertReachabilityRecord(updated.deviceId, (current) => current);
    if (persistStatus) {
      await _persist(statusBuilder(updated));
    }
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

  Future<void> _sendReadReceipt({
    required ContactRecord contact,
    required String conversationId,
    required String acknowledgedMessageId,
  }) async {
    if (acknowledgedMessageId.isEmpty) {
      return;
    }
    final me = _requireIdentity();
    if (me.suppressReadReceipts) {
      return;
    }
    final receipt = RelayEnvelope(
      kind: 'ack',
      messageId: _randomId('read'),
      conversationId: conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      createdAt: DateTime.now().toUtc(),
      acknowledgedMessageId: acknowledgedMessageId,
      payloadBase64: base64Encode(utf8.encode(jsonEncode({'receipt': 'read'}))),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: receipt,
      );
    } catch (_) {
      // Best effort read receipts. Missing them only delays sender-side read
      // state until the next read advancement.
    }
  }

  Future<String?> _sendDebugProbe({
    required ContactRecord contact,
    bool relayOnly = false,
    List<PeerRouteHealth>? rankedChecks,
  }) async {
    if (!kDebugMode) {
      return null;
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
    final checks =
        rankedChecks ??
        await _rankRouteHealthForDebug(contact.prioritizedRouteHints);
    final routes = checks
        .where(
          (check) =>
              check.available &&
              (!relayOnly || check.route.kind == PeerRouteKind.relay),
        )
        .map((check) => check.route)
        .toList(growable: false);
    if (routes.isEmpty) {
      return null;
    }
    try {
      await _deliverAcrossRoutes(
        routes: routes,
        recipientDeviceId: contact.deviceId,
        envelope: probe,
        lanTimeout: _debugRelayOperationTimeout,
        directInternetTimeout: _debugRelayOperationTimeout,
        relayTimeout: _debugRelayOperationTimeout,
      );
      return probe.messageId;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _sendDebugTwoWayMessage(
    ContactRecord contact, {
    List<PeerRouteHealth>? rankedChecks,
  }) async {
    if (!kDebugMode) {
      return null;
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
    final checks =
        rankedChecks ??
        await _rankRouteHealthForDebug(contact.prioritizedRouteHints);
    final routes = checks
        .where((check) => check.available)
        .map((check) => check.route)
        .toList(growable: false);
    if (routes.isEmpty) {
      return null;
    }
    try {
      await _deliverAcrossRoutes(
        routes: routes,
        recipientDeviceId: contact.deviceId,
        envelope: probe,
        lanTimeout: _debugRelayOperationTimeout,
        directInternetTimeout: _debugRelayOperationTimeout,
        relayTimeout: _debugRelayOperationTimeout,
      );
      return probe.messageId;
    } catch (_) {
      return null;
    }
  }

  Future<void> _waitForDebugResponses({
    required Set<String> expectedProbeAckIds,
    required Set<String> expectedTwoWayReplyIds,
  }) async {
    if (expectedProbeAckIds.isEmpty && expectedTwoWayReplyIds.isEmpty) {
      return;
    }
    final deadline = DateTime.now().toUtc().add(const Duration(seconds: 8));
    while (DateTime.now().toUtc().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 750));
      await pollNow();
      final allProbeAcksReceived =
          expectedProbeAckIds.isEmpty ||
          expectedProbeAckIds.every(_debugProbeAcknowledgements.contains);
      final allTwoWayRepliesReceived =
          expectedTwoWayReplyIds.isEmpty ||
          expectedTwoWayReplyIds.every(_debugTwoWayReplies.contains);
      if (allProbeAcksReceived && allTwoWayRepliesReceived) {
        return;
      }
    }
  }

  Future<void> _waitForHeartbeatResponses(
    Set<String> attemptedDeviceIds, {
    required DateTime startedAt,
  }) async {
    if (attemptedDeviceIds.isEmpty) {
      return;
    }
    final deadline = DateTime.now().toUtc().add(const Duration(seconds: 3));
    while (DateTime.now().toUtc().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 750));
      await pollNow();
      final allAnswered = attemptedDeviceIds.every((deviceId) {
        final record = _reachabilityRecordByDeviceId(deviceId);
        final replyAt = record?.lastHeartbeatReplyAt;
        return replyAt != null && !replyAt.isBefore(startedAt);
      });
      if (allAnswered) {
        return;
      }
    }
  }

  Future<DebugCheckResult> _runRelayProtocolRediscoveryCheck(
    IdentityRecord me, {
    bool fast = false,
  }) async {
    if (me.configuredRelays.isEmpty) {
      return const DebugCheckResult(
        name: 'Relay protocol rediscovery',
        status: DebugCheckStatus.skip,
        detail:
            'No configured relay hosts to probe for TCP/UDP/HTTP/HTTPS variants.',
      );
    }
    final refresh = await _refreshConfiguredRelayProtocols(me, fast: fast);
    final added = refresh.addedRoutes.map((route) => route.label).join(', ');
    return DebugCheckResult(
      name: 'Relay protocol rediscovery',
      status: refresh.availableRoutes == 0
          ? DebugCheckStatus.warn
          : DebugCheckStatus.pass,
      detail: refresh.addedRoutes.isEmpty
          ? 'Checked ${refresh.checkedRoutes} TCP/UDP/HTTP/HTTPS relay route(s); ${refresh.availableRoutes} available; no new protocol routes detected.'
          : 'Checked ${refresh.checkedRoutes} TCP/UDP/HTTP/HTTPS relay route(s); ${refresh.availableRoutes} available; added $added.',
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

  DebugCheckResult _runBackgroundHeartbeatPolicyCheck(IdentityRecord me) {
    final previousForeground = _appInForeground;
    final foregroundAllowed = _shouldRunAutomaticHeartbeats(me);
    _appInForeground = false;
    final backgroundAllowed = _shouldRunAutomaticHeartbeats(me);
    _appInForeground = previousForeground;

    if (kIsWeb) {
      return const DebugCheckResult(
        name: 'Background heartbeat policy',
        status: DebugCheckStatus.skip,
        detail: 'Background heartbeat policy is not evaluated on web builds.',
      );
    }
    if (Platform.isAndroid) {
      final expectedBackground = me.androidBackgroundRuntimeEnabled;
      return DebugCheckResult(
        name: 'Background heartbeat policy',
        status: backgroundAllowed == expectedBackground
            ? DebugCheckStatus.pass
            : DebugCheckStatus.fail,
        detail:
            'Foreground heartbeats ${foregroundAllowed ? 'enabled' : 'disabled'}; simulated Android background heartbeats ${backgroundAllowed ? 'enabled' : 'disabled'}; expected ${expectedBackground ? 'enabled' : 'disabled'} from the current background-runtime setting.',
      );
    }
    return DebugCheckResult(
      name: 'Background heartbeat policy',
      status: foregroundAllowed && backgroundAllowed
          ? DebugCheckStatus.pass
          : DebugCheckStatus.fail,
      detail:
          'Desktop/Linux/Windows builds keep heartbeats active in foreground and background so tray/background delivery can continue.',
    );
  }

  DebugCheckResult _runAdaptiveRuntimeSchedulerCheck(IdentityRecord me) {
    final previousForeground = _appInForeground;
    final previousActiveUntil = _runtimeActiveUntil;
    try {
      _appInForeground = true;
      _runtimeActiveUntil = _now().add(_runtimeActiveWindow);
      final foregroundActive = _currentPollInterval();
      _runtimeActiveUntil = _now().subtract(const Duration(seconds: 1));
      final foregroundIdle = _currentPollInterval();
      _appInForeground = false;
      final backgroundInterval = _currentPollInterval();
      final expectedBackground =
          !kIsWeb && Platform.isAndroid && !me.androidBackgroundRuntimeEnabled
          ? null
          : !kIsWeb && !Platform.isAndroid
          ? (awaitingRecipientAckCount > 0
                ? _foregroundActivePollInterval
                : _desktopBackgroundPollInterval)
          : _backgroundEnabledPollInterval;
      final ok =
          foregroundActive == _foregroundActivePollInterval &&
          foregroundIdle == _foregroundIdlePollInterval &&
          backgroundInterval == expectedBackground;
      return DebugCheckResult(
        name: 'Adaptive runtime scheduler',
        status: ok ? DebugCheckStatus.pass : DebugCheckStatus.fail,
        detail:
            'foreground active ${foregroundActive?.inSeconds ?? 0}s, foreground idle ${foregroundIdle?.inSeconds ?? 0}s, background ${backgroundInterval?.inSeconds ?? 0}s${backgroundInterval == null ? ' (stopped)' : ''}. Next poll ${nextScheduledPollAt?.toIso8601String() ?? '(none)'}.',
      );
    } finally {
      _appInForeground = previousForeground;
      _runtimeActiveUntil = previousActiveUntil;
    }
  }

  DebugCheckResult _runPairingSessionPolicyCheck() {
    if (_isPairingSessionActive()) {
      return DebugCheckResult(
        name: 'Pairing session policy',
        status: DebugCheckStatus.pass,
        detail:
            'Pairing session active until ${pairingSessionActiveUntil?.toIso8601String() ?? '(unknown)'}. UDP beacons can publish every ${const Duration(seconds: 5).inSeconds}s and relay pairing refresh is throttled to ${_pairingRelayAnnouncementInterval.inSeconds}s.',
      );
    }
    return const DebugCheckResult(
      name: 'Pairing session policy',
      status: DebugCheckStatus.pass,
      detail:
          'Pairing session inactive. Periodic pairing beacons and relay pairing announcements are gated off while direct beacon replies stay available.',
    );
  }

  Future<DebugCheckResult> _runAutoContactRelayCheck(IdentityRecord me) async {
    final contactRelayRoutes = _contactRelayRoutes();
    final trustedRelayRoutes = _trustedContactRelayRoutes();
    if (trustedRelayRoutes.isEmpty) {
      return const DebugCheckResult(
        name: 'Auto contact relays',
        status: DebugCheckStatus.skip,
        detail:
            'No trusted contact-provided relay routes are currently available to import.',
      );
    }
    if (!me.autoUseContactRelays) {
      return DebugCheckResult(
        name: 'Auto contact relays',
        status: DebugCheckStatus.warn,
        detail:
            '${trustedRelayRoutes.length} trusted contact relay route(s) are cached, but auto-use contact relays is off.',
      );
    }
    if (contactRelayRoutes.isEmpty) {
      return DebugCheckResult(
        name: 'Auto contact relays',
        status: DebugCheckStatus.warn,
        detail:
            '${trustedRelayRoutes.length} trusted relay route(s) exist, but none were promoted into the effective relay set.',
      );
    }
    final checks = await _rankRouteHealthForDebug(contactRelayRoutes);
    final available = checks.where((check) => check.available).length;
    return DebugCheckResult(
      name: 'Auto contact relays',
      status: available > 0 ? DebugCheckStatus.pass : DebugCheckStatus.warn,
      detail:
          'Imported ${contactRelayRoutes.length} contact relay route(s); $available currently available. Effective relay set size: ${_effectiveRelayRoutesForIdentity(me).length}.',
    );
  }

  String _expectedDeliveryStateLabelForRoute(PeerEndpoint route) {
    return route.kind == PeerRouteKind.lan
        ? DeliveryState.local.name
        : DeliveryState.relayed.name;
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

  Future<DebugCheckResult> _runRelayLoopbackCheck(
    IdentityRecord me, {
    bool fast = false,
  }) async {
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
    final checks = fast
        ? await _rankRouteHealthForDebug(relayRoutes)
        : await _rankRouteHealthForDelivery(relayRoutes);
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
        timeout: fast
            ? _debugRelayOperationTimeout
            : const Duration(seconds: 4),
      );
      final fetched = await _relayClient.fetchEnvelopes(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        limit: 8,
        timeout: fast
            ? _debugRelayOperationTimeout
            : const Duration(seconds: 4),
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

  Future<DebugCheckResult> _runRelayPairingReuseCheck(
    IdentityRecord me, {
    bool fast = false,
  }) async {
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
    final checks = fast
        ? await _rankRouteHealthForDebug(relayRoutes)
        : await _rankRouteHealthForDelivery(relayRoutes);
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
        timeout: fast
            ? _debugRelayOperationTimeout
            : const Duration(seconds: 4),
      );
      final first = await _relayClient.fetchEnvelopes(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        limit: 4,
        timeout: fast
            ? _debugRelayOperationTimeout
            : const Duration(seconds: 4),
      );
      final second = await _relayClient.fetchEnvelopes(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        limit: 4,
        timeout: fast
            ? _debugRelayOperationTimeout
            : const Duration(seconds: 4),
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
    _noteOutboundAttempt(contact.deviceId, message.id);
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
      _noteAvailablePath(contact.deviceId);
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

  Future<void> _retryUnacknowledgedMessages({bool force = false}) async {
    for (final contact in contacts) {
      final retryable = messagesFor(contact.deviceId)
          .where(
            (message) => message.outbound && message.state.awaitsRecipientAck,
          )
          .toList();
      for (final message in retryable) {
        if (!force &&
            !_shouldRetryUnacknowledgedMessage(contact.deviceId, message)) {
          continue;
        }
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

  Future<void> _replayAckForSeenEnvelope(RelayEnvelope envelope) async {
    if (envelope.kind != 'direct_message') {
      return;
    }
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) {
      return;
    }
    try {
      await _sendAck(contact: contact, envelope: envelope);
    } catch (_) {
      // Duplicate deliveries are retried best-effort; missing the replayed ack
      // only delays sender-side confirmation until the next duplicate.
    }
  }

  bool _shouldRetryUnacknowledgedMessage(
    String peerDeviceId,
    ChatMessage message,
  ) {
    if (!message.state.awaitsRecipientAck) {
      return false;
    }
    final lastAttemptAt =
        _outboundAttemptedAt[_outboundAttemptKey(peerDeviceId, message.id)] ??
        message.createdAt;
    final delay = message.state == DeliveryState.pending
        ? _pendingMessageRetryDelay
        : _acceptedMessageRetryDelay;
    return DateTime.now().toUtc().difference(lastAttemptAt) >= delay;
  }

  String _outboundAttemptKey(String peerDeviceId, String messageId) {
    return '$peerDeviceId|$messageId';
  }

  void _noteOutboundAttempt(String peerDeviceId, String messageId) {
    _outboundAttemptedAt[_outboundAttemptKey(peerDeviceId, messageId)] =
        DateTime.now().toUtc();
  }

  void _clearOutboundAttempt(String peerDeviceId, String messageId) {
    _outboundAttemptedAt.remove(_outboundAttemptKey(peerDeviceId, messageId));
  }

  Future<PeerEndpoint> _deliverToContact({
    required ContactRecord contact,
    required String recipientDeviceId,
    required RelayEnvelope envelope,
  }) async {
    final candidateRoutes = dedupePeerEndpoints(
      _candidateRoutesForContact(contact),
    );
    final preferredRoutes = _preferredRoutesForContact(contact);
    Object? lastError;
    PeerEndpoint? deliveredVia;
    final relayOnlyCandidates =
        candidateRoutes.isNotEmpty &&
        candidateRoutes.every((route) => route.kind == PeerRouteKind.relay);
    final shouldFreshRankPreferred =
        relayOnlyCandidates &&
        preferredRoutes.isNotEmpty &&
        preferredRoutes.every((route) => route.kind == PeerRouteKind.relay);
    if (preferredRoutes.isNotEmpty && !shouldFreshRankPreferred) {
      try {
        deliveredVia = await _deliverAcrossRoutes(
          routes: preferredRoutes,
          recipientDeviceId: recipientDeviceId,
          envelope: envelope,
        );
      } catch (error) {
        lastError = error;
      }
    }
    if (deliveredVia == null) {
      final triedKeys = preferredRoutes.map((route) => route.routeKey).toSet();
      final remainingRoutes = shouldFreshRankPreferred
          ? candidateRoutes
          : candidateRoutes
                .where((route) => !triedKeys.contains(route.routeKey))
                .toList(growable: false);
      if (remainingRoutes.isNotEmpty) {
        final rankedRoutes = await _rankRoutesForDelivery(remainingRoutes);
        deliveredVia = await _deliverAcrossRoutes(
          routes: rankedRoutes,
          recipientDeviceId: recipientDeviceId,
          envelope: envelope,
        );
      }
    }
    if (deliveredVia == null) {
      throw lastError ?? StateError('No reachable route for recipient.');
    }
    if (deliveredVia.kind == PeerRouteKind.lan) {
      await _rememberLanRoutesForContact(
        deviceId: contact.deviceId,
        routes: [deliveredVia],
      );
    }
    return deliveredVia;
  }

  Future<List<PeerEndpoint>> _rankRoutesForDelivery(
    List<PeerEndpoint> routes,
  ) async {
    final eligibleRoutes = routes
        .where(_isRouteEligibleNow)
        .toList(growable: false);
    final checks = await _rankRouteHealthForDelivery(eligibleRoutes);
    return checks.map((check) => check.route).toList(growable: false);
  }

  Future<List<PeerRouteHealth>> _rankRouteHealthForDelivery(
    List<PeerEndpoint> routes, {
    Duration? lanTimeout,
    Duration? directInternetTimeout,
    Duration? relayTimeout,
    bool includeAliasRoutes = true,
  }) async {
    final uniqueRoutes = dedupePeerEndpoints(routes);
    if (uniqueRoutes.isEmpty) {
      return const <PeerRouteHealth>[];
    }
    final checks = await Future.wait(
      uniqueRoutes.map(
        (route) => _checkRouteHealth(
          route,
          lanTimeout: lanTimeout,
          directInternetTimeout: directInternetTimeout,
          relayTimeout: relayTimeout,
        ),
      ),
    );
    if (includeAliasRoutes) {
      final aliasRoutes = await _sameRelayAliasRoutesFor(
        checks: checks,
        existingRoutes: uniqueRoutes,
        lanTimeout: lanTimeout,
        directInternetTimeout: directInternetTimeout,
        relayTimeout: relayTimeout,
      );
      if (aliasRoutes.isNotEmpty) {
        checks.addAll(
          await Future.wait(
            aliasRoutes.map(
              (route) => _checkRouteHealth(
                route,
                lanTimeout: lanTimeout,
                directInternetTimeout: directInternetTimeout,
                relayTimeout: relayTimeout,
              ),
            ),
          ),
        );
      }
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

  Future<List<PeerRouteHealth>> _rankRouteHealthForDebug(
    List<PeerEndpoint> routes,
  ) {
    return _rankRouteHealthForDelivery(
      routes,
      lanTimeout: _debugLanRouteTimeout,
      directInternetTimeout: _debugInternetRouteTimeout,
      relayTimeout: _debugInternetRouteTimeout,
      includeAliasRoutes: false,
    );
  }

  Future<List<PeerEndpoint>> _sameRelayAliasRoutesFor({
    required List<PeerRouteHealth> checks,
    required List<PeerEndpoint> existingRoutes,
    Duration? lanTimeout,
    Duration? directInternetTimeout,
    Duration? relayTimeout,
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
      candidates.map(
        (route) => _checkRouteHealth(
          route,
          lanTimeout: lanTimeout,
          directInternetTimeout: directInternetTimeout,
          relayTimeout: relayTimeout,
        ),
      ),
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

  int _routeKindDeliveryPriority(PeerEndpoint route) {
    return switch (route.kind) {
      PeerRouteKind.lan => 0,
      PeerRouteKind.directInternet => 1,
      PeerRouteKind.relay => 2,
    };
  }

  _RouteRuntimeState _routeRuntimeState(String routeKey) {
    return _routeRuntime.putIfAbsent(routeKey, _RouteRuntimeState.new);
  }

  DateTime? _routeLastSuccessAt(PeerEndpoint route) {
    final state = _routeRuntime[route.routeKey];
    if (state == null) {
      return null;
    }
    final successes = <DateTime?>[
      state.lastFetchSuccessAt,
      state.lastStoreSuccessAt,
    ];
    DateTime? latest;
    for (final success in successes) {
      if (success == null) {
        continue;
      }
      if (latest == null || success.isAfter(latest)) {
        latest = success;
      }
    }
    return latest;
  }

  Duration _healthCacheTtlFor(PeerEndpoint route) {
    return route.kind == PeerRouteKind.lan
        ? _lanHealthCacheTtl
        : _internetHealthCacheTtl;
  }

  Duration _recentRouteSuccessTtlFor(PeerEndpoint route) {
    return route.kind == PeerRouteKind.lan
        ? _lanRecentRouteSuccessTtl
        : _internetRecentRouteSuccessTtl;
  }

  bool _hasFreshHealthyCache(PeerEndpoint route) {
    final health = _routeHealth[route.routeKey];
    if (health == null || !health.available) {
      return false;
    }
    return _now().difference(health.checkedAt) <= _healthCacheTtlFor(route);
  }

  bool _hasRecentRouteSuccess(PeerEndpoint route) {
    final successAt = _routeLastSuccessAt(route);
    if (successAt == null) {
      return false;
    }
    return _now().difference(successAt) <= _recentRouteSuccessTtlFor(route);
  }

  bool _isRouteBackedOff(PeerEndpoint route) {
    final backoffUntil = _routeRuntime[route.routeKey]?.backoffUntil;
    return backoffUntil != null && backoffUntil.isAfter(_now());
  }

  bool _isRouteEligibleNow(PeerEndpoint route) {
    return !_isRouteBackedOff(route);
  }

  void _recordRouteSuccess(
    PeerEndpoint route, {
    bool? fetch,
    Duration? latency,
    String? relayInstanceId,
    DateTime? at,
  }) {
    final timestamp = (at ?? _now()).toUtc();
    final state = _routeRuntimeState(route.routeKey);
    if (fetch != null) {
      if (fetch) {
        state.lastFetchSuccessAt = timestamp;
      } else {
        state.lastStoreSuccessAt = timestamp;
      }
    }
    state.lastFailureAt = null;
    state.failureStreak = 0;
    state.backoffUntil = null;
    _routeHealth[route.routeKey] = PeerRouteHealth(
      route: route,
      available: true,
      latency: latency ?? _routeHealth[route.routeKey]?.latency,
      checkedAt: timestamp,
      relayInstanceId:
          relayInstanceId ?? _routeHealth[route.routeKey]?.relayInstanceId,
    );
  }

  void _recordRouteFailure(PeerEndpoint route, {DateTime? at, String? error}) {
    final timestamp = (at ?? _now()).toUtc();
    final state = _routeRuntimeState(route.routeKey);
    state.lastFailureAt = timestamp;
    state.failureStreak += 1;
    final backoff = _routeBackoffDurationFor(
      route,
      failureStreak: state.failureStreak,
    );
    state.backoffUntil = timestamp.add(backoff);
    _routeHealth[route.routeKey] = PeerRouteHealth(
      route: route,
      available: false,
      latency: null,
      checkedAt: timestamp,
      error: error,
    );
  }

  Duration _routeBackoffDurationFor(
    PeerEndpoint route, {
    required int failureStreak,
  }) {
    if (route.kind == PeerRouteKind.lan) {
      if (failureStreak <= 1) {
        return const Duration(seconds: 5);
      }
      if (failureStreak == 2) {
        return const Duration(seconds: 15);
      }
      if (failureStreak == 3) {
        return const Duration(seconds: 30);
      }
      return const Duration(seconds: 60);
    }
    if (failureStreak <= 1) {
      return const Duration(seconds: 15);
    }
    if (failureStreak == 2) {
      return const Duration(seconds: 60);
    }
    if (failureStreak == 3) {
      return const Duration(seconds: 300);
    }
    return const Duration(seconds: 600);
  }

  List<PeerEndpoint> _preferredRoutesForContact(ContactRecord contact) {
    final candidateRoutes = dedupePeerEndpoints(
      _candidateRoutesForContact(contact),
    ).where(_isRouteEligibleNow).toList(growable: false);
    final hasNonRelayCandidate = candidateRoutes.any(
      (route) => route.kind != PeerRouteKind.relay,
    );
    final recentSuccessRoutes =
        candidateRoutes
            .where(
              (route) =>
                  _hasRecentRouteSuccess(route) &&
                  (!hasNonRelayCandidate || route.kind != PeerRouteKind.relay),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final leftAt = _routeLastSuccessAt(left);
            final rightAt = _routeLastSuccessAt(right);
            if (leftAt == null && rightAt == null) {
              return 0;
            }
            if (leftAt == null) {
              return 1;
            }
            if (rightAt == null) {
              return -1;
            }
            return rightAt.compareTo(leftAt);
          });
    final hasUntestedNonRelay = candidateRoutes.any(
      (route) =>
          route.kind != PeerRouteKind.relay &&
          !_hasRecentRouteSuccess(route) &&
          !_hasFreshHealthyCache(route),
    );
    final cachedHealthyRoutes =
        candidateRoutes
            .where((route) {
              if (_hasRecentRouteSuccess(route) ||
                  !_hasFreshHealthyCache(route)) {
                return false;
              }
              if (hasUntestedNonRelay && route.kind == PeerRouteKind.relay) {
                return false;
              }
              return true;
            })
            .toList(growable: false)
          ..sort((left, right) {
            final kindCompare = _routeKindDeliveryPriority(
              left,
            ).compareTo(_routeKindDeliveryPriority(right));
            if (kindCompare != 0) {
              return kindCompare;
            }
            final leftHealth = _routeHealth[left.routeKey];
            final rightHealth = _routeHealth[right.routeKey];
            return _compareRouteHealth(
              leftHealth ??
                  PeerRouteHealth(
                    route: left,
                    available: false,
                    latency: null,
                    checkedAt: DateTime.fromMillisecondsSinceEpoch(
                      0,
                      isUtc: true,
                    ),
                  ),
              rightHealth ??
                  PeerRouteHealth(
                    route: right,
                    available: false,
                    latency: null,
                    checkedAt: DateTime.fromMillisecondsSinceEpoch(
                      0,
                      isUtc: true,
                    ),
                  ),
            );
          });
    return <PeerEndpoint>[...recentSuccessRoutes, ...cachedHealthyRoutes];
  }

  Future<PeerRouteHealth> _checkRouteHealth(
    PeerEndpoint route, {
    Duration? lanTimeout,
    Duration? directInternetTimeout,
    Duration? relayTimeout,
  }) async {
    _healthCallCount++;
    final timeout = switch (route.kind) {
      PeerRouteKind.lan => lanTimeout ?? const Duration(milliseconds: 800),
      PeerRouteKind.directInternet =>
        directInternetTimeout ?? const Duration(seconds: 2),
      PeerRouteKind.relay => relayTimeout ?? const Duration(seconds: 3),
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
      _recordRouteSuccess(
        route,
        latency: stopwatch.elapsed,
        relayInstanceId: health.relayInstanceId,
        at: health.checkedAt,
      );
      return health;
    } catch (error) {
      _recordRouteFailure(route, error: error.toString());
      final health = _routeHealth[route.routeKey]!;
      return health;
    }
  }

  Future<PeerEndpoint> _deliverAcrossRoutes({
    required List<PeerEndpoint> routes,
    required String recipientDeviceId,
    required RelayEnvelope envelope,
    Duration? lanTimeout,
    Duration? directInternetTimeout,
    Duration? relayTimeout,
  }) async {
    Object? lastError;
    for (final route in routes) {
      try {
        _storeCallCount++;
        final stopwatch = Stopwatch()..start();
        final stored = await _relayClient.storeEnvelope(
          host: route.host,
          port: route.port,
          protocol: route.protocol,
          recipientDeviceId: recipientDeviceId,
          envelope: envelope,
          timeout: route.kind == PeerRouteKind.lan
              ? lanTimeout ?? const Duration(milliseconds: 900)
              : route.kind == PeerRouteKind.directInternet
              ? directInternetTimeout ?? const Duration(seconds: 2)
              : relayTimeout ?? const Duration(seconds: 4),
        );
        stopwatch.stop();
        if (stored) {
          _recordRouteSuccess(route, fetch: false, latency: stopwatch.elapsed);
          return route;
        }
        _recordRouteFailure(route, error: 'Route did not accept store.');
      } catch (error) {
        _recordRouteFailure(route, error: error.toString());
        lastError = error;
      }
    }
    throw lastError ?? StateError('No reachable route for recipient.');
  }

  Future<ContactInvite> _resolveInviteByCodephrase(String codephrase) async {
    final me = _requireIdentity();
    activatePairingSession();
    _markRuntimeActivity();
    final mailboxId = pairingMailboxIdForCodephrase(codephrase);
    final pingSent = await _sendPairingDiscoveryPing();
    if (pingSent) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final beaconRoutes = _recentPairingBeaconRoutes();
    final beaconInvite = await _resolveInviteByRoutes(
      mailboxId: mailboxId,
      routes: beaconRoutes,
      lanTimeout: const Duration(milliseconds: 350),
    );
    if (beaconInvite != null) {
      return beaconInvite;
    }

    final relayRoutes = _internetPairingRoutesForIdentity(me);
    final relayInvite = await _resolveInviteByRoutes(
      mailboxId: mailboxId,
      routes: relayRoutes,
    );
    if (relayInvite != null) {
      return relayInvite;
    }

    final lanRoutes = _lanPairingRoutesForIdentity(
      me,
      beaconRoutes: beaconRoutes,
    );
    final lanInvite = await _resolveInviteByRoutes(
      mailboxId: mailboxId,
      routes: lanRoutes,
      lanTimeout: const Duration(milliseconds: 350),
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
    Duration lanTimeout = const Duration(milliseconds: 800),
  }) async {
    if (routes.isEmpty) {
      return null;
    }
    const batchSize = 24;
    for (var index = 0; index < routes.length; index += batchSize) {
      final batch = routes.skip(index).take(batchSize).toList(growable: false);
      final resolved = await Future.wait(
        batch.map(
          (route) => _resolveInviteByRoute(
            route: route,
            mailboxId: mailboxId,
            lanTimeout: lanTimeout,
          ),
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
    Duration lanTimeout = const Duration(milliseconds: 800),
  }) async {
    try {
      _fetchCallCount++;
      final envelopes = await _relayClient.fetchEnvelopes(
        host: route.host,
        port: route.port,
        protocol: route.protocol,
        recipientDeviceId: mailboxId,
        limit: 4,
        timeout: route.kind == PeerRouteKind.lan
            ? lanTimeout
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

  List<PeerEndpoint> _candidateRoutesForContact(ContactRecord contact) {
    return dedupePeerEndpoints([
      ...contact.prioritizedRouteHints,
      ..._lanRediscoveryRoutesForContact(contact),
    ]);
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
      final ownHostSegment = int.tryParse(address.substring(lastDot + 1));
      if (ownHostSegment == null) {
        continue;
      }
      for (final hostSegment in _nearbyHostSegments(ownHostSegment)) {
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

  List<PeerEndpoint> _lanRediscoveryRoutesForContact(ContactRecord contact) {
    final me = identity;
    if (me == null ||
        contact.lanRouteHints.isEmpty ||
        me.lanAddresses.isEmpty) {
      return const <PeerEndpoint>[];
    }
    final ports = <int>{
      ...contact.lanRouteHints.map((route) => route.port),
      defaultRelayPort,
    };
    final knownHostSegmentsByPrefix = <String, Set<int>>{};
    for (final route in contact.lanRouteHints) {
      final prefix = _subnetPrefix(route.host);
      final hostSegment = _hostSegment(route.host);
      if (prefix == null || hostSegment == null) {
        continue;
      }
      knownHostSegmentsByPrefix
          .putIfAbsent(prefix, () => <int>{})
          .add(hostSegment);
    }
    final ownAddresses = me.lanAddresses.toSet();
    final routes = <PeerEndpoint>[];
    final seen = contact.prioritizedRouteHints
        .map((route) => route.routeKey)
        .toSet();
    for (final address in ownAddresses) {
      final prefix = _subnetPrefix(address);
      final ownHostSegment = _hostSegment(address);
      if (prefix == null || ownHostSegment == null) {
        continue;
      }
      final preferredSegments = knownHostSegmentsByPrefix[prefix] ?? <int>{};
      for (final hostSegment in _rediscoveryHostSegmentsForContact(
        ownHostSegment: ownHostSegment,
        preferredSegments: preferredSegments,
      )) {
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

  List<int> _rediscoveryHostSegmentsForContact({
    required int ownHostSegment,
    required Set<int> preferredSegments,
  }) {
    if (preferredSegments.isEmpty) {
      if (ownHostSegment == 1) {
        return const <int>[2, 3, 4, 5, 6];
      }
      if (ownHostSegment <= 10) {
        return const <int>[1];
      }
      return const <int>[];
    }
    final seen = <int>{};
    final segments = <int>[];
    final sortedPreferredSegments = preferredSegments.toList(growable: false)
      ..sort(
        (left, right) => (left - ownHostSegment).abs().compareTo(
          (right - ownHostSegment).abs(),
        ),
      );
    void add(int value) {
      if (segments.length >= _maxLanRediscoveryScanHostsPerAddress ||
          value < 1 ||
          value > 254 ||
          !seen.add(value)) {
        return;
      }
      segments.add(value);
    }

    for (final preferred in sortedPreferredSegments) {
      add(preferred);
    }
    final likelyHotspotGateway =
        ownHostSegment <= 10 ||
        sortedPreferredSegments.any((segment) => segment <= 10);
    if (likelyHotspotGateway) {
      add(1);
    }
    for (final preferred in sortedPreferredSegments) {
      for (
        var offset = 1;
        offset <= _maxLanRediscoveryAdjacentHostsPerHint;
        offset++
      ) {
        add(preferred - offset);
        add(preferred + offset);
      }
    }
    return segments;
  }

  List<int> _nearbyHostSegments(
    int ownHostSegment, {
    Iterable<int> preferredSegments = const <int>[],
    int maxCount = _maxLanPairingScanHostsPerAddress,
  }) {
    final seen = <int>{};
    final segments = <int>[];
    void add(int value) {
      if (segments.length >= maxCount ||
          value < 1 ||
          value > 254 ||
          !seen.add(value)) {
        return;
      }
      segments.add(value);
    }

    for (final preferred in preferredSegments) {
      add(preferred);
    }
    for (var radius = 1; radius <= 8; radius++) {
      add(ownHostSegment - radius);
      add(ownHostSegment + radius);
    }
    for (final common in const [1, 2, 10, 20, 50, 100, 101, 200, 245, 254]) {
      add(common);
    }
    for (
      var radius = 9;
      radius <= 254 && segments.length < maxCount;
      radius++
    ) {
      add(ownHostSegment - radius);
      add(ownHostSegment + radius);
    }
    return segments;
  }

  String? _subnetPrefix(String address) {
    final lastDot = address.lastIndexOf('.');
    if (lastDot == -1) {
      return null;
    }
    return address.substring(0, lastDot);
  }

  int? _hostSegment(String address) {
    final lastDot = address.lastIndexOf('.');
    if (lastDot == -1) {
      return null;
    }
    return int.tryParse(address.substring(lastDot + 1));
  }

  bool _looksLikeHotspotGatewayAddress(String address) {
    final hostSegment = _hostSegment(address);
    if (hostSegment != 1) {
      return false;
    }
    return address.startsWith('10.') ||
        address.startsWith('172.') ||
        address.startsWith('192.168.');
  }

  Future<void> _rememberLanRoutesForContact({
    required String deviceId,
    required Iterable<PeerEndpoint> routes,
  }) async {
    final lanRoutes = dedupePeerEndpoints(
      routes.where((route) => route.kind == PeerRouteKind.lan),
    );
    if (lanRoutes.isEmpty) {
      return;
    }
    final index = _snapshot.contacts.indexWhere(
      (contact) => contact.deviceId == deviceId,
    );
    if (index == -1) {
      return;
    }
    final contacts = List<ContactRecord>.from(_snapshot.contacts);
    final contact = contacts[index];
    final mergedRoutes = prunePeerEndpointsByKind([
      ...lanRoutes,
      ...contact.routeHints,
    ]);
    if (_sameRoutes(mergedRoutes, contact.routeHints)) {
      return;
    }
    contacts[index] = contact.copyWith(routeHints: mergedRoutes);
    _snapshot = _snapshot.copyWith(contacts: contacts);
    await _saveSnapshotSilently(debounce: true);
  }

  bool _sameRoutes(List<PeerEndpoint> left, List<PeerEndpoint> right) {
    if (left.length != right.length) {
      return false;
    }
    final leftKeys = left.map((route) => route.routeKey).toList()..sort();
    final rightKeys = right.map((route) => route.routeKey).toList()..sort();
    for (var index = 0; index < leftKeys.length; index++) {
      if (leftKeys[index] != rightKeys[index]) {
        return false;
      }
    }
    return true;
  }

  bool _normalizeStoredContactRoutes() {
    var changed = false;
    final contacts = List<ContactRecord>.from(_snapshot.contacts);
    for (var index = 0; index < contacts.length; index++) {
      final current = contacts[index];
      final pruned = prunePeerEndpointsByKind(current.routeHints);
      if (_sameRoutes(pruned, current.routeHints)) {
        continue;
      }
      contacts[index] = current.copyWith(routeHints: pruned);
      changed = true;
    }
    if (changed) {
      _snapshot = _snapshot.copyWith(contacts: contacts);
    }
    return changed;
  }

  String _routeBackoffSummaryForRoutes(Iterable<PeerEndpoint> routes) {
    final entries = <String>[];
    final seen = <String>{};
    final now = _now();
    for (final route in routes) {
      if (!seen.add(route.routeKey)) {
        continue;
      }
      final state = _routeRuntime[route.routeKey];
      if (state == null) {
        continue;
      }
      final backoffUntil = state.backoffUntil;
      if (backoffUntil == null || !backoffUntil.isAfter(now)) {
        continue;
      }
      entries.add(
        '${route.label} backoff ${backoffUntil.difference(now).inSeconds}s streak ${state.failureStreak}',
      );
      if (entries.length >= _maxDebugRouteSummaryItems) {
        break;
      }
    }
    if (entries.isEmpty) {
      return '(none)';
    }
    return entries.join(' | ');
  }

  String _globalRouteBackoffSummary() {
    final routes = <PeerEndpoint>{
      ..._routeHealth.values.map((health) => health.route),
      for (final contact in contacts) ..._candidateRoutesForContact(contact),
      ...configuredRelays,
    };
    return _routeBackoffSummaryForRoutes(routes);
  }

  String _summarizeRouteChecks(Iterable<PeerRouteHealth> checks) {
    final summaries = checks
        .map((check) => check.summary)
        .toList(growable: false);
    if (summaries.length <= _maxDebugRouteSummaryItems) {
      return summaries.join(' | ');
    }
    final visible = summaries.take(_maxDebugRouteSummaryItems).join(' | ');
    return '$visible | +${summaries.length - _maxDebugRouteSummaryItems} more';
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
    final lanRoutes = _rankLanInviteAddresses(identity.lanAddresses)
        .take(_maxInviteLanHosts)
        .expand(
          (address) => _protocolRoutes(
            kind: PeerRouteKind.lan,
            host: address,
            port: identity.localRelayPort,
          ),
        )
        .toList(growable: false);
    final configuredRelayRoutes = _rankInviteRoutes(
      identity.configuredRelays.where(
        (route) => route.kind == PeerRouteKind.relay,
      ),
    ).take(_maxInviteRelayRoutes);
    final remainingRelaySlots = max(
      0,
      _maxInviteRelayRoutes - configuredRelayRoutes.length,
    );
    final contactRelayRoutes = _rankInviteRoutes(
      _contactRelayRoutes().where((route) => route.kind == PeerRouteKind.relay),
    ).take(remainingRelaySlots);
    return dedupePeerEndpoints([
      ...lanRoutes,
      ...configuredRelayRoutes,
      ...contactRelayRoutes,
    ]).take(_maxInviteRouteHints).toList(growable: false);
  }

  List<String> _rankLanInviteAddresses(Iterable<String> addresses) {
    final ranked = addresses.toSet().toList();
    ranked.sort((left, right) {
      final priorityCompare = _lanInviteAddressPriority(
        left,
      ).compareTo(_lanInviteAddressPriority(right));
      if (priorityCompare != 0) {
        return priorityCompare;
      }
      return left.compareTo(right);
    });
    return ranked;
  }

  int _lanInviteAddressPriority(String address) {
    if (address.startsWith('192.168.')) {
      return 0;
    }
    if (address.startsWith('10.')) {
      return 1;
    }
    if (address.startsWith('172.')) {
      return 2;
    }
    if (address.startsWith('169.254.')) {
      return 3;
    }
    return 4;
  }

  List<PeerEndpoint> _rankInviteRoutes(Iterable<PeerEndpoint> routes) {
    final ranked = dedupePeerEndpoints(routes);
    ranked.sort((left, right) {
      final leftHealth = _routeHealth[left.routeKey];
      final rightHealth = _routeHealth[right.routeKey];
      final leftAvailable = leftHealth?.available ?? false;
      final rightAvailable = rightHealth?.available ?? false;
      if (leftAvailable != rightAvailable) {
        return leftAvailable ? -1 : 1;
      }
      final latencyCompare = (leftHealth?.latency?.inMicroseconds ?? 1 << 62)
          .compareTo(rightHealth?.latency?.inMicroseconds ?? 1 << 62);
      if (latencyCompare != 0) {
        return latencyCompare;
      }
      final protocolCompare = _inviteProtocolPriority(
        left.protocol,
      ).compareTo(_inviteProtocolPriority(right.protocol));
      if (protocolCompare != 0) {
        return protocolCompare;
      }
      return left.label.compareTo(right.label);
    });
    return ranked;
  }

  int _inviteProtocolPriority(PeerRouteProtocol protocol) {
    return switch (protocol) {
      PeerRouteProtocol.tcp => 0,
      PeerRouteProtocol.udp => 1,
      PeerRouteProtocol.https => 2,
      PeerRouteProtocol.http => 3,
    };
  }

  Future<void> _announcePairingAvailabilityIfNeeded({
    bool force = false,
  }) async {
    final me = _snapshot.identity;
    if (me == null) {
      return;
    }
    if (!force && !_isPairingSessionActive()) {
      return;
    }
    final invite = _inviteForIdentity(me);
    final payload = invite.encodePayload();
    final mailboxIds = pairingCodephrasesForPayload(
      payload,
    ).map(pairingMailboxIdForCodephrase).toList(growable: false);
    final mailboxKey = mailboxIds.join('|');
    final now = DateTime.now().toUtc();
    final lastAnnouncementAt = _lastPairingAnnouncementAt;
    if (!force &&
        _lastPairingAnnouncementMailboxId == mailboxKey &&
        lastAnnouncementAt != null &&
        now.difference(lastAnnouncementAt) <
            _pairingRelayAnnouncementInterval) {
      return;
    }

    final stores = <Future<void>>[];
    for (final route in _announcementRoutesForIdentity(me)) {
      for (final mailboxId in mailboxIds) {
        _storeCallCount++;
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
        stores.add(
          _relayClient
              .storeEnvelope(
                host: route.host,
                port: route.port,
                protocol: route.protocol,
                recipientDeviceId: mailboxId,
                envelope: announcement,
                timeout: route.kind == PeerRouteKind.lan
                    ? const Duration(milliseconds: 500)
                    : const Duration(seconds: 2),
              )
              .then((stored) {
                if (stored) {
                  _recordRouteSuccess(route, fetch: false);
                } else {
                  _recordRouteFailure(
                    route,
                    error: 'Pairing announcement store was not accepted.',
                  );
                }
              })
              .catchError((error) {
                _recordRouteFailure(route, error: error.toString());
              })
              .then((_) {}),
        );
      }
    }
    await Future.wait(stores);
    _lastPairingAnnouncementMailboxId = mailboxKey;
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
      plaintext: _encodeDirectMessagePayload(message),
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

  Future<_DecodedDirectMessage> _decryptDirectMessage({
    required ContactRecord contact,
    required RelayEnvelope envelope,
  }) async {
    final decrypted = await _decryptMessage(
      contact: contact,
      envelope: envelope,
    );
    return _decodeDirectMessagePayload(decrypted);
  }

  String _encodeDirectMessagePayload(ChatMessage message) {
    if (!message.hasReplyPreview) {
      return message.body;
    }
    return jsonEncode({
      'version': 2,
      'body': message.body,
      'replyToMessageId': message.replyToMessageId,
      'replySnippet': message.replySnippet,
      'replySenderDeviceId': message.replySenderDeviceId,
      'replySenderDisplayName': message.replySenderDisplayName,
    });
  }

  _DecodedDirectMessage _decodeDirectMessagePayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic> &&
          decoded['version'] == 2 &&
          decoded['body'] is String) {
        return _DecodedDirectMessage(
          body: decoded['body'] as String,
          replyToMessageId: decoded['replyToMessageId'] as String?,
          replySnippet: decoded['replySnippet'] as String?,
          replySenderDeviceId: decoded['replySenderDeviceId'] as String?,
          replySenderDisplayName: decoded['replySenderDisplayName'] as String?,
        );
      }
    } catch (_) {
      // Legacy direct messages are plain-text bodies.
    }
    return _DecodedDirectMessage(body: payload);
  }

  String _replySnippetForMessage(ChatMessage message) {
    final normalized = message.bodyPreview.trim();
    if (normalized.length <= 72) {
      return normalized;
    }
    return '${normalized.substring(0, 72).trimRight()}...';
  }

  String _replySenderDisplayName(ChatMessage message) {
    final me = identity;
    if (me != null && message.senderDeviceId == me.deviceId) {
      return 'You';
    }
    final contact = _contactByDeviceId(message.senderDeviceId);
    return contact?.alias ??
        contact?.displayName ??
        message.senderDisplayName ??
        message.senderDeviceId;
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
      lastReadAt: _now(),
    );
  }

  ConversationRecord _lanLobbyConversation() {
    for (final conversation in _snapshot.conversations) {
      if (conversation.kind == ConversationKind.lanLobby) {
        return conversation;
      }
    }
    return ConversationRecord(
      id: _lanLobbyConversationId,
      kind: ConversationKind.lanLobby,
      peerDeviceId: _lanLobbyMailboxId,
      messages: const [],
      lastReadAt: _now(),
    );
  }

  int _unreadCountForConversation(ConversationRecord conversation) {
    return conversation.messages.where((message) {
      return _isUnreadMessageInConversation(conversation, message);
    }).length;
  }

  bool _isUnreadMessageInConversation(
    ConversationRecord conversation,
    ChatMessage message,
  ) {
    if (message.outbound) {
      return false;
    }
    final lastReadAt = conversation.lastReadAt;
    if (lastReadAt == null) {
      return true;
    }
    return message.createdAt.isAfter(lastReadAt);
  }

  Future<void> _markConversationReadWhere(
    bool Function(ConversationRecord conversation) predicate, {
    DateTime? readThroughAt,
    String? readThroughMessageId,
  }) async {
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final index = conversations.indexWhere(predicate);
    if (index == -1) {
      return;
    }
    final conversation = conversations[index];
    final latestCreatedAt =
        readThroughAt ??
        (conversation.messages.isEmpty
            ? _now()
            : conversation.messages
                  .map((message) => message.createdAt)
                  .reduce((left, right) => left.isAfter(right) ? left : right));
    final currentReadAt = conversation.lastReadAt;
    if (currentReadAt != null && !latestCreatedAt.isAfter(currentReadAt)) {
      return;
    }
    conversations[index] = conversation.copyWith(lastReadAt: latestCreatedAt);
    _snapshot = _snapshot.copyWith(conversations: conversations);
    await _saveSnapshotSilently(debounce: true);
    if (conversation.kind != ConversationKind.direct) {
      return;
    }
    final contact = _contactByDeviceId(conversation.peerDeviceId);
    if (contact == null) {
      return;
    }
    final effectiveMessageId =
        readThroughMessageId ??
        _latestInboundMessageAtOrBefore(conversation, latestCreatedAt)?.id;
    if (effectiveMessageId == null || effectiveMessageId.isEmpty) {
      return;
    }
    await _sendReadReceipt(
      contact: contact,
      conversationId: conversation.id,
      acknowledgedMessageId: effectiveMessageId,
    );
  }

  ChatMessage? _latestInboundMessageAtOrBefore(
    ConversationRecord conversation,
    DateTime cutoff,
  ) {
    ChatMessage? latest;
    for (final message in conversation.messages) {
      if (message.outbound || message.createdAt.isAfter(cutoff)) {
        continue;
      }
      if (latest == null || message.createdAt.isAfter(latest.createdAt)) {
        latest = message;
      }
    }
    return latest;
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
          lastReadAt: message.outbound ? message.createdAt : null,
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
          lastReadAt: message.outbound ? message.createdAt : null,
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
    final updatedMessages = conversations[conversationIndex].messages.map((
      message,
    ) {
      if (message.id != messageId) {
        return message;
      }
      if (message.state == DeliveryState.read) {
        return message;
      }
      if (message.state == DeliveryState.delivered &&
          state != DeliveryState.delivered &&
          state != DeliveryState.read) {
        return message;
      }
      return message.copyWith(state: state);
    }).toList();
    conversations[conversationIndex] = conversations[conversationIndex]
        .copyWith(messages: updatedMessages);
    _snapshot = _snapshot.copyWith(conversations: conversations);
    if (!state.awaitsRecipientAck) {
      _clearOutboundAttempt(peerDeviceId, messageId);
    }
  }

  void _markMessagesReadThroughMessage(String peerDeviceId, String messageId) {
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
    ChatMessage? targetMessage;
    for (final message in conversations[conversationIndex].messages) {
      if (message.id == messageId) {
        targetMessage = message;
        break;
      }
    }
    if (targetMessage == null) {
      return;
    }
    final cutoff = targetMessage.createdAt;
    final updatedMessages = conversations[conversationIndex].messages.map((
      message,
    ) {
      if (!message.outbound || message.createdAt.isAfter(cutoff)) {
        return message;
      }
      if (message.state == DeliveryState.canceled ||
          message.state == DeliveryState.failed ||
          message.state == DeliveryState.read) {
        return message;
      }
      _clearOutboundAttempt(peerDeviceId, message.id);
      return message.copyWith(state: DeliveryState.read);
    }).toList();
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
    _clearOutboundAttempt(peerDeviceId, messageId);
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
    await _saveSnapshotSilently();
  }

  void _setTransientStatus(String? status, {bool notify = true}) {
    _statusMessage = status;
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _saveSnapshotSilently({
    bool notify = true,
    bool debounce = false,
  }) async {
    _prunePendingRouteUpdateProbes();
    if (debounce) {
      final existingCompleter = _pendingSaveCompleter;
      if (existingCompleter != null && !existingCompleter.isCompleted) {
        if (notify) {
          notifyListeners();
        }
        return existingCompleter.future;
      }
      final completer = Completer<void>();
      _pendingSaveCompleter = completer;
      _pendingSaveTimer?.cancel();
      _pendingSaveTimer = Timer(_saveDebounceWindow, () async {
        try {
          _prunePendingRouteUpdateProbes();
          await _vaultStore.save(_snapshot);
          _vaultSaveCount++;
          _lastVaultSaveAt = _now();
          if (!completer.isCompleted) {
            completer.complete();
          }
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        } finally {
          if (identical(_pendingSaveCompleter, completer)) {
            _pendingSaveCompleter = null;
          }
          _pendingSaveTimer = null;
          if (notify) {
            notifyListeners();
          }
        }
      });
      if (notify) {
        notifyListeners();
      }
      return completer.future;
    }
    final pendingCompleter = _pendingSaveCompleter;
    _pendingSaveTimer?.cancel();
    _pendingSaveTimer = null;
    _pendingSaveCompleter = null;
    try {
      await _vaultStore.save(_snapshot);
      _vaultSaveCount++;
      _lastVaultSaveAt = _now();
      if (pendingCompleter != null && !pendingCompleter.isCompleted) {
        pendingCompleter.complete();
      }
    } catch (error, stackTrace) {
      if (pendingCompleter != null && !pendingCompleter.isCompleted) {
        pendingCompleter.completeError(error, stackTrace);
      }
      rethrow;
    }
    if (notify) {
      notifyListeners();
    }
  }

  void _prunePendingRouteUpdateProbes() {
    final now = _now();
    _pendingRouteUpdateProbes.removeWhere(
      (_, probe) => now.difference(probe.sentAt) > _knownReachabilityWindow,
    );
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
      _markRuntimeActivity();
      _setTransientStatus(
        'Received $processed item(s) instantly via local relay.',
      );
      await _saveSnapshotSilently(debounce: true);
    } else {
      notifyListeners();
    }
  }

  Future<void> _pollLocalInboxOnly() async {
    if (!hasIdentity || !_localRelayNode.isRunning) {
      return;
    }
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
          _fetchCallCount++;
          final stopwatch = Stopwatch()..start();
          final envelopes = await _relayClient.fetchEnvelopes(
            host: route.host,
            port: route.port,
            protocol: route.protocol,
            recipientDeviceId: me.deviceId,
            timeout: const Duration(milliseconds: 350),
          );
          stopwatch.stop();
          _recordRouteSuccess(route, fetch: true, latency: stopwatch.elapsed);
          processed += await _processEnvelopes(envelopes);
        } catch (error) {
          _recordRouteFailure(route, error: error.toString());
          // Full polling handles status reporting; this path only reduces LAN latency.
        }
      }
      if (processed > 0) {
        _markRuntimeActivity();
        _setTransientStatus('Received $processed item(s) via local inbox.');
        await _saveSnapshotSilently(debounce: true);
      }
    } finally {
      _reschedulePolling();
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
    _pendingSaveTimer?.cancel();
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

class _PendingRouteUpdateProbe {
  const _PendingRouteUpdateProbe({
    required this.deviceId,
    required this.reason,
    required this.sentAt,
  });

  final String deviceId;
  final String reason;
  final DateTime sentAt;
}

class _HeartbeatPassResult {
  const _HeartbeatPassResult({required this.sentCount, required this.changed});

  final int sentCount;
  final bool changed;
}

enum _RuntimeMode {
  foregroundActive,
  foregroundIdle,
  backgroundEnabled,
  backgroundDisabledAndroid,
}

class _RouteRuntimeState {
  DateTime? lastFetchSuccessAt;
  DateTime? lastStoreSuccessAt;
  DateTime? lastFailureAt;
  int failureStreak = 0;
  DateTime? backoffUntil;
}

class _DecodedDirectMessage {
  const _DecodedDirectMessage({
    required this.body,
    this.replyToMessageId,
    this.replySnippet,
    this.replySenderDeviceId,
    this.replySenderDisplayName,
  });

  final String body;
  final String? replyToMessageId;
  final String? replySnippet;
  final String? replySenderDeviceId;
  final String? replySenderDisplayName;
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
