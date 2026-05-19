import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;

import 'crypto_service.dart';
import 'local_relay_node.dart';
import 'models.dart';
import 'platform_bridge.dart';
import 'reachability_tracker.dart';
import 'relay_client.dart';
import 'relay_defaults.dart';
import 'route_health_tracker.dart';
import 'storage.dart';

/// Fallback attachment cache root used when the constructor caller
/// doesn't supply one (i.e. production where the bootstrap profile
/// chose a non-portable data root). Mirrors what `app_storage.dart`
/// would have picked for the device profile.
Future<Directory> _defaultAttachmentRootProvider() async {
  final root = await path_provider.getApplicationSupportDirectory();
  return Directory(p.join(root.path, 'attachments'));
}

const int _maxInviteRouteHints = 4;
const int _maxInviteLanHosts = 1;
const int _maxInviteRelayRoutes = 2;
const int _maxLanPairingScanHostsPerAddress = 64;
const int _maxLanRediscoveryScanHostsPerAddress = 16;
const int _maxLanRediscoveryAdjacentHostsPerHint = 2;
const int _maxDebugRouteSummaryItems = 8;
const int _maxGroupMembers = 16;
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
const Duration _pendingMessageRetryDelay = Duration(seconds: 5);
const Duration _acceptedMessageRetryDelay = Duration(seconds: 15);

/// Base URL the "Update default relays" button pulls from. Points at the
/// project's `main`-branch raw assets so a freshly-pushed signed manifest
/// reaches users without an app release.
const String kDefaultRelaysGitHubRawBase =
    'https://raw.githubusercontent.com/glitch-228/conest/main/assets';

/// Outcome of a [`MessengerController.refreshDefaultRelays`] call.
class DefaultRelaysRefreshResult {
  const DefaultRelaysRefreshResult._({
    required this.status,
    this.version,
    this.addedRoutes = const <PeerEndpoint>[],
    this.errorMessage,
  });

  const DefaultRelaysRefreshResult.upToDate({required int version})
    : this._(status: DefaultRelaysRefreshStatus.upToDate, version: version);

  const DefaultRelaysRefreshResult.updated({
    required int version,
    required List<PeerEndpoint> addedRoutes,
  }) : this._(
         status: DefaultRelaysRefreshStatus.updated,
         version: version,
         addedRoutes: addedRoutes,
       );

  const DefaultRelaysRefreshResult.error(String message)
    : this._(status: DefaultRelaysRefreshStatus.error, errorMessage: message);

  final DefaultRelaysRefreshStatus status;
  final int? version;
  final List<PeerEndpoint> addedRoutes;
  final String? errorMessage;
}

enum DefaultRelaysRefreshStatus { upToDate, updated, error }

class MessengerController extends ChangeNotifier {
  MessengerController({
    required VaultStore vaultStore,
    required RelayClient relayClient,
    LocalRelayNode? localRelayNode,
    PlatformBridge? platformBridge,
    Future<List<String>> Function()? lanAddressProvider,
    DateTime Function()? nowProvider,
    Future<SignedRelayDefaults?> Function()? signedRelayDefaultsLoader,
    Future<Directory> Function()? attachmentRootProvider,
    bool enableLongPoll = true,
  }) : _vaultStore = vaultStore,
       _localRelayNode = localRelayNode ?? LocalRelayNode(),
       _platformBridge = platformBridge ?? PlatformBridge(),
       _lanAddressProvider = lanAddressProvider ?? discoverLanAddresses,
       _nowProvider = nowProvider ?? DateTime.now,
       _signedRelayDefaultsLoader = signedRelayDefaultsLoader,
       _attachmentRootProvider =
           attachmentRootProvider ?? _defaultAttachmentRootProvider,
       _longPollEnabled = enableLongPoll {
    _relayClient = _ScoringRelayClient(
      inner: relayClient,
      onAttempt: _recordRelayAttemptFromShim,
      nowProvider: () => (nowProvider ?? DateTime.now)(),
    );
    _crypto = CryptoService(identityProvider: _requireIdentity);
    _reachability = ReachabilityTracker(
      recordsProvider: () => _snapshot.reachabilityRecords,
      recordsUpdater: (records) =>
          _snapshot = _snapshot.copyWith(reachabilityRecords: records),
      nowProvider: _now,
    );
    _routeHealthTracker = RouteHealthTracker(nowProvider: _now);
    _localRelayNode.onEnvelopeStored = _handleLocalEnvelopeStored;
  }

  final VaultStore _vaultStore;
  late final RelayClient _relayClient;
  late final CryptoService _crypto;
  late final ReachabilityTracker _reachability;
  late final RouteHealthTracker _routeHealthTracker;
  final bool _longPollEnabled;
  bool _longPollRunning = false;
  // Reference count: while > 0, `notifyListeners` defers and sets the
  // pending flag instead of dispatching. The last `_processEnvelopes` to
  // exit (depth → 0) flushes one combined notify. Reference counting
  // (rather than a capture/restore boolean) is safe for *parallel/over-
  // lapping* calls — long-poll, pollNow, and _handleLocalEnvelopeStored
  // all run concurrent _processEnvelopes futures, and the old capture/
  // restore left the deferred flag permanently `true` whenever an outer
  // call finished before its overlapping inner call (a5b93fe regression).
  int _notificationsDeferredDepth = 0;
  bool _deferredNotificationPending = false;
  // True after `dispose()` returns. Late-firing Timers and async
  // continuations that try to call notifyListeners would otherwise hit
  // ChangeNotifier's debug assertion ("used after being disposed");
  // checking this flag in the override turns those into safe no-ops.
  bool _disposed = false;
  final LocalRelayNode _localRelayNode;
  final PlatformBridge _platformBridge;
  final Future<List<String>> Function() _lanAddressProvider;
  final DateTime Function() _nowProvider;
  final Future<SignedRelayDefaults?> Function()? _signedRelayDefaultsLoader;

  /// Resolves the directory under which assembled attachment bytes are
  /// persisted, so the bubble can keep rendering the file row / image
  /// thumbnail after an app restart instead of regressing to "transferring".
  final Future<Directory> Function() _attachmentRootProvider;
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
  final Map<String, String> _announcedRelayIdentityKeys = <String, String>{};
  Future<Uint8List> Function(String url)? _httpBytesFetcherOverride;
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
  // Sender-side: bytes of the original file are held in memory keyed by
  // attachmentId until the recipient sends `attachment_complete` (or the
  // user cancels). One entry per in-flight outbound attachment.
  final Map<String, _OutboundAttachmentState> _outboundAttachments =
      <String, _OutboundAttachmentState>{};
  // Receiver-side: chunk plaintext accumulated keyed by attachmentId until
  // the last chunk arrives. Cleared once assembled bytes are surfaced.
  final Map<String, _InboundAttachmentState> _inboundAttachments =
      <String, _InboundAttachmentState>{};
  // Assembled, verified attachment bytes the UI / test can read via
  // [attachmentBytesFor]. Kept in memory for v0.3.2; persisted to disk in
  // a follow-up pass.
  final Map<String, Uint8List> _assembledAttachments = <String, Uint8List>{};

  bool get isReady => _ready;
  bool get hasIdentity => _snapshot.identity != null;
  IdentityRecord? get identity => _snapshot.identity;
  List<ContactRecord> get contacts => List.unmodifiable(_snapshot.contacts);

  /// Every group the controller knows about, including ones the local user
  /// has left and ones they have explicitly removed from their list. Sidebar
  /// callers should use [visibleGroups] instead; this getter is for code that
  /// needs the unfiltered set (tests, debug snapshots, internal lookups).
  List<GroupRecord> get groups => List.unmodifiable(_snapshot.groups);

  /// Groups that should appear in the UI sidebar: every group except the ones
  /// the local user has explicitly removed via [removeGroupFromList]. A group
  /// the user has left (but not yet removed) still appears here, with the UI
  /// rendering a "you left" badge.
  List<GroupRecord> get visibleGroups => List.unmodifiable(
    _snapshot.groups.where((group) => group.localRemovedAt == null),
  );
  List<PeerEndpoint> get configuredRelays => List.unmodifiable(
    _snapshot.identity?.configuredRelays ?? const <PeerEndpoint>[],
  );

  /// Per-endpoint relay health, derived from recorded attempts. Read-only.
  Map<String, RelayHealthScore> get relayHealthScores =>
      Map.unmodifiable(_snapshot.relayHealthScores);

  /// In-memory record of the most recent relay-announced identity keys
  /// that differ from the pinned key for the same relay_id. The UI uses
  /// this to surface a "Trust new key" affordance: tapping it calls
  /// [rotateRelayIdentityKey] with the announced value. Not persisted;
  /// rebuilt opportunistically from health checks.
  Map<String, String> get announcedRelayIdentityKeys =>
      Map.unmodifiable(_announcedRelayIdentityKeys);

  /// `routeKey`s of configured relays that were ingested from the signed
  /// default-relay manifest. The UI renders these as `default relay N`
  /// instead of host:port.
  Set<String> get defaultRelayRouteKeys =>
      Set.unmodifiable(_snapshot.defaultRelayRouteKeys);

  /// `host:port` strings for default-relay endpoints. Routes sharing one of
  /// these host:port pairs collapse to a single "default relay N" label,
  /// regardless of protocol — so multi-protocol fan-out (TCP+UDP+HTTP for
  /// the same operator address) shows up as one entry.
  Set<String> get defaultRelayHosts =>
      Set.unmodifiable(_snapshot.defaultRelayHosts);

  /// Imported relay-list sources (signed or unsigned URL imports). Exposed
  /// for the settings UI; mutation goes through [`importRelaysFromUrl`] and
  /// [`removeCustomRelaySource`].
  List<CustomRelaySource> get customRelaySources =>
      List.unmodifiable(_snapshot.customRelaySources);

  /// Wall-clock time of the most recent successful default-relays fetch
  /// from the GitHub `main`-branch raw URL. Null when only the bundled
  /// asset has been ingested.
  DateTime? get defaultRelaysLastFetchedAt =>
      _snapshot.defaultRelaysLastFetchedAt;

  /// Version of the most recently ingested signed default-relay manifest.
  /// Exposed for the settings UI alongside the last-fetched timestamp.
  int get defaultRelaysVersion => _snapshot.defaultRelayDefaultsVersion;

  /// Renders the user-visible label for a relay endpoint. Default relays
  /// (any route whose `host:port` matches an ingested default endpoint)
  /// are shown as `default relay N` where N is the 1-based index in the
  /// sorted set of default host:port pairs. Manually-added and imported
  /// relays show their actual `relay.label`. Sort-stable across renders.
  String relayDisplayLabel(PeerEndpoint relay) {
    final hostKey = '${relay.host}:${relay.port}';
    final hosts = _snapshot.defaultRelayHosts;
    if (hosts.contains(hostKey)) {
      final sorted = hosts.toList()..sort();
      return 'default relay ${sorted.indexOf(hostKey) + 1}';
    }
    // Legacy fallback for vaults persisted before v0.3.1 — pre-3 schema
    // recorded individual route keys without host grouping.
    final keys = _snapshot.defaultRelayRouteKeys;
    if (keys.contains(relay.routeKey)) {
      final sorted = keys.toList()..sort();
      return 'default relay ${sorted.indexOf(relay.routeKey) + 1}';
    }
    return relay.label;
  }

  /// Outbound delivery/read receipts that haven't yet landed on their
  /// target without throwing. Exposed for tests and diagnostics; the
  /// retry loop drains the queue automatically.
  List<PendingAckDelivery> get pendingAckDeliveries =>
      List.unmodifiable(_snapshot.pendingAckDeliveries);

  /// Test-only: force the pending-ack retry loop to run immediately
  /// regardless of the backoff window. Production code reaches this path
  /// via the periodic `_retryUnacknowledgedMessages` poll.
  @visibleForTesting
  Future<void> debugRunPendingAckRetries() =>
      _retryPendingAckDeliveries(force: true);

  /// Group-membership envelopes still awaiting an ack from the targeted
  /// recipient. Exposed for diagnostics and tests; the retry loop drains
  /// this queue automatically.
  List<PendingGroupMembershipDelivery> get pendingGroupMembershipDeliveries =>
      List.unmodifiable(_snapshot.pendingGroupMembershipDeliveries);

  /// First-use-pinned Ed25519 identity keys per relay instance id. Updated
  /// by the route-health check when a v0.3 relay advertises its key with
  /// a verifiable signature.
  Map<String, String> get pinnedRelayIdentityKeys =>
      Map.unmodifiable(_snapshot.pinnedRelayIdentityKeys);
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
  int unreadGroupCountFor(String groupId) =>
      _unreadCountForConversation(_groupConversation(groupId));
  int get unreadLanLobbyCount =>
      _unreadCountForConversation(_lanLobbyConversation());
  GroupMemberRole? groupRoleFor(String groupId, String deviceId) =>
      _groupById(groupId)?.roleFor(deviceId);
  bool canAssignGroupRoles(String groupId) {
    final me = _snapshot.identity;
    final group = _groupById(groupId);
    return me != null && group != null && group.canAssignRoles(me.deviceId);
  }

  bool canAddGroupMembers(String groupId) {
    final me = _snapshot.identity;
    final group = _groupById(groupId);
    return me != null && group != null && group.canAddMembers(me.deviceId);
  }

  bool canRemoveGroupMember(String groupId, String memberDeviceId) {
    final me = _snapshot.identity;
    final group = _groupById(groupId);
    return me != null &&
        group != null &&
        group.canRemoveMember(
          actorDeviceId: me.deviceId,
          memberDeviceId: memberDeviceId,
        );
  }

  int get seenEnvelopeCount => _snapshot.seenEnvelopeIds.length;
  PeerRouteHealth? routeHealthFor(PeerEndpoint route) =>
      _routeHealthTracker.healthMap[route.routeKey];
  ContactReachabilityRecord? reachabilityRecordFor(String deviceId) =>
      _reachability.recordByDeviceId(deviceId);
  ContactReachabilityState reachabilityStateFor(String deviceId) =>
      _reachability.stateFor(deviceId);
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

  /// Wraps `_processEnvelopes` so the notifier-batching ref-count is
  /// exercised in tests without needing to drive the long-poll loop.
  @visibleForTesting
  Future<int> processEnvelopesForTesting(List<RelayEnvelope> envelopes) =>
      _processEnvelopes(envelopes);

  /// Resolves the preferred route list for a contact under the current
  /// global + per-contact connectivity preferences. Used by routing tests.
  @visibleForTesting
  List<PeerEndpoint> preferredRoutesForTesting(ContactRecord contact) =>
      _preferredRoutesForContact(contact);

  /// Number of currently in-flight `_processEnvelopes` calls. Exposed so a
  /// test can assert the depth returns to 0 after parallel calls finish.
  @visibleForTesting
  int get notificationsDeferredDepth => _notificationsDeferredDepth;

  /// Whether a `notifyListeners` call was suppressed by the batching guard
  /// since the last flush. Exposed so tests can verify the flush behavior.
  @visibleForTesting
  bool get deferredNotificationPending => _deferredNotificationPending;

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
      // Resume the long-poll loop on foreground entry. Stopping on
      // background avoids holding an open HTTP request while the OS
      // (especially Android) tries to suspend the app.
      unawaited(_startLongPollIfEnabled());
    } else if (!value) {
      _stopLongPoll();
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
    final record = _reachability.recordByDeviceId(deviceId);
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
        if (check.available && _routeHealthTracker.isEligibleNow(check.route)) {
          selectedRoute = check.route;
          break;
        }
      }
    }
    if (selectedRoute == null) {
      _reachability.noteFailure(contact.deviceId, at: now);
      await _saveSnapshotSilently(debounce: true);
      return;
    }
    _reachability.noteAvailablePath(contact.deviceId, at: now);
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
        final summaries =
            _protocolRoutes(
                  kind: PeerRouteKind.lan,
                  host: address,
                  port: me.localRelayPort,
                )
                .map(
                  (route) =>
                      _routeHealthTracker.healthMap[route.routeKey]?.summary,
                )
                .nonNulls;
        return summaries.isEmpty
            ? 'LAN reachability for $address not checked yet.'
            : summaries.join(' | ');
      }),
      me.configuredRelays.isEmpty
          ? 'No manually configured relay.'
          : '${me.configuredRelays.length} configured relay(s).',
      ...me.configuredRelays.map(
        (route) =>
            _routeHealthTracker.healthMap[route.routeKey]?.summary ??
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
          ).any(
            (route) =>
                _routeHealthTracker.healthMap[route.routeKey]?.available ??
                false,
          );
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
      await _ingestSignedDefaultRelaysIfNeeded();
      if (_snapshot.identity != null) {
        await _refreshLanAddresses(persist: false);
        await _ensureLocalRelayRunning();
        await _ensurePairingBeaconRunning();
        _applyAndroidBackgroundPreference();
        _reschedulePolling();
        unawaited(_pollLocalInboxOnly());
        unawaited(pollNow());
        unawaited(_startLongPollIfEnabled());
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

  /// Loads the signed default-relay manifest bundled with the app and, if
  /// its version is newer than what's already stored in the vault, appends
  /// any new endpoints to the identity's configured relays. User-added
  /// relays are never overwritten — `dedupePeerEndpoints` skips duplicates
  /// by route key. Failures (missing public key, tampered manifest) are
  /// silent — the path must never block startup.
  Future<void> _ingestSignedDefaultRelaysIfNeeded() async {
    final loader =
        _signedRelayDefaultsLoader ?? _loadSignedDefaultRelaysFromBundle;
    final SignedRelayDefaults? defaults;
    try {
      defaults = await loader();
    } catch (_) {
      return;
    }
    if (defaults == null) {
      return;
    }
    if (defaults.version <= _snapshot.defaultRelayDefaultsVersion) {
      return;
    }
    await _applyIngestedDefaults(defaults, recordFetchTimestamp: false);
  }

  /// Shared ingest path used by both the bundled-asset loader and the
  /// "Update default relays" GitHub fetch. Bumps the version, fans out
  /// multi-protocol endpoints, records host:port masking entries, and
  /// fire-and-forget probes each derived route.
  Future<List<PeerEndpoint>> _applyIngestedDefaults(
    SignedRelayDefaults defaults, {
    required bool recordFetchTimestamp,
  }) async {
    final me = _snapshot.identity;
    if (defaults.endpoints.isNotEmpty && me == null) {
      // Defer ingestion until identity exists; do not bump the version
      // yet so the next initialize() retries once pairing is complete.
      return const <PeerEndpoint>[];
    }
    final derived = _expandDefaultRelaySpecs(defaults.endpoints);
    if (me != null && derived.isNotEmpty) {
      final updated = dedupePeerEndpoints([...me.configuredRelays, ...derived]);
      final newDefaultKeys = <String>{
        ..._snapshot.defaultRelayRouteKeys,
        ...derived.map((endpoint) => endpoint.routeKey),
      };
      final newDefaultHosts = <String>{
        ..._snapshot.defaultRelayHosts,
        ...defaults.endpoints.map((spec) => '${spec.host}:${spec.port}'),
      };
      _snapshot = _snapshot.copyWith(
        identity: me.copyWith(configuredRelays: updated),
        defaultRelayDefaultsVersion: defaults.version,
        defaultRelayRouteKeys: newDefaultKeys,
        defaultRelayHosts: newDefaultHosts,
        defaultRelaysLastFetchedAt: recordFetchTimestamp
            ? DateTime.now().toUtc()
            : null,
      );
    } else {
      _snapshot = _snapshot.copyWith(
        defaultRelayDefaultsVersion: defaults.version,
        defaultRelaysLastFetchedAt: recordFetchTimestamp
            ? DateTime.now().toUtc()
            : null,
      );
    }
    await _saveSnapshotSilently(notify: false);
    // Pre-flight probe each new derived endpoint so the routing layer's
    // health-scoring sees a verdict before any real traffic chooses it.
    // Fire-and-forget — we don't want to block startup on a flaky network.
    if (derived.isNotEmpty) {
      unawaited(
        Future.wait([
          for (final endpoint in derived) _probeDefaultRelay(endpoint),
        ]),
      );
    }
    return derived;
  }

  /// Expands a list of [DefaultRelayEndpointSpec] into concrete
  /// [PeerEndpoint]s. Specs with an explicit protocol stay 1:1; specs with
  /// `protocol == null` fan out across TCP/UDP/HTTP/HTTPS — the pre-flight
  /// probe + health scoring downranks anything that doesn't answer.
  List<PeerEndpoint> _expandDefaultRelaySpecs(
    List<DefaultRelayEndpointSpec> specs,
  ) {
    final result = <PeerEndpoint>[];
    for (final spec in specs) {
      if (spec.protocol != null) {
        result.add(
          PeerEndpoint(
            kind: spec.kind,
            host: spec.host,
            port: spec.port,
            protocol: spec.protocol!,
          ),
        );
        continue;
      }
      for (final protocol in PeerRouteProtocol.values) {
        result.add(
          PeerEndpoint(
            kind: spec.kind,
            host: spec.host,
            port: spec.port,
            protocol: protocol,
          ),
        );
      }
    }
    return dedupePeerEndpoints(result);
  }

  Future<void> _probeDefaultRelay(PeerEndpoint endpoint) async {
    try {
      await _relayClient.inspectHealth(
        host: endpoint.host,
        port: endpoint.port,
        protocol: endpoint.protocol,
        timeout: const Duration(seconds: 4),
        expectedIdentityPublicKeyBase64:
            _snapshot.pinnedRelayIdentityKeys[endpoint.routeKey],
      );
    } catch (_) {
      // Failure surfaces via the scoring shim already; the relay falls
      // out of the rotation until subsequent probes succeed.
    }
  }

  static Future<SignedRelayDefaults?> _loadSignedDefaultRelaysFromBundle({
    AssetBundle? bundle,
  }) async {
    const publicKey = String.fromEnvironment(
      'CONEST_DEFAULT_RELAYS_PUBLIC_KEY',
    );
    if (publicKey.isEmpty) {
      return null;
    }
    final assets = bundle ?? rootBundle;
    try {
      final manifest = await assets.loadString('assets/default_relays.json');
      final signature = await assets.loadString(
        'assets/default_relays.ed25519.sig',
      );
      return loadSignedDefaultRelays(
        manifestJson: manifest,
        signatureBase64: signature,
        publicKeyBase64: publicKey,
      );
    } catch (_) {
      return null;
    }
  }

  /// Source of truth for the in-app "Update default relays" button. Pulls
  /// the latest signed manifest from the project's GitHub `main` branch,
  /// verifies it against the build-time public key, and ingests it if the
  /// `version` is newer than the one already persisted. Returns a result
  /// describing what happened so the UI can surface a snackbar.
  Future<DefaultRelaysRefreshResult> refreshDefaultRelays() async {
    const publicKey = String.fromEnvironment(
      'CONEST_DEFAULT_RELAYS_PUBLIC_KEY',
    );
    if (publicKey.isEmpty) {
      return const DefaultRelaysRefreshResult.error(
        'This build was packaged without a default-relays signing key.',
      );
    }
    final fetcher = _httpBytesFetcher;
    Uint8List manifestBytes;
    String signatureBase64;
    try {
      manifestBytes = await fetcher(
        '$kDefaultRelaysGitHubRawBase/default_relays.json',
      );
      final sigBytes = await fetcher(
        '$kDefaultRelaysGitHubRawBase/default_relays.ed25519.sig',
      );
      signatureBase64 = utf8.decode(sigBytes).trim();
    } catch (error) {
      return DefaultRelaysRefreshResult.error('Fetch failed: $error');
    }
    final defaults = await loadSignedDefaultRelaysFromBytes(
      manifestBytes: manifestBytes,
      signatureBase64: signatureBase64,
      publicKeyBase64: publicKey,
    );
    if (defaults == null) {
      return const DefaultRelaysRefreshResult.error(
        'Signature did not verify against the build key.',
      );
    }
    if (defaults.version <= _snapshot.defaultRelayDefaultsVersion) {
      _snapshot = _snapshot.copyWith(
        defaultRelaysLastFetchedAt: DateTime.now().toUtc(),
      );
      await _saveSnapshotSilently(notify: true);
      return DefaultRelaysRefreshResult.upToDate(
        version: _snapshot.defaultRelayDefaultsVersion,
      );
    }
    final added = await _applyIngestedDefaults(
      defaults,
      recordFetchTimestamp: true,
    );
    return DefaultRelaysRefreshResult.updated(
      version: defaults.version,
      addedRoutes: added,
    );
  }

  /// Imports a relay list from a user-supplied URL. When [publicKeyBase64]
  /// is non-null, the import follows the same signed-manifest verification
  /// path as the bundled defaults (signature fetched from `<url>.ed25519.sig`).
  /// When null, the list is parsed as plain JSON (untrusted import). Either
  /// way, the imported endpoints land in `me.configuredRelays` but are NOT
  /// recorded as defaults — the UI displays them with their actual
  /// `host:port` label. Returns the recorded [`CustomRelaySource`].
  Future<CustomRelaySource> importRelaysFromUrl({
    required String url,
    String? publicKeyBase64,
    String? replaceSourceId,
  }) async {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) {
      throw ArgumentError('URL is required.');
    }
    final fetcher = _httpBytesFetcher;
    final manifestBytes = await fetcher(trimmedUrl);
    SignedRelayDefaults? parsed;
    if (publicKeyBase64 != null && publicKeyBase64.trim().isNotEmpty) {
      final sigBytes = await fetcher('$trimmedUrl.ed25519.sig');
      parsed = await loadSignedDefaultRelaysFromBytes(
        manifestBytes: manifestBytes,
        signatureBase64: utf8.decode(sigBytes).trim(),
        publicKeyBase64: publicKeyBase64.trim(),
      );
      if (parsed == null) {
        throw ArgumentError(
          'Signature failed to verify against the supplied public key.',
        );
      }
    } else {
      parsed = parseUnsignedRelayList(utf8.decode(manifestBytes));
      if (parsed == null) {
        throw ArgumentError('Could not parse relay list from $trimmedUrl.');
      }
    }
    final me = _requireIdentity();
    final derived = _expandDefaultRelaySpecs(parsed.endpoints);
    final updated = dedupePeerEndpoints([...me.configuredRelays, ...derived]);
    final source = CustomRelaySource(
      id: replaceSourceId ?? _randomId('relay-source'),
      url: trimmedUrl,
      publicKeyBase64: publicKeyBase64?.trim().isEmpty ?? true
          ? null
          : publicKeyBase64!.trim(),
      lastVersion: parsed.version,
      lastFetchedAt: DateTime.now().toUtc(),
      routeKeys: <String>{for (final route in derived) route.routeKey},
    );
    final sources = List<CustomRelaySource>.from(_snapshot.customRelaySources);
    final existingIndex = sources.indexWhere(
      (existing) => existing.id == source.id,
    );
    if (existingIndex >= 0) {
      sources[existingIndex] = source;
    } else {
      sources.add(source);
    }
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(configuredRelays: updated),
      customRelaySources: sources,
    );
    await _persist('Imported ${derived.length} relay(s) from $trimmedUrl.');
    if (derived.isNotEmpty) {
      unawaited(
        Future.wait([
          for (final endpoint in derived) _probeDefaultRelay(endpoint),
        ]),
      );
    }
    return source;
  }

  /// Drops a previously-imported source plus every route it contributed.
  /// Routes the user also added manually under the same `host:port` remain
  /// only if they have an explicit non-imported origin — since the only
  /// origin tracking is per-source, removing a source removes its routes.
  Future<void> removeCustomRelaySource(String sourceId) async {
    final me = _requireIdentity();
    final source = _snapshot.customRelaySources.firstWhere(
      (candidate) => candidate.id == sourceId,
      orElse: () =>
          throw ArgumentError('No imported relay source with id $sourceId.'),
    );
    final remainingSources = _snapshot.customRelaySources
        .where((candidate) => candidate.id != sourceId)
        .toList(growable: false);
    final remainingRoutes = me.configuredRelays
        .where((route) => !source.routeKeys.contains(route.routeKey))
        .toList(growable: false);
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(configuredRelays: remainingRoutes),
      customRelaySources: remainingSources,
    );
    await _persist('Removed imported relay source ${source.url}.');
  }

  /// Test seam — overrides the HTTP byte fetcher used by
  /// [`refreshDefaultRelays`] / [`importRelaysFromUrl`] so unit tests can
  /// drive a deterministic response without hitting the network.
  @visibleForTesting
  void setHttpBytesFetcherForTesting(
    Future<Uint8List> Function(String url) fetcher,
  ) {
    _httpBytesFetcherOverride = fetcher;
  }

  Future<Uint8List> Function(String) get _httpBytesFetcher =>
      _httpBytesFetcherOverride ?? _defaultHttpBytesFetcher;

  static Future<Uint8List> _defaultHttpBytesFetcher(String url) async {
    final uri = Uri.parse(url);
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} fetching $url',
          uri: uri,
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  /// Sink invoked by [_ScoringRelayClient] after every relay call. Updates
  /// the per-endpoint [RelayHealthScore] in the vault snapshot.
  void _recordRelayAttemptFromShim({
    required String host,
    required int port,
    required PeerRouteProtocol protocol,
    required bool success,
    Duration? latency,
    required DateTime at,
  }) {
    final endpoint = PeerEndpoint(
      kind: PeerRouteKind.relay,
      host: host,
      port: port,
      protocol: protocol,
    );
    final key = relayHealthEndpointKey(endpoint);
    final current =
        _snapshot.relayHealthScores[key] ?? RelayHealthScore(endpointKey: key);
    final updated = current.recordAttempt(
      success: success,
      latency: latency,
      at: at.toUtc(),
    );
    final scores = Map<String, RelayHealthScore>.from(
      _snapshot.relayHealthScores,
    );
    scores[key] = updated;
    _snapshot = _snapshot.copyWith(relayHealthScores: scores);
  }

  bool _shouldRunAutomaticHeartbeats(IdentityRecord me) {
    if (!Platform.isAndroid) {
      return true;
    }
    return _appInForeground || me.androidBackgroundRuntimeEnabled;
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
      final reachability = _reachability.recordByDeviceId(contact.deviceId);
      buffer.writeln(
        'contact alias=${contact.alias} device=${contact.deviceId} relayCapable=${contact.relayCapable} reachability=${_reachability.stateFor(contact.deviceId).name} lastTwoWaySuccessAt=${reachability?.lastTwoWaySuccessAt?.toIso8601String() ?? ''} lastHeartbeatAttemptAt=${reachability?.lastHeartbeatAttemptAt?.toIso8601String() ?? ''} lastHeartbeatReplyAt=${reachability?.lastHeartbeatReplyAt?.toIso8601String() ?? ''} lastAvailablePathAt=${reachability?.lastAvailablePathAt?.toIso8601String() ?? ''} lastAnySignalAt=${reachability?.lastAnySignalAt?.toIso8601String() ?? ''} lastFailureAt=${reachability?.lastFailureAt?.toIso8601String() ?? ''} routeBackoff=${_routeBackoffSummaryForRoutes(_candidateRoutesForContact(contact))} routes=${contact.prioritizedRouteHints.map((route) => '${route.kind.name}:${route.label}:${routeHealthFor(route)?.summary ?? 'not checked'}').join(' | ')}',
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
      _reachability.noteAvailablePath(current.deviceId);
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
            : 'Checked ${checks.length} path(s) for ${current.alias}; $available available. Reachability is ${_reachability.stateFor(current.deviceId).label}. ${routeUpdateSent ? 'Route info exchange requested.' : 'Route info exchange could not be sent yet.'}',
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

    // The Debug Self Test ran only in `kDebugMode` historically. Nightly
    // builds are not `kDebugMode` but still need the diagnostics for
    // battle-testing, so the gate is dropped — runDebugSelfTest now runs
    // in every build. The Run Debug Tests button itself is gated on the
    // nightly channel by `HomeScreen` so end users on stable don't see
    // it.
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
      'Debug diagnostics available on $platform (build mode '
          '${kDebugMode
              ? 'debug'
              : kReleaseMode
              ? 'release'
              : 'profile'}).',
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

    // v0.3.2-nightly.3 regression guardrails — each catches a specific
    // bug class the user battle-tested.
    final notifierBatch = await _runNotifierBatchFlushCheck();
    add(notifierBatch.name, notifierBatch.status, notifierBatch.detail);
    final loopbackWiring = _runLocalLoopbackWiringCheck();
    add(loopbackWiring.name, loopbackWiring.status, loopbackWiring.detail);
    final longPollLifecycle = _runLongPollLifecycleCheck();
    add(
      longPollLifecycle.name,
      longPollLifecycle.status,
      longPollLifecycle.detail,
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
        final record = _reachability.recordByDeviceId(contact.deviceId);
        heartbeatAttemptBaseline[contact.deviceId] =
            record?.lastHeartbeatAttemptAt;
        heartbeatReplyBaseline[contact.deviceId] = record?.lastHeartbeatReplyAt;
      }
      await _runHeartbeatPass(force: true);
      final heartbeatAttemptedIds = <String>{};
      for (final contact in contacts) {
        final record = _reachability.recordByDeviceId(contact.deviceId);
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
        stateCounts[_reachability.stateFor(contact.deviceId)] =
            (stateCounts[_reachability.stateFor(contact.deviceId)] ?? 0) + 1;
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
        final reachability = _reachability.recordByDeviceId(contact.deviceId);
        final heartbeatAttemptAt = reachability?.lastHeartbeatAttemptAt;
        final heartbeatReplyAt = reachability?.lastHeartbeatReplyAt;
        final probeMessageId = probeMessageIds[contact.deviceId];
        final relayProbeMessageId = relayProbeMessageIds[contact.deviceId];
        final twoWayMessageId = twoWayMessageIds[contact.deviceId];
        peerReports.add(
          DebugPeerReport(
            alias: contact.alias,
            deviceId: contact.deviceId,
            reachability: _reachability.stateFor(contact.deviceId),
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

  Future<void> updateGlobalConnectivity(
    GlobalConnectivityPreferences prefs,
  ) async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(identity: me.copyWith(connectivity: prefs));
    await _applyGlobalConnectivityState();
    _markRuntimeActivity();
    final label = switch ((prefs.lanEnabled, prefs.onlineEnabled)) {
      (true, true) => 'Connectivity: LAN and Online enabled.',
      (true, false) => 'Connectivity: LAN only.',
      (false, true) => 'Connectivity: Online only.',
      (false, false) =>
        'Connectivity is fully off. The app will not send or receive.',
    };
    await _persist(label);
  }

  Future<void> updateContactRoutingPreferences(
    String deviceId,
    ContactRoutingPreferences prefs,
  ) async {
    final index = _snapshot.contacts.indexWhere((c) => c.deviceId == deviceId);
    if (index < 0) {
      return;
    }
    final contacts = List<ContactRecord>.from(_snapshot.contacts);
    contacts[index] = contacts[index].copyWith(routing: prefs);
    _snapshot = _snapshot.copyWith(contacts: contacts);
    await _persist('Routing preferences updated for ${contacts[index].alias}.');
  }

  /// Reconciles runtime listeners + loops with the current global connectivity
  /// flags. Idempotent — start/stop calls already short-circuit when desired
  /// state matches actual.
  Future<void> _applyGlobalConnectivityState() async {
    final identity = _snapshot.identity;
    if (identity == null) return;
    final global = identity.connectivity;
    const stopTimeout = Duration(seconds: 2);
    if (global.lanEnabled) {
      await _ensureLocalRelayRunning();
      await _ensurePairingBeaconRunning();
    } else {
      await _localRelayNode.stop().timeout(stopTimeout, onTimeout: () {});
      await _stopPairingBeacon().timeout(stopTimeout, onTimeout: () {});
    }
    if (global.onlineEnabled) {
      unawaited(_startLongPollIfEnabled());
    } else {
      _stopLongPoll();
    }
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
    validatePeerEndpointHostAndPort(parsed.host, parsed.port);
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

  /// Replaces the pinned Ed25519 identity for [relayId] with
  /// [newKeyBase64]. The caller (UI) must only invoke this after the
  /// operator has confirmed out-of-band that the relay rotated its key.
  /// Persists the new pin and clears any active "trust new key" surface
  /// for that relay.
  Future<void> rotateRelayIdentityKey({
    required String relayId,
    required String newKeyBase64,
  }) async {
    final id = relayId.trim();
    final key = newKeyBase64.trim();
    if (id.isEmpty || key.isEmpty) {
      throw ArgumentError('relayId and newKeyBase64 are required.');
    }
    final List<int> decoded;
    try {
      decoded = base64Decode(key);
    } on FormatException {
      throw ArgumentError('newKeyBase64 is not valid base64.');
    }
    if (decoded.length != 32) {
      throw ArgumentError('newKeyBase64 must decode to 32 bytes.');
    }
    final updated = Map<String, String>.from(_snapshot.pinnedRelayIdentityKeys)
      ..[id] = key;
    _snapshot = _snapshot.copyWith(pinnedRelayIdentityKeys: updated);
    _announcedRelayIdentityKeys.remove(id);
    await _persist('Trusted new identity for relay $id.');
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
    _reachability.remove(deviceId);
    _routeHealthTracker.healthMap.removeWhere((key, _) {
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

  /// Wipes the in-memory identity and the on-disk vault. Each potentially-
  /// blocking platform call is wrapped in a 2-second timeout so a stuck
  /// MethodChannel on Android can't freeze the reset dialog (the OS has
  /// usually torn down the relevant resources on its own by app pause —
  /// we don't need to wait indefinitely).
  ///
  /// [onPostReset] runs AFTER the vault is wiped and listeners notified.
  /// It's the caller's hook to delete the storage profile and re-enter
  /// the bootstrap layer so the storage-mode wizard shows again instead
  /// of the display-name screen. Failures inside the hook are swallowed;
  /// the user can manually restart the app if needed.
  Future<void> resetIdentity({Future<void> Function()? onPostReset}) async {
    _stopLongPoll();
    _pollTimer?.cancel();
    _pollTimer = null;
    _nextScheduledPollAt = null;
    _pendingSaveTimer?.cancel();
    _pendingSaveTimer = null;
    _pendingSaveCompleter = null;
    const platformCallTimeout = Duration(seconds: 2);
    await _platformBridge
        .setAndroidBackgroundRuntimeEnabled(false)
        .timeout(platformCallTimeout, onTimeout: () {});
    await _stopPairingBeacon().timeout(platformCallTimeout, onTimeout: () {});
    await _localRelayNode.stop().timeout(platformCallTimeout, onTimeout: () {});
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
    _routeHealthTracker.clear();
    _pendingRouteUpdateProbes.clear();
    _outboundAttemptedAt.clear();
    _debugProbeAcknowledgements.clear();
    _debugTwoWayReplies.clear();
    _locallyDeletedMessageIds.clear();
    notifyListeners();
    if (onPostReset != null) {
      try {
        await onPostReset();
      } catch (_) {
        // Best-effort: caller's hook (delete profile + re-launch
        // bootstrap) shouldn't fail loudly inside a reset flow.
      }
    }
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
    final safetyNumber = await _crypto.deriveSafetyNumber([publicKey.bytes]);
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
    await _ingestSignedDefaultRelaysIfNeeded();
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

    final safetyNumber = await _crypto.deriveSafetyNumber([
      base64Decode(me.publicKeyBase64),
      base64Decode(invite.publicKeyBase64),
    ]);
    // Identity-reset / impersonation guardrail: if the invite carries the
    // same display name as an existing trusted contact but a different
    // public key, the new contact lands in pendingVerification state. The
    // crypto layer becomes the actual block — `publicKeyBase64` is empty
    // while pending so `_pairwiseDirectKey` cannot derive a shared secret
    // for either direction. The user must explicitly confirm (legit
    // reinstall) or reject (impersonation) before any envelopes flow.
    final predecessor = _findPossibleContactPredecessor(
      displayName: invite.displayName,
      publicKeyBase64: invite.publicKeyBase64,
    );
    final isPending = predecessor != null;
    final contact = ContactRecord(
      accountId: invite.accountId,
      deviceId: invite.deviceId,
      alias: alias.trim().isEmpty ? invite.displayName : alias.trim(),
      displayName: invite.displayName,
      bio: invite.bio,
      relayCapable: invite.relayCapable,
      publicKeyBase64: isPending ? '' : invite.publicKeyBase64,
      routeHints: prunePeerEndpointsByKind(invite.routeHints),
      safetyNumber: safetyNumber,
      trustedAt: DateTime.now().toUtc(),
      pendingVerification: isPending,
      replacesDeviceId: predecessor?.deviceId,
      unverifiedPublicKeyBase64: isPending ? invite.publicKeyBase64 : null,
    );
    final conversations = List<ConversationRecord>.from(_snapshot.conversations)
      ..add(
        ConversationRecord(
          id: _crypto.conversationIdFor(contact.deviceId),
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

  /// Scans existing contacts for one with the same display name (case- /
  /// whitespace-insensitive) but a different identity public key. When such
  /// a match exists, the inbound contact arrives in `pendingVerification`
  /// state and the user must confirm or reject. Returns null when there's
  /// no candidate.
  ContactRecord? _findPossibleContactPredecessor({
    required String displayName,
    required String publicKeyBase64,
  }) {
    final needle = displayName.trim().toLowerCase();
    if (needle.isEmpty) {
      return null;
    }
    ContactRecord? best;
    DateTime? bestTrustedAt;
    for (final candidate in _snapshot.contacts) {
      if (candidate.publicKeyBase64 == publicKeyBase64) {
        continue;
      }
      if (candidate.isArchived) {
        continue;
      }
      if (candidate.displayName.trim().toLowerCase() != needle) {
        continue;
      }
      if (bestTrustedAt == null || candidate.trustedAt.isAfter(bestTrustedAt)) {
        best = candidate;
        bestTrustedAt = candidate.trustedAt;
      }
    }
    return best;
  }

  /// Returns the contact identified by [deviceId] when it exists. Public
  /// for the conversation UI which needs to look up the predecessor by id.
  ContactRecord? contactByDeviceId(String deviceId) =>
      _contactByDeviceId(deviceId);

  /// Confirms that a `pendingVerification` contact is the legitimate
  /// reinstall of its predecessor. Lifts the hard block, drains held
  /// inbound envelopes into the conversation, and marks the predecessor
  /// as archived (read-only history, no outbound).
  Future<void> confirmContactReplacement(String newContactDeviceId) async {
    final contact = _contactByDeviceId(newContactDeviceId);
    if (contact == null) {
      throw ArgumentError('No contact with id $newContactDeviceId.');
    }
    if (!contact.pendingVerification) {
      return;
    }
    final promotedKey = contact.unverifiedPublicKeyBase64;
    if (promotedKey == null || promotedKey.isEmpty) {
      throw StateError(
        'Cannot confirm ${contact.alias}: no unverified public key on file.',
      );
    }
    final updatedContacts = <ContactRecord>[
      for (final existing in _snapshot.contacts)
        if (existing.deviceId == contact.deviceId)
          existing.copyWith(
            publicKeyBase64: promotedKey,
            pendingVerification: false,
            clearReplacesDeviceId: true,
            clearUnverifiedPublicKey: true,
          )
        else if (contact.replacesDeviceId != null &&
            existing.deviceId == contact.replacesDeviceId)
          existing.copyWith(replacedByDeviceId: contact.deviceId)
        else
          existing,
    ];
    final remainingHeld = _snapshot.heldUnverifiedEnvelopes
        .where((entry) => entry.senderDeviceId != contact.deviceId)
        .toList(growable: false);
    final toReplay = _snapshot.heldUnverifiedEnvelopes
        .where((entry) => entry.senderDeviceId == contact.deviceId)
        .toList(growable: false);
    _snapshot = _snapshot.copyWith(
      contacts: updatedContacts,
      heldUnverifiedEnvelopes: remainingHeld,
    );
    await _persist('Confirmed identity replacement for ${contact.alias}.');
    if (toReplay.isNotEmpty) {
      final envelopes = <RelayEnvelope>[];
      for (final entry in toReplay) {
        try {
          envelopes.add(
            RelayEnvelope.fromJson(
              jsonDecode(entry.envelopeJson) as Map<String, dynamic>,
            ),
          );
        } catch (_) {
          // Drop malformed entries; the original sender will retry.
        }
      }
      if (envelopes.isNotEmpty) {
        unawaited(_processEnvelopes(envelopes));
      }
    }
  }

  /// Rejects a `pendingVerification` contact — typically because it's an
  /// impersonation attempt. Deletes the contact and any held inbound
  /// envelopes from that sender.
  Future<void> rejectContactReplacement(String newContactDeviceId) async {
    final contact = _contactByDeviceId(newContactDeviceId);
    if (contact == null) {
      throw ArgumentError('No contact with id $newContactDeviceId.');
    }
    if (!contact.pendingVerification) {
      throw ArgumentError(
        'Contact ${contact.alias} is not awaiting verification.',
      );
    }
    final remainingContacts = _snapshot.contacts
        .where((existing) => existing.deviceId != contact.deviceId)
        .toList(growable: false);
    final remainingHeld = _snapshot.heldUnverifiedEnvelopes
        .where((entry) => entry.senderDeviceId != contact.deviceId)
        .toList(growable: false);
    final remainingConversations = _snapshot.conversations
        .where((conversation) => conversation.peerDeviceId != contact.deviceId)
        .toList(growable: false);
    final remainingReachability = _snapshot.reachabilityRecords
        .where((record) => record.deviceId != contact.deviceId)
        .toList(growable: false);
    _snapshot = _snapshot.copyWith(
      contacts: remainingContacts,
      conversations: remainingConversations,
      reachabilityRecords: remainingReachability,
      heldUnverifiedEnvelopes: remainingHeld,
    );
    await _persist('Rejected identity replacement for ${contact.alias}.');
  }

  /// Held inbound envelopes from `pendingVerification` contacts. Exposed
  /// for diagnostics + tests; the public confirm/reject API drains the
  /// queue automatically.
  List<HeldEnvelope> get heldUnverifiedEnvelopes =>
      List.unmodifiable(_snapshot.heldUnverifiedEnvelopes);

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
    if (contact.pendingVerification) {
      throw StateError(
        'Cannot send to ${contact.alias} until the identity is verified.',
      );
    }
    if (contact.isArchived) {
      throw StateError(
        'Cannot send to ${contact.alias}: this contact has been replaced.',
      );
    }

    final message = ChatMessage(
      id: _randomId('msg'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
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

  /// Hard limit for v0.3.2 attachments per [notes/PLAN.md] — "small files".
  /// Larger transfers are deferred to v0.3.3 chunk-cache work.
  /// Hard cap for a single v0.3.2 attachment. Bumped from 8 MB → 30 MB
  /// alongside zero-copy slicing and a smaller 32 KB chunk size. Larger
  /// transfers wait for v0.3.3 chunk-cache work per notes/PLAN.md.
  static const int maxAttachmentSizeBytes = 30 * 1024 * 1024;

  /// 32 KB chunks keep each pairwise-encrypted envelope well under the
  /// relay's `DEFAULT_MAX_ENVELOPE_BYTES = 256 KB` cap (32 KB raw
  /// + base64 chunk ciphertext + ChaCha20 overhead + JSON wrap ≈ 100 KB).
  /// For a worst-case 30 MB file this means ~960 chunks; SHA-256 across
  /// them is sub-second on modern devices.
  static const int _attachmentChunkSize = 32 * 1024;

  /// Maximum number of attachments accepted in one user-triggered batch
  /// (multi-file picker, drag-and-drop, mobile gallery multi-select). Each
  /// file still has to clear `maxAttachmentSizeBytes` individually; the
  /// batch cap caps the per-send fanout so a stray drag with 50+ files
  /// doesn't drown the recipient.
  static const int maxAttachmentsPerSend = 6;

  /// Sends a file attachment as a v0.3.2 1:1 transfer. The recipient
  /// receives an `attachment_offer` envelope (pairwise-encrypted), then
  /// pulls chunks back via `attachment_chunk_request` / `attachment_chunk`
  /// envelopes until the descriptor's `chunkHashes` are all verified.
  /// The original bytes stay in memory on the sender until the recipient
  /// sends `attachment_complete` or `attachment_cancel`.
  Future<void> sendAttachment({
    required ContactRecord contact,
    required Uint8List bytes,
    required String fileName,
    String mimeType = 'application/octet-stream',
    String caption = '',
  }) async {
    final me = _requireIdentity();
    if (!contact.canSendOutbound) {
      throw StateError(
        'Cannot send to ${contact.alias} until the identity is verified.',
      );
    }
    if (bytes.isEmpty) {
      throw ArgumentError('Cannot send an empty file.');
    }
    if (bytes.length > maxAttachmentSizeBytes) {
      throw ArgumentError(
        'Attachment exceeds the ${maxAttachmentSizeBytes ~/ (1024 * 1024)} '
        'MB v0.3.2 cap.',
      );
    }

    final attachmentId = _randomId('att');
    final chunkSize = _attachmentChunkSize;
    final chunkBytes = <Uint8List>[];
    final chunkHashes = <ChunkHash>[];
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize > bytes.length)
          ? bytes.length
          : offset + chunkSize;
      // Zero-copy view into the original buffer. Previously
      // `Uint8List.fromList(bytes.sublist(...))` allocated per-chunk
      // copies — for a 30 MB file that's ~960 transient allocations and
      // ~60 MB peak memory, enough to OOM low-RAM Android.
      final slice = Uint8List.view(
        bytes.buffer,
        bytes.offsetInBytes + offset,
        end - offset,
      );
      chunkBytes.add(slice);
      final digest = await Sha256().hash(slice);
      chunkHashes.add(
        ChunkHash(
          index: chunkBytes.length - 1,
          hashBase64: base64Encode(digest.bytes),
        ),
      );
    }

    // Per-attachment key; chunks travel inside pairwise-encrypted envelopes
    // today, so this is forward compatibility for v0.3.3 when relays cache
    // chunks and need them opaque without the descriptor.
    final attachmentKey = SecretKeyData.random(length: 32);
    final descriptor = AttachmentDescriptor(
      id: attachmentId,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: bytes.length,
      chunkSize: chunkSize,
      chunkHashes: chunkHashes,
      encryptionKeyBase64: base64Encode(await attachmentKey.extractBytes()),
      createdAt: DateTime.now().toUtc(),
    );

    final message = ChatMessage(
      id: _randomId('msg'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      body: caption,
      outbound: true,
      state: DeliveryState.pending,
      createdAt: DateTime.now().toUtc(),
      attachment: descriptor,
    );
    _upsertMessage(contact.deviceId, message);
    _outboundAttachments[attachmentId] = _OutboundAttachmentState(
      messageId: message.id,
      peerDeviceId: contact.deviceId,
      chunks: chunkBytes,
      descriptor: descriptor,
    );
    // Sender keeps a copy so the chat bubble can render the image / file
    // preview without waiting for the recipient's complete envelope.
    _assembledAttachments[attachmentId] = bytes;
    // Persist asynchronously so the bubble survives an app restart on
    // the sender side too — no point keeping a transfer-state bubble
    // when we have the original right here.
    unawaited(_persistAttachmentBytes(attachmentId, bytes));
    _markRuntimeActivity();
    notifyListeners();

    // Send the offer envelope. Chunks flow on demand as the recipient
    // requests them.
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'attachment_offer',
      messageId: _randomId('aoff'),
      conversationId: message.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode({
        'descriptor': descriptor.toJson(),
        'parentMessageId': message.id,
        'caption': caption,
      }),
      createdAt: message.createdAt,
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: envelope,
      );
      _updateMessageState(contact.deviceId, message.id, DeliveryState.relayed);
    } catch (error) {
      _statusMessage = 'Attachment offer delivery failed: $error';
      notifyListeners();
    }
  }

  /// Returns the assembled bytes for an attachment, or null while the
  /// transfer is still in flight (or was never offered to this peer).
  /// Hits the on-disk cache as a fallback so a freshly-launched app
  /// keeps rendering thumbnails / Save buttons for messages it
  /// received in a previous session.
  Uint8List? attachmentBytesFor(String attachmentId) {
    final cached = _assembledAttachments[attachmentId];
    if (cached != null) {
      return cached;
    }
    // Fire-and-forget disk read; the lazy loader fires notifyListeners
    // when it finishes so the bubble rebuilds with the bytes in memory.
    unawaited(_loadAttachmentBytesFromDisk(attachmentId));
    return null;
  }

  Future<Directory> _attachmentRoot() async {
    final dir = await _attachmentRootProvider();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _persistAttachmentBytes(
    String attachmentId,
    Uint8List bytes,
  ) async {
    try {
      final dir = await _attachmentRoot();
      final file = File(p.join(dir.path, attachmentId));
      await file.writeAsBytes(bytes, flush: true);
    } catch (error) {
      // Persisting is best-effort; the in-memory copy still renders.
      _statusMessage = 'Could not cache attachment to disk: $error';
    }
  }

  final Set<String> _attachmentDiskLoadInFlight = <String>{};

  Future<void> _loadAttachmentBytesFromDisk(String attachmentId) async {
    if (_assembledAttachments.containsKey(attachmentId) ||
        _attachmentDiskLoadInFlight.contains(attachmentId)) {
      return;
    }
    _attachmentDiskLoadInFlight.add(attachmentId);
    try {
      final dir = await _attachmentRoot();
      final file = File(p.join(dir.path, attachmentId));
      if (!await file.exists()) {
        return;
      }
      final bytes = await file.readAsBytes();
      _assembledAttachments[attachmentId] = bytes;
      notifyListeners();
    } catch (_) {
      // Cache miss / read failure: UI keeps the transferring indicator.
    } finally {
      _attachmentDiskLoadInFlight.remove(attachmentId);
    }
  }

  /// Test hook: drops the in-memory cache for [attachmentId] so a
  /// subsequent `attachmentBytesFor` triggers the disk-load path. Used
  /// by the regression test that asserts the bytes survive a relaunch.
  @visibleForTesting
  void evictAttachmentBytesForTesting(String attachmentId) {
    _assembledAttachments.remove(attachmentId);
  }

  /// Receiver-side progress for an inbound attachment, as a fraction
  /// in `[0, 1]`. Returns null when the transfer has either not started
  /// or has already completed (in which case [attachmentBytesFor] gives
  /// the assembled bytes). The bubble uses this to render a thin
  /// progress bar above the file row.
  double? attachmentTransferProgress(String attachmentId) {
    final state = _inboundAttachments[attachmentId];
    if (state == null) {
      return null;
    }
    if (state.descriptor.chunkHashes.isEmpty) {
      return 0;
    }
    final received = state.received.where((chunk) => chunk != null).length;
    return received / state.descriptor.chunkHashes.length;
  }

  /// Resolves the on-disk cache path for a completed attachment so the
  /// Copy-path UI affordance can hand it off to the OS clipboard.
  /// Returns null if the bytes haven't been persisted yet (transfer
  /// still in flight or the disk write failed).
  Future<String?> attachmentCachePathFor(String attachmentId) async {
    try {
      final dir = await _attachmentRoot();
      final file = File(p.join(dir.path, attachmentId));
      if (!await file.exists()) {
        return null;
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<GroupRecord> createGroup({
    required String title,
    required List<ContactRecord> members,
    List<String> adminDeviceIds = const <String>[],
    List<String> moderatorDeviceIds = const <String>[],
  }) async {
    final me = _requireIdentity();
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw ArgumentError('Group title cannot be empty.');
    }
    final uniqueMembers = _dedupeContacts(members)
        .where((contact) => contact.deviceId != me.deviceId)
        .toList(growable: false);
    if (uniqueMembers.isEmpty) {
      throw ArgumentError('Choose at least one trusted contact.');
    }
    if (uniqueMembers.length + 1 > _maxGroupMembers) {
      throw ArgumentError('Groups are capped at $_maxGroupMembers members.');
    }
    final now = _now();
    final group = GroupRecord(
      groupId: _randomId('grp'),
      title: trimmedTitle,
      ownerDeviceId: me.deviceId,
      adminDeviceIds: adminDeviceIds,
      moderatorDeviceIds: moderatorDeviceIds,
      memberDeviceIds: [
        me.deviceId,
        ...uniqueMembers.map((contact) => contact.deviceId),
      ],
      removedDeviceIds: const <String>[],
      membershipVersion: 1,
      createdAt: now,
      updatedAt: now,
    );
    final profiledGroup = _refreshGroupMemberProfiles(
      group,
      contacts: uniqueMembers,
    );
    _upsertGroup(profiledGroup);
    _ensureGroupConversation(profiledGroup);
    await _persist('Created group ${profiledGroup.title}.');
    await _sendGroupMembershipUpdate(
      profiledGroup,
      targetDeviceIds: profiledGroup.activeMemberDeviceIds
          .where((deviceId) => deviceId != me.deviceId)
          .toList(growable: false),
      reason: 'create',
    );
    return profiledGroup;
  }

  Future<void> addGroupMembers({
    required String groupId,
    required List<ContactRecord> members,
  }) async {
    final me = _requireIdentity();
    final group = _requireGroup(groupId);
    if (!group.canAddMembers(me.deviceId)) {
      throw ArgumentError('Only the group owner or an admin can add members.');
    }
    final newMemberIds = _dedupeContacts(members)
        .map((contact) => contact.deviceId)
        .where(
          (deviceId) =>
              deviceId != me.deviceId &&
              !group.activeMemberDeviceIds.contains(deviceId),
        )
        .toList(growable: false);
    if (newMemberIds.isEmpty) {
      return;
    }
    final active = <String>{...group.activeMemberDeviceIds, ...newMemberIds};
    if (active.length > _maxGroupMembers) {
      throw ArgumentError('Groups are capped at $_maxGroupMembers members.');
    }
    final updated = _refreshGroupMemberProfiles(
      group.copyWith(
        memberDeviceIds: [...active],
        removedDeviceIds: group.removedDeviceIds
            .where((deviceId) => !newMemberIds.contains(deviceId))
            .toList(growable: false),
        membershipVersion: group.membershipVersion + 1,
        updatedAt: _now(),
      ),
      contacts: members,
    );
    _upsertGroup(updated);
    await _persist('Updated group ${updated.title}.');
    await _sendGroupMembershipUpdate(
      updated,
      targetDeviceIds: updated.activeMemberDeviceIds
          .where((deviceId) => deviceId != me.deviceId)
          .toList(growable: false),
      reason: 'add_members',
    );
  }

  Future<void> removeGroupMember({
    required String groupId,
    required String memberDeviceId,
  }) async {
    final me = _requireIdentity();
    final group = _requireGroup(groupId);
    if (!group.canRemoveMember(
      actorDeviceId: me.deviceId,
      memberDeviceId: memberDeviceId,
    )) {
      throw ArgumentError('You do not have permission to remove that member.');
    }
    if (!group.activeMemberDeviceIds.contains(memberDeviceId)) {
      return;
    }
    final updated = _refreshGroupMemberProfiles(group).copyWith(
      adminDeviceIds: group.adminDeviceIds
          .where((deviceId) => deviceId != memberDeviceId)
          .toList(growable: false),
      moderatorDeviceIds: group.moderatorDeviceIds
          .where((deviceId) => deviceId != memberDeviceId)
          .toList(growable: false),
      memberDeviceIds: group.memberDeviceIds
          .where((deviceId) => deviceId != memberDeviceId)
          .toList(growable: false),
      removedDeviceIds: [...group.removedDeviceIds, memberDeviceId],
      membershipVersion: group.membershipVersion + 1,
      updatedAt: _now(),
    );
    _upsertGroup(updated);
    await _persist('Removed a member from ${updated.title}.');
    await _sendGroupMembershipUpdate(
      updated,
      targetDeviceIds: [
        ...updated.activeMemberDeviceIds.where(
          (deviceId) => deviceId != me.deviceId,
        ),
        memberDeviceId,
      ],
      reason: 'remove_member',
    );
  }

  Future<void> leaveGroup(String groupId) async {
    final me = _requireIdentity();
    final group = _requireGroup(groupId);
    if (group.ownerDeviceId == me.deviceId) {
      throw ArgumentError('The group creator cannot leave in v0.2.');
    }
    if (!group.activeMemberDeviceIds.contains(me.deviceId)) {
      return;
    }
    final updated = _refreshGroupMemberProfiles(group).copyWith(
      adminDeviceIds: group.adminDeviceIds
          .where((deviceId) => deviceId != me.deviceId)
          .toList(growable: false),
      moderatorDeviceIds: group.moderatorDeviceIds
          .where((deviceId) => deviceId != me.deviceId)
          .toList(growable: false),
      memberDeviceIds: group.memberDeviceIds
          .where((deviceId) => deviceId != me.deviceId)
          .toList(growable: false),
      removedDeviceIds: [...group.removedDeviceIds, me.deviceId],
      membershipVersion: group.membershipVersion + 1,
      updatedAt: _now(),
    );
    _upsertGroup(updated);
    await _persist('Left group ${updated.title}.');
    await _sendGroupLeave(updated);
  }

  /// Hides a group the local user has already left from the sidebar and
  /// purges the local conversation/message history. The local user must
  /// not still be an active member; the UI should require [leaveGroup]
  /// first. No wire envelope is sent — remote members already see the
  /// local user as left from the prior membership update.
  Future<void> removeGroupFromList(String groupId) async {
    final group = _requireGroup(groupId);
    final me = _requireIdentity();
    if (group.hasActiveMember(me.deviceId)) {
      throw ArgumentError('Leave the group before removing it from your list.');
    }
    if (group.localRemovedAt != null) {
      return;
    }
    final updated = group.copyWith(localRemovedAt: _now());
    final conversations = _snapshot.conversations
        .where(
          (conversation) =>
              !(conversation.kind == ConversationKind.group &&
                  conversation.id == groupId),
        )
        .toList();
    final groups = List<GroupRecord>.from(_snapshot.groups);
    final index = groups.indexWhere((g) => g.groupId == groupId);
    if (index != -1) {
      groups[index] = updated;
    }
    _snapshot = _snapshot.copyWith(
      groups: groups,
      conversations: conversations,
    );
    await _persist('Removed group ${updated.title} from your list.');
  }

  /// Owner-only. Hands ownership of [groupId] to [newOwnerDeviceId]; the
  /// previous owner is demoted to admin and stays in the group. Throws
  /// [ArgumentError] when the local user is not the current owner, when
  /// the target equals the current owner, or when the target is not a
  /// currently active member.
  Future<void> transferGroupOwnership({
    required String groupId,
    required String newOwnerDeviceId,
  }) async {
    final me = _requireIdentity();
    final group = _requireGroup(groupId);
    if (group.ownerDeviceId != me.deviceId) {
      throw ArgumentError('Only the group owner can transfer ownership.');
    }
    if (newOwnerDeviceId == me.deviceId ||
        newOwnerDeviceId == group.ownerDeviceId) {
      throw ArgumentError('Pick a different member to receive ownership.');
    }
    if (!group.hasActiveMember(newOwnerDeviceId)) {
      throw ArgumentError(
        'Ownership can only be transferred to an active member.',
      );
    }
    final previousOwner = me.deviceId;
    final adminIds = [
      previousOwner,
      ...group.adminDeviceIds.where(
        (deviceId) => deviceId != previousOwner && deviceId != newOwnerDeviceId,
      ),
    ];
    final moderatorIds = group.moderatorDeviceIds
        .where((deviceId) => deviceId != newOwnerDeviceId)
        .toList(growable: false);
    final memberIds = group.memberDeviceIds
        .where((deviceId) => deviceId != newOwnerDeviceId)
        .toList(growable: false);
    final updated = _refreshGroupMemberProfiles(
      group.copyWith(
        ownerDeviceId: newOwnerDeviceId,
        adminDeviceIds: adminIds,
        moderatorDeviceIds: moderatorIds,
        memberDeviceIds: memberIds,
        membershipVersion: group.membershipVersion + 1,
        updatedAt: _now(),
      ),
    );
    _upsertGroup(updated);
    await _persist(
      'Transferred ownership of ${updated.title} to ${groupMemberLabel(newOwnerDeviceId)}.',
    );
    await _sendGroupMembershipUpdate(
      updated,
      targetDeviceIds: updated.activeMemberDeviceIds
          .where((deviceId) => deviceId != me.deviceId)
          .toList(growable: false),
      reason: 'transfer_ownership',
    );
  }

  /// Owner-only. Dissolves [groupId] for every active member, including
  /// the owner. The group's [GroupRecord.dissolvedAt] is set so that
  /// `activeMemberDeviceIds` returns empty for every recipient, dropping
  /// the (now-former) members into the existing "You left" / Remove-from-list
  /// UX. Throws [ArgumentError] when the local user is not the current
  /// owner.
  Future<void> dissolveGroup(String groupId) async {
    final me = _requireIdentity();
    final group = _requireGroup(groupId);
    if (group.ownerDeviceId != me.deviceId) {
      throw ArgumentError('Only the group owner can delete the group.');
    }
    if (group.isDissolved) {
      return;
    }
    final formerActive = group.activeMemberDeviceIds.toList(growable: false);
    final now = _now();
    final updated = _refreshGroupMemberProfiles(
      group.copyWith(
        dissolvedAt: now,
        membershipVersion: group.membershipVersion + 1,
        updatedAt: now,
      ),
    );
    _upsertGroup(updated);
    await _persist('Deleted group ${updated.title} for everyone.');
    await _sendGroupMembershipUpdate(
      updated,
      targetDeviceIds: formerActive
          .where((deviceId) => deviceId != me.deviceId)
          .toList(growable: false),
      reason: 'dissolved',
    );
  }

  Future<void> setGroupMemberRole({
    required String groupId,
    required String memberDeviceId,
    required GroupMemberRole role,
  }) async {
    final me = _requireIdentity();
    final group = _requireGroup(groupId);
    if (!group.canAssignRoles(me.deviceId)) {
      throw ArgumentError('Only the group owner can change roles.');
    }
    if (memberDeviceId == group.ownerDeviceId ||
        role == GroupMemberRole.owner) {
      throw ArgumentError('The group owner role cannot be changed.');
    }
    if (!group.hasActiveMember(memberDeviceId)) {
      throw ArgumentError('Roles can only be assigned to active members.');
    }

    final adminIds = group.adminDeviceIds
        .where((deviceId) => deviceId != memberDeviceId)
        .toList();
    final moderatorIds = group.moderatorDeviceIds
        .where((deviceId) => deviceId != memberDeviceId)
        .toList();
    if (role == GroupMemberRole.admin) {
      adminIds.add(memberDeviceId);
    } else if (role == GroupMemberRole.moderator) {
      moderatorIds.add(memberDeviceId);
    }
    final currentRole = group.roleFor(memberDeviceId);
    if (currentRole == role) {
      return;
    }
    final updated = _refreshGroupMemberProfiles(
      group.copyWith(
        adminDeviceIds: adminIds,
        moderatorDeviceIds: moderatorIds,
        membershipVersion: group.membershipVersion + 1,
        updatedAt: _now(),
      ),
    );
    _upsertGroup(updated);
    await _persist(
      'Updated ${groupMemberLabel(memberDeviceId)} in ${updated.title}.',
    );
    await _sendGroupMembershipUpdate(
      updated,
      targetDeviceIds: updated.activeMemberDeviceIds
          .where((deviceId) => deviceId != me.deviceId)
          .toList(growable: false),
      reason: 'role_change',
    );
  }

  Future<void> sendGroupMessage({
    required String groupId,
    required String body,
    ChatMessage? replyTo,
  }) async {
    final me = _requireIdentity();
    final group = _requireGroup(groupId);
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return;
    }
    if (!group.hasActiveMember(me.deviceId)) {
      throw ArgumentError('You are no longer a member of this group.');
    }
    final profiledGroup = _refreshGroupMemberProfiles(group);
    if (!_sameGroupMemberProfiles(profiledGroup, group)) {
      _upsertGroup(profiledGroup);
    }
    final recipientContacts = _groupRecipientContacts(profiledGroup);
    if (recipientContacts.isEmpty) {
      throw ArgumentError('No reachable group member profiles are available.');
    }
    final message = ChatMessage(
      id: _randomId('gmsg'),
      conversationId: profiledGroup.groupId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: profiledGroup.groupId,
      body: trimmed,
      outbound: true,
      state: DeliveryState.pending,
      createdAt: _now(),
      senderDisplayName: me.displayName,
      replyToMessageId: replyTo?.id,
      replySnippet: replyTo == null ? null : _replySnippetForMessage(replyTo),
      replySenderDeviceId: replyTo?.senderDeviceId,
      replySenderDisplayName: replyTo == null
          ? null
          : _replySenderDisplayName(replyTo),
      recipientStates: {
        for (final contact in recipientContacts)
          contact.deviceId: DeliveryState.pending,
      },
    );
    _upsertGroupMessage(profiledGroup.groupId, message);
    _markRuntimeActivity();
    await _persist('Sending group message to ${profiledGroup.title}.');
    for (final contact in recipientContacts) {
      await _tryDeliverExistingGroupMessage(
        group: profiledGroup,
        contact: contact,
        message: message,
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
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'message_edit',
      messageId: _randomId('edit'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
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
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'message_delete',
      messageId: _randomId('del'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
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

  /// In-memory rate-limit for orphan-removal notices. When we receive an
  /// envelope from a sender we no longer know, we send one
  /// `contact_remove` back so the peer (whose original contact_remove
  /// got lost in transit, or who never thought we were a contact) can
  /// drop us. Without this throttle, every retry from the peer would
  /// echo back another notice and spam the relay.
  final Map<String, DateTime> _orphanRemovalNoticesSentAt =
      <String, DateTime>{};
  static const Duration _orphanRemovalNoticeCooldown = Duration(minutes: 5);

  Future<void> _maybeSendOrphanContactRemoval({
    required String senderDeviceId,
  }) async {
    if (senderDeviceId.isEmpty || !hasIdentity) {
      return;
    }
    // Global Online disabled → no relay traffic, including this echo.
    if (!_snapshot.identity!.connectivity.onlineEnabled) {
      return;
    }
    // Already in contacts (or being verified) → not an orphan.
    if (_contactByDeviceId(senderDeviceId) != null) {
      return;
    }
    // Group member → handled by group flow.
    for (final group in _snapshot.groups) {
      if (group.activeMemberDeviceIds.contains(senderDeviceId)) {
        return;
      }
    }
    final me = _requireIdentity();
    if (senderDeviceId == me.deviceId) {
      return;
    }
    final now = _now();
    final lastSent = _orphanRemovalNoticesSentAt[senderDeviceId];
    if (lastSent != null &&
        now.difference(lastSent) < _orphanRemovalNoticeCooldown) {
      return;
    }
    _orphanRemovalNoticesSentAt[senderDeviceId] = now;
    final removal = RelayEnvelope(
      kind: 'contact_remove',
      messageId: _randomId('rmorph'),
      conversationId: 'contact-remove-$senderDeviceId',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: senderDeviceId,
      createdAt: DateTime.now().toUtc(),
    );
    final relayRoutes = me.configuredRelays
        .where((r) => r.kind == PeerRouteKind.relay)
        .toList(growable: false);
    if (relayRoutes.isEmpty) {
      return;
    }
    try {
      await _deliverAcrossRoutes(
        routes: relayRoutes,
        recipientDeviceId: senderDeviceId,
        envelope: removal,
      );
    } catch (_) {
      // Best-effort; receiver may not share a relay with us.
    }
  }

  Future<bool> _sendContactRemoval(ContactRecord contact) async {
    final me = _requireIdentity();
    final removal = RelayEnvelope(
      kind: 'contact_remove',
      messageId: _randomId('rm'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
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

  Future<void> _sendGroupMembershipUpdate(
    GroupRecord group, {
    required List<String> targetDeviceIds,
    required String reason,
  }) async {
    final me = _requireIdentity();
    final profiledGroup = _refreshGroupMemberProfiles(group);
    if (!_sameGroupMemberProfiles(profiledGroup, group)) {
      _upsertGroup(profiledGroup);
    }
    final payload = jsonEncode({
      'version': 1,
      'reason': reason,
      'group': profiledGroup.toJson(),
    });
    final now = _now();
    for (final deviceId in targetDeviceIds.toSet()) {
      if (deviceId == me.deviceId) {
        continue;
      }
      final contact = _groupMemberContact(profiledGroup, deviceId);
      if (contact == null) {
        continue;
      }
      final envelope = await _crypto.encryptPayloadEnvelope(
        kind: 'group_membership',
        messageId: _randomId('grpctl'),
        conversationId: profiledGroup.groupId,
        senderAccountId: me.accountId,
        senderDeviceId: me.deviceId,
        recipientDeviceId: contact.deviceId,
        contact: contact,
        plaintext: payload,
      );
      // Enqueue BEFORE attempting delivery so a failure (or a crash mid-send)
      // doesn't lose the obligation. The retry loop drains this queue
      // independently. Inbound `group_membership_ack` clears the entry.
      _enqueuePendingMembershipDelivery(
        PendingGroupMembershipDelivery(
          groupId: profiledGroup.groupId,
          targetDeviceId: contact.deviceId,
          membershipVersion: profiledGroup.membershipVersion,
          originalMessageId: envelope.messageId,
          reason: reason,
          lastAttemptedAt: now,
          attempts: 1,
        ),
      );
      try {
        await _deliverToContact(
          contact: contact,
          recipientDeviceId: contact.deviceId,
          envelope: envelope,
        );
      } catch (_) {
        // Stays in the pending queue; the retry loop will pick it up.
      }
    }
    // Persist the freshly-enqueued pending deliveries so a crash before
    // the next debounce flush doesn't lose them.
    await _saveSnapshotSilently(notify: false);
  }

  /// Upserts a pending membership delivery into the persistent queue.
  /// `(groupId, targetDeviceId)` is the natural key — only one entry per
  /// recipient per group survives. Newer membership versions supersede
  /// older queued entries for the same target.
  void _enqueuePendingMembershipDelivery(PendingGroupMembershipDelivery entry) {
    final updated = <PendingGroupMembershipDelivery>[];
    var inserted = false;
    for (final existing in _snapshot.pendingGroupMembershipDeliveries) {
      final sameTarget =
          existing.groupId == entry.groupId &&
          existing.targetDeviceId == entry.targetDeviceId;
      if (!sameTarget) {
        updated.add(existing);
        continue;
      }
      if (entry.membershipVersion >= existing.membershipVersion) {
        updated.add(entry);
      } else {
        // Incoming entry is older than what's already queued — keep the
        // queued one. (Should not happen in practice because membership
        // versions only ever bump.)
        updated.add(existing);
      }
      inserted = true;
    }
    if (!inserted) {
      updated.add(entry);
    }
    _snapshot = _snapshot.copyWith(pendingGroupMembershipDeliveries: updated);
  }

  void _clearPendingMembershipDelivery({
    required String groupId,
    required String targetDeviceId,
    int? acknowledgedMembershipVersion,
  }) {
    final filtered = _snapshot.pendingGroupMembershipDeliveries
        .where((entry) {
          if (entry.groupId != groupId ||
              entry.targetDeviceId != targetDeviceId) {
            return true;
          }
          if (acknowledgedMembershipVersion != null &&
              entry.membershipVersion > acknowledgedMembershipVersion) {
            // The peer ack'd an older version; a newer one is still owed.
            return true;
          }
          return false;
        })
        .toList(growable: false);
    if (filtered.length == _snapshot.pendingGroupMembershipDeliveries.length) {
      return;
    }
    _snapshot = _snapshot.copyWith(pendingGroupMembershipDeliveries: filtered);
  }

  /// Walks the persistent queue and re-sends any membership envelope whose
  /// last attempt is older than the standard retry delay. Re-encrypts the
  /// **current** group snapshot under a fresh envelope each time so the
  /// recipient always converges on the latest state. Caps `attempts` to
  /// avoid burning relay quota on permanently unreachable peers.
  Future<void> _retryPendingMembershipDeliveries({bool force = false}) async {
    if (_snapshot.pendingGroupMembershipDeliveries.isEmpty) {
      return;
    }
    final me = _snapshot.identity;
    if (me == null) {
      return;
    }
    const maxAttempts = 50;
    final now = _now();
    // Snapshot first; the queue is rebuilt as we go.
    final pending = List<PendingGroupMembershipDelivery>.from(
      _snapshot.pendingGroupMembershipDeliveries,
    );
    for (final entry in pending) {
      if (entry.attempts >= maxAttempts) {
        continue;
      }
      if (!force) {
        final waited = now.difference(entry.lastAttemptedAt);
        final delay = entry.attempts <= 1
            ? _pendingMessageRetryDelay
            : _acceptedMessageRetryDelay;
        if (waited < delay) {
          continue;
        }
      }
      final group = _groupById(entry.groupId);
      if (group == null) {
        _clearPendingMembershipDelivery(
          groupId: entry.groupId,
          targetDeviceId: entry.targetDeviceId,
        );
        continue;
      }
      // If the recipient is no longer reachable as a group member (kicked
      // long ago and forgotten, etc.), drop the obligation.
      final contact = _groupMemberContact(group, entry.targetDeviceId);
      if (contact == null || contact.isArchived) {
        _clearPendingMembershipDelivery(
          groupId: entry.groupId,
          targetDeviceId: entry.targetDeviceId,
        );
        continue;
      }
      if (contact.pendingVerification) {
        // Hold; confirm-replacement will drain on key promotion.
        continue;
      }
      final profiledGroup = _refreshGroupMemberProfiles(group);
      final payload = jsonEncode({
        'version': 1,
        'reason': entry.reason,
        'group': profiledGroup.toJson(),
      });
      final envelope = await _crypto.encryptPayloadEnvelope(
        kind: 'group_membership',
        messageId: _randomId('grpctl'),
        conversationId: profiledGroup.groupId,
        senderAccountId: me.accountId,
        senderDeviceId: me.deviceId,
        recipientDeviceId: contact.deviceId,
        contact: contact,
        plaintext: payload,
      );
      _enqueuePendingMembershipDelivery(
        entry.copyWith(
          membershipVersion: profiledGroup.membershipVersion,
          originalMessageId: envelope.messageId,
          lastAttemptedAt: now,
          attempts: entry.attempts + 1,
        ),
      );
      try {
        await _deliverToContact(
          contact: contact,
          recipientDeviceId: contact.deviceId,
          envelope: envelope,
        );
      } catch (_) {
        // Stays queued; next pass will retry.
      }
    }
  }

  Future<void> _sendGroupMembershipAck(
    RelayEnvelope original, {
    required GroupRecord group,
    required ContactRecord sender,
  }) async {
    final me = _requireIdentity();
    final payload = jsonEncode({
      'version': 1,
      'groupId': group.groupId,
      'membershipVersion': group.membershipVersion,
      'acknowledgedMessageId': original.messageId,
    });
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'group_membership_ack',
      messageId: _randomId('grpctlack'),
      conversationId: group.groupId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: original.senderDeviceId,
      contact: sender,
      plaintext: payload,
      acknowledgedMessageId: original.messageId,
    );
    try {
      await _deliverToContact(
        contact: sender,
        recipientDeviceId: sender.deviceId,
        envelope: envelope,
      );
    } catch (_) {
      // Best-effort ack. If it's lost the sender retries the membership
      // update on its next cycle and we re-ack on receipt.
    }
  }

  Future<void> _handleGroupMembershipAck(RelayEnvelope envelope) async {
    final group = _groupById(envelope.conversationId);
    if (group == null) {
      return;
    }
    final sender =
        _groupMemberContact(group, envelope.senderDeviceId) ??
        _contactByDeviceId(envelope.senderDeviceId);
    if (sender == null) {
      return;
    }
    final decoded = await _crypto.decryptMessage(
      contact: sender,
      envelope: envelope,
    );
    final payload = jsonDecode(decoded);
    if (payload is! Map<String, dynamic>) {
      return;
    }
    final groupId = payload['groupId'] as String?;
    if (groupId == null || groupId != group.groupId) {
      return;
    }
    final acknowledgedVersion =
        (payload['membershipVersion'] as num?)?.toInt() ??
        group.membershipVersion;
    _clearPendingMembershipDelivery(
      groupId: group.groupId,
      targetDeviceId: envelope.senderDeviceId,
      acknowledgedMembershipVersion: acknowledgedVersion,
    );
    _reachability.noteAnySignal(
      envelope.senderDeviceId,
      at: envelope.createdAt,
    );
    await _persist('Group ${group.title} membership ack from ${sender.alias}.');
  }

  Future<void> _sendGroupLeave(GroupRecord group) async {
    final me = _requireIdentity();
    final profiledGroup = _refreshGroupMemberProfiles(group);
    final payload = jsonEncode({
      'version': 1,
      'groupId': profiledGroup.groupId,
      'membershipVersion': profiledGroup.membershipVersion,
      'leftDeviceId': me.deviceId,
    });
    final targets = profiledGroup.memberDeviceIds
        .where((deviceId) => deviceId != me.deviceId)
        .toSet();
    for (final deviceId in targets) {
      final contact = _groupMemberContact(profiledGroup, deviceId);
      if (contact == null) {
        continue;
      }
      final envelope = await _crypto.encryptPayloadEnvelope(
        kind: 'group_leave',
        messageId: _randomId('grpleave'),
        conversationId: profiledGroup.groupId,
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
      } catch (_) {
        // Leaving is best effort; future owner updates resolve membership.
      }
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
    // Skip the send entirely for non-sendable contacts. _sendRouteUpdate
    // historically bypassed _deliverToContact (which has the same
    // guard) when `routes` was explicit — that's the heartbeat path —
    // so route_updates were leaking out to pendingVerification /
    // archived peers, hitting the relay one-sided and wasting
    // bandwidth + confusing the UI ("we're still in touch" when in
    // fact the peer reset identity).
    if (!contact.canSendOutbound) {
      return false;
    }
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
        _reachability.noteHeartbeatAttempt(
          contact.deviceId,
          at: effectiveSentAt,
        );
      }
      return true;
    } catch (_) {
      if (effectiveProbeId != null) {
        _pendingRouteUpdateProbes.remove(
          _pendingRouteUpdateProbeKey(contact.deviceId, effectiveProbeId),
        );
      }
      if (reason == 'heartbeat' || reason == 'chat_resume') {
        _reachability.noteHeartbeatAttempt(
          contact.deviceId,
          at: effectiveSentAt,
        );
        _reachability.noteFailure(contact.deviceId);
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
      final record = _reachability.recordByDeviceId(contact.deviceId);
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
          if (check.available &&
              _routeHealthTracker.isEligibleNow(check.route)) {
            selectedRoute = check.route;
            break;
          }
        }
      }
      if (selectedRoute == null) {
        _reachability.noteFailure(contact.deviceId);
        changed = true;
        continue;
      }
      _reachability.noteAvailablePath(contact.deviceId);
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
          _routeHealthTracker.recordSuccess(
            route,
            fetch: true,
            latency: stopwatch.elapsed,
          );
          if (route.kind == PeerRouteKind.relay) {
            relaySuccess = true;
          }
          processed += await _processEnvelopes(envelopes);
          if (envelopes.isNotEmpty) {
            routeNotes.add('${route.kind.name}:${route.host}');
          }
        } catch (error) {
          _routeHealthTracker.recordFailure(route, error: error.toString());
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
    return !_routeHealthTracker.isEligibleNow(route);
  }

  /// Picks the highest-priority remote relay route for the long-poll
  /// loop. The local-relay loopback is deliberately excluded — the
  /// embedded relay's `onEnvelopeStored` callback already delivers LAN
  /// envelopes to `_handleLocalEnvelopeStored` synchronously, so long-
  /// polling 127.0.0.1 adds no latency benefit and creates a concurrent
  /// `_processEnvelopes` path that races with the callback (a primary
  /// trigger for the v0.3.2-nightly.2 notifier-batching bug). Among
  /// remote relays, the first eligible configured route wins; route
  /// health is re-checked every iteration so a flapping relay is
  /// dropped quickly.
  @visibleForTesting
  PeerEndpoint? pickPrimaryRelayForLongPollForTesting(IdentityRecord me) =>
      _pickPrimaryRelayForLongPoll(me);

  PeerEndpoint? _pickPrimaryRelayForLongPoll(IdentityRecord me) {
    for (final relay in me.configuredRelays) {
      if (relay.kind != PeerRouteKind.relay) {
        continue;
      }
      if (_routeHealthTracker.isEligibleNow(relay)) {
        return relay;
      }
    }
    return null;
  }

  Future<void> _startLongPollIfEnabled() async {
    if (!_longPollEnabled || _longPollRunning) {
      return;
    }
    if (_snapshot.identity?.connectivity.onlineEnabled == false) {
      return;
    }
    _longPollRunning = true;
    unawaited(_runLongPollLoop());
  }

  void _stopLongPoll() {
    _longPollRunning = false;
  }

  /// Persistent fetch loop that holds an open request against the primary
  /// relay with `wait_ms: 25s`. The relay wakes the request as soon as a
  /// new envelope arrives (per the v0.3.2 long-poll path in the Rust
  /// server), so delivery latency drops from the 5–30 s poll interval to
  /// the network round-trip plus the relay's [Condvar] wake (~50–300 ms
  /// in practice). Old relays that ignore `wait_ms` return immediately
  /// empty; the elapsed-time guard at the bottom of the loop keeps that
  /// case from busy-looping the CPU.
  Future<void> _runLongPollLoop() async {
    while (_longPollRunning && hasIdentity) {
      final me = identity;
      if (me == null) {
        break;
      }
      final route = _pickPrimaryRelayForLongPoll(me);
      if (route == null) {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }
      final stopwatch = Stopwatch()..start();
      List<RelayEnvelope> envelopes = const [];
      try {
        envelopes = await _relayClient.fetchEnvelopes(
          host: route.host,
          port: route.port,
          protocol: route.protocol,
          recipientDeviceId: me.deviceId,
          waitFor: const Duration(seconds: 25),
        );
        stopwatch.stop();
        _routeHealthTracker.recordSuccess(
          route,
          fetch: true,
          latency: stopwatch.elapsed,
        );
      } catch (error) {
        stopwatch.stop();
        _routeHealthTracker.recordFailure(route, error: error.toString());
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      if (envelopes.isNotEmpty) {
        await _processEnvelopes(envelopes);
        _markRuntimeActivity();
        notifyListeners();
      } else if (stopwatch.elapsed < const Duration(seconds: 1)) {
        // Relay returned empty almost instantly — either it doesn't speak
        // `wait_ms` (older build) or there's nothing in the mailbox. Sleep
        // so we don't busy-loop the request.
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  List<ChatMessage> messagesFor(String peerDeviceId) {
    final conversation = _conversationFor(peerDeviceId);
    return List<ChatMessage>.from(conversation.messages)
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
  }

  List<ChatMessage> messagesForGroup(String groupId) {
    final conversation = _groupConversation(groupId);
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

  ChatMessage? _groupMessageById(String groupId, String messageId) {
    for (final message in _groupConversation(groupId).messages) {
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

  ChatMessage? lastGroupMessageFor(String groupId) {
    final messages = messagesForGroup(groupId);
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

  bool isUnreadGroupMessage(String groupId, ChatMessage message) {
    return _isUnreadMessageInConversation(_groupConversation(groupId), message);
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
    unawaited(
      _platformBridge.dismissMessageNotification(
        conversationId: _crypto.conversationIdFor(peerDeviceId),
      ),
    );
  }

  Future<void> markGroupReadThroughMessage(
    String groupId,
    ChatMessage message,
  ) async {
    if (message.outbound) {
      return;
    }
    final group = _groupById(groupId);
    if (group == null) {
      return;
    }
    await _markConversationReadWhere(
      (conversation) =>
          conversation.kind == ConversationKind.group &&
          conversation.id == groupId,
      readThroughAt: message.createdAt,
      readThroughMessageId: message.id,
    );
    unawaited(
      _platformBridge.dismissMessageNotification(conversationId: groupId),
    );
    final contact = _groupMemberContact(group, message.senderDeviceId);
    if (contact == null) {
      return;
    }
    await _sendReadReceipt(
      contact: contact,
      conversationId: groupId,
      acknowledgedMessageId: message.id,
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
    if (!me.connectivity.lanEnabled) {
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
    if (_snapshot.identity?.connectivity.lanEnabled == false) {
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

  @override
  void notifyListeners() {
    if (_disposed) {
      return;
    }
    if (_notificationsDeferredDepth > 0) {
      _deferredNotificationPending = true;
      return;
    }
    super.notifyListeners();
  }

  Future<int> _processEnvelopes(List<RelayEnvelope> envelopes) async {
    _notificationsDeferredDepth++;
    var processed = 0;
    try {
      processed = await _processEnvelopesInternal(envelopes);
    } finally {
      _notificationsDeferredDepth--;
      if (_notificationsDeferredDepth == 0 && _deferredNotificationPending) {
        _deferredNotificationPending = false;
        super.notifyListeners();
      }
    }
    return processed;
  }

  Future<int> _processEnvelopesInternal(List<RelayEnvelope> envelopes) async {
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
      // Identity-reset guardrail: if the sender is a known contact in
      // `pendingVerification`, hold the raw envelope without decrypt /
      // dispatch — applies to every kind (ack, route_update, group_*,
      // message_*, etc.), not just direct text. The crypto layer already
      // can't process these (the contact has no active publicKeyBase64
      // while pending), but short-circuiting here keeps logs quiet and
      // ensures inbound state stays consistent with confirm/reject.
      final senderContact = _contactByDeviceId(envelope.senderDeviceId);
      if (senderContact != null && senderContact.pendingVerification) {
        _enqueueHeldEnvelope(senderContact.deviceId, envelope);
        _markSeen(envelope.messageId);
        continue;
      }
      processed++;
      if (envelope.kind == 'ack') {
        _reachability.noteTwoWaySuccess(envelope.senderDeviceId);
        if (_groupById(envelope.conversationId) != null) {
          _updateGroupRecipientState(
            envelope.conversationId,
            envelope.acknowledgedMessageId ?? '',
            envelope.senderDeviceId,
            _isReadReceiptAck(envelope)
                ? DeliveryState.read
                : DeliveryState.delivered,
          );
        } else {
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

      if (envelope.kind == 'group_membership') {
        await _handleGroupMembership(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'group_membership_ack') {
        await _handleGroupMembershipAck(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'group_leave') {
        await _handleGroupLeave(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'group_message') {
        await _handleGroupMessage(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'contact_remove') {
        await _handleContactRemoval(envelope);
        _markSeen(envelope.messageId);
        continue;
      }

      if (envelope.kind == 'attachment_offer' ||
          envelope.kind == 'attachment_chunk_request' ||
          envelope.kind == 'attachment_chunk' ||
          envelope.kind == 'attachment_complete' ||
          envelope.kind == 'attachment_cancel') {
        await _handleAttachmentEnvelope(envelope);
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
        // The peer thinks we're a contact but we don't think they are.
        // The likely cause is that our earlier contact_remove envelope
        // never reached them (relay down / both peers offline at
        // different times). Echo one contact_remove back so they can
        // catch up. Rate-limited to once per cooldown per sender.
        unawaited(
          _maybeSendOrphanContactRemoval(
            senderDeviceId: envelope.senderDeviceId,
          ),
        );
        continue;
      }

      final decodedMessage = await _crypto.decryptDirectMessage(
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
      _reachability.noteAnySignal(contact.deviceId, at: envelope.createdAt);
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
      case 'group_membership':
      case 'group_leave':
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

  /// Receiver-side dispatcher for the five v0.3.2 attachment envelope
  /// kinds. The sender peer is looked up from `senderDeviceId` to derive
  /// the pairwise key; decryption + JSON parse failures are surfaced as
  /// transient status messages rather than crashing the poll loop.
  Future<void> _handleAttachmentEnvelope(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null || contact.pendingVerification) {
      return;
    }
    Map<String, dynamic> payload;
    try {
      final plaintext = await _crypto.decryptMessage(
        contact: contact,
        envelope: envelope,
      );
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      payload = decoded;
    } catch (_) {
      return;
    }

    switch (envelope.kind) {
      case 'attachment_offer':
        await _handleAttachmentOffer(contact, envelope, payload);
        return;
      case 'attachment_chunk_request':
        await _handleAttachmentChunkRequest(contact, payload);
        return;
      case 'attachment_chunk':
        await _handleAttachmentChunk(contact, payload);
        return;
      case 'attachment_complete':
        _handleAttachmentComplete(contact, payload);
        return;
      case 'attachment_cancel':
        _handleAttachmentCancel(payload);
        return;
    }
  }

  Future<void> _handleAttachmentOffer(
    ContactRecord sender,
    RelayEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    final descriptorJson = payload['descriptor'];
    if (descriptorJson is! Map<String, dynamic>) {
      return;
    }
    final descriptor = AttachmentDescriptor.fromJson(descriptorJson);
    if (descriptor.sizeBytes > maxAttachmentSizeBytes ||
        descriptor.chunkHashes.isEmpty) {
      return;
    }
    final me = _requireIdentity();
    final message = ChatMessage(
      id: _randomId('msg'),
      conversationId: _crypto.conversationIdFor(sender.deviceId),
      senderDeviceId: sender.deviceId,
      recipientDeviceId: me.deviceId,
      body: (payload['caption'] as String?) ?? '',
      outbound: false,
      state: DeliveryState.pending,
      createdAt: envelope.createdAt,
      senderDisplayName: sender.alias,
      attachment: descriptor,
    );
    _upsertMessage(sender.deviceId, message);
    _inboundAttachments[descriptor.id] = _InboundAttachmentState(
      messageId: message.id,
      peerDeviceId: sender.deviceId,
      descriptor: descriptor,
    );
    notifyListeners();
    await _sendAttachmentChunkRequest(sender, descriptor.id, 0);
  }

  Future<void> _sendAttachmentChunkRequest(
    ContactRecord peer,
    String attachmentId,
    int index,
  ) async {
    final me = _requireIdentity();
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'attachment_chunk_request',
      messageId: _randomId('areq'),
      conversationId: _crypto.conversationIdFor(peer.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: peer.deviceId,
      contact: peer,
      plaintext: jsonEncode({'attachmentId': attachmentId, 'index': index}),
    );
    try {
      await _deliverToContact(
        contact: peer,
        recipientDeviceId: peer.deviceId,
        envelope: envelope,
      );
    } catch (_) {
      // Retry on next poll cycle; the receiver still has the inbound
      // state, so the request will be re-issued.
    }
  }

  Future<void> _handleAttachmentChunkRequest(
    ContactRecord requester,
    Map<String, dynamic> payload,
  ) async {
    final attachmentId = payload['attachmentId'] as String?;
    final index = payload['index'] as int?;
    if (attachmentId == null || index == null) {
      return;
    }
    final state = _outboundAttachments[attachmentId];
    if (state == null || state.peerDeviceId != requester.deviceId) {
      return;
    }
    if (index < 0 || index >= state.chunks.length) {
      return;
    }
    final chunkBytes = state.chunks[index];
    final hash = state.descriptor.chunkHashes[index].hashBase64;
    final chunk = AttachmentChunk(
      attachmentId: attachmentId,
      index: index,
      ciphertextBase64: base64Encode(chunkBytes),
      hashBase64: hash,
    );
    final me = _requireIdentity();
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'attachment_chunk',
      messageId: _randomId('achk'),
      conversationId: _crypto.conversationIdFor(requester.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: requester.deviceId,
      contact: requester,
      plaintext: jsonEncode(chunk.toJson()),
    );
    try {
      await _deliverToContact(
        contact: requester,
        recipientDeviceId: requester.deviceId,
        envelope: envelope,
      );
    } catch (_) {
      // Receiver will re-request the missing chunk.
    }
  }

  Future<void> _handleAttachmentChunk(
    ContactRecord sender,
    Map<String, dynamic> payload,
  ) async {
    final chunk = AttachmentChunk.fromJson(payload);
    final state = _inboundAttachments[chunk.attachmentId];
    if (state == null || state.peerDeviceId != sender.deviceId) {
      return;
    }
    if (chunk.index < 0 || chunk.index >= state.received.length) {
      return;
    }
    final bytes = Uint8List.fromList(base64Decode(chunk.ciphertextBase64));
    final digest = await Sha256().hash(bytes);
    final expectedHash = state.descriptor.chunkHashes[chunk.index].hashBase64;
    if (base64Encode(digest.bytes) != expectedHash) {
      // Hash mismatch — request the chunk once more. If it fails again we
      // cancel the transfer.
      await _sendAttachmentChunkRequest(
        sender,
        chunk.attachmentId,
        chunk.index,
      );
      return;
    }
    state.received[chunk.index] = bytes;
    if (state.isComplete) {
      final builder = BytesBuilder();
      for (final part in state.received) {
        builder.add(part!);
      }
      final assembled = builder.toBytes();
      _assembledAttachments[chunk.attachmentId] = assembled;
      // Persist so the receiver bubble survives an app restart instead
      // of regressing to "transferring" once _assembledAttachments goes
      // away with the controller.
      unawaited(_persistAttachmentBytes(chunk.attachmentId, assembled));
      _inboundAttachments.remove(chunk.attachmentId);
      _updateMessageState(
        sender.deviceId,
        state.messageId,
        DeliveryState.delivered,
      );
      await _sendAttachmentComplete(sender, chunk.attachmentId);
      notifyListeners();
    } else {
      await _sendAttachmentChunkRequest(
        sender,
        chunk.attachmentId,
        state.nextMissingIndex,
      );
    }
  }

  Future<void> _sendAttachmentComplete(
    ContactRecord peer,
    String attachmentId,
  ) async {
    final me = _requireIdentity();
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'attachment_complete',
      messageId: _randomId('adone'),
      conversationId: _crypto.conversationIdFor(peer.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: peer.deviceId,
      contact: peer,
      plaintext: jsonEncode({'attachmentId': attachmentId}),
    );
    try {
      await _deliverToContact(
        contact: peer,
        recipientDeviceId: peer.deviceId,
        envelope: envelope,
      );
    } catch (_) {
      // Best effort; the sender's local state is already correct.
    }
  }

  void _handleAttachmentComplete(
    ContactRecord sender,
    Map<String, dynamic> payload,
  ) {
    final attachmentId = payload['attachmentId'] as String?;
    if (attachmentId == null) {
      return;
    }
    final state = _outboundAttachments.remove(attachmentId);
    if (state == null) {
      return;
    }
    _updateMessageState(
      sender.deviceId,
      state.messageId,
      DeliveryState.delivered,
    );
    notifyListeners();
  }

  void _handleAttachmentCancel(Map<String, dynamic> payload) {
    final attachmentId = payload['attachmentId'] as String?;
    if (attachmentId == null) {
      return;
    }
    _outboundAttachments.remove(attachmentId);
    _inboundAttachments.remove(attachmentId);
    notifyListeners();
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
    _reachability.noteAnySignal(
      sender.deviceId,
      at: sentAt ?? envelope.createdAt,
    );
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
          _reachability.noteHeartbeatReply(
            sender.deviceId,
            at: envelope.createdAt,
          );
          _markRuntimeActivity();
        }
        _reachability.noteTwoWaySuccess(
          sender.deviceId,
          at: envelope.createdAt,
        );
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

  Future<void> _handleGroupMembership(RelayEnvelope envelope) async {
    final existingForEnvelope = _groupById(envelope.conversationId);
    final sender = existingForEnvelope == null
        ? _contactByDeviceId(envelope.senderDeviceId)
        : _groupMemberContact(existingForEnvelope, envelope.senderDeviceId) ??
              _contactByDeviceId(envelope.senderDeviceId);
    if (sender == null) {
      return;
    }
    final decoded = await _crypto.decryptMessage(
      contact: sender,
      envelope: envelope,
    );
    final payload = jsonDecode(decoded);
    if (payload is! Map<String, dynamic>) {
      return;
    }
    final groupPayload = payload['group'];
    if (groupPayload is! Map<String, dynamic>) {
      return;
    }
    final incoming = GroupRecord.fromJson(groupPayload);
    if (incoming.groupId != envelope.conversationId) {
      return;
    }
    final me = _snapshot.identity;
    if (me == null) {
      return;
    }
    if (!incoming.memberDeviceIds.contains(me.deviceId) &&
        !incoming.removedDeviceIds.contains(me.deviceId)) {
      return;
    }
    final existing = _groupById(incoming.groupId);
    if (existing == null) {
      final senderRole = incoming.roleFor(envelope.senderDeviceId);
      if (incoming.ownerDeviceId != envelope.senderDeviceId &&
          senderRole != GroupMemberRole.admin) {
        return;
      }
    } else {
      if (incoming.membershipVersion <= existing.membershipVersion) {
        return;
      }
      if (!_isAuthorizedGroupMembershipUpdate(
        existing: existing,
        incoming: incoming,
        senderDeviceId: envelope.senderDeviceId,
      )) {
        return;
      }
    }
    final enriched = _mergeIncomingGroupMemberProfiles(
      incoming,
      trustedProfiles: [_groupProfileForContact(sender)],
    );
    // localRemovedAt is local-only state. The wire payload never carries it,
    // so a routine inbound update would otherwise wipe a prior local removal.
    // Preserve the existing flag, unless the update re-adds the local user
    // as an active member — in that case let the group reappear in the UI.
    final preserved = existing?.localRemovedAt;
    final shouldClear =
        preserved != null && enriched.hasActiveMember(me.deviceId);
    final merged = preserved == null || shouldClear
        ? enriched.copyWith(clearLocalRemovedAt: true)
        : enriched.copyWith(localRemovedAt: preserved);
    _upsertGroup(merged);
    if (merged.localRemovedAt == null) {
      _ensureGroupConversation(merged);
    }
    _reachability.noteAnySignal(sender.deviceId, at: envelope.createdAt);
    await _persist('Updated group ${enriched.title}.');
    // Tell the sender we applied their version so they can drop the
    // pending-retry entry. Best-effort; the sender will retry on miss.
    await _sendGroupMembershipAck(envelope, group: merged, sender: sender);
  }

  Future<void> _handleGroupLeave(RelayEnvelope envelope) async {
    final existing = _groupById(envelope.conversationId);
    if (existing == null) {
      return;
    }
    final sender = _groupMemberContact(existing, envelope.senderDeviceId);
    final me = _snapshot.identity;
    if (sender == null || me == null) {
      return;
    }
    final decoded = await _crypto.decryptMessage(
      contact: sender,
      envelope: envelope,
    );
    final payload = jsonDecode(decoded);
    if (payload is! Map<String, dynamic>) {
      return;
    }
    final groupId = payload['groupId'] as String?;
    if (groupId == null || groupId.isEmpty || groupId != existing.groupId) {
      return;
    }
    if (!existing.activeMemberDeviceIds.contains(envelope.senderDeviceId)) {
      return;
    }
    final updated = existing.copyWith(
      adminDeviceIds: existing.adminDeviceIds
          .where((deviceId) => deviceId != envelope.senderDeviceId)
          .toList(growable: false),
      moderatorDeviceIds: existing.moderatorDeviceIds
          .where((deviceId) => deviceId != envelope.senderDeviceId)
          .toList(growable: false),
      memberDeviceIds: existing.memberDeviceIds
          .where((deviceId) => deviceId != envelope.senderDeviceId)
          .toList(growable: false),
      removedDeviceIds: [...existing.removedDeviceIds, envelope.senderDeviceId],
      membershipVersion: max(
        existing.membershipVersion + 1,
        payload['membershipVersion'] as int? ?? existing.membershipVersion + 1,
      ),
      updatedAt: envelope.createdAt,
    );
    _upsertGroup(updated);
    _reachability.noteAnySignal(sender.deviceId, at: envelope.createdAt);
    await _persist('${sender.alias} left ${updated.title}.');
    if (updated.ownerDeviceId == me.deviceId) {
      await _sendGroupMembershipUpdate(
        updated,
        targetDeviceIds: updated.activeMemberDeviceIds
            .where((deviceId) => deviceId != me.deviceId)
            .toList(growable: false),
        reason: 'member_left',
      );
    }
  }

  Future<void> _handleGroupMessage(RelayEnvelope envelope) async {
    final group = _groupById(envelope.conversationId);
    if (group == null ||
        !group.hasActiveMember(envelope.senderDeviceId) ||
        group.removedDeviceIds.contains(envelope.senderDeviceId)) {
      return;
    }
    final sender = _groupMemberContact(group, envelope.senderDeviceId);
    if (sender == null) {
      return;
    }
    final decoded = await _crypto.decryptMessage(
      contact: sender,
      envelope: envelope,
    );
    final payload = _crypto.decodeGroupMessagePayload(decoded);
    if (payload.groupId != group.groupId ||
        payload.membershipVersion < group.membershipVersion) {
      return;
    }
    final existingConversation = _groupConversation(group.groupId);
    final alreadyKnown = existingConversation.messages.any(
      (message) => message.id == envelope.messageId,
    );
    if (!alreadyKnown) {
      _upsertGroupMessage(
        group.groupId,
        ChatMessage(
          id: envelope.messageId,
          conversationId: group.groupId,
          senderDeviceId: envelope.senderDeviceId,
          recipientDeviceId: envelope.recipientDeviceId,
          body: payload.body,
          outbound: false,
          state: DeliveryState.delivered,
          createdAt: envelope.createdAt,
          senderDisplayName: payload.senderDisplayName ?? sender.alias,
          replyToMessageId: payload.replyToMessageId,
          replySnippet: payload.replySnippet,
          replySenderDeviceId: payload.replySenderDeviceId,
          replySenderDisplayName: payload.replySenderDisplayName,
        ),
      );
      _showInboundGroupNotification(
        group: group,
        sender: sender,
        body: payload.body,
      );
    }
    _reachability.noteAnySignal(sender.deviceId, at: envelope.createdAt);
    await _sendAck(contact: sender, envelope: envelope);
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
    _reachability.ensure(updated.deviceId);
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
    final decoded = await _crypto.decryptMessage(
      contact: contact,
      envelope: envelope,
    );
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
    final decoded = await _crypto.decryptMessage(
      contact: contact,
      envelope: envelope,
    );
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
    final recent = _recentInboundLinesForContact(contact, defaultBody: body);
    unawaited(
      _platformBridge.showMessageNotification(
        title: contact.alias,
        body: body,
        conversationId: _crypto.conversationIdFor(contact.deviceId),
        senderName: contact.alias,
        selfName: me.displayName,
        recentMessages: recent,
      ),
    );
  }

  void _showInboundGroupNotification({
    required GroupRecord group,
    required ContactRecord sender,
    required String body,
  }) {
    final me = identity;
    if (me == null || !me.notificationsEnabled) {
      return;
    }
    final recent = _recentInboundLinesForGroup(group);
    unawaited(
      _platformBridge.showMessageNotification(
        title: group.title,
        body: '${sender.alias}: $body',
        conversationId: group.groupId,
        senderName: sender.alias,
        selfName: me.displayName,
        recentMessages: recent,
      ),
    );
  }

  static const int _notificationRecentMessageCap = 5;

  @visibleForTesting
  List<({String sender, String body, int timestampMs})>
  recentInboundLinesForContactForTesting(
    ContactRecord contact, {
    String defaultBody = '',
  }) => _recentInboundLinesForContact(contact, defaultBody: defaultBody);

  List<({String sender, String body, int timestampMs})>
  _recentInboundLinesForContact(
    ContactRecord contact, {
    required String defaultBody,
  }) {
    final messages = messagesFor(
      contact.deviceId,
    ).where((m) => !m.outbound).toList(growable: false);
    final tail = messages.length > _notificationRecentMessageCap
        ? messages.sublist(messages.length - _notificationRecentMessageCap)
        : messages;
    if (tail.isEmpty) {
      return [
        (
          sender: contact.alias,
          body: defaultBody,
          timestampMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
      ];
    }
    return [
      for (final m in tail)
        (
          sender: contact.alias,
          body: m.body,
          timestampMs: m.createdAt.millisecondsSinceEpoch,
        ),
    ];
  }

  List<({String sender, String body, int timestampMs})>
  _recentInboundLinesForGroup(GroupRecord group) {
    final messages = messagesForGroup(
      group.groupId,
    ).where((m) => !m.outbound).toList(growable: false);
    final tail = messages.length > _notificationRecentMessageCap
        ? messages.sublist(messages.length - _notificationRecentMessageCap)
        : messages;
    return [
      for (final m in tail)
        (
          sender: _groupSenderAliasFor(group, m.senderDeviceId),
          body: m.body,
          timestampMs: m.createdAt.millisecondsSinceEpoch,
        ),
    ];
  }

  String _groupSenderAliasFor(GroupRecord group, String deviceId) {
    final contact = _contactByDeviceId(deviceId);
    if (contact != null) return contact.alias;
    if (deviceId == identity?.deviceId) {
      return identity?.displayName ?? 'You';
    }
    return deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;
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
    // Enqueue first so a crash mid-send doesn't lose the obligation; the
    // happy-path delivery clears the entry immediately. Retries are
    // independent of the original message-retry pass.
    _enqueuePendingAckDelivery(
      PendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: envelope.messageId,
        conversationId: envelope.conversationId,
        kind: PendingAckKind.delivered,
        lastAttemptedAt: _now(),
        attempts: 1,
      ),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: ack,
      );
      _clearPendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: envelope.messageId,
        kind: PendingAckKind.delivered,
      );
    } catch (_) {
      // Stays queued; the retry loop will pick it up.
    }
    await _saveSnapshotSilently(notify: false);
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
    _enqueuePendingAckDelivery(
      PendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: acknowledgedMessageId,
        conversationId: conversationId,
        kind: PendingAckKind.read,
        lastAttemptedAt: _now(),
        attempts: 1,
      ),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: receipt,
      );
      _clearPendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: acknowledgedMessageId,
        kind: PendingAckKind.read,
      );
      // A successful `read` ack implies `delivered` was effectively
      // received too — clear any stale `delivered` queue entry for the
      // same message so we don't pointlessly re-send it.
      _clearPendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: acknowledgedMessageId,
        kind: PendingAckKind.delivered,
      );
    } catch (_) {
      // Stays queued; the retry loop will pick it up.
    }
    await _saveSnapshotSilently(notify: false);
  }

  /// Persists a raw inbound envelope under quarantine for a contact that's
  /// still in `pendingVerification`. The user-facing confirm action drains
  /// these back into the inbound pipeline; reject discards them.
  void _enqueueHeldEnvelope(String senderDeviceId, RelayEnvelope envelope) {
    final encoded = jsonEncode(envelope.toJson());
    final existing =
        _snapshot.heldUnverifiedEnvelopes
            .where(
              (entry) =>
                  !(entry.senderDeviceId == senderDeviceId &&
                      entry.envelopeJson == encoded),
            )
            .toList(growable: true)
          ..add(
            HeldEnvelope(
              senderDeviceId: senderDeviceId,
              conversationId: envelope.conversationId,
              envelopeJson: encoded,
              receivedAt: DateTime.now().toUtc(),
            ),
          );
    _snapshot = _snapshot.copyWith(heldUnverifiedEnvelopes: existing);
    unawaited(_saveSnapshotSilently(notify: true));
  }

  void _enqueuePendingAckDelivery(PendingAckDelivery entry) {
    final filtered =
        _snapshot.pendingAckDeliveries
            .where(
              (existing) =>
                  !(existing.targetDeviceId == entry.targetDeviceId &&
                      existing.acknowledgedMessageId ==
                          entry.acknowledgedMessageId &&
                      existing.kind == entry.kind),
            )
            .toList(growable: true)
          ..add(entry);
    _snapshot = _snapshot.copyWith(pendingAckDeliveries: filtered);
  }

  void _clearPendingAckDelivery({
    required String targetDeviceId,
    required String acknowledgedMessageId,
    required PendingAckKind kind,
  }) {
    final filtered = _snapshot.pendingAckDeliveries
        .where(
          (entry) =>
              !(entry.targetDeviceId == targetDeviceId &&
                  entry.acknowledgedMessageId == acknowledgedMessageId &&
                  entry.kind == kind),
        )
        .toList(growable: false);
    if (filtered.length == _snapshot.pendingAckDeliveries.length) {
      return;
    }
    _snapshot = _snapshot.copyWith(pendingAckDeliveries: filtered);
  }

  /// Drains [VaultSnapshot.pendingAckDeliveries], re-sending each ack
  /// envelope whose last attempt is older than the standard backoff
  /// window. Successful re-delivery clears the entry; persistent failures
  /// bump `attempts` and stay queued up to a cap (after which the
  /// existing message-retry cascade will eventually re-trigger receipt
  /// generation on the receiver side).
  Future<void> _retryPendingAckDeliveries({bool force = false}) async {
    if (_snapshot.pendingAckDeliveries.isEmpty) {
      return;
    }
    final me = _snapshot.identity;
    if (me == null) {
      return;
    }
    const maxAttempts = 30;
    final now = _now();
    final pending = List<PendingAckDelivery>.from(
      _snapshot.pendingAckDeliveries,
    );
    for (final entry in pending) {
      if (entry.attempts >= maxAttempts) {
        continue;
      }
      if (!force) {
        final waited = now.difference(entry.lastAttemptedAt);
        final delay = entry.attempts <= 1
            ? _pendingMessageRetryDelay
            : _acceptedMessageRetryDelay;
        if (waited < delay) {
          continue;
        }
      }
      final contact = _contactByDeviceId(entry.targetDeviceId);
      if (contact == null || contact.isArchived) {
        // Successor exists or contact removed — drop the stale entry.
        _clearPendingAckDelivery(
          targetDeviceId: entry.targetDeviceId,
          acknowledgedMessageId: entry.acknowledgedMessageId,
          kind: entry.kind,
        );
        continue;
      }
      if (contact.pendingVerification) {
        // Hold the entry; confirm-replacement will drain it once the
        // unverified key is promoted and the crypto layer can encrypt.
        continue;
      }
      final envelope = RelayEnvelope(
        kind: 'ack',
        messageId: _randomId(
          entry.kind == PendingAckKind.read ? 'read' : 'ack',
        ),
        conversationId: entry.conversationId,
        senderAccountId: me.accountId,
        senderDeviceId: me.deviceId,
        recipientDeviceId: contact.deviceId,
        createdAt: DateTime.now().toUtc(),
        acknowledgedMessageId: entry.acknowledgedMessageId,
        payloadBase64: entry.kind == PendingAckKind.read
            ? base64Encode(utf8.encode(jsonEncode({'receipt': 'read'})))
            : null,
      );
      _enqueuePendingAckDelivery(
        entry.copyWith(lastAttemptedAt: now, attempts: entry.attempts + 1),
      );
      try {
        await _deliverToContact(
          contact: contact,
          recipientDeviceId: contact.deviceId,
          envelope: envelope,
        );
        _clearPendingAckDelivery(
          targetDeviceId: entry.targetDeviceId,
          acknowledgedMessageId: entry.acknowledgedMessageId,
          kind: entry.kind,
        );
      } catch (_) {
        // Stays queued.
      }
    }
    await _saveSnapshotSilently(notify: false);
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
        final record = _reachability.recordByDeviceId(deviceId);
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

  Future<DebugCheckResult> _runNotifierBatchFlushCheck() async {
    // Regression: a previous wasDeferred/restore implementation left the
    // notifier gate permanently closed when two _processEnvelopes calls
    // overlapped at an await boundary. Drive three parallel empty calls
    // and assert the depth counter returns to its baseline — i.e. the
    // parallel calls cleanly +1/-1 without leaking. A non-zero baseline
    // is legitimate when a long-poll-driven _processEnvelopes is in
    // flight at snapshot time.
    final beforeDepth = _notificationsDeferredDepth;
    await Future.wait([
      _processEnvelopes(const []),
      _processEnvelopes(const []),
      _processEnvelopes(const []),
    ]);
    final afterDepth = _notificationsDeferredDepth;
    if (afterDepth != beforeDepth) {
      return DebugCheckResult(
        name: 'Notifier batch flush',
        status: DebugCheckStatus.fail,
        detail:
            'Parallel _processEnvelopes calls leaked notifier depth '
            '(before=$beforeDepth, after=$afterDepth). UI updates may be '
            'silently dropped.',
      );
    }
    return DebugCheckResult(
      name: 'Notifier batch flush',
      status: DebugCheckStatus.pass,
      detail:
          'Parallel _processEnvelopes calls cleanly drained to the '
          'baseline depth ($beforeDepth); notify dispatch stays unblocked.',
    );
  }

  DebugCheckResult _runLocalLoopbackWiringCheck() {
    // Regression guard: the local relay's onEnvelopeStored callback is the
    // synchronous push path for LAN deliveries. If the wiring breaks, LAN
    // messages would only arrive via short-poll (5–15s lag).
    final running = _localRelayNode.isRunning;
    final callbackWired = _localRelayNode.onEnvelopeStored != null;
    if (!callbackWired) {
      return const DebugCheckResult(
        name: 'LAN local-loopback wiring',
        status: DebugCheckStatus.fail,
        detail:
            'LocalRelayNode.onEnvelopeStored is null — LAN envelopes will not '
            'push to _handleLocalEnvelopeStored.',
      );
    }
    if (!running) {
      return const DebugCheckResult(
        name: 'LAN local-loopback wiring',
        status: DebugCheckStatus.warn,
        detail:
            'Callback is wired but the local relay is not running yet. LAN '
            'push will activate once the relay starts.',
      );
    }
    return const DebugCheckResult(
      name: 'LAN local-loopback wiring',
      status: DebugCheckStatus.pass,
      detail:
          'Local relay is running and onEnvelopeStored is wired; LAN deliveries '
          'push synchronously via _handleLocalEnvelopeStored.',
    );
  }

  DebugCheckResult _runLongPollLifecycleCheck() {
    // Regression guard: the long-poll loop must be running while the app is
    // in the foreground (and the constructor enabled it) and stopped when
    // the app goes background. Asserts the current state matches the
    // expected one for this controller.
    if (!_longPollEnabled) {
      return const DebugCheckResult(
        name: 'Long-poll lifecycle',
        status: DebugCheckStatus.skip,
        detail:
            'Long-poll was disabled at construction (test fixture). Lifecycle '
            'check does not apply.',
      );
    }
    final expectedRunning = _appInForeground && hasIdentity;
    if (_longPollRunning != expectedRunning) {
      return DebugCheckResult(
        name: 'Long-poll lifecycle',
        status: DebugCheckStatus.fail,
        detail:
            'Long-poll loop state mismatch: running=$_longPollRunning, '
            'expected=$expectedRunning (foreground=$_appInForeground, '
            'hasIdentity=$hasIdentity). Foreground/background lifecycle '
            'wiring may be broken.',
      );
    }
    return DebugCheckResult(
      name: 'Long-poll lifecycle',
      status: DebugCheckStatus.pass,
      detail:
          'Long-poll loop running=$_longPollRunning matches expected for '
          'foreground=$_appInForeground, hasIdentity=$hasIdentity.',
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
    final knownRelayRoutes = _routeHealthTracker.healthMap.values
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
      final envelope = await _crypto.encryptDirectMessage(
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
      _reachability.noteAvailablePath(contact.deviceId);
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

  Future<bool> _tryDeliverExistingGroupMessage({
    required GroupRecord group,
    required ContactRecord contact,
    required ChatMessage message,
  }) async {
    if (_locallyDeletedMessageIds.contains(message.id) ||
        _groupMessageById(group.groupId, message.id) == null ||
        !group.hasActiveMember(contact.deviceId)) {
      return true;
    }
    _noteOutboundAttempt(contact.deviceId, message.id);
    try {
      final envelope = await _crypto.encryptGroupMessage(
        group: group,
        contact: contact,
        message: message,
      );
      final route = await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: envelope,
      );
      _reachability.noteAvailablePath(contact.deviceId);
      if (route.kind == PeerRouteKind.lan) {
        await _rememberLanRoutesForGroupMember(
          groupId: group.groupId,
          deviceId: contact.deviceId,
          routes: [route],
        );
      }
      final state = route.kind == PeerRouteKind.lan
          ? DeliveryState.local
          : DeliveryState.relayed;
      _updateGroupRecipientState(
        group.groupId,
        message.id,
        contact.deviceId,
        state,
      );
      _lastRelayStatus = route.kind == PeerRouteKind.lan
          ? 'group LAN delivery via ${route.host}:${route.port}'
          : 'group relay accepted via ${route.host}:${route.port}';
      await _saveSnapshotSilently(debounce: true);
      return true;
    } catch (error) {
      _lastRelayStatus = 'group delivery queued';
      _statusMessage = 'Group delivery retry pending: $error';
      notifyListeners();
      return false;
    }
  }

  Future<void> _retryUnacknowledgedMessages({bool force = false}) async {
    // Membership envelopes have their own queue (persisted in the vault)
    // — drain it before regular messages so a freshly-arriving peer sees
    // the latest group state before we try to send them chat lines.
    await _retryPendingMembershipDeliveries(force: force);
    // Pending acks and read receipts have their own persistent queue
    // too — drain them next so a peer who comes back online sees a fresh
    // batch of receipts for already-delivered messages.
    await _retryPendingAckDeliveries(force: force);
    for (final contact in contacts) {
      if (!contact.canSendOutbound) {
        // Pending verification or archived — skip silently. The crypto
        // layer would refuse anyway; this keeps the retry loop quiet.
        continue;
      }
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
    for (final group in groups) {
      final me = _snapshot.identity;
      if (me == null || !group.hasActiveMember(me.deviceId)) {
        continue;
      }
      final retryable = messagesForGroup(group.groupId)
          .where(
            (message) =>
                message.outbound &&
                message.recipientStates.values.any(
                  (state) => state.awaitsRecipientAck,
                ),
          )
          .toList();
      for (final message in retryable) {
        for (final entry in message.recipientStates.entries) {
          if (!entry.value.awaitsRecipientAck) {
            continue;
          }
          final contact = _groupMemberContact(group, entry.key);
          if (contact == null || !group.hasActiveMember(contact.deviceId)) {
            continue;
          }
          if (!contact.canSendOutbound) {
            // Pending verification or archived — skip silently.
            continue;
          }
          if (!force &&
              !_shouldRetryUnacknowledgedMessage(contact.deviceId, message)) {
            continue;
          }
          await _tryDeliverExistingGroupMessage(
            group: group,
            contact: contact,
            message: message,
          );
        }
      }
    }
  }

  Future<void> _replayAckForSeenEnvelope(RelayEnvelope envelope) async {
    if (envelope.kind != 'direct_message' && envelope.kind != 'group_message') {
      return;
    }
    final group = envelope.kind == 'group_message'
        ? _groupById(envelope.conversationId)
        : null;
    final contact = group == null
        ? _contactByDeviceId(envelope.senderDeviceId)
        : _groupMemberContact(group, envelope.senderDeviceId);
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
    // Defense in depth: the crypto layer already can't derive a shared
    // secret for a pending or archived contact (publicKeyBase64 is empty
    // / superseded), so any encrypt would fail with a base64 decode
    // error. Surface a useful message before the crypto throw, and keep
    // retry loops quiet by failing fast.
    if (contact.pendingVerification) {
      throw StateError(
        'Refusing to send to ${contact.alias}: identity is awaiting verification.',
      );
    }
    if (contact.isArchived) {
      throw StateError(
        'Refusing to send to ${contact.alias}: this contact has been replaced.',
      );
    }
    final effective = _effectiveTransports(contact);
    final candidateRoutes =
        dedupePeerEndpoints(_candidateRoutesForContact(contact))
            .where((route) => _routeAllowedByTransports(route, effective))
            .toList(growable: false);
    if (candidateRoutes.isEmpty) {
      throw StateError(
        'Connectivity is disabled for ${contact.alias} — no allowed routes.',
      );
    }
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
        .where(_routeHealthTracker.isEligibleNow)
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
          ..sort(_routeHealthTracker.compareHealth);
    final healthyDirectInternet =
        checks
            .where(
              (check) =>
                  check.available &&
                  check.route.kind == PeerRouteKind.directInternet,
            )
            .toList()
          ..sort(_routeHealthTracker.compareHealth);
    final unhealthyLan =
        checks
            .where(
              (check) =>
                  !check.available && check.route.kind == PeerRouteKind.lan,
            )
            .toList()
          ..sort(_routeHealthTracker.compareHealth);
    final unhealthyDirectInternet =
        checks
            .where(
              (check) =>
                  !check.available &&
                  check.route.kind == PeerRouteKind.directInternet,
            )
            .toList()
          ..sort(_routeHealthTracker.compareHealth);
    final healthyRelays =
        checks
            .where(
              (check) =>
                  check.available && check.route.kind == PeerRouteKind.relay,
            )
            .toList()
          ..sort(_routeHealthTracker.compareHealth);
    final unhealthyRelays =
        checks
            .where(
              (check) =>
                  !check.available && check.route.kind == PeerRouteKind.relay,
            )
            .toList()
          ..sort(_routeHealthTracker.compareHealth);

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

  /// Resolves per-contact + global connectivity into the actually-allowed
  /// transports for this delivery. The intersection makes the global flag a
  /// hard kill-switch — a per-contact toggle cannot re-enable a transport the
  /// global has disabled.
  ({bool lan, bool online, RoutingPreference preferred}) _effectiveTransports(
    ContactRecord contact,
  ) {
    final identity = _snapshot.identity;
    final global =
        identity?.connectivity ?? const GlobalConnectivityPreferences();
    final c = contact.routing;
    return (
      lan: global.lanEnabled && c.lanEnabled,
      online: global.onlineEnabled && c.onlineEnabled,
      preferred: c.preferred,
    );
  }

  bool _routeAllowedByTransports(
    PeerEndpoint route,
    ({bool lan, bool online, RoutingPreference preferred}) effective,
  ) {
    switch (route.kind) {
      case PeerRouteKind.lan:
        return effective.lan;
      case PeerRouteKind.relay:
      case PeerRouteKind.directInternet:
        return effective.online;
    }
  }

  List<PeerEndpoint> _preferredRoutesForContact(ContactRecord contact) {
    final effective = _effectiveTransports(contact);
    final candidateRoutes =
        dedupePeerEndpoints(_candidateRoutesForContact(contact))
            .where((route) => _routeAllowedByTransports(route, effective))
            .where(_routeHealthTracker.isEligibleNow)
            .toList(growable: false);
    final hasNonRelayCandidate = candidateRoutes.any(
      (route) => route.kind != PeerRouteKind.relay,
    );
    final recentSuccessRoutes =
        candidateRoutes
            .where(
              (route) =>
                  _routeHealthTracker.hasRecentRouteSuccess(route) &&
                  (!hasNonRelayCandidate || route.kind != PeerRouteKind.relay),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final leftAt = _routeHealthTracker.lastSuccessAt(left);
            final rightAt = _routeHealthTracker.lastSuccessAt(right);
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
          !_routeHealthTracker.hasRecentRouteSuccess(route) &&
          !_routeHealthTracker.hasFreshHealthyCache(route),
    );
    final cachedHealthyRoutes =
        candidateRoutes
            .where((route) {
              if (_routeHealthTracker.hasRecentRouteSuccess(route) ||
                  !_routeHealthTracker.hasFreshHealthyCache(route)) {
                return false;
              }
              if (hasUntestedNonRelay && route.kind == PeerRouteKind.relay) {
                return false;
              }
              return true;
            })
            .toList(growable: false)
          ..sort((left, right) {
            final kindCompare = _routeHealthTracker
                .kindDeliveryPriority(left)
                .compareTo(_routeHealthTracker.kindDeliveryPriority(right));
            if (kindCompare != 0) {
              return kindCompare;
            }
            final leftHealth = _routeHealthTracker.healthMap[left.routeKey];
            final rightHealth = _routeHealthTracker.healthMap[right.routeKey];
            return _routeHealthTracker.compareHealth(
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
    // Any eligible LAN route is unconditionally preferred, even when it
    // hasn't been exercised inside the recent-success window or the
    // fresh-cache TTL. LAN cost is zero, latency is sub-millisecond, and
    // the user expects messages to flow over LAN when both peers are on
    // the same network. The recent-success / cached-healthy gates above
    // only matter for choosing among non-LAN tiers (direct internet,
    // relay). Without this short-circuit, a >30s pause on LAN would
    // route the next message through relay even though the LAN path is
    // perfectly healthy.
    final eligibleLanRoutes = candidateRoutes
        .where((route) => route.kind == PeerRouteKind.lan)
        .toList(growable: false);
    final eligibleNonLanRoutes = candidateRoutes
        .where((route) => route.kind != PeerRouteKind.lan)
        .toList(growable: false);
    final preferred = <PeerEndpoint>[];
    final seenKeys = <String>{};
    // When the contact prefers online and both transports are allowed,
    // non-LAN routes come first — including not-yet-exercised ones, mirroring
    // the LAN-first short-circuit. Otherwise the default LAN-first order.
    final order =
        effective.lan &&
            effective.online &&
            effective.preferred == RoutingPreference.online
        ? <PeerEndpoint>[
            ...eligibleNonLanRoutes,
            ...eligibleLanRoutes,
            ...recentSuccessRoutes,
            ...cachedHealthyRoutes,
          ]
        : <PeerEndpoint>[
            ...eligibleLanRoutes,
            ...recentSuccessRoutes,
            ...cachedHealthyRoutes,
          ];
    for (final route in order) {
      if (seenKeys.add(route.routeKey)) {
        preferred.add(route);
      }
    }
    return preferred;
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
      final cachedRelayId =
          _routeHealthTracker.healthMap[route.routeKey]?.relayInstanceId;
      final expectedKey = cachedRelayId == null
          ? null
          : _snapshot.pinnedRelayIdentityKeys[cachedRelayId];
      final info = await _relayClient.inspectHealth(
        host: route.host,
        port: route.port,
        protocol: route.protocol,
        timeout: timeout,
        expectedIdentityPublicKeyBase64: expectedKey,
      );
      stopwatch.stop();
      if (!info.ok) {
        throw StateError('Route health check failed.');
      }
      // TOFU: if this relay_id has no pin yet and the response carried a
      // self-announced + signature-verified identity key, pin it. Mismatch
      // surfaces a banner; we never auto-rotate a pin.
      if (route.kind == PeerRouteKind.relay &&
          info.relayInstanceId != null &&
          info.identityPublicKeyBase64 != null) {
        final relayId = info.relayInstanceId!;
        final announced = info.identityPublicKeyBase64!;
        final existing = _snapshot.pinnedRelayIdentityKeys[relayId];
        if (existing == null) {
          if (info.signatureVerified) {
            final updated = Map<String, String>.from(
              _snapshot.pinnedRelayIdentityKeys,
            )..[relayId] = announced;
            _snapshot = _snapshot.copyWith(pinnedRelayIdentityKeys: updated);
          }
        } else if (info.pinnedKeyMismatch ||
            (info.signatureVerified == false && announced != existing)) {
          _announcedRelayIdentityKeys[relayId] = announced;
          _setTransientStatus(
            'Relay $relayId identity changed — verify with the operator.',
            notify: false,
          );
        } else if (announced == existing) {
          // Pinned key still matches; clear any stale "trust new key"
          // surface so the UI banner goes away.
          _announcedRelayIdentityKeys.remove(relayId);
        }
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
      _routeHealthTracker.healthMap[route.routeKey] = health;
      _routeHealthTracker.recordSuccess(
        route,
        latency: stopwatch.elapsed,
        relayInstanceId: health.relayInstanceId,
        at: health.checkedAt,
      );
      return health;
    } on RelayIdentityMismatchException catch (error) {
      _setTransientStatus(
        'Relay ${route.host}:${route.port} identity mismatch — verify with the operator.',
        notify: false,
      );
      _routeHealthTracker.recordFailure(route, error: error.toString());
      final health = _routeHealthTracker.healthMap[route.routeKey]!;
      return health;
    } catch (error) {
      _routeHealthTracker.recordFailure(route, error: error.toString());
      final health = _routeHealthTracker.healthMap[route.routeKey]!;
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
          _routeHealthTracker.recordSuccess(
            route,
            fetch: false,
            latency: stopwatch.elapsed,
          );
          return route;
        }
        _routeHealthTracker.recordFailure(
          route,
          error: 'Route did not accept store.',
        );
      } catch (error) {
        _routeHealthTracker.recordFailure(route, error: error.toString());
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
    return _withRelayScoringTieBreak(
      dedupePeerEndpoints([
        ...contact.prioritizedRouteHints,
        ..._lanRediscoveryRoutesForContact(contact),
      ]),
    );
  }

  /// Preserves the existing kind-based ordering (LAN → direct → relay) but
  /// re-sorts the relay tier by [RelayHealthScore] so a relay that has been
  /// consistently failing falls below a healthier sibling. Relays with fewer
  /// than 5 recorded attempts are treated as unknown (optimistic). Relays
  /// with recent successRate < 0.3 sink to the back of the relay tier.
  List<PeerEndpoint> _withRelayScoringTieBreak(List<PeerEndpoint> routes) {
    final nonRelay = <PeerEndpoint>[];
    final relay = <PeerEndpoint>[];
    for (final route in routes) {
      if (route.kind == PeerRouteKind.relay) {
        relay.add(route);
      } else {
        nonRelay.add(route);
      }
    }
    if (relay.length <= 1) {
      return routes;
    }
    bool isPoor(PeerEndpoint endpoint) {
      final score =
          _snapshot.relayHealthScores[relayHealthEndpointKey(endpoint)];
      return score != null &&
          score.recentAttempts >= 5 &&
          score.successRate < 0.3;
    }

    double rate(PeerEndpoint endpoint) {
      final score =
          _snapshot.relayHealthScores[relayHealthEndpointKey(endpoint)];
      if (score == null || score.recentAttempts == 0) {
        return 1.0; // optimistic for fresh endpoints
      }
      return score.successRate;
    }

    relay.sort((a, b) {
      final aPoor = isPoor(a);
      final bPoor = isPoor(b);
      if (aPoor != bPoor) {
        return aPoor ? 1 : -1;
      }
      return rate(b).compareTo(rate(a));
    });
    return [...nonRelay, ...relay];
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
      ..._routeHealthTracker.healthMap.values
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

  Future<void> _rememberLanRoutesForGroupMember({
    required String groupId,
    required String deviceId,
    required Iterable<PeerEndpoint> routes,
  }) async {
    final lanRoutes = dedupePeerEndpoints(
      routes.where((route) => route.kind == PeerRouteKind.lan),
    );
    if (lanRoutes.isEmpty) {
      return;
    }
    final groups = List<GroupRecord>.from(_snapshot.groups);
    final groupIndex = groups.indexWhere((group) => group.groupId == groupId);
    if (groupIndex == -1) {
      return;
    }
    final group = groups[groupIndex];
    final profile = group.memberProfileFor(deviceId);
    if (profile == null) {
      return;
    }
    final mergedRoutes = prunePeerEndpointsByKind([
      ...lanRoutes,
      ...profile.routeHints,
    ]);
    if (_sameRoutes(mergedRoutes, profile.routeHints)) {
      return;
    }
    final profiles = group.memberProfiles
        .map(
          (candidate) => candidate.deviceId == deviceId
              ? candidate.copyWith(routeHints: mergedRoutes)
              : candidate,
        )
        .toList(growable: false);
    groups[groupIndex] = group.copyWith(memberProfiles: profiles);
    _snapshot = _snapshot.copyWith(groups: groups);
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
      final state = _routeHealthTracker.runtimeMap[route.routeKey];
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
      ..._routeHealthTracker.healthMap.values.map((health) => health.route),
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
      final leftHealth = _routeHealthTracker.healthMap[left.routeKey];
      final rightHealth = _routeHealthTracker.healthMap[right.routeKey];
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
                  _routeHealthTracker.recordSuccess(route, fetch: false);
                } else {
                  _routeHealthTracker.recordFailure(
                    route,
                    error: 'Pairing announcement store was not accepted.',
                  );
                }
              })
              .catchError((error) {
                _routeHealthTracker.recordFailure(
                  route,
                  error: error.toString(),
                );
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
    for (final health in _routeHealthTracker.healthMap.values) {
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
    final groupProfile = _groupById(
      message.conversationId,
    )?.memberProfileFor(message.senderDeviceId);
    return contact?.alias ??
        contact?.displayName ??
        groupProfile?.displayName ??
        message.senderDisplayName ??
        message.senderDeviceId;
  }

  ConversationRecord _conversationFor(String peerDeviceId) {
    for (final conversation in _snapshot.conversations) {
      if (conversation.peerDeviceId == peerDeviceId) {
        return conversation;
      }
    }
    return ConversationRecord(
      id: _crypto.conversationIdFor(peerDeviceId),
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

  GroupRecord? _groupById(String groupId) {
    for (final group in _snapshot.groups) {
      if (group.groupId == groupId) {
        return group;
      }
    }
    return null;
  }

  GroupRecord _requireGroup(String groupId) {
    final group = _groupById(groupId);
    if (group == null) {
      throw ArgumentError('Group not found.');
    }
    return group;
  }

  ConversationRecord _groupConversation(String groupId) {
    for (final conversation in _snapshot.conversations) {
      if (conversation.kind == ConversationKind.group &&
          conversation.id == groupId) {
        return conversation;
      }
    }
    return ConversationRecord(
      id: groupId,
      kind: ConversationKind.group,
      peerDeviceId: groupId,
      messages: const [],
      lastReadAt: _now(),
    );
  }

  void _ensureGroupConversation(GroupRecord group) {
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    if (conversations.any(
      (conversation) =>
          conversation.kind == ConversationKind.group &&
          conversation.id == group.groupId,
    )) {
      return;
    }
    conversations.add(
      ConversationRecord(
        id: group.groupId,
        kind: ConversationKind.group,
        peerDeviceId: group.groupId,
        messages: const [],
        lastReadAt: _now(),
      ),
    );
    _snapshot = _snapshot.copyWith(conversations: conversations);
  }

  void _upsertGroup(GroupRecord group) {
    final groups = List<GroupRecord>.from(_snapshot.groups);
    final index = groups.indexWhere(
      (candidate) => candidate.groupId == group.groupId,
    );
    if (index == -1) {
      groups.add(group);
    } else {
      groups[index] = group;
    }
    _snapshot = _snapshot.copyWith(groups: groups);
  }

  List<ContactRecord> _dedupeContacts(List<ContactRecord> contacts) {
    final seen = <String>{};
    final result = <ContactRecord>[];
    for (final contact in contacts) {
      if (seen.add(contact.deviceId)) {
        result.add(contact);
      }
    }
    return result;
  }

  GroupMemberProfile _groupProfileForIdentity(IdentityRecord identity) {
    return GroupMemberProfile(
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      displayName: identity.displayName,
      bio: identity.bio,
      relayCapable: identity.relayModeEnabled,
      publicKeyBase64: identity.publicKeyBase64,
      routeHints: _inviteRouteHintsForIdentity(identity),
    );
  }

  GroupMemberProfile _groupProfileForContact(ContactRecord contact) {
    return GroupMemberProfile(
      accountId: contact.accountId,
      deviceId: contact.deviceId,
      displayName: contact.displayName,
      bio: contact.bio,
      relayCapable: contact.relayCapable,
      publicKeyBase64: contact.publicKeyBase64,
      routeHints: contact.routeHints,
    );
  }

  GroupRecord _refreshGroupMemberProfiles(
    GroupRecord group, {
    Iterable<ContactRecord> contacts = const <ContactRecord>[],
  }) {
    final knownIds = <String>{
      ...group.memberDeviceIds,
      ...group.removedDeviceIds,
      group.ownerDeviceId,
    };
    final profilesByDeviceId = <String, GroupMemberProfile>{
      for (final profile in group.memberProfiles)
        if (knownIds.contains(profile.deviceId)) profile.deviceId: profile,
    };
    final me = _snapshot.identity;
    if (me != null && knownIds.contains(me.deviceId)) {
      profilesByDeviceId[me.deviceId] = _groupProfileForIdentity(me);
    }
    for (final contact in [..._snapshot.contacts, ...contacts]) {
      if (knownIds.contains(contact.deviceId)) {
        profilesByDeviceId[contact.deviceId] = _groupProfileForContact(contact);
      }
    }
    final orderedIds = <String>[
      ...group.memberDeviceIds,
      ...group.removedDeviceIds,
      group.ownerDeviceId,
    ];
    final seen = <String>{};
    final profiles = <GroupMemberProfile>[];
    for (final deviceId in orderedIds) {
      if (!seen.add(deviceId)) {
        continue;
      }
      final profile = profilesByDeviceId[deviceId];
      if (profile != null) {
        profiles.add(profile);
      }
    }
    return group.copyWith(memberProfiles: profiles);
  }

  GroupRecord _mergeIncomingGroupMemberProfiles(
    GroupRecord incoming, {
    Iterable<GroupMemberProfile> trustedProfiles = const <GroupMemberProfile>[],
  }) {
    final existing = _groupById(incoming.groupId);
    final profilesByDeviceId = <String, GroupMemberProfile>{
      for (final profile
          in existing?.memberProfiles ?? const <GroupMemberProfile>[])
        profile.deviceId: profile,
      for (final profile in incoming.memberProfiles) profile.deviceId: profile,
      for (final profile in trustedProfiles) profile.deviceId: profile,
    };
    final me = _snapshot.identity;
    if (me != null &&
        (incoming.memberDeviceIds.contains(me.deviceId) ||
            incoming.removedDeviceIds.contains(me.deviceId))) {
      profilesByDeviceId[me.deviceId] = _groupProfileForIdentity(me);
    }
    for (final contact in _snapshot.contacts) {
      if (incoming.memberDeviceIds.contains(contact.deviceId) ||
          incoming.removedDeviceIds.contains(contact.deviceId)) {
        profilesByDeviceId[contact.deviceId] = _groupProfileForContact(contact);
      }
    }
    final orderedIds = <String>[
      ...incoming.memberDeviceIds,
      ...incoming.removedDeviceIds,
      incoming.ownerDeviceId,
    ];
    final seen = <String>{};
    final profiles = <GroupMemberProfile>[];
    for (final deviceId in orderedIds) {
      if (!seen.add(deviceId)) {
        continue;
      }
      final profile = profilesByDeviceId[deviceId];
      if (profile != null) {
        profiles.add(profile);
      }
    }
    return incoming.copyWith(memberProfiles: profiles);
  }

  bool _sameGroupMemberProfiles(GroupRecord left, GroupRecord right) {
    final leftEncoded = left.memberProfiles.map((profile) {
      final routeKeys =
          profile.routeHints.map((route) => route.routeKey).toList()..sort();
      return [
        profile.deviceId,
        profile.displayName,
        profile.bio,
        profile.relayCapable.toString(),
        profile.publicKeyBase64,
        routeKeys.join(','),
      ].join('|');
    }).toList()..sort();
    final rightEncoded = right.memberProfiles.map((profile) {
      final routeKeys =
          profile.routeHints.map((route) => route.routeKey).toList()..sort();
      return [
        profile.deviceId,
        profile.displayName,
        profile.bio,
        profile.relayCapable.toString(),
        profile.publicKeyBase64,
        routeKeys.join(','),
      ].join('|');
    }).toList()..sort();
    if (leftEncoded.length != rightEncoded.length) {
      return false;
    }
    for (var index = 0; index < leftEncoded.length; index++) {
      if (leftEncoded[index] != rightEncoded[index]) {
        return false;
      }
    }
    return true;
  }

  bool _isAuthorizedGroupMembershipUpdate({
    required GroupRecord existing,
    required GroupRecord incoming,
    required String senderDeviceId,
  }) {
    if (incoming.ownerDeviceId != existing.ownerDeviceId) {
      // Only the current owner can hand off the gavel, and only to a
      // device that was already an active member of the group. Anything
      // else (an admin trying to claim ownership, a stranger asserting
      // a new owner) is rejected.
      if (senderDeviceId != existing.ownerDeviceId) {
        return false;
      }
      if (!existing.activeMemberDeviceIds.contains(incoming.ownerDeviceId)) {
        return false;
      }
      return true;
    }
    if (senderDeviceId == existing.ownerDeviceId) {
      return true;
    }
    if (existing.roleFor(senderDeviceId) != GroupMemberRole.admin) {
      return false;
    }
    if (incoming.title != existing.title) {
      return false;
    }

    final existingActive = existing.activeMemberDeviceIds.toSet();
    final incomingActive = incoming.activeMemberDeviceIds.toSet();
    final added = incomingActive.difference(existingActive);
    final removed = existingActive.difference(incomingActive);
    for (final removedDeviceId in removed) {
      final removedRole = existing.roleFor(removedDeviceId);
      if (removedRole == GroupMemberRole.owner ||
          removedRole == GroupMemberRole.admin) {
        return false;
      }
    }
    for (final addedDeviceId in added) {
      if (incoming.roleFor(addedDeviceId) != GroupMemberRole.member) {
        return false;
      }
    }

    final expectedAdmins = existing.adminDeviceIds
        .where(incomingActive.contains)
        .toSet();
    if (!_sameIdSet(incoming.adminDeviceIds, expectedAdmins)) {
      return false;
    }
    final expectedModerators = existing.moderatorDeviceIds
        .where(incomingActive.contains)
        .toSet();
    if (!_sameIdSet(incoming.moderatorDeviceIds, expectedModerators)) {
      return false;
    }
    return true;
  }

  bool _sameIdSet(Iterable<String> left, Iterable<String> right) {
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    if (leftSet.length != rightSet.length) {
      return false;
    }
    return leftSet.containsAll(rightSet);
  }

  ContactRecord? _groupMemberContact(GroupRecord group, String deviceId) {
    final contact = _contactByDeviceId(deviceId);
    if (contact != null) {
      return contact;
    }
    final profile = group.memberProfileFor(deviceId);
    if (profile == null) {
      return null;
    }
    return ContactRecord(
      accountId: profile.accountId,
      deviceId: profile.deviceId,
      alias: profile.displayName,
      displayName: profile.displayName,
      bio: profile.bio,
      relayCapable: profile.relayCapable,
      publicKeyBase64: profile.publicKeyBase64,
      routeHints: profile.routeHints,
      safetyNumber: 'group-${_shortId(profile.publicKeyBase64)}',
      trustedAt: group.createdAt,
    );
  }

  List<ContactRecord> _groupRecipientContacts(GroupRecord group) {
    final me = _snapshot.identity;
    if (me == null) {
      return const <ContactRecord>[];
    }
    return group.activeMemberDeviceIds
        .where((deviceId) => deviceId != me.deviceId)
        .map((deviceId) => _groupMemberContact(group, deviceId))
        .whereType<ContactRecord>()
        .toList(growable: false);
  }

  String groupMemberLabel(String deviceId) {
    final me = _snapshot.identity;
    if (me != null && deviceId == me.deviceId) {
      return 'You';
    }
    final contact = _contactByDeviceId(deviceId);
    GroupMemberProfile? profile;
    for (final group in _snapshot.groups) {
      profile = group.memberProfileFor(deviceId);
      if (profile != null) {
        break;
      }
    }
    return contact?.alias ??
        contact?.displayName ??
        profile?.displayName ??
        'Unknown ${_shortId(deviceId)}';
  }

  String _shortId(String value) {
    if (value.length <= 8) {
      return value;
    }
    return value.substring(value.length - 8);
  }

  String groupDeliverySummary(ChatMessage message) {
    if (message.recipientStates.isEmpty) {
      return message.state.label;
    }
    var read = 0;
    var delivered = 0;
    var accepted = 0;
    var pending = 0;
    for (final state in message.recipientStates.values) {
      switch (state) {
        case DeliveryState.read:
          read++;
          delivered++;
          accepted++;
        case DeliveryState.delivered:
          delivered++;
          accepted++;
        case DeliveryState.local:
        case DeliveryState.relayed:
          accepted++;
        case DeliveryState.pending:
          pending++;
        case DeliveryState.canceled:
        case DeliveryState.failed:
          pending++;
      }
    }
    final total = message.recipientStates.length;
    if (read == total) {
      return 'Read by all $total';
    }
    if (delivered == total) {
      return 'Delivered to all $total';
    }
    if (accepted > 0 && pending > 0) {
      return 'Accepted by $accepted of $total';
    }
    if (accepted > 0) {
      return 'Accepted by $accepted of $total';
    }
    return 'Waiting for $total member(s)';
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
          id: _crypto.conversationIdFor(peerDeviceId),
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

  void _upsertGroupMessage(String groupId, ChatMessage message) {
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final index = conversations.indexWhere(
      (conversation) =>
          conversation.kind == ConversationKind.group &&
          conversation.id == groupId,
    );
    if (index == -1) {
      conversations.add(
        ConversationRecord(
          id: groupId,
          kind: ConversationKind.group,
          peerDeviceId: groupId,
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

  void _updateGroupRecipientState(
    String groupId,
    String messageId,
    String recipientDeviceId,
    DeliveryState state,
  ) {
    if (messageId.isEmpty || recipientDeviceId.isEmpty) {
      return;
    }
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final conversationIndex = conversations.indexWhere(
      (conversation) =>
          conversation.kind == ConversationKind.group &&
          conversation.id == groupId,
    );
    if (conversationIndex == -1) {
      return;
    }
    final updatedMessages = conversations[conversationIndex].messages.map((
      message,
    ) {
      if (message.id != messageId || !message.outbound) {
        return message;
      }
      final states = Map<String, DeliveryState>.from(message.recipientStates);
      final current = states[recipientDeviceId];
      if (current == null) {
        return message;
      }
      if (current == DeliveryState.read) {
        return message;
      }
      if (current == DeliveryState.delivered &&
          state != DeliveryState.delivered &&
          state != DeliveryState.read) {
        return message;
      }
      states[recipientDeviceId] = state;
      if (!state.awaitsRecipientAck) {
        _clearOutboundAttempt(recipientDeviceId, messageId);
      }
      return message.copyWith(
        state: _aggregateGroupDeliveryState(states),
        recipientStates: states,
      );
    }).toList();
    conversations[conversationIndex] = conversations[conversationIndex]
        .copyWith(messages: updatedMessages);
    _snapshot = _snapshot.copyWith(conversations: conversations);
  }

  DeliveryState _aggregateGroupDeliveryState(
    Map<String, DeliveryState> recipientStates,
  ) {
    if (recipientStates.isEmpty) {
      return DeliveryState.delivered;
    }
    final states = recipientStates.values.toList(growable: false);
    if (states.every((state) => state == DeliveryState.read)) {
      return DeliveryState.read;
    }
    if (states.every(
      (state) =>
          state == DeliveryState.delivered || state == DeliveryState.read,
    )) {
      return DeliveryState.delivered;
    }
    if (states.any((state) => state == DeliveryState.pending)) {
      return DeliveryState.pending;
    }
    if (states.any((state) => state == DeliveryState.relayed)) {
      return DeliveryState.relayed;
    }
    if (states.any((state) => state == DeliveryState.local)) {
      return DeliveryState.local;
    }
    return DeliveryState.pending;
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
      (_, probe) => now.difference(probe.sentAt) > kKnownReachabilityWindow,
    );
  }

  IdentityRecord _requireIdentity() {
    final me = _snapshot.identity;
    if (me == null) {
      throw StateError('Create a device identity first.');
    }
    return me;
  }

  String _randomId(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(10, (_) => random.nextInt(256));
    final suffix = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$prefix-$suffix';
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
          _routeHealthTracker.recordSuccess(
            route,
            fetch: true,
            latency: stopwatch.elapsed,
          );
          processed += await _processEnvelopes(envelopes);
        } catch (error) {
          _routeHealthTracker.recordFailure(route, error: error.toString());
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
    _disposed = true;
    _stopLongPoll();
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

class _OutboundAttachmentState {
  _OutboundAttachmentState({
    required this.messageId,
    required this.peerDeviceId,
    required this.chunks,
    required this.descriptor,
  });

  final String messageId;
  final String peerDeviceId;
  final List<Uint8List> chunks;
  final AttachmentDescriptor descriptor;
}

class _InboundAttachmentState {
  _InboundAttachmentState({
    required this.messageId,
    required this.peerDeviceId,
    required this.descriptor,
  }) : received = List<Uint8List?>.filled(descriptor.chunkHashes.length, null);

  final String messageId;
  final String peerDeviceId;
  final AttachmentDescriptor descriptor;
  final List<Uint8List?> received;

  int get nextMissingIndex {
    for (var i = 0; i < received.length; i++) {
      if (received[i] == null) {
        return i;
      }
    }
    return -1;
  }

  bool get isComplete => received.every((chunk) => chunk != null);
}

enum _RuntimeMode {
  foregroundActive,
  foregroundIdle,
  backgroundEnabled,
  backgroundDisabledAndroid,
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

typedef _RelayAttemptCallback =
    void Function({
      required String host,
      required int port,
      required PeerRouteProtocol protocol,
      required bool success,
      Duration? latency,
      required DateTime at,
    });

/// Wraps a [RelayClient] and records the outcome of every call so the
/// controller can maintain a [RelayHealthScore] per endpoint without
/// touching the eight individual call sites.
class _ScoringRelayClient implements RelayClient {
  _ScoringRelayClient({
    required this.inner,
    required this.onAttempt,
    required this.nowProvider,
  });

  final RelayClient inner;
  final _RelayAttemptCallback onAttempt;
  final DateTime Function() nowProvider;

  Future<T> _track<T>({
    required String host,
    required int port,
    required PeerRouteProtocol protocol,
    required Future<T> Function() action,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await action();
      stopwatch.stop();
      onAttempt(
        host: host,
        port: port,
        protocol: protocol,
        success: true,
        latency: stopwatch.elapsed,
        at: nowProvider(),
      );
      return result;
    } catch (_) {
      stopwatch.stop();
      onAttempt(
        host: host,
        port: port,
        protocol: protocol,
        success: false,
        latency: null,
        at: nowProvider(),
      );
      rethrow;
    }
  }

  @override
  Future<Duration> probe({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) {
    return _track(
      host: host,
      port: port,
      protocol: protocol,
      action: () => inner.probe(
        host: host,
        port: port,
        protocol: protocol,
        timeout: timeout,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      ),
    );
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
  }) {
    return _track(
      host: host,
      port: port,
      protocol: protocol,
      action: () => inner.storeEnvelope(
        host: host,
        port: port,
        protocol: protocol,
        recipientDeviceId: recipientDeviceId,
        envelope: envelope,
        timeout: timeout,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      ),
    );
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
  }) {
    return _track(
      host: host,
      port: port,
      protocol: protocol,
      action: () => inner.fetchEnvelopes(
        host: host,
        port: port,
        protocol: protocol,
        recipientDeviceId: recipientDeviceId,
        limit: limit,
        timeout: timeout,
        waitFor: waitFor,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      ),
    );
  }

  @override
  Future<bool> health({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) {
    return _track(
      host: host,
      port: port,
      protocol: protocol,
      action: () => inner.health(
        host: host,
        port: port,
        protocol: protocol,
        timeout: timeout,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      ),
    );
  }

  @override
  Future<RelayHealthInfo> inspectHealth({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) {
    return _track(
      host: host,
      port: port,
      protocol: protocol,
      action: () => inner.inspectHealth(
        host: host,
        port: port,
        protocol: protocol,
        timeout: timeout,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      ),
    );
  }
}
