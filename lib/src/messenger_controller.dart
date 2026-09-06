import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;

import 'crypto_service.dart';
import 'beam_protocol.dart';
import 'attachment_safety.dart';
import 'iroh_transport.dart';
import 'lan_direct.dart';
import 'local_relay_node.dart';
import 'models.dart';
import 'native_attachment_crypto.dart';
import 'platform_bridge.dart';
import 'reachability_tracker.dart';
import 'staged_attachment.dart';

export 'staged_attachment.dart' show StagedAttachment;
export 'beam_protocol.dart'
    show
        BeamDecodeProgress,
        BeamDecoder,
        BeamEncoder,
        BeamFrame,
        BeamImportResult,
        BeamManifest,
        BeamMode,
        BeamPackage,
        PreparedBeamTransfer,
        conestBeamMaximumPayloadBytes;
import 'relay_client.dart';
import 'relay_defaults.dart';
import 'route_health_tracker.dart';
import 'storage.dart';
import 'storage_capacity.dart';
import 'transport.dart';

const bool experimentalAndroidBackgroundRuntimeAvailable = bool.fromEnvironment(
  'CONEST_EXPERIMENTAL_ANDROID_BACKGROUND_RUNTIME',
  defaultValue: false,
);

/// Fallback attachment cache root used when the constructor caller
/// doesn't supply one (i.e. production where the bootstrap profile
/// chose a non-portable data root). Mirrors what `app_storage.dart`
/// would have picked for the device profile.
Future<Directory> _defaultAttachmentRootProvider() async {
  final root = await path_provider.getApplicationSupportDirectory();
  return Directory(p.join(root.path, 'attachments'));
}

class _SingleDigestSink implements Sink<dart_crypto.Digest> {
  dart_crypto.Digest? value;

  @override
  void add(dart_crypto.Digest data) {
    value = data;
  }

  @override
  void close() {}
}

const int _maxInviteRouteHints = 8;
const int _maxInviteLanHosts = 1;

List<int> _attachmentChunkAssociatedData(
  AttachmentDescriptor descriptor,
  int index,
  int plaintextLength,
) => utf8.encode(
  jsonEncode(<String, Object>{
    'version': 2,
    'attachmentId': descriptor.id,
    'fileHashBase64': descriptor.fileHashBase64,
    'sizeBytes': descriptor.sizeBytes,
    'blockSize': descriptor.chunkSize,
    'index': index,
    'plaintextLength': plaintextLength,
  }),
);

List<int> _attachmentBlockNonce(AttachmentDescriptor descriptor, int index) {
  final prefix = base64Decode(descriptor.noncePrefixBase64);
  if (prefix.length != 16 || index < 0) {
    throw const FormatException('Attachment v2 nonce geometry is invalid.');
  }
  final nonce = Uint8List(24)..setRange(0, 16, prefix);
  ByteData.sublistView(nonce).setUint64(16, index, Endian.big);
  return nonce;
}

bool _attachmentBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

String? _irohSocketAddressForRoute(PeerEndpoint route) {
  final address = InternetAddress.tryParse(route.host);
  if (address == null || !isValidPeerEndpointPort(route.port)) return null;
  return address.type == InternetAddressType.IPv6
      ? '[${address.address}]:${route.port}'
      : '${address.address}:${route.port}';
}

({String host, int port})? _parseIrohSocketAddress(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  final String host;
  final String portText;
  if (normalized.startsWith('[')) {
    final bracket = normalized.indexOf(']');
    if (bracket <= 1 ||
        bracket + 2 > normalized.length ||
        normalized[bracket + 1] != ':') {
      return null;
    }
    host = normalized.substring(1, bracket);
    portText = normalized.substring(bracket + 2);
  } else {
    final colon = normalized.lastIndexOf(':');
    if (colon <= 0 || colon == normalized.length - 1) return null;
    host = normalized.substring(0, colon);
    portText = normalized.substring(colon + 1);
  }
  final port = int.tryParse(portText);
  final address = InternetAddress.tryParse(host);
  if (address == null || port == null || !isValidPeerEndpointPort(port)) {
    return null;
  }
  return (host: address.address, port: port);
}

int _verifiedBytesFor(
  AttachmentDescriptor descriptor,
  Iterable<int> completedBlocks,
) {
  var total = 0;
  for (final index in completedBlocks) {
    if (index < 0 || index >= descriptor.effectiveChunkCount) continue;
    final offset = index * descriptor.chunkSize;
    total += min(descriptor.chunkSize, descriptor.sizeBytes - offset);
  }
  return total.clamp(0, descriptor.sizeBytes);
}

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

/// Cadence used while at least one attachment transfer is in flight. The
/// idle 15 s cadence killed file transfers that fell back to relay polling
/// (each chunk RTT stretched into 15 s of wait). nightly.10 drops this
/// from 1 s → 250 ms so a relay-only 10 MB transfer doesn't pay a full
/// second of wait between every chunk wave. The relay's wake-on-store
/// Condvar means most polls are no-ops; this just shortens the worst
/// case when wake-up misses.
const Duration _activeTransferPollInterval = Duration(milliseconds: 250);
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
const int _maxEncryptedEnvelopeCiphertextBytes = 2 * 1024 * 1024;
const int _maxAttachmentChunkCiphertextBase64Bytes = 2 * 1024 * 1024;
const int _maxBootstrapPayloadBytes = 32 * 1024;
const int _maxLanLobbyPayloadBytes = 96 * 1024;
const int _maxPendingContactRequests = 20;
const Duration _pendingContactRequestTtl = Duration(days: 7);

const Set<String> _v2PairwiseKinds = <String>{
  'direct_message',
  'ack',
  'contact_exchange',
  'contact_remove',
  'route_update',
  'group_membership',
  'group_membership_ack',
  'group_leave',
  'group_message',
  'attachment_offer',
  'attachment_chunk_request',
  'attachment_chunk',
  'attachment_complete',
  'attachment_cancel',
  'attachment_pause_control',
  'attachment_progress',
  'message_edit',
  'message_delete',
  'debug_probe',
  'debug_probe_ack',
  'debug_two_way_message',
  'debug_two_way_reply',
  'debug_file_test_probe',
  'debug_file_test_probe_ack',
  'debug_file_test_result',
};

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

class AttachmentSpoolException implements Exception {
  AttachmentSpoolException(this.message, {this.canUseOriginal = false});

  final String message;
  final bool canUseOriginal;

  @override
  String toString() => message;
}

enum DefaultRelaysRefreshStatus { upToDate, updated, error }

class DebugFileTestResult {
  const DebugFileTestResult({
    required this.testId,
    required this.attachmentId,
    required this.peerDeviceId,
    required this.sizeMiB,
    required this.success,
    required this.startedAt,
    required this.completedAt,
    this.bytesVerified = 0,
    this.sha256Base64,
    this.detail,
  });

  final String testId;
  final String attachmentId;
  final String peerDeviceId;
  final int sizeMiB;
  final bool success;
  final DateTime startedAt;
  final DateTime completedAt;
  final int bytesVerified;
  final String? sha256Base64;
  final String? detail;

  Duration get elapsed => completedAt.difference(startedAt);

  double? get mebibytesPerSecond => elapsed.inMilliseconds <= 0
      ? null
      : (bytesVerified / (1024 * 1024)) / (elapsed.inMilliseconds / 1000);
}

class DebugAttachmentTestSpec {
  const DebugAttachmentTestSpec({
    required this.testId,
    required this.buildId,
    required this.sizeMiB,
    required this.startedAt,
    this.irohOnly = false,
  });

  final String testId;
  final String buildId;
  final int sizeMiB;
  final DateTime startedAt;
  final bool irohOnly;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'protocolVersion': 1,
    'irohOnly': irohOnly,
    'testId': testId,
    'buildId': buildId,
    'sizeMiB': sizeMiB,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };

  static DebugAttachmentTestSpec? tryParse(Object? value) {
    if (value is! Map<String, dynamic> || value['protocolVersion'] != 1) {
      return null;
    }
    final testId = value['testId'];
    final buildId = value['buildId'];
    final sizeMiB = value['sizeMiB'];
    final startedAt = DateTime.tryParse(value['startedAt'] as String? ?? '');
    if ((value['irohOnly'] != null && value['irohOnly'] is! bool) ||
        testId is! String ||
        testId.isEmpty ||
        testId.length > 160 ||
        buildId is! String ||
        buildId.isEmpty ||
        buildId.length > 256 ||
        sizeMiB is! int ||
        !MessengerController.debugLanTestSizesMiB.contains(sizeMiB) ||
        startedAt == null) {
      return null;
    }
    return DebugAttachmentTestSpec(
      testId: testId,
      buildId: buildId,
      sizeMiB: sizeMiB,
      startedAt: startedAt.toUtc(),
      irohOnly: value['irohOnly'] == true,
    );
  }
}

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
    StorageCapacityProvider? storageCapacityProvider,
    bool enableLongPoll = true,
    bool enablePairingBeacon = true,
    LanDirectChannel? lanDirectChannel,
    NativeAttachmentCrypto? attachmentCrypto,
    String? debugBuildId,
    Future<TransportRegistry?> Function(IdentityRecord identity)?
    transportRegistryFactory,
  }) : _vaultStore = vaultStore,
       _localRelayNode = localRelayNode ?? LocalRelayNode(),
       _platformBridge = platformBridge ?? PlatformBridge(),
       _lanAddressProvider = lanAddressProvider ?? discoverLanAddresses,
       _nowProvider = nowProvider ?? DateTime.now,
       _signedRelayDefaultsLoader = signedRelayDefaultsLoader,
       _attachmentRootProvider =
           attachmentRootProvider ?? _defaultAttachmentRootProvider,
       _storageCapacityProvider =
           storageCapacityProvider ?? defaultStorageCapacityProvider,
       _longPollEnabled = enableLongPoll,
       _pairingBeaconEnabled = enablePairingBeacon,
       _lanDirectChannel = lanDirectChannel,
       _nativeAttachmentCrypto =
           attachmentCrypto ?? NativeAttachmentCrypto.tryCreate(),
       _debugBuildId = debugBuildId?.trim().isEmpty == false
           ? debugBuildId!.trim()
           : null,
       _transportRegistryFactory = transportRegistryFactory {
    _relayClient = _ScoringRelayClient(
      inner: relayClient,
      onAttempt: _recordRelayAttemptFromShim,
      nowProvider: () => (nowProvider ?? DateTime.now)(),
    );
    _transferControlSubscription = _platformBridge.transferControlEvents.listen(
      _handleNativeTransferControl,
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
  final StorageCapacityProvider _storageCapacityProvider;
  late final RelayClient _relayClient;
  late final CryptoService _crypto;
  late final ReachabilityTracker _reachability;
  late final RouteHealthTracker _routeHealthTracker;
  late final StreamSubscription<String> _transferControlSubscription;
  Timer? _transferNotificationTimer;
  final bool _longPollEnabled;
  final bool _pairingBeaconEnabled;
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
  PlatformBridge get platformBridge => _platformBridge;
  final Future<List<String>> Function() _lanAddressProvider;
  final DateTime Function() _nowProvider;
  final Future<SignedRelayDefaults?> Function()? _signedRelayDefaultsLoader;

  /// Resolves the directory under which assembled attachment bytes are
  /// persisted, so the bubble can keep rendering the file row / image
  /// thumbnail after an app restart instead of regressing to "transferring".
  final Future<Directory> Function() _attachmentRootProvider;
  Future<Directory>? _attachmentRootFuture;

  /// nightly.9 LocalSend-style direct PUT channel. Null → fast-path is
  /// disabled and every chunk goes through the relay envelope shape (the
  /// existing path). When non-null and `start()` returns a port, peers
  /// can advertise their endpoint via the chunk_request payload and the
  /// sender PUTs chunks directly instead of round-tripping via the relay.
  final LanDirectChannel? _lanDirectChannel;
  final NativeAttachmentCrypto? _nativeAttachmentCrypto;
  final String? _debugBuildId;
  final Future<TransportRegistry?> Function(IdentityRecord identity)?
  _transportRegistryFactory;
  TransportRegistry? _transportRegistry;
  final List<StreamSubscription<TransportInboundEnvelope>>
  _transportInboundSubscriptions = [];

  /// Cache: peer deviceId → endpoint where the peer's `LanDirectChannel`
  /// is listening. Populated when an `attachment_chunk_request` payload
  /// carries the peer's port hint. Evicted on repeated PUT failures.
  final Map<String, LanDirectEndpoint> _peerLanDirect = {};

  /// Current LAN addresses for embedding in our own outbound payload
  /// hints. Refreshed during initialize() and on connectivity changes.
  List<String> _localLanAddressesCache = const <String>[];

  /// Per-recipient LAN-direct failure cooldown. After two consecutive
  /// PUT failures we demote a peer to relay-only for this window before
  /// re-probing.
  // nightly.12: cooldown shortened from 30 s → 10 s. Combined with the
  // probe-before-demote gate in `_onLanDirectPutFailure`, demotions are
  // now rare; when they do happen we recover ~3× faster.
  static const Duration _lanDirectCooldown = Duration(seconds: 10);
  // nightly.12: LAN-direct endpoint freshness extended 5 min → 30 min.
  // Peers keep the same `localPort` for the lifetime of the process
  // anyway; the 5-min cap forced unnecessary re-warms via chunk_request
  // hints whenever a quiet contact came back.
  static const Duration _lanDirectFreshness = Duration(minutes: 30);

  /// nightly.10 staged-attachment buckets, keyed by recipient deviceId.
  /// Every input pipeline (picker, drag-drop, paste, Ctrl+V) calls
  /// `stageAttachments` to populate one of these instead of sending
  /// immediately. The composer renders them as preview tiles with an
  /// X-to-cancel; the Send button calls `sendStagedBundle` to commit.
  /// Lives on the controller (not the chat screen state) so navigation
  /// between contacts doesn't lose the staged items.
  final Map<String, List<StagedAttachment>> _stagedAttachments = {};
  VaultSnapshot _snapshot = VaultSnapshot.empty();

  /// Rolling cap on the persisted seen-envelope ledger. Envelopes older
  /// than the cap window are also long past every relay's queue TTL, so
  /// they can never be re-delivered and keeping their ids only bloats the
  /// vault. Mutable so tests can exercise the eviction without processing
  /// tens of thousands of envelopes.
  @visibleForTesting
  static int seenEnvelopeCap = 20000;

  /// In-memory mirror of [VaultSnapshot.seenEnvelopeIds]. The persisted
  /// form stays a List (ordered, JSON-friendly, cap-evictable from the
  /// front) but dedupe checks run against this Set so envelope processing
  /// doesn't pay an O(n) List scan per envelope. Rebuilt wherever
  /// `_snapshot` is replaced wholesale (vault load, identity reset).
  final Set<String> _seenEnvelopeIdSet = <String>{};

  /// Envelope ids currently being dispatched by an in-flight
  /// `_processEnvelopes` run. Long-poll, `pollNow`, and the local-relay
  /// store callback run overlapping `_processEnvelopes` futures, and the
  /// same envelope can arrive via two transports (LAN push + relay poll)
  /// before either run reaches `_markSeen` — the seen ledger alone can't
  /// catch that because it's only written after the dispatch awaits.
  /// Reserving the id here, synchronously, before the first await closes
  /// the window (duplicate acks, double-run control-envelope handlers).
  final Set<String> _inFlightEnvelopeIds = <String>{};
  final Set<String> _servingAttachmentBlocks = <String>{};
  final Set<String> _receivingAttachmentBlocks = <String>{};
  Timer? _pollTimer;
  bool _ready = false;
  Completer<void>? _pollCompleter;
  bool _appInForeground = true;
  NetworkCostClass _networkCostClass = NetworkCostClass.unmetered;
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
  String? _debugFileTestStatus;
  final List<DebugFileTestResult> _debugFileTestResults =
      <DebugFileTestResult>[];
  final Map<String, Completer<bool>> _debugFileProbeCompleters =
      <String, Completer<bool>>{};
  final Map<String, Completer<DebugFileTestResult>> _debugFileResultCompleters =
      <String, Completer<DebugFileTestResult>>{};
  final Map<String, DebugAttachmentTestSpec> _outboundDebugAttachmentTests =
      <String, DebugAttachmentTestSpec>{};
  final Map<String, _AuthorizedDebugFileTest> _authorizedInboundDebugFileTests =
      <String, _AuthorizedDebugFileTest>{};
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
  // Download acceptance can involve allocating a large sparse partial file
  // and persisting its journal. Track it separately so the UI acknowledges
  // the tap immediately and duplicate taps cannot race two truncations.
  final Set<String> _acceptingIncomingAttachmentIds = <String>{};
  // Assembled, verified attachment bytes the UI / test can read via
  // [attachmentBytesFor]. Kept in memory for v0.3.2; persisted to disk in
  // a follow-up pass.
  final Map<String, Uint8List> _assembledAttachments = <String, Uint8List>{};
  // Completed files above 8 MiB intentionally stay out of Dart heap. This
  // synchronous index lets widgets distinguish "ready on disk" from an
  // in-flight transfer without probing the filesystem during build.
  final Set<String> _locallyAvailableAttachments = <String>{};
  final Map<String, int> _preparationProgressBytes = <String, int>{};
  final Set<String> _dismissedTransferIds = <String>{};

  // Small JPEG posters shipped alongside video offers so the receiver
  // can render a thumbnail BEFORE the full bytes finish transferring.
  // Keyed by attachment id; capped at the offer envelope's `posterBase64`
  // size (~32 KB per asset).
  final Map<String, Uint8List> _videoPosters = <String, Uint8List>{};

  /// Returns the video poster bytes for an attachment, or null if no
  /// poster shipped with the offer.
  Uint8List? videoPosterFor(String attachmentId) => _videoPosters[attachmentId];

  // v0.3.3-nightly.6 per-contact serial transfer queue. Each contact gets
  // a FIFO of pending attachment ids; the worker dispatches one offer at
  // a time and only advances when `attachment_complete` lands (or a
  // stall timeout fires). Multi-contact sends still run in parallel.
  final Map<String, List<String>> _outboundQueueByContact =
      <String, List<String>>{};
  final Map<String, String> _activeOutboundByContact = <String, String>{};
  final Map<String, Timer> _outboundStallTimers = <String, Timer>{};

  static const Duration _outboundStallTimeout = Duration(seconds: 60);

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
    // Boost while any attachment transfer is in flight (sending or
    // receiving). Without this the idle 15 s cadence stretched every
    // chunk that fell back to relay polling into a 15 s wait — see the
    // 95 KB-at-33% / 238 KB-at-25% reports from nightly.6 battle tests.
    if (hasActiveTransfer) {
      return _activeTransferPollInterval;
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

  /// True when at least one inbound or outbound attachment transfer is
  /// currently in flight. Used by [_currentPollInterval] to boost the
  /// poll cadence so chunk envelopes don't queue behind the idle 15 s
  /// poll interval. Public so the Debug bundle can surface the boost.
  bool get hasActiveTransfer =>
      _inboundAttachments.isNotEmpty || _activeOutboundByContact.isNotEmpty;

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
      final transportIdentityMigrated = await _ensureTransportIdentity();
      final protocolQueueMigrated = _markLegacyQueuedControlsIncompatible();
      if (!experimentalAndroidBackgroundRuntimeAvailable &&
          (_snapshot.identity?.androidBackgroundRuntimeEnabled ?? false)) {
        _snapshot = _snapshot.copyWith(
          identity: _snapshot.identity!.copyWith(
            androidBackgroundRuntimeEnabled: false,
          ),
        );
        await _saveSnapshotSilently(notify: false);
      } else if (protocolQueueMigrated || transportIdentityMigrated) {
        await _saveSnapshotSilently(notify: false);
      }
      _rebuildSeenEnvelopeIdSet();
      final normalized = _normalizeStoredContactRoutes();
      if (normalized) {
        await _saveSnapshotSilently(notify: false);
      }
      // nightly.9 scrubber: users who ran nightly.8 had attachment_progress
      // and attachment_pause_control envelopes leak into chat history as
      // JSON-shaped text bodies (the outer gate at L5614 was missing those
      // kinds). Clean them up on boot so the regression doesn't linger in
      // the UI after the user updates.
      final scrubbed = _scrubLeakedAttachmentEnvelopeMessages();
      if (scrubbed) {
        await _saveSnapshotSilently(notify: false);
      }
      await _startLanDirectChannel();
      appendDebugLog(
        _nativeAttachmentCrypto == null
            ? 'Attachment crypto: compatible Dart fallback'
            : 'Attachment crypto: native Rust XChaCha/SHA acceleration',
      );
      await _discardInterruptedDebugFileTests();
      await _restoreTransferSessionsAndCleanAttachments();
      await _ingestSignedDefaultRelaysIfNeeded();
      if (_snapshot.identity != null) {
        await _startTransportRegistry();
        await _refreshLanAddresses(persist: false);
        await _ensureLocalRelayRunning();
        await _ensurePairingBeaconRunning();
        _applyAndroidBackgroundPreference();
        for (final contact in _snapshot.contacts) {
          _pumpOutboundQueue(contact);
        }
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

  Future<void> _startTransportRegistry() async {
    final factory = _transportRegistryFactory;
    if (_transportRegistry != null || factory == null) {
      return;
    }
    final me = _snapshot.identity;
    if (me == null) return;
    try {
      final registry = await factory(me);
      if (registry == null) return;
      await registry.start();
      _transportRegistry = registry;
      for (final adapter in registry.adapters) {
        _transportInboundSubscriptions.add(
          adapter.inboundEnvelopes.listen(
            _handleTransportInbound,
            onError: (Object error, StackTrace stackTrace) {
              appendDebugLog(
                '${adapter.kind.label} inbound transport failed: $error',
              );
            },
          ),
        );
      }
    } catch (error) {
      appendDebugLog('Native transport startup failed: $error');
      _setTransientStatus(
        'Direct online transport is unavailable; relay fallback remains active.',
      );
    }
  }

  Future<void> _stopTransportRegistry() async {
    for (final subscription in _transportInboundSubscriptions) {
      await subscription.cancel();
    }
    _transportInboundSubscriptions.clear();
    final registry = _transportRegistry;
    _transportRegistry = null;
    if (registry != null) await registry.stop();
  }

  Future<void> _handleTransportInbound(TransportInboundEnvelope inbound) async {
    if (inbound.transport != TransportKind.iroh) return;
    final contact = _snapshot.contacts
        .where(
          (candidate) =>
              candidate.irohEndpointId == inbound.senderTransportIdentity,
        )
        .firstOrNull;
    final global = _snapshot.identity?.connectivity;
    if (global == null ||
        (contact?.routing.effectivePolicy(TransportKind.iroh, global) ??
                global.policyFor(TransportKind.iroh)) ==
            TransportPolicy.disabled ||
        (inbound.path == TransportPathKind.relayed &&
            (!global.irohRelayEnabled ||
                !(contact?.routing.irohRelayEnabled ?? true)))) {
      appendDebugLog('Dropped Iroh ingress disabled by connectivity policy.');
      return;
    }
    try {
      if (contact == null) {
        // A first contact request cannot have a local pin yet. Authenticate
        // its signed ci6 binding against QUIC's remote identity, and retain
        // the existing explicit-approval flow; no messages/files get through.
        if (inbound.bytes.length > _maxBootstrapPayloadBytes * 2) return;
        final decoded = jsonDecode(utf8.decode(inbound.bytes));
        if (decoded is! Map<String, dynamic>) return;
        final envelope = RelayEnvelope.fromJson(decoded);
        if (envelope.kind != 'contact_exchange' ||
            envelope.protocolVersion != 1 ||
            !_isValidInboundEnvelope(envelope)) {
          return;
        }
        final invite = ContactInvite.tryDecodePayload(
          utf8.decode(base64Decode(envelope.payloadBase64!)),
        );
        if (invite == null ||
            !invite.usesSignedFormat ||
            invite.irohEndpointId != inbound.senderTransportIdentity ||
            invite.deviceId != envelope.senderDeviceId ||
            invite.accountId != envelope.senderAccountId ||
            !await _crypto.verifyContactInvite(invite)) {
          appendDebugLog('Rejected Iroh contact request identity binding.');
          return;
        }
        await _processEnvelopes(
          [envelope],
          ingressKind: inbound.path == TransportPathKind.relayed
              ? PeerRouteKind.relay
              : PeerRouteKind.directInternet,
        );
        return;
      }
      if (!contact.hasPinnedIrohIdentity || !contact.canSendOutbound) {
        appendDebugLog('Rejected Iroh envelope from an untrusted contact.');
        return;
      }
      final range = decodeIrohAttachmentRangeFrame(inbound.bytes);
      if (range != null) {
        final state = _inboundAttachments[range.attachmentId];
        if (state == null || range.offset % state.descriptor.chunkSize != 0) {
          throw const FormatException(
            'Iroh attachment range does not match an active manifest.',
          );
        }
        if (state.debugTest case final spec?) {
          if (!spec.irohOnly || inbound.path != TransportPathKind.direct) {
            throw const FormatException(
              'Diagnostic block arrived on an unselected transport.',
            );
          }
        }
        await _handleAttachmentChunkBytes(
          contact,
          attachmentId: range.attachmentId,
          index: range.offset ~/ state.descriptor.chunkSize,
          packedBytes: range.bytes,
          expectedHash: range.sha256,
        );
        _reachability.noteAvailablePath(contact.deviceId);
        return;
      }
      final decoded = jsonDecode(utf8.decode(inbound.bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Iroh envelope must be a JSON object.');
      }
      final envelope = RelayEnvelope.fromJson(decoded);
      if (envelope.senderDeviceId != contact.deviceId ||
          envelope.recipientDeviceId != _snapshot.identity?.deviceId) {
        throw const FormatException('Iroh envelope identity mismatch.');
      }
      final processed = await _processEnvelopes(
        [envelope],
        ingressKind: inbound.path == TransportPathKind.relayed
            ? PeerRouteKind.relay
            : PeerRouteKind.directInternet,
      );
      if (processed > 0) {
        _reachability.noteAvailablePath(contact.deviceId);
        await _saveSnapshotSilently(debounce: true);
      }
    } catch (error) {
      appendDebugLog('Rejected malformed Iroh envelope: $error');
    }
  }

  Future<bool> _ensureTransportIdentity() async {
    final current = _snapshot.identity;
    if (current == null) return false;
    if (current.hasTransportIdentity) {
      if (current.irohEndpointId?.isNotEmpty == true) return false;
      _snapshot = _snapshot.copyWith(
        identity: current.copyWith(
          irohEndpointId: _crypto.irohEndpointIdForSigningKey(
            current.signingPublicKeyBase64!,
          ),
        ),
      );
      return true;
    }
    final signing = await _crypto.createSigningIdentity();
    _snapshot = _snapshot.copyWith(
      identity: current.copyWith(
        signingPublicKeyBase64: signing.publicKeyBase64,
        signingPrivateKeyBase64: signing.privateKeyBase64,
        irohEndpointId: _crypto.irohEndpointIdForSigningKey(
          signing.publicKeyBase64,
        ),
      ),
    );
    return true;
  }

  Future<void> _restoreTransferSessionsAndCleanAttachments() async {
    final root = await _attachmentRoot();
    final cacheDir = Directory(p.join(root.path, 'cache'));
    final spoolDir = Directory(p.join(root.path, 'spool'));
    final partialDir = Directory(p.join(root.path, 'partial'));
    await Future.wait(<Future<void>>[
      cacheDir.create(recursive: true),
      spoolDir.create(recursive: true),
      partialDir.create(recursive: true),
    ]);

    // Attachment v2 is a deliberate hard cut-over. Completed history and
    // cache files remain readable, but a v1 partial cannot be made safe under
    // the v2 nonce/journal rules. Mark its bubble canceled, remove only the
    // app-owned partial/spool and retain any original user-selected source.
    final legacyIncomplete = _snapshot.transferSessions
        .where(
          (session) =>
              session.attachment.protocolVersion < 2 &&
              session.state != TransferState.completed &&
              session.state != TransferState.canceled,
        )
        .toList(growable: false);
    if (legacyIncomplete.isNotEmpty) {
      for (final session in legacyIncomplete) {
        final peerId = session.peerDeviceIds.firstOrNull;
        if (peerId != null && session.messageId.isNotEmpty) {
          _updateMessageState(
            peerId,
            session.messageId,
            DeliveryState.canceled,
          );
        }
        if (session.sourceKind != TransferSourceKind.originalPath &&
            session.relativePath.isNotEmpty) {
          final ownedPath = p.normalize(
            p.join(root.path, session.relativePath),
          );
          if (isContainedPath(root.path, ownedPath)) {
            try {
              final file = File(ownedPath);
              if (await file.exists()) await file.delete();
            } catch (_) {}
          }
        }
        appendDebugLog(
          'Canceled legacy attachment ${session.id} during protocol-v2 migration; resend required.',
        );
      }
      final legacyIds = legacyIncomplete.map((entry) => entry.id).toSet();
      _snapshot = _snapshot.copyWith(
        transferSessions: _snapshot.transferSessions
            .where((entry) => !legacyIds.contains(entry.id))
            .toList(growable: false),
      );
      await _saveSnapshotSilently(notify: false);
    }

    // Both the pre-v2 id-based name and the v2 content-addressed name are
    // legitimate references. A prior startup janitor only knew about the id
    // form and could delete a completed v2 cache entry on the next launch.
    final cacheAttachmentIds = <String, Set<String>>{};
    for (final conversation in _snapshot.conversations) {
      for (final message in conversation.messages) {
        final attachment = message.attachment;
        if (attachment == null) continue;
        cacheAttachmentIds
            .putIfAbsent(attachmentStorageKey(attachment.id), () => <String>{})
            .add(attachment.id);
        if (attachment.fileHashBase64.isNotEmpty) {
          cacheAttachmentIds
              .putIfAbsent(
                attachmentStorageKey('sha256:${attachment.fileHashBase64}'),
                () => <String>{},
              )
              .add(attachment.id);
        }
      }
    }
    final referencedCacheKeys = cacheAttachmentIds.keys.toSet();
    final referencedInternalPaths = <String>{
      for (final session in _snapshot.transferSessions)
        if (session.relativePath.isNotEmpty)
          p.normalize(p.join(root.path, session.relativePath)),
    };

    Future<void> cleanDirectory(
      Directory directory, {
      required bool cache,
    }) async {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final normalized = p.normalize(entity.path);
        final basename = p.basename(entity.path);
        final keep = cache
            ? referencedCacheKeys.contains(basename)
            : referencedInternalPaths.contains(normalized);
        if (!keep || basename.endsWith('.tmp')) {
          try {
            await entity.delete();
          } catch (_) {}
        } else if (cache) {
          final attachmentIds = cacheAttachmentIds[basename];
          if (attachmentIds != null) {
            _locallyAvailableAttachments.addAll(attachmentIds);
          }
        }
      }
    }

    await cleanDirectory(cacheDir, cache: true);
    await cleanDirectory(spoolDir, cache: false);
    await cleanDirectory(partialDir, cache: false);
    // Pre-hardening caches stored attacker-controlled ids directly under the
    // root. They are never trusted as paths after v2; remove regular files
    // left there while preserving the managed subdirectories above.
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }

    final retainedSessions = <TransferSession>[];
    var restoredSessionsChanged = false;
    for (final session in _snapshot.transferSessions) {
      if (session.state == TransferState.canceled) {
        retainedSessions.add(session);
        continue;
      }
      if (session.state == TransferState.preparing) {
        final peerId = session.peerDeviceIds.firstOrNull;
        if (peerId != null && session.messageId.isNotEmpty) {
          _updateMessageState(peerId, session.messageId, DeliveryState.failed);
        }
        appendDebugLog(
          'Preparation for ${session.id} was interrupted; source was not sent.',
        );
        continue;
      }
      if (session.state == TransferState.completed &&
          session.sourceKind == TransferSourceKind.originalPath) {
        final path = session.sourcePath;
        if (path != null && await File(path).exists()) {
          retainedSessions.add(session);
        }
        continue;
      }
      final peerId = session.peerDeviceIds.firstOrNull;
      final contact = peerId == null ? null : _contactByDeviceId(peerId);
      if (contact == null ||
          _messageById(peerId!, session.messageId) == null ||
          session.attachment.fileHashBase64.isEmpty) {
        continue;
      }
      if (session.direction == TransferDirection.outbound) {
        final sourcePath = session.sourceKind == TransferSourceKind.originalPath
            ? session.sourcePath
            : p.join(root.path, session.relativePath);
        if (sourcePath == null || !await File(sourcePath).exists()) {
          const error =
              'Prepared attachment data is unavailable. Select and resend the file.';
          _updateMessageState(peerId, session.messageId, DeliveryState.failed);
          retainedSessions.add(
            session.copyWith(
              state: TransferState.failed,
              updatedAt: _now().toUtc(),
              lastError: error,
            ),
          );
          restoredSessionsChanged = true;
          appendDebugLog('Could not restore outbound ${session.id}: $error');
          continue;
        }
        final stat = await File(sourcePath).stat();
        if (stat.size != session.attachment.sizeBytes ||
            (session.sourceKind == TransferSourceKind.originalPath &&
                session.sourceModifiedAt != null &&
                stat.modified != session.sourceModifiedAt)) {
          const error =
              'The attachment source changed. Select and resend the file.';
          _updateMessageState(peerId, session.messageId, DeliveryState.failed);
          retainedSessions.add(
            session.copyWith(
              state: TransferState.failed,
              updatedAt: _now().toUtc(),
              lastError: error,
            ),
          );
          restoredSessionsChanged = true;
          appendDebugLog('Could not restore outbound ${session.id}: $error');
          continue;
        }
        final outboundState = _OutboundAttachmentState(
          messageId: session.messageId,
          peerDeviceId: peerId,
          sourcePath: sourcePath,
          sourceKind: session.sourceKind,
          descriptor: session.attachment,
          requiresLan: session.requiresLan,
          lanOnly: session.lanOnly,
        );
        final legacyPaused =
            session.state == TransferState.paused &&
            !session.pausedByMe &&
            !session.pausedByPeer;
        outboundState
          ..pausedByMe = session.pausedByMe || legacyPaused
          ..pausedByPeer = session.pausedByPeer;
        _outboundAttachments[session.id] = outboundState;
        _locallyAvailableAttachments.add(session.id);
        if (!outboundState.paused) {
          _enqueueOutbound(contact, session.id);
        }
        retainedSessions.add(session);
      } else {
        var restoredSession = session;
        var partialPath = session.relativePath.isEmpty
            ? null
            : p.join(root.path, session.relativePath);
        if (partialPath != null) {
          final partial = File(partialPath);
          if (!await partial.exists() ||
              await partial.length() != session.attachment.sizeBytes) {
            final normalizedPartial = p.normalize(partial.path);
            final normalizedPartialRoot =
                '${p.normalize(partialDir.path)}${p.separator}';
            if (normalizedPartial.startsWith(normalizedPartialRoot)) {
              try {
                if (await partial.exists()) await partial.delete();
              } catch (_) {}
            }
            partialPath = null;
            restoredSession = session.copyWith(
              state: TransferState.pending,
              relativePath: '',
              completedChunks: const <int>[],
              bytesTransferred: 0,
              updatedAt: _now().toUtc(),
              lastError:
                  'Previous partial download data was unavailable. Tap Download to restart.',
            );
            restoredSessionsChanged = true;
            appendDebugLog(
              'Reset inbound ${session.id}: partial data was missing or invalid.',
            );
          }
        }
        final restoredAwaitingAcceptance = partialPath == null;
        final inboundState = _InboundAttachmentState(
          messageId: session.messageId,
          peerDeviceId: peerId,
          descriptor: session.attachment,
          partialPath: partialPath,
          awaitingAcceptance: restoredAwaitingAcceptance,
          accepted: !restoredAwaitingAcceptance,
          receivedChunks: restoredSession.completedChunks,
        );
        final legacyPaused =
            session.state == TransferState.paused &&
            !session.pausedByMe &&
            !session.pausedByPeer;
        inboundState
          ..pausedByMe = session.pausedByMe || legacyPaused
          ..pausedByPeer = session.pausedByPeer;
        _inboundAttachments[session.id] = inboundState;
        retainedSessions.add(restoredSession);
        if (partialPath != null && !inboundState.paused) {
          _scheduleAttachmentRetry(session.id);
          _startInboundRequestWindow(inboundState, contact);
        }
      }
    }
    if (restoredSessionsChanged ||
        retainedSessions.length != _snapshot.transferSessions.length) {
      _snapshot = _snapshot.copyWith(transferSessions: retainedSessions);
      await _saveSnapshotSilently(notify: false);
    }
    final validAttachmentIds = <String>{
      for (final conversation in _snapshot.conversations)
        for (final message in conversation.messages)
          if (message.attachment != null) message.attachment!.id,
    };
    final originalCacheReferenceCount =
        _snapshot.attachmentCacheReferences.length;
    final retainedCacheReferences = _snapshot.attachmentCacheReferences
        .where((entry) => validAttachmentIds.contains(entry.attachmentId))
        .toList(growable: true);
    _snapshot = _snapshot.copyWith(
      attachmentCacheReferences: retainedCacheReferences,
    );
    var cacheReferencesChanged =
        retainedCacheReferences.length != originalCacheReferenceCount;
    for (final attachmentId in _locallyAvailableAttachments) {
      if (!retainedCacheReferences.any(
        (entry) => entry.attachmentId == attachmentId,
      )) {
        _recordAttachmentCacheReference(attachmentId);
        cacheReferencesChanged = true;
      }
    }
    await _evictManagedCacheIfNeeded(root);
    if (cacheReferencesChanged) {
      await _saveSnapshotSilently(notify: false);
    }
  }

  /// Debug transfer authorizations and result completers are intentionally
  /// process-local. If a debug artifact was force-stopped mid-test, resuming
  /// the generated payload as an ordinary user attachment would leave a
  /// permanent bubble with no runner waiting for its result. Remove only the
  /// diagnostic MIME type and its app-owned files before normal restoration.
  Future<void> _discardInterruptedDebugFileTests() async {
    if (_debugBuildId == null) return;
    const diagnosticMime = 'application/x-conest-transfer-test';
    final diagnosticIds = <String>{
      for (final session in _snapshot.transferSessions)
        if (session.attachment.mimeType == diagnosticMime) session.id,
      for (final conversation in _snapshot.conversations)
        for (final message in conversation.messages)
          if (message.attachment?.mimeType == diagnosticMime)
            message.attachment!.id,
    };
    if (diagnosticIds.isEmpty) return;
    for (final attachmentId in diagnosticIds) {
      await _deleteAttachmentArtifacts(attachmentId);
    }
    final conversations = _snapshot.conversations
        .map(
          (conversation) => conversation.copyWith(
            messages: conversation.messages
                .where(
                  (message) => !diagnosticIds.contains(message.attachment?.id),
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
    _snapshot = _snapshot.copyWith(
      conversations: conversations,
      transferSessions: _snapshot.transferSessions
          .where((session) => !diagnosticIds.contains(session.id))
          .toList(growable: false),
      attachmentCacheReferences: _snapshot.attachmentCacheReferences
          .where((reference) => !diagnosticIds.contains(reference.attachmentId))
          .toList(growable: false),
    );
    final root = await _attachmentRoot();
    final diagnostics = Directory(p.join(root.path, 'diagnostics'));
    if (await diagnostics.exists()) {
      await for (final entity in diagnostics.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    appendDebugLog(
      'Removed ${diagnosticIds.length} interrupted automatic file test(s).',
    );
    await _saveSnapshotSilently(notify: false);
  }

  void setStatus(String? value) {
    _statusMessage = value;
    notifyListeners();
  }

  /// In-memory ring buffer of recent diagnostic lines (clipboard, save,
  /// rotation). Bounded to the last [_debugLogCapacity] entries so a long
  /// session can't leak memory. Inspected from the Debug menu so the user
  /// can read errors that the transient status line lost.
  static const int _debugLogCapacity = 50;
  final List<String> _debugLog = <String>[];

  void appendDebugLog(String line) {
    final stamped = '${DateTime.now().toUtc().toIso8601String()}  $line';
    _debugLog.add(stamped);
    if (_debugLog.length > _debugLogCapacity) {
      _debugLog.removeAt(0);
    }
    // Automatic transfer diagnostics run on physical devices where the
    // in-app ring buffer is not observable while the UI is busy. Mirror only
    // exact debug-artifact traces to the platform log; stable/nightly builds
    // retain the bounded in-memory log without emitting contact metadata.
    if (_debugBuildId != null) {
      debugPrint('[ConestDebug] $stamped');
    }
  }

  List<String> get recentDebugLog => List<String>.unmodifiable(_debugLog);

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
      await _checkRouteHealth(
        endpoint,
        relayTimeout: const Duration(seconds: 4),
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
    buffer.writeln('debugBuildId=${_debugBuildId ?? "(none)"}');
    buffer.writeln('lanDirectPort=$lanDirectPort');
    if (_lanDirectChannel case final HttpLanDirectChannel channel) {
      buffer.writeln('lanLastPutFailure=${channel.lastPutFailure ?? "(none)"}');
    }
    for (final entry in _peerLanDirect.entries) {
      final ep = entry.value;
      buffer.writeln(
        'lanPeer=${entry.key} endpoint=${ep.host}:${ep.port} alternateHosts=${ep.alternateHosts.join(",")} failures=${ep.consecutiveFailures} demotedUntil=${ep.demotedUntil}',
      );
    }
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
      final payload = (await _inviteForIdentity(me)).encodePayload();
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
    final attachmentSelfTest = await _runAttachmentSelfTest();
    add(
      attachmentSelfTest.name,
      attachmentSelfTest.status,
      attachmentSelfTest.detail,
    );
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
    if (enabled && !experimentalAndroidBackgroundRuntimeAvailable) {
      throw StateError(
        'Android background receive is experimental and unavailable in this build.',
      );
    }
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
    prefs = prefs.copyWith(
      irohRelayUrls: normalizeIrohRelayUrls(prefs.irohRelayUrls),
    );
    final restartNative =
        me.connectivity.irohRelayEnabled != prefs.irohRelayEnabled ||
        !listEquals(me.connectivity.irohRelayUrls, prefs.irohRelayUrls) ||
        me.connectivity.policyFor(TransportKind.iroh) !=
            prefs.policyFor(TransportKind.iroh);
    _snapshot = _snapshot.copyWith(identity: me.copyWith(connectivity: prefs));
    if (restartNative) {
      await _stopTransportRegistry();
    }
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

  double get _storageReserveFraction =>
      (_snapshot.identity?.connectivity.storageReserveEnabled ?? true)
      ? 0.10
      : 0;

  bool _canAllocateStorage(StorageCapacity? capacity, int bytes) =>
      capacity?.canAllocate(bytes, reserveFraction: _storageReserveFraction) ??
      false;

  Future<void> updateStorageReserveEnabled(bool enabled) async {
    final me = _requireIdentity();
    _snapshot = _snapshot.copyWith(
      identity: me.copyWith(
        connectivity: me.connectivity.copyWith(storageReserveEnabled: enabled),
      ),
    );
    await _persist(
      enabled
          ? '10% free-space reserve enabled.'
          : '10% free-space reserve disabled.',
    );
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
      await _startTransportRegistry();
      unawaited(_startLongPollIfEnabled());
    } else {
      await _stopTransportRegistry();
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
    final oldKey = _snapshot.pinnedRelayIdentityKeys[id];
    final updated = Map<String, String>.from(_snapshot.pinnedRelayIdentityKeys)
      ..[id] = key;
    if (oldKey != null) {
      for (final entry in updated.entries.toList(growable: false)) {
        if (entry.value == oldKey) updated[entry.key] = key;
      }
    }
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
    final attachmentIds = <String>{
      for (final conversation in _snapshot.conversations)
        if (conversation.peerDeviceId == deviceId)
          for (final message in conversation.messages)
            if (message.attachment != null) message.attachment!.id,
    };
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
    for (final attachmentId in attachmentIds) {
      _outboundAttachments.remove(attachmentId);
      _inboundAttachments.remove(attachmentId)?.retryTimer?.cancel();
      _assembledAttachments.remove(attachmentId);
      _removeTransferSession(attachmentId);
      unawaited(_deleteAttachmentArtifacts(attachmentId));
    }
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
    await _stopTransportRegistry().timeout(
      platformCallTimeout,
      onTimeout: () {},
    );
    try {
      final attachmentRoot = await _attachmentRoot();
      if (await attachmentRoot.exists()) {
        await attachmentRoot.delete(recursive: true);
      }
    } catch (error) {
      appendDebugLog('Attachment cache reset failed: $error');
    }
    await _vaultStore.clear();
    _snapshot = VaultSnapshot.empty();
    _rebuildSeenEnvelopeIdSet();
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
    _authorizedInboundDebugFileTests.clear();
    _outboundDebugAttachmentTests.clear();
    _debugFileTestResults.clear();
    _debugFileTestStatus = null;
    _locallyDeletedMessageIds.clear();
    for (final state in _inboundAttachments.values) {
      state.retryTimer?.cancel();
    }
    for (final timer in _outboundStallTimers.values) {
      timer.cancel();
    }
    _inboundAttachments.clear();
    _outboundAttachments.clear();
    _assembledAttachments.clear();
    _locallyAvailableAttachments.clear();
    _videoPosters.clear();
    _outboundQueueByContact.clear();
    _activeOutboundByContact.clear();
    _outboundStallTimers.clear();
    _peerLanDirect.clear();
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
    final signingIdentity = await _crypto.createSigningIdentity();
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
      signingPublicKeyBase64: signingIdentity.publicKeyBase64,
      signingPrivateKeyBase64: signingIdentity.privateKeyBase64,
      irohEndpointId: _crypto.irohEndpointIdForSigningKey(
        signingIdentity.publicKeyBase64,
      ),
    );
    _snapshot = _snapshot.copyWith(identity: created);
    await _startTransportRegistry();
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

  /// Prepares an explicitly untrusted public optical transfer. It is signed
  /// so corruption and a stable sender key can be shown, but it never inherits
  /// contact trust and receivers must approve the final import.
  Future<PreparedBeamTransfer> preparePublicBeam({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) => _prepareBeam(
    mode: BeamMode.public,
    cleartext: bytes,
    fileName: fileName,
    mimeType: mimeType,
  );

  /// Prepares an optical transfer encrypted with the same pairwise secret as
  /// normal Conest attachments. The recipient identity is bound into the AEAD
  /// associated data so a frame stream shown to the wrong contact cannot be
  /// decrypted or silently imported.
  Future<PreparedBeamTransfer> prepareContactBeam({
    required ContactRecord contact,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) {
    if (!contact.canSendOutbound || !contact.hasPinnedIrohIdentity) {
      throw StateError(
        'Contact-encrypted Beam requires a verified ci6 contact identity.',
      );
    }
    return _prepareBeam(
      mode: BeamMode.contactEncrypted,
      cleartext: bytes,
      fileName: fileName,
      mimeType: mimeType,
      contact: contact,
    );
  }

  Future<PreparedBeamTransfer> prepareInviteBeam() async {
    final invite = await buildInvite();
    return _prepareBeam(
      mode: BeamMode.contactInvite,
      cleartext: Uint8List.fromList(utf8.encode(invite.encodePayload())),
      fileName: 'conest-contact.ci6',
      mimeType: 'application/vnd.conest.invite',
    );
  }

  Future<PreparedBeamTransfer> _prepareBeam({
    required BeamMode mode,
    required Uint8List cleartext,
    required String fileName,
    required String mimeType,
    ContactRecord? contact,
  }) async {
    if (cleartext.isEmpty || cleartext.length > conestBeamMaximumPayloadBytes) {
      throw ArgumentError(
        'Beam v1 payloads must be between 1 byte and 64 MiB.',
      );
    }
    final safeName = sanitizeAttachmentFileName(fileName);
    final safeMime = sanitizeAttachmentMimeType(mimeType);
    final me = _requireIdentity();
    final signingKey = me.signingPublicKeyBase64;
    if (signingKey == null || signingKey.isEmpty) {
      throw StateError('The installation signing identity is unavailable.');
    }
    final random = Random.secure();
    final transferId = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    var encodedPayload = cleartext;
    String? encryptionMetadata;
    if (mode == BeamMode.contactEncrypted) {
      if (contact == null) {
        throw ArgumentError('An encrypted Beam requires a contact.');
      }
      final encrypted = await _crypto.encryptBeamPayload(
        contact: contact,
        transferId: transferId,
        plaintext: cleartext,
      );
      encodedPayload = encrypted.ciphertext;
      encryptionMetadata = encrypted.metadataBase64;
    }
    var manifest = BeamManifest(
      transferId: transferId,
      mode: mode,
      fileName: safeName,
      mimeType: safeMime,
      sizeBytes: encodedPayload.length,
      sha256Base64: base64Encode(
        dart_crypto.sha256.convert(encodedPayload).bytes,
      ),
      createdAt: _now(),
      senderFingerprint: _beamFingerprintForSigningKey(signingKey),
      senderSigningPublicKeyBase64: signingKey,
      encryptionMetadataBase64: encryptionMetadata,
    );
    manifest = await _crypto.signBeamManifest(manifest);
    final package = BeamPackage(manifest: manifest, payload: encodedPayload);
    return PreparedBeamTransfer(
      package: package,
      encoder: BeamEncoder(package: package),
      recipientDeviceId: contact?.deviceId,
    );
  }

  /// Verifies a decoded Beam before the UI is allowed to offer an import.
  /// Public transfers stay untrusted even when their self-signature is valid.
  Future<BeamImportResult> inspectBeamPackage(BeamPackage package) async {
    final manifest = package.manifest;
    if (manifest.fileName != sanitizeAttachmentFileName(manifest.fileName) ||
        !isValidAttachmentMimeType(manifest.mimeType)) {
      throw const FormatException('Beam attachment metadata is unsafe.');
    }
    final signingKey = manifest.senderSigningPublicKeyBase64;
    if (signingKey == null || signingKey.isEmpty) {
      throw const FormatException('Beam sender signing key is missing.');
    }
    final expectedFingerprint = _beamFingerprintForSigningKey(signingKey);
    if (manifest.senderFingerprint != expectedFingerprint ||
        !await _crypto.verifyBeamManifest(
          manifest: manifest,
          signingPublicKeyBase64: signingKey,
        )) {
      throw const FormatException('Beam manifest signature is invalid.');
    }
    ContactRecord? sender;
    for (final candidate in _snapshot.contacts) {
      if (candidate.signingPublicKeyBase64 == signingKey &&
          candidate.transportIdentityVerifiedAt != null &&
          !candidate.pendingVerification) {
        sender = candidate;
        break;
      }
    }
    if (manifest.mode == BeamMode.contactEncrypted) {
      if (sender == null) {
        throw const FormatException(
          'Encrypted Beam sender is not a verified contact.',
        );
      }
      final metadata = manifest.encryptionMetadataBase64;
      if (metadata == null || metadata.isEmpty) {
        throw const FormatException('Beam encryption metadata is missing.');
      }
      final bytes = await _crypto.decryptBeamPayload(
        contact: sender,
        transferId: manifest.transferId,
        encrypted: BeamEncryptedPayload(
          ciphertext: package.payload,
          metadataBase64: metadata,
        ),
      );
      return BeamImportResult(
        manifest: manifest,
        bytes: bytes,
        senderVerified: true,
        contactTrusted: true,
        senderDeviceId: sender.deviceId,
      );
    }
    if (manifest.mode == BeamMode.contactInvite) {
      final invite = ContactInvite.decodePayload(utf8.decode(package.payload));
      if (!invite.usesSignedFormat ||
          invite.signingPublicKeyBase64 != signingKey ||
          !await _crypto.verifyContactInvite(invite)) {
        throw const FormatException('Beam contact invite is invalid.');
      }
      return BeamImportResult(
        manifest: manifest,
        bytes: package.payload,
        senderVerified: true,
        contactTrusted: false,
        invite: invite,
      );
    }
    return BeamImportResult(
      manifest: manifest,
      bytes: package.payload,
      senderVerified: true,
      contactTrusted: false,
      senderDeviceId: sender?.deviceId,
    );
  }

  /// Persists a Beam only after an explicit UI acceptance. It is deliberately
  /// kept outside conversations: public optical data never acquires contact
  /// trust merely because its signature and content hash are valid.
  Future<File> persistAcceptedBeam(BeamImportResult result) async {
    if (result.invite != null) {
      throw StateError('Contact invites are not attachment files.');
    }
    final root = await _attachmentRoot();
    final capacity = await _storageCapacityProvider(root.path);
    if (capacity != null &&
        !_canAllocateStorage(capacity, result.bytes.length)) {
      throw StateError(
        _storageReserveFraction > 0
            ? 'Not enough storage is available while preserving the safety reserve.'
            : 'Not enough free storage for this file.',
      );
    }
    final directory = Directory(p.join(root.path, 'beam', 'accepted'));
    if (!await directory.exists()) await directory.create(recursive: true);
    final safeName = sanitizeAttachmentFileName(result.manifest.fileName);
    final target = File(
      p.join(directory.path, '${result.manifest.transferId}-$safeName'),
    );
    if (await target.exists()) return target;
    final temporary = File('${target.path}.part');
    await temporary.writeAsBytes(result.bytes, flush: true);
    await restrictFileToOwner(temporary);
    await temporary.rename(target.path);
    await restrictFileToOwner(target);
    return target;
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
    bool recipientKnowsIdentity = false,
  }) async {
    final me = _requireIdentity();
    if (invite.version >= 6 && !await _crypto.verifyContactInvite(invite)) {
      throw const FormatException('Contact invite signature is invalid.');
    }
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
      signingPublicKeyBase64: invite.signingPublicKeyBase64,
      irohEndpointId: invite.irohEndpointId,
      capabilities: invite.capabilities,
      transportIdentityVerifiedAt: invite.version >= 6 ? _now() : null,
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
      exchangeStatus =
          await _sendReciprocalContactExchange(
            contact,
            recipientKnowsIdentity: recipientKnowsIdentity,
          )
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

  List<PendingContactRequest> get pendingContactRequests =>
      List.unmodifiable(_snapshot.pendingContactRequests);

  Future<ContactAdditionResult> approvePendingContactRequest(
    String requestId, {
    String? alias,
  }) async {
    final request = _snapshot.pendingContactRequests
        .where((entry) => entry.id == requestId)
        .firstOrNull;
    if (request == null) {
      throw ArgumentError('Contact request is no longer available.');
    }
    final invite = ContactInvite.decodePayload(request.invitePayload);
    if (invite.deviceId != request.senderDeviceId ||
        invite.accountId != request.senderAccountId) {
      throw const FormatException('Contact request identity mismatch.');
    }
    final result = await _trustInvite(
      invite: invite,
      recipientKnowsIdentity: true,
      alias: alias?.trim().isNotEmpty == true
          ? alias!.trim()
          : invite.displayName,
    );
    _snapshot = _snapshot.copyWith(
      pendingContactRequests: _snapshot.pendingContactRequests
          .where((entry) => entry.id != requestId)
          .toList(growable: false),
    );
    await _saveSnapshotSilently(notify: true);
    return result;
  }

  Future<void> rejectPendingContactRequest(String requestId) async {
    final filtered = _snapshot.pendingContactRequests
        .where((entry) => entry.id != requestId)
        .toList(growable: false);
    if (filtered.length == _snapshot.pendingContactRequests.length) return;
    _snapshot = _snapshot.copyWith(pendingContactRequests: filtered);
    await _persist('Contact request rejected.');
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
      createdAt: _now().toUtc(),
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

  /// Files at or below this boundary may use ordinary relay-capable routes.
  /// Anything larger is marked LAN-direct-only and can never fall back to a
  /// relay for chunk bytes.
  static const int maxAttachmentSizeBytes = 30 * 1024 * 1024;

  /// 32 KB chunks keep each pairwise-encrypted envelope well under the
  /// relay's `DEFAULT_MAX_ENVELOPE_BYTES = 256 KB` cap (32 KB raw
  /// + base64 chunk ciphertext + ChaCha20 overhead + JSON wrap ≈ 100 KB).
  /// For a worst-case 30 MB file this means ~960 chunks; SHA-256 across
  /// them is sub-second on modern devices.
  static const int _attachmentChunkSize = 128 * 1024;

  /// Direct-only attachments use 4 MiB independently authenticated blocks.
  /// Binary LAN v2 carries these without the relay envelope's JSON/base64
  /// expansion, cutting HTTP transactions 32-fold while keeping pause,
  /// resume, corruption recovery, and bounded-memory random access.
  static const int _lanAttachmentChunkSize = 4 * 1024 * 1024;

  /// When the only route to a contact is LAN, the size cap lifts to this
  /// value — LAN bandwidth + chunk size aren't constrained by the relay's
  /// envelope cap, and the user explicitly opted into LAN-only mode.
  static const int maxLanAttachmentSizeBytes = 2 * 1024 * 1024 * 1024;

  static const List<int> debugLanTestSizesMiB = <int>[
    5,
    15,
    30,
    125,
    1000,
    2000,
  ];

  String? get debugFileTestStatus => _debugFileTestStatus;
  bool get debugFileBattleTestEnabled => _debugBuildId != null;
  String? get debugBuildId => _debugBuildId;
  List<DebugFileTestResult> get debugFileTestResults =>
      List<DebugFileTestResult>.unmodifiable(_debugFileTestResults);
  bool get nativeAttachmentCryptoAvailable => _nativeAttachmentCrypto != null;

  /// Returns the cap that applies to attachments destined for [contact]
  /// given its current effective routes. If LAN is the ONLY transport in
  /// the candidate set (either because the user disabled online for the
  /// contact or because no relay/direct-internet route is healthy), the
  /// LAN-unlimited cap applies. Otherwise the standard 30 MB cap holds.
  int effectiveMaxAttachmentSizeFor(ContactRecord contact) {
    final effective = _effectiveTransports(contact);
    final policies = _effectiveTransportPolicies(contact);
    final irohAllowed =
        _transportRegistry?.adapterFor(TransportKind.iroh) != null &&
        contact.hasPinnedIrohIdentity &&
        (policies[TransportKind.iroh] == TransportPolicy.automatic ||
            policies[TransportKind.iroh] == TransportPolicy.preferred);
    if (!effective.lan && !irohAllowed) return maxAttachmentSizeBytes;
    // Selection is allowed while LAN is enabled even if the direct endpoint
    // is temporarily absent. Large sessions enter waitingForLan and never
    // leak file chunks through the online/relay fallback.
    return maxLanAttachmentSizeBytes;
  }

  /// Picks the chunk size to use when slicing a new outbound attachment.
  /// LAN-only contacts get the larger LAN chunk size since their chunk
  /// envelopes never traverse the relay's 256 KB envelope cap.
  int _effectiveChunkSizeFor(ContactRecord contact) {
    final effective = _effectiveTransports(contact);
    if (effective.lan && !effective.online) {
      return _lanAttachmentChunkSize;
    }
    return _attachmentChunkSize;
  }

  /// Maximum number of attachments accepted in one user-triggered batch
  /// (multi-file picker, drag-and-drop, mobile gallery multi-select). Each
  /// file still has to clear `maxAttachmentSizeBytes` individually; the
  /// batch cap caps the per-send fanout so a stray drag with 50+ files
  /// doesn't drown the recipient.
  static const int maxAttachmentsPerSend = 30;

  /// Telegram-style media-group cap: a group of uncaptioned images sent
  /// together renders as one album bubble. Larger batches are split into
  /// multiple albums of this size each.
  static const int maxAttachmentsPerAlbum = 10;

  /// Pause between attachment_offer envelopes WITHIN one album, in ms.
  /// Spreads sender CPU + relay store-rate over the wire so a 6-photo
  /// album doesn't slam the queue.
  static const int albumOfferIntervalMs = 250;

  /// Pause between albums in ms. Slightly longer than the intra-album
  /// interval so the receiver's UI has time to settle before the next
  /// album fans in.
  static const int albumGapIntervalMs = 500;

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
    String? albumId,
    Uint8List? poster,
  }) async {
    return sendAttachmentSource(
      contact: contact,
      source: StagedAttachment(
        id: _randomId('stage'),
        fileName: fileName,
        mimeType: mimeType,
        sizeBytes: bytes.length,
        bytes: bytes,
        poster: poster,
        caption: caption,
      ),
      caption: caption,
      albumId: albumId,
    );
  }

  Future<void> sendAttachmentSource({
    required ContactRecord contact,
    required StagedAttachment source,
    String caption = '',
    String? albumId,
    bool allowOriginalFallback = false,
    bool forceLanOnly = false,
    DebugAttachmentTestSpec? debugTest,
    bool debugUseSourceInPlace = false,
  }) async {
    final me = _requireIdentity();
    if (!contact.canSendOutbound) {
      throw StateError(
        'Cannot send to ${contact.alias} until the identity is verified.',
      );
    }
    if (source.sizeBytes <= 0) {
      throw ArgumentError('Cannot send an empty file.');
    }
    if ((debugTest != null || debugUseSourceInPlace) &&
        (_debugBuildId == null || debugTest?.buildId != _debugBuildId)) {
      throw StateError('Automatic file tests require this exact debug build.');
    }
    final perContactCap = effectiveMaxAttachmentSizeFor(contact);
    if (source.sizeBytes > perContactCap) {
      final mb = perContactCap ~/ (1024 * 1024);
      throw ArgumentError(
        'Attachment exceeds the $mb MB cap for this contact.',
      );
    }

    final attachmentId = _randomId('att');
    final requiresLan =
        forceLanOnly || source.sizeBytes > maxAttachmentSizeBytes;
    final chunkSize = requiresLan
        ? _lanAttachmentChunkSize
        : _effectiveChunkSizeFor(contact);
    final chunkCount = (source.sizeBytes + chunkSize - 1) ~/ chunkSize;
    final attachmentKey = SecretKeyData.random(length: 32);
    final noncePrefix = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final createdAt = DateTime.now().toUtc();
    final provisionalDescriptor = AttachmentDescriptor(
      id: attachmentId,
      fileName: sanitizeAttachmentFileName(source.fileName),
      mimeType: sanitizeAttachmentMimeType(source.mimeType),
      sizeBytes: source.sizeBytes,
      chunkSize: chunkSize,
      chunkHashes: const <ChunkHash>[],
      chunkCount: chunkCount,
      fileHashBase64: base64Encode(Uint8List(32)),
      encryptionKeyBase64: base64Encode(await attachmentKey.extractBytes()),
      protocolVersion: 2,
      noncePrefixBase64: base64Encode(noncePrefix),
      presentation: source.presentation,
      thumbnailBase64:
          source.poster != null && source.poster!.length <= 32 * 1024
          ? base64Encode(source.poster!)
          : null,
      createdAt: createdAt,
    );

    var message = ChatMessage(
      id: _randomId('msg'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      body: caption.length <= 4096 ? caption : caption.substring(0, 4096),
      outbound: true,
      state: DeliveryState.pending,
      createdAt: createdAt,
      attachment: provisionalDescriptor,
      albumId: albumId,
    );
    _upsertMessage(contact.deviceId, message);
    _preparationProgressBytes[attachmentId] = 0;
    _upsertTransferSession(
      TransferSession(
        id: attachmentId,
        attachment: provisionalDescriptor,
        peerDeviceIds: <String>[contact.deviceId],
        state: TransferState.preparing,
        completedChunks: const <int>[],
        createdAt: createdAt,
        updatedAt: _now().toUtc(),
        direction: TransferDirection.outbound,
        messageId: message.id,
        sourceKind: TransferSourceKind.privateSpool,
        sourceSizeBytes: source.sizeBytes,
        requiresLan: requiresLan,
        lanOnly: forceLanOnly,
      ),
    );
    await _saveSnapshotSilently(notify: true);

    final _PreparedAttachmentSource prepared;
    try {
      prepared = await _prepareOutboundAttachmentSource(
        attachmentId: attachmentId,
        source: source,
        allowOriginalFallback: allowOriginalFallback,
        preferOriginalSource: debugUseSourceInPlace,
        onProgress: (bytes) {
          _preparationProgressBytes[attachmentId] = bytes;
          notifyListeners();
        },
      );
    } catch (_) {
      _preparationProgressBytes.remove(attachmentId);
      _removeTransferSession(attachmentId);
      _deleteMessage(contact.deviceId, message.id);
      await _saveSnapshotSilently(notify: true);
      rethrow;
    }
    _preparationProgressBytes.remove(attachmentId);
    _locallyAvailableAttachments.add(attachmentId);
    final descriptor = AttachmentDescriptor(
      id: provisionalDescriptor.id,
      fileName: provisionalDescriptor.fileName,
      mimeType: provisionalDescriptor.mimeType,
      sizeBytes: prepared.sizeBytes,
      chunkSize: provisionalDescriptor.chunkSize,
      chunkHashes: const <ChunkHash>[],
      chunkCount: provisionalDescriptor.chunkCount,
      fileHashBase64: prepared.fileHashBase64,
      encryptionKeyBase64: provisionalDescriptor.encryptionKeyBase64,
      protocolVersion: 2,
      noncePrefixBase64: provisionalDescriptor.noncePrefixBase64,
      presentation: provisionalDescriptor.presentation,
      thumbnailBase64: provisionalDescriptor.thumbnailBase64,
      createdAt: createdAt,
    );
    message = message.copyWith(attachment: descriptor);
    _upsertMessage(contact.deviceId, message);
    _outboundAttachments[attachmentId] = _OutboundAttachmentState(
      messageId: message.id,
      peerDeviceId: contact.deviceId,
      sourcePath: prepared.path,
      sourceKind: prepared.sourceKind,
      descriptor: descriptor,
      requiresLan: requiresLan,
      lanOnly: forceLanOnly,
    );
    if (debugTest != null) {
      _outboundDebugAttachmentTests[attachmentId] = debugTest;
    }
    // Stash the video poster (if any) so the sender's own bubble can
    // render the same thumbnail the receiver sees.
    if (source.poster != null && source.poster!.isNotEmpty) {
      _videoPosters[attachmentId] = source.poster!;
    }
    _upsertTransferSession(
      TransferSession(
        id: attachmentId,
        attachment: descriptor,
        peerDeviceIds: <String>[contact.deviceId],
        state: requiresLan && !_hasUsableLargeDirectTransport(contact)
            ? TransferState.waitingForLan
            : TransferState.pending,
        completedChunks: const <int>[],
        createdAt: descriptor.createdAt,
        updatedAt: _now().toUtc(),
        direction: TransferDirection.outbound,
        messageId: message.id,
        relativePath: prepared.relativePath,
        sourceKind: prepared.sourceKind,
        sourcePath: prepared.sourceKind == TransferSourceKind.originalPath
            ? prepared.path
            : null,
        sourceSizeBytes: prepared.sizeBytes,
        sourceModifiedAt: prepared.sourceModifiedAt,
        requiresLan: requiresLan,
        lanOnly: forceLanOnly,
      ),
    );
    _markRuntimeActivity();
    await _saveSnapshotSilently(notify: true);

    // Enqueue for this contact's serial transfer worker. The worker
    // dispatches the offer envelope when the previous outbound for the
    // same contact finishes — or immediately if the queue was empty.
    _enqueueOutbound(contact, attachmentId);
    _pumpOutboundQueue(contact);
  }

  /// Generates an app-owned deterministic file and sends it through the
  /// normal attachment-v2 preparation, encryption, LAN HTTP, journaling, and
  /// final-hash path. Payload blocks are LAN-only so a successful run cannot
  /// be mistaken for a Conest/Iroh relay success. The offer/control envelope
  /// may still use any enabled route so the test can bootstrap the LAN hint.
  Future<void> runLanAttachmentDiagnostic({
    required ContactRecord contact,
    required int sizeMiB,
  }) async {
    final testId = _randomId('lantest');
    final target = await _generateDebugAttachmentSource(
      testId: testId,
      sizeMiB: sizeMiB,
      needsSpoolCopy: true,
    );
    try {
      _debugFileTestStatus =
          'Preparing and hashing $sizeMiB MiB through the normal sender path…';
      notifyListeners();
      await sendAttachmentSource(
        contact: contact,
        source: StagedAttachment(
          id: testId,
          fileName: 'conest-lan-test-${sizeMiB}MiB.bin',
          mimeType: 'application/x-conest-transfer-test',
          sizeBytes: sizeMiB * 1024 * 1024,
          filePath: target.path,
          caption:
              'Conest LAN transfer diagnostic · $sizeMiB MiB · final SHA-256 required',
        ),
        caption:
            'Conest LAN transfer diagnostic · $sizeMiB MiB · final SHA-256 required',
        forceLanOnly: true,
      );
      _debugFileTestStatus =
          '$sizeMiB MiB LAN test queued for ${contact.alias}. '
          'Press Download on the receiving device.';
      appendDebugLog(_debugFileTestStatus!);
    } finally {
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      notifyListeners();
    }
  }

  /// Runs an end-to-end file transfer without receiver interaction. Both
  /// peers must advertise the exact same debug build token. The receiver
  /// auto-accepts only this authenticated diagnostic marker, verifies the
  /// production final SHA-256, reports the result, and deletes test data.
  Future<DebugFileTestResult> runDebugFileBattleTest({
    required ContactRecord contact,
    required int sizeMiB,
  }) async {
    final buildId = _debugBuildId;
    if (buildId == null) {
      throw StateError('Automatic file battle tests are debug-build only.');
    }
    _validateDebugFileTestTarget(contact, sizeMiB);
    final testId = _randomId('filetest');
    _debugFileTestStatus =
        'Checking that ${contact.alias} is on this exact debug build…';
    notifyListeners();
    final irohOnly = !_effectiveTransports(contact).lan;
    await _probeDebugFileTestPeer(contact, testId, buildId, irohOnly: irohOnly);
    final startedAt = _now().toUtc();
    final spec = DebugAttachmentTestSpec(
      testId: testId,
      buildId: buildId,
      sizeMiB: sizeMiB,
      startedAt: startedAt,
      irohOnly: irohOnly,
    );
    final resultCompleter = Completer<DebugFileTestResult>();
    final target = await _generateDebugAttachmentSource(
      testId: testId,
      sizeMiB: sizeMiB,
      needsSpoolCopy: false,
    );
    _debugFileResultCompleters[testId] = resultCompleter;
    try {
      _debugFileTestStatus =
          'Hashing and sending $sizeMiB MiB to ${contact.alias}; '
          'the peer will accept and verify automatically…';
      notifyListeners();
      await sendAttachmentSource(
        contact: contact,
        source: StagedAttachment(
          id: testId,
          fileName: 'conest-debug-test-${sizeMiB}MiB.bin',
          mimeType: 'application/x-conest-transfer-test',
          sizeBytes: sizeMiB * 1024 * 1024,
          filePath: target.path,
          caption: 'Conest automatic debug transfer · $sizeMiB MiB',
        ),
        caption: 'Conest automatic debug transfer · $sizeMiB MiB',
        forceLanOnly: !irohOnly,
        debugTest: spec,
        debugUseSourceInPlace: true,
      );
      final timeoutMinutes = max(5, (sizeMiB / 60).ceil() + 2);
      final result = await resultCompleter.future.timeout(
        Duration(minutes: timeoutMinutes),
        onTimeout: () => DebugFileTestResult(
          testId: testId,
          attachmentId: '',
          peerDeviceId: contact.deviceId,
          sizeMiB: sizeMiB,
          success: false,
          startedAt: startedAt,
          completedAt: _now().toUtc(),
          detail: 'Timed out waiting for the peer verification result.',
        ),
      );
      if (!_debugFileTestResults.any((entry) => entry.testId == testId)) {
        _debugFileTestResults.insert(0, result);
        if (_debugFileTestResults.length > 20) {
          _debugFileTestResults.removeRange(20, _debugFileTestResults.length);
        }
      }
      _debugFileTestStatus = result.success
          ? '$sizeMiB MiB passed with exact hash in '
                '${result.elapsed.inSeconds}s '
                '(${result.mebibytesPerSecond?.toStringAsFixed(1) ?? "?"} MiB/s).'
          : '$sizeMiB MiB failed: ${result.detail ?? "unknown error"}';
      appendDebugLog(_debugFileTestStatus!);
      await _cleanupOutboundDebugTest(testId);
      notifyListeners();
      return result;
    } finally {
      _debugFileResultCompleters.remove(testId);
      await _cleanupOutboundDebugTest(testId);
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
    }
  }

  Future<List<DebugFileTestResult>> runDebugFileBattleTestMatrix({
    required ContactRecord contact,
  }) async {
    final results = <DebugFileTestResult>[];
    for (final sizeMiB in debugLanTestSizesMiB) {
      final result = await runDebugFileBattleTest(
        contact: contact,
        sizeMiB: sizeMiB,
      );
      results.add(result);
      if (!result.success) break;
    }
    return List<DebugFileTestResult>.unmodifiable(results);
  }

  void _validateDebugFileTestTarget(ContactRecord contact, int sizeMiB) {
    if (!debugLanTestSizesMiB.contains(sizeMiB)) {
      throw ArgumentError('Unsupported diagnostic size: $sizeMiB MiB.');
    }
    if (!contact.canSendOutbound) {
      throw StateError('Select a verified contact for the file diagnostic.');
    }
    if (!_effectiveTransports(contact).lan && !_canUseIrohForContact(contact)) {
      throw StateError('Enable LAN or Iroh for ${contact.alias}.');
    }
  }

  Future<File> _generateDebugAttachmentSource({
    required String testId,
    required int sizeMiB,
    required bool needsSpoolCopy,
  }) async {
    final sizeBytes = sizeMiB * 1024 * 1024;
    if (sizeBytes > maxLanAttachmentSizeBytes) {
      throw ArgumentError('Diagnostic exceeds the 2 GiB LAN limit.');
    }
    final root = await _attachmentRoot();
    final capacity = await _storageCapacityProvider(root.path);
    final requiredBytes = needsSpoolCopy ? sizeBytes * 2 : sizeBytes;
    if (!_canAllocateStorage(capacity, requiredBytes)) {
      throw AttachmentSpoolException(
        _storageReserveFraction == 0
            ? 'Not enough free storage for the diagnostic file.'
            : needsSpoolCopy
            ? 'Not enough storage for the diagnostic source and immutable spool while keeping 10% free.'
            : 'Not enough storage for the debug test source while keeping 10% free.',
      );
    }
    final diagnosticDir = Directory(p.join(root.path, 'diagnostics'));
    await diagnosticDir.create(recursive: true);
    final target = File(p.join(diagnosticDir.path, '$testId.bin'));
    final temporary = File('${target.path}.tmp');
    _debugFileTestStatus = 'Generating $sizeMiB MiB test file…';
    notifyListeners();
    try {
      await temporary.create(recursive: true);
      await restrictFileToOwner(temporary);
      final pattern = Uint8List(1024 * 1024);
      for (var index = 0; index < pattern.length; index++) {
        pattern[index] = (index * 31 + sizeMiB * 17) & 0xff;
      }
      final sink = temporary.openWrite(mode: FileMode.writeOnly);
      var written = 0;
      try {
        while (written < sizeBytes) {
          final remaining = sizeBytes - written;
          final count = min(pattern.length, remaining);
          sink.add(
            count == pattern.length ? pattern : pattern.sublist(0, count),
          );
          written += count;
          if (written == sizeBytes || written % (32 * 1024 * 1024) == 0) {
            _debugFileTestStatus =
                'Generating $sizeMiB MiB test file: '
                '${(written * 100 / sizeBytes).toStringAsFixed(0)}%';
            notifyListeners();
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      await temporary.rename(target.path);
      return target;
    } catch (_) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<_PreparedAttachmentSource> _prepareOutboundAttachmentSource({
    required String attachmentId,
    required StagedAttachment source,
    required bool allowOriginalFallback,
    bool preferOriginalSource = false,
    void Function(int bytes)? onProgress,
  }) async {
    final root = await _attachmentRoot();
    final spoolDir = Directory(p.join(root.path, 'spool'));
    await spoolDir.create(recursive: true);
    final storageKey = attachmentStorageKey(attachmentId);
    final relativePath = p.join('spool', '$storageKey.bin');
    final target = File(p.join(root.path, relativePath));
    final originalPath = source.filePath;
    if (preferOriginalSource && originalPath != null) {
      final original = File(originalPath);
      final normalizedRoot = p.normalize(p.absolute(root.path));
      final normalizedOriginal = p.normalize(p.absolute(original.path));
      if (!p.isWithin(normalizedRoot, normalizedOriginal)) {
        throw AttachmentSpoolException(
          'Debug source-in-place is limited to app-owned storage.',
        );
      }
      final stat = await original.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != source.sizeBytes) {
        throw AttachmentSpoolException('The diagnostic source file changed.');
      }
      var hashed = 0;
      final digestOutput = _SingleDigestSink();
      final digestInput = dart_crypto.sha256.startChunkedConversion(
        digestOutput,
      );
      await for (final chunk in original.openRead()) {
        hashed += chunk.length;
        digestInput.add(chunk);
        onProgress?.call(hashed);
      }
      digestInput.close();
      final digest = digestOutput.value;
      if (hashed != stat.size || digest == null) {
        throw AttachmentSpoolException('The diagnostic source file changed.');
      }
      return _PreparedAttachmentSource(
        path: original.path,
        relativePath: p.relative(normalizedOriginal, from: normalizedRoot),
        // Generated diagnostics are immutable app-owned spool data. Treating
        // them as external originals made a harmless filesystem timestamp
        // change after process restart permanently fail the transfer.
        sourceKind: TransferSourceKind.privateSpool,
        sizeBytes: stat.size,
        fileHashBase64: base64Encode(digest.bytes),
        sourceModifiedAt: stat.modified,
      );
    }
    final capacity = await _storageCapacityProvider(root.path);
    final canSpool = _canAllocateStorage(capacity, source.sizeBytes);
    Object? spoolError;
    if (canSpool) {
      final temporary = File('${target.path}.tmp');
      try {
        var written = 0;
        final digestOutput = _SingleDigestSink();
        final digestInput = dart_crypto.sha256.startChunkedConversion(
          digestOutput,
        );
        await temporary.create(recursive: true);
        await restrictFileToOwner(temporary);
        final sink = temporary.openWrite(mode: FileMode.writeOnly);
        try {
          await for (final chunk in source.openRead()) {
            written += chunk.length;
            if (written > source.sizeBytes) {
              throw const FormatException(
                'Attachment source grew while copying.',
              );
            }
            sink.add(chunk);
            digestInput.add(chunk);
            onProgress?.call(written);
          }
          await sink.flush();
        } finally {
          await sink.close();
          digestInput.close();
        }
        if (written != source.sizeBytes) {
          throw const FormatException(
            'Attachment source size changed while copying.',
          );
        }
        await temporary.rename(target.path);
        final digest = digestOutput.value;
        if (digest == null) {
          throw const FormatException('Attachment hashing did not complete.');
        }
        return _PreparedAttachmentSource(
          path: target.path,
          relativePath: relativePath,
          sourceKind: TransferSourceKind.privateSpool,
          sizeBytes: written,
          fileHashBase64: base64Encode(digest.bytes),
          sourceModifiedAt: await target.lastModified(),
        );
      } catch (error) {
        spoolError = error;
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    }
    if (!allowOriginalFallback || originalPath == null) {
      throw AttachmentSpoolException(
        canSpool
            ? 'Could not create a private attachment spool: $spoolError'
            : _storageReserveFraction > 0
            ? 'Not enough storage to keep the required 10% free-space reserve.'
            : 'Not enough free storage to prepare this file.',
        canUseOriginal: originalPath != null,
      );
    }
    final original = File(originalPath);
    final stat = await original.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size != source.sizeBytes) {
      throw AttachmentSpoolException('The selected source file changed.');
    }
    final digest = await dart_crypto.sha256.bind(original.openRead()).first;
    return _PreparedAttachmentSource(
      path: original.path,
      relativePath: '',
      sourceKind: TransferSourceKind.originalPath,
      sizeBytes: stat.size,
      fileHashBase64: base64Encode(digest.bytes),
      sourceModifiedAt: stat.modified,
    );
  }

  bool _hasUsableLanDirectEndpoint(String deviceId) {
    final endpoint = _peerLanDirect[deviceId];
    return endpoint != null && _lanDirectEndpointUsable(endpoint);
  }

  void _upsertTransferSession(TransferSession session) {
    final sessions = List<TransferSession>.from(_snapshot.transferSessions);
    final index = sessions.indexWhere((entry) => entry.id == session.id);
    if (index < 0) {
      sessions.add(session);
    } else {
      sessions[index] = session;
    }
    _snapshot = _snapshot.copyWith(transferSessions: sessions);
  }

  TransferSession? _transferSessionById(String attachmentId) => _snapshot
      .transferSessions
      .where((entry) => entry.id == attachmentId)
      .firstOrNull;

  void _setTransferSessionState(
    String attachmentId,
    TransferState state, {
    String? error,
    bool storageReserveBlocked = false,
  }) {
    final session = _transferSessionById(attachmentId);
    if (session == null) return;
    _upsertTransferSession(
      session.copyWith(
        state: state,
        updatedAt: _now().toUtc(),
        lastError: error,
        clearLastError: error == null,
        storageReserveBlocked: storageReserveBlocked,
      ),
    );
    if (state == TransferState.failed || state == TransferState.canceled) {
      _completeDebugFileTestFromLocalFailure(
        attachmentId,
        error ??
            (state == TransferState.canceled
                ? 'The local transfer was canceled.'
                : 'The local transfer failed.'),
      );
    }
    unawaited(_saveSnapshotSilently(notify: true, debounce: true));
  }

  void _completeDebugFileTestFromLocalFailure(
    String attachmentId,
    String detail,
  ) {
    final spec = _outboundDebugAttachmentTests[attachmentId];
    if (spec == null) return;
    final completer = _debugFileResultCompleters[spec.testId];
    if (completer == null || completer.isCompleted) return;
    final outbound = _outboundAttachments[attachmentId];
    final result = DebugFileTestResult(
      testId: spec.testId,
      attachmentId: attachmentId,
      peerDeviceId: outbound?.peerDeviceId ?? '',
      sizeMiB: spec.sizeMiB,
      success: false,
      startedAt: spec.startedAt,
      completedAt: _now().toUtc(),
      detail: detail,
    );
    _debugFileTestStatus = '${spec.sizeMiB} MiB failed: $detail';
    appendDebugLog(
      'Automatic file test ${spec.testId} failed locally for '
      '$attachmentId: $detail',
    );
    completer.complete(result);
  }

  void _setTransferSessionPause(
    String attachmentId, {
    bool? pausedByMe,
    bool? pausedByPeer,
  }) {
    final session = _transferSessionById(attachmentId);
    if (session == null) return;
    final nextPausedByMe = pausedByMe ?? session.pausedByMe;
    final nextPausedByPeer = pausedByPeer ?? session.pausedByPeer;
    _upsertTransferSession(
      session.copyWith(
        state: nextPausedByMe || nextPausedByPeer
            ? TransferState.paused
            : TransferState.reconnecting,
        pausedByMe: nextPausedByMe,
        pausedByPeer: nextPausedByPeer,
        updatedAt: _now().toUtc(),
        clearLastError: true,
      ),
    );
  }

  void _removeTransferSession(String attachmentId) {
    _snapshot = _snapshot.copyWith(
      transferSessions: _snapshot.transferSessions
          .where((entry) => entry.id != attachmentId)
          .toList(growable: false),
    );
  }

  /// Pushes an attachmentId onto the contact's serial-send queue. Idempotent
  /// guard against duplicate enqueues.
  void _enqueueOutbound(ContactRecord contact, String attachmentId) {
    final queue = _outboundQueueByContact.putIfAbsent(
      contact.deviceId,
      () => <String>[],
    );
    if (!queue.contains(attachmentId) &&
        _activeOutboundByContact[contact.deviceId] != attachmentId) {
      queue.add(attachmentId);
    }
  }

  /// If no transfer is currently active for [contact], pops the head of the
  /// queue and dispatches its offer envelope. Called from sendAttachment
  /// after enqueue + from attachment_complete / cancel / delete cleanup.
  void _pumpOutboundQueue(ContactRecord contact) {
    if (_activeOutboundByContact.containsKey(contact.deviceId)) return;
    final queue = _outboundQueueByContact[contact.deviceId];
    if (queue == null || queue.isEmpty) return;
    final next = queue.removeAt(0);
    final state = _outboundAttachments[next];
    if (state == null) {
      // Sender-side cancel happened between enqueue + pump. Move on.
      _pumpOutboundQueue(contact);
      return;
    }
    final wasIdle = !hasActiveTransfer;
    _activeOutboundByContact[contact.deviceId] = next;
    state.activatedAt = DateTime.now().toUtc();
    state.lastChunkAt = state.activatedAt;
    _armOutboundStallTimer(contact);
    if (wasIdle) _reschedulePolling();
    unawaited(_dispatchAttachmentOffer(contact, state));
    notifyListeners();
  }

  /// Encrypts + delivers the attachment_offer envelope for [state]. On
  /// failure the active slot is freed and the local message flips to
  /// Failed; the next queued item gets a chance to dispatch.
  Future<void> _dispatchAttachmentOffer(
    ContactRecord contact,
    _OutboundAttachmentState state,
  ) async {
    if (!hasIdentity) return;
    final me = _requireIdentity();
    final descriptor = state.descriptor;
    final message = _messageById(contact.deviceId, state.messageId);
    if (message == null) {
      // Parent ChatMessage was deleted between enqueue + dispatch.
      _outboundAttachments.remove(descriptor.id);
      _clearActiveOutbound(contact.deviceId, descriptor.id);
      _pumpOutboundQueue(contact);
      return;
    }
    // nightly.10: embed our LAN-direct endpoint hint in the offer so the
    // receiver can issue chunk_requests directly via HTTP from the very
    // first chunk — no relay round-trip required even for the request
    // direction. Empty map when the LAN-direct channel isn't available
    // (web, sandboxed CI), so peers gracefully fall back to relay.
    final lanHint = _localLanDirectHintPayload();
    final debugTest = _outboundDebugAttachmentTests[descriptor.id];
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
        'caption': message.body,
        if (message.albumId != null) 'albumId': message.albumId,
        // Video poster (small JPEG thumbnail) so the receiver can render
        // a preview before the full video bytes finish transferring.
        // Capped at ~32 KB at the sender to keep the offer envelope
        // under the relay's 256 KB cap.
        if (_videoPosters[descriptor.id] != null &&
            _videoPosters[descriptor.id]!.length <= 32 * 1024)
          'posterBase64': base64Encode(_videoPosters[descriptor.id]!),
        if (debugTest != null) 'debugFileTest': debugTest.toJson(),
        ...lanHint,
      }),
      createdAt: message.createdAt,
    );
    try {
      final route = await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: envelope,
        allowRelayedPaths: debugTest?.irohOnly != true,
        allowLegacyRoutes: debugTest?.irohOnly != true,
        allowedUnifiedKinds: debugTest?.irohOnly == true
            ? {TransportKind.iroh}
            : null,
      );
      _updateMessageState(
        contact.deviceId,
        message.id,
        route.kind == PeerRouteKind.lan
            ? DeliveryState.local
            : DeliveryState.relayed,
        route: route,
      );
    } catch (error) {
      _statusMessage = 'Attachment is waiting for a route: $error';
      appendDebugLog(
        'sendAttachment offer failed for ${descriptor.id} '
        '(${descriptor.fileName}): $error',
      );
      _scheduleOutboundReconnect(contact, state, error.toString());
    }
  }

  void _armOutboundStallTimer(ContactRecord contact) {
    _outboundStallTimers[contact.deviceId]?.cancel();
    _outboundStallTimers[contact.deviceId] = Timer(
      _outboundStallTimeout,
      () => _onOutboundStall(contact),
    );
  }

  static const List<Duration> _transferRetryBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  // A 4 MiB authenticated block routinely takes more than one second to
  // encrypt, upload, decrypt, and journal on older Android devices. The old
  // generic 1 s retry timer cleared the whole request window while healthy
  // blocks were still in flight, producing an endless
  // "downloaded a little → reconnecting" loop.
  static const List<Duration> _inboundTransferRetryBackoff = <Duration>[
    Duration(seconds: 30),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  void _scheduleOutboundReconnect(
    ContactRecord contact,
    _OutboundAttachmentState state,
    String reason,
  ) {
    state.autoRetries = min(state.autoRetries + 1, 1 << 20);
    final delay =
        _transferRetryBackoff[min(
          state.autoRetries - 1,
          _transferRetryBackoff.length - 1,
        )];
    state.nextRetryAt = DateTime.now().toUtc().add(delay);
    _setTransferSessionState(
      state.descriptor.id,
      TransferState.reconnecting,
      error: reason,
    );
    _updateMessageState(
      contact.deviceId,
      state.messageId,
      DeliveryState.pending,
    );
    _clearActiveOutbound(contact.deviceId, state.descriptor.id);
    _enqueueOutbound(contact, state.descriptor.id);
    _outboundStallTimers[contact.deviceId]?.cancel();
    _outboundStallTimers[contact.deviceId] = Timer(delay, () {
      state.nextRetryAt = null;
      _pumpOutboundQueue(contact);
    });
    notifyListeners();
  }

  void _onOutboundStall(ContactRecord contact) {
    final activeId = _activeOutboundByContact[contact.deviceId];
    if (activeId == null) return;
    final state = _outboundAttachments[activeId];
    if (state == null) {
      _clearActiveOutbound(contact.deviceId, activeId);
      _pumpOutboundQueue(contact);
      return;
    }
    // If the transfer is paused, keep waiting — pause is explicit, not a
    // stall. The timer rearms on resume so we don't lose the escape hatch.
    if (state.paused) {
      _armOutboundStallTimer(contact);
      return;
    }
    appendDebugLog(
      'Outbound stall for ${state.descriptor.id} '
      '(${state.descriptor.fileName}) after ${_outboundStallTimeout.inSeconds}s; '
      'keeping the resumable session and backing off.',
    );
    _scheduleOutboundReconnect(
      contact,
      state,
      'No verified block acknowledgement for ${_outboundStallTimeout.inSeconds} seconds.',
    );
  }

  void _clearActiveOutbound(String peerDeviceId, String attachmentId) {
    if (_activeOutboundByContact[peerDeviceId] == attachmentId) {
      _activeOutboundByContact.remove(peerDeviceId);
      _outboundStallTimers.remove(peerDeviceId)?.cancel();
      // Drop back to idle cadence if no transfer is in flight anywhere.
      if (!hasActiveTransfer) _reschedulePolling();
    }
  }

  /// Returns the queue position of [attachmentId] for its contact. Returns
  /// 0 when not queued (either active or unknown), positive integer for
  /// queued items (1 = next to dispatch).
  int outboundQueuePositionFor(String attachmentId) {
    for (final entry in _outboundQueueByContact.entries) {
      final idx = entry.value.indexOf(attachmentId);
      if (idx >= 0) return idx + 1;
    }
    return 0;
  }

  /// Returns the sender-side transfer progress (0..1) for an active outbound
  /// attachment, or null if the attachment isn't currently active (queued,
  /// finished, or unknown). UI uses null to mean "show queued/idle status
  /// instead of a progress bar".
  double? outboundAttachmentProgress(String attachmentId) {
    final state = _outboundAttachments[attachmentId];
    if (state == null) return null;
    // Only show progress for the active item per contact.
    if (_activeOutboundByContact[state.peerDeviceId] != attachmentId) {
      return null;
    }
    final total = state.descriptor.effectiveChunkCount;
    if (total <= 0) return null;
    // Prefer the receiver-reported count (`peerReceivedCount`) so the
    // sender's bubble shows the SAME percentage as the receiver's — fixes
    // the nightly.7 desync. Fall back to our own ship-count for very
    // small transfers that finish before the first progress envelope.
    final peerBytes = state.peerReceivedBytes;
    if (peerBytes != null) {
      return peerBytes / state.descriptor.sizeBytes;
    }
    final peer = state.peerReceivedCount;
    if (peer != null) return peer / total;
    return (state.highestChunkSent + 1) / total;
  }

  TransferSnapshot? transferSnapshotFor(String attachmentId) {
    ChatMessage? message;
    for (final conversation in _snapshot.conversations) {
      message = conversation.messages
          .where((entry) => entry.attachment?.id == attachmentId)
          .firstOrNull;
      if (message != null) break;
    }
    if (message == null || message.attachment == null) return null;
    final descriptor = message.attachment!;
    final session = _transferSessionById(attachmentId);
    final outbound = _outboundAttachments[attachmentId];
    final inbound = _inboundAttachments[attachmentId];
    final pause = pauseStateFor(attachmentId);
    final int bytes =
        _preparationProgressBytes[attachmentId] ??
        outbound?.peerReceivedBytes ??
        inbound?.receivedBytes ??
        session?.bytesTransferred ??
        (attachmentAvailableLocally(attachmentId) ? descriptor.sizeBytes : 0);
    final speed = outbound?.bytesPerSecond ?? inbound?.bytesPerSecond;
    final remaining = max(0, descriptor.sizeBytes - bytes);
    final eta = speed != null && speed > 1
        ? Duration(seconds: (remaining / speed).ceil())
        : null;
    final route = outbound?.lastDeliveryRoute;
    final (transport, path, routeLabel) = switch (route) {
      OutboundDeliveryRoute.lanDirect => (
        TransportKind.lan,
        TransportPathKind.local,
        'LAN',
      ),
      OutboundDeliveryRoute.irohDirect => (
        TransportKind.iroh,
        TransportPathKind.direct,
        'Direct online',
      ),
      OutboundDeliveryRoute.irohRelay => (
        TransportKind.iroh,
        TransportPathKind.relayed,
        'Iroh relay',
      ),
      OutboundDeliveryRoute.conestRelay => (
        TransportKind.conestRelay,
        TransportPathKind.storeForward,
        'Conest relay',
      ),
      _ => (
        message.transportKind,
        message.transportPath,
        message.transportDetail,
      ),
    };
    final phase = pause != null && (pause.pausedByMe || pause.pausedByPeer)
        ? TransferPhase.paused
        : inbound?.awaitingAcceptance == true
        ? TransferPhase.awaitingApproval
        : switch (session?.state) {
            TransferState.preparing => TransferPhase.preparing,
            TransferState.queued => TransferPhase.queued,
            TransferState.transferring => TransferPhase.transferring,
            TransferState.reconnecting => TransferPhase.reconnecting,
            TransferState.paused => TransferPhase.paused,
            TransferState.completed => TransferPhase.completed,
            TransferState.failed => TransferPhase.failed,
            TransferState.canceled => TransferPhase.canceled,
            TransferState.waitingForLan ||
            TransferState.pending => TransferPhase.waitingForPeer,
            TransferState.waitingForStorage => TransferPhase.awaitingApproval,
            null when attachmentAvailableLocally(attachmentId) =>
              TransferPhase.completed,
            null when message.state == DeliveryState.failed =>
              TransferPhase.failed,
            null when message.state == DeliveryState.canceled =>
              TransferPhase.canceled,
            null => TransferPhase.unavailable,
          };
    return TransferSnapshot(
      id: attachmentId,
      phase: phase,
      direction: message.outbound
          ? TransferDirection.outbound
          : TransferDirection.inbound,
      bytesTransferred: bytes,
      totalBytes: descriptor.sizeBytes,
      bytesPerSecond: speed,
      eta: eta,
      queuePriority: outboundQueuePositionFor(attachmentId),
      transport: transport,
      path: path,
      routeLabel: routeLabel,
      pausedByMe: pause?.pausedByMe ?? false,
      pausedByPeer: pause?.pausedByPeer ?? false,
      retryAt: outbound?.nextRetryAt ?? inbound?.nextRetryAt,
      error: session?.lastError,
    );
  }

  List<TransferSnapshot> get transferSnapshots {
    final seen = <String>{};
    final snapshots = <TransferSnapshot>[];
    for (final conversation in _snapshot.conversations) {
      for (final message in conversation.messages.reversed) {
        final id = message.attachment?.id;
        if (id == null || _dismissedTransferIds.contains(id) || !seen.add(id)) {
          continue;
        }
        final snapshot = transferSnapshotFor(id);
        if (snapshot != null) snapshots.add(snapshot);
      }
    }
    return List.unmodifiable(snapshots);
  }

  ChatMessage? messageForAttachment(String attachmentId) {
    for (final conversation in _snapshot.conversations) {
      final message = conversation.messages
          .where((entry) => entry.attachment?.id == attachmentId)
          .firstOrNull;
      if (message != null) return message;
    }
    return null;
  }

  AttachmentDescriptor? attachmentDescriptorFor(String attachmentId) =>
      messageForAttachment(attachmentId)?.attachment;

  @visibleForTesting
  String inboundTransferDebugForTesting(String attachmentId) {
    final state = _inboundAttachments[attachmentId];
    if (state == null) return 'missing';
    return 'accepted=${state.accepted},awaiting=${state.awaitingAcceptance},'
        'partial=${state.partialPath},received=${state.received.length},'
        'requested=${state.requestedInFlight.length},paused=${state.paused},'
        'retry=${state.retryAttempts}';
  }

  String? peerDeviceIdForAttachment(String attachmentId) {
    final message = messageForAttachment(attachmentId);
    if (message == null) return null;
    return message.outbound
        ? message.recipientDeviceId
        : message.senderDeviceId;
  }

  String transferConversationLabel(String attachmentId) {
    final peerId = peerDeviceIdForAttachment(attachmentId);
    if (peerId == null) return 'Conversation';
    return _contactByDeviceId(peerId)?.alias ?? 'Conversation';
  }

  Future<void> pauseAllTransfers() async {
    final ids = transferSnapshots
        .where((entry) => entry.phase.isActive && !entry.pausedByPeer)
        .map((entry) => entry.id)
        .toList(growable: false);
    for (final id in ids) {
      await pauseAttachment(id);
    }
  }

  Future<void> resumeAllTransfers() async {
    final ids = transferSnapshots
        .where((entry) => entry.pausedByMe)
        .map((entry) => entry.id)
        .toList(growable: false);
    for (final id in ids) {
      await resumeAttachment(id);
    }
  }

  void prioritizeTransfer(String attachmentId) {
    for (final entry in _outboundQueueByContact.entries) {
      final index = entry.value.indexOf(attachmentId);
      if (index <= 0) continue;
      entry.value
        ..removeAt(index)
        ..insert(0, attachmentId);
      _setTransferSessionState(attachmentId, TransferState.queued);
      notifyListeners();
      return;
    }
  }

  bool _managedIrohRelayAllowsBulk() {
    final connectivity = _snapshot.identity?.connectivity;
    return connectivity != null &&
        connectivity.irohRelayEnabled &&
        connectivity.irohRelayUrls.isNotEmpty &&
        connectivity.irohCustomRelaysBulkCapable;
  }

  bool _largeIrohRelayAllowed(String attachmentId) {
    final session = _transferSessionById(attachmentId);
    return session?.allowIrohRelay == true || _managedIrohRelayAllowsBulk();
  }

  /// Whether the transfer manager should offer an explicit, per-transfer
  /// override for an unknown/free Iroh relay. Durable Conest relays remain
  /// excluded for payload blocks above their 30 MiB attachment cap.
  bool canContinueLargeTransferOverIrohRelay(String attachmentId) {
    final outbound = _outboundAttachments[attachmentId];
    final session = _transferSessionById(attachmentId);
    if (outbound == null ||
        session == null ||
        !outbound.requiresLan ||
        session.allowIrohRelay ||
        _managedIrohRelayAllowsBulk()) {
      return false;
    }
    final contact = _contactByDeviceId(outbound.peerDeviceId);
    if (contact == null || !contact.hasPinnedIrohIdentity) return false;
    final global = _snapshot.identity?.connectivity;
    if (global == null ||
        !global.onlineEnabled ||
        !global.irohRelayEnabled ||
        !contact.routing.onlineEnabled ||
        !contact.routing.irohRelayEnabled ||
        _transportRegistry?.adapterFor(TransportKind.iroh) == null) {
      return false;
    }
    final policy = _effectiveTransportPolicies(contact)[TransportKind.iroh];
    return policy == TransportPolicy.automatic ||
        policy == TransportPolicy.preferred;
  }

  Future<void> continueLargeTransferOverIrohRelay(String attachmentId) async {
    if (!canContinueLargeTransferOverIrohRelay(attachmentId)) return;
    final state = _outboundAttachments[attachmentId]!;
    final session = _transferSessionById(attachmentId)!;
    final peer = _contactByDeviceId(state.peerDeviceId);
    if (peer == null) return;
    _upsertTransferSession(
      session.copyWith(
        state: TransferState.reconnecting,
        allowIrohRelay: true,
        updatedAt: _now().toUtc(),
        clearLastError: true,
      ),
    );
    state
      ..consecutiveChunkFailures = 0
      ..nextRetryAt = null;
    await _saveSnapshotSilently(notify: true);
    // A resume control makes the receiver immediately refill its request
    // window instead of waiting for the next exponential-retry deadline.
    await _sendAttachmentPauseControl(
      peer: peer,
      attachmentId: attachmentId,
      paused: false,
    );
  }

  void clearCompletedTransfers() {
    for (final snapshot in transferSnapshots) {
      if (snapshot.phase == TransferPhase.completed ||
          snapshot.phase == TransferPhase.canceled) {
        _dismissedTransferIds.add(snapshot.id);
      }
    }
    notifyListeners();
  }

  /// nightly.11: the channel that carried the most recent successful
  /// chunk delivery for this attachment. The bubble overlay renders this
  /// as a small "LAN" / "relay" chip — when LAN-direct is firing the
  /// user sees green "LAN" and knows the fast path works. When something
  /// silently kicks delivery back to relay (Android cleartext block,
  /// peer behind isolation), the chip flips to "relay" and the user can
  /// flag it instead of just feeling "slow".
  OutboundDeliveryRoute lastDeliveryRouteFor(String attachmentId) {
    final state = _outboundAttachments[attachmentId];
    return state?.lastDeliveryRoute ?? OutboundDeliveryRoute.unknown;
  }

  /// True when [attachmentId] recently delivered a chunk via a non-primary
  /// route (LAN failed, relay succeeded — or both consecutive failures).
  /// The bubble's status line prepends "Rerouting · " while this is set.
  /// Window: 5 s after the most recent fallback so a brief flap doesn't
  /// leave the label stuck.
  bool isOutboundReroutingFor(String attachmentId) {
    final state = _outboundAttachments[attachmentId];
    if (state == null) return false;
    final at = state.lastRouteFallbackAt;
    if (at == null) return false;
    return DateTime.now().toUtc().difference(at) < const Duration(seconds: 5);
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

  /// Whether a complete local source/cache exists even when it is too large
  /// to materialize in memory. Large-file UI should use path-based open/save.
  bool attachmentAvailableLocally(String attachmentId) =>
      _locallyAvailableAttachments.contains(attachmentId);

  /// Public accessor for the on-disk attachment root. Used by UI code that
  /// needs to stage temp files alongside the assembled attachments — e.g.
  /// the clipboard-cache directory the image-copy path writes a stable
  /// file:// URI into.
  Future<Directory> attachmentRoot() => _attachmentRoot();

  Future<Directory> _attachmentRoot() async {
    final dir = await (_attachmentRootFuture ??= _attachmentRootProvider());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  final Set<String> _attachmentDiskLoadInFlight = <String>{};

  Future<void> _loadAttachmentBytesFromDisk(String attachmentId) async {
    if (_assembledAttachments.containsKey(attachmentId) ||
        _attachmentDiskLoadInFlight.contains(attachmentId)) {
      return;
    }
    _attachmentDiskLoadInFlight.add(attachmentId);
    try {
      final file = await _attachmentCacheFile(attachmentId);
      if (!await file.exists()) {
        return;
      }
      final size = await file.length();
      if (size > 8 * 1024 * 1024) return;
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
    if (state.descriptor.effectiveChunkCount <= 0) {
      return 0;
    }
    return state.receivedBytes / state.descriptor.sizeBytes;
  }

  bool attachmentAwaitingAcceptance(String attachmentId) =>
      _inboundAttachments[attachmentId]?.awaitingAcceptance ?? false;

  bool attachmentAcceptanceInProgress(String attachmentId) =>
      _acceptingIncomingAttachmentIds.contains(attachmentId);

  bool canDownloadIgnoringStorageReserve(String attachmentId) =>
      _storageReserveFraction > 0 &&
      attachmentAwaitingAcceptance(attachmentId) &&
      (_transferSessionById(attachmentId)?.storageReserveBlocked ?? false);

  Future<void> acceptIncomingAttachment(
    String attachmentId, {
    bool ignoreStorageReserve = false,
  }) async {
    final state = _inboundAttachments[attachmentId];
    if (state == null ||
        !state.awaitingAcceptance ||
        !_acceptingIncomingAttachmentIds.add(attachmentId)) {
      return;
    }
    appendDebugLog('Accepting incoming attachment $attachmentId.');
    notifyListeners();
    try {
      final preparation = await _createInboundPartialFile(
        state.descriptor,
        ignoreStorageReserve: ignoreStorageReserve,
      );
      final partialPath = preparation.path;
      if (partialPath == null) {
        _setTransferSessionState(
          attachmentId,
          TransferState.waitingForStorage,
          error: preparation.error,
          storageReserveBlocked: preparation.reserveBlocked,
        );
        return;
      }
      final contact = _contactByDeviceId(state.peerDeviceId);
      if (contact == null) {
        _setTransferSessionState(
          attachmentId,
          TransferState.failed,
          error: 'The attachment sender is no longer a contact.',
        );
        return;
      }
      state
        ..partialPath = partialPath
        ..accepted = true
        ..awaitingAcceptance = false;
      final requiresDirect =
          state.descriptor.sizeBytes > maxAttachmentSizeBytes;
      final routeAvailable =
          !requiresDirect || _hasUsableLargeDirectTransport(contact);
      final session = _transferSessionById(attachmentId);
      if (session != null) {
        final root = await _attachmentRoot();
        _upsertTransferSession(
          session.copyWith(
            state: routeAvailable
                ? TransferState.transferring
                : TransferState.waitingForLan,
            relativePath: p.relative(partialPath, from: root.path),
            updatedAt: _now().toUtc(),
            clearLastError: true,
          ),
        );
        // The accepted partial path must be durable before any block can be
        // written. A restart between these operations can then resume safely.
        await _saveSnapshotSilently(notify: false);
      }
      appendDebugLog(
        'Incoming attachment $attachmentId accepted; '
        'route=${routeAvailable ? "available" : "waiting-for-direct"}.',
      );
      // Rebuild the bubble before touching the network. Previously this was
      // after Future.wait(request window), which made Download appear inert
      // whenever a route was slow or unavailable.
      notifyListeners();
      if (routeAvailable) {
        _scheduleAttachmentRetry(attachmentId);
        _startInboundRequestWindow(state, contact);
      }
    } catch (error, stackTrace) {
      appendDebugLog(
        'Could not accept incoming attachment $attachmentId: $error\n'
        '$stackTrace',
      );
      state
        ..accepted = false
        ..awaitingAcceptance = true
        ..partialPath = null;
      _setTransferSessionState(
        attachmentId,
        TransferState.waitingForStorage,
        error: 'Could not prepare this download. Check storage and try again.',
      );
      _setTransientStatus(
        'Could not prepare ${state.descriptor.fileName} for download.',
      );
    } finally {
      _acceptingIncomingAttachmentIds.remove(attachmentId);
      notifyListeners();
    }
  }

  Future<void> rejectIncomingAttachment(String attachmentId) async {
    final state = _inboundAttachments[attachmentId];
    if (state == null) return;
    await state.closeFile();
    final contact = _contactByDeviceId(state.peerDeviceId);
    if (contact != null) {
      unawaited(_sendAttachmentCancel(contact, attachmentId));
    }
    _deleteMessage(state.peerDeviceId, state.messageId);
    await _deleteAttachmentArtifacts(attachmentId);
    _removeTransferSession(attachmentId);
    await _saveSnapshotSilently(notify: true);
  }

  /// Resolves the on-disk cache path for a completed attachment so the
  /// Copy-path UI affordance can hand it off to the OS clipboard.
  /// Returns null if the bytes haven't been persisted yet (transfer
  /// still in flight or the disk write failed).
  Future<String?> attachmentCachePathFor(String attachmentId) async {
    try {
      final file = await _attachmentCacheFile(attachmentId);
      if (!await file.exists()) {
        final outbound = _outboundAttachments[attachmentId];
        if (outbound != null && await File(outbound.sourcePath).exists()) {
          return outbound.sourcePath;
        }
        final session = _transferSessionById(attachmentId);
        final originalPath =
            session?.sourceKind == TransferSourceKind.originalPath
            ? session?.sourcePath
            : null;
        if (originalPath != null && await File(originalPath).exists()) {
          return originalPath;
        }
        return null;
      }
      _recordAttachmentCacheReference(attachmentId);
      unawaited(_saveSnapshotSilently(notify: false, debounce: true));
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<File> _attachmentCacheFile(String attachmentId) async {
    final root = await _attachmentRoot();
    final cache = Directory(p.join(root.path, 'cache'));
    if (!await cache.exists()) await cache.create(recursive: true);
    final legacy = File(p.join(cache.path, attachmentStorageKey(attachmentId)));
    final descriptor = attachmentDescriptorFor(attachmentId);
    final hash = descriptor?.fileHashBase64;
    if (hash == null || hash.isEmpty) return legacy;
    final managed = File(
      p.join(cache.path, attachmentStorageKey('sha256:$hash')),
    );
    if (!await managed.exists() && await legacy.exists()) {
      try {
        await legacy.rename(managed.path);
      } catch (_) {
        return legacy;
      }
    }
    return managed;
  }

  int _cacheReferenceCount(String fileHashBase64) {
    var references = 0;
    for (final conversation in _snapshot.conversations) {
      for (final message in conversation.messages) {
        if (message.attachment?.fileHashBase64 == fileHashBase64) {
          references++;
        }
      }
    }
    return references;
  }

  AttachmentCacheReference? cacheReferenceFor(String attachmentId) => _snapshot
      .attachmentCacheReferences
      .where((entry) => entry.attachmentId == attachmentId)
      .firstOrNull;

  bool attachmentKeptOffline(String attachmentId) =>
      cacheReferenceFor(attachmentId)?.keepOffline ?? false;

  void _recordAttachmentCacheReference(
    String attachmentId, {
    bool? keepOffline,
    bool? explicitlySaved,
    DateTime? accessedAt,
  }) {
    final descriptor = attachmentDescriptorFor(attachmentId);
    if (descriptor == null || descriptor.fileHashBase64.isEmpty) return;
    final records = _snapshot.attachmentCacheReferences.toList();
    final index = records.indexWhere(
      (entry) => entry.attachmentId == attachmentId,
    );
    final now = (accessedAt ?? _now()).toUtc();
    if (index < 0) {
      records.add(
        AttachmentCacheReference(
          attachmentId: attachmentId,
          fileHashBase64: descriptor.fileHashBase64,
          lastAccessedAt: now,
          keepOffline: keepOffline ?? false,
          explicitlySaved: explicitlySaved ?? false,
        ),
      );
    } else {
      records[index] = records[index].copyWith(
        lastAccessedAt: now,
        keepOffline: keepOffline,
        explicitlySaved: explicitlySaved,
      );
    }
    _snapshot = _snapshot.copyWith(attachmentCacheReferences: records);
  }

  Future<void> setAttachmentKeepOffline(
    String attachmentId,
    bool keepOffline,
  ) async {
    if (!attachmentAvailableLocally(attachmentId) && keepOffline) {
      throw StateError('Download the attachment before keeping it offline.');
    }
    _recordAttachmentCacheReference(attachmentId, keepOffline: keepOffline);
    await _saveSnapshotSilently(notify: true);
  }

  Future<void> markAttachmentExplicitlySaved(String attachmentId) async {
    _recordAttachmentCacheReference(attachmentId, explicitlySaved: true);
    await _saveSnapshotSilently(notify: false, debounce: true);
  }

  Future<void> evictAttachment(String attachmentId) async {
    final descriptor = attachmentDescriptorFor(attachmentId);
    if (descriptor == null) return;
    final sameContent = <String>{
      for (final conversation in _snapshot.conversations)
        for (final message in conversation.messages)
          if (message.attachment?.fileHashBase64 == descriptor.fileHashBase64)
            message.attachment!.id,
    };
    final protected = _snapshot.attachmentCacheReferences.any(
      (entry) =>
          sameContent.contains(entry.attachmentId) &&
          (entry.keepOffline || entry.explicitlySaved),
    );
    final active = _snapshot.transferSessions.any(
      (entry) =>
          sameContent.contains(entry.id) &&
          entry.state != TransferState.completed &&
          entry.state != TransferState.canceled &&
          entry.state != TransferState.failed,
    );
    if (protected) {
      throw StateError(
        'This attachment is saved or marked Keep offline and cannot be evicted.',
      );
    }
    if (active) {
      final activeStates = _snapshot.transferSessions
          .where(
            (entry) =>
                sameContent.contains(entry.id) &&
                entry.state != TransferState.completed &&
                entry.state != TransferState.canceled &&
                entry.state != TransferState.failed,
          )
          .map((entry) => '${entry.id}:${entry.state.name}')
          .join(', ');
      throw StateError(
        'This attachment still has an active transfer session ($activeStates).',
      );
    }
    final cache = await _attachmentCacheFile(attachmentId);
    if (await cache.exists()) await cache.delete();
    for (final id in sameContent) {
      _locallyAvailableAttachments.remove(id);
      _assembledAttachments.remove(id);
    }
    await _saveSnapshotSilently(notify: true);
  }

  int get _managedCacheLimitBytes => !kIsWeb && Platform.isAndroid
      ? 2 * 1024 * 1024 * 1024
      : 10 * 1024 * 1024 * 1024;

  Duration get _managedCacheMaximumAge => !kIsWeb && Platform.isAndroid
      ? const Duration(days: 30)
      : const Duration(days: 90);

  Future<void> _evictManagedCacheIfNeeded(Directory root) async {
    final cache = Directory(p.join(root.path, 'cache'));
    if (!await cache.exists()) return;
    final now = _now().toUtc();
    final recordsByHash = <String, List<AttachmentCacheReference>>{};
    for (final record in _snapshot.attachmentCacheReferences) {
      recordsByHash
          .putIfAbsent(
            record.fileHashBase64,
            () => <AttachmentCacheReference>[],
          )
          .add(record);
    }
    final candidates =
        <({File file, int size, DateTime lastAccess, Set<String> ids})>[];
    var total = 0;
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      total += stat.size;
      final matching = <AttachmentCacheReference>[];
      for (final entry in recordsByHash.entries) {
        if (attachmentStorageKey('sha256:${entry.key}') ==
            p.basename(entity.path)) {
          matching.addAll(entry.value);
          break;
        }
      }
      final ids = matching.map((entry) => entry.attachmentId).toSet();
      final protected = matching.any(
        (entry) => entry.keepOffline || entry.explicitlySaved,
      );
      final active = _snapshot.transferSessions.any(
        (entry) =>
            ids.contains(entry.id) &&
            entry.state != TransferState.completed &&
            entry.state != TransferState.canceled &&
            entry.state != TransferState.failed,
      );
      if (protected || active) continue;
      final lastAccess = matching.isEmpty
          ? stat.modified.toUtc()
          : matching
                .map((entry) => entry.lastAccessedAt)
                .reduce((left, right) => left.isAfter(right) ? left : right);
      candidates.add((
        file: entity,
        size: stat.size,
        lastAccess: lastAccess,
        ids: ids,
      ));
    }
    candidates.sort(
      (left, right) => left.lastAccess.compareTo(right.lastAccess),
    );
    final capacity = await _storageCapacityProvider(root.path);
    final reserve = capacity == null
        ? 0
        : (capacity.totalBytes * _storageReserveFraction).ceil();
    var projectedFree = capacity?.freeBytes ?? (1 << 62);
    for (final candidate in candidates) {
      final expired =
          now.difference(candidate.lastAccess) > _managedCacheMaximumAge;
      final overLimit = total > _managedCacheLimitBytes;
      final belowReserve = projectedFree < reserve;
      if (!expired && !overLimit && !belowReserve) continue;
      try {
        if (await candidate.file.exists()) await candidate.file.delete();
        total -= candidate.size;
        projectedFree += candidate.size;
        for (final id in candidate.ids) {
          _locallyAvailableAttachments.remove(id);
          _assembledAttachments.remove(id);
        }
      } catch (error) {
        appendDebugLog(
          'Cache eviction failed for ${candidate.file.path}: $error',
        );
      }
    }
  }

  Future<void> _deleteAttachmentArtifacts(String attachmentId) async {
    _locallyAvailableAttachments.remove(attachmentId);
    try {
      final root = await _attachmentRoot();
      final key = attachmentStorageKey(attachmentId);
      final candidates = <String>{
        p.join(root.path, 'cache', key),
        p.join(root.path, 'cache', '$key.tmp'),
        p.join(root.path, 'spool', '$key.bin'),
        p.join(root.path, 'spool', '$key.bin.tmp'),
        p.join(root.path, 'partial', '$key.part'),
      };
      final descriptor = attachmentDescriptorFor(attachmentId);
      final hash = descriptor?.fileHashBase64;
      if (hash != null && hash.isNotEmpty && _cacheReferenceCount(hash) <= 1) {
        candidates.add(
          p.join(root.path, 'cache', attachmentStorageKey('sha256:$hash')),
        );
      }
      final session = _transferSessionById(attachmentId);
      if (session != null && session.relativePath.isNotEmpty) {
        candidates.add(p.join(root.path, session.relativePath));
      }
      for (final path in candidates) {
        if (!isContainedPath(root.path, path)) continue;
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (error) {
      appendDebugLog('Attachment cleanup failed for $attachmentId: $error');
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
    final attachmentId = message.attachment?.id;
    _clearOutboundAttempt(contact.deviceId, messageId);
    _deleteMessage(contact.deviceId, messageId);
    if (attachmentId != null) {
      unawaited(_sendAttachmentCancel(contact, attachmentId));
    }
    await _persist('Canceled and deleted pending message to ${contact.alias}.');
  }

  /// Removes every member of [albumId] from this device. For outbound
  /// members that still need a remote-deletion envelope, [deleteMessage]
  /// handles that. Mirrors the user's mental model that the popup menu
  /// applies to the album as a unit, not one tile at a time.
  Future<void> deleteAlbum(String albumId) async {
    if (albumId.isEmpty) return;
    final targets = <({String peerDeviceId, String messageId})>[];
    for (final conversation in _snapshot.conversations) {
      for (final message in conversation.messages) {
        if (message.albumId == albumId) {
          targets.add((
            peerDeviceId: conversation.peerDeviceId,
            messageId: message.id,
          ));
        }
      }
    }
    if (targets.isEmpty) return;
    for (final target in targets) {
      final contact = _contactByDeviceId(target.peerDeviceId);
      try {
        if (contact != null) {
          await deleteMessage(contact: contact, messageId: target.messageId);
        } else {
          _deleteMessage(target.peerDeviceId, target.messageId);
        }
      } catch (_) {
        _deleteMessage(target.peerDeviceId, target.messageId);
      }
    }
  }

  /// Cancels every in-flight outbound transfer in [albumId]. Each member
  /// uses the existing per-attachment cancel path so the receiver still
  /// gets `attachment_cancel` envelopes.
  Future<void> cancelAlbum(String albumId) async {
    if (albumId.isEmpty) return;
    final outboundMembers = <({ContactRecord contact, ChatMessage message})>[];
    for (final conversation in _snapshot.conversations) {
      for (final message in conversation.messages) {
        if (message.albumId != albumId || !message.outbound) continue;
        final contact = _contactByDeviceId(conversation.peerDeviceId);
        if (contact == null) continue;
        outboundMembers.add((contact: contact, message: message));
      }
    }
    for (final entry in outboundMembers) {
      final attachmentId = entry.message.attachment?.id;
      if (attachmentId == null) continue;
      try {
        if (entry.message.state == DeliveryState.pending) {
          await cancelPendingMessage(
            contact: entry.contact,
            messageId: entry.message.id,
          );
        } else {
          unawaited(_sendAttachmentCancel(entry.contact, attachmentId));
          _clearOutboundAttempt(entry.contact.deviceId, entry.message.id);
          _outboundAttachments.remove(attachmentId);
          _activeOutboundByContact.remove(entry.contact.deviceId);
          _outboundQueueByContact[entry.contact.deviceId]?.remove(attachmentId);
          _updateMessageState(
            entry.contact.deviceId,
            entry.message.id,
            DeliveryState.canceled,
          );
        }
      } catch (_) {
        // Best-effort; per-member failure should not block the rest.
      }
    }
    notifyListeners();
  }

  // ---- nightly.10 staged attachment API ----

  /// Append [items] to the staged bucket for [contact]. The composer's
  /// preview tray will pick this up via `stagedAttachmentsFor` on the
  /// next notify.
  void stageAttachments({
    required ContactRecord contact,
    required List<StagedAttachment> items,
  }) {
    if (items.isEmpty) return;
    final list = _stagedAttachments.putIfAbsent(
      contact.deviceId,
      () => <StagedAttachment>[],
    );
    list.addAll(items);
    notifyListeners();
  }

  /// Read-only view of what's currently staged for [deviceId]. Returns
  /// the empty list when no staging exists — the composer treats that as
  /// "no preview tray to show".
  List<StagedAttachment> stagedAttachmentsFor(String deviceId) {
    final list = _stagedAttachments[deviceId];
    if (list == null) return const <StagedAttachment>[];
    return List<StagedAttachment>.unmodifiable(list);
  }

  /// Drop a single staged item via its [stagedId]. Wired to the X button
  /// on each preview tile.
  void removeStaged({required String deviceId, required String stagedId}) {
    final list = _stagedAttachments[deviceId];
    if (list == null) return;
    list.removeWhere((item) => item.id == stagedId);
    if (list.isEmpty) {
      _stagedAttachments.remove(deviceId);
    }
    notifyListeners();
  }

  void reorderStaged({
    required String deviceId,
    required int oldIndex,
    required int newIndex,
  }) {
    final list = _stagedAttachments[deviceId];
    if (list == null || oldIndex < 0 || oldIndex >= list.length) return;
    final target = newIndex.clamp(0, list.length - 1);
    final item = list.removeAt(oldIndex);
    list.insert(target, item);
    notifyListeners();
  }

  void setStagedPresentation({
    required String deviceId,
    required String stagedId,
    required AttachmentPresentation presentation,
  }) {
    final list = _stagedAttachments[deviceId];
    if (list == null) return;
    final index = list.indexWhere((entry) => entry.id == stagedId);
    if (index < 0 || list[index].presentation == presentation) return;
    list[index] = list[index].copyWith(presentation: presentation);
    notifyListeners();
  }

  /// Wipe the bucket — used after a successful `sendStagedBundle` and
  /// when the user navigates away from the contact and explicitly
  /// abandons the bundle.
  void clearStagedFor(String deviceId) {
    final removed = _stagedAttachments.remove(deviceId);
    if (removed != null) notifyListeners();
  }

  /// Commit the staged bundle. Applies the same album packing the
  /// (now-deprecated) `_sendMultipleAttachments` did: per-item captions
  /// go solo; uncaptioned items bundle into albums of
  /// [maxAttachmentsPerAlbum]; the composer's [caption] (typed in the
  /// TextField) is promoted to the FIRST uncaptioned item. Clears the
  /// bucket immediately so the UI moves the previews into the chat
  /// thread; per-item failures surface via the bubble's Failed state.
  Future<void> sendStagedBundle({
    required ContactRecord contact,
    String caption = '',
    Future<bool> Function(
      StagedAttachment attachment,
      AttachmentSpoolException error,
    )?
    confirmOriginalSourceFallback,
  }) async {
    final staged = _stagedAttachments[contact.deviceId];
    if (staged == null || staged.isEmpty) return;
    final items = List<StagedAttachment>.from(staged);
    _stagedAttachments.remove(contact.deviceId);
    notifyListeners();

    // Album packing identical to the pre-staging flow.
    final albums = <List<StagedAttachment>>[];
    var current = <StagedAttachment>[];
    var composerCaptionUsed = false;
    for (final item in items) {
      var effectiveCaption = item.caption;
      if (item.caption.isEmpty && !composerCaptionUsed && caption.isNotEmpty) {
        effectiveCaption = caption;
        composerCaptionUsed = true;
      }
      final effective = effectiveCaption == item.caption
          ? item
          : item.copyWith(caption: effectiveCaption);
      if (effective.caption.isNotEmpty ||
          effective.presentation == AttachmentPresentation.file) {
        if (current.isNotEmpty) {
          albums.add(current);
          current = <StagedAttachment>[];
        }
        albums.add([effective]);
        continue;
      }
      current.add(effective);
      if (current.length == maxAttachmentsPerAlbum) {
        albums.add(current);
        current = <StagedAttachment>[];
      }
    }
    if (current.isNotEmpty) albums.add(current);

    for (var a = 0; a < albums.length; a++) {
      final album = albums[a];
      final albumId = album.length > 1 ? newAlbumId() : null;
      for (var i = 0; i < album.length; i++) {
        final entry = album[i];
        try {
          await sendAttachmentSource(
            contact: contact,
            source: entry,
            caption: album.length == 1
                ? entry.caption
                : (i == 0 ? entry.caption : ''),
            albumId: albumId,
          );
        } on AttachmentSpoolException catch (error) {
          final useOriginal =
              error.canUseOriginal &&
              confirmOriginalSourceFallback != null &&
              await confirmOriginalSourceFallback(entry, error);
          if (useOriginal) {
            await sendAttachmentSource(
              contact: contact,
              source: entry,
              caption: album.length == 1
                  ? entry.caption
                  : (i == 0 ? entry.caption : ''),
              albumId: albumId,
              allowOriginalFallback: true,
            );
          } else {
            appendDebugLog(
              'sendStagedBundle: ${entry.fileName} not sent — $error',
            );
          }
        } catch (error) {
          appendDebugLog('sendStagedBundle: ${entry.fileName} failed — $error');
        }
        if (i < album.length - 1) {
          await Future<void>.delayed(
            const Duration(milliseconds: albumOfferIntervalMs),
          );
        }
      }
      if (a < albums.length - 1) {
        await Future<void>.delayed(
          const Duration(milliseconds: albumGapIntervalMs),
        );
      }
    }
  }

  /// Called when the host platform reports a connectivity-interface change
  /// (Wi-Fi ↔ VPN ↔ cellular). The host wires `connectivity_plus`'s stream
  /// in `main.dart` and calls this method on every event so the controller
  /// stays platform-agnostic and testable (just call the method directly).
  ///
  /// Re-probes every active transfer so a stale-socket `_deliverToContact`
  /// future doesn't hold the queue hostage waiting for the 60 s stall
  /// timer (the symptom the user reported when toggling VPN mid-transfer).
  void onConnectivityChanged({String? interfaceLabel}) {
    final label = interfaceLabel ?? 'unknown';
    final normalizedLabel = label.toLowerCase();
    _networkCostClass = normalizedLabel.contains('none')
        ? NetworkCostClass.offline
        : normalizedLabel.contains('mobile')
        ? NetworkCostClass.metered
        : NetworkCostClass.unmetered;
    appendDebugLog(
      'Connectivity changed ($label) — kicking active transfers + polling.',
    );
    _routeHealthTracker.clearBackoffWindows();
    // An address learned on the old interface is no longer trusted as a LAN
    // destination. Both peers exchange fresh, authenticated endpoint hints.
    _peerLanDirect.clear();
    for (final state in _outboundAttachments.values.where(
      (entry) => entry.requiresLan,
    )) {
      final peer = _contactByDeviceId(state.peerDeviceId);
      if (peer == null || !_hasUsableLargeDirectTransport(peer)) {
        _setTransferSessionState(
          state.descriptor.id,
          TransferState.waitingForLan,
          error: 'Waiting for a direct route after connectivity changed.',
        );
      }
    }
    unawaited(_refreshAndAdvertiseLanDirectRoutes());
    // Cancel inbound retry timers so the next re-request fires immediately
    // through the (possibly different) route instead of waiting out the
    // original interval against a stale interface.
    for (final state in _inboundAttachments.values) {
      state.retryTimer?.cancel();
      state.requestedInFlight.clear();
      final peer = _contactByDeviceId(state.peerDeviceId);
      if (peer == null) continue;
      _scheduleAttachmentRetry(state.descriptor.id);
      _startInboundRequestWindow(state, peer);
    }
    // Kick every outbound queue — the new interface may have a viable
    // route the old one didn't, and the queue might be parked behind a
    // stalled active outbound.
    for (final contactId in _activeOutboundByContact.keys.toList()) {
      final contact = _contactByDeviceId(contactId);
      if (contact != null) _pumpOutboundQueue(contact);
    }
    // Drain whatever queued at the relay during the interface flap.
    unawaited(pollNow());
  }

  Future<void> _refreshAndAdvertiseLanDirectRoutes() async {
    await _refreshLocalLanDirectAddressCache();
    for (final contact in _snapshot.contacts.where(
      (entry) => entry.canSendOutbound,
    )) {
      await _sendRouteUpdate(
        contact,
        requestReply: true,
        reason: 'connectivity_change',
      );
    }
  }

  /// nightly.11: cancel an outbound transfer by attachmentId. Walks the
  /// outbound state, sends an attachment_cancel envelope to the peer,
  /// clears local state and flips the parent message to canceled. Used
  /// by the context-menu Cancel action where we only have the
  /// attachment id, not the (contact, message) pair.
  Future<void> cancelAttachmentById(String attachmentId) async {
    final state = _outboundAttachments[attachmentId];
    if (state == null) return;
    final contact = _contactByDeviceId(state.peerDeviceId);
    if (contact == null) return;
    unawaited(_sendAttachmentCancel(contact, attachmentId));
    _clearOutboundAttempt(contact.deviceId, state.messageId);
    _outboundAttachments.remove(attachmentId);
    _clearActiveOutbound(contact.deviceId, attachmentId);
    _outboundQueueByContact[contact.deviceId]?.remove(attachmentId);
    _setTransferSessionState(attachmentId, TransferState.canceled);
    _updateMessageState(
      contact.deviceId,
      state.messageId,
      DeliveryState.canceled,
    );
    _pumpOutboundQueue(contact);
    notifyListeners();
    await state.closeFile();
    await _deleteAttachmentArtifacts(attachmentId);
    await _saveSnapshotSilently(notify: false);
  }

  Future<void> cancelTransfer(String attachmentId) async {
    if (_outboundAttachments.containsKey(attachmentId)) {
      await cancelAttachmentById(attachmentId);
      return;
    }
    final state = _inboundAttachments.remove(attachmentId);
    if (state == null) return;
    state.retryTimer?.cancel();
    await state.closeFile();
    final contact = _contactByDeviceId(state.peerDeviceId);
    if (contact != null) {
      unawaited(_sendAttachmentCancel(contact, attachmentId));
    }
    _setTransferSessionState(attachmentId, TransferState.canceled);
    _updateMessageState(
      state.peerDeviceId,
      state.messageId,
      DeliveryState.canceled,
    );
    await _deleteAttachmentArtifacts(attachmentId);
    await _saveSnapshotSilently(notify: true);
  }

  /// User-initiated retry of a Failed attachment. Resets the auto-retry
  /// counter, clears in-flight chunk progress so the queue worker starts
  /// fresh, flips the parent message back to `sending`, and re-enqueues.
  /// Invoked by the bubble's "tap to retry" InkWell (nightly.9).
  void retryAttachment(String attachmentId) {
    final state = _outboundAttachments[attachmentId];
    if (state == null) {
      final inbound = _inboundAttachments[attachmentId];
      if (inbound == null || inbound.awaitingAcceptance) return;
      final contact = _contactByDeviceId(inbound.peerDeviceId);
      if (contact == null) return;
      if (inbound.isComplete) {
        inbound.finalizing = false;
        _setTransferSessionState(attachmentId, TransferState.reconnecting);
        _updateMessageState(
          inbound.peerDeviceId,
          inbound.messageId,
          DeliveryState.pending,
        );
        appendDebugLog(
          'Retrying final verification and cache promotion for $attachmentId.',
        );
        unawaited(_finalizeInboundAttachment(contact, attachmentId, inbound));
        notifyListeners();
        return;
      }
      inbound
        ..retryAttempts = 0
        ..nextRetryAt = null
        ..requestedInFlight.clear();
      _setTransferSessionState(attachmentId, TransferState.reconnecting);
      _startInboundRequestWindow(inbound, contact);
      notifyListeners();
      return;
    }
    final contact = _contactByDeviceId(state.peerDeviceId);
    if (contact == null) return;
    state.autoRetries = 0;
    state.highestChunkSent = -1;
    state.peerReceivedCount = null;
    state.peerReceivedBytes = null;
    state.peerProgressAt = null;
    _updateMessageState(
      state.peerDeviceId,
      state.messageId,
      DeliveryState.pending,
    );
    appendDebugLog('User tapped retry for $attachmentId — re-enqueueing.');
    _enqueueOutbound(contact, attachmentId);
    _pumpOutboundQueue(contact);
    notifyListeners();
  }

  Future<void> deleteMessage({
    required ContactRecord contact,
    required String messageId,
  }) async {
    final message = _messageById(contact.deviceId, messageId);
    if (message == null) {
      throw ArgumentError('Message not found.');
    }
    final attachmentId = message.attachment?.id;
    if (attachmentId != null) {
      // Deleting a message with an in-flight *inbound* transfer must also
      // tear down the local chunk-assembly state: the attachment_cancel
      // below only stops the peer's side, and an orphaned retryTimer keeps
      // firing chunk_requests for a message that no longer exists.
      final inboundState = _inboundAttachments.remove(attachmentId);
      inboundState?.retryTimer?.cancel();
      if (inboundState != null) unawaited(inboundState.closeFile());
      _assembledAttachments.remove(attachmentId);
      _removeTransferSession(attachmentId);
      unawaited(_deleteAttachmentArtifacts(attachmentId));
    }
    _clearOutboundAttempt(contact.deviceId, messageId);
    _deleteMessage(contact.deviceId, messageId);
    await _persist('Message deleted locally.');

    // nightly.12: send attachment_cancel whenever the deleted message
    // carries an attachment, regardless of direction. Pre-nightly.12
    // this only fired for OUTBOUND messages, so receiver-side deletes
    // of an in-flight transfer never told the sender to stop pushing
    // chunks. Now both directions notify the peer; the outbox makes the
    // notification at-least-once.
    if (attachmentId != null) {
      unawaited(_sendAttachmentCancel(contact, attachmentId));
    }
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
    // nightly.12: route the edit through the unified outbox too, so an
    // offline peer still gets the new text when they next poll.
    await _enqueueAndDeliverEnvelope(
      contact: contact,
      envelope: envelope,
      kind: PendingAckKind.messageEdit,
    );
    await _persist('Message edit queued to ${contact.alias}.');
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
    // nightly.12: route through the unified outbox so an offline peer
    // still receives the deletion when they next poll. Pre-nightly.12
    // this was fire-and-forget and the user reported deletes not
    // reaching the other side.
    await _enqueueAndDeliverEnvelope(
      contact: contact,
      envelope: envelope,
      kind: PendingAckKind.messageDelete,
    );
    return true;
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
      protocolVersion: 1,
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

  Future<bool> _sendReciprocalContactExchange(
    ContactRecord contact, {
    bool recipientKnowsIdentity = false,
  }) async {
    if (!contact.canSendOutbound) return false;
    final me = _requireIdentity();
    final payload = (await _inviteForIdentity(me)).encodePayload();
    // Bootstrap is an untrusted v1 request because the recipient may not
    // know our public key yet. It has no effects until explicit approval.
    final exchange = recipientKnowsIdentity
        ? await _crypto.encryptPayloadEnvelope(
            kind: 'contact_exchange',
            messageId: _randomId('xchg'),
            conversationId: 'contact-exchange-${contact.deviceId}',
            senderAccountId: me.accountId,
            senderDeviceId: me.deviceId,
            recipientDeviceId: contact.deviceId,
            contact: contact,
            plaintext: payload,
          )
        : RelayEnvelope(
            protocolVersion: 1,
            kind: 'contact_exchange',
            messageId: _randomId('xchg'),
            conversationId: 'contact-exchange-${contact.deviceId}',
            senderAccountId: me.accountId,
            senderDeviceId: me.deviceId,
            recipientDeviceId: contact.deviceId,
            createdAt: _now().toUtc(),
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
    final removedAt = DateTime.now().toUtc();
    final removal = await _crypto.encryptPayloadEnvelope(
      kind: 'contact_remove',
      messageId: _randomId('rm'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode({
        'removedDeviceId': contact.deviceId,
        'removedAt': removedAt.toIso8601String(),
      }),
      createdAt: removedAt,
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
        createdAt: now.toUtc(),
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
        createdAt: now.toUtc(),
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
      createdAt: _now().toUtc(),
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
      'invitePayload': (await _inviteForIdentity(me)).encodePayload(),
      'requestReply': requestReply,
      'reason': reason,
      'sentAt': effectiveSentAt.toIso8601String(),
      ..._localLanDirectHintPayload(),
    };
    if (effectiveProbeId != null) {
      routeUpdatePayload['probeId'] = effectiveProbeId;
    }
    final payload = jsonEncode(routeUpdatePayload);
    final update = await _crypto.encryptPayloadEnvelope(
      kind: 'route_update',
      messageId: _randomId('route'),
      conversationId: 'route-update-${contact.deviceId}',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: payload,
      createdAt: effectiveSentAt,
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
      if (!contact.canSendOutbound) continue;
      changed = true;
      final sentHeartbeat = await _sendRouteUpdate(
        contact,
        requestReply: true,
        reason: 'heartbeat',
      );
      if (sentHeartbeat) {
        _reachability.noteAvailablePath(contact.deviceId);
        sent++;
      }
    }
    return _HeartbeatPassResult(sentCount: sent, changed: changed);
  }

  Future<void> pollNow() async {
    if (!hasIdentity) {
      return;
    }
    final activePoll = _pollCompleter;
    if (activePoll != null) {
      await activePoll.future;
      return;
    }
    final pollCompleter = Completer<void>();
    _pollCompleter = pollCompleter;
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
          final expectedRelayKey = await _requireOperationalRelayPin(route);
          final batch = await _relayClient.fetchLeasedEnvelopes(
            host: route.host,
            port: route.port,
            protocol: route.protocol,
            recipientDeviceId: me.deviceId,
            expectedIdentityPublicKeyBase64: expectedRelayKey,
            timeout: route.kind == PeerRouteKind.lan
                ? const Duration(milliseconds: 900)
                : const Duration(seconds: 4),
          );
          final envelopes = batch.envelopes;
          stopwatch.stop();
          _routeHealthTracker.recordSuccess(
            route,
            fetch: true,
            latency: stopwatch.elapsed,
          );
          if (route.kind == PeerRouteKind.relay) {
            relaySuccess = true;
          }
          processed += await _processEnvelopes(
            envelopes,
            failOnProcessingError: true,
          );
          // The lease is the relay's durability boundary. Persist message,
          // range-journal and dedupe mutations before deleting its rows so a
          // process crash can only replay, never lose, an accepted envelope.
          if (envelopes.isNotEmpty) {
            await _saveSnapshotSilently(notify: false);
          }
          if (batch.leaseId case final leaseId?) {
            await _relayClient.acknowledgeLease(
              host: route.host,
              port: route.port,
              protocol: route.protocol,
              recipientDeviceId: me.deviceId,
              leaseId: leaseId,
              expectedIdentityPublicKeyBase64: expectedRelayKey,
            );
          }
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
      if (identical(_pollCompleter, pollCompleter)) {
        _pollCompleter = null;
      }
      if (!pollCompleter.isCompleted) pollCompleter.complete();
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
      RelayFetchBatch batch = const RelayFetchBatch(envelopes: []);
      try {
        final expectedRelayKey = await _requireOperationalRelayPin(route);
        batch = await _relayClient.fetchLeasedEnvelopes(
          host: route.host,
          port: route.port,
          protocol: route.protocol,
          recipientDeviceId: me.deviceId,
          waitFor: const Duration(seconds: 25),
          expectedIdentityPublicKeyBase64: expectedRelayKey,
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
      final envelopes = batch.envelopes;
      if (envelopes.isNotEmpty) {
        try {
          await _processEnvelopes(envelopes, failOnProcessingError: true);
          await _saveSnapshotSilently(notify: false);
          if (batch.leaseId case final leaseId?) {
            await _relayClient.acknowledgeLease(
              host: route.host,
              port: route.port,
              protocol: route.protocol,
              recipientDeviceId: me.deviceId,
              leaseId: leaseId,
              expectedIdentityPublicKeyBase64:
                  await _requireOperationalRelayPin(route),
            );
          }
        } catch (error) {
          // The lease expires and replays. Message-id deduplication makes
          // that safe, while preserving at-least-once delivery. This also
          // covers a failed vault commit or envelope handler.
          appendDebugLog(
            'Relay lease retained after processing/save failure: $error',
          );
          continue;
        }
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
    return conversation.messages
        .where(_isRenderableMessage)
        .toList(growable: false)
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
  }

  List<ChatMessage> messagesForGroup(String groupId) {
    final conversation = _groupConversation(groupId);
    return conversation.messages
        .where(_isRenderableMessage)
        .toList(growable: false)
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
  }

  /// Every renderable inbound + outbound message in the 1:1 conversation
  /// with [peerDeviceId] that carries an `image/*` attachment whose bytes
  /// are already in memory (`attachmentBytesFor` returns non-null). Sorted
  /// chronologically so the full-screen viewer's PageView can swipe
  /// forward = later, backward = earlier.
  List<ChatMessage> imageAttachmentsFor(String peerDeviceId) {
    return messagesFor(peerDeviceId)
        .where((m) {
          final att = m.attachment;
          if (att == null) return false;
          if (!att.mimeType.startsWith('image/')) return false;
          return attachmentBytesFor(att.id) != null;
        })
        .toList(growable: false);
  }

  /// Belt-and-suspenders filter to keep ghost messages out of the rendered
  /// list. A message with no body, no attachment, and no reply preview has
  /// nothing to draw — past pipelines occasionally produced these via a
  /// duplicate-offer or torn-state race, and they showed up as
  /// "10:42 •••" stubs in the chat. Reject them at the public API.
  static bool _isRenderableMessage(ChatMessage m) {
    if (m.body.trim().isNotEmpty) return true;
    if (m.attachment != null) return true;
    if (m.replyToMessageId != null && m.replyToMessageId!.isNotEmpty) {
      return true;
    }
    return false;
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
    if (!_pairingBeaconEnabled || kIsWeb || _pairingBeaconSocket != null) {
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
    _scheduleTransferForegroundSync();
  }

  void _scheduleTransferForegroundSync() {
    if (_transferNotificationTimer?.isActive == true) return;
    _transferNotificationTimer = Timer(
      const Duration(milliseconds: 500),
      _syncTransferForeground,
    );
  }

  Future<void> _syncTransferForeground() async {
    final active = transferSnapshots
        .where(
          (entry) =>
              entry.phase.isActive || entry.phase == TransferPhase.paused,
        )
        .toList(growable: false);
    if (active.isEmpty) {
      await _platformBridge.stopTransferForeground();
      return;
    }
    final transferred = active.fold<int>(
      0,
      (value, entry) => value + entry.bytesTransferred,
    );
    final total = active.fold<int>(
      0,
      (value, entry) => value + entry.totalBytes,
    );
    await _platformBridge.updateTransferForeground(
      title: active.length == 1
          ? attachmentDescriptorFor(active.first.id)?.fileName ??
                'Conest transfer'
          : '${active.length} Conest transfers',
      transferredBytes: transferred,
      totalBytes: total,
      paused: active.every((entry) => entry.phase == TransferPhase.paused),
    );
  }

  void _handleNativeTransferControl(String action) {
    switch (action) {
      case 'pause_all':
        unawaited(pauseAllTransfers());
      case 'resume_all':
        unawaited(resumeAllTransfers());
      case 'cancel_all':
        final ids = transferSnapshots
            .where(
              (entry) =>
                  entry.phase.isActive || entry.phase == TransferPhase.paused,
            )
            .map((entry) => entry.id)
            .toList(growable: false);
        for (final id in ids) {
          unawaited(cancelTransfer(id));
        }
    }
  }

  Future<int> _processEnvelopes(
    List<RelayEnvelope> envelopes, {
    PeerRouteKind ingressKind = PeerRouteKind.relay,
    bool failOnProcessingError = false,
  }) async {
    _notificationsDeferredDepth++;
    var outcome = const _EnvelopeProcessingOutcome();
    try {
      outcome = await _processEnvelopesInternal(envelopes, ingressKind);
    } finally {
      _notificationsDeferredDepth--;
      if (_notificationsDeferredDepth == 0 && _deferredNotificationPending) {
        _deferredNotificationPending = false;
        if (!_disposed) super.notifyListeners();
      }
    }
    if (failOnProcessingError && outcome.failed > 0) {
      throw StateError(
        '${outcome.failed} relay envelope(s) failed during processing.',
      );
    }
    return outcome.processed;
  }

  Future<_EnvelopeProcessingOutcome> _processEnvelopesInternal(
    List<RelayEnvelope> envelopes,
    PeerRouteKind ingressKind,
  ) async {
    var processed = 0;
    var failed = 0;
    final orderedEnvelopes = List<RelayEnvelope>.from(envelopes)
      ..sort((left, right) {
        final leftPriority = _processingPriority(left.kind);
        final rightPriority = _processingPriority(right.kind);
        return leftPriority.compareTo(rightPriority);
      });
    for (final envelope in orderedEnvelopes) {
      if (!_isValidInboundEnvelope(envelope)) {
        appendDebugLog(
          'Rejected malformed or incompatible envelope '
          '${_boundedLogValue(envelope.messageId)} '
          'kind=${_boundedLogValue(envelope.kind)}.',
        );
        continue;
      }
      if (_seenEnvelopeIdSet.contains(envelope.messageId)) {
        await _replayAckForSeenEnvelope(envelope);
        continue;
      }
      if (!_inFlightEnvelopeIds.add(envelope.messageId)) {
        // An overlapping _processEnvelopes run (the same envelope arriving
        // via a second transport) is already dispatching this id; its ack
        // and side effects cover this copy too.
        continue;
      }
      try {
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
        if (senderContact != null &&
            senderContact.accountId != envelope.senderAccountId) {
          appendDebugLog(
            'Rejected sender account mismatch for ${senderContact.deviceId}.',
          );
          continue;
        }
        if (senderContact != null && senderContact.pendingVerification) {
          _enqueueHeldEnvelope(senderContact.deviceId, envelope);
          continue;
        }
        // Connectivity mode is bidirectional: if the sender contact's
        // effective prefs forbid the ingress transport, drop the envelope
        // silently. No ack is emitted, so the sender's queue stall timer
        // eventually marks the message Failed. Pairing / contact_exchange
        // envelopes (sender unknown locally) are not gated — they need to
        // land for the contact to be created in the first place.
        if (senderContact != null &&
            _droppedByIngressMode(senderContact, ingressKind)) {
          _markSeen(envelope.messageId);
          appendDebugLog(
            'Dropped inbound from ${senderContact.alias}: ingress '
            '${ingressKind.name} disabled per effective connectivity prefs.',
          );
          continue;
        }
        processed++;
        if (envelope.kind == 'ack') {
          await _handleAck(envelope);
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
            envelope.kind == 'attachment_cancel' ||
            envelope.kind == 'attachment_pause_control' ||
            envelope.kind == 'attachment_progress') {
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

        // Nightly builds are release-mode binaries, so kDebugMode cannot
        // gate the authenticated peer diagnostics exposed by their Debug
        // menu. These envelopes still pass the normal known-contact,
        // identity, ingress-policy, decryption, and deduplication checks.
        if (envelope.kind == 'debug_probe') {
          await _handleDebugProbe(envelope);
          _markSeen(envelope.messageId);
          continue;
        }

        if (envelope.kind == 'debug_probe_ack') {
          await _handleDebugAcknowledgement(envelope, twoWay: false);
          _markSeen(envelope.messageId);
          continue;
        }

        if (envelope.kind == 'debug_two_way_message') {
          await _handleDebugTwoWayMessage(envelope);
          _markSeen(envelope.messageId);
          continue;
        }

        if (envelope.kind == 'debug_two_way_reply') {
          await _handleDebugAcknowledgement(envelope, twoWay: true);
          _markSeen(envelope.messageId);
          continue;
        }

        if (envelope.kind == 'debug_file_test_probe') {
          await _handleDebugFileTestProbe(envelope);
          _markSeen(envelope.messageId);
          continue;
        }

        if (envelope.kind == 'debug_file_test_probe_ack') {
          await _handleDebugFileTestProbeAck(envelope);
          _markSeen(envelope.messageId);
          continue;
        }

        if (envelope.kind == 'debug_file_test_result') {
          await _handleDebugFileTestResult(envelope);
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
          // Strict v2 cannot authenticate an orphan response after the key
          // has been forgotten. Silently ignore instead of emitting a
          // forgeable contact-removal control.
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
      } catch (error) {
        failed++;
        appendDebugLog(
          'Dropped envelope ${_boundedLogValue(envelope.messageId)} after '
          'processing error: ${_boundedLogValue(error.toString(), 180)}',
        );
      } finally {
        _inFlightEnvelopeIds.remove(envelope.messageId);
      }
    }
    return _EnvelopeProcessingOutcome(processed: processed, failed: failed);
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
      case 'debug_file_test_probe':
      case 'debug_file_test_probe_ack':
      case 'debug_file_test_result':
        return 1;
      default:
        return 2;
    }
  }

  String _boundedLogValue(Object? value, [int maxLength = 80]) {
    final text = value?.toString() ?? '';
    return text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';
  }

  bool _isValidInboundEnvelope(RelayEnvelope envelope) {
    final me = _snapshot.identity;
    if (me == null) return false;
    bool bounded(String value, int max) =>
        value.isNotEmpty &&
        value.length <= max &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
    if (!bounded(envelope.kind, 64) ||
        !bounded(envelope.messageId, 160) ||
        !bounded(envelope.conversationId, 256) ||
        !bounded(envelope.senderAccountId, 160) ||
        !bounded(envelope.senderDeviceId, 160) ||
        !bounded(envelope.recipientDeviceId, 160)) {
      return false;
    }
    final now = _now().toUtc();
    final createdAt = envelope.createdAt.toUtc();
    if (createdAt.isAfter(now.add(const Duration(days: 1))) ||
        createdAt.isBefore(now.subtract(const Duration(days: 30)))) {
      return false;
    }
    if (envelope.kind == 'lan_lobby_message') {
      if (envelope.protocolVersion != 1 ||
          envelope.recipientDeviceId != _lanLobbyMailboxId ||
          envelope.payloadBase64 == null) {
        return false;
      }
      try {
        return base64Decode(envelope.payloadBase64!).length <=
            _maxLanLobbyPayloadBytes;
      } catch (_) {
        return false;
      }
    }
    if (envelope.recipientDeviceId != me.deviceId ||
        envelope.senderDeviceId == me.deviceId) {
      return false;
    }
    if (envelope.protocolVersion == 1) {
      if (envelope.kind != 'contact_exchange' ||
          _contactByDeviceId(envelope.senderDeviceId) != null ||
          envelope.payloadBase64 == null) {
        return false;
      }
      try {
        return base64Decode(envelope.payloadBase64!).length <=
            _maxBootstrapPayloadBytes;
      } catch (_) {
        return false;
      }
    }
    if (envelope.protocolVersion != 2 ||
        !_v2PairwiseKinds.contains(envelope.kind) ||
        envelope.payloadBase64 != null ||
        envelope.nonceBase64 == null ||
        envelope.ciphertextBase64 == null ||
        envelope.macBase64 == null) {
      return false;
    }
    try {
      return base64Decode(envelope.nonceBase64!).length == 12 &&
          base64Decode(envelope.macBase64!).length == 16 &&
          base64Decode(envelope.ciphertextBase64!).length <=
              _maxEncryptedEnvelopeCiphertextBytes;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleAck(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null || contact.accountId != envelope.senderAccountId) {
      return;
    }
    final decoded = jsonDecode(
      await _crypto.decryptMessage(contact: contact, envelope: envelope),
    );
    if (decoded is! Map<String, dynamic>) return;
    final receipt = decoded['receipt'] as String?;
    final target = decoded['acknowledgedMessageId'] as String?;
    if ((receipt != 'read' && receipt != 'delivered') ||
        target == null ||
        target.isEmpty ||
        target != envelope.acknowledgedMessageId) {
      return;
    }
    final group = _groupById(envelope.conversationId);
    if (group != null) {
      if (!group.hasActiveMember(contact.deviceId)) return;
      _updateGroupRecipientState(
        group.groupId,
        target,
        contact.deviceId,
        receipt == 'read' ? DeliveryState.read : DeliveryState.delivered,
      );
    } else {
      if (envelope.conversationId !=
          _crypto.conversationIdFor(contact.deviceId)) {
        return;
      }
      final message = _messageById(contact.deviceId, target);
      if (message == null || !message.outbound) return;
      if (receipt == 'read') {
        _markMessagesReadThroughMessage(contact.deviceId, target);
      } else {
        _updateMessageState(contact.deviceId, target, DeliveryState.delivered);
        _clearOutboundAttempt(contact.deviceId, target);
      }
    }
    _reachability.noteTwoWaySuccess(contact.deviceId);
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
        await _handleAttachmentComplete(contact, payload);
        return;
      case 'attachment_cancel':
        _handleAttachmentCancel(contact, payload);
        return;
      case 'attachment_pause_control':
        _handleAttachmentPauseControl(contact, payload);
        return;
      case 'attachment_progress':
        _handleAttachmentProgress(contact, payload);
        return;
    }
  }

  Future<void> _handleAttachmentOffer(
    ContactRecord sender,
    RelayEnvelope envelope,
    Map<String, dynamic> payload,
  ) async {
    // nightly.10: cache the sender's LAN-direct endpoint from the offer
    // so the very first chunk_request we issue can go via direct HTTP
    // instead of round-tripping through the relay.
    _cachePeerLanDirectFromPayload(sender.deviceId, payload);
    final descriptorJson = payload['descriptor'];
    if (descriptorJson is! Map<String, dynamic>) {
      return;
    }
    final AttachmentDescriptor descriptor;
    try {
      descriptor = _validateIncomingAttachmentDescriptor(
        AttachmentDescriptor.fromJson(descriptorJson),
      );
    } catch (_) {
      _setTransientStatus(
        'Rejected malformed attachment offer from ${sender.alias}.',
      );
      return;
    }
    final rawDebugTest = payload['debugFileTest'];
    final debugTest = DebugAttachmentTestSpec.tryParse(rawDebugTest);
    final debugAuthorization = debugTest == null
        ? null
        : _authorizedInboundDebugFileTests.remove(debugTest.testId);
    final debugAuthorized =
        debugAuthorization != null &&
        debugAuthorization.peerDeviceId == sender.deviceId &&
        debugAuthorization.expiresAt.isAfter(_now().toUtc());
    if (rawDebugTest != null &&
        (debugTest == null ||
            _debugBuildId == null ||
            debugTest.buildId != _debugBuildId ||
            !debugAuthorized ||
            debugAuthorization.irohOnly != debugTest.irohOnly ||
            descriptor.mimeType != 'application/x-conest-transfer-test' ||
            descriptor.sizeBytes != debugTest.sizeMiB * 1024 * 1024)) {
      appendDebugLog(
        'Rejected automatic file-test offer from ${sender.alias}: '
        'debug build/protocol mismatch.',
      );
      return;
    }
    // Dedupe: if we already have an inbound ChatMessage with this exact
    // descriptor id, skip — a stray duplicate offer envelope (envelope-seen
    // cache miss, retry, double-poll) would otherwise create a second
    // ghost bubble with the same attachment.
    final existingInbound = _inboundAttachments[descriptor.id];
    if (existingInbound != null ||
        _outboundAttachments.containsKey(descriptor.id) ||
        _snapshot.conversations.any(
          (conversation) => conversation.messages.any(
            (message) => message.attachment?.id == descriptor.id,
          ),
        )) {
      appendDebugLog(
        'Dropping duplicate attachment_offer for ${descriptor.id} '
        'from ${sender.alias}.',
      );
      return;
    }
    final rawCaptionValue = payload['caption'];
    final rawCaption = rawCaptionValue ?? '';
    final rawAlbumId = payload['albumId'];
    final parentMessageId = payload['parentMessageId'];
    if (rawCaption is! String ||
        rawCaption.length > 4096 ||
        rawAlbumId != null &&
            (rawAlbumId is! String ||
                rawAlbumId.length > 160 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(rawAlbumId)) ||
        parentMessageId != null &&
            (parentMessageId is! String ||
                parentMessageId.isEmpty ||
                parentMessageId.length > 160)) {
      _setTransientStatus('Rejected invalid attachment metadata.');
      return;
    }
    Uint8List? posterBytes;
    final manifestThumbnail = descriptor.thumbnailBase64;
    if (manifestThumbnail != null) {
      try {
        posterBytes = base64Decode(manifestThumbnail);
      } catch (_) {
        return;
      }
      if (posterBytes.length > 32 * 1024) return;
    }
    final posterValue = payload['posterBase64'];
    if (posterBytes == null && posterValue != null) {
      if (posterValue is! String || posterValue.isEmpty) return;
      try {
        posterBytes = base64Decode(posterValue);
      } catch (_) {
        return;
      }
      if (posterBytes.length > 32 * 1024) return;
    }
    final me = _requireIdentity();
    final message = ChatMessage(
      id: _randomId('msg'),
      conversationId: _crypto.conversationIdFor(sender.deviceId),
      senderDeviceId: sender.deviceId,
      recipientDeviceId: me.deviceId,
      body: rawCaption,
      outbound: false,
      state: DeliveryState.pending,
      createdAt: envelope.createdAt,
      senderDisplayName: sender.alias,
      attachment: descriptor,
      albumId: rawAlbumId as String?,
    );
    _upsertMessage(sender.deviceId, message);
    // Decode + cache the video poster (if any) so the bubble can render
    // a thumbnail before the full bytes finish transferring.
    if (posterBytes != null) {
      _videoPosters[descriptor.id] = posterBytes;
    }
    final wasIdle = !hasActiveTransfer;
    final requiresLan = descriptor.sizeBytes > maxAttachmentSizeBytes;
    final directAvailable = _hasUsableLargeDirectTransport(sender);
    final autoDownload =
        debugTest != null ||
        (_snapshot.identity?.connectivity.autoDownloadPreset ??
                AutoDownloadPreset.medium)
            .allows(
              mimeType: descriptor.mimeType,
              sizeBytes: descriptor.sizeBytes,
              network: _networkCostClass,
              verifiedContact: sender.canSendOutbound,
            );
    final awaitingAcceptance =
        debugTest == null &&
        (!autoDownload || (requiresLan && !directAvailable));
    final preparation = awaitingAcceptance
        ? (path: null, error: null, reserveBlocked: false)
        : await _createInboundPartialFile(descriptor);
    final partialPath = preparation.path;
    final inboundState = _InboundAttachmentState(
      messageId: message.id,
      peerDeviceId: sender.deviceId,
      descriptor: descriptor,
      partialPath: partialPath,
      awaitingAcceptance: awaitingAcceptance || partialPath == null,
      accepted: !awaitingAcceptance && partialPath != null,
      debugTest: debugTest,
    );
    _inboundAttachments[descriptor.id] = inboundState;
    _upsertTransferSession(
      TransferSession(
        id: descriptor.id,
        attachment: descriptor,
        peerDeviceIds: <String>[sender.deviceId],
        state: awaitingAcceptance
            ? TransferState.pending
            : partialPath == null
            ? TransferState.waitingForStorage
            : requiresLan && !directAvailable
            ? TransferState.waitingForLan
            : TransferState.transferring,
        completedChunks: const <int>[],
        createdAt: descriptor.createdAt,
        updatedAt: _now().toUtc(),
        direction: TransferDirection.inbound,
        messageId: message.id,
        relativePath: partialPath == null
            ? ''
            : p.relative(partialPath, from: (await _attachmentRoot()).path),
        sourceKind: TransferSourceKind.partialFile,
        requiresLan: requiresLan,
        lastError: preparation.error,
        storageReserveBlocked: preparation.reserveBlocked,
      ),
    );
    await _saveSnapshotSilently(notify: false);
    // Active transfer just started — boost the poll cadence so chunk
    // envelopes that fall back to relay polling get picked up in 1 s
    // instead of the idle 15 s.
    if (wasIdle) _reschedulePolling();
    // Schedule a retry timer that re-requests the next missing chunk if no
    // chunk arrives within 5 s. Caps at 12 retries before giving up.
    if (partialPath != null && !awaitingAcceptance) {
      _scheduleAttachmentRetry(descriptor.id);
    }
    notifyListeners();
    // Prime the chunk-request window as a microtask so it lands AFTER the
    // current `_processEnvelopes` batch commits its state. Without this,
    // back-to-back offers (multi-file send) could race: file 1's chunk
    // request could fire before file 1's `_outboundAttachments` entry on
    // the sender side was visible to the chunk-request handler that
    // bounces through the local-relay loopback.
    if (partialPath != null && !awaitingAcceptance) {
      Future.microtask(() => _startInboundRequestWindow(inboundState, sender));
    } else if (debugTest != null) {
      Future.microtask(
        () => _finishRejectedDebugFileTest(
          sender: sender,
          state: inboundState,
          detail: 'Receiver could not allocate the verified partial file.',
        ),
      );
    }
  }

  AttachmentDescriptor _validateIncomingAttachmentDescriptor(
    AttachmentDescriptor descriptor,
  ) {
    final now = _now().toUtc();
    final createdAt = descriptor.createdAt.toUtc();
    final safeFileName = sanitizeAttachmentFileName(descriptor.fileName);
    if (descriptor.id.isEmpty ||
        descriptor.id.length > 160 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(descriptor.id) ||
        descriptor.sizeBytes <= 0 ||
        descriptor.sizeBytes > maxLanAttachmentSizeBytes ||
        descriptor.chunkCount <= 0 ||
        descriptor.protocolVersion != 2 ||
        descriptor.chunkHashes.isNotEmpty ||
        (descriptor.chunkSize != _attachmentChunkSize &&
            descriptor.chunkSize != _lanAttachmentChunkSize) ||
        descriptor.effectiveChunkCount <= 0 ||
        descriptor.effectiveChunkCount > 16384 ||
        descriptor.effectiveChunkCount !=
            (descriptor.sizeBytes + descriptor.chunkSize - 1) ~/
                descriptor.chunkSize ||
        descriptor.fileHashBase64.isEmpty ||
        descriptor.fileName != safeFileName ||
        !isValidAttachmentMimeType(descriptor.mimeType) ||
        createdAt.isAfter(now.add(const Duration(days: 1))) ||
        createdAt.isBefore(now.subtract(const Duration(days: 30)))) {
      throw const FormatException('Attachment descriptor is out of range.');
    }
    if (descriptor.sizeBytes > maxAttachmentSizeBytes &&
        descriptor.chunkSize != _lanAttachmentChunkSize) {
      throw const FormatException('Large attachments require LAN chunks.');
    }
    if (base64Decode(descriptor.fileHashBase64).length != 32 ||
        base64Decode(descriptor.encryptionKeyBase64).length != 32 ||
        base64Decode(descriptor.noncePrefixBase64).length != 16 ||
        (descriptor.thumbnailBase64 != null &&
            base64Decode(descriptor.thumbnailBase64!).length > 32 * 1024)) {
      throw const FormatException('Attachment descriptor keys are invalid.');
    }
    return AttachmentDescriptor(
      id: descriptor.id,
      fileName: safeFileName,
      mimeType: descriptor.mimeType,
      sizeBytes: descriptor.sizeBytes,
      chunkSize: descriptor.chunkSize,
      chunkHashes: const <ChunkHash>[],
      chunkCount: descriptor.effectiveChunkCount,
      fileHashBase64: descriptor.fileHashBase64,
      encryptionKeyBase64: descriptor.encryptionKeyBase64,
      protocolVersion: descriptor.protocolVersion,
      noncePrefixBase64: descriptor.noncePrefixBase64,
      presentation: descriptor.presentation,
      thumbnailBase64: descriptor.thumbnailBase64,
      createdAt: createdAt,
    );
  }

  Future<({String? path, String? error, bool reserveBlocked})>
  _createInboundPartialFile(
    AttachmentDescriptor descriptor, {
    bool ignoreStorageReserve = false,
  }) async {
    final root = await _attachmentRoot();
    final capacity = await _storageCapacityProvider(root.path);
    final reserve = ignoreStorageReserve ? 0.0 : _storageReserveFraction;
    if (capacity == null ||
        !capacity.canAllocate(descriptor.sizeBytes, reserveFraction: reserve)) {
      final reserveBlocked =
          capacity != null &&
          reserve > 0 &&
          capacity.canAllocate(descriptor.sizeBytes, reserveFraction: 0);
      final error = capacity == null
          ? 'Could not check available storage. Try again.'
          : reserveBlocked
          ? 'Not enough storage is available while keeping the 10% free-space reserve.'
          : 'Not enough free storage for this file. Free up space and try again.';
      _setTransientStatus(error);
      return (path: null, error: error, reserveBlocked: reserveBlocked);
    }
    final partialDir = Directory(p.join(root.path, 'partial'));
    await partialDir.create(recursive: true);
    final file = File(
      p.join(partialDir.path, '${attachmentStorageKey(descriptor.id)}.part'),
    );
    await file.create(recursive: true);
    await restrictFileToOwner(file);
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.truncate(descriptor.sizeBytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    return (path: file.path, error: null, reserveBlocked: false);
  }

  Future<void> _sendAttachmentChunkRequest(
    ContactRecord peer,
    String attachmentId,
    int index,
  ) async {
    final me = _requireIdentity();
    final inbound = _inboundAttachments[attachmentId];
    if (inbound == null || !inbound.accepted || inbound.partialPath == null) {
      return;
    }
    final requiresLan = inbound.descriptor.sizeBytes > maxAttachmentSizeBytes;
    // nightly.9: piggy-back our LAN-direct endpoint hint so the sender
    // can PUT subsequent chunks directly to our HTTP server instead of
    // round-tripping through the relay envelope shape.
    final hint = _localLanDirectHintPayload();
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'attachment_chunk_request',
      messageId: _randomId('areq'),
      conversationId: _crypto.conversationIdFor(peer.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: peer.deviceId,
      contact: peer,
      plaintext: jsonEncode({
        'attachmentId': attachmentId,
        'index': index,
        'senderIrohBinaryVersion': 1,
        ...hint,
      }),
    );
    // nightly.10: LAN-direct fast-path for chunk_request too. If the peer
    // advertised their port in the offer/chunk_request hint, push this
    // request straight to their HTTP server instead of round-tripping
    // through the relay. Together with the chunk-response fast-path from
    // nightly.9 this gives full LAN symmetry — zero relay round-trips
    // for the chunk loop once the offer lands.
    final lanDirectChannel = _lanDirectChannel;
    final lanDirectEndpoint = _peerLanDirect[peer.deviceId];
    if (inbound.debugTest?.irohOnly != true &&
        _effectiveTransports(peer).lan &&
        lanDirectChannel != null &&
        lanDirectChannel.isRunning &&
        lanDirectEndpoint != null &&
        _lanDirectEndpointUsable(lanDirectEndpoint)) {
      final ok = await lanDirectChannel.putEnvelope(
        host: lanDirectEndpoint.host,
        port: lanDirectEndpoint.port,
        envelope: envelope,
        timeout: const Duration(seconds: 5),
      );
      // nightly.12: per-attempt route log so the user can audit why a
      // transfer felt slow without instrumenting their own session.
      appendDebugLog(
        'LAN-direct PUT chunk_request to ${peer.alias} '
        '${lanDirectEndpoint.host}:${lanDirectEndpoint.port} '
        'result=${ok ? "ok" : "fail"}',
      );
      if (ok) {
        _onLanDirectPutSuccess(peer.deviceId);
        if (requiresLan) {
          _setTransferSessionState(attachmentId, TransferState.transferring);
        }
        return;
      }
      unawaited(_onLanDirectPutFailure(peer.deviceId));
    }
    try {
      await _deliverToContact(
        contact: peer,
        recipientDeviceId: peer.deviceId,
        envelope: envelope,
        allowRelayedPaths: inbound.debugTest?.irohOnly != true,
        allowLegacyRoutes: inbound.debugTest?.irohOnly != true,
        allowedUnifiedKinds: inbound.debugTest?.irohOnly == true
            ? {TransportKind.iroh}
            : null,
      );
    } catch (error) {
      // Retry on next poll cycle; the receiver still has the inbound
      // state, so the request will be re-issued.
      appendDebugLog(
        'chunk_req route failed → ${peer.alias} idx=$index '
        'attachmentId=$attachmentId: $error',
      );
      inbound.requestedInFlight.remove(index);
    }
  }

  Future<void> _handleAttachmentChunkRequest(
    ContactRecord requester,
    Map<String, dynamic> payload,
  ) async {
    final id = payload['attachmentId'];
    final index = payload['index'];
    if (id is! String || index is! int) return;
    final key = '${requester.deviceId}|$id|$index';
    if (!_servingAttachmentBlocks.add(key)) return;
    try {
      await _serveAttachmentChunkRequest(requester, payload);
    } finally {
      _servingAttachmentBlocks.remove(key);
    }
  }

  Future<void> _serveAttachmentChunkRequest(
    ContactRecord requester,
    Map<String, dynamic> payload,
  ) async {
    final attachmentId = payload['attachmentId'] as String?;
    final index = payload['index'] as int?;
    if (attachmentId == null || index == null) {
      return;
    }
    final irohBinaryVersionValue = payload['senderIrohBinaryVersion'];
    if (irohBinaryVersionValue != null &&
        (irohBinaryVersionValue is! int ||
            irohBinaryVersionValue < 0 ||
            irohBinaryVersionValue > 1)) {
      return;
    }
    final irohBinarySupported = irohBinaryVersionValue == 1;
    // nightly.9: cache the requester's LAN-direct endpoint if they
    // advertised one. Subsequent chunk responses can PUT directly to
    // their HTTP server instead of round-tripping the relay.
    _cachePeerLanDirectFromPayload(requester.deviceId, payload);
    final state = _outboundAttachments[attachmentId];
    if (state == null || state.peerDeviceId != requester.deviceId) {
      // Sender no longer has this attachment (deleted, canceled, or never
      // existed across a reinstall) — proactively cancel so the receiver
      // stops asking for chunks that will never arrive.
      unawaited(_sendAttachmentCancel(requester, attachmentId));
      return;
    }
    if (_messageById(state.peerDeviceId, state.messageId) == null) {
      // Parent message was locally deleted; tear down outbound state and
      // notify the receiver.
      _outboundAttachments.remove(attachmentId);
      _clearActiveOutbound(state.peerDeviceId, attachmentId);
      final peerContact = _contactByDeviceId(state.peerDeviceId);
      if (peerContact != null) _pumpOutboundQueue(peerContact);
      unawaited(_sendAttachmentCancel(requester, attachmentId));
      return;
    }
    // Honor the bilateral pause: silently drop the chunk request so the
    // receiver's retry timer just keeps idling. When the paused side
    // resumes, the next chunk request flows through here normally.
    if (state.paused) {
      return;
    }
    bool stillActive() =>
        identical(_outboundAttachments[attachmentId], state) && !state.paused;
    if (index < 0 || index >= state.descriptor.effectiveChunkCount) {
      return;
    }
    final irohOnly =
        _outboundDebugAttachmentTests[attachmentId]?.irohOnly == true;
    final allowLargeIrohRelay =
        state.requiresLan &&
        !state.lanOnly &&
        _largeIrohRelayAllowed(attachmentId);
    if (state.requiresLan &&
        !allowLargeIrohRelay &&
        (state.lanOnly
            ? !_hasUsableLanDirectEndpoint(requester.deviceId)
            : !_hasUsableLargeDirectTransport(requester))) {
      _setTransferSessionState(
        attachmentId,
        TransferState.waitingForLan,
        error: 'Waiting for LAN or direct Iroh; relay use is not automatic.',
      );
      return;
    }
    final Uint8List chunkBytes;
    try {
      chunkBytes = await _readOutboundAttachmentChunk(state, index);
    } catch (error) {
      if (!stillActive()) return;
      _setTransferSessionState(
        attachmentId,
        TransferState.failed,
        error: error.toString(),
      );
      _updateMessageState(
        state.peerDeviceId,
        state.messageId,
        DeliveryState.failed,
      );
      return;
    }
    if (!stillActive()) return;
    final encryptedBlock = await _encryptAttachmentBlock(
      state.descriptor,
      index,
      chunkBytes,
    );
    if (!stillActive()) return;
    final digestBytes = encryptedBlock.hash;
    final packedChunk = encryptedBlock.ciphertext;
    // Binary LAN v2: the attachment block already has end-to-end AEAD and a
    // manifest-bound nonce/AAD. Send those bytes directly instead of paying
    // for a second pairwise encryption plus nested JSON/base64 expansion.
    final lanChannel = _lanDirectChannel;
    final binaryLanChannel = lanChannel is BinaryLanDirectChannel
        ? lanChannel as BinaryLanDirectChannel
        : null;
    final binaryLanEndpoint = _peerLanDirect[requester.deviceId];
    if (!irohOnly &&
        _effectiveTransports(requester).lan &&
        binaryLanChannel != null &&
        binaryLanEndpoint != null &&
        binaryLanEndpoint.binaryBlockVersion >= 1 &&
        _lanDirectEndpointUsable(binaryLanEndpoint)) {
      var ok = await binaryLanChannel.putAttachmentBlock(
        host: binaryLanEndpoint.host,
        port: binaryLanEndpoint.port,
        block: LanAttachmentBlock(
          attachmentId: attachmentId,
          index: index,
          hash: digestBytes,
          ciphertext: packedChunk,
        ),
        timeout: const Duration(seconds: 30),
      );
      if (!stillActive()) return;
      if (!ok) {
        // The block is immutable, independently authenticated, and
        // idempotent by attachment/index. One quick retry absorbs Wi-Fi
        // handoff/socket churn without forcing the receiver to wait for its
        // conservative 30-second durable-range timer.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!stillActive()) return;
        ok = await binaryLanChannel.putAttachmentBlock(
          host: binaryLanEndpoint.host,
          port: binaryLanEndpoint.port,
          block: LanAttachmentBlock(
            attachmentId: attachmentId,
            index: index,
            hash: digestBytes,
            ciphertext: packedChunk,
          ),
          timeout: const Duration(seconds: 30),
        );
        if (!stillActive()) return;
        appendDebugLog(
          'LAN-binary immediate retry chunk[$index] to ${requester.alias} '
          'result=${ok ? "ok" : "fail"}',
        );
      }
      appendDebugLog(
        'LAN-binary PUT chunk[$index] to ${requester.alias} '
        '${binaryLanEndpoint.host}:${binaryLanEndpoint.port} '
        'result=${ok ? "ok" : "fail"}',
      );
      if (ok) {
        _onLanDirectPutSuccess(requester.deviceId);
        if (_activeOutboundByContact[state.peerDeviceId] == attachmentId) {
          if (index > state.highestChunkSent) state.highestChunkSent = index;
          state.lastChunkAt = DateTime.now().toUtc();
          state.consecutiveChunkFailures = 0;
          state.lastDeliveryRoute = OutboundDeliveryRoute.lanDirect;
          _armOutboundStallTimer(requester);
          notifyListeners();
        }
        return;
      }
      unawaited(_onLanDirectPutFailure(requester.deviceId));
      if (state.descriptor.chunkSize > _attachmentChunkSize) {
        _setTransferSessionState(
          attachmentId,
          TransferState.reconnecting,
          error: 'Binary LAN block failed; retrying without losing progress.',
        );
        // The peer explicitly advertised binary v1. A failed PUT is a
        // transient path failure, not evidence of protocol incompatibility;
        // the receiver's durable-range retry will request this same block.
        return;
      }
    }
    if (irohBinarySupported && !state.lanOnly) {
      final allowIrohRelay =
          !irohOnly && (!state.requiresLan || allowLargeIrohRelay);
      try {
        final receipt = await _deliverIrohAttachmentRange(
          contact: requester,
          range: AttachmentRange(
            attachmentId: attachmentId,
            offset: index * state.descriptor.chunkSize,
            bytes: packedChunk,
            sha256Base64: base64Encode(digestBytes),
          ),
          allowRelay: allowIrohRelay,
        );
        if (receipt != null) {
          appendDebugLog(
            'Iroh-binary stream chunk[$index] to ${requester.alias} '
            'path=${receipt.route.path.name}',
          );
          if (_activeOutboundByContact[state.peerDeviceId] == attachmentId) {
            if (index > state.highestChunkSent) {
              state.highestChunkSent = index;
            }
            state.lastChunkAt = DateTime.now().toUtc();
            state.consecutiveChunkFailures = 0;
            state.lastDeliveryRoute =
                receipt.route.path == TransportPathKind.relayed
                ? OutboundDeliveryRoute.irohRelay
                : OutboundDeliveryRoute.irohDirect;
            _armOutboundStallTimer(requester);
            notifyListeners();
          }
          return;
        }
      } catch (error) {
        appendDebugLog(
          'Iroh-binary stream chunk[$index] to ${requester.alias} failed: '
          '$error',
        );
      }
      if (!stillActive()) return;
      if (state.requiresLan || irohOnly) {
        _setTransferSessionState(
          attachmentId,
          allowIrohRelay
              ? TransferState.reconnecting
              : TransferState.waitingForLan,
          error: allowIrohRelay
              ? 'Iroh path failed; retrying the verified block.'
              : 'Direct Iroh is unavailable; waiting without using a relay.',
        );
        return;
      }
    }
    if (state.descriptor.chunkSize > _attachmentChunkSize) {
      _setTransferSessionState(
        attachmentId,
        TransferState.failed,
        error:
            'The peer does not support binary direct attachment blocks. '
            'Update Conest on both devices and retry.',
      );
      return;
    }
    final chunk = AttachmentChunk(
      attachmentId: attachmentId,
      index: index,
      ciphertextBase64: base64Encode(packedChunk),
      hashBase64: base64Encode(digestBytes),
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
    if (!stillActive()) return;
    final preferredPrimaryKey = _preferredRoutesForContact(
      requester,
    ).firstOrNull?.routeKey;
    // nightly.9 LAN-direct fast-path: if the requester recently advertised
    // a LAN-direct endpoint and we have a channel to PUT through, try it
    // before the relay-shaped delivery. Success skips ALL relay round-trips.
    final lanDirectChannel = _lanDirectChannel;
    final lanDirectEndpoint = _peerLanDirect[requester.deviceId];
    if (lanDirectChannel != null &&
        lanDirectChannel.isRunning &&
        lanDirectEndpoint != null &&
        _lanDirectEndpointUsable(lanDirectEndpoint)) {
      final ok = await lanDirectChannel.putEnvelope(
        host: lanDirectEndpoint.host,
        port: lanDirectEndpoint.port,
        envelope: envelope,
        timeout: const Duration(seconds: 5),
      );
      if (!stillActive()) return;
      // nightly.12: per-attempt route log for chunks too.
      appendDebugLog(
        'LAN-direct PUT chunk[$index] to ${requester.alias} '
        '${lanDirectEndpoint.host}:${lanDirectEndpoint.port} '
        'result=${ok ? "ok" : "fail"}',
      );
      if (ok) {
        _onLanDirectPutSuccess(requester.deviceId);
        if (_activeOutboundByContact[state.peerDeviceId] == attachmentId) {
          if (index > state.highestChunkSent) {
            state.highestChunkSent = index;
          }
          state.lastChunkAt = DateTime.now().toUtc();
          state.consecutiveChunkFailures = 0;
          state.lastDeliveryRoute = OutboundDeliveryRoute.lanDirect;
          _armOutboundStallTimer(requester);
          notifyListeners();
        }
        return;
      }
      unawaited(_onLanDirectPutFailure(requester.deviceId));
      appendDebugLog(
        state.requiresLan
            ? 'LAN-direct PUT to ${requester.alias} failed; waiting for LAN.'
            : 'LAN-direct PUT to ${requester.alias} failed; falling back to relay.',
      );
    }
    if (state.lanOnly) {
      _setTransferSessionState(
        attachmentId,
        TransferState.waitingForLan,
        error: 'LAN diagnostic is waiting for the peer LAN endpoint.',
      );
      return;
    }
    if (state.requiresLan &&
        !allowLargeIrohRelay &&
        !_hasUsableLargeDirectTransport(requester)) {
      _setTransferSessionState(
        attachmentId,
        TransferState.waitingForLan,
        error: 'Direct delivery unavailable; relay use is not automatic.',
      );
      return;
    }
    try {
      final deliveredVia = await _deliverToContact(
        contact: requester,
        recipientDeviceId: requester.deviceId,
        envelope: envelope,
        allowRelayedPaths: !state.requiresLan || allowLargeIrohRelay,
        allowLegacyRoutes: !state.requiresLan,
        allowedUnifiedKinds: state.requiresLan
            ? const <TransportKind>{TransportKind.iroh}
            : null,
      );
      // Sender progress + stall-timer activity refresh. Only advance if
      // this is the active outbound for this contact (the receiver could
      // be re-requesting after a stale state).
      if (_activeOutboundByContact[state.peerDeviceId] == attachmentId) {
        if (index > state.highestChunkSent) {
          state.highestChunkSent = index;
        }
        state.lastChunkAt = DateTime.now().toUtc();
        state.consecutiveChunkFailures = 0;
        state.lastDeliveryRoute = switch ((
          deliveredVia.transportKind,
          deliveredVia.path,
        )) {
          (TransportKind.iroh, TransportPathKind.direct) =>
            OutboundDeliveryRoute.irohDirect,
          (TransportKind.iroh, TransportPathKind.relayed) =>
            OutboundDeliveryRoute.irohRelay,
          _ => OutboundDeliveryRoute.conestRelay,
        };
        // If the delivered route is NOT the preferred primary, surface
        // "Rerouting · X%" on the bubble for the next few seconds so the
        // user sees the fallback is working.
        if (preferredPrimaryKey != null &&
            deliveredVia.routeKey != preferredPrimaryKey) {
          state.lastRouteFallbackAt = DateTime.now().toUtc();
        }
        _armOutboundStallTimer(requester);
        notifyListeners();
      }
    } catch (error) {
      if (!stillActive()) return;
      state.consecutiveChunkFailures++;
      appendDebugLog(
        'Chunk $index for $attachmentId: all routes failed '
        '(streak ${state.consecutiveChunkFailures}) — $error',
      );
      // Bump the rerouting hint even on a hard failure so the bubble
      // does not look frozen while the receiver retries.
      if (state.consecutiveChunkFailures >= 2) {
        state.lastRouteFallbackAt = DateTime.now().toUtc();
        notifyListeners();
      }
      if (state.requiresLan && !allowLargeIrohRelay) {
        _setTransferSessionState(
          attachmentId,
          TransferState.waitingForLan,
          error:
              'Direct route unavailable. Continue over Iroh relay or wait for direct.',
        );
      } else {
        _setTransferSessionState(
          attachmentId,
          TransferState.reconnecting,
          error: 'Transfer route failed; retrying without losing progress.',
        );
      }
    }
  }

  Future<Uint8List> _readOutboundAttachmentChunk(
    _OutboundAttachmentState state,
    int index,
  ) async {
    final file = File(state.sourcePath);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size != state.descriptor.sizeBytes) {
      throw const FormatException('Attachment source is missing or changed.');
    }
    if (state.sourceKind == TransferSourceKind.originalPath) {
      final session = _transferSessionById(state.descriptor.id);
      final expectedModified = session?.sourceModifiedAt;
      if (expectedModified != null && stat.modified != expectedModified) {
        throw const FormatException('Original attachment source was modified.');
      }
    }
    final offset = index * state.descriptor.chunkSize;
    final expectedLength = min(
      state.descriptor.chunkSize,
      state.descriptor.sizeBytes - offset,
    );
    if (offset < 0 || expectedLength <= 0) {
      throw const FormatException('Attachment chunk offset is invalid.');
    }
    final bytes = await state.readChunk(offset, expectedLength);
    if (bytes.length != expectedLength) {
      throw const FormatException('Attachment source ended unexpectedly.');
    }
    return bytes;
  }

  Future<({Uint8List ciphertext, Uint8List hash})> _encryptAttachmentBlock(
    AttachmentDescriptor descriptor,
    int index,
    Uint8List plaintext,
  ) async {
    final key = base64Decode(descriptor.encryptionKeyBase64);
    final nonce = Uint8List.fromList(_attachmentBlockNonce(descriptor, index));
    final aad = Uint8List.fromList(
      _attachmentChunkAssociatedData(descriptor, index, plaintext.length),
    );
    final native = _nativeAttachmentCrypto;
    if (native != null) {
      try {
        final encrypted = native.encrypt(
          key: key,
          nonce: nonce,
          aad: aad,
          plaintext: plaintext,
        );
        return (
          ciphertext: encrypted.ciphertext,
          hash: encrypted.plaintextSha256,
        );
      } catch (error) {
        appendDebugLog(
          'Native attachment encryption failed; using compatible Dart path: '
          '$error',
        );
      }
    }
    final digest = await Sha256().hash(plaintext);
    final chunkCipher = Xchacha20.poly1305Aead();
    final encrypted = await chunkCipher.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    return (
      ciphertext: Uint8List.fromList(<int>[
        ...encrypted.cipherText,
        ...encrypted.mac.bytes,
      ]),
      hash: Uint8List.fromList(digest.bytes),
    );
  }

  Future<void> _handleAttachmentChunk(
    ContactRecord sender,
    Map<String, dynamic> payload,
  ) async {
    final chunk = AttachmentChunk.fromJson(payload);
    if (chunk.attachmentId.isEmpty ||
        chunk.attachmentId.length > 160 ||
        chunk.ciphertextBase64.length >
            _maxAttachmentChunkCiphertextBase64Bytes ||
        chunk.hashBase64.length > 64) {
      return;
    }
    final Uint8List packedBytes;
    final Uint8List expectedHash;
    try {
      packedBytes = base64Decode(chunk.ciphertextBase64);
      expectedHash = base64Decode(chunk.hashBase64);
      if (expectedHash.length != 32) return;
    } catch (_) {
      return;
    }
    await _handleAttachmentChunkBytes(
      sender,
      attachmentId: chunk.attachmentId,
      index: chunk.index,
      packedBytes: packedBytes,
      expectedHash: expectedHash,
    );
  }

  Future<void> _handleAttachmentChunkBytes(
    ContactRecord sender, {
    required String attachmentId,
    required int index,
    required Uint8List packedBytes,
    required Uint8List expectedHash,
  }) async {
    final key = '${sender.deviceId}|$attachmentId|$index';
    if (!_receivingAttachmentBlocks.add(key)) return;
    try {
      await _receiveAttachmentChunkBytes(
        sender,
        attachmentId: attachmentId,
        index: index,
        packedBytes: packedBytes,
        expectedHash: expectedHash,
      );
    } finally {
      _receivingAttachmentBlocks.remove(key);
    }
  }

  Future<void> _receiveAttachmentChunkBytes(
    ContactRecord sender, {
    required String attachmentId,
    required int index,
    required Uint8List packedBytes,
    required Uint8List expectedHash,
  }) async {
    if (attachmentId.isEmpty ||
        attachmentId.length > 160 ||
        expectedHash.length != 32) {
      return;
    }
    final state = _inboundAttachments[attachmentId];
    if (state == null || state.peerDeviceId != sender.deviceId) {
      return;
    }
    // Janitor: if the parent ChatMessage is gone (locally deleted), drop
    // the inbound state silently. The next chunk-request retry that the
    // sender's `_handleAttachmentChunkRequest` sees will trigger the
    // sender-side cancel echo too.
    if (_messageById(state.peerDeviceId, state.messageId) == null) {
      state.retryTimer?.cancel();
      _inboundAttachments.remove(attachmentId);
      if (!hasActiveTransfer) _reschedulePolling();
      return;
    }
    if (!state.accepted ||
        state.partialPath == null ||
        index < 0 ||
        index >= state.descriptor.effectiveChunkCount) {
      return;
    }
    final offset = index * state.descriptor.chunkSize;
    final expectedLength = min(
      state.descriptor.chunkSize,
      state.descriptor.sizeBytes - offset,
    );
    const authenticationTagLength = 16;
    if (packedBytes.length != expectedLength + authenticationTagLength) {
      state.requestedInFlight.remove(index);
      return;
    }
    final Uint8List bytes;
    try {
      final key = base64Decode(state.descriptor.encryptionKeyBase64);
      final nonce = Uint8List.fromList(
        _attachmentBlockNonce(state.descriptor, index),
      );
      final aad = Uint8List.fromList(
        _attachmentChunkAssociatedData(state.descriptor, index, expectedLength),
      );
      final native = _nativeAttachmentCrypto;
      if (native != null) {
        bytes = native.decrypt(
          key: key,
          nonce: nonce,
          aad: aad,
          ciphertext: packedBytes,
          expectedPlaintextSha256: expectedHash,
        );
      } else {
        final cipher = Xchacha20.poly1305Aead();
        final macStart = packedBytes.length - cipher.macAlgorithm.macLength;
        bytes = Uint8List.fromList(
          await cipher.decrypt(
            SecretBox(
              packedBytes.sublist(0, macStart),
              nonce: nonce,
              mac: Mac(packedBytes.sublist(macStart)),
            ),
            secretKey: SecretKey(key),
            aad: aad,
          ),
        );
        final digest = await Sha256().hash(bytes);
        if (!_attachmentBytesEqual(digest.bytes, expectedHash)) {
          throw const FormatException('Attachment block digest mismatch.');
        }
      }
    } catch (_) {
      state.requestedInFlight.remove(index);
      if (!identical(_inboundAttachments[attachmentId], state) ||
          state.finalizing) {
        return;
      }
      await _sendAttachmentChunkRequest(sender, attachmentId, index);
      return;
    }
    if (!identical(_inboundAttachments[attachmentId], state) ||
        state.finalizing) {
      return;
    }
    if (!state.received.contains(index)) {
      await state.writeChunk(offset, bytes);
      if (!identical(_inboundAttachments[attachmentId], state)) return;
      state.received.add(index);
      state.recordProgress();
      // Persist only crash-safe checkpoints. The old path flushed, closed and
      // rewrote the encrypted vault for every block, which made large files
      // progressively slower. A crash can now replay at most 8 MiB / 2 s.
      if (state.shouldCheckpoint || state.isComplete) {
        await _checkpointInboundTransfer(attachmentId, state);
      } else {
        _scheduleInboundCheckpoint(attachmentId, state);
      }
    }
    // Whatever the path was, this index is no longer outstanding.
    state.requestedInFlight.remove(index);
    // Reset the retry budget on any successful chunk arrival; the transfer
    // is making forward progress so we don't need to escalate.
    state.retryAttempts = 0;
    state.nextRetryAt = null;
    appendDebugLog(
      'chunk_resp rx ← ${sender.alias} idx=$index '
      '${bytes.length}B attachmentId=$attachmentId',
    );
    // Tell the sender how many chunks we now have so its bubble can show
    // the same percentage we do (nightly.8 LocalSend-style sync). The
    // debounce inside the helper caps to one envelope per 250 ms; the
    // completion path below forces a final emit so the sender flips to
    // 100% in lockstep with us.
    _maybeSendAttachmentProgress(state, sender, force: state.isComplete);
    if (state.isComplete) {
      await _finalizeInboundAttachment(sender, attachmentId, state);
    } else if (state.paused) {
      // Paused mid-transfer — sit on the chunks we have. The owner-only
      // resume re-arms the retry timer and re-issues the next request.
    } else {
      _scheduleAttachmentRetry(attachmentId);
      // Pipelined refill: keep up to _inboundChunkWindow requests in
      // flight so a slow path doesn't serialize on per-chunk RTT.
      _startInboundRequestWindow(state, sender);
    }
  }

  Future<void> _finalizeInboundAttachment(
    ContactRecord sender,
    String attachmentId,
    _InboundAttachmentState state,
  ) async {
    // Several independently handled blocks can observe completion before the
    // first finalizer's awaits finish. Only one may verify/promote the
    // partial: a second finalizer could otherwise delete the first one's newly
    // promoted cache file and then fail to rename the vanished part.
    if (state.finalizing || !state.isComplete || state.partialPath == null) {
      return;
    }
    state.finalizing = true;
    try {
      state.retryTimer?.cancel();
      await state.checkpoint();
      await state.closeFile();
      final partial = File(state.partialPath!);
      final wholeDigest = await dart_crypto.sha256
          .bind(partial.openRead())
          .first;
      if (base64Encode(wholeDigest.bytes) != state.descriptor.fileHashBase64) {
        if (state.debugTest != null) {
          try {
            await _sendDebugFileTestResult(
              contact: sender,
              state: state,
              success: false,
              bytesVerified: 0,
              detail: 'Whole-file SHA-256 mismatch.',
            );
          } catch (_) {}
        }
        _setTransferSessionState(
          attachmentId,
          TransferState.failed,
          error: 'Whole-file integrity verification failed.',
        );
        await _deleteAttachmentArtifacts(attachmentId);
        _inboundAttachments.remove(attachmentId);
        _updateMessageState(
          sender.deviceId,
          state.messageId,
          DeliveryState.failed,
        );
        unawaited(_sendAttachmentCancel(sender, attachmentId));
        notifyListeners();
        return;
      }
      final cacheFile = await _attachmentCacheFile(attachmentId);
      if (await cacheFile.exists()) await cacheFile.delete();
      await partial.rename(cacheFile.path);
      _locallyAvailableAttachments.add(attachmentId);
      _recordAttachmentCacheReference(attachmentId);
      if (state.descriptor.sizeBytes <= 8 * 1024 * 1024) {
        _assembledAttachments[attachmentId] = await cacheFile.readAsBytes();
      }
      _inboundAttachments.remove(attachmentId);
      _removeTransferSession(attachmentId);
      if (!hasActiveTransfer) _reschedulePolling();
      _updateMessageState(
        sender.deviceId,
        state.messageId,
        DeliveryState.delivered,
      );
      await _sendAttachmentComplete(sender, attachmentId);
      if (state.debugTest != null) {
        Object? resultError;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await _sendDebugFileTestResult(
              contact: sender,
              state: state,
              success: true,
              bytesVerified: state.descriptor.sizeBytes,
              detail: 'Final SHA-256 and every authenticated block matched.',
            );
            resultError = null;
            break;
          } catch (error) {
            resultError = error;
            if (attempt < 2) {
              await Future<void>.delayed(Duration(seconds: attempt + 1));
            }
          }
        }
        if (resultError != null) {
          appendDebugLog(
            'Could not return debug file-test result for $attachmentId: '
            '$resultError',
          );
        }
        await _deleteAttachmentArtifacts(attachmentId);
        _deleteMessage(state.peerDeviceId, state.messageId);
      }
      await _saveSnapshotSilently(notify: false);
      notifyListeners();
    } catch (error, stackTrace) {
      state.finalizing = false;
      final detail = 'Could not verify and save the completed file: $error';
      if (state.debugTest != null) {
        try {
          await _sendDebugFileTestResult(
            contact: sender,
            state: state,
            success: false,
            bytesVerified: state.receivedBytes,
            detail: detail,
          );
        } catch (_) {}
      }
      appendDebugLog('$detail\n$stackTrace');
      _setTransferSessionState(
        attachmentId,
        TransferState.failed,
        error: detail,
      );
      _updateMessageState(
        sender.deviceId,
        state.messageId,
        DeliveryState.failed,
      );
      notifyListeners();
    }
  }

  /// A stalled receive remains resumable. Connectivity outages use bounded
  /// exponential retry instead of turning a valid large transfer into a
  /// permanent failure after sixty seconds.

  void _scheduleInboundCheckpoint(
    String attachmentId,
    _InboundAttachmentState state,
  ) {
    state.checkpointTimer ??= Timer(
      _InboundAttachmentState.checkpointInterval,
      () async {
        state.checkpointTimer = null;
        if (!identical(_inboundAttachments[attachmentId], state) ||
            state.received.isEmpty) {
          return;
        }
        try {
          await _checkpointInboundTransfer(attachmentId, state);
        } catch (error) {
          appendDebugLog(
            'Checkpoint failed for $attachmentId; the last interval may be '
            'requested again after restart: $error',
          );
        }
      },
    );
  }

  Future<void> _checkpointInboundTransfer(
    String attachmentId,
    _InboundAttachmentState state,
  ) async {
    state.checkpointTimer?.cancel();
    state.checkpointTimer = null;
    // Capture the journal before flushing; later writes are not part of this
    // durability boundary even if they finish while this future resumes.
    final completed = state.received.toList()..sort();
    await state.checkpoint();
    if (!identical(_inboundAttachments[attachmentId], state)) {
      return;
    }
    final session = _transferSessionById(attachmentId);
    if (session == null) return;
    _upsertTransferSession(
      session.copyWith(
        state: state.paused ? TransferState.paused : TransferState.transferring,
        completedChunks: completed,
        bytesTransferred: _verifiedBytesFor(state.descriptor, completed),
        updatedAt: _now().toUtc(),
        clearLastError: true,
      ),
    );
    await _saveSnapshotSilently(notify: false);
  }

  /// How many block requests the receiver keeps outstanding. Relay-sized
  /// transfers stay conservatively bounded while direct-only large files use
  /// a bounded 16 MiB window and rely on LAN/QUIC backpressure.
  static const int _inboundChunkWindow = 8;
  static const int _largeDirectInboundChunkWindow = 4;

  void _startInboundRequestWindow(
    _InboundAttachmentState state,
    ContactRecord sender,
  ) {
    unawaited(_topUpInboundWindow(state, sender));
  }

  /// Tops up the inbound chunk-request window for [state] so up to
  /// [_inboundChunkWindow] requests are in flight. Idempotent — call after
  /// every chunk arrival, on offer accept, and on resume.
  Future<void> _topUpInboundWindow(
    _InboundAttachmentState state,
    ContactRecord sender,
  ) async {
    if (state.paused ||
        !state.accepted ||
        state.awaitingAcceptance ||
        state.partialPath == null) {
      return;
    }
    final window = state.descriptor.sizeBytes > maxAttachmentSizeBytes
        ? _largeDirectInboundChunkWindow
        : _inboundChunkWindow;
    final requests = <Future<void>>[];
    while (state.requestedInFlight.length < window) {
      final next = state.nextUnrequestedIndex();
      if (next < 0) break;
      state.requestedInFlight.add(next);
      appendDebugLog(
        'chunk_req tx → ${sender.alias} idx=$next '
        'attachmentId=${state.descriptor.id}',
      );
      requests.add(() async {
        try {
          await _sendAttachmentChunkRequest(sender, state.descriptor.id, next);
        } catch (error, stackTrace) {
          state.requestedInFlight.remove(next);
          appendDebugLog(
            'chunk_req setup failed → ${sender.alias} idx=$next '
            'attachmentId=${state.descriptor.id}: $error\n$stackTrace',
          );
          _setTransferSessionState(
            state.descriptor.id,
            TransferState.reconnecting,
            error: 'The transfer route failed. Retrying automatically.',
          );
        }
      }());
    }
    await Future.wait(requests);
  }

  void _scheduleAttachmentRetry(String attachmentId) {
    final state = _inboundAttachments[attachmentId];
    if (state == null) return;
    // Don't burn retry budget while the transfer is paused — the owner
    // will rearm explicitly on resume.
    if (state.paused ||
        !state.accepted ||
        state.awaitingAcceptance ||
        state.partialPath == null) {
      state.retryTimer?.cancel();
      return;
    }
    state.retryTimer?.cancel();
    final delay =
        _inboundTransferRetryBackoff[min(
          state.retryAttempts,
          _inboundTransferRetryBackoff.length - 1,
        )];
    state.nextRetryAt = DateTime.now().toUtc().add(delay);
    state.retryTimer = Timer(delay, () {
      final s = _inboundAttachments[attachmentId];
      if (s == null) return;
      if (s.paused || !s.accepted || s.partialPath == null) {
        // Became paused during the wait — drop without escalating.
        return;
      }
      final peer = _contactByDeviceId(s.peerDeviceId);
      if (peer == null) return;
      s.nextRetryAt = null;
      s.retryAttempts = min(s.retryAttempts + 1, 1 << 20);
      s.requestedInFlight.clear();
      _setTransferSessionState(
        attachmentId,
        TransferState.reconnecting,
        error: 'Waiting for the next verified block.',
      );
      appendDebugLog(
        'Re-requesting chunk ${s.nextMissingIndex} for $attachmentId '
        '(retry ${s.retryAttempts}).',
      );
      _startInboundRequestWindow(s, peer);
      _scheduleAttachmentRetry(attachmentId);
    });
  }

  Future<void> _sendAttachmentCancel(
    ContactRecord peer,
    String attachmentId,
  ) async {
    if (!hasIdentity) return;
    final me = _requireIdentity();
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'attachment_cancel',
      messageId: _randomId('acancel'),
      conversationId: _crypto.conversationIdFor(peer.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: peer.deviceId,
      contact: peer,
      plaintext: jsonEncode({'attachmentId': attachmentId}),
    );
    // nightly.12: route through the unified outbox so a receiver-side
    // delete during transfer is GUARANTEED to reach the sender (it
    // retries until success or 30 attempts). Pre-nightly.12 was
    // fire-and-forget and the user reported transfers staying alive on
    // the sender after the receiver dropped them.
    await _enqueueAndDeliverEnvelope(
      contact: peer,
      envelope: envelope,
      kind: PendingAckKind.attachmentCancel,
    );
  }

  /// Broadcasts the local pause/resume decision to the peer so they can
  /// mirror the state. `pausedByMe = true` on this side translates to
  /// `pausedByPeer = true` on the peer's mirror.
  Future<void> _sendAttachmentPauseControl({
    required ContactRecord peer,
    required String attachmentId,
    required bool paused,
  }) async {
    if (!hasIdentity) return;
    final me = _requireIdentity();
    final envelope = await _crypto.encryptPayloadEnvelope(
      kind: 'attachment_pause_control',
      messageId: _randomId('apause'),
      conversationId: _crypto.conversationIdFor(peer.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: peer.deviceId,
      contact: peer,
      plaintext: jsonEncode({'attachmentId': attachmentId, 'paused': paused}),
    );
    try {
      await _deliverToContact(
        contact: peer,
        recipientDeviceId: peer.deviceId,
        envelope: envelope,
      );
    } catch (error) {
      appendDebugLog(
        'Pause-control envelope to ${peer.alias} for $attachmentId '
        '(paused=$paused) failed: $error',
      );
    }
  }

  void _handleAttachmentPauseControl(
    ContactRecord sender,
    Map<String, dynamic> payload,
  ) {
    final attachmentId = payload['attachmentId'] as String?;
    final paused = payload['paused'] as bool?;
    if (attachmentId == null || paused == null) return;
    // Mirror on whichever side(s) hold state for this attachment.
    final outbound = _outboundAttachments[attachmentId];
    final inbound = _inboundAttachments[attachmentId];
    if ((outbound == null && inbound == null) ||
        (outbound != null && outbound.peerDeviceId != sender.deviceId) ||
        (inbound != null && inbound.peerDeviceId != sender.deviceId)) {
      return;
    }
    if (outbound != null && outbound.peerDeviceId == sender.deviceId) {
      outbound.pausedByPeer = paused;
    }
    if (inbound != null && inbound.peerDeviceId == sender.deviceId) {
      inbound.pausedByPeer = paused;
      if (paused) {
        inbound.retryTimer?.cancel();
      } else if (!inbound.pausedByMe) {
        _scheduleAttachmentRetry(attachmentId);
        // Resume fans out a fresh window of requests so the transfer
        // doesn't single-step its way back up to the pipeline depth.
        inbound.requestedInFlight.clear();
        _startInboundRequestWindow(inbound, sender);
      }
    }
    _setTransferSessionPause(attachmentId, pausedByPeer: paused);
    unawaited(_saveSnapshotSilently(notify: false, debounce: true));
    appendDebugLog(
      'Peer ${sender.alias} ${paused ? "paused" : "resumed"} '
      'attachment $attachmentId.',
    );
    notifyListeners();
  }

  /// Pauses an in-flight attachment from this side. The peer is notified so
  /// their UI can render "Paused by ${me.displayName}" with a disabled
  /// resume button. Only the side that initiated the pause may resume; the
  /// other side can still cancel/delete to terminate.
  Future<void> pauseAttachment(String attachmentId) async {
    final outbound = _outboundAttachments[attachmentId];
    final inbound = _inboundAttachments[attachmentId];
    final peerDeviceId = outbound?.peerDeviceId ?? inbound?.peerDeviceId;
    if (peerDeviceId == null) return;
    final peer = _contactByDeviceId(peerDeviceId);
    if (peer == null) return;
    if (outbound != null) outbound.pausedByMe = true;
    if (inbound != null) {
      inbound.pausedByMe = true;
      inbound.retryTimer?.cancel();
    }
    _setTransferSessionPause(attachmentId, pausedByMe: true);
    await _saveSnapshotSilently(notify: false);
    notifyListeners();
    await _sendAttachmentPauseControl(
      peer: peer,
      attachmentId: attachmentId,
      paused: true,
    );
  }

  /// Resumes a paused attachment — only meaningful when this side is the
  /// one who paused it. If the peer paused, this call is a no-op.
  Future<void> resumeAttachment(String attachmentId) async {
    final outbound = _outboundAttachments[attachmentId];
    final inbound = _inboundAttachments[attachmentId];
    final peerDeviceId = outbound?.peerDeviceId ?? inbound?.peerDeviceId;
    if (peerDeviceId == null) return;
    final peer = _contactByDeviceId(peerDeviceId);
    if (peer == null) return;
    if ((outbound?.pausedByMe ?? false) == false &&
        (inbound?.pausedByMe ?? false) == false) {
      return;
    }
    if (outbound != null) outbound.pausedByMe = false;
    if (inbound != null) {
      inbound.pausedByMe = false;
      if (!inbound.pausedByPeer) {
        _scheduleAttachmentRetry(attachmentId);
        // Resume fans out a fresh window so we don't single-step back.
        inbound.requestedInFlight.clear();
        _startInboundRequestWindow(inbound, peer);
      }
    }
    _setTransferSessionPause(attachmentId, pausedByMe: false);
    await _saveSnapshotSilently(notify: false);
    notifyListeners();
    await _sendAttachmentPauseControl(
      peer: peer,
      attachmentId: attachmentId,
      paused: false,
    );
  }

  /// Pause-state for the UI. Returns (pausedByMe, pausedByPeer) — null
  /// when no in-flight transfer exists for [attachmentId].
  ({bool pausedByMe, bool pausedByPeer})? pauseStateFor(String attachmentId) {
    final outbound = _outboundAttachments[attachmentId];
    if (outbound != null) {
      return (
        pausedByMe: outbound.pausedByMe,
        pausedByPeer: outbound.pausedByPeer,
      );
    }
    final inbound = _inboundAttachments[attachmentId];
    if (inbound != null) {
      return (
        pausedByMe: inbound.pausedByMe,
        pausedByPeer: inbound.pausedByPeer,
      );
    }
    return null;
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

  /// Debounce window for outgoing `attachment_progress` envelopes. Cap to
  /// at most one progress envelope per 250 ms per attachment so a 1000-chunk
  /// flood doesn't generate 1000 tiny envelopes that drown the relay queue.
  static const Duration _progressDebounce = Duration(milliseconds: 250);

  /// Emits an `attachment_progress` envelope to the sender if the debounce
  /// window has elapsed (or `force == true`, used on completion). The
  /// payload carries the receiver's current chunk count so the sender's UI
  /// can render the same percentage the receiver sees.
  void _maybeSendAttachmentProgress(
    _InboundAttachmentState state,
    ContactRecord sender, {
    bool force = false,
  }) {
    final now = DateTime.now().toUtc();
    if (!force &&
        state.lastProgressSentAt != null &&
        now.difference(state.lastProgressSentAt!) < _progressDebounce) {
      return;
    }
    state.lastProgressSentAt = now;
    final received = state.received.length;
    final receivedBytes = state.receivedBytes;
    unawaited(
      _sendAttachmentProgress(
        sender,
        attachmentId: state.descriptor.id,
        received: received,
        total: state.descriptor.effectiveChunkCount,
        receivedBytes: receivedBytes,
        totalBytes: state.descriptor.sizeBytes,
      ),
    );
  }

  Future<void> _sendAttachmentProgress(
    ContactRecord peer, {
    required String attachmentId,
    required int received,
    required int total,
    required int receivedBytes,
    required int totalBytes,
  }) async {
    if (!hasIdentity) return;
    final me = _requireIdentity();
    try {
      final envelope = await _crypto.encryptPayloadEnvelope(
        kind: 'attachment_progress',
        messageId: _randomId('aprog'),
        conversationId: _crypto.conversationIdFor(peer.deviceId),
        senderAccountId: me.accountId,
        senderDeviceId: me.deviceId,
        recipientDeviceId: peer.deviceId,
        contact: peer,
        plaintext: jsonEncode({
          'attachmentId': attachmentId,
          'received': received,
          'total': total,
          'receivedBytes': receivedBytes,
          'totalBytes': totalBytes,
        }),
      );
      await _deliverToContact(
        contact: peer,
        recipientDeviceId: peer.deviceId,
        envelope: envelope,
      );
    } catch (_) {
      // Progress envelopes are advisory — losing one just means the
      // sender's UI lags briefly. The next chunk arrival will trigger
      // another emit.
    }
  }

  void _handleAttachmentProgress(
    ContactRecord sender,
    Map<String, dynamic> payload,
  ) {
    final attachmentId = payload['attachmentId'] as String?;
    final received = payload['received'] as int?;
    if (attachmentId == null || received == null) return;
    final state = _outboundAttachments[attachmentId];
    if (state == null || state.peerDeviceId != sender.deviceId) return;
    if (received < 0 || received > state.descriptor.effectiveChunkCount) {
      return;
    }
    state.peerReceivedCount = received;
    final exactBytes = (payload['receivedBytes'] as num?)?.toInt();
    if (exactBytes != null &&
        (exactBytes < 0 || exactBytes > state.descriptor.sizeBytes)) {
      return;
    }
    state.recordPeerProgress(
      exactBytes ??
          _verifiedBytesFor(state.descriptor, Iterable<int>.generate(received)),
      DateTime.now().toUtc(),
    );
    notifyListeners();
  }

  Future<void> _handleAttachmentComplete(
    ContactRecord sender,
    Map<String, dynamic> payload,
  ) async {
    final attachmentId = payload['attachmentId'] as String?;
    if (attachmentId == null) {
      return;
    }
    final state = _outboundAttachments[attachmentId];
    if (state != null && state.peerDeviceId != sender.deviceId) return;
    if (state == null) {
      // Receiver completed an attachment whose state we already cleared
      // (cancel, delete, stall). Still advance the queue so a later
      // queued item can dispatch.
      _clearActiveOutbound(sender.deviceId, attachmentId);
      _pumpOutboundQueue(sender);
      return;
    }
    _outboundAttachments.remove(attachmentId);
    final session = _transferSessionById(attachmentId);
    await state.closeFile();
    if (state.sourceKind == TransferSourceKind.privateSpool) {
      try {
        final source = File(state.sourcePath);
        final cache = await _attachmentCacheFile(attachmentId);
        if (await cache.exists()) await cache.delete();
        if (await source.exists()) await source.rename(cache.path);
        if (await cache.exists()) {
          _locallyAvailableAttachments.add(attachmentId);
          _recordAttachmentCacheReference(attachmentId);
        }
        if (state.descriptor.sizeBytes <= 8 * 1024 * 1024 &&
            await cache.exists()) {
          _assembledAttachments[attachmentId] = await cache.readAsBytes();
        }
      } catch (error) {
        appendDebugLog('Could not finalize outbound attachment: $error');
      } finally {
        // The peer has already verified the full-file hash. Cache promotion
        // is best-effort and must not leave a Delivered message backed by an
        // apparently active transfer session (which also blocks eviction).
        _removeTransferSession(attachmentId);
      }
    } else if (session != null) {
      _upsertTransferSession(
        session.copyWith(
          state: TransferState.completed,
          updatedAt: _now().toUtc(),
          bytesTransferred: state.descriptor.sizeBytes,
          clearLastError: true,
        ),
      );
    }
    _updateMessageState(
      sender.deviceId,
      state.messageId,
      DeliveryState.delivered,
    );
    _clearActiveOutbound(sender.deviceId, attachmentId);
    await _saveSnapshotSilently(notify: false);
    notifyListeners();
    _pumpOutboundQueue(sender);
  }

  void _handleAttachmentCancel(
    ContactRecord sender,
    Map<String, dynamic> payload,
  ) {
    final attachmentId = payload['attachmentId'] as String?;
    if (attachmentId == null) {
      return;
    }
    final inbound = _inboundAttachments[attachmentId];
    final outbound = _outboundAttachments[attachmentId];
    if ((inbound == null && outbound == null) ||
        (inbound != null && inbound.peerDeviceId != sender.deviceId) ||
        (outbound != null && outbound.peerDeviceId != sender.deviceId)) {
      return;
    }
    // Find the inbound parent ChatMessage so the bubble can transition to a
    // sensible end-state (text-only if there was a caption; removed entirely
    // otherwise — leaving an empty "Transferring 0%" bubble is the bug we
    // came here to fix).
    final inboundState = _inboundAttachments.remove(attachmentId);
    inboundState?.retryTimer?.cancel();
    final outboundState = _outboundAttachments.remove(attachmentId);
    if (inboundState != null) unawaited(inboundState.closeFile());
    if (outboundState != null) unawaited(outboundState.closeFile());
    _assembledAttachments.remove(attachmentId);
    _locallyAvailableAttachments.remove(attachmentId);
    _removeTransferSession(attachmentId);
    unawaited(_deleteAttachmentArtifacts(attachmentId));
    // If the peer canceled an attachment we were actively shipping, free
    // the queue slot so the next item dispatches.
    if (outboundState != null) {
      // nightly.12: cancel the stall timer too — without this it kept
      // firing after the queue slot was freed, generating spurious
      // "Auto-retrying…" log noise on the sender side when the receiver
      // had already torn down. Also flip the parent ChatMessage to
      // `canceled` so the sender's bubble visually mirrors the peer's
      // cancel.
      _outboundStallTimers.remove(outboundState.peerDeviceId)?.cancel();
      _clearActiveOutbound(outboundState.peerDeviceId, attachmentId);
      _outboundQueueByContact[outboundState.peerDeviceId]?.remove(attachmentId);
      _updateMessageState(
        outboundState.peerDeviceId,
        outboundState.messageId,
        DeliveryState.canceled,
      );
      final peerContact = _contactByDeviceId(outboundState.peerDeviceId);
      if (peerContact != null) _pumpOutboundQueue(peerContact);
    }
    if (inboundState != null) {
      final parent = _messageById(
        inboundState.peerDeviceId,
        inboundState.messageId,
      );
      if (parent != null) {
        if (parent.body.isEmpty) {
          _deleteMessage(inboundState.peerDeviceId, inboundState.messageId);
        } else {
          _clearAttachmentOnMessage(
            inboundState.peerDeviceId,
            inboundState.messageId,
          );
        }
      }
    }
    notifyListeners();
  }

  /// Replaces the attachment field on a specific message with null so its
  /// bubble downgrades from "Transferring…" to a plain text row. Used when
  /// the sender canceled the attachment but the caption remains visible.
  void _clearAttachmentOnMessage(String peerDeviceId, String messageId) {
    final conversations = List<ConversationRecord>.from(
      _snapshot.conversations,
    );
    final idx = conversations.indexWhere((c) => c.peerDeviceId == peerDeviceId);
    if (idx < 0) return;
    final updated = <ChatMessage>[];
    var changed = false;
    for (final m in conversations[idx].messages) {
      if (m.id == messageId && m.attachment != null) {
        updated.add(m.copyWith(clearAttachment: true));
        changed = true;
      } else {
        updated.add(m);
      }
    }
    if (!changed) return;
    conversations[idx] = conversations[idx].copyWith(messages: updated);
    _snapshot = _snapshot.copyWith(conversations: conversations);
  }

  Future<void> _handleContactExchange(RelayEnvelope envelope) async {
    final existing = _contactByDeviceId(envelope.senderDeviceId);
    final String payload;
    if (envelope.protocolVersion == 1) {
      if (existing != null) return;
      final rawPayload = envelope.payloadBase64;
      if (rawPayload == null || rawPayload.isEmpty) return;
      payload = utf8.decode(base64Decode(rawPayload));
    } else {
      if (existing == null || existing.pendingVerification) return;
      payload = await _crypto.decryptMessage(
        contact: existing,
        envelope: envelope,
      );
    }
    final invite = ContactInvite.tryDecodePayload(payload);
    if (invite == null ||
        invite.deviceId != envelope.senderDeviceId ||
        invite.accountId != envelope.senderAccountId) {
      return;
    }
    if (invite.version >= 6 && !await _crypto.verifyContactInvite(invite)) {
      appendDebugLog(
        'Rejected contact_exchange with an invalid ci6 signature from '
        '${envelope.senderDeviceId}.',
      );
      return;
    }
    if (existing != null) {
      if (invite.publicKeyBase64 != existing.publicKeyBase64 ||
          invite.accountId != existing.accountId ||
          (existing.signingPublicKeyBase64 != null &&
              invite.signingPublicKeyBase64 !=
                  existing.signingPublicKeyBase64) ||
          (existing.irohEndpointId != null &&
              invite.irohEndpointId != existing.irohEndpointId)) {
        appendDebugLog(
          'Rejected contact_exchange identity replacement for '
          '${existing.deviceId}.',
        );
        return;
      }
      await _updateExistingContactFromInvite(
        invite,
        statusBuilder: (contact) =>
            'Updated ${contact.alias} profile and route hints.',
      );
      return;
    }
    final cutoff = _now().subtract(_pendingContactRequestTtl);
    final pending =
        _snapshot.pendingContactRequests
            .where(
              (entry) =>
                  entry.receivedAt.isAfter(cutoff) &&
                  entry.senderDeviceId != invite.deviceId,
            )
            .toList(growable: true)
          ..add(
            PendingContactRequest(
              id: envelope.messageId,
              senderAccountId: invite.accountId,
              senderDeviceId: invite.deviceId,
              invitePayload: payload,
              receivedAt: _now().toUtc(),
            ),
          );
    if (pending.length > _maxPendingContactRequests) {
      pending.removeRange(0, pending.length - _maxPendingContactRequests);
    }
    _snapshot = _snapshot.copyWith(pendingContactRequests: pending);
    await _persist('New contact request from ${invite.displayName}.');
  }

  Future<void> _handleRouteUpdate(RelayEnvelope envelope) async {
    final sender = _contactByDeviceId(envelope.senderDeviceId);
    if (sender == null) {
      return;
    }
    final decodedPayload = await _crypto.decryptMessage(
      contact: sender,
      envelope: envelope,
    );
    String? invitePayload;
    var requestReply = false;
    var reason = 'rediscovery';
    String? probeId;
    DateTime? sentAt;
    Map<String, dynamic>? routePayload;
    try {
      final decoded = jsonDecode(decodedPayload);
      if (decoded is Map<String, dynamic>) {
        routePayload = decoded;
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
    if (invite == null ||
        invite.deviceId != envelope.senderDeviceId ||
        invite.accountId != sender.accountId ||
        invite.publicKeyBase64 != sender.publicKeyBase64) {
      return;
    }
    if (invite.version >= 6 && !await _crypto.verifyContactInvite(invite)) {
      appendDebugLog(
        'Rejected route_update with an invalid ci6 signature from '
        '${sender.deviceId}.',
      );
      return;
    }
    if ((sender.signingPublicKeyBase64 != null &&
            sender.signingPublicKeyBase64 != invite.signingPublicKeyBase64) ||
        (sender.irohEndpointId != null &&
            sender.irohEndpointId != invite.irohEndpointId)) {
      appendDebugLog(
        'Blocked an unexpected transport identity change for ${sender.alias}.',
      );
      return;
    }
    if (routePayload != null) {
      _cachePeerLanDirectFromPayload(sender.deviceId, routePayload);
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
      if (!_preservesExistingGroupMemberIdentities(existing, incoming)) {
        appendDebugLog(
          'Rejected group membership identity replacement for '
          '${incoming.groupId}.',
        );
        return;
      }
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
    if (invite.version >= 6 && !await _crypto.verifyContactInvite(invite)) {
      return null;
    }
    if ((existing.signingPublicKeyBase64 != null &&
            existing.signingPublicKeyBase64 != invite.signingPublicKeyBase64) ||
        (existing.irohEndpointId != null &&
            existing.irohEndpointId != invite.irohEndpointId)) {
      appendDebugLog(
        'Blocked transport identity rotation for ${existing.alias}; '
        'explicit verification is required.',
      );
      return null;
    }
    final updated = existing.copyWith(
      displayName: invite.displayName,
      bio: invite.bio.isEmpty ? existing.bio : invite.bio,
      relayCapable: invite.relayCapable,
      routeHints: prunePeerEndpointsByKind(invite.routeHints),
      signingPublicKeyBase64: invite.signingPublicKeyBase64,
      irohEndpointId: invite.irohEndpointId,
      capabilities: invite.capabilities,
      transportIdentityVerifiedAt: invite.version >= 6
          ? (existing.transportIdentityVerifiedAt ?? _now())
          : existing.transportIdentityVerifiedAt,
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
    final decoded = jsonDecode(
      await _crypto.decryptMessage(contact: contact, envelope: envelope),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded['removedDeviceId'] != identity?.deviceId) {
      return;
    }
    final removedAt =
        DateTime.tryParse(decoded['removedAt'] as String? ?? '')?.toUtc() ??
        envelope.createdAt.toUtc();
    final index = _snapshot.contacts.indexWhere(
      (candidate) => candidate.deviceId == contact.deviceId,
    );
    if (index < 0) return;
    final contacts = List<ContactRecord>.from(_snapshot.contacts);
    contacts[index] = contact.copyWith(remoteRemovedAt: removedAt);
    _snapshot = _snapshot.copyWith(contacts: contacts);
    _reachability.remove(contact.deviceId);
    await _persist(
      '${contact.alias} removed you. The conversation remains archived locally.',
    );
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
    await _crypto.decryptMessage(contact: contact, envelope: envelope);
    final me = _requireIdentity();
    final ack = await _crypto.encryptPayloadEnvelope(
      kind: 'debug_probe_ack',
      messageId: _randomId('dbgack'),
      conversationId: envelope.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode({'acknowledgedMessageId': envelope.messageId}),
      acknowledgedMessageId: envelope.messageId,
    );
    // nightly.12: route the probe ack through the unified outbox so it
    // doesn't get lost in the 3-device simultaneous test.
    await _enqueueAndDeliverEnvelope(
      contact: contact,
      envelope: ack,
      kind: PendingAckKind.debugProbeAck,
    );
  }

  Future<void> _probeDebugFileTestPeer(
    ContactRecord contact,
    String testId,
    String buildId, {
    required bool irohOnly,
  }) async {
    await _refreshLocalLanDirectAddressCache();
    final localLanHint = _localLanDirectHintPayload();
    if (!irohOnly && localLanHint['senderLanBinaryVersion'] != 1) {
      throw StateError(
        'This device could not advertise a binary LAN endpoint. '
        'Check Wi-Fi/LAN access and restart Conest Debug.',
      );
    }
    final me = _requireIdentity();
    final completer = Completer<bool>();
    _debugFileProbeCompleters[testId] = completer;
    final probe = await _crypto.encryptPayloadEnvelope(
      kind: 'debug_file_test_probe',
      messageId: _randomId('fileprobe'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode(<String, dynamic>{
        'protocolVersion': 1,
        'testId': testId,
        'buildId': buildId,
        'irohOnly': irohOnly,
        ...localLanHint,
      }),
    );
    try {
      try {
        await _deliverToContact(
          contact: contact,
          recipientDeviceId: contact.deviceId,
          envelope: probe,
          allowRelayedPaths: !irohOnly,
          allowLegacyRoutes: !irohOnly,
          allowedUnifiedKinds: irohOnly ? {TransportKind.iroh} : null,
        ).timeout(const Duration(seconds: 20));
      } catch (error) {
        throw StateError(
          irohOnly
              ? 'Could not establish direct Iroh with ${contact.alias}. No relay was used. Check that both peers are online and direct connections are permitted. Details: $error'
              : 'Could not reach ${contact.alias} for the LAN test. Check the peer connection and try again. Details: $error',
        );
      }
      final accepted = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
      if (!accepted) {
        throw StateError(
          '${contact.alias} did not confirm the same debug build and '
          'selected direct transport. '
          'Install the identical debug artifact on both peers.',
        );
      }
    } finally {
      _debugFileProbeCompleters.remove(testId);
    }
  }

  Future<void> _handleDebugFileTestProbe(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null || !contact.canSendOutbound) return;
    final decoded = jsonDecode(
      await _crypto.decryptMessage(contact: contact, envelope: envelope),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded['protocolVersion'] != 1 ||
        decoded['testId'] is! String ||
        decoded['buildId'] is! String) {
      return;
    }
    final testId = decoded['testId'] as String;
    final requestedBuild = decoded['buildId'] as String;
    final irohOnly = decoded['irohOnly'] == true;
    if (testId.isEmpty ||
        testId.length > 160 ||
        requestedBuild.isEmpty ||
        requestedBuild.length > 256) {
      return;
    }
    _cachePeerLanDirectFromPayload(contact.deviceId, decoded);
    await _refreshLocalLanDirectAddressCache();
    final localLanHint = _localLanDirectHintPayload();
    final localBuild = _debugBuildId;
    final accepted =
        localBuild != null &&
        localBuild == requestedBuild &&
        (irohOnly
            ? _canUseIrohForContact(contact)
            : localLanHint['senderLanBinaryVersion'] == 1);
    final now = _now().toUtc();
    _authorizedInboundDebugFileTests.removeWhere(
      (_, authorization) => !authorization.expiresAt.isAfter(now),
    );
    if (accepted) {
      // A matching build token alone must not silently allocate a large file.
      // The offer must follow this authenticated probe from the same verified
      // contact and consume its short-lived authorization.
      _authorizedInboundDebugFileTests[testId] = _AuthorizedDebugFileTest(
        peerDeviceId: contact.deviceId,
        irohOnly: irohOnly,
        expiresAt: now.add(const Duration(minutes: 10)),
      );
    }
    final me = _requireIdentity();
    final acknowledgement = await _crypto.encryptPayloadEnvelope(
      kind: 'debug_file_test_probe_ack',
      messageId: _randomId('fileprobeack'),
      conversationId: envelope.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      acknowledgedMessageId: envelope.messageId,
      plaintext: jsonEncode(<String, dynamic>{
        'protocolVersion': 1,
        'testId': testId,
        'buildId': localBuild ?? '',
        'accepted': accepted,
        'irohOnly': irohOnly,
        'probeMessageId': envelope.messageId,
        ...localLanHint,
      }),
    );
    await _deliverToContact(
      contact: contact,
      recipientDeviceId: contact.deviceId,
      envelope: acknowledgement,
      allowRelayedPaths: !irohOnly,
      allowLegacyRoutes: !irohOnly,
      allowedUnifiedKinds: irohOnly ? {TransportKind.iroh} : null,
    );
  }

  Future<void> _handleDebugFileTestProbeAck(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) return;
    final decoded = jsonDecode(
      await _crypto.decryptMessage(contact: contact, envelope: envelope),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded['protocolVersion'] != 1 ||
        decoded['testId'] is! String ||
        decoded['buildId'] is! String ||
        decoded['accepted'] is! bool ||
        decoded['probeMessageId'] != envelope.acknowledgedMessageId) {
      return;
    }
    _cachePeerLanDirectFromPayload(contact.deviceId, decoded);
    final peerEndpoint = _peerLanDirect[contact.deviceId];
    final peerBinaryReady =
        peerEndpoint != null &&
        peerEndpoint.binaryBlockVersion >= 1 &&
        _lanDirectEndpointUsable(peerEndpoint);
    final completer = _debugFileProbeCompleters[decoded['testId'] as String];
    if (completer == null || completer.isCompleted) return;
    completer.complete(
      decoded['accepted'] == true &&
          decoded['buildId'] == _debugBuildId &&
          (decoded['irohOnly'] == true
              ? _canUseIrohForContact(contact)
              : peerBinaryReady),
    );
  }

  Future<void> _handleDebugFileTestResult(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null || _debugBuildId == null) return;
    final decoded = jsonDecode(
      await _crypto.decryptMessage(contact: contact, envelope: envelope),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded['protocolVersion'] != 1 ||
        decoded['testId'] is! String ||
        decoded['attachmentId'] is! String ||
        decoded['buildId'] != _debugBuildId ||
        decoded['sizeMiB'] is! int ||
        decoded['success'] is! bool ||
        decoded['bytesVerified'] is! int) {
      return;
    }
    final testId = decoded['testId'] as String;
    final attachmentId = decoded['attachmentId'] as String;
    final specEntry = _outboundDebugAttachmentTests.entries
        .where((entry) => entry.value.testId == testId)
        .firstOrNull;
    if (specEntry == null || specEntry.key != attachmentId) return;
    final spec = specEntry.value;
    final descriptor =
        _outboundAttachments[attachmentId]?.descriptor ??
        attachmentDescriptorFor(attachmentId);
    if (descriptor == null ||
        decoded['sizeMiB'] != spec.sizeMiB ||
        decoded['bytesVerified'] is! int) {
      return;
    }
    final reportedSuccess = decoded['success'] == true;
    final reportedHash = decoded['sha256Base64'] as String?;
    final bytesVerified = decoded['bytesVerified'] as int;
    final success =
        reportedSuccess &&
        bytesVerified == descriptor.sizeBytes &&
        reportedHash == descriptor.fileHashBase64;
    final completedAt =
        DateTime.tryParse(decoded['completedAt'] as String? ?? '')?.toUtc() ??
        _now().toUtc();
    final result = DebugFileTestResult(
      testId: testId,
      attachmentId: attachmentId,
      peerDeviceId: contact.deviceId,
      sizeMiB: spec.sizeMiB,
      success: success,
      startedAt: spec.startedAt,
      completedAt: completedAt,
      bytesVerified: bytesVerified,
      sha256Base64: reportedHash,
      detail: success
          ? decoded['detail'] as String?
          : (decoded['detail'] as String? ??
                'Peer result did not match the sent manifest.'),
    );
    _debugFileTestResults.removeWhere((entry) => entry.testId == testId);
    _debugFileTestResults.insert(0, result);
    if (_debugFileTestResults.length > 20) {
      _debugFileTestResults.removeRange(20, _debugFileTestResults.length);
    }
    final completer = _debugFileResultCompleters[testId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
    notifyListeners();
  }

  Future<void> _sendDebugFileTestResult({
    required ContactRecord contact,
    required _InboundAttachmentState state,
    required bool success,
    required int bytesVerified,
    String? detail,
  }) async {
    final spec = state.debugTest;
    final buildId = _debugBuildId;
    if (spec == null || buildId == null || spec.buildId != buildId) return;
    final me = _requireIdentity();
    final result = await _crypto.encryptPayloadEnvelope(
      kind: 'debug_file_test_result',
      messageId: _randomId('filetestresult'),
      conversationId: _crypto.conversationIdFor(contact.deviceId),
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode(<String, dynamic>{
        'protocolVersion': 1,
        'testId': spec.testId,
        'attachmentId': state.descriptor.id,
        'buildId': buildId,
        'sizeMiB': spec.sizeMiB,
        'success': success,
        'bytesVerified': bytesVerified,
        'sha256Base64': success ? state.descriptor.fileHashBase64 : null,
        'completedAt': _now().toUtc().toIso8601String(),
        'detail': ?detail,
      }),
    );
    await _deliverToContact(
      contact: contact,
      recipientDeviceId: contact.deviceId,
      envelope: result,
      allowRelayedPaths: !spec.irohOnly,
      allowLegacyRoutes: !spec.irohOnly,
      allowedUnifiedKinds: spec.irohOnly ? {TransportKind.iroh} : null,
    );
  }

  Future<void> _finishRejectedDebugFileTest({
    required ContactRecord sender,
    required _InboundAttachmentState state,
    required String detail,
  }) async {
    try {
      await _sendDebugFileTestResult(
        contact: sender,
        state: state,
        success: false,
        bytesVerified: 0,
        detail: detail,
      );
    } finally {
      _inboundAttachments.remove(state.descriptor.id);
      _removeTransferSession(state.descriptor.id);
      await _deleteAttachmentArtifacts(state.descriptor.id);
      _deleteMessage(state.peerDeviceId, state.messageId);
      await _saveSnapshotSilently(notify: true);
    }
  }

  Future<void> _cleanupOutboundDebugTest(String testId) async {
    final entry = _outboundDebugAttachmentTests.entries
        .where((candidate) => candidate.value.testId == testId)
        .firstOrNull;
    if (entry == null) return;
    final attachmentId = entry.key;
    final state = _outboundAttachments.remove(attachmentId);
    _outboundDebugAttachmentTests.remove(attachmentId);
    if (state != null) {
      await state.closeFile();
      _outboundStallTimers.remove(state.peerDeviceId)?.cancel();
      _clearActiveOutbound(state.peerDeviceId, attachmentId);
      _outboundQueueByContact[state.peerDeviceId]?.remove(attachmentId);
      await _deleteAttachmentArtifacts(attachmentId);
      _deleteMessage(state.peerDeviceId, state.messageId);
      final contact = _contactByDeviceId(state.peerDeviceId);
      if (contact != null) _pumpOutboundQueue(contact);
    } else {
      await _deleteAttachmentArtifacts(attachmentId);
      final message = messageForAttachment(attachmentId);
      if (message != null) {
        final peer = peerDeviceIdForAttachment(attachmentId);
        if (peer != null) _deleteMessage(peer, message.id);
      }
    }
    _removeTransferSession(attachmentId);
    await _saveSnapshotSilently(notify: true);
  }

  Future<void> _handleDebugTwoWayMessage(RelayEnvelope envelope) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) {
      return;
    }
    await _crypto.decryptMessage(contact: contact, envelope: envelope);
    final me = _requireIdentity();
    final reply = await _crypto.encryptPayloadEnvelope(
      kind: 'debug_two_way_reply',
      messageId: _randomId('dbgreply'),
      conversationId: envelope.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      acknowledgedMessageId: envelope.messageId,
      plaintext: jsonEncode({
        'replyFrom': me.deviceId,
        'displayName': me.displayName,
        'receivedMessageId': envelope.messageId,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    // nightly.12: route the two-way reply through the unified outbox.
    await _enqueueAndDeliverEnvelope(
      contact: contact,
      envelope: reply,
      kind: PendingAckKind.debugTwoWayReply,
    );
  }

  Future<void> _handleDebugAcknowledgement(
    RelayEnvelope envelope, {
    required bool twoWay,
  }) async {
    final contact = _contactByDeviceId(envelope.senderDeviceId);
    if (contact == null) return;
    final decoded = jsonDecode(
      await _crypto.decryptMessage(contact: contact, envelope: envelope),
    );
    if (decoded is! Map<String, dynamic>) return;
    final target = twoWay
        ? decoded['receivedMessageId'] as String?
        : decoded['acknowledgedMessageId'] as String?;
    if (target == null || target != envelope.acknowledgedMessageId) return;
    if (twoWay) {
      _debugTwoWayReplies.add(target);
    } else {
      _debugProbeAcknowledgements.add(target);
    }
  }

  Future<void> _sendAck({
    required ContactRecord contact,
    required RelayEnvelope envelope,
  }) async {
    final me = _requireIdentity();
    final ack = await _crypto.encryptPayloadEnvelope(
      kind: 'ack',
      messageId: _randomId('ack'),
      conversationId: envelope.conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode({
        'receipt': 'delivered',
        'acknowledgedMessageId': envelope.messageId,
      }),
      createdAt: _now().toUtc(),
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
    final receipt = await _crypto.encryptPayloadEnvelope(
      kind: 'ack',
      messageId: _randomId('read'),
      conversationId: conversationId,
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode({
        'receipt': 'read',
        'acknowledgedMessageId': acknowledgedMessageId,
      }),
      createdAt: _now().toUtc(),
      acknowledgedMessageId: acknowledgedMessageId,
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
    if (utf8.encode(encoded).length > 384 * 1024) return;
    final now = _now().toUtc();
    final cutoff = now.subtract(const Duration(days: 7));
    final existing =
        _snapshot.heldUnverifiedEnvelopes
            .where(
              (entry) =>
                  entry.receivedAt.isAfter(cutoff) &&
                  !(entry.senderDeviceId == senderDeviceId &&
                      entry.envelopeJson == encoded),
            )
            .toList(growable: true)
          ..add(
            HeldEnvelope(
              senderDeviceId: senderDeviceId,
              conversationId: envelope.conversationId,
              envelopeJson: encoded,
              receivedAt: now,
            ),
          );
    final senderEntries = existing
        .where((entry) => entry.senderDeviceId == senderDeviceId)
        .toList(growable: false);
    if (senderEntries.length > 64) {
      final evict = senderEntries
          .take(senderEntries.length - 64)
          .map((entry) => entry.envelopeJson)
          .toSet();
      existing.removeWhere(
        (entry) =>
            entry.senderDeviceId == senderDeviceId &&
            evict.contains(entry.envelopeJson),
      );
    }
    if (existing.length > 256) {
      existing.removeRange(0, existing.length - 256);
    }
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

  bool _markLegacyQueuedControlsIncompatible() {
    var changed = false;
    final entries = _snapshot.pendingAckDeliveries
        .map((entry) {
          if (!entry.kind.carriesEnvelope ||
              entry.envelopeJson == null ||
              entry.requiresPeerUpdate) {
            return entry;
          }
          try {
            final envelope = RelayEnvelope.fromJson(entry.envelopeJson!);
            if (envelope.protocolVersion == 2) return entry;
          } catch (_) {
            // Corrupt and legacy controls are both unsafe to replay.
          }
          changed = true;
          return entry.copyWith(requiresPeerUpdate: true);
        })
        .toList(growable: false);
    if (changed) {
      _snapshot = _snapshot.copyWith(pendingAckDeliveries: entries);
    }
    return changed;
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

  /// nightly.12 unified envelope outbox. Every control envelope (delete,
  /// cancel, edit, debug probe, debug reply, etc.) flows through this so
  /// an offline peer eventually gets it: the entry is persisted in
  /// [VaultSnapshot.pendingAckDeliveries], the first delivery attempt
  /// runs immediately, and `_retryPendingAckDeliveries` re-pushes from
  /// the vault until success or the 30-attempt cap.
  ///
  /// Replaces the fire-and-forget `try { _deliverToContact } catch (_) {}`
  /// pattern that was scattered across 15+ call sites pre-nightly.12.
  Future<void> _enqueueAndDeliverEnvelope({
    required ContactRecord contact,
    required RelayEnvelope envelope,
    required PendingAckKind kind,
  }) async {
    assert(
      kind.carriesEnvelope,
      'use _enqueuePendingAckDelivery for delivered/read kinds',
    );
    _enqueuePendingAckDelivery(
      PendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: envelope.messageId,
        conversationId: envelope.conversationId,
        kind: kind,
        lastAttemptedAt: _now(),
        attempts: 1,
        envelopeJson: envelope.toJson(),
      ),
    );
    try {
      await _deliverToContact(
        contact: contact,
        recipientDeviceId: contact.deviceId,
        envelope: envelope,
      );
      _clearPendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: envelope.messageId,
        kind: kind,
      );
    } catch (error) {
      appendDebugLog(
        'Envelope ${envelope.kind} queued for retry to ${contact.alias}: '
        '$error',
      );
    }
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
      if (entry.requiresPeerUpdate) {
        continue;
      }
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
      // nightly.12: kinds that carry their full encrypted envelope (delete,
      // cancel, edit, debug_probe, etc.) re-push the stored ciphertext
      // verbatim. Pre-nightly.12 `delivered`/`read` kinds rebuild a fresh
      // `ack` envelope as before.
      RelayEnvelope envelope;
      if (entry.kind.carriesEnvelope && entry.envelopeJson != null) {
        try {
          envelope = RelayEnvelope.fromJson(entry.envelopeJson!);
        } catch (_) {
          // Corrupted entry — drop so we don't loop forever.
          _clearPendingAckDelivery(
            targetDeviceId: entry.targetDeviceId,
            acknowledgedMessageId: entry.acknowledgedMessageId,
            kind: entry.kind,
          );
          continue;
        }
      } else {
        envelope = await _crypto.encryptPayloadEnvelope(
          kind: 'ack',
          messageId: _randomId(
            entry.kind == PendingAckKind.read ? 'read' : 'ack',
          ),
          conversationId: entry.conversationId,
          senderAccountId: me.accountId,
          senderDeviceId: me.deviceId,
          recipientDeviceId: contact.deviceId,
          contact: contact,
          plaintext: jsonEncode({
            'receipt': entry.kind == PendingAckKind.read ? 'read' : 'delivered',
            'acknowledgedMessageId': entry.acknowledgedMessageId,
          }),
          acknowledgedMessageId: entry.acknowledgedMessageId,
        );
      }
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
    final probe = await _crypto.encryptPayloadEnvelope(
      kind: 'debug_probe',
      messageId: _randomId('dbg'),
      conversationId: 'debug-${me.deviceId}-${contact.deviceId}',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode({
        'deviceId': me.deviceId,
        'displayName': me.displayName,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      }),
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
    // nightly.12: persist the probe in the unified outbox so the 3-device
    // simultaneous test stops showing 0/N acceptance. The first attempt
    // is the route-constrained relay-only / relay-or-LAN delivery; on
    // failure the retry loop re-pushes via the generic _deliverToContact.
    _enqueuePendingAckDelivery(
      PendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: probe.messageId,
        conversationId: probe.conversationId,
        kind: PendingAckKind.debugProbe,
        lastAttemptedAt: _now(),
        attempts: 1,
        envelopeJson: probe.toJson(),
      ),
    );
    try {
      await _deliverAcrossRoutes(
        routes: routes,
        recipientDeviceId: contact.deviceId,
        envelope: probe,
        lanTimeout: _debugRelayOperationTimeout,
        directInternetTimeout: _debugRelayOperationTimeout,
        relayTimeout: _debugRelayOperationTimeout,
      );
      _clearPendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: probe.messageId,
        kind: PendingAckKind.debugProbe,
      );
      return probe.messageId;
    } catch (_) {
      // Stays queued; retry loop will use _deliverToContact on next pass.
      return probe.messageId;
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
    final probe = await _crypto.encryptPayloadEnvelope(
      kind: 'debug_two_way_message',
      messageId: _randomId('dbgtwoway'),
      conversationId: 'debug-two-way-${me.deviceId}-${contact.deviceId}',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: contact.deviceId,
      contact: contact,
      plaintext: jsonEncode({
        'from': me.deviceId,
        'displayName': me.displayName,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
        'expectReply': true,
      }),
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
    // nightly.12: persist the two-way debug message in the unified
    // outbox so a 3-device simultaneous test stops dropping requests.
    _enqueuePendingAckDelivery(
      PendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: probe.messageId,
        conversationId: probe.conversationId,
        kind: PendingAckKind.debugTwoWayMessage,
        lastAttemptedAt: _now(),
        attempts: 1,
        envelopeJson: probe.toJson(),
      ),
    );
    try {
      await _deliverAcrossRoutes(
        routes: routes,
        recipientDeviceId: contact.deviceId,
        envelope: probe,
        lanTimeout: _debugRelayOperationTimeout,
        directInternetTimeout: _debugRelayOperationTimeout,
        relayTimeout: _debugRelayOperationTimeout,
      );
      _clearPendingAckDelivery(
        targetDeviceId: contact.deviceId,
        acknowledgedMessageId: probe.messageId,
        kind: PendingAckKind.debugTwoWayMessage,
      );
      return probe.messageId;
    } catch (_) {
      // Stays queued; retry loop drives delivery via _deliverToContact.
      return probe.messageId;
    }
  }

  Future<void> _waitForDebugResponses({
    required Set<String> expectedProbeAckIds,
    required Set<String> expectedTwoWayReplyIds,
  }) async {
    if (expectedProbeAckIds.isEmpty && expectedTwoWayReplyIds.isEmpty) {
      return;
    }
    // nightly.12: deadline bumped 8s → 20s. The 3-device simultaneous
    // test under user-reported load consistently showed 0/N because
    // probes hadn't been delivered + drained by the 8s mark. With
    // probes now persisted in the outbox (Phase 3) the late drain
    // succeeds — just give it room.
    final deadline = DateTime.now().toUtc().add(const Duration(seconds: 20));
    while (DateTime.now().toUtc().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 750));
      await pollNow();
      // nightly.12: also kick the pending-ack retry loop so probes that
      // failed their first push attempt re-push immediately rather than
      // waiting for the standard backoff window.
      unawaited(_retryPendingAckDeliveries(force: true));
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

  Future<DebugCheckResult> _runAttachmentSelfTest() async {
    // Loopback exercise of the chunk pipeline — builds a descriptor over a
    // small random buffer, splits + hashes + reassembles + verifies. Catches
    // regressions in the chunk hash math AND a torn-state path where the
    // descriptor's chunkHashes don't line up with the assembled bytes.
    try {
      final random = Random();
      final source = Uint8List.fromList(
        List<int>.generate(1024, (_) => random.nextInt(256)),
      );
      const chunkSize = 256;
      final chunkBytes = <Uint8List>[];
      final chunkHashes = <ChunkHash>[];
      for (var offset = 0; offset < source.length; offset += chunkSize) {
        final end = (offset + chunkSize > source.length)
            ? source.length
            : offset + chunkSize;
        final slice = Uint8List.view(
          source.buffer,
          source.offsetInBytes + offset,
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
      // Reassemble + verify hash per chunk.
      final builder = BytesBuilder();
      for (var i = 0; i < chunkBytes.length; i++) {
        final digest = await Sha256().hash(chunkBytes[i]);
        if (base64Encode(digest.bytes) != chunkHashes[i].hashBase64) {
          return DebugCheckResult(
            name: 'Attachment self-test',
            status: DebugCheckStatus.fail,
            detail: 'Chunk $i hash mismatch on local round-trip.',
          );
        }
        builder.add(chunkBytes[i]);
      }
      final assembled = builder.toBytes();
      if (assembled.length != source.length) {
        return DebugCheckResult(
          name: 'Attachment self-test',
          status: DebugCheckStatus.fail,
          detail:
              'Assembled length ${assembled.length} != source ${source.length}.',
        );
      }
      for (var i = 0; i < assembled.length; i++) {
        if (assembled[i] != source[i]) {
          return DebugCheckResult(
            name: 'Attachment self-test',
            status: DebugCheckStatus.fail,
            detail: 'Byte mismatch at offset $i after reassembly.',
          );
        }
      }
      return DebugCheckResult(
        name: 'Attachment self-test',
        status: DebugCheckStatus.pass,
        detail:
            '${source.length}-byte buffer split into ${chunkBytes.length} '
            'chunks, hashed, reassembled byte-equal.',
      );
    } catch (error) {
      return DebugCheckResult(
        name: 'Attachment self-test',
        status: DebugCheckStatus.fail,
        detail: 'Threw: $error',
      );
    }
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
      protocolVersion: 1,
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
      final expectedRelayKey = await _requireOperationalRelayPin(
        selected.route,
      );
      await _relayClient.storeEnvelope(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        envelope: envelope,
        expectedIdentityPublicKeyBase64: expectedRelayKey,
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
        expectedIdentityPublicKeyBase64: expectedRelayKey,
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
      protocolVersion: 1,
      kind: 'pairing_announcement',
      messageId: messageId,
      conversationId: 'debug-pairing-reuse',
      senderAccountId: me.accountId,
      senderDeviceId: me.deviceId,
      recipientDeviceId: mailbox,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(
        utf8.encode((await _inviteForIdentity(me)).encodePayload()),
      ),
    );
    try {
      final expectedRelayKey = await _requireOperationalRelayPin(
        selected.route,
      );
      await _relayClient.storeEnvelope(
        host: selected.route.host,
        port: selected.route.port,
        protocol: selected.route.protocol,
        recipientDeviceId: mailbox,
        envelope: envelope,
        expectedIdentityPublicKeyBase64: expectedRelayKey,
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
        expectedIdentityPublicKeyBase64: expectedRelayKey,
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
        expectedIdentityPublicKeyBase64: expectedRelayKey,
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
      final payload = (await _inviteForIdentity(current)).encodePayload();
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
      _updateMessageState(contact.deviceId, message.id, state, route: route);
      _lastRelayStatus = '${route.label} accepted';
      await _persist(
        route.path == TransportPathKind.storeForward
            ? 'Encrypted message stored for ${contact.alias} via ${route.label}.'
            : 'Sent to ${contact.alias} via ${route.label}; waiting for a delivery receipt.',
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
      if (route.endpoint?.kind == PeerRouteKind.lan) {
        await _rememberLanRoutesForGroupMember(
          groupId: group.groupId,
          deviceId: contact.deviceId,
          routes: [route.endpoint!],
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
      _lastRelayStatus = 'group delivery via ${route.label}';
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
    if (contact == null || !contact.canSendOutbound) {
      return;
    }
    // Seen IDs also include envelopes discarded by ingress policy. Replay
    // a receipt only for an authenticated message actually stored locally.
    final message = group == null
        ? _messageById(contact.deviceId, envelope.messageId)
        : _groupMessageById(group.groupId, envelope.messageId);
    if (message == null ||
        message.outbound ||
        message.senderDeviceId != envelope.senderDeviceId ||
        contact.accountId != envelope.senderAccountId) {
      return;
    }
    try {
      await _crypto.decryptMessage(contact: contact, envelope: envelope);
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

  Future<_DeliveryRoute> _deliverToContact({
    required ContactRecord contact,
    required String recipientDeviceId,
    required RelayEnvelope envelope,
    bool allowRelayedPaths = true,
    bool allowLegacyRoutes = true,
    Set<TransportKind>? allowedUnifiedKinds,
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
    final policies = _effectiveTransportPolicies(contact);
    final candidateRoutes =
        dedupePeerEndpoints(_candidateRoutesForContact(contact))
            .where((route) => _legacyRouteAllowed(route, effective, policies))
            .where((_) => allowLegacyRoutes)
            .where(
              (route) => allowRelayedPaths || route.kind != PeerRouteKind.relay,
            )
            .toList(growable: false);
    final canTryRegistry =
        _transportRegistry != null &&
        policies.values.any(
          (policy) =>
              policy == TransportPolicy.automatic ||
              policy == TransportPolicy.preferred,
        );
    if (candidateRoutes.isEmpty && !canTryRegistry) {
      throw StateError(
        'Connectivity is disabled for ${contact.alias} — no allowed routes.',
      );
    }
    final preferredRoutes = _preferredRoutesForContact(contact)
        .where(
          (route) =>
              candidateRoutes.any((entry) => entry.routeKey == route.routeKey),
        )
        .toList(growable: false);
    Object? lastError;
    _DeliveryRoute? deliveredVia;
    final attemptedRouteKeys = <String>{};

    Future<void> tryLegacy(Iterable<PeerEndpoint> routes) async {
      if (deliveredVia != null) return;
      final untried = routes
          .where((route) => attemptedRouteKeys.add(route.routeKey))
          .toList(growable: false);
      if (untried.isEmpty) return;
      try {
        final endpoint = await _deliverAcrossRoutes(
          routes: untried,
          recipientDeviceId: recipientDeviceId,
          envelope: envelope,
        );
        deliveredVia = _DeliveryRoute.legacy(endpoint);
      } catch (error) {
        lastError = error;
      }
    }

    Future<void> tryUnifiedTransports() async {
      if (deliveredVia != null || !canTryRegistry) return;
      try {
        final registryPolicies = allowedUnifiedKinds == null
            ? policies
            : <TransportKind, TransportPolicy>{
                for (final entry in policies.entries)
                  entry.key: allowedUnifiedKinds.contains(entry.key)
                      ? entry.value
                      : TransportPolicy.disabled,
              };
        deliveredVia = await _deliverViaTransportRegistry(
          contact: contact,
          envelope: envelope,
          policies: registryPolicies,
          allowRelay: allowRelayedPaths,
        );
      } catch (error) {
        lastError = error;
      }
    }

    final preferredLan = preferredRoutes.where(
      (route) => route.kind == PeerRouteKind.lan,
    );
    final preferredDirectInternet = preferredRoutes.where(
      (route) => route.kind == PeerRouteKind.directInternet,
    );
    final preferredConestRelays = preferredRoutes.where(
      (route) => route.kind == PeerRouteKind.relay,
    );

    // Attachment protocol v2 has one deterministic route order on every
    // platform. In particular, an Iroh relay is still an Iroh path and must
    // be exhausted before the durable Conest store-forward relay. This keeps
    // the latter an offline-delivery route instead of accidentally making it
    // the hot path when an old online preference is present after migration.
    await tryLegacy(preferredLan);
    await tryUnifiedTransports();
    await tryLegacy(preferredDirectInternet);
    await tryLegacy(preferredConestRelays);
    // A contact can advertise one public endpoint while the user has
    // configured a faster/private endpoint for the same signed relay. If the
    // advertised endpoint is currently backed off, it will not enter the
    // health-ranking pass below. Reuse only aliases that were already proven
    // to carry the same stable relay instance id and are still explicitly in
    // the user's configured/contact-trusted relay set.
    await tryLegacy(_knownHealthyRelayAliasesFor(candidateRoutes));
    if (deliveredVia == null) {
      // Rank the complete advertised set, including a route whose first
      // store just failed. Its signed health response carries the stable
      // relay instance id that lets ranking discover a healthier configured
      // alias for the same relay. [tryLegacy] still filters already-attempted
      // route keys, so no failed store is repeated in this delivery pass.
      // A route already in backoff from an earlier delivery remains excluded;
      // only a route attempted in this pass may bypass that gate for the
      // signed relay-identity lookup.
      final rankCandidates = candidateRoutes
          .where(
            (route) =>
                (route.kind == PeerRouteKind.relay &&
                    attemptedRouteKeys.contains(route.routeKey)) ||
                _routeHealthTracker.isEligibleNow(route),
          )
          .toList(growable: false);
      if (rankCandidates.isNotEmpty) {
        // Probing a just-failed relay is only for stable relay-id alias
        // discovery. Preserve its store-failure backoff even when the
        // relay's lighter health endpoint answers successfully.
        final preserveFailureFor = rankCandidates
            .where(
              (route) =>
                  route.kind == PeerRouteKind.relay &&
                  attemptedRouteKeys.contains(route.routeKey),
            )
            .toList(growable: false);
        final runtimeBefore = <String, RouteRuntimeState?>{
          for (final route in preserveFailureFor)
            route.routeKey: _routeHealthTracker.runtimeFor(route)?.clone(),
        };
        final healthBefore = <String, PeerRouteHealth?>{
          for (final route in preserveFailureFor)
            route.routeKey: _routeHealthTracker.healthFor(route),
        };
        List<PeerRouteHealth> rankedChecks;
        try {
          rankedChecks = await _rankRouteHealthForDelivery(rankCandidates);
        } finally {
          for (final route in preserveFailureFor) {
            final observedRelayInstanceId = _routeHealthTracker
                .healthFor(route)
                ?.relayInstanceId;
            final runtime = runtimeBefore[route.routeKey];
            if (runtime == null) {
              _routeHealthTracker.runtimeMap.remove(route.routeKey);
            } else {
              _routeHealthTracker.runtimeMap[route.routeKey] = runtime;
            }
            final health = healthBefore[route.routeKey];
            if (health == null) {
              _routeHealthTracker.healthMap.remove(route.routeKey);
            } else {
              _routeHealthTracker.healthMap[route.routeKey] = PeerRouteHealth(
                route: health.route,
                available: health.available,
                latency: health.latency,
                checkedAt: health.checkedAt,
                relayInstanceId:
                    health.relayInstanceId ?? observedRelayInstanceId,
                error: health.error,
              );
            }
          }
        }
        final rankedRoutes = rankedChecks.map((check) => check.route);
        await tryLegacy(rankedRoutes);
      }
    }
    final result = deliveredVia;
    if (result == null) {
      throw lastError ?? StateError('No reachable route for recipient.');
    }
    final deliveredEndpoint = result.endpoint;
    if (deliveredEndpoint?.kind == PeerRouteKind.lan) {
      await _rememberLanRoutesForContact(
        deviceId: contact.deviceId,
        routes: [deliveredEndpoint!],
      );
    }
    return result;
  }

  List<PeerEndpoint> _knownHealthyRelayAliasesFor(
    List<PeerEndpoint> advertisedRoutes,
  ) {
    final me = identity;
    if (me == null) return const <PeerEndpoint>[];
    final relayIds = advertisedRoutes
        .where((route) => route.kind == PeerRouteKind.relay)
        .map(_routeHealthTracker.healthFor)
        .whereType<PeerRouteHealth>()
        .map((health) => health.relayInstanceId)
        .whereType<String>()
        .toSet();
    if (relayIds.isEmpty) return const <PeerEndpoint>[];

    final advertisedKeys = advertisedRoutes
        .map((route) => route.routeKey)
        .toSet();
    final trustedRoutes = _effectiveRelayRoutesForIdentity(me);
    final matches = <PeerRouteHealth>[];
    for (final route in trustedRoutes) {
      if (advertisedKeys.contains(route.routeKey) ||
          !_routeHealthTracker.isEligibleNow(route)) {
        continue;
      }
      final health = _routeHealthTracker.healthFor(route);
      if (health == null ||
          !health.available ||
          health.relayInstanceId == null ||
          !relayIds.contains(health.relayInstanceId)) {
        continue;
      }
      matches.add(health);
    }
    matches.sort(_routeHealthTracker.compareHealth);
    return matches.map((health) => health.route).toList(growable: false);
  }

  Map<TransportKind, TransportPolicy> _effectiveTransportPolicies(
    ContactRecord contact,
  ) {
    final global =
        _snapshot.identity?.connectivity ??
        const GlobalConnectivityPreferences();
    return {
      for (final kind in TransportKind.values)
        kind: contact.routing.effectivePolicy(kind, global),
    };
  }

  bool _legacyRouteAllowed(
    PeerEndpoint route,
    ({bool lan, bool online, RoutingPreference preferred}) effective,
    Map<TransportKind, TransportPolicy> policies,
  ) {
    final kind = route.kind == PeerRouteKind.lan
        ? TransportKind.lan
        : TransportKind.conestRelay;
    final policy = policies[kind] ?? TransportPolicy.disabled;
    if (policy == TransportPolicy.disabled ||
        policy == TransportPolicy.askBeforeUse) {
      return false;
    }
    return _routeAllowedByTransports(route, effective);
  }

  Future<_DeliveryRoute> _deliverViaTransportRegistry({
    required ContactRecord contact,
    required RelayEnvelope envelope,
    required Map<TransportKind, TransportPolicy> policies,
    bool allowRelay = true,
  }) async {
    final registry = _transportRegistry;
    final global = _snapshot.identity?.connectivity;
    if (registry == null || global == null) {
      throw StateError('No unified transport adapter is running.');
    }
    final result = await registry.deliverEnvelope(
      peer: _transportPeerForContact(contact, allowRelay: allowRelay),
      envelope: TransportEnvelope(
        id: envelope.messageId,
        recipientDeviceId: envelope.recipientDeviceId,
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(envelope.toJson()))),
        createdAt: envelope.createdAt,
      ),
      policies: policies,
    );
    return _DeliveryRoute.transport(result.receipt);
  }

  TransportPeer _transportPeerForContact(
    ContactRecord contact, {
    required bool allowRelay,
  }) {
    final global = _snapshot.identity?.connectivity;
    return TransportPeer(
      deviceId: contact.deviceId,
      transportIdentity: contact.irohEndpointId,
      identityPinned: contact.hasPinnedIrohIdentity,
      directAddresses: contact.directInternetRouteHints
          .where((route) => route.protocol == PeerRouteProtocol.udp)
          .map(_irohSocketAddressForRoute)
          .nonNulls
          .take(8)
          .toList(growable: false),
      allowRelay:
          allowRelay &&
          (global?.irohRelayEnabled ?? false) &&
          contact.routing.irohRelayEnabled,
    );
  }

  Future<DeliveryReceipt?> _deliverIrohAttachmentRange({
    required ContactRecord contact,
    required AttachmentRange range,
    required bool allowRelay,
  }) async {
    final registry = _transportRegistry;
    final global = _snapshot.identity?.connectivity;
    final adapter = registry?.adapterFor(TransportKind.iroh);
    if (registry == null || global == null || adapter == null) return null;
    final policy = contact.routing.effectivePolicy(TransportKind.iroh, global);
    if (policy == TransportPolicy.disabled ||
        policy == TransportPolicy.askBeforeUse ||
        !contact.hasPinnedIrohIdentity) {
      return null;
    }
    final peer = _transportPeerForContact(contact, allowRelay: allowRelay);
    final routes = await adapter.discoverRoutes(peer);
    for (final route in routes) {
      if (!peer.allowRelay && route.path == TransportPathKind.relayed) continue;
      final receipt = await adapter
          .sendAttachmentRange(peer: peer, route: route, range: range)
          .timeout(const Duration(seconds: 60));
      if (receipt.accepted) return receipt;
    }
    return null;
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

  bool _hasUsableLargeDirectTransport(ContactRecord contact) {
    if (_effectiveTransports(contact).lan &&
        _hasUsableLanDirectEndpoint(contact.deviceId)) {
      return true;
    }
    return _canUseIrohForContact(contact);
  }

  bool _canUseIrohForContact(ContactRecord contact) {
    final iroh = _transportRegistry?.adapterFor(TransportKind.iroh);
    if (iroh == null || !contact.hasPinnedIrohIdentity) return false;
    final policy = _effectiveTransportPolicies(contact)[TransportKind.iroh];
    return policy == TransportPolicy.automatic ||
        policy == TransportPolicy.preferred;
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

  /// Connectivity mode is bidirectional: when the user (or contact override)
  /// disables LAN or online, the matching transport is rejected for INBOUND
  /// envelopes too. Returns true when the current effective prefs would
  /// reject the ingress kind for [contact].
  bool _droppedByIngressMode(ContactRecord contact, PeerRouteKind ingressKind) {
    final effective = _effectiveTransports(contact);
    switch (ingressKind) {
      case PeerRouteKind.lan:
        return !effective.lan;
      case PeerRouteKind.relay:
      case PeerRouteKind.directInternet:
        return !effective.online;
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
      final expectedKey = _pinnedIdentityKeyForRoute(route);
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
      if (route.kind == PeerRouteKind.relay &&
          (!info.signatureVerified ||
              info.relayInstanceId == null ||
              info.identityPublicKeyBase64 == null)) {
        throw StateError('Unknown relay did not complete signed TOFU health.');
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
            final updated =
                Map<String, String>.from(_snapshot.pinnedRelayIdentityKeys)
                  ..[relayId] = announced
                  ..[route.routeKey] = announced;
            _snapshot = _snapshot.copyWith(pinnedRelayIdentityKeys: updated);
            unawaited(_saveSnapshotSilently(notify: false, debounce: true));
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
          if (_snapshot.pinnedRelayIdentityKeys[route.routeKey] != existing) {
            final updated = Map<String, String>.from(
              _snapshot.pinnedRelayIdentityKeys,
            )..[route.routeKey] = existing;
            _snapshot = _snapshot.copyWith(pinnedRelayIdentityKeys: updated);
            unawaited(_saveSnapshotSilently(notify: false, debounce: true));
          }
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
      return _routeHealthTracker.healthMap[route.routeKey] ??
          PeerRouteHealth(
            route: route,
            available: false,
            latency: null,
            checkedAt: _now().toUtc(),
            error: error.toString(),
          );
    } catch (error) {
      _routeHealthTracker.recordFailure(route, error: error.toString());
      return _routeHealthTracker.healthMap[route.routeKey] ??
          PeerRouteHealth(
            route: route,
            available: false,
            latency: null,
            checkedAt: _now().toUtc(),
            error: error.toString(),
          );
    }
  }

  String? _pinnedIdentityKeyForRoute(PeerEndpoint route) {
    final direct = _snapshot.pinnedRelayIdentityKeys[route.routeKey];
    if (direct != null) return direct;
    final relayId =
        _routeHealthTracker.healthMap[route.routeKey]?.relayInstanceId;
    return relayId == null ? null : _snapshot.pinnedRelayIdentityKeys[relayId];
  }

  Future<String?> _requireOperationalRelayPin(PeerEndpoint route) async {
    if (route.kind != PeerRouteKind.relay) return null;
    var key = _pinnedIdentityKeyForRoute(route);
    if (key != null) return key;
    final health = await _checkRouteHealth(route);
    if (!health.available) {
      throw StateError('Relay has no verified identity pin.');
    }
    key = _pinnedIdentityKeyForRoute(route);
    if (key == null) {
      throw StateError('Relay health succeeded without a persisted pin.');
    }
    return key;
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
        final expectedRelayKey = await _requireOperationalRelayPin(route);
        _storeCallCount++;
        final stopwatch = Stopwatch()..start();
        final stored = await _relayClient.storeEnvelope(
          host: route.host,
          port: route.port,
          protocol: route.protocol,
          recipientDeviceId: recipientDeviceId,
          envelope: envelope,
          expectedIdentityPublicKeyBase64: expectedRelayKey,
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
      final expectedRelayKey = await _requireOperationalRelayPin(route);
      final envelopes = await _relayClient.fetchEnvelopes(
        host: route.host,
        port: route.port,
        protocol: route.protocol,
        recipientDeviceId: mailboxId,
        limit: 4,
        expectedIdentityPublicKeyBase64: expectedRelayKey,
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

  /// Best-effort start for the LAN-direct HTTP server. Failure is silent
  /// — the relay path still works, just slower. Stores a snapshot of the
  /// local LAN addresses so they can be advertised to peers via the
  /// chunk_request payload hint.
  Future<void> _startLanDirectChannel() async {
    final channel = _lanDirectChannel;
    if (channel == null) return;
    channel.onEnvelope = _handleLanDirectEnvelope;
    final binaryChannel = channel is BinaryLanDirectChannel
        ? channel as BinaryLanDirectChannel
        : null;
    if (binaryChannel != null) {
      binaryChannel.onAttachmentBlock = _handleLanDirectAttachmentBlock;
    }
    try {
      final port = await channel.start();
      if (port != null) {
        appendDebugLog('LAN-direct server listening on port $port');
      } else {
        appendDebugLog('LAN-direct server refused to bind — fast-path off.');
      }
    } catch (error) {
      appendDebugLog('LAN-direct server failed to start: $error');
    }
    await _refreshLocalLanDirectAddressCache();
  }

  Future<void> _refreshLocalLanDirectAddressCache() async {
    try {
      _localLanAddressesCache = (await _lanAddressProvider())
          .where(isValidLanDirectHost)
          .take(4)
          .toList(growable: false);
    } catch (error) {
      appendDebugLog('LAN-direct address discovery failed: $error');
      _localLanAddressesCache = const <String>[];
    }
  }

  /// Dispatch entrypoint for envelopes arriving on the LAN-direct HTTP
  /// server. Wraps the existing `_handleAttachmentEnvelope` with the
  /// same deferred-notification accounting `_processEnvelopes` uses, so
  /// concurrent LAN + relay arrivals still coalesce into one notify.
  Future<void> _handleLanDirectEnvelope(RelayEnvelope envelope) async {
    if (_disposed) return;
    await _processEnvelopes(<RelayEnvelope>[
      envelope,
    ], ingressKind: PeerRouteKind.lan);
  }

  Future<void> _handleLanDirectAttachmentBlock(LanAttachmentBlock block) async {
    if (_disposed || block.hash.length != 32) return;
    final state = _inboundAttachments[block.attachmentId];
    if (state == null) return;
    final sender = _contactByDeviceId(state.peerDeviceId);
    if (sender == null ||
        !_effectiveTransports(sender).lan ||
        state.debugTest?.irohOnly == true) {
      return;
    }
    await _handleAttachmentChunkBytes(
      sender,
      attachmentId: block.attachmentId,
      index: block.index,
      packedBytes: block.ciphertext,
      expectedHash: block.hash,
    );
  }

  /// Public getter so the host (main.dart) and tests can read the bound
  /// port for diagnostics or assertions. Null until the channel starts.
  int? get lanDirectPort => _lanDirectChannel?.localPort;

  /// JSON-encodable hint embedded in our outgoing attachment_chunk_request
  /// (and offer) payloads so peers can cache our LAN-direct endpoint.
  /// Returns an empty map when the channel isn't running, the platform
  /// refused to bind, or no LAN addresses are known.
  Map<String, dynamic> _localLanDirectHintPayload() {
    final port = _lanDirectChannel?.localPort;
    if (port == null) return const <String, dynamic>{};
    // Identity addresses are the last successfully discovered durable view;
    // the direct-channel cache is the current runtime view. Unioning them
    // avoids advertising no endpoint during a transient Android interface
    // enumeration failure while still filtering to private LAN hosts.
    final addresses = <String>{
      ..._localLanAddressesCache,
      ...?_snapshot.identity?.lanAddresses,
    }.where(isValidLanDirectHost).take(4).toList(growable: false);
    if (addresses.isEmpty) return const <String, dynamic>{};
    return {
      'senderLanDirectPort': port,
      'senderLanAddresses': addresses,
      if (_lanDirectChannel is BinaryLanDirectChannel)
        'senderLanBinaryVersion': 1,
    };
  }

  /// Test-only view of which peer endpoints we have cached. Used by
  /// integration tests to assert the hint flowed through correctly.
  @visibleForTesting
  LanDirectEndpoint? peerLanDirectEndpointForTesting(String peerDeviceId) =>
      _peerLanDirect[peerDeviceId];

  @visibleForTesting
  void cachePeerLanDirectHintForTesting(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) => _cachePeerLanDirectFromPayload(peerDeviceId, payload);

  @visibleForTesting
  void failTransferForTesting(String attachmentId, String error) =>
      _setTransferSessionState(
        attachmentId,
        TransferState.failed,
        error: error,
      );

  /// nightly.12 test hook: snapshot of the persistent envelope outbox.
  /// Lets tests assert "this delete was queued for retry" without
  /// reaching into the vault directly.
  @visibleForTesting
  List<PendingAckDelivery> get pendingAckDeliveriesForTesting =>
      List<PendingAckDelivery>.unmodifiable(_snapshot.pendingAckDeliveries);

  /// nightly.12 test hook: drive a forced drain of the retry queue. The
  /// production loop runs from `pollNow`; the test wants to validate
  /// post-offline drainage without depending on its cadence.
  @visibleForTesting
  Future<void> retryPendingAckDeliveriesForTesting({bool force = true}) =>
      _retryPendingAckDeliveries(force: force);

  /// Picks the host of [endpoint] if it is currently reachable. Today
  /// returns the endpoint as-is; future work could probe via Socket.
  bool _lanDirectEndpointUsable(LanDirectEndpoint endpoint) {
    if (endpoint.demotedUntil != null &&
        endpoint.demotedUntil!.isAfter(DateTime.now().toUtc())) {
      return false;
    }
    // nightly.12: freshness cap 5 min → 30 min via `_lanDirectFreshness`.
    if (DateTime.now().toUtc().difference(endpoint.cachedAt) >
        _lanDirectFreshness) {
      return false;
    }
    return true;
  }

  /// Parses the LAN-direct hint embedded in incoming `attachment_offer`
  /// and `attachment_chunk_request` payloads and caches the peer's
  /// endpoint. Picks the FIRST advertised address (peers should list
  /// their best-guess LAN IP first). Tests inject a fake transport that
  /// uses a sentinel host string so the resolver doesn't matter.
  void _cachePeerLanDirectFromPayload(
    String peerDeviceId,
    Map<String, dynamic> payload,
  ) {
    final port = payload['senderLanDirectPort'];
    final addresses = payload['senderLanAddresses'];
    final binaryVersionValue = payload['senderLanBinaryVersion'];
    final incomingBinaryVersion = binaryVersionValue is int
        ? binaryVersionValue
        : null;
    if (port is! int ||
        !isValidPeerEndpointPort(port) ||
        (binaryVersionValue != null && binaryVersionValue is! int) ||
        (incomingBinaryVersion != null &&
            (incomingBinaryVersion < 0 || incomingBinaryVersion > 1)) ||
        addresses is! List ||
        addresses.isEmpty ||
        addresses.length > 4 ||
        addresses.any(
          (value) => value is! String || !isValidLanDirectHost(value),
        )) {
      return;
    }
    final previous = _peerLanDirect[peerDeviceId];
    final hosts = addresses.cast<String>();
    final localHosts = <String>[
      ..._localLanAddressesCache,
      ...?_snapshot.identity?.lanAddresses,
    ];
    bool sameSubnet(String host) => localHosts.any((local) {
      final a = InternetAddress.tryParse(host)?.rawAddress;
      final b = InternetAddress.tryParse(local)?.rawAddress;
      return a?.length == 4 &&
          b?.length == 4 &&
          a![0] == b![0] &&
          a[1] == b[1] &&
          a[2] == b[2];
    });
    final host =
        previous != null &&
            previous.port == port &&
            hosts.contains(previous.host)
        ? previous.host
        : hosts.where(sameSubnet).firstOrNull ?? hosts.first;
    final previousBinaryVersion = previous?.binaryBlockVersion ?? 0;
    // Capability fields were optional on older route/control envelopes. A
    // later envelope without the field must not downgrade an endpoint that
    // already proved binary v1 support during the authenticated debug probe.
    final binaryVersion = max(
      incomingBinaryVersion ?? 0,
      previousBinaryVersion,
    );
    if (previous != null && previous.host == host && previous.port == port) {
      previous.cachedAt = DateTime.now().toUtc();
      previous.binaryBlockVersion = binaryVersion;
      previous.alternateHosts = hosts.where((entry) => entry != host).toList();
      // Every request and heartbeat repeats this hint. It is not a route
      // change: clearing the window here resends blocks still being served.
      return;
    }
    _peerLanDirect[peerDeviceId] = LanDirectEndpoint(
      host: host,
      port: port,
      cachedAt: DateTime.now().toUtc(),
      binaryBlockVersion: binaryVersion,
      alternateHosts: hosts.where((entry) => entry != host).toList(),
    );
    appendDebugLog(
      'Cached LAN-direct endpoint for $peerDeviceId: $host:$port '
      'binary=v$binaryVersion.',
    );
    _resumeTransfersForLanEndpoint(peerDeviceId);
  }

  void _resumeTransfersForLanEndpoint(String peerDeviceId) {
    final contact = _contactByDeviceId(peerDeviceId);
    for (final state in _inboundAttachments.values.where(
      (entry) => entry.peerDeviceId == peerDeviceId && entry.accepted,
    )) {
      state.requestedInFlight.clear();
      _setTransferSessionState(state.descriptor.id, TransferState.transferring);
      if (contact != null) {
        _scheduleAttachmentRetry(state.descriptor.id);
        _startInboundRequestWindow(state, contact);
      }
    }
    if (contact != null) _pumpOutboundQueue(contact);
    notifyListeners();
  }

  /// Records a PUT failure and demotes the peer to relay-only after the
  /// second consecutive miss — but only if a fast TCP probe confirms the
  /// peer's HTTP server is actually unreachable. nightly.11 demoted on a
  /// single jitter blip and burned 30 s of relay-only delivery even when
  /// LAN was fine; nightly.12 stays sticky on transient hiccups.
  Future<void> _onLanDirectPutFailure(String peerDeviceId) async {
    final ep = _peerLanDirect[peerDeviceId];
    if (ep == null) return;
    ep.consecutiveFailures++;
    if (ep.consecutiveFailures < 2) return;
    final channel = _lanDirectChannel;
    if (channel == null || !channel.isRunning) {
      ep.demotedUntil = DateTime.now().toUtc().add(_lanDirectCooldown);
      return;
    }
    final reachable = await channel.probeReachable(
      host: ep.host,
      port: ep.port,
    );
    if (!identical(_peerLanDirect[peerDeviceId], ep)) return;
    if (reachable) {
      appendDebugLog(
        'LAN-direct PUT failures to $peerDeviceId were transient '
        '(probe ${ep.host}:${ep.port} succeeded); staying on LAN-direct.',
      );
      // Reset the streak so a later real outage still triggers demotion.
      ep.consecutiveFailures = 0;
      return;
    }
    for (final host in ep.alternateHosts) {
      final available = await channel.probeReachable(host: host, port: ep.port);
      if (!identical(_peerLanDirect[peerDeviceId], ep)) return;
      if (!available) continue;
      _peerLanDirect[peerDeviceId] = LanDirectEndpoint(
        host: host,
        port: ep.port,
        cachedAt: DateTime.now().toUtc(),
        binaryBlockVersion: ep.binaryBlockVersion,
        alternateHosts: [
          ep.host,
          ...ep.alternateHosts.where((value) => value != host),
        ],
      );
      appendDebugLog(
        'LAN-direct switched to reachable $host:${ep.port} for $peerDeviceId.',
      );
      _resumeTransfersForLanEndpoint(peerDeviceId);
      return;
    }
    ep.demotedUntil = DateTime.now().toUtc().add(_lanDirectCooldown);
    appendDebugLog(
      'LAN-direct demoted for $peerDeviceId after ${ep.consecutiveFailures} '
      'failures + probe ${ep.host}:${ep.port} unreachable; cooldown '
      '${_lanDirectCooldown.inSeconds}s.',
    );
  }

  /// Clears the failure counter after a successful PUT.
  void _onLanDirectPutSuccess(String peerDeviceId) {
    final ep = _peerLanDirect[peerDeviceId];
    if (ep == null) return;
    ep.consecutiveFailures = 0;
    ep.demotedUntil = null;
  }

  /// nightly.9 one-shot scrubber for the nightly.8 regression where the
  /// outer envelope-kind gate did not forward `attachment_progress` or
  /// `attachment_pause_control` to the attachment handler. The payloads
  /// then fell through to the default text-message path and surfaced as
  /// JSON-shaped chat bodies. Idempotent — running it twice is a no-op
  /// once the conversations have been cleaned.
  bool _scrubLeakedAttachmentEnvelopeMessages() {
    var anyChanged = false;
    final cleanedConversations = <ConversationRecord>[];
    for (final conversation in _snapshot.conversations) {
      final filtered = conversation.messages
          .where((message) => !_isLeakedAttachmentEnvelopeBody(message.body))
          .toList(growable: false);
      if (filtered.length == conversation.messages.length) {
        cleanedConversations.add(conversation);
        continue;
      }
      anyChanged = true;
      cleanedConversations.add(conversation.copyWith(messages: filtered));
    }
    if (!anyChanged) {
      return false;
    }
    final removed =
        _snapshot.conversations.fold<int>(
          0,
          (sum, c) => sum + c.messages.length,
        ) -
        cleanedConversations.fold<int>(0, (sum, c) => sum + c.messages.length);
    appendDebugLog(
      'nightly.9 scrubber: removed $removed leaked attachment-envelope body '
      'message(s) from ${cleanedConversations.length} conversation(s).',
    );
    _snapshot = _snapshot.copyWith(conversations: cleanedConversations);
    return true;
  }

  static bool _isLeakedAttachmentEnvelopeBody(String body) {
    final trimmed = body.trimLeft();
    if (!trimmed.startsWith('{')) return false;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return false;
      if (!decoded.containsKey('attachmentId')) return false;
      return decoded.containsKey('received') ||
          decoded.containsKey('pausedByMe') ||
          decoded.containsKey('pausedByPeer');
    } catch (_) {
      return false;
    }
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

  Future<ContactInvite> _inviteForIdentity(IdentityRecord identity) async {
    if (!identity.hasTransportIdentity ||
        identity.irohEndpointId?.isNotEmpty != true) {
      throw StateError('Transport identity has not been initialized.');
    }
    final unsigned = ContactInvite(
      version: 6,
      accountId: identity.accountId,
      deviceId: identity.deviceId,
      displayName: identity.displayName,
      bio: identity.bio,
      pairingNonce: identity.pairingNonce,
      pairingEpochMs: identity.pairingEpochMs,
      relayCapable: identity.relayModeEnabled,
      publicKeyBase64: identity.publicKeyBase64,
      routeHints: _inviteRouteHintsForIdentity(identity),
      signingPublicKeyBase64: identity.signingPublicKeyBase64,
      irohEndpointId: identity.irohEndpointId,
      capabilities: const [
        TransportKind.lan,
        TransportKind.iroh,
        TransportKind.conestRelay,
        TransportKind.optical,
      ],
    );
    return unsigned.copyWithSignature(
      await _crypto.signContactInvite(unsigned),
    );
  }

  List<PeerEndpoint> _inviteRouteHintsForIdentity(IdentityRecord identity) {
    final irohDirectRoutes = _irohDirectInviteRoutes(identity).take(2);
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
      ...irohDirectRoutes,
      ...lanRoutes,
      ...configuredRelayRoutes,
      ...contactRelayRoutes,
    ]).take(_maxInviteRouteHints).toList(growable: false);
  }

  List<PeerEndpoint> _irohDirectInviteRoutes(IdentityRecord identity) {
    final adapter = _transportRegistry?.adapterFor(TransportKind.iroh);
    if (adapter is! IrohTransportAdapter) return const <PeerEndpoint>[];
    final advertised = adapter.status?.directAddresses ?? const <String>[];
    final routes = <PeerEndpoint>[];
    for (final value in advertised) {
      final parsed = _parseIrohSocketAddress(value);
      if (parsed == null) continue;
      final address = InternetAddress.tryParse(parsed.host);
      if (address == null) continue;
      final unspecified = address.rawAddress.every((byte) => byte == 0);
      if (unspecified) {
        for (final candidate in identity.lanAddresses) {
          final candidateAddress = InternetAddress.tryParse(candidate);
          if (candidateAddress == null || candidateAddress.isLoopback) continue;
          routes.add(
            PeerEndpoint(
              kind: PeerRouteKind.directInternet,
              host: candidateAddress.address,
              port: parsed.port,
              protocol: PeerRouteProtocol.udp,
            ),
          );
        }
      } else if (!address.isLoopback) {
        routes.add(
          PeerEndpoint(
            kind: PeerRouteKind.directInternet,
            host: address.address,
            port: parsed.port,
            protocol: PeerRouteProtocol.udp,
          ),
        );
      }
    }
    return dedupePeerEndpoints(routes);
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
    final invite = await _inviteForIdentity(me);
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
      String? expectedRelayKey;
      try {
        expectedRelayKey = await _requireOperationalRelayPin(route);
      } catch (error) {
        _routeHealthTracker.recordFailure(route, error: error.toString());
        continue;
      }
      for (final mailboxId in mailboxIds) {
        _storeCallCount++;
        final announcement = RelayEnvelope(
          protocolVersion: 1,
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
                expectedIdentityPublicKeyBase64: expectedRelayKey,
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

  bool _preservesExistingGroupMemberIdentities(
    GroupRecord existing,
    GroupRecord incoming,
  ) {
    final incomingByDevice = <String, GroupMemberProfile>{
      for (final profile in incoming.memberProfiles) profile.deviceId: profile,
    };
    for (final prior in existing.memberProfiles) {
      final next = incomingByDevice[prior.deviceId];
      if (next == null) continue;
      if (next.accountId != prior.accountId ||
          next.publicKeyBase64 != prior.publicKeyBase64) {
        return false;
      }
    }
    for (final contact in _snapshot.contacts) {
      final next = incomingByDevice[contact.deviceId];
      if (next == null) continue;
      if (next.accountId != contact.accountId ||
          next.publicKeyBase64 != contact.publicKeyBase64) {
        return false;
      }
    }
    return true;
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
    DeliveryState state, {
    _DeliveryRoute? route,
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
      return message.copyWith(
        state: state,
        transportKind: route?.transportKind,
        transportPath: route?.path,
        transportDetail: route?.label,
      );
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
    // Capture the attachment id BEFORE pruning so the cleanup below has it.
    String? attachmentId;
    for (final m in conversations[conversationIndex].messages) {
      if (m.id == messageId) {
        attachmentId = m.attachment?.id;
        break;
      }
    }
    final updatedMessages = conversations[conversationIndex].messages
        .where((message) => message.id != messageId)
        .toList();
    conversations[conversationIndex] = conversations[conversationIndex]
        .copyWith(messages: updatedMessages);
    _snapshot = _snapshot.copyWith(conversations: conversations);
    if (attachmentId != null) {
      _outboundAttachments.remove(attachmentId);
      final inbound = _inboundAttachments.remove(attachmentId);
      inbound?.retryTimer?.cancel();
      _assembledAttachments.remove(attachmentId);
      _removeTransferSession(attachmentId);
      unawaited(_deleteAttachmentArtifacts(attachmentId));
      // If this was the active outbound for the peer, free the slot and
      // pump the queue so the next pending attachment can dispatch. The
      // helper also drops poll cadence back to idle when the last
      // transfer ends; cover the inbound-removed case here too.
      _clearActiveOutbound(peerDeviceId, attachmentId);
      if (inbound != null && !hasActiveTransfer) _reschedulePolling();
      // Drop the id from any queue snapshots as well.
      _outboundQueueByContact[peerDeviceId]?.remove(attachmentId);
      final peerContact = _contactByDeviceId(peerDeviceId);
      if (peerContact != null) _pumpOutboundQueue(peerContact);
    }
  }

  void _markSeen(String envelopeId) {
    if (!_seenEnvelopeIdSet.add(envelopeId)) {
      return;
    }
    var ids = List<String>.from(_snapshot.seenEnvelopeIds)..add(envelopeId);
    if (ids.length > seenEnvelopeCap) {
      // Trim with 10% headroom so the front-of-list copy runs once per
      // ~cap/10 envelopes instead of on every overflowing envelope. The
      // list is append-ordered, so the front holds the oldest ids.
      final keepCount = seenEnvelopeCap - (seenEnvelopeCap ~/ 10);
      final evicted = ids.sublist(0, ids.length - keepCount);
      ids = ids.sublist(ids.length - keepCount);
      evicted.forEach(_seenEnvelopeIdSet.remove);
    }
    _snapshot = _snapshot.copyWith(seenEnvelopeIds: ids);
  }

  /// Rebuilds the O(1) dedupe mirror after `_snapshot` is replaced
  /// wholesale (vault load, identity reset). Keep in sync with every
  /// `_snapshot = <whole new snapshot>` assignment.
  void _rebuildSeenEnvelopeIdSet() {
    _seenEnvelopeIdSet
      ..clear()
      ..addAll(_snapshot.seenEnvelopeIds);
  }

  /// Vault-bloat guard: relay health scores accumulate for every endpoint
  /// ever probed (debug relay checks, contacts' stale hints, defaults that
  /// rotated away) and were never evicted. Keep the most recently exercised
  /// [_relayHealthScoreCap]; an evicted score just re-learns over a few
  /// probes if its endpoint comes back.
  static const int _relayHealthScoreCap = 128;

  void _pruneRelayHealthScores() {
    final scores = _snapshot.relayHealthScores;
    if (scores.length <= _relayHealthScoreCap) {
      return;
    }
    DateTime lastTouched(RelayHealthScore score) {
      final success = score.lastSuccessAt;
      final failure = score.lastFailureAt;
      if (success == null) {
        return failure ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      }
      if (failure == null || success.isAfter(failure)) {
        return success;
      }
      return failure;
    }

    final entries = scores.entries.toList(growable: false)
      ..sort(
        (left, right) =>
            lastTouched(right.value).compareTo(lastTouched(left.value)),
      );
    _snapshot = _snapshot.copyWith(
      relayHealthScores: <String, RelayHealthScore>{
        for (final entry in entries.take(_relayHealthScoreCap))
          entry.key: entry.value,
      },
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
    _pruneRelayHealthScores();
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
          _pruneRelayHealthScores();
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

  String _beamFingerprintForSigningKey(String signingKeyBase64) {
    final digest = dart_crypto.sha256
        .convert(base64Decode(signingKeyBase64))
        .bytes
        .take(12);
    final compact = digest
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return [
      for (var index = 0; index < compact.length; index += 4)
        compact.substring(index, min(index + 4, compact.length)),
    ].join('-');
  }

  /// Public helper for fresh, collision-resistant album ids. Previously
  /// `_sendMultipleAttachments` minted ids from `DateTime.now().micros…`,
  /// which collided when two consecutive batches dispatched within the
  /// same microsecond and merged distinct albums into one bubble. Use
  /// this helper instead so the cryptographic randomness avoids that.
  String newAlbumId() => _randomId('alb');

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
    final processed = await _processEnvelopes([
      envelope,
    ], ingressKind: PeerRouteKind.lan);
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
        experimentalAndroidBackgroundRuntimeAvailable &&
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
    _transferNotificationTimer?.cancel();
    unawaited(_transferControlSubscription.cancel());
    unawaited(_platformBridge.stopTransferForeground());
    _localRelayNode.onEnvelopeStored = null;
    unawaited(_stopPairingBeacon());
    unawaited(_platformBridge.setAndroidBackgroundRuntimeEnabled(false));
    unawaited(_localRelayNode.stop());
    unawaited(_lanDirectChannel?.stop());
    unawaited(_stopTransportRegistry());
    for (final state in _outboundAttachments.values) {
      unawaited(state.closeFile());
    }
    for (final state in _inboundAttachments.values) {
      state.retryTimer?.cancel();
      unawaited(state.closeFile());
    }
    _authorizedInboundDebugFileTests.clear();
    _outboundDebugAttachmentTests.clear();
    super.dispose();
  }
}

class _AuthorizedDebugFileTest {
  const _AuthorizedDebugFileTest({
    required this.peerDeviceId,
    required this.expiresAt,
    required this.irohOnly,
  });

  final String peerDeviceId;
  final DateTime expiresAt;
  final bool irohOnly;
}

class _PairingBeaconRoute {
  const _PairingBeaconRoute({required this.route, required this.seenAt});

  final PeerEndpoint route;
  final DateTime seenAt;
}

class _EnvelopeProcessingOutcome {
  const _EnvelopeProcessingOutcome({this.processed = 0, this.failed = 0});

  final int processed;
  final int failed;
}

class _DeliveryRoute {
  const _DeliveryRoute({
    required this.transportKind,
    required this.path,
    required this.label,
    required this.routeKey,
    this.endpoint,
  });

  factory _DeliveryRoute.legacy(PeerEndpoint endpoint) => _DeliveryRoute(
    transportKind: endpoint.kind == PeerRouteKind.lan
        ? TransportKind.lan
        : TransportKind.conestRelay,
    path: endpoint.kind == PeerRouteKind.lan
        ? TransportPathKind.local
        : endpoint.kind == PeerRouteKind.directInternet
        ? TransportPathKind.direct
        : TransportPathKind.storeForward,
    label: endpoint.kind == PeerRouteKind.lan
        ? 'LAN ${endpoint.label}'
        : 'Conest relay ${endpoint.label}',
    routeKey: endpoint.routeKey,
    endpoint: endpoint,
  );

  factory _DeliveryRoute.transport(DeliveryReceipt receipt) => _DeliveryRoute(
    transportKind: receipt.route.transport,
    path: receipt.route.path,
    label: receipt.route.label,
    routeKey: receipt.route.routeId,
  );

  final TransportKind transportKind;
  final TransportPathKind path;
  final String label;
  final String routeKey;
  final PeerEndpoint? endpoint;

  PeerRouteKind get kind => switch (path) {
    TransportPathKind.local => PeerRouteKind.lan,
    TransportPathKind.direct => PeerRouteKind.directInternet,
    TransportPathKind.relayed ||
    TransportPathKind.storeForward ||
    TransportPathKind.manual => PeerRouteKind.relay,
  };

  String get host => endpoint?.host ?? label;
  int get port => endpoint?.port ?? 0;
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
    required this.sourcePath,
    required this.sourceKind,
    required this.descriptor,
    required this.requiresLan,
    this.lanOnly = false,
  });

  final String messageId;
  final String peerDeviceId;
  final String sourcePath;
  final TransferSourceKind sourceKind;
  final AttachmentDescriptor descriptor;
  final bool requiresLan;
  final bool lanOnly;

  RandomAccessFile? _sourceHandle;
  Future<void> _sourceIo = Future<void>.value();

  /// Serializes seeks on one long-lived descriptor. Multiple receiver
  /// requests may arrive concurrently, but RandomAccessFile has one cursor.
  Future<Uint8List> readChunk(int offset, int length) {
    final completer = Completer<Uint8List>();
    _sourceIo = _sourceIo.catchError((_) {}).then((_) async {
      try {
        final handle = _sourceHandle ??= await File(sourcePath).open();
        await handle.setPosition(offset);
        completer.complete(Uint8List.fromList(await handle.read(length)));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> closeFile() async {
    await _sourceIo.catchError((_) {});
    final handle = _sourceHandle;
    _sourceHandle = null;
    await handle?.close();
  }

  /// Highest chunk index the receiver has successfully pulled. Drives the
  /// sender-side progress bar. Reset to -1 on entry, advanced by every
  /// `_handleAttachmentChunkRequest` that we honour.
  int highestChunkSent = -1;

  /// Bilateral pause state. Either side may pause; only the side that set
  /// pausedByMe can clear it. The other side sees pausedByPeer and can
  /// cancel/delete but not silently un-pause.
  bool pausedByMe = false;
  bool pausedByPeer = false;
  bool get paused => pausedByMe || pausedByPeer;

  /// When this transfer became "active" — i.e. its offer envelope shipped
  /// and the queue worker is now watching for chunk activity. Used by the
  /// stall escape hatch to decide when to declare the transfer dead.
  DateTime? activatedAt;

  /// Last time the chunk-request handler advanced `highestChunkSent`.
  /// Refreshed on every chunk we successfully shipped.
  DateTime? lastChunkAt;

  /// Receiver's reported received-chunk count from the most recent
  /// `attachment_progress` envelope. Used by `outboundAttachmentProgress`
  /// to render the SAME percentage on the sender side as the receiver
  /// shows — fixes the nightly.7 desync where each side computed its
  /// own value (LocalSend-style).
  int? peerReceivedCount;
  int? peerReceivedBytes;
  DateTime? peerProgressAt;
  DateTime? _rateSampleAt;
  int _rateSampleBytes = 0;
  double? bytesPerSecond;

  void recordPeerProgress(int bytes, DateTime at) {
    final previousAt = _rateSampleAt;
    if (previousAt != null && bytes >= _rateSampleBytes) {
      final seconds = at.difference(previousAt).inMicroseconds / 1000000;
      if (seconds > 0) {
        final instant = (bytes - _rateSampleBytes) / seconds;
        bytesPerSecond = bytesPerSecond == null
            ? instant
            : bytesPerSecond! * 0.7 + instant * 0.3;
      }
    }
    _rateSampleAt = at;
    _rateSampleBytes = bytes;
    peerReceivedBytes = bytes;
    peerProgressAt = at;
  }

  /// Number of automatic re-enqueues fired by the stall escape hatch
  /// while the contact stayed reachable. Capped at
  /// [MessengerController._outboundAutoRetryLimit]; after that the
  /// bubble flips to Failed and waits for a manual tap.
  int autoRetries = 0;
  DateTime? nextRetryAt;

  /// Set whenever a chunk is delivered via a NON-primary route — the
  /// preferred route (usually LAN) failed and the rotation inside
  /// `_deliverToContact` had to fall through to relay. The bubble's
  /// status line shows "Rerouting · X%" while this flag is fresh so the
  /// user can tell their transfer is recovering via a backup path.
  DateTime? lastRouteFallbackAt;

  /// `_handleAttachmentChunkRequest` tracks consecutive failed chunk
  /// deliveries. When this hits a small threshold the UI surfaces a
  /// rerouting hint even before a successful fallback lands.
  int consecutiveChunkFailures = 0;

  /// nightly.11: kind of the route the most recent successful chunk
  /// delivery used. The bubble overlay shows this as a small "LAN" or
  /// "relay" chip so the user can see at a glance whether LAN-direct is
  /// actually firing — the nightly.9-10 LAN-speed root cause was that
  /// LAN-direct was silently failing on Android and falling through to
  /// relay; this chip surfaces the misbehaviour instantly.
  OutboundDeliveryRoute lastDeliveryRoute = OutboundDeliveryRoute.unknown;
}

class _PreparedAttachmentSource {
  const _PreparedAttachmentSource({
    required this.path,
    required this.relativePath,
    required this.sourceKind,
    required this.sizeBytes,
    required this.fileHashBase64,
    required this.sourceModifiedAt,
  });

  final String path;
  final String relativePath;
  final TransferSourceKind sourceKind;
  final int sizeBytes;
  final String fileHashBase64;
  final DateTime sourceModifiedAt;
}

/// Channel that carried the most recent successful chunk delivery for
/// an outbound attachment.
enum OutboundDeliveryRoute {
  unknown,
  lanDirect,
  irohDirect,
  irohRelay,
  conestRelay,
}

class _InboundAttachmentState {
  _InboundAttachmentState({
    required this.messageId,
    required this.peerDeviceId,
    required this.descriptor,
    this.partialPath,
    this.awaitingAcceptance = false,
    this.accepted = true,
    this.debugTest,
    Iterable<int> receivedChunks = const <int>[],
  }) : received = <int>{...receivedChunks};

  final String messageId;
  final String peerDeviceId;
  final AttachmentDescriptor descriptor;
  final Set<int> received;
  String? partialPath;
  bool awaitingAcceptance;
  bool accepted;
  final DebugAttachmentTestSpec? debugTest;
  bool finalizing = false;
  RandomAccessFile? _partialHandle;
  Future<void> _partialIo = Future<void>.value();
  int _bytesSinceCheckpoint = 0;
  DateTime _lastCheckpointAt = DateTime.now().toUtc();
  DateTime? _rateSampleAt;
  int _rateSampleBytes = 0;
  double? bytesPerSecond;

  static const int checkpointBytes = 8 * 1024 * 1024;
  static const Duration checkpointInterval = Duration(seconds: 2);

  Future<void> writeChunk(int offset, Uint8List bytes) {
    final completer = Completer<void>();
    _partialIo = _partialIo.catchError((_) {}).then((_) async {
      try {
        final path = partialPath;
        if (path == null) throw StateError('Partial attachment path is gone.');
        // For RandomAccessFile, Dart's append mode means read/write without
        // truncation; setPosition still selects the durable range offset.
        // FileMode.writeOnly would truncate the preallocated partial here.
        final handle = _partialHandle ??= await File(
          path,
        ).open(mode: FileMode.append);
        await handle.setPosition(offset);
        await handle.writeFrom(bytes);
        _bytesSinceCheckpoint += bytes.length;
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  bool get shouldCheckpoint =>
      _bytesSinceCheckpoint >= checkpointBytes ||
      DateTime.now().toUtc().difference(_lastCheckpointAt) >=
          checkpointInterval;

  Future<void> checkpoint() {
    final completer = Completer<void>();
    _partialIo = _partialIo.catchError((_) {}).then((_) async {
      try {
        await _partialHandle?.flush();
        _bytesSinceCheckpoint = 0;
        _lastCheckpointAt = DateTime.now().toUtc();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> closeFile() {
    checkpointTimer?.cancel();
    checkpointTimer = null;
    final completer = Completer<void>();
    _partialIo = _partialIo.catchError((_) {}).then((_) async {
      try {
        final handle = _partialHandle;
        _partialHandle = null;
        await handle?.close();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  int get receivedBytes => _verifiedBytesFor(descriptor, received);

  void recordProgress() {
    final now = DateTime.now().toUtc();
    final bytes = receivedBytes;
    final previousAt = _rateSampleAt;
    if (previousAt != null && bytes >= _rateSampleBytes) {
      final seconds = now.difference(previousAt).inMicroseconds / 1000000;
      if (seconds > 0) {
        final instant = (bytes - _rateSampleBytes) / seconds;
        bytesPerSecond = bytesPerSecond == null
            ? instant
            : bytesPerSecond! * 0.7 + instant * 0.3;
      }
    }
    _rateSampleAt = now;
    _rateSampleBytes = bytes;
  }

  /// Re-request timer that fires if no chunk has arrived for ~5 s. Reset on
  /// every received chunk; cancelled on completion or cancel/delete.
  Timer? retryTimer;
  Timer? checkpointTimer;

  /// Number of consecutive timer-triggered re-requests. Capped to avoid an
  /// unbounded loop on a permanently-broken peer.
  int retryAttempts = 0;
  DateTime? nextRetryAt;

  /// Bilateral pause state mirrors the outbound side.
  bool pausedByMe = false;
  bool pausedByPeer = false;
  bool get paused => pausedByMe || pausedByPeer;

  /// Indices we've asked the sender for and not yet received. Used to keep
  /// up to `MessengerController._inboundChunkWindow` requests outstanding
  /// so a slow path doesn't serialize on per-chunk RTT.
  final Set<int> requestedInFlight = <int>{};

  /// Debounce gate for `attachment_progress` envelopes the receiver sends
  /// back to the sender. We emit at most one per [_progressDebounce]
  /// window to keep big transfers from drowning the relay in tiny
  /// progress envelopes.
  DateTime? lastProgressSentAt;

  int get nextMissingIndex {
    for (var i = 0; i < descriptor.effectiveChunkCount; i++) {
      if (!received.contains(i)) {
        return i;
      }
    }
    return -1;
  }

  /// Like [nextMissingIndex] but also skips chunks we already have a
  /// request out for. Used by the windowed top-up loop to avoid asking
  /// for the same chunk twice.
  int nextUnrequestedIndex() {
    for (var i = 0; i < descriptor.effectiveChunkCount; i++) {
      if (!received.contains(i) && !requestedInFlight.contains(i)) {
        return i;
      }
    }
    return -1;
  }

  bool get isComplete => received.length == descriptor.effectiveChunkCount;
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
  Future<RelayFetchBatch> fetchLeasedEnvelopes({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    int limit = 64,
    Duration timeout = const Duration(seconds: 4),
    Duration waitFor = Duration.zero,
    Duration leaseFor = const Duration(seconds: 60),
    String? expectedIdentityPublicKeyBase64,
  }) {
    return _track(
      host: host,
      port: port,
      protocol: protocol,
      action: () => inner.fetchLeasedEnvelopes(
        host: host,
        port: port,
        protocol: protocol,
        recipientDeviceId: recipientDeviceId,
        limit: limit,
        timeout: timeout,
        waitFor: waitFor,
        leaseFor: leaseFor,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      ),
    );
  }

  @override
  Future<void> acknowledgeLease({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    required String leaseId,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) {
    return _track(
      host: host,
      port: port,
      protocol: protocol,
      action: () => inner.acknowledgeLease(
        host: host,
        port: port,
        protocol: protocol,
        recipientDeviceId: recipientDeviceId,
        leaseId: leaseId,
        timeout: timeout,
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
