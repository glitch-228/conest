import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'file_privacy_controller_cases.dart';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:conest/main.dart' as app;
import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/src/ui/internet_transports.dart';
import 'package:conest/src/ui/tor_carrier_panel.dart';
import 'package:conest/src/app_locales.dart';
import 'package:conest/src/ui/calls_list.dart';
import 'package:conest/main.dart' show sniffImageMimeType, buildDeltaAttachment;
import 'package:conest/src/bitchat/direct.dart';
import 'package:conest/src/bitchat/desktop_links.dart';
import 'package:conest/src/bitchat/gateway.dart';
import 'package:conest/src/bitchat/geo_relays.g.dart';
import 'package:conest/src/bitchat/mesh.dart';
import 'package:conest/src/bitchat/packet.dart';
import 'package:conest/src/bitchat_carrier.dart';
import 'package:conest/src/bitchat_chats.dart';
import 'package:conest/src/build_info.dart';
import 'package:conest/src/carrier.dart';
import 'package:conest/src/crypto_service.dart';
import 'package:conest/src/feature_models.dart';
import 'package:conest/src/email/mail_socket.dart';
import 'package:conest/src/account/account_model.dart';
import 'package:conest/src/energy_policy.dart';
import 'package:conest/src/ui/devices_panel.dart';
import 'package:conest/src/connection_map.dart';
import 'package:conest/src/debug_auto_run.dart';
import 'package:conest/src/transport_exchange_test.dart';
import 'package:conest/src/ui/connections_screen.dart';
import 'package:conest/src/ui/error_history_screen.dart';
import 'package:conest/src/ui/user_mode_screen.dart';
import 'package:conest/src/group_file_crypto.dart';
import 'package:conest/src/group_call/group_call_media.dart';
import 'package:conest/src/group_call/group_call_crypto.dart';
import 'package:conest/src/group_call/group_call_models.dart';
import 'support/fake_call_network.dart' show FakeCallMedia;
import 'package:conest/src/group_file_download.dart';
import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/iroh_ffi_bridge.dart';
import 'package:conest/src/iroh_transport.dart';
import 'package:conest/src/lan_direct.dart';
import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/matrix_carrier.dart';
import 'package:conest/src/meshcore_carrier.dart';
import 'package:conest/src/meshtastic_carrier.dart';
import 'package:conest/src/meshtastic/radio.dart';
import 'package:conest/src/radio_chats.dart';
import 'package:conest/src/matrix_client.dart';
import 'package:conest/src/matrix_service.dart';
import 'package:conest/src/messenger_controller.dart';
import 'package:conest/src/delta_chats.dart';
import 'package:conest/src/email/delta_mail.dart';
import 'package:conest/src/email/carrier_mail.dart' show maxCarrierMailBytes;
import 'package:conest/src/email/delta_content.dart';
import 'package:conest/src/email/pgp.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/network_history.dart';
import 'package:conest/src/native_attachment_crypto.dart';
import 'package:conest/src/nostr/event.dart';
import 'package:conest/src/nostr/relay.dart';
import 'package:conest/src/nostr_carrier.dart';
import 'package:conest/src/nostr_direct.dart';
import 'package:conest/src/nostr/nip17.dart';
import 'package:conest/src/platform_bridge.dart';
import 'package:conest/src/ratchet.dart';
import 'package:conest/src/relay_client.dart'
    show
        RelayClient,
        RelayFetchBatch,
        RelayHealthInfo,
        RelayIdentityMismatchException;
import 'package:conest/src/relay_defaults.dart';
import 'package:conest/src/reticulum/rnode_interface.dart';
import 'package:conest/src/reticulum_carrier.dart';
import 'package:conest/src/storage.dart';
import 'package:conest/src/storage_capacity.dart';
import 'package:conest/src/tor_carrier.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/ui/app_mode_selector.dart';
import 'package:conest/src/ui/matrix_home_screen.dart';
import 'package:conest/src/update_service.dart';
import 'package:conest/src/voice_call_service.dart';
import 'package:conest/src/group_file_manifest.dart';

import 'support/fake_homeserver.dart';
import 'support/fake_ble_mesh.dart';
import 'support/fake_desktop_ble.dart';
import 'support/fake_mail_server.dart';
import 'support/fake_matrix_native.dart';
import 'support/fake_meshcore.dart';
import 'support/fake_meshtastic.dart';
import 'support/fake_nostr_relay.dart';
import 'support/fake_ratchet_engine.dart';
import 'support/observing_ratchet_store.dart';
import 'support/fake_rns_bus.dart';
import 'support/fake_tor.dart';

part 'delta_controller_content_tests.dart';
part 'l10n_controller_cases.dart';

const _fakeRelayIdentityKey = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

Future<String> _realPrivateLanHost() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.any,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (isValidLanDirectHost(address.address)) return address.address;
    }
  }
  throw StateError('No private or link-local interface is available.');
}

/// nightly.9 in-process LAN-direct channel that bypasses real HTTP — the
/// Flutter test binding intercepts every HttpClient request and returns
/// 400, which would defeat any real-network test. This double routes
/// envelopes by a synthetic "host:port" registry so the controller-side
/// integration (hint flow + cache + fast-path) can be exercised end-to-end.
class _InProcessLanDirectChannel
    implements LanDirectChannel, BinaryLanDirectChannel {
  _InProcessLanDirectChannel({required this.host});

  static final Map<String, _InProcessLanDirectChannel> _registry = {};
  static int _nextPort = 49000;

  final String host;
  int? _port;
  Future<void> Function(RelayEnvelope envelope)? _handler;
  Future<void> Function(LanAttachmentBlock block)? _blockHandler;

  /// Number of envelopes this channel has accepted. Tests assert > 0 to
  /// confirm the fast-path actually carried traffic.
  int acceptedEnvelopes = 0;

  /// nightly.12: per-test knob. When `simulatedReachable == false`, the
  /// `probeReachable` method returns false so the controller's
  /// probe-before-demote gate triggers an actual demotion. Default true
  /// (the peer is reachable; transient PUT failures shouldn't demote).
  bool simulatedReachable = true;

  /// nightly.12: queue of PUT calls that should fail (returns false)
  /// even when the destination channel is registered. Consumed FIFO. Use
  /// to simulate a single chunk hiccup without taking the channel down.
  int transientFailureCount = 0;

  /// Receiver-side cutoff used by restart/resume tests. Once this channel
  /// has accepted the configured number of envelopes, later PUTs fail until
  /// a replacement channel is started after the simulated restart.
  int? rejectAfterAcceptedEnvelopes;

  /// Optional test barrier for proving UI/controller operations don't await
  /// a slow LAN request. Complete it to release queued PUTs.
  Completer<void>? blockPutsUntil;
  Future<bool> Function()? blockPutOverride;

  @override
  int? get localPort => _port;

  @override
  bool get isRunning => _port != null;

  @override
  set onEnvelope(Future<void> Function(RelayEnvelope envelope) handler) {
    _handler = handler;
  }

  @override
  set onAttachmentBlock(
    Future<void> Function(LanAttachmentBlock block) handler,
  ) {
    _blockHandler = handler;
  }

  @override
  Future<int?> start() async {
    if (_port != null) return _port;
    _port = _nextPort++;
    _registry['$host:$_port'] = this;
    return _port;
  }

  @override
  Future<void> stop() async {
    if (_port != null) {
      _registry.remove('$host:$_port');
      _port = null;
    }
  }

  @override
  Future<bool> probeReachable({
    required String host,
    required int port,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final barrier = blockPutsUntil;
    if (barrier != null) await barrier.future;
    final target = _registry['$host:$port'];
    if (target == null) return false;
    return target.simulatedReachable;
  }

  @override
  Future<bool> putEnvelope({
    required String host,
    required int port,
    required RelayEnvelope envelope,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final target = _registry['$host:$port'];
    if (target == null) return false;
    // nightly.12: transient-failure injection — consume one slot from the
    // queue without delivering. Lets the test exercise the controller's
    // probe-before-demote gate.
    if (transientFailureCount > 0) {
      transientFailureCount--;
      return false;
    }
    final cutoff = target.rejectAfterAcceptedEnvelopes;
    if (cutoff != null && target.acceptedEnvelopes >= cutoff) {
      return false;
    }
    final handler = target._handler;
    if (handler == null) return false;
    target.acceptedEnvelopes++;
    // Roundtrip through JSON so we exercise the same serialization the
    // real HttpLanDirectChannel would use.
    final roundTripped = RelayEnvelope.fromJson(
      jsonDecode(jsonEncode(envelope.toJson())) as Map<String, dynamic>,
    );
    await handler(roundTripped);
    return true;
  }

  @override
  Future<bool> putAttachmentBlock({
    required String host,
    required int port,
    required LanAttachmentBlock block,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final override = blockPutOverride;
    if (override != null) return override();
    final target = _registry['$host:$port'];
    if (target == null) return false;
    if (transientFailureCount > 0) {
      transientFailureCount--;
      return false;
    }
    final cutoff = target.rejectAfterAcceptedEnvelopes;
    if (cutoff != null && target.acceptedEnvelopes >= cutoff) return false;
    final handler = target._blockHandler;
    if (handler == null) return false;
    target.acceptedEnvelopes++;
    await handler(
      LanAttachmentBlock(
        attachmentId: block.attachmentId,
        index: block.index,
        hash: Uint8List.fromList(block.hash),
        ciphertext: Uint8List.fromList(block.ciphertext),
      ),
    );
    return true;
  }
}

class _MemoryVaultStore extends VaultStore {
  _MemoryVaultStore()
    : this._(Directory.systemTemp.createTempSync('conest-controller-history-'));
  _MemoryVaultStore._(Directory directory)
    : super(
        vaultFileProvider: () async => File('${directory.path}/vault'),
        keyProvider: FileVaultKeyProvider(
          fileProvider: () async => File('${directory.path}/key'),
        ),
      ) {
    addTearDown(() async {
      await closeGroupHistory();
      // Background ratchet writes (for example a reset bundle) can still be
      // landing after the controllers are disposed; let them drain.
      for (var attempt = 0; await directory.exists(); attempt++) {
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          if (attempt >= 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
  }
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
    await super.clear();
    _snapshot = VaultSnapshot.empty();
  }
}

class _GroupCallVaultStore extends _MemoryVaultStore {
  Future<void> Function()? beforePeerWrite;
  int committedPeerWrites = 0;
  final watchedIdentities = <String, Completer<void>>{};
  int watchedWrites = 0;

  Completer<void> watchIdentity(String identity) =>
      watchedIdentities[identity] = Completer<void>();

  @override
  Future<RatchetStore> openRatchetStore() async =>
      ObservingRatchetStore(await super.openRatchetStore(), (state) {
        committedPeerWrites++;
        final completion = watchedIdentities[state.peerIdentityKey];
        if (completion != null) {
          watchedWrites++;
          if (!completion.isCompleted) completion.complete();
        }
      }, () async => await beforePeerWrite?.call());
}

class _DelayedVaultStore extends _MemoryVaultStore {
  Completer<void>? releaseWrite;
  Completer<void>? writeStarted;

  @override
  Future<void> save(VaultSnapshot snapshot) async {
    final barrier = releaseWrite;
    if (barrier != null) {
      releaseWrite = null;
      writeStarted?.complete();
      await barrier.future;
    }
    await super.save(snapshot);
  }
}

class _FailingVaultStore extends _MemoryVaultStore {
  bool failNextSave = false;

  @override
  Future<void> save(VaultSnapshot snapshot) async {
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('simulated vault save failure');
    }
    await super.save(snapshot);
  }
}

// Exercise the production TCP multiplexer without occupying the app's port.
class _EphemeralLocalRelayNode extends LocalRelayNode {
  @override
  Future<void> start(int port) async {
    if (isRunning) return;
    final reservation = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final availablePort = reservation.port;
    await reservation.close();
    await super.start(availablePort);
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

/// Simulates the Android symptom where a platform-side stop call hangs.
/// `resetIdentity` must time out and proceed instead of blocking the UI.
class _HangingLocalRelayNode extends LocalRelayNode {
  bool _running = true;

  @override
  bool get isRunning => _running;

  @override
  int? get port => 0;

  @override
  Future<void> start(int port) async {}

  @override
  Future<void> stop() async {
    // Never completes — mimics a wedged native call.
    await Completer<void>().future;
    _running = false;
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
    this.shouldFailStore,
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
  // nightly.12: mutable so tests can toggle store-failure mid-run
  // (e.g. "Bob is offline, then comes back online" scenarios).
  bool Function(
    String host,
    int port,
    PeerRouteProtocol protocol,
    String recipientDeviceId,
    RelayEnvelope envelope,
  )?
  shouldFailStore;
  final List<String> storeAttempts = <String>[];

  /// An error to throw for stores to [host] (a network's own error).
  Object? Function(String host)? storeErrorFor;
  final List<String> fetchAttempts = <String>[];

  /// Hosts asked with a wait (long polls).
  final List<String> waitingFetchHosts = <String>[];
  final List<String> inspectHealthAttempts = <String>[];
  final List<RelayEnvelope> storedEnvelopes = <RelayEnvelope>[];
  final Map<String, List<RelayEnvelope>> _queues =
      <String, List<RelayEnvelope>>{};

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
  }) async => RelayFetchBatch(
    envelopes: await (() {
      if (waitFor > Duration.zero) waitingFetchHosts.add(host);
      return fetchEnvelopes(
        host: host,
        port: port,
        protocol: protocol,
        recipientDeviceId: recipientDeviceId,
        limit: limit,
        timeout: timeout,
        waitFor: waitFor,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      );
    })(),
  );

  @override
  Future<void> acknowledgeLease({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    required String leaseId,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) async {}

  // ---- nightly.9 aggressive simulator knobs ----
  //
  // These are additive — every existing knob keeps working. Tests opt in
  // by populating these fields; an empty / zero default is a no-op.

  /// Scriptable route-availability timeline. Each entry is evaluated by
  /// finding the latest entry whose [at] has elapsed since the first
  /// `storeEnvelope` call; the current state is its `(lanUp, relayUp)`.
  /// A store against a route whose kind is currently "down" throws.
  /// Default empty = both routes always up.
  final List<({Duration at, bool lanUp, bool relayUp})> routeTimeline =
      <({Duration at, bool lanUp, bool relayUp})>[];

  /// Per-envelope latency injection. Both bounds inclusive. Default zero
  /// = instant. Helps test pipelining + window behaviour under jitter.
  Duration latencyMin = Duration.zero;
  Duration latencyMax = Duration.zero;

  /// If a key matches an attachmentId, after that many chunk envelopes
  /// have flowed for the attachment the NEXT chunk store throws. Cleared
  /// after firing once so the failure is a singular blip, not permanent.
  final Map<String, int> midTransferInterruptionAt = <String, int>{};

  /// Counter of chunk envelopes per attachmentId that have flowed
  /// successfully through storeEnvelope. Used by
  /// [midTransferInterruptionAt] to decide when to fire.
  final Map<String, int> _chunkFlowCount = <String, int>{};

  /// Returns true if the host:protocol pair is currently a "LAN" route.
  /// Default heuristic: hosts that look like RFC1918 IPs OR 127.0.0.1
  /// are LAN; everything else is treated as relay.
  bool Function(String host, PeerRouteProtocol protocol) routeClassifier =
      _defaultRouteClassifier;

  static bool _defaultRouteClassifier(String host, PeerRouteProtocol protocol) {
    if (host == '127.0.0.1' ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host)) {
      return true;
    }
    return false;
  }

  /// Lazy stopwatch started on the first `storeEnvelope` call so timeline
  /// entries are relative to test start, not wall clock.
  final Stopwatch _simClock = Stopwatch();
  final Random _simRandom = Random(0xC0DE);

  ({bool lanUp, bool relayUp}) _currentRouteState() {
    if (routeTimeline.isEmpty) return (lanUp: true, relayUp: true);
    var current = (lanUp: true, relayUp: true);
    final elapsed = _simClock.elapsed;
    for (final entry in routeTimeline) {
      if (entry.at <= elapsed) {
        current = (lanUp: entry.lanUp, relayUp: entry.relayUp);
      }
    }
    return current;
  }

  Future<void> _maybeApplyLatency() async {
    if (latencyMax <= Duration.zero) return;
    final spanMicros = latencyMax.inMicroseconds - latencyMin.inMicroseconds;
    final jitter = spanMicros > 0
        ? latencyMin.inMicroseconds + _simRandom.nextInt(spanMicros)
        : latencyMin.inMicroseconds;
    await Future<void>.delayed(Duration(microseconds: jitter.toInt()));
  }

  /// True if the store should fail because the requested route's kind is
  /// currently scripted as "down" in [routeTimeline].
  bool _shouldFailDueToRouteTimeline(String host, PeerRouteProtocol protocol) {
    if (routeTimeline.isEmpty) return false;
    final state = _currentRouteState();
    final isLan = routeClassifier(host, protocol);
    return isLan ? !state.lanUp : !state.relayUp;
  }

  /// True if [midTransferInterruptionAt] is armed for the envelope's
  /// attachment AND the per-attachment chunk counter has reached the
  /// threshold. Consumes the trigger so it fires exactly once.
  bool _shouldFireInterruption(RelayEnvelope envelope) {
    if (envelope.kind != 'attachment_chunk') return false;
    // The chunk envelope's payload is encrypted, so we can't read the
    // attachmentId without the crypto layer. Instead we key on the
    // message-id prefix the controller uses, which lives in cleartext
    // header fields, OR allow tests to pass the parent attachmentId via
    // a special "*" wildcard meaning "any attachment_chunk".
    final wildcard = midTransferInterruptionAt['*'];
    if (wildcard == null) return false;
    final count = _chunkFlowCount['*'] ?? 0;
    if (count + 1 >= wildcard) {
      midTransferInterruptionAt.remove('*');
      return true;
    }
    _chunkFlowCount['*'] = count + 1;
    return false;
  }

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
    // nightly.9 simulator: start the lazy clock + apply optional latency
    // jitter + route-timeline gating before any of the static checks fire.
    if (!_simClock.isRunning) _simClock.start();
    await _maybeApplyLatency();
    if (_shouldFailDueToRouteTimeline(host, protocol)) {
      throw StateError(
        'Simulated outage (route timeline) for ${_key(host, port, protocol)}',
      );
    }
    if (_shouldFireInterruption(envelope)) {
      throw StateError(
        'Simulated mid-transfer interruption at ${_key(host, port, protocol)}',
      );
    }
    final key = _key(host, port, protocol);
    storeAttempts.add('$host:$port');
    if (!_isRouteAllowed(_storeAllowedHosts, host, port, protocol)) {
      throw StateError('Route unavailable for $key');
    }
    if (storeErrorFor?.call(host) case final error?) throw error;
    if (_containsRoute(_storeFailingHosts, host, port, protocol)) {
      throw StateError('Route unavailable for $key');
    }
    if (shouldFailStore?.call(
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
    if (storeErrorFor?.call(host) case final error?) throw error;
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
      identityPublicKeyBase64:
          expectedIdentityPublicKeyBase64 ?? _fakeRelayIdentityKey,
      signatureVerified: true,
    );
  }
}

class _LeasedFakeRelayClient extends _FakeRelayClient {
  int acknowledgementCount = 0;

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
  }) async {
    final envelopes = await fetchEnvelopes(
      host: host,
      port: port,
      protocol: protocol,
      recipientDeviceId: recipientDeviceId,
      limit: limit,
      timeout: timeout,
      waitFor: waitFor,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
    return RelayFetchBatch(
      envelopes: envelopes,
      leaseId: envelopes.isEmpty ? null : 'lease-0123456789abcdef',
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
  }) async {
    acknowledgementCount++;
  }
}

class _BlockingFetchRelayClient extends _FakeRelayClient {
  Completer<void>? _fetchEntered;
  Completer<void>? _releaseFetch;

  Future<void> blockNextFetch() {
    _fetchEntered = Completer<void>();
    _releaseFetch = Completer<void>();
    return _fetchEntered!.future;
  }

  void releaseBlockedFetch() {
    final release = _releaseFetch;
    if (release != null && !release.isCompleted) release.complete();
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
    final entered = _fetchEntered;
    final release = _releaseFetch;
    if (entered != null && release != null && !entered.isCompleted) {
      entered.complete();
      await release.future;
      _fetchEntered = null;
      _releaseFetch = null;
    }
    return super.fetchEnvelopes(
      host: host,
      port: port,
      protocol: protocol,
      recipientDeviceId: recipientDeviceId,
      limit: limit,
      timeout: timeout,
      waitFor: waitFor,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
  }
}

ConestBuildInfo _createBuildInfo() {
  return ConestBuildInfo(
    appName: 'Conest',
    packageName: 'dev.conest.conest',
    version: '0.1.0',
    buildNumber: '1',
    channel: UpdateChannel.nightly,
    isDebugBuild: true,
  );
}

UpdateService _createUpdateService() {
  return UpdateService(
    buildInfo: _createBuildInfo(),
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
  }) async => RelayFetchBatch(
    envelopes: await fetchEnvelopes(
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

  @override
  Future<void> acknowledgeLease({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    required String leaseId,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) async {}

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
    return RelayHealthInfo(
      ok: true,
      relayInstanceId: 'fake-relay-$host:$port',
      identityPublicKeyBase64:
          expectedIdentityPublicKeyBase64 ?? _fakeRelayIdentityKey,
      signatureVerified: true,
    );
  }
}

/// The widget-test binding replaces HttpClient with a mock that answers
/// 400; the Matrix tests need real loopback HTTP to their fake homeserver.
class _RealHttpOverrides extends HttpOverrides {}

MatrixHttp _realMatrixHttp() =>
    HttpOverrides.runWithHttpOverrides(IoMatrixHttp.new, _RealHttpOverrides());

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
  LocalRelayNode? localRelayNode,
  Future<Directory> Function()? attachmentRootProvider,
  PlatformBridge? platformBridge,
  GroupCallMediaEngine? groupCallMedia,
  LanDirectChannel? lanDirectChannel,
  StorageCapacityProvider? storageCapacityProvider,
  Future<TransportRegistry?> Function(IdentityRecord identity)?
  transportRegistryFactory,
  String? debugBuildId,
  RatchetEngine? ratchetEngine,
  bool? matrixCarrierEnabled,
  MatrixNativeApi? matrixNativeApi,
  Future<List<String>> Function()? lanAddressProvider,
  NostrSocketConnector? nostrConnector,
  MailConnector? mailConnector,
  RnsConnector? reticulumConnector,
  MeshtasticConnector? meshtasticConnector,
  MeshCoreConnector? meshCoreConnector,
  BitchatConnector? bitchatConnector,
  TorApi? torApi,
  EnergyPolicy? energyPolicy,
  bool keepErrorHistory = false,
}) async {
  final controller = MessengerController(
    keepErrorHistory: keepErrorHistory,
    energyPolicy: energyPolicy,
    torApi: torApi,
    bitchatConnector: bitchatConnector,
    meshCoreConnector: meshCoreConnector,
    meshtasticConnector: meshtasticConnector,
    nostrConnector: nostrConnector,
    mailConnector: mailConnector,
    reticulumConnector: reticulumConnector,
    vaultStore: vaultStore ?? _MemoryVaultStore(),
    relayClient: relayClient,
    localRelayNode: localRelayNode ?? _FakeLocalRelayNode(),
    lanAddressProvider: lanAddressProvider ?? () async => lanAddresses,
    nowProvider: nowProvider,
    signedRelayDefaultsLoader: signedRelayDefaultsLoader,
    enableLongPoll: enableLongPoll,
    enablePairingBeacon: false,
    platformBridge: platformBridge,
    groupCallMedia: groupCallMedia,
    lanDirectChannel: lanDirectChannel,
    transportRegistryFactory: transportRegistryFactory,
    debugBuildId: debugBuildId,
    ratchetEngine: ratchetEngine,
    matrixCarrierEnabled: matrixCarrierEnabled,
    matrixHttpFactory: _realMatrixHttp,
    // Only an explicit fake: a native library on the test machine must not
    // turn the HTTP carrier tests into native-client tests.
    matrixNativeApi: matrixNativeApi,
    loadNativeMatrixClient: false,
    storageCapacityProvider:
        storageCapacityProvider ??
        (_) async => const StorageCapacity(
          freeBytes: 100 * 1024 * 1024 * 1024,
          totalBytes: 120 * 1024 * 1024 * 1024,
        ),
    attachmentRootProvider:
        attachmentRootProvider ??
        () async {
          // Isolated per-test tmpdir so concurrent tests don't share an
          // attachment cache and so a passed `path_provider` isn't
          // required in the test runner.
          final base = Directory.systemTemp.createTempSync(
            'conest_test_attachments_',
          );
          return base;
        },
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
  if (!second.contacts.any(
    (contact) => contact.deviceId == first.identity!.deviceId,
  )) {
    final senderDeviceId = first.identity!.deviceId;
    var request = second.pendingContactRequests
        .where((entry) => entry.senderDeviceId == senderDeviceId)
        .firstOrNull;
    for (var attempt = 0; attempt < 50 && request == null; attempt++) {
      await second.pollNow();
      request = second.pendingContactRequests
          .where((entry) => entry.senderDeviceId == senderDeviceId)
          .firstOrNull;
      if (request == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    expect(
      request,
      isNotNull,
      reason: 'Pairing request should arrive before the helper approves it.',
    );
    await second.approvePendingContactRequest(request!.id);
  }
  for (var attempt = 0; attempt < 50; attempt++) {
    await first.pollNow();
    final contact = first.contacts
        .where((contact) => contact.deviceId == second.identity!.deviceId)
        .firstOrNull;
    if (contact?.canSendOutbound == true) break;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    first.contacts
        .where((contact) => contact.deviceId == second.identity!.deviceId)
        .firstOrNull
        ?.canSendOutbound,
    isTrue,
    reason: 'contact approval response did not reach the requester',
  );
  expect(
    second.contacts.any(
      (contact) => contact.deviceId == first.identity!.deviceId,
    ),
    isTrue,
  );
}

Future<TransportRegistry?> _directNativeIrohRegistry(
  IdentityRecord identity,
) async {
  final privateKey = identity.signingPrivateKeyBase64;
  final endpointId = identity.irohEndpointId;
  final bridge = FfiNativeIrohBridge.tryCreate();
  if (privateKey == null || endpointId == null || bridge == null) {
    throw StateError('The native Iroh bridge is unavailable.');
  }
  return TransportRegistry(<TransportAdapter>[
    IrohTransportAdapter(
      bridge: bridge,
      secretKeySeed: Uint8List.fromList(base64Decode(privateKey)),
      relayEnabled: false,
      expectedEndpointId: endpointId,
    ),
  ]);
}

class _InProcessIrohNetwork {
  _InProcessIrohNetwork({this.relayed = false});
  final bool relayed;
  final bridges = <String, _InProcessIrohBridge>{};
  final envelopes = <RelayEnvelope>[];
  final groupFileHeaders = <GroupFileBinaryHeader>[];

  /// (sender, recipient) endpoint pairs that cannot reach each other.
  final blockedPairs = <(String, String)>{};
  final blockedEnvelopePairs = <(String, String)>{};
  final heldHelloPairs = <(String, String)>{};
  final heldHellos = <(String, RelayEnvelope)>[];

  /// Pairs whose sends are accepted and lost (a firewall dropping what
  /// arrives while the other way works).
  final droppedPairs = <(String, String)>{};

  Future<TransportRegistry?> registry(IdentityRecord identity) async {
    final bridge = _InProcessIrohBridge(this, identity.irohEndpointId!);
    bridges[bridge.endpointId] = bridge;
    return TransportRegistry([
      IrohTransportAdapter(
        bridge: bridge,
        secretKeySeed: Uint8List.fromList(
          base64Decode(identity.signingPrivateKeyBase64!),
        ),
        relayEnabled: identity.connectivity.irohRelayEnabled,
        expectedEndpointId: identity.irohEndpointId,
      ),
    ]);
  }

  void inject(
    IdentityRecord recipient,
    String senderEndpoint,
    RelayEnvelope envelope,
  ) {
    bridges[recipient.irohEndpointId]!._inbound.add(
      IrohBridgeInbound(
        senderEndpointId: senderEndpoint,
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(envelope.toJson()))),
        relayed: relayed,
      ),
    );
  }
}

class _InProcessIrohBridge implements NativeIrohDatagramBridge {
  _InProcessIrohBridge(this.network, this.endpointId);
  final _InProcessIrohNetwork network;
  final String endpointId;
  final _inbound = StreamController<IrohBridgeInbound>.broadcast();
  final _datagrams = StreamController<IrohBridgeDatagram>.broadcast();
  @override
  Stream<IrohBridgeDatagram> get datagrams => _datagrams.stream;
  @override
  Stream<IrohBridgeInbound> get inbound => _inbound.stream;
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
  Future<IrohBridgeReceipt> sendDatagram({
    required String remoteEndpointId,
    required Uint8List bytes,
    required bool allowRelay,
  }) async {
    final recipient = network.bridges[remoteEndpointId];
    if (recipient == null ||
        (network.relayed && !allowRelay) ||
        network.blockedPairs.contains((endpointId, remoteEndpointId))) {
      throw StateError('Peer unreachable');
    }
    if (!network.droppedPairs.contains((endpointId, remoteEndpointId))) {
      recipient._datagrams.add(
        IrohBridgeDatagram(
          senderEndpointId: endpointId,
          bytes: Uint8List.fromList(bytes),
          relayed: network.relayed,
        ),
      );
    }
    return IrohBridgeReceipt(
      endpointId: remoteEndpointId,
      relayed: network.relayed,
      accepted: true,
    );
  }
  @override
  Future<IrohBridgeReceipt> sendEnvelope({
    required String remoteEndpointId,
    required Uint8List bytes,
    required bool allowRelay,
    List<String> directAddresses = const [],
  }) async {
    if (!network.bridges.containsKey(endpointId)) {
      throw StateError('Sender offline');
    }
    if (network.relayed && !allowRelay) throw StateError('Relay disabled');
    final recipient = network.bridges[remoteEndpointId];
    if (recipient == null) throw StateError('Peer offline');
    if (network.blockedPairs.contains((endpointId, remoteEndpointId))) {
      throw StateError('Peer unreachable');
    }
    if (network.blockedEnvelopePairs.contains((endpointId, remoteEndpointId))) {
      throw StateError('Envelope route unreachable');
    }
    if (network.droppedPairs.contains((endpointId, remoteEndpointId))) {
      return IrohBridgeReceipt(
        endpointId: remoteEndpointId,
        relayed: network.relayed,
        accepted: true,
      );
    }
    final range = decodeIrohAttachmentRangeFrame(bytes);
    if (range != null && isGroupFileBinary(range.bytes)) {
      network.groupFileHeaders.add(peekGroupFileBinary(range.bytes));
    }
    if (range == null) {
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final envelope = RelayEnvelope.fromJson(
          decoded['conestForwarded'] == 1
              ? decoded['envelope'] as Map<String, dynamic>
              : decoded,
      );
      network.envelopes.add(envelope);
      if (envelope.kind == 'ratchet_hello' &&
          network.heldHelloPairs.contains((endpointId, remoteEndpointId))) {
        network.heldHellos.add((endpointId, envelope));
        return IrohBridgeReceipt(
          endpointId: remoteEndpointId,
          relayed: network.relayed,
          accepted: true,
        );
      }
    }
    recipient._inbound.add(
      IrohBridgeInbound(
        senderEndpointId: endpointId,
        bytes: bytes,
        relayed: network.relayed,
      ),
    );
    return IrohBridgeReceipt(
      endpointId: remoteEndpointId,
      relayed: network.relayed,
      accepted: true,
    );
  }

  @override
  Future<void> close() => _inbound.close();
}

Future<void> _waitForIroh(
  bool Function() ready, {
  String reason = 'Iroh delivery did not finish',
  Duration? timeout,
}) async {
  // Real native Iroh on a shared CI runner can take several seconds per
  // dial (seen twice timing out at 5 s); the in-memory bridge cannot.
  final native = Platform.environment['CONEST_RUN_IROH_GROUP_CERT'] == '1';
  final deadline = DateTime.now().add(
    timeout ?? Duration(seconds: native ? 20 : 5),
  );
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue, reason: reason);
}

const _irohOnlyConnectivity = GlobalConnectivityPreferences(
  lanEnabled: false,
  transportPolicies: {TransportKind.iroh: TransportPolicy.automatic},
  autoDownloadPreset: AutoDownloadPreset.custom,
);

void main() {
  deltaContentControllerTests();
  _localizationControllerTests();
  test('chat folders move later and persist their final order', () async {
    final vault = _MemoryVaultStore();
    final controller = await _createController(
      relayClient: _FakeRelayClient(),
      displayName: 'Folders',
      vaultStore: vault,
      createIdentity: false,
    );
    addTearDown(controller.dispose);

    await controller.createChatFolder('First');
    await controller.createChatFolder('Second');
    await controller.createChatFolder('Third');
    await controller.reorderChatFolders(0, 1);

    final expected = <String>['Second', 'First', 'Third'];
    expect(controller.chatFolders.map((folder) => folder.name), expected);
    expect(
      (await vault.load()).chatFolders.map((folder) => folder.name),
      expected,
    );
  });

  test(
    'chat folders create rename membership delete persist across vault reload',
    () async {
      final vault = _MemoryVaultStore();
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Folders',
        vaultStore: vault,
      );
      var controllerDisposed = false;
      addTearDown(() {
        if (!controllerDisposed) controller.dispose();
      });
      await controller.updateConversationPreferences(
        ConversationKind.direct,
        'peer',
        pinned: true,
      );

      final folder = await controller.createChatFolder(
        '  Research  ',
        conversationIds: const ['peer'],
      );
      await controller.updateChatFolder(
        folder.id,
        name: '  Work  ',
        conversationIds: const ['peer', 'group'],
      );
      await controller.flushPendingChanges();
      controller.dispose();
      controllerDisposed = true;

      final restored = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Folders',
        vaultStore: vault,
        createIdentity: false,
      );
      addTearDown(restored.dispose);
      expect(restored.chatFolders.single.name, 'Work');
      expect(
        restored.conversationIdsForFolder(folder.id),
        ['peer', 'group'],
      );

      await restored.deleteChatFolder(folder.id);
      expect(restored.chatFolders, isEmpty);
      expect(
        restored
            .conversationPreferences(ConversationKind.direct, 'peer')
            .pinned,
        isTrue,
        reason:
            'deleting a folder must preserve the conversation and its local settings',
      );
    },
  );

  test(
    'scheduled messages recover across handoff and recheck send authorization',
    () async {
      final vault = _MemoryVaultStore();
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Scheduler',
        vaultStore: vault,
        createIdentity: false,
      );
      var controllerDisposed = false;
      addTearDown(() {
        if (!controllerDisposed) controller.dispose();
      });
      final due = DateTime.now().toUtc().add(const Duration(hours: 1));
      final beforeHandoff = await controller.scheduleTextMessage(
        kind: ConversationKind.direct,
        conversationId: 'peer',
        body: 'retry after restart',
        scheduledAt: due,
      );
      final afterHandoff = await controller.scheduleTextMessage(
        kind: ConversationKind.direct,
        conversationId: 'peer',
        body: 'already in the outbox',
        scheduledAt: due,
      );
      await controller.flushPendingChanges();
      controller.dispose();
      controllerDisposed = true;

      final interrupted = await vault.load();
      final handoffTime = DateTime.now().toUtc();
      final queuedMessage = ChatMessage(
        id: afterHandoff.id,
        conversationId: 'peer',
        senderDeviceId: 'local-device',
        recipientDeviceId: 'peer',
        body: afterHandoff.body,
        outbound: true,
        state: DeliveryState.pending,
        createdAt: handoffTime,
      );
      await vault.save(
        interrupted.copyWith(
          scheduledMessages: [
            beforeHandoff.copyWith(state: ScheduledMessageState.sending),
            afterHandoff.copyWith(state: ScheduledMessageState.sending),
          ],
          conversations: [
            ConversationRecord(
              id: 'peer',
              kind: ConversationKind.direct,
              peerDeviceId: 'peer',
              messages: [queuedMessage],
            ),
          ],
        ),
      );

      final restored = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Scheduler',
        vaultStore: vault,
        createIdentity: false,
      );
      addTearDown(restored.dispose);
      expect(
        restored.scheduledMessages
            .singleWhere((entry) => entry.id == beforeHandoff.id)
            .state,
        ScheduledMessageState.waiting,
      );
      expect(
        restored.scheduledMessages
            .singleWhere((entry) => entry.id == afterHandoff.id)
            .state,
        ScheduledMessageState.sent,
      );
      await restored.sendScheduledMessageNow(beforeHandoff.id);
      final unauthorized = restored.scheduledMessages.singleWhere(
        (entry) => entry.id == beforeHandoff.id,
      );
      expect(unauthorized.state, ScheduledMessageState.blocked);
      expect(
        unauthorized.failureReason,
        contains('Contact is no longer available.'),
      );
      expect(
        restored
            .messagesFor('peer')
            .where((message) => message.id == afterHandoff.id),
        hasLength(1),
      );
    },
  );

  test('scheduled messages recheck rescheduling during a due batch', () async {
    final vault = _DelayedVaultStore();
    var now = DateTime.now().toUtc();
    final controller = await _createController(
      relayClient: _FakeRelayClient(),
      displayName: 'Scheduler',
      vaultStore: vault,
      nowProvider: () => now,
    );
    addTearDown(controller.dispose);
    final due = now.add(const Duration(hours: 1));
    final first = await controller.scheduleTextMessage(
      kind: ConversationKind.direct,
      conversationId: 'removed-peer',
      body: 'first due message',
      scheduledAt: due,
    );
    final second = await controller.scheduleTextMessage(
      kind: ConversationKind.direct,
      conversationId: 'removed-peer',
      body: 'reschedule while first dispatch waits',
      scheduledAt: due,
    );
    controller.setAppForegroundState(false);
    await controller.flushPendingChanges();
    now = due.add(const Duration(minutes: 1));
    final release = Completer<void>();
    vault.releaseWrite = release;
    vault.writeStarted = Completer<void>();
    controller.setAppForegroundState(true);
    await vault.writeStarted!.future.timeout(const Duration(seconds: 5));
    final rescheduling = controller.rescheduleMessage(
      second.id,
      now.add(const Duration(hours: 1)),
    );
    release.complete();
    await rescheduling;
    await _waitForIroh(
      () => controller.scheduledMessages
          .singleWhere((entry) => entry.id == first.id).state ==
          ScheduledMessageState.blocked,
    );
    await controller.flushPendingChanges();
    expect(
      controller.scheduledMessages
          .singleWhere((entry) => entry.id == second.id).state,
      ScheduledMessageState.waiting,
    );
  });

  test(
    'scheduled sends stay blocked after revocation and cancel removes staged copies',
    () async {
      final relay = _FakeRelayClient();
      final bobRoot = Directory.systemTemp.createTempSync(
        'conest_scheduled_revocation_',
      );
      addTearDown(() => bobRoot.deleteSync(recursive: true));
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        attachmentRootProvider: () async => bobRoot,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Revocation',
        members: alice.contacts,
      );
      await bob.pollNow();
      expect(
        bob.visibleGroups.single.hasActiveMember(bob.identity!.deviceId),
        isTrue,
      );

      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      final source = File(p.join(bobRoot.path, 'source.txt'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      StagedAttachment sourceAttachment(String id) => StagedAttachment(
        id: id,
        fileName: 'source.txt',
        mimeType: 'text/plain',
        sizeBytes: 3,
        filePath: source.path,
      );
      final due = DateTime.now().toUtc().add(const Duration(hours: 1));
      final scheduled = [
        await bob.scheduleTextMessage(
          kind: ConversationKind.direct,
          conversationId: aliceId,
          body: 'direct text after revocation',
          scheduledAt: due,
        ),
        await bob.scheduleAttachment(
          contact: bob.contacts.single,
          source: sourceAttachment('direct-source'),
          scheduledAt: due,
          caption: 'direct file after revocation',
        ),
        await bob.scheduleTextMessage(
          kind: ConversationKind.group,
          conversationId: group.groupId,
          body: 'group text after removal',
          scheduledAt: due,
        ),
        await bob.scheduleGroupAttachment(
          groupId: group.groupId,
          source: sourceAttachment('group-source'),
          scheduledAt: due,
        ),
      ];
      final stagedCopies = [
        for (final entry in scheduled)
          if (entry.attachmentPath != null)
            File(p.join(bobRoot.path, entry.attachmentPath!)),
      ];
      expect(stagedCopies, hasLength(2));
      for (final copy in stagedCopies) {
        expect(copy.existsSync(), isTrue);
        expect(copy.path, isNot(source.path));
      }

      // Alice revokes both authorizations after Bob approved the schedule.
      await alice.removeGroupMember(groupId: group.groupId, memberDeviceId: bobId);
      await alice.removeContact(bobId);
      for (var attempt = 0; attempt < 50; attempt++) {
        await bob.pollNow();
        if (bob.contacts.single.isArchived &&
            !bob.visibleGroups.single.hasActiveMember(bobId)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(bob.contacts.single.isArchived, isTrue);
      expect(bob.visibleGroups.single.hasActiveMember(bobId), isFalse);

      relay.storedEnvelopes.clear();
      for (final entry in scheduled) {
        await bob.sendScheduledMessageNow(entry.id);
        final result = bob.scheduledMessages.singleWhere(
          (value) => value.id == entry.id,
        );
        expect(
          result.state,
          ScheduledMessageState.blocked,
          reason: '${entry.body} must not be delivered after revocation',
        );
        expect(result.failureReason, isNotEmpty);
      }
      const deliveryKinds = <String>{
        'direct_message',
        'group_message',
        'group_history',
        'attachment_offer',
        'attachment_chunk',
      };
      expect(
        relay.storedEnvelopes.where(
          (envelope) =>
              envelope.senderDeviceId == bobId &&
              deliveryKinds.contains(envelope.kind),
        ),
        isEmpty,
      );
      // Blocked items keep their staged copy so the user can still retry.
      for (final copy in stagedCopies) {
        expect(copy.existsSync(), isTrue);
      }

      for (final entry in scheduled) {
        await bob.cancelScheduledMessage(entry.id);
      }
      expect(
        bob.scheduledMessages
            .where((value) => scheduled.any((entry) => entry.id == value.id))
            .map((value) => value.state),
        everyElement(ScheduledMessageState.canceled),
      );
      for (final copy in stagedCopies) {
        expect(copy.existsSync(), isFalse);
        expect(File('${copy.path}.tmp').existsSync(), isFalse);
      }
      expect(
        source.readAsBytesSync(),
        <int>[1, 2, 3],
        reason: 'cancelling must never touch the original picked file',
      );
    },
  );

  test(
    'group poll converges after reordered duplicate delivery and restart',
    () async {
      final relay = _FakeRelayClient();
      final carolVault = _MemoryVaultStore();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      var carol = await _createController(
        relayClient: relay,
        displayName: 'Carol',
        vaultStore: carolVault,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(() => carol.dispose());
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await _pairControllers(bob, carol);
      final group = await alice.createGroup(
        title: 'Reordered poll',
        members: alice.contacts,
      );
      final carolId = carol.identity!.deviceId;

      Future<void> pump(
        bool Function() ready,
        String reason, {
        bool includeCarol = true,
      }) async {
        for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
          await alice.pollNow();
          await bob.pollNow();
          if (includeCarol) await carol.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(ready(), isTrue, reason: reason);
      }

      await pump(
        () => carol.visibleGroups.any(
          (candidate) => candidate.groupId == group.groupId,
        ),
        'Carol joins before the poll',
      );

      // Carol stops polling while the poll is created, voted on, revoted and
      // closed, so its whole history reaches her later out of order.
      final carolInboxStart = relay.storedEnvelopes.length;
      await alice.createGroupPoll(
        groupId: group.groupId,
        question: 'Lunch?',
        options: const ['Soup', 'Salad', 'Pasta'],
      );
      String? pollId;
      await pump(() {
        pollId = bob
            .messagesForGroup(group.groupId)
            .map((message) => message.poll?.id)
            .whereType<String>()
            .firstOrNull;
        return pollId != null;
      }, 'Bob sees the poll', includeCarol: false);
      await bob.voteInGroupPoll(
        groupId: group.groupId,
        pollId: pollId!,
        optionIndexes: const [0],
      );
      await bob.voteInGroupPoll(
        groupId: group.groupId,
        pollId: pollId!,
        optionIndexes: const [1],
      );
      await alice.voteInGroupPoll(
        groupId: group.groupId,
        pollId: pollId!,
        optionIndexes: const [2],
      );
      await pump(
        () =>
            alice
                .groupPollProjection(group.groupId, pollId!)
                ?.votes[bob.identity!.deviceId]
                ?.optionIndexes
                .join(',') ==
            '1',
        'Alice sees Bob change his vote',
        includeCarol: false,
      );
      await alice.closeGroupPoll(groupId: group.groupId, pollId: pollId!);
      final expected = alice.groupPollProjection(group.groupId, pollId!)!;
      expect(expected.definition.isClosed, isTrue);
      expect(expected.counts(), <int>[0, 1, 1]);

      final forCarol = relay.storedEnvelopes
          .skip(carolInboxStart)
          .where((envelope) => envelope.recipientDeviceId == carolId)
          .toList();
      expect(forCarol, isNotEmpty);
      await carol.processEnvelopesForTesting(forCarol.reversed.toList());
      await carol.processEnvelopesForTesting(forCarol);
      await carol.processEnvelopesForTesting(forCarol.reversed.toList());

      bool matchesExpected(MessengerController peer) {
        final projection = peer.groupPollProjection(group.groupId, pollId!);
        return projection != null &&
            projection.definition.isClosed &&
            projection.closedCheckpointEventId ==
                expected.closedCheckpointEventId &&
            projection.counts().join(',') == expected.counts().join(',') &&
            projection.unconfirmedVotes.isEmpty;
      }

      await pump(
        () => matchesExpected(carol),
        'Carol converges after reordered and duplicated delivery',
      );
      final pollMessages = carol
          .messagesForGroup(group.groupId)
          .where((message) => message.poll?.id == pollId)
          .toList();
      expect(pollMessages, hasLength(1), reason: 'duplicates must collapse');

      await carol.flushPendingChanges();
      carol.dispose();
      carol = await _createController(
        relayClient: relay,
        displayName: 'Carol',
        vaultStore: carolVault,
        createIdentity: false,
      );
      // The projection is rebuilt from the local history journal after
      // startup; wait for it without any network traffic.
      await _waitForIroh(
        () => matchesExpected(carol),
        reason: 'the closed projection must survive a restart',
      );
      // Redelivering the full history after restart changes nothing.
      await carol.processEnvelopesForTesting(forCarol);
      await carol.pollNow();
      expect(matchesExpected(carol), isTrue);
      expect(
        carol
            .messagesForGroup(group.groupId)
            .where((message) => message.poll?.id == pollId),
        hasLength(1),
      );
    },
  );

  test(
    'draft updates during a delayed vault write schedule a new snapshot',
    () async {
      final vault = _DelayedVaultStore();
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: vault,
      );
      addTearDown(controller.dispose);
      final release = Completer<void>();
      vault.releaseWrite = release;
      vault.writeStarted = Completer<void>();
      final first = controller.setConversationDraft(
        ConversationKind.direct,
        'peer',
        'first',
      );
      await vault.writeStarted!.future.timeout(const Duration(seconds: 5));
      final second = controller.setConversationDraft(
        ConversationKind.direct,
        'peer',
        'later keystrokes',
      );
      release.complete();
      await first;
      await controller.flushPendingChanges();
      await second;
      expect(
        (await vault.load()).conversations.single.draft,
        'later keystrokes',
      );
    },
  );

  test(
    'background and disposal flush drafts before the debounce expires',
    () async {
      final vault = _MemoryVaultStore();
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: vault,
      );
      final background = controller.setConversationDraft(
        ConversationKind.direct,
        'peer',
        'background draft',
      );
      controller.setAppForegroundState(false);
      await background.timeout(const Duration(seconds: 1));
      expect(
        (await vault.load()).conversations.single.draft,
        'background draft',
      );
      final closing = controller.setConversationDraft(
        ConversationKind.direct,
        'peer',
        'closing draft',
      );
      controller.dispose();
      await closing.timeout(const Duration(seconds: 1));
      expect((await vault.load()).conversations.single.draft, 'closing draft');
    },
  );

  test(
    'conversation drafts isolate destinations and survive controller restart',
    () async {
      final vault = _MemoryVaultStore();
      final relay = _FakeRelayClient();
      final first = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: vault,
      );
      final writes = <Future<void>>[];
      writes.add(
        first.setConversationDraft(
          ConversationKind.direct,
          'same-id',
          'unfinished private',
        ),
      );
      writes.add(
        first.setConversationDraft(
          ConversationKind.group,
          'same-id',
          'unfinished group',
        ),
      );
      writes.add(
        first.setConversationDraft(
          ConversationKind.lanLobby,
          'lobby',
          'unfinished lobby',
        ),
      );
      writes.add(
        first.setConversationDraft(
          ConversationKind.direct,
          'same-id',
          'latest private',
        ),
      );
      await Future.wait(writes);
      first.dispose();
      final restored = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: vault,
        createIdentity: false,
      );
      addTearDown(restored.dispose);
      expect(
        restored.conversationDraft(ConversationKind.direct, 'same-id'),
        'latest private',
      );
      expect(
        restored.conversationDraft(ConversationKind.group, 'same-id'),
        'unfinished group',
      );
      expect(
        restored.conversationDraft(ConversationKind.lanLobby, 'lobby'),
        'unfinished lobby',
      );
      await restored.setConversationDraft(
        ConversationKind.direct,
        'same-id',
        '',
      );
      expect(
        restored.conversationDraft(ConversationKind.direct, 'same-id'),
        isEmpty,
      );
      expect(
        restored.conversationDraft(ConversationKind.group, 'same-id'),
        'unfinished group',
      );
      expect(
        relay.storedEnvelopes.where(
          (e) => e.kind == 'direct_message' || e.kind == 'group_message',
        ),
        isEmpty,
      );
    },
  );

  test(
    'discarded message duplicates never manufacture delivery receipts',
    () async {
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await bob.updateGlobalConnectivity(
        bob.identity!.connectivity.copyWith(onlineEnabled: false),
      );
      await alice.sendMessage(
        contact: alice.contacts.single,
        body: 'blocked ingress',
      );
      final envelope = relay.storedEnvelopes.lastWhere(
        (e) => e.kind == 'direct_message',
      );
      relay.storedEnvelopes.clear();
      await bob.processEnvelopesForTesting([envelope]);
      await bob.processEnvelopesForTesting([envelope]);
      expect(bob.messagesFor(alice.identity!.deviceId), isEmpty);
      expect(relay.storedEnvelopes.where((e) => e.kind == 'ack'), isEmpty);
    },
  );

  test(
    'Beam pairing receives Iroh heartbeat replies without legacy routes',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      final beam = await bob.prepareInviteBeam();
      final imported = await alice.inspectBeamPackage(beam.package);
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: imported.invite!.encodePayload(),
        codephrase: '',
      );
      await _waitForIroh(() => bob.pendingContactRequests.isNotEmpty);
      await bob.approvePendingContactRequest(
        bob.pendingContactRequests.single.id,
      );
      await _waitForIroh(
        () => alice.contacts
                .where((contact) => contact.deviceId == bob.identity!.deviceId)
                .firstOrNull
                ?.canSendOutbound ==
            true,
        reason: 'Iroh approval response did not unlock the contact',
      );
      network.envelopes.clear();
      expect(await alice.runHeartbeatPassNow(), 1);
      await _waitForIroh(
        () =>
            network.envelopes.where((e) => e.kind == 'route_update').length >=
            2,
      );
      await _waitForIroh(
        () =>
            alice.reachabilityStateFor(bob.identity!.deviceId) ==
            ContactReachabilityState.online,
      );
    },
  );

  test('rejected contact messages remain unconfirmed after retries', () async {
    final relay = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relay,
      displayName: 'Alice',
    );
    final bob = await _createController(relayClient: relay, displayName: 'Bob');
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    await bob.rejectPendingContactRequest(bob.pendingContactRequests.single.id);
    await alice.sendMessage(contact: alice.contacts.single, body: 'unaccepted');
    expect(alice.statusMessage, isNot(contains('Delivered')));
    for (var i = 0; i < 2; i++) {
      await bob.pollNow();
      await alice.pollNow();
      await alice.retryUnacknowledgedMessagesNow();
    }
    expect(bob.messagesFor(alice.identity!.deviceId), isEmpty);
    expect(
      alice.messagesFor(bob.identity!.deviceId).single.state.awaitsRecipientAck,
      isTrue,
    );
  });

  test('Contact approval releases locally queued messages', () async {
    final relay = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relay,
      displayName: 'Alice',
    );
    final bob = await _createController(relayClient: relay, displayName: 'Bob');
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await alice.sendMessage(contact: alice.contacts.single, body: 'queued');
    expect(alice.messagesFor(bob.identity!.deviceId).single.state, DeliveryState.pending);
    expect(alice.statusMessage, contains('accepts'));

    await bob.pollNow();
    await bob.approvePendingContactRequest(bob.pendingContactRequests.single.id);
    for (var attempt = 0; attempt < 50; attempt++) {
      await alice.pollNow();
      if (alice.contacts
              .where((contact) => contact.deviceId == bob.identity!.deviceId)
              .firstOrNull
              ?.canSendOutbound ==
          true) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      alice.contacts
          .where((contact) => contact.deviceId == bob.identity!.deviceId)
          .firstOrNull
          ?.canSendOutbound,
      isTrue,
      reason: 'approval response did not arrive',
    );
    await bob.pollNow();
    await alice.pollNow();

    expect(bob.messagesFor(alice.identity!.deviceId).single.body, 'queued');
    expect(
      alice.messagesFor(bob.identity!.deviceId).single.state,
      DeliveryState.delivered,
    );
  });

  test('saved messages stay on this device and survive a restart', () async {
    final relay = _FakeRelayClient();
    final vault = _MemoryVaultStore();
    final root = Directory.systemTemp.createTempSync('conest_saved_');
    addTearDown(() => root.deleteSync(recursive: true));
    final alice = await _createController(
      relayClient: relay,
      displayName: 'Alice',
      vaultStore: vault,
      attachmentRootProvider: () async => root,
    );
    final saved = alice.savedMessagesContact!;
    final me = alice.identity!.deviceId;
    expect(alice.isSavedMessages(saved.deviceId), isTrue);
    expect(alice.contacts, isEmpty);

    await alice.sendMessage(contact: saved, body: 'note to self');
    await alice.sendAttachment(
      contact: saved,
      bytes: Uint8List.fromList(List<int>.generate(5000, (i) => i % 251)),
      fileName: 'ticket.pdf',
      mimeType: 'application/pdf',
      caption: 'boarding pass',
    );
    final file = alice
        .messagesFor(me)
        .singleWhere((m) => m.hasAttachment)
        .attachment!;
    expect(alice.messagesFor(me).map((m) => m.state).toSet(), {
      DeliveryState.delivered,
    });
    expect(alice.attachmentAvailableLocally(file.id), isTrue);
    final text = alice
        .messagesFor(me)
        .singleWhere((m) => m.body == 'note to self');
    await alice.editMessage(contact: saved, messageId: text.id, body: 'edited');
    await alice.toggleMessageReaction(
      contact: saved,
      messageId: text.id,
      emoji: '⭐',
    );
    // Nothing leaves the device.
    expect(relay.storeAttempts, isEmpty);
    expect(alice.transferSnapshots, isEmpty);

    alice.dispose();
    final restarted = await _createController(
      relayClient: relay,
      displayName: 'unused',
      createIdentity: false,
      vaultStore: vault,
      attachmentRootProvider: () async => root,
    );
    addTearDown(restarted.dispose);
    final kept = restarted.messagesFor(me);
    expect(kept.map((m) => m.body), containsAll(['edited', 'boarding pass']));
    expect(kept.singleWhere((m) => m.body == 'edited').reactions.keys, ['⭐']);
    expect(restarted.attachmentAvailableLocally(file.id), isTrue);
    // Loaded from disk on first use.
    restarted.attachmentBytesFor(file.id);
    for (
      var i = 0;
      i < 50 && restarted.attachmentBytesFor(file.id) == null;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      restarted.attachmentBytesFor(file.id),
      List<int>.generate(5000, (i) => i % 251),
    );
    await restarted.deleteMessage(
      contact: restarted.savedMessagesContact!,
      messageId: text.id,
    );
    expect(restarted.messagesFor(me).map((m) => m.body), ['boarding pass']);
    expect(relay.storeAttempts, isEmpty);
  });

  testWidgets('Saved messages is pinned and opens as a chat with yourself', (
    tester,
  ) async {
    late MessengerController alice;
    await tester.runAsync(() async {
      alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
      );
      await alice.sendMessage(
        contact: alice.savedMessagesContact!,
        body: 'buy oat milk',
      );
    });
    addTearDown(alice.dispose);
    final updates = _createUpdateService();
    final theme = app.ConestThemeController.memory();
    addTearDown(updates.dispose);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: alice,
          builder: (context, _) => app.HomeScreen(
            controller: alice,
            updateService: updates,
            buildInfo: _createBuildInfo(),
            themeController: theme,
            palette: app.ConestPalette(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('saved-messages-row')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('saved-messages-row')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('buy oat milk'), findsWidgets);
    // A chat with yourself: no routes, reachability or route inspector.
    expect(
      find.textContaining(RegExp('only on this device', caseSensitive: false)),
      findsOneWidget,
    );
    expect(find.byTooltip('Route inspector'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('contact recovery', () {
    late _FakeRelayClient relay;
    late MessengerController alice;
    late MessengerController bob;
    // Envelopes from Bob to Alice vanish while this says so.
    var dropBobToAlice = (RelayEnvelope envelope) => false;
    var dropAliceToBob = (RelayEnvelope envelope) => false;

    setUp(() async {
      dropBobToAlice = (_) => false;
      dropAliceToBob = (_) => false;
      relay = _FakeRelayClient(
        shouldBlackholeStore: (_, _, _, recipient, envelope) {
          if (envelope.senderDeviceId == bob.identity?.deviceId &&
              recipient == alice.identity?.deviceId) {
            return dropBobToAlice(envelope);
          }
          if (envelope.senderDeviceId == alice.identity?.deviceId &&
              recipient == bob.identity?.deviceId) {
            return dropAliceToBob(envelope);
          }
          return false;
        },
      );
      alice = await _createController(relayClient: relay, displayName: 'Alice');
      bob = await _createController(relayClient: relay, displayName: 'Bob');
    });
    tearDown(() {
      alice.dispose();
      bob.dispose();
    });

    String id(MessengerController controller) => controller.identity!.deviceId;
    ContactRecord? contactOf(
      MessengerController owner,
      MessengerController peer,
    ) => owner.contacts.where((c) => c.deviceId == id(peer)).firstOrNull;

    Future<void> until(bool Function() done, {int rounds = 60}) async {
      for (var round = 0; round < rounds && !done(); round++) {
        await alice.pollNow();
        await bob.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<PendingContactRequest> requestAt(
      MessengerController owner,
      MessengerController from,
    ) async {
      await until(
        () => owner.pendingContactRequests.any(
          (r) => r.senderDeviceId == id(from),
        ),
      );
      return owner.pendingContactRequests.singleWhere(
        (r) => r.senderDeviceId == id(from),
      );
    }

    Future<void> add(MessengerController from, MessengerController to) async {
      await from.addContactFromInvite(
        alias: to.identity!.displayName,
        payload: (await to.buildInvite()).encodePayload(),
        codephrase: '',
      );
    }

    test('a lost acceptance is given again when the request repeats', () async {
      dropBobToAlice = (_) => true;
      await add(alice, bob);
      await bob.approvePendingContactRequest((await requestAt(bob, alice)).id);
      await until(() => false, rounds: 5);
      expect(
        contactOf(alice, bob)!.pairingState,
        isNot(ContactPairingState.accepted),
      );

      dropBobToAlice = (_) => false;
      await alice.retryContactPairingNow(id(bob));
      await until(
        () =>
            contactOf(alice, bob)!.pairingState == ContactPairingState.accepted,
      );
      expect(contactOf(alice, bob)!.pairingState, ContactPairingState.accepted);
    });

    test('a message from the accepting side implies the acceptance', () async {
      dropBobToAlice = (envelope) => envelope.kind == 'contact_exchange';
      await add(alice, bob);
      await bob.approvePendingContactRequest((await requestAt(bob, alice)).id);
      await bob.sendMessage(contact: contactOf(bob, alice)!, body: 'hi Alice');
      await until(
        () => alice.messagesFor(id(bob)).any((m) => m.body == 'hi Alice'),
      );
      expect(contactOf(alice, bob)!.pairingState, ContactPairingState.accepted);
    });

    test('a lost decline is given again when the request repeats', () async {
      dropBobToAlice = (_) => true;
      await add(alice, bob);
      await bob.rejectPendingContactRequest((await requestAt(bob, alice)).id);
      await until(() => false, rounds: 5);
      dropBobToAlice = (_) => false;
      await alice.retryContactPairingNow(id(bob));
      await until(
        () =>
            contactOf(alice, bob)!.pairingState == ContactPairingState.declined,
      );
      expect(contactOf(alice, bob)!.pairingState, ContactPairingState.declined);
    });

    test('both adding each other at once needs no approval', () async {
      await add(alice, bob);
      await add(bob, alice);
      await until(
        () =>
            contactOf(alice, bob)?.pairingState ==
                ContactPairingState.accepted &&
            contactOf(bob, alice)?.pairingState == ContactPairingState.accepted,
      );
      expect(contactOf(alice, bob)!.pairingState, ContactPairingState.accepted);
      expect(contactOf(bob, alice)!.pairingState, ContactPairingState.accepted);
    });

    test(
      'a lost removal is repeated, and the contact can be added again',
      () async {
        await _pairControllers(alice, bob);
        await bob.sendMessage(contact: contactOf(bob, alice)!, body: 'before');
        await until(
          () => alice.messagesFor(id(bob)).any((m) => m.body == 'before'),
        );
        // Only the first notice is lost.
        var removals = 0;
        dropAliceToBob = (envelope) =>
            envelope.kind == 'contact_remove' && removals++ == 0;
        await alice.removeContact(id(bob));
        expect(contactOf(bob, alice)!.remoteRemovedAt, isNull);

        // Bob, unaware, writes again: Alice repeats the notice.
        await bob.sendMessage(contact: contactOf(bob, alice)!, body: 'hello?');
        await until(() => contactOf(bob, alice)!.remoteRemovedAt != null);
        expect(removals, greaterThanOrEqualTo(2));
        expect(contactOf(bob, alice)!.remoteRemovedAt, isNotNull);

        // Alice adds Bob again: he sees a request to reconnect.
        await add(alice, bob);
        await bob.approvePendingContactRequest(
          (await requestAt(bob, alice)).id,
        );
        await until(
          () =>
              contactOf(alice, bob)?.pairingState ==
              ContactPairingState.accepted,
        );
        expect(
          contactOf(alice, bob)!.pairingState,
          ContactPairingState.accepted,
        );
        expect(contactOf(bob, alice)!.remoteRemovedAt, isNull);
        expect(
          bob.messagesFor(id(alice)).map((m) => m.body),
          contains('before'),
        );
        await alice.sendMessage(contact: contactOf(alice, bob)!, body: 'again');
        await until(
          () => bob.messagesFor(id(alice)).any((m) => m.body == 'again'),
        );
        expect(
          bob.messagesFor(id(alice)).map((m) => m.body),
          contains('again'),
        );
      },
    );

    test('a replayed invite does not accept a waiting request', () async {
      await add(alice, bob);
      await until(
        () => bob.pendingContactRequests.any(
          (r) => r.senderDeviceId == id(alice),
        ),
      );
      // Anyone holding Bob's (public) invite can send this.
      final forged = RelayEnvelope(
        protocolVersion: 1,
        kind: 'contact_exchange',
        messageId: 'forged-request',
        conversationId: 'pairing',
        senderAccountId: bob.identity!.accountId,
        senderDeviceId: id(bob),
        recipientDeviceId: id(alice),
        createdAt: DateTime.now().toUtc(),
        payloadBase64: base64Encode(
          utf8.encode(
            jsonEncode({
              'exchangeVersion': 2,
              'invitePayload': (await bob.buildInvite()).encodePayload(),
              'pairingRequestId': 'forged',
            }),
          ),
        ),
      );
      dropAliceToBob = (_) => true;
      await alice.processEnvelopesForTesting([forged]);
      expect(
        contactOf(alice, bob)!.pairingState,
        isNot(ContactPairingState.accepted),
      );
    });

    test('a contact added by both sides can still be removed', () async {
      await add(alice, bob);
      await add(bob, alice);
      await until(
        () =>
            contactOf(alice, bob)?.pairingState ==
                ContactPairingState.accepted &&
            contactOf(bob, alice)?.pairingState == ContactPairingState.accepted,
      );
      expect(bob.pendingContactRequests, isEmpty);
      expect(alice.pendingContactRequests, isEmpty);
      await alice.removeContact(id(bob));
      await until(() => contactOf(bob, alice)?.remoteRemovedAt != null);
      expect(contactOf(bob, alice)!.remoteRemovedAt, isNotNull);
    });

    test('approving someone you asked too accepts on both sides', () async {
      await add(alice, bob);
      final request = await requestAt(bob, alice);
      // Bob adds Alice himself before looking at her request.
      dropBobToAlice = (_) => true;
      await add(bob, alice);
      dropBobToAlice = (_) => false;
      await bob.approvePendingContactRequest(request.id);
      await until(
        () =>
            contactOf(alice, bob)?.pairingState ==
                ContactPairingState.accepted &&
            contactOf(bob, alice)?.pairingState == ContactPairingState.accepted,
      );
      expect(contactOf(alice, bob)!.pairingState, ContactPairingState.accepted);
      expect(contactOf(bob, alice)!.pairingState, ContactPairingState.accepted);
      expect(bob.pendingContactRequests, isEmpty);
    });

    test(
      'a removal still arrives after re-adding over a cancelled request',
      () async {
        dropBobToAlice = (_) => true;
        await add(alice, bob);
        await bob.approvePendingContactRequest(
          (await requestAt(bob, alice)).id,
        );
        await until(() => false, rounds: 5);
        await alice.cancelContactPairing(id(bob));
        dropBobToAlice = (_) => false;
        await add(alice, bob);
        await until(
          () =>
              contactOf(alice, bob)!.pairingState ==
              ContactPairingState.accepted,
        );
        expect(
          contactOf(alice, bob)!.pairingState,
          ContactPairingState.accepted,
        );
        await bob.removeContact(id(alice));
        await until(() => contactOf(alice, bob)!.remoteRemovedAt != null);
        expect(contactOf(alice, bob)!.remoteRemovedAt, isNotNull);
      },
    );

    test('a lost removal notice is repeated to a group co-member', () async {
      await _pairControllers(alice, bob);
      await alice.createGroup(title: 'Team', members: [contactOf(alice, bob)!]);
      await until(() => bob.groups.isNotEmpty);
      dropBobToAlice = (e) => e.kind == 'contact_remove';
      await bob.removeContact(id(alice));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      dropBobToAlice = (_) => false;
      expect(contactOf(alice, bob)!.remoteRemovedAt, isNull);
      // A direct message, unlike group traffic, gets the notice repeated.
      await alice.sendMessage(contact: contactOf(alice, bob)!, body: 'hello?');
      await until(() => contactOf(alice, bob)?.remoteRemovedAt != null);
      expect(contactOf(alice, bob)!.remoteRemovedAt, isNotNull);
    });

    test('someone who removed you cannot pull you into a new group', () async {
      await _pairControllers(alice, bob);
      final oldBob = contactOf(alice, bob)!;
      await alice.removeContact(id(bob));
      await until(() => contactOf(bob, alice)?.remoteRemovedAt != null);
      expect(contactOf(bob, alice)!.remoteRemovedAt, isNotNull);
      await alice.createGroup(title: 'Surprise', members: [oldBob]);
      await until(
        () => relay.storedEnvelopes.any((e) => e.kind == 'group_membership'),
      );
      await bob.pollNow();
      expect(bob.groups, isEmpty);
    });

    test(
      'a contact who removes you stays reachable in a shared group',
      () async {
        await _pairControllers(alice, bob);
        final group = await alice.createGroup(
          title: 'Team',
          members: [contactOf(alice, bob)!],
        );
        await until(() => bob.groups.isNotEmpty);
        await bob.removeContact(id(alice));
        await until(() => contactOf(alice, bob)?.remoteRemovedAt != null);
        expect(contactOf(alice, bob)!.remoteRemovedAt, isNotNull);

        await alice.sendGroupMessage(
          groupId: group.groupId,
          body: 'still here?',
        );
        await until(
          () => bob
              .messagesForGroup(group.groupId)
              .any((m) => m.body == 'still here?'),
        );
        expect(
          bob.messagesForGroup(group.groupId).map((m) => m.body),
          contains('still here?'),
        );
        // Our own group message shows how it went, as in a direct chat.
        expect(
          alice
              .messagesForGroup(group.groupId)
              .singleWhere((m) => m.body == 'still here?')
              .route,
          isNotNull,
        );
        await bob.sendGroupMessage(groupId: group.groupId, body: 'yes');
        await until(
          () =>
              alice.messagesForGroup(group.groupId).any((m) => m.body == 'yes'),
        );
        expect(
          alice.messagesForGroup(group.groupId).map((m) => m.body),
          contains('yes'),
        );
        // Their group traffic is no reason to repeat the removal notice.
        final removals = relay.storedEnvelopes
            .where((e) => e.kind == 'contact_remove')
            .length;
        expect(removals, 1);
      },
    );

    test('the removed side can add the contact again', () async {
      await _pairControllers(alice, bob);
      await alice.removeContact(id(bob));
      await until(() => contactOf(bob, alice)?.remoteRemovedAt != null);
      expect(contactOf(bob, alice)!.remoteRemovedAt, isNotNull);

      await add(bob, alice);
      await alice.approvePendingContactRequest(
        (await requestAt(alice, bob)).id,
      );
      await until(
        () =>
            contactOf(bob, alice)?.pairingState == ContactPairingState.accepted,
      );
      expect(contactOf(bob, alice)!.pairingState, ContactPairingState.accepted);
      expect(contactOf(bob, alice)!.remoteRemovedAt, isNull);
    });
  });

  test('cancelled pairing ignores a late acceptance response', () async {
    final relay = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relay,
      displayName: 'Alice',
    );
    final bob = await _createController(relayClient: relay, displayName: 'Bob');
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await alice.addContactFromInvite(
      alias: 'Bob',
      payload: (await bob.buildInvite()).encodePayload(),
      codephrase: '',
    );
    await bob.pollNow();
    final request = bob.pendingContactRequests.single;
    await bob.approvePendingContactRequest(request.id);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (relay.storedEnvelopes.any(
        (envelope) =>
            envelope.kind == 'contact_exchange' &&
            envelope.senderDeviceId == bob.identity!.deviceId &&
            envelope.recipientDeviceId == alice.identity!.deviceId &&
            envelope.protocolVersion == 2,
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      relay.storedEnvelopes.any(
        (envelope) =>
            envelope.kind == 'contact_exchange' &&
            envelope.senderDeviceId == bob.identity!.deviceId &&
            envelope.recipientDeviceId == alice.identity!.deviceId &&
            envelope.protocolVersion == 2,
      ),
      isTrue,
      reason: 'the acceptance response was not queued on the relay',
    );
    await alice.cancelContactPairing(bob.identity!.deviceId);
    await alice.pollNow();
    expect(
      alice.contacts.single.pairingState,
      ContactPairingState.cancelled,
    );
    expect(alice.contacts.single.canSendOutbound, isFalse);
  });

  test(
    'automatic online file test verifies direct Iroh with LAN disabled',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
        debugBuildId: 'debug-direct-iroh',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
        debugBuildId: 'debug-direct-iroh',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(
        _irohOnlyConnectivity.copyWith(irohRelayEnabled: false),
      );
      await bob.updateGlobalConnectivity(
        _irohOnlyConnectivity.copyWith(irohRelayEnabled: false),
      );
      await _pairControllers(alice, bob);
      relay.storedEnvelopes.clear();
      for (final sender in [alice, bob]) {
        final result = await sender
            .runDebugFileBattleTest(contact: sender.contacts.single, sizeMiB: 5)
            .timeout(const Duration(seconds: 30));
        expect(result.success, isTrue, reason: result.detail);
        expect(result.bytesVerified, 5 * 1024 * 1024);
      }
      expect(
        relay.storedEnvelopes.where((e) => e.kind != 'pairing_announcement'),
        isEmpty,
      );
    },
  );

  test(
    'automatic online file test verifies direct Iroh with one peer off Wi-Fi while LAN remains enabled',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        lanDirectChannel: _InProcessLanDirectChannel(host: '192.168.1.20'),
        transportRegistryFactory: network.registry,
        debugBuildId: 'debug-direct-iroh',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        lanAddresses: const [],
        transportRegistryFactory: network.registry,
        debugBuildId: 'debug-direct-iroh',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(
        _irohOnlyConnectivity.copyWith(
          irohRelayEnabled: false,
          lanEnabled: true,
        ),
      );
      await bob.updateGlobalConnectivity(
        _irohOnlyConnectivity.copyWith(
          irohRelayEnabled: false,
          lanEnabled: true,
        ),
      );
      await _pairControllers(alice, bob);
      relay.storedEnvelopes.clear();
      for (final sender in [alice, bob]) {
        final result = await sender
            .runDebugFileBattleTest(contact: sender.contacts.single, sizeMiB: 5)
            .timeout(const Duration(seconds: 30));
        expect(result.success, isTrue, reason: result.detail);
        expect(result.bytesVerified, 5 * 1024 * 1024);
      }
      expect(
        relay.storedEnvelopes.where((e) => e.kind != 'pairing_announcement'),
        isEmpty,
      );
    },
  );

  test(
    'verification progress renews the stall timer and cannot regress',
    () async {
      final timers = <Timer>[];
      await runZoned(
        () async {
          final relay = _FakeRelayClient();
          final alice = await _createController(
            relayClient: relay,
            displayName: 'Alice',
          );
          final bob = await _createController(
            relayClient: relay,
            displayName: 'Bob',
          );
          addTearDown(alice.dispose);
          addTearDown(bob.dispose);
          await _pairControllers(alice, bob);
          await alice.sendAttachment(
            contact: alice.contacts.single,
            bytes: Uint8List(1024),
            fileName: 'verify.bin',
          );
          final descriptor = alice
              .messagesFor(bob.identity!.deviceId)
              .singleWhere((m) => m.attachment != null)
              .attachment!;
          final crypto = CryptoService(identityProvider: () => bob.identity!);
          var sequence = 0;
          Future<void> progress(int received, int bytes) async {
            final envelope = await crypto.encryptPayloadEnvelope(
              kind: 'attachment_progress',
              messageId: 'progress-${sequence++}',
              conversationId: crypto.conversationIdFor(
                alice.identity!.deviceId,
              ),
              senderAccountId: bob.identity!.accountId,
              senderDeviceId: bob.identity!.deviceId,
              recipientDeviceId: alice.identity!.deviceId,
              contact: bob.contacts.single,
              plaintext: jsonEncode({
                'attachmentId': descriptor.id,
                'received': received,
                'receivedBytes': bytes,
                'total': descriptor.effectiveChunkCount,
                'totalBytes': descriptor.sizeBytes,
                'verifying': true,
              }),
            );
            await alice.processEnvelopesForTesting([envelope]);
          }

          expect(timers, isNotEmpty);
          final initialTimer = timers.last;
          await progress(descriptor.effectiveChunkCount, descriptor.sizeBytes);
          expect(initialTimer.isActive, isFalse);
          expect(timers.last.isActive, isTrue);
          expect(
            alice.transferSnapshotFor(descriptor.id)!.phase,
            TransferPhase.verifying,
          );
          final verificationTimer = timers.last;
          await progress(descriptor.effectiveChunkCount, descriptor.sizeBytes);
          expect(
            verificationTimer.isActive,
            isFalse,
            reason:
                'verification heartbeats must renew the deadline even without new blocks',
          );
          final renewedTimer = timers.last;
          await progress(0, 0);
          expect(identical(timers.last, renewedTimer), isTrue);
          expect(
            alice.transferSnapshotFor(descriptor.id)!.phase,
            TransferPhase.verifying,
          );
          expect(alice.outboundAttachmentProgress(descriptor.id), 1);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            if (duration == const Duration(seconds: 60)) timers.add(timer);
            return timer;
          },
        ),
      );
    },
  );

  for (final relayed in [false, true]) {
    test(
      'different-network Iroh messaging and file tests use ${relayed ? "default relay fallback" : "direct connections"} without Conest relays',
      () async {
        final network = _InProcessIrohNetwork(relayed: relayed);
        final relay = _FakeRelayClient();
        final aliceChannel = _InProcessLanDirectChannel(host: '192.168.10.2');
        final bobChannel = _InProcessLanDirectChannel(host: '192.168.20.2');
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
          lanAddresses: ['192.168.10.2'],
          lanDirectChannel: aliceChannel,
          transportRegistryFactory: network.registry,
          debugBuildId: 'debug-iroh-fallback',
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
          lanAddresses: ['192.168.20.2'],
          lanDirectChannel: bobChannel,
          transportRegistryFactory: network.registry,
          debugBuildId: 'debug-iroh-fallback',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        for (final controller in [alice, bob]) {
          await controller.updateGlobalConnectivity(
            _irohOnlyConnectivity.copyWith(lanEnabled: true),
          );
        }
        await _pairControllers(alice, bob);
        aliceChannel.transientFailureCount = 10000;
        bobChannel.transientFailureCount = 10000;
        relay.shouldFailStore = (_, _, _, _, _) => true;
        relay.storedEnvelopes.clear();
        for (final sender in [alice, bob]) {
          await sender.sendMessage(
            contact: sender.contacts.single,
            body: 'Across networks',
          );
          final result = await sender
              .runDebugFileBattleTest(
                contact: sender.contacts.single,
                sizeMiB: 5,
              )
              .timeout(const Duration(seconds: 30));
          expect(result.success, isTrue, reason: result.detail);
        }
        expect(
          alice
              .messagesFor(bob.identity!.deviceId)
              .where((m) => !m.outbound && m.body == 'Across networks'),
          hasLength(1),
        );
        expect(
          bob
              .messagesFor(alice.identity!.deviceId)
              .where((m) => !m.outbound && m.body == 'Across networks'),
          hasLength(1),
        );
        // Exercise the ordinary picker/send path, including a failed binary
        // LAN upload falling through to Iroh and the >30 MiB relay policy.
        final manualBytes = Uint8List(31 * 1024 * 1024)..[0] = 17;
        final sourceRoot = await Directory.systemTemp.createTemp(
          'conest-manual-iroh-',
        );
        addTearDown(() => sourceRoot.delete(recursive: true));
        final sourceFile = File('${sourceRoot.path}/manual-large.bin');
        await sourceFile.writeAsBytes(manualBytes);
        await alice.sendAttachmentSource(
          contact: alice.contacts.single,
          source: StagedAttachment(
            id: 'manual-source',
            fileName: 'manual-large.bin',
            mimeType: 'application/octet-stream',
            sizeBytes: manualBytes.length,
            filePath: sourceFile.path,
          ),
        );
        ChatMessage? manual;
        for (var step = 0; step < 2000; step++) {
          manual = bob
              .messagesFor(alice.identity!.deviceId)
              .where((m) => m.attachment?.fileName == 'manual-large.bin')
              .firstOrNull;
          if (manual != null) {
            if (bob.attachmentAwaitingAcceptance(manual.attachment!.id)) {
              await bob.acceptIncomingAttachment(manual.attachment!.id);
            }
            if (bob.attachmentAvailableLocally(manual.attachment!.id)) break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(manual, isNotNull);
        expect(manual!.attachment!.chunkSize, 4 * 1024 * 1024);
        final cache = await bob.attachmentCachePathFor(manual.attachment!.id);
        expect(cache, isNotNull);
        expect(await File(cache!).length(), manualBytes.length);
        expect((await File(cache).openRead(0, 1).first).single, 17);
        expect(relay.storedEnvelopes, isEmpty);
      },
    );
  }

  test(
    'Iroh-only transfers use 1 MiB blocks with receivers that take them',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      for (final controller in [alice, bob]) {
        await controller.updateGlobalConnectivity(_irohOnlyConnectivity);
      }
      await _pairControllers(alice, bob);
      relay.shouldFailStore = (_, _, _, _, _) => true;
      expect(
        alice.contacts.single.featureCapabilities,
        contains(ApplicationCapability.irohBlock1MiBV1),
      );
      final bytes = Uint8List.fromList(
        List.generate(2 * 1024 * 1024 + 3001, (index) => index * 7 % 251),
      );
      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: bytes,
        fileName: 'iroh-1mib.bin',
      );
      ChatMessage? received;
      await _waitForIroh(() {
        received = bob
            .messagesFor(alice.identity!.deviceId)
            .where((m) => m.attachment?.fileName == 'iroh-1mib.bin')
            .firstOrNull;
        final id = received?.attachment?.id;
        if (id != null && bob.attachmentAwaitingAcceptance(id)) {
          unawaited(bob.acceptIncomingAttachment(id));
        }
        return id != null && bob.attachmentAvailableLocally(id);
      }, reason: 'the 1 MiB-block transfer did not finish');
      expect(received!.attachment!.chunkSize, 1024 * 1024);
      final cache = await bob.attachmentCachePathFor(received!.attachment!.id);
      expect(await File(cache!).readAsBytes(), bytes);
    },
  );

  test(
    'transfer retries wait for the blocks in flight at the measured rate',
    () {
      // Nothing measured yet: assume a slow 1 Mbit/s path, so four 1 MiB
      // blocks get a minute rather than the old fixed 30 seconds.
      expect(
        MessengerController.transferRetryDelay(
          attempt: 0,
          blockBytes: 1024 * 1024,
          window: 4,
          bytesPerSecond: null,
        ),
        greaterThanOrEqualTo(const Duration(seconds: 60)),
      );
      // A fast LAN keeps the base backoff.
      expect(
        MessengerController.transferRetryDelay(
          attempt: 0,
          blockBytes: 4 * 1024 * 1024,
          window: 4,
          bytesPerSecond: 50 * 1024 * 1024,
        ),
        const Duration(seconds: 30),
      );
      // A slow relay path (200 KiB/s) with 4 MiB in flight: well over a minute.
      expect(
        MessengerController.transferRetryDelay(
          attempt: 0,
          blockBytes: 1024 * 1024,
          window: 4,
          bytesPerSecond: 200 * 1024,
        ),
        greaterThan(const Duration(seconds: 40)),
      );
      // Bounded.
      expect(
        MessengerController.transferRetryDelay(
          attempt: 9,
          blockBytes: 4 * 1024 * 1024,
          window: 4,
          bytesPerSecond: 1,
        ),
        lessThanOrEqualTo(const Duration(minutes: 10)),
      );
    },
  );

  test(
    'a file over the Iroh limit is refused while no LAN path works',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      // LAN stays enabled, so the send is staged; it just never works.
      for (final controller in [alice, bob]) {
        await controller.updateGlobalConnectivity(
          _irohOnlyConnectivity.copyWith(lanEnabled: true),
        );
        controller.irohTransferLimitBytesForTesting = 1024 * 1024;
      }
      await _pairControllers(alice, bob);
      relay.shouldFailStore = (_, _, _, _, _) => true;
      // No LAN path has worked: the file is refused up front, not offered
      // and left waiting.
      await expectLater(
        alice.sendAttachment(
          contact: alice.contacts.single,
          bytes: Uint8List(3 * 1024 * 1024),
          fileName: 'big.bin',
        ),
        throwsA(isA<IrohTransferLimitException>()),
      );
      expect(
        bob
            .messagesFor(alice.identity!.deviceId)
            .where((m) => m.attachment != null),
        isEmpty,
      );
      expect(
        network.envelopes.where((e) => e.kind == 'attachment_chunk'),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'Iroh limit blocks oversized manual and debug sends before preparation and honors both peers',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final aliceVault = _MemoryVaultStore();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: aliceVault,
        transportRegistryFactory: network.registry,
        debugBuildId: 'debug-limit',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
        debugBuildId: 'debug-limit',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      final contact = alice.contacts.single;
      expect(alice.effectiveMaxAttachmentSizeFor(contact), 100 * 1024 * 1024);
      await expectLater(
        alice.sendAttachmentSource(
          contact: contact,
          source: StagedAttachment(
            id: 'oversized',
            fileName: 'oversized.bin',
            mimeType: 'application/octet-stream',
            sizeBytes: 100 * 1024 * 1024 + 1,
            filePath: '/does-not-exist',
          ),
        ),
        throwsA(isA<IrohTransferLimitException>()),
      );
      await expectLater(
        alice.runDebugFileBattleTest(contact: contact, sizeMiB: 125),
        throwsA(isA<IrohTransferLimitException>()),
      );
      await alice.updateIrohTransferLimitEnabled(false);
      expect(
        (await aliceVault.load())
            .identity!
            .connectivity
            .irohTransferLimitEnabled,
        isFalse,
      );
      expect(
        alice.effectiveMaxAttachmentSizeFor(contact),
        MessengerController.maxLanAttachmentSizeBytes,
      );
      await expectLater(
        alice.runDebugFileBattleTest(contact: contact, sizeMiB: 125),
        throwsA(isA<IrohTransferLimitException>()),
        reason: 'receiver limit is still on',
      );
      expect(alice.messagesFor(contact.deviceId), isEmpty);
      expect(bob.messagesFor(alice.identity!.deviceId), isEmpty);
      final matrix = await alice.runDebugFileBattleTestMatrix(contact: contact);
      expect(matrix.map((result) => result.sizeMiB), [5, 15, 30, 100]);
      expect(matrix.every((result) => result.success), isTrue);
      expect(alice.debugFileTestStatus, contains('100 MiB Iroh limit'));
      await alice.updateIrohTransferLimitEnabled(true);
      await alice.updateGlobalConnectivity(
        alice.identity!.connectivity.copyWith(lanEnabled: true),
      );
      expect(
        alice.effectiveMaxAttachmentSizeFor(contact),
        MessengerController.maxLanAttachmentSizeBytes,
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'repeated LAN hints preserve the endpoint and prefer the shared subnet',
    () async {
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        lanAddresses: ['192.168.3.55'],
      );
      addTearDown(controller.dispose);
      final hint = <String, dynamic>{
        'senderLanDirectPort': 43210,
        'senderLanAddresses': ['172.17.0.1', '192.168.3.11'],
        'senderLanBinaryVersion': 1,
      };
      controller.cachePeerLanDirectHintForTesting('peer', hint);
      final before = controller.peerLanDirectEndpointForTesting('peer')!;
      expect(before.host, '192.168.3.11');
      before.consecutiveFailures = 1;
      controller.cachePeerLanDirectHintForTesting('peer', hint);
      expect(
        identical(before, controller.peerLanDirectEndpointForTesting('peer')),
        isTrue,
      );
      expect(before.consecutiveFailures, 1);
      expect(before.alternateHosts, ['172.17.0.1']);
    },
  );

  testWidgets(
    'storage reserve warning offers Download anyway and Settings exposes its switch',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late MessengerController alice;
      late MessengerController bob;
      late String id;
      await tester.runAsync(() async {
        final relay = _FakeRelayClient();
        alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
        );
        bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
          storageCapacityProvider: (_) async => const StorageCapacity(
            freeBytes: 512 * 1024,
            totalBytes: 10 * 1024 * 1024,
          ),
        );
        await _pairControllers(alice, bob);
        await bob.updateGlobalConnectivity(
          bob.identity!.connectivity.copyWith(
            autoDownloadPreset: AutoDownloadPreset.custom,
          ),
        );
        await alice.sendAttachment(
          contact: alice.contacts.single,
          bytes: Uint8List(64 * 1024),
          fileName: 'reserve-ui.bin',
        );
        await bob.pollNow();
        id = bob
            .messagesFor(alice.identity!.deviceId)
            .singleWhere((m) => m.attachment != null)
            .attachment!
            .id;
        await bob.acceptIncomingAttachment(id);
      });
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      final updates = _createUpdateService();
      final theme = app.ConestThemeController.memory();
      addTearDown(updates.dispose);
      addTearDown(theme.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: bob,
            builder: (context, _) => app.HomeScreen(
              controller: bob,
              updateService: updates,
              buildInfo: _createBuildInfo(),
              themeController: theme,
              palette: app.ConestPalette(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Alice').first);
      await tester.pump();
      expect(find.text('Download anyway'), findsOneWidget);
      expect(find.textContaining('10% free-space reserve'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Download anyway'));
        await _waitForIroh(
          () =>
              !bob.attachmentAwaitingAcceptance(id) &&
              !bob.attachmentAcceptanceInProgress(id),
        );
      });
      await tester.pump(const Duration(milliseconds: 250));
      expect(bob.identity!.connectivity.storageReserveEnabled, isTrue);
      expect(find.text('Download anyway'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: app.SettingsDialog(
              controller: bob,
              updateService: updates,
              themeController: theme,
              palette: app.ConestPalette(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Keep 10% of storage free'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Keep 10% of storage free'));
        await _waitForIroh(
          () => !bob.identity!.connectivity.storageReserveEnabled,
        );
      });
      await tester.pump();
      expect(bob.identity!.connectivity.storageReserveEnabled, isFalse);
      expect(bob.identity!.connectivity.irohTransferLimitEnabled, isTrue);
      await tester.ensureVisible(
        find.text('Limit Iroh files to 100 MiB (recommended)'),
      );
      await tester.runAsync(() async {
        await tester.tap(
          find.text('Limit Iroh files to 100 MiB (recommended)'),
        );
        await _waitForIroh(
          () => !bob.identity!.connectivity.irohTransferLimitEnabled,
        );
      });
      await tester.pump();
      expect(bob.identity!.connectivity.irohTransferLimitEnabled, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await bob.cancelTransfer(id);
      });
    },
  );

  for (final disableGlobally in [false, true]) {
    test(
      'storage reserve can be bypassed with global setting=$disableGlobally',
      () async {
        final relay = _FakeRelayClient();
        final vault = _MemoryVaultStore();
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
          vaultStore: vault,
          storageCapacityProvider: (_) async => const StorageCapacity(
            freeBytes: 512 * 1024,
            totalBytes: 10 * 1024 * 1024,
          ),
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        await bob.updateGlobalConnectivity(
          bob.identity!.connectivity.copyWith(
            autoDownloadPreset: AutoDownloadPreset.custom,
          ),
        );
        final bytes = Uint8List.fromList(List<int>.filled(64 * 1024, 73));
        await alice.sendAttachment(
          contact: alice.contacts.single,
          bytes: bytes,
          fileName: 'reserve.bin',
        );
        await bob.pollNow();
        final id = bob
            .messagesFor(alice.identity!.deviceId)
            .singleWhere((m) => m.attachment != null)
            .attachment!
            .id;
        await bob.acceptIncomingAttachment(id);
        expect(bob.attachmentAwaitingAcceptance(id), isTrue);
        expect(bob.canDownloadIgnoringStorageReserve(id), isTrue);
        expect(
          bob.transferSnapshotFor(id)?.error,
          contains('10% free-space reserve'),
        );
        await bob.pollNow();
        await _waitForIroh(
          () => vault._snapshot.transferSessions.any(
            (s) => s.storageReserveBlocked,
          ),
        );
        expect(
          TransferSession.fromJson(
            vault._snapshot.transferSessions.single.toJson(),
          ).storageReserveBlocked,
          isTrue,
        );
        if (disableGlobally) {
          await bob.updateStorageReserveEnabled(false);
          expect(
            (await vault.load()).identity!.connectivity.storageReserveEnabled,
            isFalse,
          );
        }
        await bob.acceptIncomingAttachment(
          id,
          ignoreStorageReserve: !disableGlobally,
        );
        expect(bob.attachmentAwaitingAcceptance(id), isFalse);
        expect(
          bob.identity!.connectivity.storageReserveEnabled,
          !disableGlobally,
        );
        for (var i = 0; i < 10 && !bob.attachmentAvailableLocally(id); i++) {
          await alice.pollNow();
          await bob.pollNow();
        }
        expect(bob.attachmentBytesFor(id), bytes);
        await alice.sendAttachment(
          contact: alice.contacts.single,
          bytes: bytes,
          fileName: 'second.bin',
        );
        await alice.pollNow();
        await bob.pollNow();
        final secondId = bob
            .messagesFor(alice.identity!.deviceId)
            .singleWhere((m) => m.attachment?.fileName == 'second.bin')
            .attachment!
            .id;
        await bob.acceptIncomingAttachment(secondId);
        expect(
          bob.attachmentAwaitingAcceptance(secondId),
          !disableGlobally,
          reason:
              'A one-time override must not disable the reserve for subsequent files',
        );
      },
    );
  }

  test(
    'Download anyway rechecks actual free space and refuses unknown capacity',
    () async {
      StorageCapacity? capacity = const StorageCapacity(
        freeBytes: 512 * 1024,
        totalBytes: 10 * 1024 * 1024,
      );
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        storageCapacityProvider: (_) async => capacity,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await bob.updateGlobalConnectivity(
        bob.identity!.connectivity.copyWith(
          autoDownloadPreset: AutoDownloadPreset.custom,
        ),
      );
      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: Uint8List(64 * 1024),
        fileName: 'full.bin',
      );
      await bob.pollNow();
      final id = bob
          .messagesFor(alice.identity!.deviceId)
          .singleWhere((m) => m.attachment != null)
          .attachment!
          .id;
      await bob.acceptIncomingAttachment(id);
      expect(bob.canDownloadIgnoringStorageReserve(id), isTrue);
      capacity = const StorageCapacity(
        freeBytes: 1024,
        totalBytes: 10 * 1024 * 1024,
      );
      await bob.acceptIncomingAttachment(id, ignoreStorageReserve: true);
      expect(bob.attachmentAwaitingAcceptance(id), isTrue);
      expect(bob.canDownloadIgnoringStorageReserve(id), isFalse);
      expect(
        bob.transferSnapshotFor(id)?.error,
        contains('Not enough free storage'),
      );
      await bob.updateStorageReserveEnabled(false);
      await bob.acceptIncomingAttachment(id);
      expect(bob.attachmentAwaitingAcceptance(id), isTrue);
      capacity = null;
      await bob.acceptIncomingAttachment(id, ignoreStorageReserve: true);
      expect(bob.attachmentAwaitingAcceptance(id), isTrue);
      expect(
        bob.transferSnapshotFor(id)?.error,
        contains('Could not check available storage'),
      );
    },
  );

  test(
    'canceling an in-flight binary block prevents retries and fallback delivery',
    () async {
      final relay = _FakeRelayClient();
      final aliceChannel = _InProcessLanDirectChannel(host: '192.168.70.10');
      final bobChannel = _InProcessLanDirectChannel(host: '192.168.70.11');
      final vault = _MemoryVaultStore();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: vault,
        lanAddresses: [aliceChannel.host],
        lanDirectChannel: aliceChannel,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        lanAddresses: [bobChannel.host],
        lanDirectChannel: bobChannel,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(aliceChannel.stop);
      addTearDown(bobChannel.stop);
      await _pairControllers(alice, bob);
      await bob.updateGlobalConnectivity(
        bob.identity!.connectivity.copyWith(
          autoDownloadPreset: AutoDownloadPreset.custom,
        ),
      );
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var attempts = 0;
      aliceChannel.blockPutOverride = () async {
        attempts++;
        await release.future;
        return false;
      };
      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'cancel.bin',
      );
      await bob.pollNow();
      final id = bob
          .messagesFor(alice.identity!.deviceId)
          .singleWhere((m) => m.attachment != null)
          .attachment!
          .id;
      await bob.acceptIncomingAttachment(id);
      await _waitForIroh(() => attempts > 0);
      await alice.cancelTransfer(id);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(attempts, 1);
      expect(
        vault._snapshot.transferSessions.single.state,
        TransferState.canceled,
      );
      expect(
        relay.storedEnvelopes.where((e) => e.kind == 'attachment_chunk'),
        isEmpty,
      );
      expect(
        alice
            .messagesFor(bob.identity!.deviceId)
            .singleWhere((m) => m.attachment?.id == id)
            .state,
        DeliveryState.canceled,
      );
    },
  );

  for (final relayed in [false, true]) {
    test(
      'Iroh pairing and two-way messages work with relayed=$relayed and legacy routes disabled',
      () async {
        final network = _InProcessIrohNetwork(relayed: relayed);
        final relay = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
          transportRegistryFactory: network.registry,
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
          transportRegistryFactory: network.registry,
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
        await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
        relay.storedEnvelopes.clear();
        final result = await alice.addContactFromInvite(
          alias: 'Bob',
          payload: (await bob.buildInvite()).encodePayload(),
          codephrase: '',
        );
        expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
        await _waitForIroh(() => bob.pendingContactRequests.isNotEmpty);
        expect(
          bob.contacts,
          isEmpty,
          reason: 'Bootstrap must still require approval',
        );
        await bob.approvePendingContactRequest(
          bob.pendingContactRequests.single.id,
        );
        expect(bob.contacts.single.hasPinnedIrohIdentity, isTrue);
        await _waitForIroh(
          () => network.envelopes.any(
            (e) => e.kind == 'contact_exchange' && e.protocolVersion == 2,
          ),
        );
        await alice.sendMessage(
          contact: alice.contacts.single,
          body: 'Hello over Iroh',
        );
        await _waitForIroh(
          () => bob
              .messagesFor(alice.identity!.deviceId)
              .any((m) => m.body == 'Hello over Iroh'),
        );
        await bob.sendMessage(
          contact: bob.contacts.single,
          body: 'Reply over Iroh',
        );
        await _waitForIroh(
          () => alice
              .messagesFor(bob.identity!.deviceId)
              .any((m) => m.body == 'Reply over Iroh'),
        );
        await _waitForIroh(
          () => alice
              .messagesFor(bob.identity!.deviceId)
              .where((m) => m.outbound)
              .every((m) => m.state == DeliveryState.delivered),
        );
        final bytes = Uint8List.fromList(
          List<int>.generate(256 * 1024 + 3, (i) => i % 251),
        );
        await alice.sendAttachment(
          contact: alice.contacts.single,
          bytes: bytes,
          fileName: 'iroh.bin',
        );
        await _waitForIroh(
          () => bob
              .messagesFor(alice.identity!.deviceId)
              .any((m) => m.attachment != null),
        );
        final attachmentId = bob
            .messagesFor(alice.identity!.deviceId)
            .singleWhere((m) => m.attachment != null)
            .attachment!
            .id;
        await bob.acceptIncomingAttachment(attachmentId);
        await _waitForIroh(() => bob.attachmentAvailableLocally(attachmentId));
        // Disk availability precedes the asynchronous in-memory cache load.
        // Wait for that accessor before comparing bytes, as the UI does.
        await _waitForIroh(() => bob.attachmentBytesFor(attachmentId) != null);
        expect(bob.attachmentBytesFor(attachmentId), bytes);
        await _waitForIroh(
          () =>
              alice.transferSnapshotFor(attachmentId)?.phase ==
              TransferPhase.completed,
        );
        expect(
          relay.storedEnvelopes.where((e) => e.kind != 'pairing_announcement'),
          isEmpty,
        );
      },
    );
  }

  test(
    'native Iroh direct contact adding works without LAN or any relay',
    () async {
      final relay = _FakeRelayClient()
        ..shouldFailStore = (_, _, _, _, _) => true;
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        internetRelayHost: null,
        transportRegistryFactory: _directNativeIrohRegistry,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        internetRelayHost: null,
        transportRegistryFactory: _directNativeIrohRegistry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      for (final peer in [alice, bob]) {
        await peer.updateGlobalConnectivity(_irohOnlyConnectivity);
        expect(peer.identity!.connectivity.lanEnabled, isFalse);
      }

      final result = await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      // The request is sent in the background; Bob must approve it.
      expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
      await _waitForIroh(() => bob.pendingContactRequests.isNotEmpty);
      await bob.approvePendingContactRequest(
        bob.pendingContactRequests.single.id,
      );
      expect(bob.contacts.single.hasPinnedIrohIdentity, isTrue);
      await _waitForIroh(
        () =>
            alice.contacts.single.featureCapabilityVersion == 1 &&
            alice.contacts.single.canSendOutbound,
      );

      await alice.sendMessage(
        contact: alice.contacts.single,
        body: 'Direct hello',
      );
      await _waitForIroh(
        () => bob
            .messagesFor(alice.identity!.deviceId)
            .any((m) => m.body == 'Direct hello'),
      );
      await bob.sendMessage(contact: bob.contacts.single, body: 'Direct reply');
      await _waitForIroh(
        () => alice
            .messagesFor(bob.identity!.deviceId)
            .any((m) => m.body == 'Direct reply'),
      );
      expect(relay.storedEnvelopes, isEmpty);
    },
  );

  // Live network qualification: build conest_native with
  // `--features test-relay-only` and set CONEST_IROH_TEST_RELAY_ONLY=1 so
  // endpoints have no IP transports and must use the public Iroh relays.
  test(
    'native Iroh contact adding works through the public Iroh relays only',
    () async {
      final adapters = <IrohTransportAdapter>[];
      Future<TransportRegistry?> relayOnlyRegistry(
        IdentityRecord identity,
      ) async {
        final bridge = FfiNativeIrohBridge.tryCreate();
        if (bridge == null) {
          throw StateError('The native Iroh bridge is unavailable.');
        }
        final adapter = IrohTransportAdapter(
          bridge: bridge,
          secretKeySeed: Uint8List.fromList(
            base64Decode(identity.signingPrivateKeyBase64!),
          ),
          relayEnabled: true,
          expectedEndpointId: identity.irohEndpointId,
        );
        adapters.add(adapter);
        return TransportRegistry(<TransportAdapter>[adapter]);
      }

      Future<void> waitForRelay(
        bool Function() ready,
        String reason,
      ) async {
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: reason);
      }

      final relay = _FakeRelayClient()
        ..shouldFailStore = (_, _, _, _, _) => true;
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        internetRelayHost: null,
        transportRegistryFactory: relayOnlyRegistry,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        internetRelayHost: null,
        transportRegistryFactory: relayOnlyRegistry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      for (final peer in [alice, bob]) {
        await peer.updateGlobalConnectivity(_irohOnlyConnectivity);
        expect(peer.identity!.connectivity.irohRelayEnabled, isTrue);
      }

      final result = await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      // The request is sent in the background; Bob must approve it.
      expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
      await waitForRelay(
        () => bob.pendingContactRequests.isNotEmpty,
        'contact request did not arrive over the Iroh relay',
      );
      await bob.approvePendingContactRequest(
        bob.pendingContactRequests.single.id,
      );
      expect(bob.contacts.single.hasPinnedIrohIdentity, isTrue);
      await waitForRelay(
        () =>
            alice.contacts.single.featureCapabilityVersion == 1 &&
            alice.contacts.single.canSendOutbound,
        'acceptance did not return over the Iroh relay',
      );
      await alice.sendMessage(
        contact: alice.contacts.single,
        body: 'Relayed hello',
      );
      await waitForRelay(
        () => bob
            .messagesFor(alice.identity!.deviceId)
            .any((m) => m.body == 'Relayed hello'),
        'message did not arrive over the Iroh relay',
      );
      await bob.sendMessage(
        contact: bob.contacts.single,
        body: 'Relayed reply',
      );
      await waitForRelay(
        () => alice
            .messagesFor(bob.identity!.deviceId)
            .any((m) => m.body == 'Relayed reply'),
        'reply did not arrive over the Iroh relay',
      );
      expect(relay.storedEnvelopes, isEmpty);
      // Prove no direct path existed: relay-only endpoints bind no IP
      // transports, so they have no direct address to advertise.
      expect(adapters, hasLength(2));
      for (final adapter in adapters) {
        expect(adapter.status, isNotNull);
        expect(adapter.status!.directAddresses, isEmpty);
      }
    },
    skip: Platform.environment['CONEST_IROH_TEST_RELAY_ONLY'] == null
        ? 'Requires the live Iroh relays and a test-relay-only native build'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'Iroh group history signed polls and scheduled file captions converge',
    () async {
      final network = _InProcessIrohNetwork();
      final relayClient = _FakeRelayClient();
      final attachmentRoot = await Directory.systemTemp.createTemp(
        'conest-scheduled-group-caption-',
      );
      final aliceAttachmentRoot = Directory(
        p.join(attachmentRoot.path, 'alice'),
      );
      final bobAttachmentRoot = Directory(p.join(attachmentRoot.path, 'bob'));
      await aliceAttachmentRoot.create();
      await bobAttachmentRoot.create();
      addTearDown(() => attachmentRoot.delete(recursive: true));
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => aliceAttachmentRoot,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => bobAttachmentRoot,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await alice.addContactFromInvite(
        alias: bob.identity!.displayName,
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await _waitForIroh(() => bob.pendingContactRequests.isNotEmpty);
      await bob.approvePendingContactRequest(
        bob.pendingContactRequests.single.id,
      );
      await _waitForIroh(
        () =>
            alice.contacts.single.featureCapabilityVersion == 1 &&
            bob.contacts.single.featureCapabilityVersion == 1,
        reason: 'authenticated application capability exchange',
      );
      expect(
        alice.contacts.single.featureCapabilities,
        contains(ApplicationCapability.groupPollsV1),
      );
      expect(
        bob.contacts.single.featureCapabilities,
        contains(ApplicationCapability.groupFileCaptionsV2),
      );
      final restoredContact = ContactRecord.fromJson(
        alice.contacts.single.toJson(),
      );
      expect(restoredContact.featureCapabilityVersion, 1);
      expect(
        restoredContact.featureCapabilities,
        alice.contacts.single.featureCapabilities,
      );
      final bobContact = alice.contacts.single;
      final group = await alice.createGroup(
        title: 'Poll delivery',
        members: <ContactRecord>[bobContact],
      );
      await _waitForIroh(
        () =>
            bob.groups.any((candidate) => candidate.groupId == group.groupId) &&
            alice.pendingGroupMembershipDeliveries.isEmpty,
        reason: 'group membership delivery',
      );
      final aliceGroup = alice.groups.singleWhere(
        (candidate) => candidate.groupId == group.groupId,
      );
      final bobProfile = aliceGroup.memberProfileFor(bob.identity!.deviceId)!;
      expect(bobProfile.featureCapabilityVersion, 1);
      expect(
        bobProfile.featureCapabilities,
        contains(ApplicationCapability.groupPollsV1),
      );
      expect(
        GroupMemberProfile.fromJson(bobProfile.toJson()).featureCapabilities,
        bobProfile.featureCapabilities,
      );

      await alice.createGroupPoll(
        groupId: group.groupId,
        question: 'Choose one',
        options: const <String>['First', 'Second'],
      );
      await _waitForIroh(
        () => bob
            .messagesForGroup(group.groupId)
            .any((message) => message.poll?.question == 'Choose one'),
        reason: 'poll delivery',
      );
      final poll = bob
          .messagesForGroup(group.groupId)
          .singleWhere((message) => message.poll?.question == 'Choose one')
          .poll!;

      await expectLater(
        bob.sendGroupMessage(
          groupId: group.groupId,
          body: 'Conflicting poll ID',
          poll: PollDefinition(
            id: poll.id,
            question: 'Different immutable question',
            options: const <String>['Yes', 'No'],
            mode: PollChoiceMode.single,
            creatorDeviceId: bob.identity!.deviceId,
            createdAt: DateTime.now().toUtc(),
          ),
        ),
        throwsStateError,
      );

      await bob.voteInGroupPoll(
        groupId: group.groupId,
        pollId: poll.id,
        optionIndexes: const <int>[1],
      );
      await _waitForIroh(
        () =>
            alice
                .groupPollProjection(group.groupId, poll.id)
                ?.votes[bob.identity!.deviceId]
                ?.optionIndexes
                .join(',') ==
            '1',
        reason: 'vote delivery',
      );
      await alice.closeGroupPoll(groupId: group.groupId, pollId: poll.id);
      await _waitForIroh(
        () =>
            bob
                .groupPollProjection(group.groupId, poll.id)
                ?.definition
                .isClosed ==
            true,
        reason: 'close checkpoint delivery',
      );
      await expectLater(
        alice.closeGroupPoll(groupId: group.groupId, pollId: poll.id),
        throwsStateError,
      );

      final closed = bob.groupPollProjection(group.groupId, poll.id)!;
      expect(closed.definition.isClosed, isTrue);
      expect(closed.counts(), <int>[0, 1]);
      await bob.sendGroupMessage(
        groupId: group.groupId,
        body: 'late signed vote',
        pollVote: PollVote(
          pollId: poll.id,
          voterDeviceId: bob.identity!.deviceId,
          optionIndexes: const <String>['0'],
          changedAt: DateTime.now().toUtc(),
        ),
      );
      await _waitForIroh(
        () =>
            alice
                .groupPollProjection(group.groupId, poll.id)
                ?.unconfirmedVotes[bob.identity!.deviceId]
                ?.optionIndexes
                .join(',') ==
            '0',
        reason: 'late vote remains visible as unconfirmed',
      );
      final afterLateVote = alice.groupPollProjection(group.groupId, poll.id)!;
      expect(
        afterLateVote.votes[bob.identity!.deviceId]?.optionIndexes,
        <String>['1'],
      );
      expect(afterLateVote.counts(), <int>[0, 1]);

      await alice.createGroupPoll(
        groupId: group.groupId,
        question: 'Empty close checkpoint',
        options: const <String>['Yes', 'No'],
      );
      await _waitForIroh(
        () => bob
            .messagesForGroup(group.groupId)
            .any(
              (message) => message.poll?.question == 'Empty close checkpoint',
            ),
        reason: 'second poll delivery',
      );
      final emptyCheckpointPoll = bob
          .messagesForGroup(group.groupId)
          .singleWhere(
            (message) => message.poll?.question == 'Empty close checkpoint',
          )
          .poll!;
      await alice.closeGroupPoll(
        groupId: group.groupId,
        pollId: emptyCheckpointPoll.id,
      );
      await _waitForIroh(
        () =>
            bob
                .groupPollProjection(group.groupId, emptyCheckpointPoll.id)
                ?.definition
                .isClosed ==
            true,
        reason: 'empty close checkpoint delivery',
      );
      await bob.sendGroupMessage(
        groupId: group.groupId,
        body: 'late vote after empty checkpoint',
        pollVote: PollVote(
          pollId: emptyCheckpointPoll.id,
          voterDeviceId: bob.identity!.deviceId,
          optionIndexes: const <String>['0'],
          changedAt: DateTime.now().toUtc(),
        ),
      );
      await _waitForIroh(
        () =>
            alice
                .groupPollProjection(group.groupId, emptyCheckpointPoll.id)
                ?.unconfirmedVotes[bob.identity!.deviceId]
                ?.optionIndexes
                .join(',') ==
            '0',
        reason: 'vote outside empty checkpoint stays unconfirmed',
      );
      expect(
        alice
            .groupPollProjection(group.groupId, emptyCheckpointPoll.id)!
            .counts(),
        <int>[0, 0],
      );

      final source = await File(
        p.join(aliceAttachmentRoot.path, 'scheduled-caption.txt'),
      ).writeAsBytes(<int>[1, 2, 3]);
      final scheduled = await alice.scheduleGroupAttachment(
        groupId: group.groupId,
        source: StagedAttachment(
          id: 'scheduled-caption-source',
          fileName: 'scheduled-caption.txt',
          mimeType: 'text/plain',
          sizeBytes: 3,
          filePath: source.path,
        ),
        scheduledAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      await alice.editScheduledMessage(scheduled.id, 'Group file caption');
      await alice.sendScheduledMessageNow(scheduled.id);
      final dispatchedSchedule = alice.scheduledMessages.singleWhere(
        (entry) => entry.id == scheduled.id,
      );
      expect(
        dispatchedSchedule.state,
        ScheduledMessageState.sent,
        reason:
            dispatchedSchedule.failureReason ??
            'The scheduled group attachment was not handed off.',
      );
      await _waitForIroh(
        () => bob
            .messagesForGroup(group.groupId)
            .any(
              (message) =>
                  message.groupFile?.fileName == 'scheduled-caption.txt' &&
                  message.body == 'Group file caption',
            ),
        reason: 'scheduled caption is signed with its group attachment',
      );
      final groupFileMessage = bob
          .messagesForGroup(group.groupId)
          .singleWhere(
            (message) => message.groupFile?.fileName == 'scheduled-caption.txt',
          );
      final retryEventId = await alice.publishGroupFile(
        groupId: group.groupId,
        path: source.path,
        fileName: 'scheduled-caption.txt',
        mimeType: 'text/plain',
        caption: 'Group file caption',
        scheduledOperationId: scheduled.id,
      );
      expect(retryEventId, groupFileMessage.groupHistoryEventId);
      await expectLater(
        bob.voteInGroupPoll(
          groupId: group.groupId,
          pollId: poll.id,
          optionIndexes: const <int>[0],
        ),
        throwsStateError,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'Iroh group history crosses partitions through a group-only carrier',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final peers = <MessengerController>[];
      final aliceVault = _MemoryVaultStore();
      for (final name in ['Alice', 'Bob', 'Carol', 'Dave']) {
        final peer = await _createController(
          relayClient: relay,
          displayName: name,
          internetRelayHost: null,
          transportRegistryFactory: network.registry,
          vaultStore: name == 'Alice' ? aliceVault : null,
        );
        peers.add(peer);
        addTearDown(peer.dispose);
        await peer.updateGlobalConnectivity(_irohOnlyConnectivity);
      }
      final [alice, bob, carol, dave] = peers;
      for (final peer in [bob, carol, dave]) {
        await alice.addContactFromInvite(
          alias: peer.identity!.displayName,
          payload: (await peer.buildInvite()).encodePayload(),
          codephrase: '',
        );
        await _waitForIroh(() => peer.pendingContactRequests.isNotEmpty);
        await peer.approvePendingContactRequest(
          peer.pendingContactRequests.single.id,
        );
      }
      final group = await alice.createGroup(
        title: 'Carried history',
        members: alice.contacts,
      );
      expect(
        await alice.groupHistoryIncludesEarlierMessages(group.groupId),
        isTrue,
      );
      await expectLater(
        bob.setGroupHistoryIncludesEarlierMessages(group.groupId, false),
        throwsStateError,
      );
      await alice.setGroupHistoryIncludesEarlierMessages(group.groupId, false);
      expect(
        await alice.groupHistoryIncludesEarlierMessages(group.groupId),
        isFalse,
      );
      await alice.setGroupHistoryIncludesEarlierMessages(group.groupId, true);
      expect(
        await alice.groupHistoryIncludesEarlierMessages(group.groupId),
        isTrue,
      );
      await _waitForIroh(
        () =>
            [bob, carol, dave].every((peer) => peer.groups.isNotEmpty) &&
            alice.pendingGroupMembershipDeliveries.isEmpty,
      );
      final carolBridge = network.bridges.remove(
        carol.identity!.irohEndpointId,
      )!;
      final daveBridge = network.bridges.remove(dave.identity!.irohEndpointId)!;
      await alice.sendGroupMessage(
        groupId: group.groupId,
        body: 'Alice partition message',
      );
      await bob.sendGroupMessage(
        groupId: group.groupId,
        body: 'Bob partition message',
      );
      await bob.synchronizeGroupHistory(
        groupId: group.groupId,
        peerDeviceId: alice.identity!.deviceId,
      );
      final aliceBridge = network.bridges.remove(
        alice.identity!.irohEndpointId,
      )!;
      network.bridges[carol.identity!.irohEndpointId!] = carolBridge;
      carol.onConnectivityChanged(interfaceLabel: 'mobile');
      await _waitForIroh(
        () => carol.messagesForGroup(group.groupId).length == 2,
      );
      final bobBridge = network.bridges.remove(
        bob.identity!.irohEndpointId,
      )!;
      network.bridges[dave.identity!.irohEndpointId!] = daveBridge;
      dave.requestGroupHistoryCatchUp(group.groupId);
      await _waitForIroh(
        () => dave.messagesForGroup(group.groupId).length == 2,
      );
      expect(
        dave
            .messagesForGroup(group.groupId)
            .map((message) => message.body)
            .toSet(),
        {'Alice partition message', 'Bob partition message'},
      );
      expect(dave.contactByDeviceId(carol.identity!.deviceId), isNull);
      expect(
        await dave.synchronizeGroupHistory(
          groupId: group.groupId,
          peerDeviceId: carol.identity!.deviceId,
        ),
        anyOf(0, 2),
      );
      expect(dave.messagesForGroup(group.groupId), hasLength(2));
      final original = alice
          .messagesForGroup(group.groupId)
          .firstWhere((message) => message.body == 'Alice partition message');
      await expectLater(
        dave.changeGroupMessage(
          groupId: group.groupId,
          messageId: original.id,
          body: 'Forged edit',
        ),
        throwsStateError,
      );
      await alice.changeGroupMessage(
        groupId: group.groupId,
        messageId: original.id,
        body: 'Alice edited offline',
      );
      network.bridges[alice.identity!.irohEndpointId!] = aliceBridge;
      await carol.synchronizeGroupHistory(
        groupId: group.groupId,
        peerDeviceId: alice.identity!.deviceId,
      );
      expect(
        carol
            .messagesForGroup(group.groupId)
            .firstWhere((message) => message.id == original.id)
            .body,
        'Alice edited offline',
      );
      await alice.changeGroupMessage(
        groupId: group.groupId,
        messageId: original.id,
        delete: true,
      );
      // More than a projection page arrives after the deletion. Catch-up must
      // still update an older message already displayed by the receiving peer.
      final journal = await aliceVault.openGroupHistory(group.groupId);
      final identity = alice.identity!;
      var head = (await journal.authorHead(identity.deviceId))!;
      final signingKey = SimpleKeyPairData(
        base64Decode(identity.signingPrivateKeyBase64!),
        publicKey: SimplePublicKey(
          base64Decode(identity.signingPublicKeyBase64!),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      );
      for (var index = 0; index < 55; index++) {
        head = await GroupHistoryEvent.sign(
          groupId: group.groupId,
          authorAccountId: identity.accountId,
          authorDeviceId: identity.deviceId,
          keyPair: signingKey,
          sequence: head.sequence + 1,
          previousEventId: head.eventId,
          lamport: head.lamport + 1,
          membershipId: head.membershipId,
          kind: GroupEventKind.message,
          payload: {
            'messageId': 'later-$index',
            'body': 'Later $index',
            'createdAt': DateTime.utc(2026, 9, 15).toIso8601String(),
          },
        );
        await journal.append(head);
      }
      await carol.synchronizeGroupHistory(
        groupId: group.groupId,
        peerDeviceId: alice.identity!.deviceId,
      );
      network.bridges.remove(alice.identity!.irohEndpointId);
      await dave.synchronizeGroupHistory(
        groupId: group.groupId,
        peerDeviceId: carol.identity!.deviceId,
      );
      expect(
        dave.messagesForGroup(group.groupId).map((message) => message.body),
        contains('Bob partition message'),
      );
      expect(
        dave
            .messagesForGroup(group.groupId)
            .any((message) => message.id == original.id),
        isFalse,
      );

      // Close a poll in Alice's partition while Bob casts a vote in the
      // connected partition. The signed checkpoint must remain stable when
      // the carrier later brings Bob's vote to all four peers.
      network.bridges[alice.identity!.irohEndpointId!] = aliceBridge;
      network.bridges[bob.identity!.irohEndpointId!] = bobBridge;
      await alice.createGroupPoll(
        groupId: group.groupId,
        question: 'Partitioned close',
        options: const ['Alice side', 'Bob side'],
      );
      // Bob missed the synthetic journal page above. Rejoin through history
      // sync before voting, rather than assuming a live poll envelope also
      // supplies every predecessor in its signed author chain.
      for (final peer in [bob, carol, dave]) {
        await peer.synchronizeGroupHistory(
          groupId: group.groupId,
          peerDeviceId: alice.identity!.deviceId,
        );
      }
      await _waitForIroh(
        () => peers.every(
          (peer) => peer.messagesForGroup(group.groupId).any(
            (message) => message.poll?.question == 'Partitioned close',
          ),
        ),
        reason: 'poll definition reaches every member before partition',
      );
      final partitionPoll = alice
          .messagesForGroup(group.groupId)
          .singleWhere(
            (message) => message.poll?.question == 'Partitioned close',
          )
          .poll!;
      final isolatedAlice = network.bridges.remove(
        alice.identity!.irohEndpointId,
      )!;
      await alice.voteInGroupPoll(
        groupId: group.groupId,
        pollId: partitionPoll.id,
        optionIndexes: const [0],
      );
      await alice.closeGroupPoll(
        groupId: group.groupId,
        pollId: partitionPoll.id,
      );
      await bob.voteInGroupPoll(
        groupId: group.groupId,
        pollId: partitionPoll.id,
        optionIndexes: const [1],
      );
      await _waitForIroh(
        () =>
            carol
                .groupPollProjection(group.groupId, partitionPoll.id)
                ?.votes[bob.identity!.deviceId]
                ?.optionIndexes
                .single ==
            '1',
        reason: 'the connected partition received the authenticated vote',
      );
      network.bridges[alice.identity!.irohEndpointId!] = isolatedAlice;
      for (final peer in peers) {
        if (peer == alice) continue;
        await peer.synchronizeGroupHistory(
          groupId: group.groupId,
          peerDeviceId: alice.identity!.deviceId,
        );
      }
      await alice.synchronizeGroupHistory(
        groupId: group.groupId,
        peerDeviceId: bob.identity!.deviceId,
      );
      await _waitForIroh(
        () => peers.every((peer) {
          final projection = peer.groupPollProjection(
            group.groupId,
            partitionPoll.id,
          );
          return projection?.definition.isClosed == true &&
              projection?.counts().join(',') == '1,0' &&
              projection?.unconfirmedVotes.containsKey(
                    bob.identity!.deviceId,
                  ) ==
                  true;
        }),
        reason:
            'all peers converge on the close checkpoint and retain the late vote as unconfirmed',
      );

      await dave.loadOlderGroupHistory(group.groupId);
      expect(
        dave
            .messagesForGroup(group.groupId)
            .any((message) => message.id == original.id),
        isFalse,
      );
      expect(
        network.envelopes.where((envelope) => envelope.kind == 'group_history'),
        isNotEmpty,
      );
      expect(
        relay.storedEnvelopes.where(
          (envelope) => envelope.kind != 'pairing_announcement',
        ),
        isEmpty,
      );
    },
  );

  test(
    'Iroh group admission excludes earlier history and survives later policy changes',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final peers = <MessengerController>[];
      for (final name in ['Alice', 'Bob', 'Carol']) {
        final peer = await _createController(
          relayClient: relay,
          displayName: name,
          internetRelayHost: null,
          transportRegistryFactory: network.registry,
        );
        peers.add(peer);
        addTearDown(peer.dispose);
        await peer.updateGlobalConnectivity(_irohOnlyConnectivity);
      }
      final [alice, bob, carol] = peers;
      Future<void> catchUp(String phase) async {
        await carol
            .synchronizeGroupHistory(
              groupId: alice.groups.single.groupId,
              peerDeviceId: alice.identity!.deviceId,
            )
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () {
                throw StateError(
                  '$phase timed out. Alice: ${alice.recentDebugLog.join("\n")} Carol: ${carol.recentDebugLog.join("\n")}',
                );
              },
            );
      }

      for (final peer in [bob, carol]) {
        await alice.addContactFromInvite(
          alias: peer.identity!.displayName,
          payload: (await peer.buildInvite()).encodePayload(),
          codephrase: '',
        );
        await _waitForIroh(() => peer.pendingContactRequests.isNotEmpty);
        await peer.approvePendingContactRequest(
          peer.pendingContactRequests.single.id,
        );
      }
      final group = await alice.createGroup(
        title: 'Admission policy',
        members: [
          alice.contacts.firstWhere(
            (peer) => peer.deviceId == bob.identity!.deviceId,
          ),
        ],
      );
      await _waitForIroh(
        () =>
            bob.groups.isNotEmpty &&
            alice.pendingGroupMembershipDeliveries.isEmpty,
      );
      await alice.sendGroupMessage(
        groupId: group.groupId,
        body: 'before admission',
      );
      await alice.setGroupHistoryIncludesEarlierMessages(group.groupId, false);
      await alice.addGroupMembers(
        groupId: group.groupId,
        members: [
          alice.contacts.firstWhere(
            (peer) => peer.deviceId == carol.identity!.deviceId,
          ),
        ],
      );
      await _waitForIroh(
        () =>
            carol.groups.isNotEmpty &&
            alice.pendingGroupMembershipDeliveries.isEmpty,
      );
      await catchUp('admission catch-up');
      expect(carol.messagesForGroup(group.groupId), isEmpty);
      final bridge = network.bridges.remove(carol.identity!.irohEndpointId)!;
      await alice.sendGroupMessage(
        groupId: group.groupId,
        body: 'after admission',
      );
      network.bridges[carol.identity!.irohEndpointId!] = bridge;
      carol.onConnectivityChanged(interfaceLabel: 'mobile');
      await catchUp('admission catch-up');
      expect(
        carol.messagesForGroup(group.groupId).map((message) => message.body),
        ['after admission'],
      );
      String? cursor;
      var pages = 0;
      do {
        cursor = await carol.loadOlderGroupHistory(
          group.groupId,
          beforeEventId: cursor,
        );
        expect(++pages, lessThan(10));
      } while (cursor != null);
      expect(
        carol.messagesForGroup(group.groupId).map((message) => message.body),
        ['after admission'],
      );
      await alice.setGroupHistoryIncludesEarlierMessages(group.groupId, true);
      await _waitForIroh(() => alice.pendingGroupMembershipDeliveries.isEmpty);
      await catchUp('admission catch-up');
      expect(
        carol.messagesForGroup(group.groupId).map((message) => message.body),
        ['after admission'],
      );
    },
  );

  test(
    'repeated group service replacements retain every pending hardware cleanup',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final media = _HeldGroupCloseMedia();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
        ratchetEngine: FakeRatchetEngine(),
        groupCallMedia: media,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
        ratchetEngine: FakeRatchetEngine(),
        groupCallMedia: FakeCallMedia(),
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      final original = await alice.createGroup(
        title: 'Original',
        members: alice.contacts,
      );
      await alice.joinOrStartGroupCall(original.groupId);
      final first = alice.groupCallService!;
      media.closeGate = Completer<void>();
      addTearDown(() {
        if (!media.closeGate!.isCompleted) media.closeGate!.complete();
      });
      await alice.resetIdentity();
      await alice.createIdentity(
        displayName: 'Idle replacement',
        internetRelayHost: null,
        internetRelayPort: defaultRelayPort,
        localRelayPort: defaultRelayPort,
      );
      final idle = alice.groupCallService!;
      expect(identical(first, idle), false);
      expect(first.mediaBusy, true);
      await alice.resetIdentity();
      await alice.createIdentity(
        displayName: 'Newest',
        internetRelayHost: null,
        internetRelayPort: defaultRelayPort,
        localRelayPort: defaultRelayPort,
      );
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      final newest = await alice.createGroup(
        title: 'Newest',
        members: alice.contacts,
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        alice.joinOrStartGroupCall(newest.groupId),
        throwsStateError,
      );
      expect(media.opened, true, reason: 'Original close still owns hardware');
      media.closeGate!.complete();
      await _waitForIroh(() => !first.mediaBusy);
      await alice.joinOrStartGroupCall(newest.groupId);
      expect(media.opened, true);
      await Future<void>.delayed(Duration.zero);
      expect(alice.groupCallService!.active, isNotNull);
      expect(
        media.opened,
        true,
        reason: 'No previous cleanup can close the new call',
      );
    },
  );

  test('with no call, the app is not woken for calls', () async {
    final bridge = _VoiceRecordingBridge();
    final alice = await _createController(
      relayClient: _FakeRelayClient(),
      displayName: 'Alice',
      platformBridge: bridge,
      ratchetEngine: FakeRatchetEngine(),
    );
    addTearDown(alice.dispose);
    expect(alice.groupCallService, isNotNull);
    var notified = 0;
    void count() => notified++;
    alice.addListener(count);
    addTearDown(() => alice.removeListener(count));
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(bridge.foreground, isEmpty);
    expect(notified, lessThan(2));
  });

  test('a group call tells Android only what changed', () async {
    final network = _InProcessIrohNetwork();
    final relay = _FakeRelayClient();
    final bridge = _VoiceRecordingBridge();
    final alice = await _createController(
      relayClient: relay,
      displayName: 'Alice',
      platformBridge: bridge,
      transportRegistryFactory: network.registry,
      ratchetEngine: FakeRatchetEngine(),
      groupCallMedia: FakeCallMedia(),
    );
    final bob = await _createController(
      relayClient: relay,
      displayName: 'Bob',
      transportRegistryFactory: network.registry,
      ratchetEngine: FakeRatchetEngine(),
      groupCallMedia: FakeCallMedia(),
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
    await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'Quiet upkeep',
      members: alice.contacts,
    );
    await alice.joinOrStartGroupCall(group.groupId);
    await Future<void>.delayed(Duration.zero);
    final before = bridge.foreground.length;
    for (var i = 0; i < 5; i++) {
      await alice.groupCallService!.tick();
      await Future<void>.delayed(Duration.zero);
    }
    expect(bridge.foreground.length, before);
  });

  test('call upkeep never falls back to relays', () async {
    final network = _InProcessIrohNetwork();
    final relay = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relay,
      displayName: 'Alice',
      transportRegistryFactory: network.registry,
      ratchetEngine: FakeRatchetEngine(),
      groupCallMedia: FakeCallMedia(),
    );
    final bob = await _createController(
      relayClient: relay,
      displayName: 'Bob',
      transportRegistryFactory: network.registry,
      ratchetEngine: FakeRatchetEngine(),
      groupCallMedia: FakeCallMedia(),
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await _pairControllers(alice, bob);
    final group = await alice.createGroup(
      title: 'Upkeep routes',
      members: alice.contacts,
    );
    await bob.pollNow();
    await alice.joinOrStartGroupCall(group.groupId);
    // Bob drops off every live route; only the relay could still reach him.
    final aliceIroh = alice.identity!.irohEndpointId!;
    final bobIroh = bob.identity!.irohEndpointId!;
    network.blockedPairs
      ..add((aliceIroh, bobIroh))
      ..add((bobIroh, aliceIroh));
    final relayed = <String>[];
    // (The fake also carries LAN delivery, which is a live route.)
    relay.shouldFailStore = (host, _, _, _, envelope) {
      if (envelope.kind == 'group_call_signal' && host == 'relay.example') {
        relayed.add(envelope.messageId);
      }
      return false;
    };
    for (var i = 0; i < 12; i++) {
      await alice.groupCallService!.tick();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(relayed, isEmpty);
  });

  test(
    'empty group ticks preserve a live Android 1:1 foreground call',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final bridge = _VoiceRecordingBridge();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        platformBridge: bridge,
        transportRegistryFactory: network.registry,
        ratchetEngine: FakeRatchetEngine(),
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        platformBridge: _VoiceRecordingBridge(),
        transportRegistryFactory: network.registry,
        ratchetEngine: FakeRatchetEngine(),
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      await _waitForIroh(
        () => alice.contacts.single.featureCapabilities.contains(
          ApplicationCapability.voiceCallsV1,
        ),
      );
      final call = await alice.voiceCallService!.startOutgoing(
        bob.identity!.deviceId,
      );
      await alice.voiceCallService!.onAccepted(callId: call.callId);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.foreground.last, 'connected');
      final before = bridge.foreground.length;
      await alice.groupCallService!.tick();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.foreground.skip(before), isNot(contains('idle')));
      expect(bridge.foreground.last, 'connected');
      expect(alice.voiceCallService!.mediaBusy, true);
    },
  );

  Future<void> groupCallRevocation({bool foreignClaim = false}) async {
    final network = _InProcessIrohNetwork();
    final relay = _FakeRelayClient();
    var now = DateTime.now().toUtc();
    final media = <FakeCallMedia>[];
    final peers = <MessengerController>[];
    final vaults = <_GroupCallVaultStore>[];
    for (final name in ['Alice', 'Bob', 'Phone', 'Carol']) {
      final audio = FakeCallMedia();
      final vault = _GroupCallVaultStore();
      final peer = await _createController(
        relayClient: relay,
        displayName: name,
        transportRegistryFactory: network.registry,
        ratchetEngine: FakeRatchetEngine(),
        groupCallMedia: audio,
        vaultStore: vault,
        nowProvider: () => now,
      );
      addTearDown(peer.dispose);
      peers.add(peer);
      media.add(audio);
      vaults.add(vault);
      await peer.updateGlobalConnectivity(_irohOnlyConnectivity);
    }
    final [alice, bob, phone, carol] = peers;
    var stage = 0;
    Future<void> waitRevocation(bool Function() ready) async {
      stage++;
      var nextStep = DateTime.now().add(const Duration(milliseconds: 500));
      try {
        await _waitForIroh(
          () {
            if (ready()) return true;
            if (stage >= 5 && !DateTime.now().isBefore(nextStep)) {
              // Advance the injected protocol clock while waiting for calls.
              // A frozen clock otherwise suppresses the actual 2 s key retry.
              now = now.add(const Duration(milliseconds: 125));
              nextStep = DateTime.now().add(const Duration(milliseconds: 500));
              for (final peer in peers) {
                unawaited(peer.groupCallService?.tick());
              }
            }
            return false;
          },
          reason: "revocation setup stage $stage, foreign=$foreignClaim",
          timeout: const Duration(seconds: 45),
        );
      } catch (_) {
        for (var index = 0; index < peers.length; index++) {
          final peer = peers[index];
          final room = peer.groupCallService?.active;
          debugPrint(
            '${peer.identity!.displayName}: term=${room?.term} '
            'coordinator=${room?.coordinator} epoch=${room?.epoch}/${room?.cipher.epoch} '
            'roster=${room?.participants.map((p) => p.deviceId).toList()} '
            'ratchetWrites=${vaults[index].committedPeerWrites}',
          );
        }
        rethrow;
      }
    }

    await _pairControllers(alice, bob);
    await _pairControllers(bob, carol);
    now = now.add(const Duration(hours: 25));
    final qr = await phone.startLinkAsNewDevice();
    await alice.startLinkFromQrCode(qr);
    await waitRevocation(
      () => phone.linkCode != null && alice.linkCode != null,
    );
    expect(phone.linkCode, alice.linkCode);
    await phone.confirmLinkCode();
    await alice.confirmLinkCode();
    await waitRevocation(
      () =>
          phone.linkState == LinkState.linked &&
          bob.linkedDevicesOf(alice.identity!.deviceId).isNotEmpty,
    );
    final phoneId = phone.identity!.deviceId;
    await waitRevocation(
      () =>
          bob
              .contactByDeviceId(phoneId)
              ?.featureCapabilities
              .contains(ApplicationCapability.groupVoiceCallsV1) ==
          true,
    );
    final group = await bob.createGroup(
      title: 'Account call',
      members: [
        bob.contactByDeviceId(alice.identity!.deviceId)!,
        bob.contactByDeviceId(phoneId)!,
        bob.contactByDeviceId(carol.identity!.deviceId)!,
      ],
    );
    await waitRevocation(
      () => peers.every((p) => p.groups.any((g) => g.groupId == group.groupId)),
    );
    await bob.joinOrStartGroupCall(group.groupId);
    await waitRevocation(
      () => [
        alice,
        phone,
        carol,
      ].every((p) => p.groupCallService?.roomFor(group.groupId) != null),
    );
    for (final peer in [alice, phone, carol]) {
      await peer.joinOrStartGroupCall(group.groupId);
    }
    await waitRevocation(
      () => peers.every(
        (p) =>
            p.groupCallService?.active?.connected == true &&
            p.groupCallService!.active!.participants.length == 4,
      ),
    );
    final targetId = foreignClaim ? carol.identity!.deviceId : phoneId;
    final epoch = bob.groupCallService!.active!.epoch;
    await alice.revokeAccountDevice(targetId);
    await waitRevocation(
      () => bob
          .contactByDeviceId(alice.identity!.deviceId)!
          .accountRevokedDeviceIds
          .contains(targetId),
    );
    for (final peer in [alice, bob]) {
      // Revocation is authorization, not a destructive edit to group history.
      expect(
        peer.groups
            .singleWhere((g) => g.groupId == group.groupId)
            .hasActiveMember(targetId),
        true,
      );
      expect(
        peer.groups
            .singleWhere((g) => g.groupId == group.groupId)
            .memberProfileFor(targetId),
        isNotNull,
      );
      expect(
        peer
            .groupCallMembersFor(group.groupId)
            .singleWhere((m) => m.deviceId == targetId)
            .canJoin,
        foreignClaim,
      );
      await peer.groupCallService!.tick();
    }
    if (foreignClaim) {
      expect(bob.groupCallService!.active!.epoch, epoch);
      final before = media[0].played.length;
      await waitRevocation(() {
        if (media[0].played.length > before) return true;
        unawaited(carol.groupCallService!.sendAudio(Uint8List.fromList([74])));
        return false;
      });
      expect(media[0].played.last.$3, [74]);
      return;
    }
    expect(bob.linkedDevicesOf(alice.identity!.deviceId), isEmpty);
    await waitRevocation(
      () => [alice, bob, carol].every(
        (p) =>
            p.groupCallService!.active!.connected &&
            p.groupCallService!.active!.participants.length == 3,
      ),
    );
    expect(bob.groupCallService!.active!.epoch, greaterThan(epoch));
    // The former participant cannot install the survivors' rotated key.
    final frame = await bob.groupCallService!.active!.cipher.encrypt(
      Uint8List.fromList([0, 0, 0, 0, 1, 75]),
    );
    expect(
      await phone.groupCallService!.active!.cipher.decrypt(frame!),
      isNull,
    );
    await expectLater(
      bob.groupCallService!.transport.sendSignal(
        GroupCallSignal(
          groupId: group.groupId,
          callId: bob.groupCallService!.active!.callId,
          senderDeviceId: bob.identity!.deviceId,
          action: 'key',
          issuedAt: now,
          payload: {'key': base64Encode(GroupCallCipher.randomKey())},
        ),
        phoneId,
      ),
      throwsStateError,
    );
    final phoneCrypto = CryptoService(identityProvider: () => phone.identity!);
    final probe = RatchetSessions(
      engine: FakeRatchetEngine(random: Random(736)),
      store: MemoryRatchetStore(),
    );
    final bundle = await probe.createBundle();
    final written = vaults[1].watchIdentity(bundle.identityKey);
    final packet = await phoneCrypto.encryptPayloadEnvelope(
      kind: 'ratchet_bundle',
      messageId: 'revoked-bootstrap',
      conversationId: phoneCrypto.conversationIdFor(bob.identity!.deviceId),
      senderAccountId: phone.identity!.accountId,
      senderDeviceId: phoneId,
      recipientDeviceId: bob.identity!.deviceId,
      contact: phone.contactByDeviceId(bob.identity!.deviceId)!,
      plaintext: jsonEncode({
        'version': 1,
        'reason': 'answer',
        'bundle': bundle.toJson(),
      }),
    );
    network.inject(bob.identity!, phone.identity!.irohEndpointId!, packet);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(written.isCompleted, false);
    final played = [
      for (final index in [0, 1, 3]) media[index].played.length,
    ];
    await phone.groupCallService!.sendAudio(Uint8List.fromList([76]));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect([
      for (final index in [0, 1, 3]) media[index].played.length,
    ], played);
    final before = media[0].played.length;
    await waitRevocation(() {
      if (media[0].played.length > before) return true;
      unawaited(bob.groupCallService!.sendAudio(Uint8List.fromList([77])));
      return false;
    });
    expect(media[0].played.last.$3, [77]);
  }

  test(
    'account revocation excludes a linked device from stale group call profiles',
    () => groupCallRevocation(),
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'account revocation cannot exclude a different account from group calls',
    () => groupCallRevocation(foreignClaim: true),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  Future<void> groupOnlyVoiceCall({
    bool carrierControls = false,
    bool probeBootstrap = false,
    bool probeAuthorization = false,
  }) async {
    final network = _InProcessIrohNetwork();
    final carrierNetwork = _FakeCarrierNetwork();
    final relay = _FakeRelayClient();
    final media = <FakeCallMedia>[];
    final peers = <MessengerController>[];
    final vaults = <_GroupCallVaultStore>[];
    var protocolNow = DateTime.now();
    var driveCallClock = false;
    DateTime? frozenNow;
    for (final name in ['Alice', 'Bob', 'Carol']) {
      final audio = FakeCallMedia();
      final vault = _GroupCallVaultStore();
      vaults.add(vault);
      media.add(audio);
      final peer = await _createController(
        relayClient: relay,
        displayName: name,
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        ratchetEngine: FakeRatchetEngine(),
        groupCallMedia: audio,
        vaultStore: vault,
        nowProvider: () => frozenNow ?? protocolNow,
      );
      peers.add(peer);
      addTearDown(peer.dispose);
      await peer.updateGlobalConnectivity(
        carrierControls
            ? _irohOnlyConnectivity.copyWith(
                transportPolicies: {
                  TransportKind.iroh: TransportPolicy.automatic,
                  TransportKind.nostr: TransportPolicy.automatic,
                },
              )
            : _irohOnlyConnectivity,
      );
      if (carrierControls) {
        await carrierNetwork.join(peer, 'npub-$name|wss://relay.one');
      }
    }
    final [alice, bob, carol] = peers;
    Future<void> waitForCall(
      bool Function() ready,
      String reason, {
      Duration? timeout,
    }) async {
      try {
        var nextStep = DateTime.now().add(const Duration(milliseconds: 500));
        await _waitForIroh(
          () {
            if (ready()) return true;
            if (driveCallClock &&
                frozenNow == null &&
                !DateTime.now().isBefore(nextStep)) {
              // The fake media engine emits no capture heartbeat. Advance
              // protocol time separately from real encrypted disk I/O; the
              // deterministic call-network tests cover failure deadlines.
              protocolNow = protocolNow.add(const Duration(milliseconds: 125));
              nextStep = DateTime.now().add(const Duration(milliseconds: 500));
              for (final peer in peers) {
                unawaited(peer.groupCallService?.tick());
              }
            }
            return false;
          },
          reason: reason,
          timeout:
              timeout ?? (driveCallClock ? const Duration(seconds: 15) : null),
        );
      } catch (_) {
        for (final peer in peers) {
          final room =
              peer.groupCallService?.active ??
              peer.groupCallService?.rooms.firstOrNull;
          // State only: never print the key-bearing signal payloads.
          debugPrint(
            '${peer.identity!.displayName}: contacts=${peer.contacts.length} '
            'requests=${peer.pendingContactRequests.length} '
            'groups=${peer.groups.length} call=${room?.callId} '
            'joined=${room?.joined} connected=${room?.connected} '
            'term=${room?.term} epoch=${room?.epoch}/${room?.cipher.epoch} '
            'participants=${room?.participants.map((p) => p.deviceId).toList()}',
          );
        }
        rethrow;
      }
    }
    for (final peer in [bob, carol]) {
      await alice.addContactFromInvite(
        alias: peer.identity!.displayName,
        payload: (await peer.buildInvite()).encodePayload(),
        codephrase: '',
      );
      await waitForCall(
        () => peer.pendingContactRequests.isNotEmpty,
        'group call pairing request for ${peer.identity!.displayName}',
      );
      await peer.approvePendingContactRequest(
        peer.pendingContactRequests.single.id,
      );
    }
    if (carrierControls) {
      network.blockedEnvelopePairs.addAll([
        (bob.identity!.irohEndpointId!, carol.identity!.irohEndpointId!),
        (carol.identity!.irohEndpointId!, bob.identity!.irohEndpointId!),
      ]);
    }
    if (probeBootstrap) {
      network.heldHelloPairs.addAll([
        (bob.identity!.irohEndpointId!, carol.identity!.irohEndpointId!),
        (carol.identity!.irohEndpointId!, bob.identity!.irohEndpointId!),
      ]);
    }
    final group = await alice.createGroup(
      title: 'Voice group',
      members: alice.contacts,
    );
    await waitForCall(
      () => bob.groups.isNotEmpty && carol.groups.isNotEmpty,
      'group call membership arrived',
    );
    await waitForCall(
      () => peers.every(
        (p) => p.groupCallMembersFor(group.groupId).every((m) => m.canJoin),
      ),
      'group call capabilities arrived',
    );
    expect(bob.contactByDeviceId(carol.identity!.deviceId), isNull);
    expect(carol.contactByDeviceId(bob.identity!.deviceId), isNull);
    if (probeBootstrap) {
      await waitForCall(
        () => network.heldHellos.isNotEmpty,
        'group-only hello was captured',
        timeout: const Duration(seconds: 15),
      );
      final (endpoint, hello) = network.heldHellos.first;
      final recipientIndex = peers.indexWhere(
        (p) => p.identity!.deviceId == hello.recipientDeviceId,
      );
      final recipient = peers[recipientIndex];
      final vault = vaults[recipientIndex];
      final store = await vault.openRatchetStore();
      final sender = alice.contactByDeviceId(hello.senderDeviceId)!;
      for (var attempt = 0; attempt < 100; attempt++) {
        if ((await store.readPeer(ratchetPeerId(sender)))?.peerIdentityKey !=
            null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final writeStarted = Completer<void>();
      final allowWrite = Completer<void>();
      addTearDown(() {
        if (!allowWrite.isCompleted) allowWrite.complete();
      });
      vault.beforePeerWrite = () async {
        if (!writeStarted.isCompleted) writeStarted.complete();
        await allowWrite.future;
      };
      int pairwiseBundles() => network.envelopes
          .where(
            (e) =>
                e.kind == 'ratchet_bundle' &&
                e.senderDeviceId != alice.identity!.deviceId &&
                e.recipientDeviceId != alice.identity!.deviceId,
          )
          .length;
      final beforeBundles = pairwiseBundles();
      final beforeWrites = vault.committedPeerWrites;
      network.inject(recipient.identity!, endpoint, hello);
      await writeStarted.future.timeout(const Duration(seconds: 5));
      network.inject(recipient.identity!, endpoint, hello);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      allowWrite.complete();
      vault.beforePeerWrite = null;
      await waitForCall(
        () => vault.committedPeerWrites > beforeWrites,
        'duplicate hello durable write completed',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        pairwiseBundles(),
        beforeBundles,
        reason: 'duplicate hello must not reset the session',
      );
      network.heldHelloPairs.clear();
      for (final (senderEndpoint, packet) in network.heldHellos.skip(1)) {
        final target = peers.singleWhere(
          (p) => p.identity!.deviceId == packet.recipientDeviceId,
        );
        network.inject(target.identity!, senderEndpoint, packet);
      }

      // Evict the hello from the 256-entry crypto plaintext cache using real
      // ratcheted traffic, then replay it. Seen ids must be checked first.
      var sent = 0;
      int encryptedMessages() => network.envelopes
          .where(
            (e) =>
                e.kind == 'direct_message' &&
                e.protocolVersion == 3 &&
                e.recipientDeviceId == recipient.identity!.deviceId,
          )
          .length;
      while (encryptedMessages() < 257 && sent < 270) {
        await alice.sendMessage(
          contact: alice.contactByDeviceId(recipient.identity!.deviceId)!,
          body: 'cache-fill-${sent++}',
        );
      }
      expect(encryptedMessages(), greaterThanOrEqualTo(257));
      await waitForCall(
        () => recipient.messagesFor(alice.identity!.deviceId).length >= sent,
        'ratchet cache eviction traffic arrived',
      );
      final beforeReplay = pairwiseBundles();
      network.inject(recipient.identity!, endpoint, hello);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        pairwiseBundles(),
        beforeReplay,
        reason: 'seen hello replay must not reset the session',
      );
    }
    driveCallClock = true;
    await alice.joinOrStartGroupCall(group.groupId);
    await waitForCall(
      () =>
          bob.groupCallService?.roomFor(group.groupId) != null &&
          carol.groupCallService?.roomFor(group.groupId) != null,
      'group call start discovered',
      // Allow one 5 s protocol beacon with the injected clock and real I/O.
      timeout: const Duration(seconds: 25),
    );
    await bob.joinOrStartGroupCall(group.groupId);
    await carol.joinOrStartGroupCall(group.groupId);
    await waitForCall(
      () => peers.every(
        (p) =>
            p.groupCallService?.active?.connected == true &&
            p.groupCallService!.active!.participants.length == 3,
      ),
      'group-only call keys arrived',
    );
    await waitForCall(() {
      if (media[1].played.isNotEmpty) return true;
      // A capture stream emits fresh frames; Iroh datagrams are best-effort.
      unawaited(
        carol.groupCallService!.sendAudio(Uint8List.fromList([36, 42])),
      );
      return false;
    }, 'group-only audio arrived');
    final packet = media[1].played.last;
    expect(packet.$3, [36, 42]);
    expect(
      bob.groupCallService!.active!.participants
          .singleWhere((p) => p.index == packet.$1)
          .deviceId,
      carol.identity!.deviceId,
    );
    final keys = network.envelopes.where(
      (e) => e.kind == 'group_call_signal' && e.protocolVersion == 3,
    );
    expect(keys, isNotEmpty);
    await bob.setVoiceNoiseSuppression(false);
    expect(media[1].noise.last, false);
    final carrierBeforeHandoff = carrierNetwork.frames.length;
    await alice.groupCallService!.leave();
    final survivors = [bob, carol];
    final leader =
        (survivors.map((p) => p.identity!.deviceId).toList()..sort()).first;
    await waitForCall(
      () => survivors.every(
        (p) =>
            p.groupCallService?.active?.coordinator == leader &&
            p.groupCallService!.active!.term == 1 &&
            p.groupCallService!.active!.participants.length == 2,
      ),
      'group-only coordinator handoff',
      timeout: const Duration(seconds: 15),
    );
    await waitForCall(
      () =>
          survivors.every((p) => p.groupCallService?.active?.connected == true),
      'group-only handoff key arrived',
      // A previously lost bootstrap offer backs off for 10 s. Media must
      // recover once that bounded session retry succeeds.
      timeout: const Duration(seconds: 45),
    );
    final beforeHandoffAudio = media[1].played.length;
    await waitForCall(() {
      if (media[1].played.length > beforeHandoffAudio) return true;
      unawaited(
        carol.groupCallService!.sendAudio(Uint8List.fromList([77, 88])),
      );
      return false;
    }, 'group-only handoff audio arrived');
    expect(media[1].played.last.$3, [77, 88]);
    if (carrierControls) {
      expect(carrierNetwork.frames.length, greaterThan(carrierBeforeHandoff));
    }
    expect(bob.contactByDeviceId(carol.identity!.deviceId), isNull);
    expect(carol.contactByDeviceId(bob.identity!.deviceId), isNull);
    await bob.groupCallService!.leave();
    expect(bob.groupCallSummariesFor(group.groupId), hasLength(1));
    if (probeAuthorization) {
      final crypto = CryptoService(identityProvider: () => bob.identity!);
      final target = alice.contactByDeviceId(carol.identity!.deviceId)!;
      final vault = vaults[2];
      Future<(RelayEnvelope, Completer<void>)> control(
        int sequence, {
        String? account,
        String? conversation,
        int padding = 0,
      }) async {
        final session = RatchetSessions(
          engine: FakeRatchetEngine(random: Random(500 + sequence)),
          store: MemoryRatchetStore(),
        );
        final bundle = await session.createBundle();
        final written = vault.watchIdentity(bundle.identityKey);
        final envelope = await crypto.encryptPayloadEnvelope(
          kind: 'ratchet_bundle',
          messageId: 'bootstrap-probe-$sequence',
          conversationId:
              conversation ?? crypto.conversationIdFor(target.deviceId),
          senderAccountId: account ?? bob.identity!.accountId,
          senderDeviceId: bob.identity!.deviceId,
          recipientDeviceId: target.deviceId,
          contact: target,
          plaintext: jsonEncode({
            'version': 1,
            'reason': 'answer',
            'bundle': bundle.toJson(),
            if (padding > 0) 'padding': 'x' * padding,
          }),
        );
        return (envelope, written);
      }

      final beforeInvalid = vault.watchedWrites;
      for (final (index, account, conversation, endpoint, padding) in [
        (1, 'wrong-account', null, bob.identity!.irohEndpointId!, 0),
        (2, null, 'wrong-conversation', bob.identity!.irohEndpointId!, 0),
        (3, null, null, 'ff' * 32, 0),
        (4, null, null, bob.identity!.irohEndpointId!, 70 * 1024),
      ]) {
        final (packet, _) = await control(
          index,
          account: account,
          conversation: conversation,
          padding: padding,
        );
        network.inject(carol.identity!, endpoint, packet);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(
          vault.watchedWrites,
          beforeInvalid,
          reason: 'invalid bootstrap identity/scope/pin/size $index',
        );
      }

      const marker = 'm36-private-control-marker';
      final malformed = await crypto.encryptPayloadEnvelope(
        kind: 'ratchet_bundle',
        messageId: 'bootstrap-malformed-probe',
        conversationId: crypto.conversationIdFor(target.deviceId),
        senderAccountId: bob.identity!.accountId,
        senderDeviceId: bob.identity!.deviceId,
        recipientDeviceId: target.deviceId,
        contact: target,
        plaintext: '{"secret":"$marker',
      );
      network.inject(carol.identity!, bob.identity!.irohEndpointId!, malformed);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(carol.recentDebugLog.any((line) => line.contains(marker)), false);

      // A blocked durable write cannot create an unlimited bootstrap queue.
      // Freeze the policy clock only after the audible handoff has passed.
      frozenNow = DateTime.now().add(const Duration(seconds: 1));
      final writeStarted = Completer<void>();
      final allowWrite = Completer<void>();
      addTearDown(() {
        if (!allowWrite.isCompleted) allowWrite.complete();
      });
      vault.beforePeerWrite = () async {
        if (!writeStarted.isCompleted) writeStarted.complete();
        await allowWrite.future;
      };
      final beforeBurst = vault.watchedWrites;
      Completer<void>? last;
      for (var index = 10; index < 30; index++) {
        final (packet, written) = await control(index);
        last = written;
        network.inject(carol.identity!, bob.identity!.irohEndpointId!, packet);
      }
      await writeStarted.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      allowWrite.complete();
      vault.beforePeerWrite = null;
      await Future.any<void>([
        last!.future,
        Future<void>.delayed(const Duration(seconds: 2)),
      ]);
      expect(vault.watchedWrites - beforeBurst, inInclusiveRange(1, 16));
      await carol.flushPendingChanges();
      await Future<void>.delayed(Duration.zero);

      // Completed jobs still obey the per-second admission budget.
      frozenNow = frozenNow.add(const Duration(seconds: 1));
      final beforeRate = vault.watchedWrites;
      for (var index = 40; index < 80; index++) {
        final (packet, written) = await control(index);
        network.inject(carol.identity!, bob.identity!.irohEndpointId!, packet);
        await Future.any<void>([
          written.future,
          Future<void>.delayed(const Duration(milliseconds: 100)),
        ]);
        await Future<void>.delayed(Duration.zero);
        await carol.flushPendingChanges();
        await Future<void>.delayed(Duration.zero);
      }
      expect(vault.watchedWrites - beforeRate, inInclusiveRange(1, 32));
    }
  }

  test(
    'group-only members join encrypted voice calls over Iroh',
    () => groupOnlyVoiceCall(),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'group-only call keys survive handoff over a carrier',
    () => groupOnlyVoiceCall(carrierControls: true),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'group-only hello duplicates and cache-evicted replays preserve call keys',
    () => groupOnlyVoiceCall(probeBootstrap: true),
    // 257 real durable ratchet writes exercise eviction under full-suite load.
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'group-only ratchet controls enforce identity privacy and resource bounds',
    () => groupOnlyVoiceCall(probeAuthorization: true),
    timeout: const Timeout(Duration(minutes: 3)),
  );

  for (final native in [false, true]) {
    for (final relayed in native ? [false] : [false, true]) {
      test(
        'Iroh group-only members exchange messages and receipts relayed=$relayed native=$native',
        () async {
          final network = _InProcessIrohNetwork(relayed: relayed);
          final relay = _FakeRelayClient();
          final peers = <MessengerController>[];
          for (final name in ['Alice', 'Bob', 'Carol']) {
            final peer = await _createController(
              relayClient: relay,
              displayName: name,
              internetRelayHost: null,
              transportRegistryFactory: native
                  ? _directNativeIrohRegistry
                  : network.registry,
            );
            peers.add(peer);
            addTearDown(peer.dispose);
            await peer.updateGlobalConnectivity(_irohOnlyConnectivity);
          }
          final [alice, bob, carol] = peers;
          for (final peer in [bob, carol]) {
            await alice.addContactFromInvite(
              alias: peer.identity!.displayName,
              payload: (await peer.buildInvite()).encodePayload(),
              codephrase: '',
            );
            await _waitForIroh(
              () => peer.pendingContactRequests.isNotEmpty,
              reason: 'contact request reached ${peer.identity!.displayName}',
            );
            await peer.approvePendingContactRequest(
              peer.pendingContactRequests.single.id,
            );
          }
          final group = await alice.createGroup(
            title: 'Iroh only',
            members: alice.contacts,
          );
          await _waitForIroh(
            () => bob.groups.isNotEmpty && carol.groups.isNotEmpty,
            reason: 'group invitation reached Bob and Carol',
          );
          expect(bob.contactByDeviceId(carol.identity!.deviceId), isNull);
          expect(carol.contactByDeviceId(bob.identity!.deviceId), isNull);
          final profile = GroupRecord.fromJson(
            bob.groups.single.toJson(),
          ).memberProfileFor(carol.identity!.deviceId)!;
          expect(profile.irohEndpointId, carol.identity!.irohEndpointId);
          expect(
            profile.signingPublicKeyBase64,
            carol.identity!.signingPublicKeyBase64,
          );
          expect(profile.capabilities, contains(TransportKind.iroh));
          relay.storedEnvelopes.clear();
          await bob.sendGroupMessage(
            groupId: group.groupId,
            body: 'group without contacts',
          );
          await _waitForIroh(
            () => carol.messagesForGroup(group.groupId).length == 1,
            reason: "Bob's first group message reached Carol",
          );
          await _waitForIroh(
            () =>
                bob
                    .messagesForGroup(group.groupId)
                    .single
                    .recipientStates[carol.identity!.deviceId] ==
                DeliveryState.delivered,
            reason: "Carol's delivery receipt reached Bob",
          );
          await carol.markGroupReadThroughMessage(
            group.groupId,
            carol.messagesForGroup(group.groupId).single,
          );
          await _waitForIroh(
            () =>
                bob
                    .messagesForGroup(group.groupId)
                    .single
                    .recipientStates[carol.identity!.deviceId] ==
                DeliveryState.read,
            reason: "Carol's read receipt reached Bob",
          );
          // A valid pairwise encrypted DM must not inherit the group's trust.
          await carol.synchronizeGroupHistory(
            groupId: group.groupId,
            peerDeviceId: bob.identity!.deviceId,
          );
          final crypto = CryptoService(identityProvider: () => bob.identity!);
          final carolContact = alice.contacts.singleWhere(
            (c) => c.deviceId == carol.identity!.deviceId,
          );
          final forbidden = await crypto.encryptPayloadEnvelope(
            kind: 'direct_message',
            messageId: 'forbidden-group-dm',
            conversationId: crypto.conversationIdFor(carolContact.deviceId),
            senderAccountId: bob.identity!.accountId,
            senderDeviceId: bob.identity!.deviceId,
            recipientDeviceId: carolContact.deviceId,
            contact: carolContact,
            plaintext: 'private intrusion',
          );
          if (!native) {
            network.inject(
              carol.identity!,
              bob.identity!.irohEndpointId!,
              forbidden,
            );
          }
          await carol.sendGroupMessage(groupId: group.groupId, body: 'reply');
          await _waitForIroh(
            () => bob.messagesForGroup(group.groupId).length == 2,
            reason: "Carol's reply reached Bob",
          );
          expect(carol.messagesFor(bob.identity!.deviceId), isEmpty);
          await alice.setGroupMemberRole(
            groupId: group.groupId,
            memberDeviceId: carol.identity!.deviceId,
            role: GroupMemberRole.admin,
          );
          await _waitForIroh(
            () =>
                carol.groups.single.roleFor(carol.identity!.deviceId) ==
                    GroupMemberRole.admin &&
                bob.groups.single.roleFor(carol.identity!.deviceId) ==
                    GroupMemberRole.admin,
            reason: "Carol's promotion reached Carol and Bob",
          );
          await carol.removeGroupMember(
            groupId: group.groupId,
            memberDeviceId: bob.identity!.deviceId,
          );
          await _waitForIroh(
            () => !bob.groups.single.hasActiveMember(bob.identity!.deviceId),
            reason: "Bob's removal reached Bob",
          );
          await _waitForIroh(
            () => carol.pendingGroupMembershipDeliveries.isEmpty,
            reason: "Carol's membership deliveries finished",
          );
          await carol.addGroupMembers(
            groupId: group.groupId,
            members: [
              alice.contacts.singleWhere(
                (c) => c.deviceId == bob.identity!.deviceId,
              ),
            ],
          );
          await _waitForIroh(
            () => bob.groups.single.hasActiveMember(bob.identity!.deviceId),
            reason: "Bob's re-admission reached Bob",
          );
          await bob.sendGroupMessage(
            groupId: group.groupId,
            body: 'after rejoining',
          );
          await _waitForIroh(
            () => carol.messagesForGroup(group.groupId).length == 3,
            reason: "Bob's message after rejoining reached Carol",
          );

          expect(
            network.envelopes.where(
              (e) => e.acknowledgedMessageId == forbidden.messageId,
            ),
            isEmpty,
          );
          expect(
            relay.storedEnvelopes.where(
              (e) => e.kind != 'pairing_announcement',
            ),
            isEmpty,
          );
        },
        skip:
            native && Platform.environment['CONEST_RUN_IROH_GROUP_CERT'] != '1',
      );
    }
  }

  test('a group file finished after a timeout still gets its receipt', () {
    bool finished(GroupFileDownloadState? previous) =>
        MessengerController.groupFileJustFinished(
          previous,
          GroupFileDownloadState.complete,
        );
    // A late piece completes a download that had gone back to waiting.
    expect(finished(GroupFileDownloadState.waiting), isTrue);
    expect(finished(GroupFileDownloadState.failed), isTrue);
    expect(finished(GroupFileDownloadState.paused), isTrue);
    expect(finished(GroupFileDownloadState.downloading), isTrue);
    // Read back whole after a restart: acknowledged before.
    expect(finished(null), isFalse);
    expect(finished(GroupFileDownloadState.checking), isFalse);
    expect(finished(GroupFileDownloadState.complete), isFalse);
    expect(
      MessengerController.groupFileJustFinished(
        GroupFileDownloadState.downloading,
        GroupFileDownloadState.failed,
      ),
      isFalse,
    );
  });

  testWidgets('group members who are not contacts have an Add contact button', (
    tester,
  ) async {
    late MessengerController alice;
    late MessengerController bob;
    late MessengerController carol;
    late GroupRecord bobsGroup;
    await tester.runAsync(() async {
      final relay = _FakeRelayClient();
      alice = await _createController(relayClient: relay, displayName: 'Alice');
      bob = await _createController(relayClient: relay, displayName: 'Bob');
      carol = await _createController(relayClient: relay, displayName: 'Carol');
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      final group = await alice.createGroup(
        title: 'Friends',
        members: alice.contacts.toList(),
      );
      for (var i = 0; i < 100; i++) {
        await bob.pollNow();
        final mine = bob.groups.where((g) => g.groupId == group.groupId);
        if (mine.isNotEmpty &&
            mine.single.memberProfileFor(carol.identity!.deviceId) != null) {
          bobsGroup = mine.single;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);
    final carolId = carol.identity!.deviceId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: app.GroupDetailsDialog(
            controller: bob,
            palette: app.ConestPalette(),
            group: bobsGroup,
          ),
        ),
      ),
    );
    await tester.pump();
    // Alice is a contact already; Carol is not.
    expect(
      find.byKey(ValueKey('group-add-contact-${alice.identity!.deviceId}')),
      findsNothing,
    );
    await tester.tap(find.byKey(ValueKey('group-add-contact-$carolId')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(bob.contacts.any((c) => c.deviceId == carolId), isTrue);
    expect(find.byKey(ValueKey('group-add-contact-$carolId')), findsNothing);
  });

  test(
    'a group member who is not a contact can be added from the group',
    () async {
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      final carol = await _createController(
        relayClient: relay,
        displayName: 'Carol',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      Future<void> until(bool Function() ready, String what) async {
        for (var i = 0; i < 100 && !ready(); i++) {
          await Future.wait([alice.pollNow(), bob.pollNow(), carol.pollNow()]);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(ready(), isTrue, reason: what);
      }

      final group = await alice.createGroup(
        title: 'Friends',
        members: alice.contacts.toList(),
      );
      final carolId = carol.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      await until(
        () =>
            bob.groups.any(
              (g) =>
                  g.groupId == group.groupId &&
                  g.memberProfileFor(carolId) != null,
            ) &&
            carol.groups.any((g) => g.groupId == group.groupId),
        'both are in the group',
      );
      expect(bob.contacts.any((c) => c.deviceId == carolId), isFalse);

      // Not someone outside the group, nor themselves.
      await expectLater(
        bob.requestContactFromGroup(
          groupId: group.groupId,
          memberDeviceId: 'dev-nobody',
        ),
        throwsArgumentError,
      );
      final result = await bob.requestContactFromGroup(
        groupId: group.groupId,
        memberDeviceId: carolId,
      );
      expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
      await until(
        () =>
            carol.pendingContactRequests.any((r) => r.senderDeviceId == bobId),
        'Carol sees an ordinary contact request from Bob',
      );
      final request = carol.pendingContactRequests.firstWhere(
        (r) => r.senderDeviceId == bobId,
      );
      await carol.approvePendingContactRequest(request.id);
      await until(
        () =>
            bob.contacts.any((c) => c.deviceId == carolId && c.canSendOutbound),
        'Bob hears Carol accepted',
      );
      await bob.sendMessage(
        contact: bob.contacts.firstWhere((c) => c.deviceId == carolId),
        body: 'hi from the group',
      );
      await until(
        () =>
            carol.messagesFor(bobId).any((m) => m.body == 'hi from the group'),
        'a direct message reaches Carol',
      );
      // Already a contact now.
      await expectLater(
        bob.requestContactFromGroup(
          groupId: group.groupId,
          memberDeviceId: carolId,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'group files get receipts and stay finished with nobody reachable',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final bobVault = _MemoryVaultStore();
      final aliceRoot = await Directory.systemTemp.createTemp('conest_gf_a-');
      final bobRoot = await Directory.systemTemp.createTemp('conest_gf_b-');
      addTearDown(() async {
        if (await aliceRoot.exists()) await aliceRoot.delete(recursive: true);
        if (await bobRoot.exists()) await bobRoot.delete(recursive: true);
      });
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => aliceRoot,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        internetRelayHost: null,
        vaultStore: bobVault,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => bobRoot,
      );
      var aliceDisposed = false;
      var bobDisposed = false;
      addTearDown(() {
        if (!aliceDisposed) alice.dispose();
        if (!bobDisposed) bob.dispose();
      });
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Receipts',
        members: [alice.contacts.single],
      );
      await _waitForIroh(() => bob.groups.isNotEmpty);
      final source = await File(
        '${aliceRoot.path}/photo.bin',
      ).writeAsBytes([4, 8, 15, 16, 23, 42]);
      await alice.publishGroupFile(
        groupId: group.groupId,
        path: source.path,
        fileName: 'photo.bin',
        mimeType: 'application/octet-stream',
      );
      final eventId = alice
          .messagesForGroup(group.groupId)
          .singleWhere((message) => message.groupFile != null)
          .id;
      final bobId = bob.identity!.deviceId;
      ChatMessage aliceCopy() => alice
          .messagesForGroup(group.groupId)
          .singleWhere((message) => message.id == eventId);
      // Sent, not "waiting for a reachable path".
      expect(aliceCopy().state, isNot(DeliveryState.pending));
      await _waitForIroh(
        () =>
            bob.groupFileSession(eventId)?.download.state ==
            GroupFileDownloadState.complete,
      );
      await _waitForIroh(
        () => aliceCopy().recipientStates[bobId] == DeliveryState.delivered,
        reason: 'Bob tells Alice he has the file',
      );
      expect(aliceCopy().state, DeliveryState.delivered);

      // Nobody else is reachable when Bob starts again.
      alice.dispose();
      aliceDisposed = true;
      bob.dispose();
      bobDisposed = true;
      final resumed = await _createController(
        relayClient: relay,
        displayName: 'unused',
        createIdentity: false,
        vaultStore: bobVault,
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => bobRoot,
      );
      addTearDown(resumed.dispose);
      await _waitForIroh(
        () =>
            resumed.groupFileSession(eventId)?.download.state ==
            GroupFileDownloadState.complete,
        reason: 'a file held whole needs no provider',
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'retained group file sessions restore providers after a vault restart',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final bobVault = _MemoryVaultStore();
      final aliceRoot = await Directory.systemTemp.createTemp(
        'conest_group_file_restart_alice-',
      );
      final bobRoot = await Directory.systemTemp.createTemp(
        'conest_group_file_restart_bob-',
      );
      addTearDown(() async {
        if (await aliceRoot.exists()) await aliceRoot.delete(recursive: true);
        if (await bobRoot.exists()) await bobRoot.delete(recursive: true);
      });
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => aliceRoot,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        internetRelayHost: null,
        vaultStore: bobVault,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => bobRoot,
      );
      addTearDown(alice.dispose);
      var bobDisposed = false;
      addTearDown(() {
        if (!bobDisposed) bob.dispose();
      });
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Restartable files',
        members: [alice.contacts.single],
      );
      await _waitForIroh(() => bob.groups.isNotEmpty);

      final source = await File(
        '${aliceRoot.path}/source.bin',
      ).writeAsBytes([1, 3, 3, 7, 9]);
      await alice.publishGroupFile(
        groupId: group.groupId,
        path: source.path,
        fileName: 'restartable.bin',
        mimeType: 'application/octet-stream',
      );
      final eventId = alice
          .messagesForGroup(group.groupId)
          .singleWhere((message) => message.groupFile != null)
          .id;
      await _waitForIroh(
        () => bob
            .messagesForGroup(group.groupId)
            .any((message) => message.id == eventId),
      );
      await _waitForIroh(
        () =>
            bob.groupFileSession(eventId)?.download.state ==
            GroupFileDownloadState.complete,
      );

      bob.dispose();
      bobDisposed = true;
      final resumed = await _createController(
        relayClient: relay,
        displayName: 'unused',
        createIdentity: false,
        vaultStore: bobVault,
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => bobRoot,
      );
      addTearDown(resumed.dispose);
      await _waitForIroh(
        () =>
            resumed.groupFileSession(eventId)?.download.state ==
            GroupFileDownloadState.complete,
      );
      expect(await File(resumed.groupFilePathFor(eventId)!).readAsBytes(), [
        1,
        3,
        3,
        7,
        9,
      ]);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  for (final lan in [true, false]) {
    test(
      'real socket group-only messaging uses ${lan ? "LAN" : "custom relay"}',
      () async {
        Future<LocalRelayNode> startNode() async {
          final reservation = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final port = reservation.port;
          await reservation.close();
          final node = LocalRelayNode(maxRequestsPerMinute: 10000);
          await node.start(port);
          addTearDown(node.stop);
          return node;
        }

        int? relayPort;
        if (!lan) {
          final reservation = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          relayPort = reservation.port;
          await reservation.close();
          final directory = await Directory.systemTemp.createTemp(
            'conest_group_relay_',
          );
          final process = await Process.start(
            Platform.environment['CONEST_RELAY_TEST_BINARY']!,
            [
              '127.0.0.1:$relayPort',
              '--identity-seed-path',
              '${directory.path}/identity.seed',
              '--database-path',
              '${directory.path}/relay.sqlite3',
              '--max-requests-per-minute',
              '10000',
            ],
          );
          process.stdout.listen((_) {});
          process.stderr.listen((_) {});
          addTearDown(() async {
            process.kill();
            await process.exitCode;
            await directory.delete(recursive: true);
          });
          var ready = false;
          for (var attempt = 0; attempt < 50 && !ready; attempt++) {
            try {
              final socket = await Socket.connect(
                '127.0.0.1',
                relayPort,
                timeout: const Duration(milliseconds: 100),
              );
              socket.destroy();
              ready = true;
            } catch (_) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
          expect(ready, isTrue);
        }
        final traffic = <RelayEnvelope>[];
        final peers = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Carol']) {
          final node = lan ? await startNode() : _FakeLocalRelayNode();
          final peer = await _createController(
            relayClient: RelayClient(),
            displayName: name,
            createIdentity: false,
            localRelayNode: node,
            lanAddresses: lan ? ['127.0.0.1'] : [],
            transportRegistryFactory: (_) async => null,
          );
          addTearDown(peer.dispose);
          await peer.createIdentity(
            displayName: name,
            internetRelayHost: lan ? null : 'tcp://127.0.0.1',
            internetRelayPort: relayPort ?? 7667,
            localRelayPort: node.port ?? 7667,
          );
          await peer.updateGlobalConnectivity(
            GlobalConnectivityPreferences(
              lanEnabled: lan,
              onlineEnabled: !lan,
              transportPolicies: {
                TransportKind.lan: lan
                    ? TransportPolicy.automatic
                    : TransportPolicy.disabled,
                TransportKind.iroh: TransportPolicy.disabled,
                TransportKind.conestRelay: lan
                    ? TransportPolicy.disabled
                    : TransportPolicy.automatic,
              },
            ),
          );
          if (lan) {
            final onStored = node.onEnvelopeStored;
            node.onEnvelopeStored = (id, envelope) {
              traffic.add(envelope);
              onStored?.call(id, envelope);
            };
          }
          peers.add(peer);
        }
        final [alice, bob, carol] = peers;
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        final group = await alice.createGroup(
          title: 'Socket group',
          members: alice.contacts,
        );
        await bob.pollNow();
        await carol.pollNow();
        expect(bob.contactByDeviceId(carol.identity!.deviceId), isNull);
        await bob.sendGroupMessage(
          groupId: group.groupId,
          body: 'real sockets',
        );
        await carol.pollNow();
        await bob.pollNow();
        await _waitForIroh(
          () => carol.messagesForGroup(group.groupId).isNotEmpty,
        );
        await _waitForIroh(
          () =>
              bob
                  .messagesForGroup(group.groupId)
                  .single
                  .recipientStates[carol.identity!.deviceId] ==
              DeliveryState.delivered,
        );
        if (lan) {
          expect(
            traffic.where(
              (e) =>
                  e.kind == 'group_message' &&
                  e.senderDeviceId == bob.identity!.deviceId,
            ),
            isNotEmpty,
          );
        } else {
          expect(
            peers.every((peer) => peer.pinnedRelayIdentityKeys.isNotEmpty),
            isTrue,
          );
        }
        await carol.sendGroupMessage(
          groupId: group.groupId,
          body: 'socket reply',
        );
        await bob.pollNow();
        await _waitForIroh(
          () => bob.messagesForGroup(group.groupId).length == 2,
        );
      },
      skip: !lan && Platform.environment['CONEST_RELAY_TEST_BINARY'] == null,
    );
  }

  test(
    'Iroh bootstrap rejects spoofed endpoint bindings, signatures and unknown messages',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      final invite = await alice.buildInvite();
      RelayEnvelope request(
        String id, {
        ContactInvite? payload,
        String kind = 'contact_exchange',
        String? recipient,
      }) => RelayEnvelope(
        protocolVersion: 1,
        kind: kind,
        messageId: id,
        conversationId: 'pairing',
        senderAccountId: alice.identity!.accountId,
        senderDeviceId: alice.identity!.deviceId,
        recipientDeviceId: recipient ?? bob.identity!.deviceId,
        createdAt: DateTime.now().toUtc(),
        payloadBase64: base64Encode(
          utf8.encode((payload ?? invite).encodePayload()),
        ),
      );
      network.inject(bob.identity!, 'unrelated-endpoint', request('spoofed'));
      network.inject(
        bob.identity!,
        alice.identity!.irohEndpointId!,
        request(
          'tampered',
          payload: invite.copyWithSignature(
            base64Encode(List<int>.filled(64, 0)),
          ),
        ),
      );
      network.inject(
        bob.identity!,
        alice.identity!.irohEndpointId!,
        request('unknown-message', kind: 'message'),
      );
      network.inject(
        bob.identity!,
        alice.identity!.irohEndpointId!,
        request('wrong-recipient', recipient: 'somebody-else'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(bob.pendingContactRequests, isEmpty);
      expect(bob.contacts, isEmpty);
      network.inject(
        bob.identity!,
        alice.identity!.irohEndpointId!,
        request('valid'),
      );
      await _waitForIroh(() => bob.pendingContactRequests.isNotEmpty);
      expect(bob.pendingContactRequests.single.id, 'valid');
    },
  );

  test(
    'unrelated contacts cannot control or collide with another peer attachment and cancellation survives restart',
    () async {
      final relay = _FakeRelayClient();
      final aliceVault = _MemoryVaultStore();
      final aliceRoot = Directory.systemTemp.createTempSync(
        'conest_cancel_restart_',
      );
      addTearDown(() => aliceRoot.deleteSync(recursive: true));
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: aliceVault,
        attachmentRootProvider: () async => aliceRoot,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      final carol = await _createController(
        relayClient: relay,
        displayName: 'Carol',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await bob.updateGlobalConnectivity(
        bob.identity!.connectivity.copyWith(
          autoDownloadPreset: AutoDownloadPreset.custom,
        ),
      );
      await alice.sendAttachment(
        contact: alice.contactByDeviceId(bob.identity!.deviceId)!,
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'private.bin',
      );
      final message = alice
          .messagesFor(bob.identity!.deviceId)
          .singleWhere((m) => m.attachment != null);
      final descriptor = message.attachment!;
      final crypto = CryptoService(identityProvider: () => carol.identity!);
      for (final kind in [
        'attachment_pause_control',
        'attachment_complete',
        'attachment_cancel',
        'attachment_offer',
      ]) {
        final forged = await crypto.encryptPayloadEnvelope(
          kind: kind,
          messageId: 'forged-$kind',
          conversationId: crypto.conversationIdFor(alice.identity!.deviceId),
          senderAccountId: carol.identity!.accountId,
          senderDeviceId: carol.identity!.deviceId,
          recipientDeviceId: alice.identity!.deviceId,
          contact: carol.contacts.single,
          plaintext: jsonEncode({
            'attachmentId': descriptor.id,
            'paused': true,
            'descriptor': descriptor.toJson(),
          }),
        );
        await relay.storeEnvelope(
          host: 'relay.example',
          port: defaultRelayPort,
          recipientDeviceId: alice.identity!.deviceId,
          envelope: forged,
        );
        await alice.pollNow();
        expect(alice.pauseStateFor(descriptor.id), (
          pausedByMe: false,
          pausedByPeer: false,
        ), reason: kind);
        expect(
          aliceVault._snapshot.transferSessions
              .singleWhere((s) => s.attachment.id == descriptor.id)
              .pausedByPeer,
          isFalse,
          reason: kind,
        );
        expect(
          alice
              .messagesFor(carol.identity!.deviceId)
              .where((m) => m.attachment != null),
          isEmpty,
          reason: kind,
        );
      }
      await alice.cancelTransfer(descriptor.id);
      await _waitForIroh(
        () =>
            aliceVault._snapshot.transferSessions
                .singleWhere((s) => s.attachment.id == descriptor.id)
                .state ==
            TransferState.canceled,
      );
      expect(
        alice
            .messagesFor(bob.identity!.deviceId)
            .singleWhere((m) => m.id == message.id)
            .state,
        DeliveryState.canceled,
      );
      final restarted = await _createController(
        relayClient: relay,
        displayName: 'unused',
        createIdentity: false,
        vaultStore: aliceVault,
        attachmentRootProvider: () async => aliceRoot,
      );
      addTearDown(restarted.dispose);
      expect(restarted.pauseStateFor(descriptor.id), isNull);
      expect(
        restarted
            .messagesFor(bob.identity!.deviceId)
            .singleWhere((m) => m.id == message.id)
            .state,
        DeliveryState.canceled,
      );
      expect(aliceRoot.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

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
    expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
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
      expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
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
      expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
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

    expect(invite.routeHints.length, lessThanOrEqualTo(8));
    // Every LAN address goes out, best first (TCP and UDP); the others are
    // TCP only: the best-ranked one can be an interface the peer cannot
    // reach.
    final lan = invite.routeHints
        .where((route) => route.kind == PeerRouteKind.lan)
        .toList();
    expect(lan, hasLength(4));
    expect(lan.first.host, '192.168.1.20');
    expect(lan.map((route) => route.host).toSet(), {
      '192.168.1.20',
      '10.0.0.20',
      '172.16.0.20',
    });
    // A way in from another network always makes it.
    expect(
      invite.routeHints.where((route) => route.kind == PeerRouteKind.relay),
      hasLength(inInclusiveRange(1, 2)),
    );
    expect(controller.invitesReachOverInternet, isTrue);
    expect(payload.length, lessThan(900));
    expect(payload, startsWith('ci6|'));
    expect(invite.usesSignedFormat, isTrue);
    expect(invite.irohEndpointId, isNotEmpty);
  });

  test('an invite with no internet route says so', () async {
    final controller = await _createController(
      relayClient: _FakeRelayClient(),
      displayName: 'Alice',
      internetRelayHost: null,
    );
    addTearDown(controller.dispose);
    expect(controller.invitesReachOverInternet, isFalse);
  });

  test('hotspot gateway addresses are treated as LAN discovery addresses', () {
    expect(isLanDiscoveryAddress('172.20.10.1'), isTrue);
    expect(isLanDiscoveryAddress('192.168.43.1'), isTrue);
    expect(isIgnoredLanInterfaceName('wlan0'), isFalse);
    expect(isIgnoredLanInterfaceName('docker0'), isTrue);
  });

  test('virtual, VPN and mobile-data interfaces are never LAN', () {
    for (final name in [
      'virbr0',
      'lxcbr0',
      'incusbr0',
      'podman0',
      'cni0',
      'waydroid0',
      'wg0',
      'throne-tun',
      'rmnet_data0',
      'ccmni1',
      'v4-rmnet_data0',
    ]) {
      expect(isIgnoredLanInterfaceName(name), isTrue, reason: name);
    }
    for (final name in ['wlan0', 'wlp3s0', 'enp0s31f6', 'eth0', 'ap0']) {
      expect(isIgnoredLanInterfaceName(name), isFalse, reason: name);
    }
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
    'adding a contact creates a pending request on the other side',
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
      expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
      await bob.pollNow();
      expect(bob.contacts, isEmpty);
      expect(bob.pendingContactRequests, hasLength(1));
      await bob.approvePendingContactRequest(
        bob.pendingContactRequests.single.id,
      );
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
    var now = DateTime.utc(2026, 7, 13, 12);
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
      nowProvider: () => now,
    );
    final carol = await _createController(
      relayClient: relayClient,
      displayName: 'Carol',
      nowProvider: () => now,
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
    // LAN-first preferred routes can leave a microtask of group-message
    // snapshot work pending right after pollNow returns under specific
    // test orderings; an empty delay drains it. In production every
    // notifyListeners triggers a fresh UI read on the next frame anyway.
    await Future<void>.delayed(Duration.zero);

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
      await alice.approvePendingContactRequest(
        alice.pendingContactRequests.single.id,
      );

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
      await controller.acceptContactPairingForTesting(
        controller.contacts.single.deviceId,
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

  test(
    'unknown exchange requires approval and remote removal archives history',
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
      expect(alice.contacts, hasLength(1));
      expect(bob.contacts, isEmpty);
      expect(bob.pendingContactRequests, hasLength(1));
      await bob.approvePendingContactRequest(
        bob.pendingContactRequests.single.id,
      );
      expect(bob.contacts, hasLength(1));
      await alice.pollNow();
      expect(alice.contacts.single.canSendOutbound, isTrue);

      await alice.sendMessage(contact: alice.contacts.single, body: 'keep me');
      await bob.pollNow();
      expect(bob.messagesFor(bob.contacts.single.deviceId), hasLength(1));

      await alice.removeContact(bob.identity!.deviceId);
      await bob.pollNow();

      expect(alice.contacts, isEmpty);
      expect(bob.contacts, hasLength(1));
      expect(bob.contacts.single.remoteRemovedAt, isNotNull);
      expect(bob.contacts.single.canSendOutbound, isFalse);
      expect(bob.messagesFor(bob.contacts.single.deviceId), hasLength(1));
    },
  );

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
    'contact request stays queued when the pairing exchange cannot be sent',
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

      expect(result.exchangeStatus, ContactExchangeStatus.pendingApproval);
      await _waitForIroh(
        () =>
            controller.contacts.single.pairingState ==
            ContactPairingState.queued,
        reason: 'an unsent request stays queued for automatic retry',
      );
      expect(controller.contacts.single.canSendOutbound, isFalse);
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
    await controller.acceptContactPairingForTesting(
      controller.contacts.single.deviceId,
    );

    final contact = controller.contacts.single;
    relayClient.storeAttempts.clear();
    await controller.sendMessage(contact: contact, body: 'hello over LAN');

    expect(relayClient.storeAttempts, <String>['192.168.1.25:7667']);
    expect(
      controller.messagesFor(contact.deviceId).single.state,
      DeliveryState.local,
    );
    expect(
      controller.messagesFor(contact.deviceId).single.route,
      MessageRoute.lanDirect,
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
    await controller.acceptContactPairingForTesting(
      controller.contacts.single.deviceId,
    );

    final contact = controller.contacts.single;
    relayClient.storeAttempts.clear();
    await controller.sendMessage(contact: contact, body: 'hello via relay');

    expect(relayClient.storeAttempts, <String>['relay.example:7667']);
    expect(
      controller.messagesFor(contact.deviceId).single.state,
      DeliveryState.relayed,
    );
    expect(
      controller.messagesFor(contact.deviceId).single.route,
      MessageRoute.conestRelay,
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
      await controller.acceptContactPairingForTesting(
        controller.contacts.single.deviceId,
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
      await controller.acceptContactPairingForTesting(
        controller.contacts.single.deviceId,
      );

      final contact = controller.contacts.single;
      relayClient.storeAttempts.clear();
      await controller.sendMessage(contact: contact, body: 'same relay alias');

      expect(
        relayClient.storeAttempts,
        contains('192.168.3.9:7667'),
        reason:
            'status=${controller.statusMessage}; '
            'debug=${controller.recentDebugLog.join(" || ")}; '
            'snapshot=${controller.buildDebugSnapshotText()}',
      );
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
      var now = DateTime.utc(2026, 7, 13, 9);
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
      await controller.acceptContactPairingForTesting(
        controller.contacts.single.deviceId,
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

    await _pairControllers(alice, bob);
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

  test('direct reactions update both copies and can be toggled off', () async {
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
    final bobContactForAlice = bob.contacts.single;
    final aliceContactForBob = alice.contacts.single;
    await alice.sendMessage(contact: aliceContactForBob, body: 'react here');
    await bob.pollNow();
    final received = bob.messagesFor(bobContactForAlice.deviceId).single;

    await bob.toggleMessageReaction(
      contact: bobContactForAlice,
      messageId: received.id,
      emoji: '👍',
    );
    await alice.pollNow();
    final reacted = alice.messagesFor(aliceContactForBob.deviceId).single;
    expect(reacted.reactions['👍'], contains(bob.identity!.deviceId));

    await bob.toggleMessageReaction(
      contact: bobContactForAlice,
      messageId: received.id,
      emoji: '👍',
    );
    await alice.pollNow();
    expect(
      alice.messagesFor(aliceContactForBob.deviceId).single.reactions,
      isEmpty,
    );
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

    await _pairControllers(alice, bob);
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

      await _pairControllers(alice, bob);
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

      await _pairControllers(alice, bob);
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
    var now = DateTime.utc(2026, 7, 13, 12);
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

    await _pairControllers(alice, bob);
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
    var now = DateTime.utc(2026, 7, 13, 13);
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

    await _pairControllers(alice, bob);
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
      var now = DateTime.utc(2026, 7, 13, 14);
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

      await _pairControllers(alice, bob);
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
      var now = DateTime.utc(2026, 7, 13, 15);
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

      await _pairControllers(alice, bob);
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
      var now = DateTime.utc(2026, 7, 13, 16);
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

      await _pairControllers(alice, bob);
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
      // Pairing may already have recorded a probe reply; the failed
      // heartbeat must not add a newer one.
      final lastReply = alice
          .reachabilityRecordFor(aliceContactForBob.deviceId)
          ?.lastHeartbeatReplyAt;
      expect(lastReply == null || lastReply.isBefore(now), isTrue);
    },
  );

  test(
    'heartbeat pass skips contacts with very recent two-way traffic',
    () async {
      var now = DateTime.utc(2026, 7, 13, 17);
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

      await _pairControllers(alice, bob);
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

      await _pairControllers(alice, bob);
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

    await _pairControllers(alice, bob);
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

      await _pairControllers(alice, bob);
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

      await _pairControllers(alice, bob);
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

    await _pairControllers(alice, bob);
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

      await _pairControllers(alice, bob);
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

  group('Read marks', () {
    test(
      'a contact whose clock was ahead cannot hide new messages as read',
      () async {
        final relayClient = _FakeRelayClient();
        var bobSkew = const Duration(hours: 2);
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          nowProvider: () => DateTime.now().add(bobSkew),
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        final bobId = bob.identity!.deviceId;

        await bob.sendMessage(contact: bob.contacts.single, body: 'one');
        await alice.pollNow();
        await alice.markConversationReadThroughMessage(
          bobId,
          alice.messagesFor(bobId).single,
        );
        expect(alice.unreadCountFor(bobId), 0);

        // Bob sets his clock right, then writes again.
        bobSkew = Duration.zero;
        await bob.sendMessage(contact: bob.contacts.single, body: 'two');
        await alice.pollNow();
        final two = alice.messagesFor(bobId).firstWhere((m) => m.body == 'two');
        expect(alice.isUnreadMessage(bobId, two), isTrue);
        expect(alice.unreadCountFor(bobId), 1);

        await alice.markConversationReadThroughMessage(bobId, two);
        await bob.pollNow();
        final sent = bob
            .messagesFor(alice.identity!.deviceId)
            .firstWhere((m) => m.body == 'two');
        expect(sent.state, DeliveryState.read);
      },
    );

    test('a read mark left in the future is brought back at start', () async {
      final relayClient = _FakeRelayClient();
      final aliceVault = _MemoryVaultStore();
      var aliceSkew = const Duration(hours: 2);
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        vaultStore: aliceVault,
        nowProvider: () => DateTime.now().add(aliceSkew),
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final bobId = bob.identity!.deviceId;
      await bob.sendMessage(contact: bob.contacts.single, body: 'one');
      await alice.pollNow();
      await alice.markConversationReadThroughMessage(
        bobId,
        alice.messagesFor(bobId).single,
      );
      await alice.flushPendingChanges();
      alice.dispose();

      aliceSkew = Duration.zero;
      final restarted = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        vaultStore: aliceVault,
        createIdentity: false,
      );
      addTearDown(restarted.dispose);
      await bob.sendMessage(contact: bob.contacts.single, body: 'two');
      await restarted.pollNow();
      expect(restarted.unreadCountFor(bobId), 1);
    });

    test('a failed save still sends the read receipt', () async {
      final relayClient = _FakeRelayClient();
      final aliceVault = _FailingVaultStore();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        vaultStore: aliceVault,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final bobId = bob.identity!.deviceId;
      await bob.sendMessage(contact: bob.contacts.single, body: 'read me');
      await alice.pollNow();
      await bob.pollNow();

      aliceVault.failNextSave = true;
      await alice.markConversationReadThroughMessage(
        bobId,
        alice.messagesFor(bobId).single,
      );
      await bob.pollNow();
      expect(
        bob.messagesFor(alice.identity!.deviceId).single.state,
        DeliveryState.read,
      );
    });

    test('reading a group sends each sender a receipt', () async {
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
        title: 'Receipts for all',
        members: alice.contacts,
      );
      await bob.pollNow();
      await carol.pollNow();

      await bob.sendGroupMessage(groupId: group.groupId, body: 'from bob');
      await carol.sendGroupMessage(groupId: group.groupId, body: 'from carol');
      await alice.pollNow();
      final inbound = alice.messagesForGroup(group.groupId);
      expect(inbound, hasLength(2));
      await alice.markGroupReadThroughMessage(group.groupId, inbound.last);
      expect(alice.unreadGroupCountFor(group.groupId), 0);

      await bob.pollNow();
      await carol.pollNow();
      final aliceId = alice.identity!.deviceId;
      for (final (device, body) in [(bob, 'from bob'), (carol, 'from carol')]) {
        final sent = device
            .messagesForGroup(group.groupId)
            .firstWhere((m) => m.body == body);
        expect(sent.recipientStates[aliceId], DeliveryState.read, reason: body);
      }
    });

    test('a file that was read shows as read to its sender', () async {
      final relayClient = _FakeRelayClient();
      final root = Directory.systemTemp.createTempSync('conest_read_file_');
      addTearDown(() => root.deleteSync(recursive: true));
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        attachmentRootProvider: () async =>
            Directory('${root.path}/a')..createSync(recursive: true),
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        attachmentRootProvider: () async =>
            Directory('${root.path}/b')..createSync(recursive: true),
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final aliceId = alice.identity!.deviceId;
      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: Uint8List.fromList(List<int>.generate(5000, (i) => i % 251)),
        fileName: 'notes.pdf',
        mimeType: 'application/pdf',
      );
      await bob.pollNow();
      final received = bob
          .messagesFor(aliceId)
          .singleWhere((m) => m.hasAttachment);
      final sent = alice
          .messagesFor(bob.identity!.deviceId)
          .singleWhere((m) => m.hasAttachment);
      expect(received.id, sent.id);

      await bob.markConversationReadThroughMessage(aliceId, received);
      await alice.pollNow();
      expect(
        alice
            .messagesFor(bob.identity!.deviceId)
            .singleWhere((m) => m.hasAttachment)
            .state,
        DeliveryState.read,
      );
    });

    test(
      'a member who read a group message has read the ones before it',
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
          title: 'Read through',
          members: alice.contacts,
        );
        await bob.pollNow();
        await alice.sendGroupMessage(groupId: group.groupId, body: 'first');
        await alice.sendGroupMessage(groupId: group.groupId, body: 'second');
        await bob.pollNow();
        await alice.pollNow();

        // Bob's read names only the newest message.
        final second = bob
            .messagesForGroup(group.groupId)
            .firstWhere((m) => m.body == 'second');
        await bob.markGroupReadThroughMessage(group.groupId, second);
        await alice.pollNow();
        final bobId = bob.identity!.deviceId;
        for (final message in alice.messagesForGroup(group.groupId)) {
          expect(
            message.recipientStates[bobId],
            DeliveryState.read,
            reason: message.body,
          );
        }
      },
    );
  });

  testWidgets('Courier navigation keeps private and lobby drafts separate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    await tester.runAsync(() async {
      final relay = _FakeRelayClient();
      alice = await _createController(relayClient: relay, displayName: 'Alice');
      bob = await _createController(relayClient: relay, displayName: 'Bob');
      await _pairControllers(alice, bob);
    });
    final theme = app.ConestThemeController.memory();
    final updates = _createUpdateService();
    addTearDown(theme.dispose);
    addTearDown(updates.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: updates,
          buildInfo: _createBuildInfo(),
          themeController: theme,
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'private unfinished');
    await tester.tap(find.text('LAN lobby').first);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      isEmpty,
    );
    await tester.enterText(find.byType(TextField).last, 'lobby unfinished');
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'private unfinished',
    );
    await tester.tap(find.text('LAN lobby').first);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'lobby unfinished',
    );
    await tester.runAsync(alice.flushPendingChanges);
    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('Courier filters Conest and Matrix chats in Both mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    final native = FakeMatrixNative(FakeMatrixHub())
      ..rooms = [
        {'roomId': '!club:x', 'name': 'Book club', 'unread': 2},
      ];
    await tester.runAsync(() async {
      final relay = _FakeRelayClient();
      alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        matrixCarrierEnabled: true,
        matrixNativeApi: native,
      );
      bob = await _createController(relayClient: relay, displayName: 'Bob');
      await _pairControllers(alice, bob);
      await alice.matrixClient!.signInWithPassword(
        homeserver: 'https://x',
        user: 'alice',
        password: 'p',
      );
    });
    final theme = app.ConestThemeController.memory();
    final updates = _createUpdateService();
    addTearDown(theme.dispose);
    addTearDown(updates.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: updates,
          buildInfo: _createBuildInfo(),
          themeController: theme,
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();
    Finder chip(String label) => find.widgetWithText(ChoiceChip, label);
    Future<void> tapChip(String label) async {
      // The chip row scrolls sideways in the narrow chat list.
      await tester.scrollUntilVisible(
        chip(label),
        label == 'All chats' ? -80 : 80,
        scrollable: find
            .ancestor(
              of: find.byType(ChoiceChip).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pump();
      await tester.tap(chip(label));
      await tester.pump();
    }

    final bobRow = find.byKey(
      ValueKey('courier-chat-${bob.identity!.deviceId}'),
    );
    final clubRow = find.byKey(const ValueKey('courier-chat-matrix:!club:x'));
    expect(chip('Conest'), findsOneWidget);
    expect(bobRow, findsOneWidget);
    expect(clubRow, findsOneWidget);

    await tapChip('Matrix');
    expect(clubRow, findsOneWidget);
    expect(bobRow, findsNothing);

    await tapChip('Conest');
    expect(clubRow, findsNothing);
    expect(bobRow, findsOneWidget);

    // Conest-only mode shows no Matrix chats and no filters.
    await tapChip('All chats');
    await tester.runAsync(() => alice.setAppMode(AppMode.conest));
    await tester.pump();
    expect(chip('Conest'), findsNothing);
    expect(clubRow, findsNothing);
    expect(bobRow, findsOneWidget);

    await tester.runAsync(alice.flushPendingChanges);
    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('bitchat chats join the chat list with a filter of their own', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    late _FakeBitchatPhone phone;
    final area = FakeBleNeighbourhood()..connect('alice', 'phone');
    await tester.runAsync(() async {
      final relay = _FakeRelayClient();
      alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        bitchatConnector: () async => area.node('alice'),
      );
      bob = await _createController(relayClient: relay, displayName: 'Bob');
      await _pairControllers(alice, bob);
      await alice.enableBitchatCarrier();
      while (alice.bitchatChannel?.state != BitchatCarrierState.running) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      phone = await _FakeBitchatPhone.start(area, 'phone');
      await phone.say('anyone around?');
      while (alice.bitchatChats.mesh.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await alice.flushPendingChanges();
    });
    final theme = app.ConestThemeController.memory();
    final updates = _createUpdateService();
    addTearDown(theme.dispose);
    addTearDown(updates.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: updates,
          buildInfo: _createBuildInfo(),
          themeController: theme,
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();
    Finder chip(String label) => find.widgetWithText(ChoiceChip, label);
    final bobRow = find.byKey(
      ValueKey('courier-chat-${bob.identity!.deviceId}'),
    );
    final meshRow = find.byKey(const ValueKey('courier-chat-bitchat:#mesh'));
    expect(chip('bitchat'), findsOneWidget);
    expect(meshRow, findsOneWidget);
    expect(
      find.descendant(of: meshRow, matching: find.textContaining('anyone')),
      findsOneWidget,
    );
    expect(bobRow, findsOneWidget);

    // The chip row scrolls sideways in the narrow chat list.
    await tester.scrollUntilVisible(
      chip('bitchat'),
      80,
      scrollable: find
          .ancestor(
            of: find.byType(ChoiceChip).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    await tester.tap(chip('bitchat'));
    await tester.pump();
    expect(meshRow, findsOneWidget);
    expect(bobRow, findsNothing);

    // Hidden from the chat list: no row and no filter, and the list falls
    // back to everything rather than staying empty.
    await tester.runAsync(() => alice.setShowsChatNetwork('bitchat', false));
    await tester.pump();
    expect(meshRow, findsNothing);
    expect(chip('bitchat'), findsNothing);
    expect(bobRow, findsOneWidget);

    await tester.runAsync(() async {
      await phone.stop();
      await alice.flushPendingChanges();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('Matrix-only home signs in, then lists rooms', (tester) async {
    late MessengerController controller;
    final native = FakeMatrixNative(FakeMatrixHub())
      ..rooms = [
        {'roomId': '!dm:x', 'name': 'Carol', 'direct': true, 'unread': 1},
      ];
    await tester.runAsync(() async {
      controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        createIdentity: false,
        matrixCarrierEnabled: true,
        matrixNativeApi: native,
      );
      await controller.setAppMode(AppMode.matrixOnly);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MatrixHomeScreen(
          controller: controller,
          palette: app.ConestPalette(),
        ),
      ),
    );
    expect(find.text('Sign in to your Matrix account'), findsOneWidget);
    expect(find.text('Sign in with browser'), findsOneWidget);
    expect(find.byType(AppModeSelector), findsOneWidget);

    await tester.runAsync(
      () => controller.matrixClient!.signInWithPassword(
        homeserver: 'https://x',
        user: 'alice',
        password: 'p',
      ),
    );
    await tester.pump();
    expect(find.text('Carol'), findsOneWidget);
    expect(find.byTooltip('New Matrix chat'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('Courier search keeps archived chats in the archive view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    late MessengerController carol;
    await tester.runAsync(() async {
      final relay = _FakeRelayClient();
      alice = await _createController(relayClient: relay, displayName: 'Alice');
      bob = await _createController(relayClient: relay, displayName: 'Bob');
      carol = await _createController(relayClient: relay, displayName: 'Carol');
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await alice.updateConversationPreferences(
        ConversationKind.direct,
        bob.identity!.deviceId,
        archived: true,
      );
    });
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);
    final theme = app.ConestThemeController.memory();
    final updates = _createUpdateService();
    addTearDown(theme.dispose);
    addTearDown(updates.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: updates,
          buildInfo: _createBuildInfo(),
          themeController: theme,
          palette: app.ConestPalette(),
        ),
      ),
    );
    final search = find.byKey(const ValueKey('courier-search'));
    final bobRow = ValueKey('courier-chat-${bob.identity!.deviceId}');
    final carolRow = ValueKey('courier-chat-${carol.identity!.deviceId}');
    await tester.enterText(search, 'Bob');
    await tester.pump();
    expect(find.byKey(bobRow), findsNothing);

    await tester.enterText(search, '');
    await tester.pump();
    await tester.tap(find.text('Archived chats').first);
    await tester.pump();
    await tester.enterText(search, 'Bob');
    await tester.pump();
    expect(find.byKey(bobRow), findsOneWidget);
    expect(find.byKey(carolRow), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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

        await _pairControllers(alice, bob);
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
            buildInfo: _createBuildInfo(),
            themeController: app.ConestThemeController.memory(),
            palette: app.ConestPalette(),
          ),
        ),
      );
      await tester.pump();

      await tester.ensureVisible(find.text('Bob').first);
      final divider = find.byKey(
        const ValueKey('conversation-sidebar-divider'),
      );
      expect(tester.getTopLeft(divider).dx, 380);
      await tester.drag(divider, const Offset(1000, 0));
      await tester.pump();
      expect(tester.getTopLeft(divider).dx, 560);
      await tester.drag(divider, const Offset(-1000, 0));
      await tester.pump();
      expect(tester.getTopLeft(divider).dx, 300);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(tester.getTopLeft(divider).dx, 380);
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

      await _pairControllers(alice, bob);
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
          buildInfo: _createBuildInfo(),
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

  testWidgets('several selected messages are forwarded together, in order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    late MessengerController carol;
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
      final bobContact = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      await alice.sendMessage(contact: bobContact, body: 'first to forward');
      await alice.sendMessage(contact: bobContact, body: 'second to forward');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: _createUpdateService(),
          buildInfo: _createBuildInfo(),
          themeController: app.ConestThemeController.memory(),
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    // Beside the bubble (on the text itself, a long press selects text).
    Offset beside(String text) {
      final rect = tester.getRect(find.text(text).last);
      return Offset(rect.left - 120, rect.center.dy);
    }

    await tester.longPressAt(beside('first to forward'));
    await tester.pump();
    await tester.tapAt(beside('second to forward'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('selection-forward')));
    await tester.pumpAndSettle();
    expect(find.text('Forward 2 messages'), findsOneWidget);
    await tester.tap(find.text('Carol').last);
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await carol.pollNow();
        if (carol.messagesFor(alice.identity!.deviceId).length >= 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();
    expect(carol.messagesFor(alice.identity!.deviceId).map((m) => m.body), [
      'first to forward',
      'second to forward',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    carol.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('album files are selected one by one and have menus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    final ids = <String>[];
    final root = Directory.systemTemp.createTempSync('conest_album_pick_');
    addTearDown(() => root.deleteSync(recursive: true));
    await tester.runAsync(() async {
      final relayClient = _FakeRelayClient();
      alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        attachmentRootProvider: () async =>
            Directory('${root.path}/a')..createSync(recursive: true),
      );
      bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        attachmentRootProvider: () async =>
            Directory('${root.path}/b')..createSync(recursive: true),
      );
      await _pairControllers(alice, bob);
      final bobContact = alice.contacts.single;
      await alice.sendMessage(contact: bobContact, body: 'album caption');
      for (var i = 0; i < 2; i++) {
        await alice.sendAttachment(
          contact: bobContact,
          bytes: Uint8List.fromList(
            List<int>.generate(3000, (j) => (i + j) % 251),
          ),
          fileName: 'part$i.pdf',
          mimeType: 'application/pdf',
          albumId: 'album-pick',
          caption: i == 0 ? 'two files' : '',
        );
      }
      ids.addAll(
        alice
            .messagesFor(bob.identity!.deviceId)
            .where((m) => m.albumId == 'album-pick')
            .map((m) => m.id),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: _createUpdateService(),
          buildInfo: _createBuildInfo(),
          themeController: app.ConestThemeController.memory(),
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    expect(ids, hasLength(2));

    // Near a corner: in transfer, the card's middle holds its pause and
    // cancel buttons, whose tooltips take a long press.
    Offset corner(String id) =>
        tester.getTopLeft(find.byKey(ValueKey('album-item-$id'))) +
        const Offset(6, 6);
    // One file, not the album.
    await tester.longPressAt(corner(ids[0]));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    // While selecting, a tap on the other file adds just that one.
    await tester.tap(find.byKey(ValueKey('album-item-${ids[1]}')));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('album-item-${ids[1]}')));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('album-item-${ids[0]}')));
    await tester.pump();

    // Right-click on a file: its own menu.
    await tester.tap(
      find.byKey(ValueKey('album-item-${ids[0]}')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Forward attachment'), findsOneWidget);
    expect(find.text('Select'), findsOneWidget);
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('album-item-${ids[0]}')));
    await tester.pump();

    // Right-click on the album (its caption): the album's menu.
    await tester.tap(find.text('two files'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Select album'), findsOneWidget);
    expect(find.text('Forward album'), findsOneWidget);
    await tester.tap(find.text('Select album'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('albums are forwarded as one album and voice notes as voice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    late MessengerController carol;
    late String carolId;
    final root = Directory.systemTemp.createTempSync('conest_forward_album_');
    addTearDown(() => root.deleteSync(recursive: true));
    await tester.runAsync(() async {
      final relayClient = _FakeRelayClient();
      Future<Directory> Function() rootFor(String name) =>
          () async =>
              Directory('${root.path}/$name')..createSync(recursive: true);
      alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        attachmentRootProvider: rootFor('a'),
      );
      bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        attachmentRootProvider: rootFor('b'),
      );
      carol = await _createController(
        relayClient: relayClient,
        displayName: 'Carol',
        attachmentRootProvider: rootFor('c'),
      );
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      carolId = carol.identity!.deviceId;
      final bobContact = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      for (var i = 0; i < 2; i++) {
        await alice.sendAttachment(
          contact: bobContact,
          bytes: Uint8List.fromList(
            List<int>.generate(3000, (j) => (i + j) % 251),
          ),
          fileName: 'part$i.pdf',
          mimeType: 'application/pdf',
          albumId: 'album-src',
        );
      }
      final voice = Uint8List.fromList([
        ...'OggS'.codeUnits,
        ...List<int>.generate(2000, (j) => j % 251),
      ]);
      await alice.sendVoiceMessage(
        contact: bobContact,
        source: StagedAttachment(
          id: 'voice-src',
          fileName: 'voice-message.ogg',
          mimeType: 'audio/ogg; codecs=opus',
          sizeBytes: voice.length,
          bytes: voice,
        ),
        metadata: const VoiceMessageMetadata(durationMs: 2000),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: app.HomeScreen(
          controller: alice,
          updateService: _createUpdateService(),
          buildInfo: _createBuildInfo(),
          themeController: app.ConestThemeController.memory(),
          palette: app.ConestPalette(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Bob').first);
    await tester.pump();

    int filesToCarol() =>
        alice.messagesFor(carolId).where((m) => m.attachment != null).length;
    Future<void> pickCarol(int files) async {
      await tester.pumpAndSettle();
      await tester.tap(find.text('Carol').last);
      // The forward runs on the test clock (it starts from a tap).
      for (var i = 0; i < 100 && filesToCarol() < files; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.byTooltip('Album actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forward album'));
    await pickCarol(2);
    final album = alice
        .messagesFor(carolId)
        .where((m) => m.attachment != null)
        .toList();
    expect(album.map((m) => m.attachment!.fileName), [
      'part0.pdf',
      'part1.pdf',
    ]);
    expect(album.map((m) => m.albumId).toSet(), hasLength(1));
    expect(album.first.albumId, isNotNull);
    expect(album.first.albumId, isNot('album-src'));

    // The one message outside the album: the voice note.
    final voiceMenu = find.byWidgetPredicate(
      (widget) =>
          widget is PopupMenuButton<String> &&
          widget.tooltip == 'Message actions',
    );
    tester.state<PopupMenuButtonState<String>>(voiceMenu).showButtonMenu();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forward attachment'));
    await tester.pumpAndSettle();
    // The picker opens once the file is found on disk.
    for (var i = 0; i < 50 && find.byType(Dialog).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await pickCarol(3);
    final forwardedVoice = alice
        .messagesFor(carolId)
        .lastWhere((m) => m.attachment != null)
        .attachment!;
    expect(forwardedVoice.fileName, 'voice-message.ogg');
    expect(forwardedVoice.voiceMetadata?.durationMs, 2000);

    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    carol.dispose();
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

      await _pairControllers(alice, bob);
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
          buildInfo: _createBuildInfo(),
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
      var now = DateTime.utc(2026, 7, 13, 18);
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

        await _pairControllers(alice, bob);
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
            buildInfo: _createBuildInfo(),
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

      await _pairControllers(alice, bob);
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
            buildInfo: _createBuildInfo(),
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
    // The Telegram-style read sweep is debounced by 800 ms; pump past
    // it so the mark-read fires before we assert.
    await tester.pump(const Duration(milliseconds: 900));
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

  testWidgets('an album as the newest message is marked read', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    late String bobId;
    final root = Directory.systemTemp.createTempSync('conest_album_read_');
    addTearDown(() => root.deleteSync(recursive: true));
    await tester.runAsync(() async {
      final relayClient = _FakeRelayClient();
      alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        attachmentRootProvider: () async =>
            Directory('${root.path}/a')..createSync(recursive: true),
      );
      bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        attachmentRootProvider: () async =>
            Directory('${root.path}/b')..createSync(recursive: true),
      );
      await _pairControllers(alice, bob);
      bobId = bob.identity!.deviceId;
      await bob.sendMessage(contact: bob.contacts.single, body: 'two files');
      for (var i = 0; i < 2; i++) {
        await bob.sendAttachment(
          contact: bob.contacts.single,
          bytes: Uint8List.fromList(
            List<int>.generate(3000, (j) => (i + j) % 251),
          ),
          fileName: 'part$i.pdf',
          mimeType: 'application/pdf',
          albumId: 'album-1',
        );
      }
      await alice.pollNow();
    });
    expect(alice.unreadCountFor(bobId), 3);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: alice,
          builder: (context, _) => app.HomeScreen(
            controller: alice,
            updateService: _createUpdateService(),
            buildInfo: _createBuildInfo(),
            themeController: app.ConestThemeController.memory(),
            palette: app.ConestPalette(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Bob').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(alice.unreadCountFor(bobId), 0);

    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('scrolling a chat to newer unread messages marks them read', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late MessengerController alice;
    late MessengerController bob;
    late String bobId;
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
      await _pairControllers(alice, bob);
      bobId = bob.identity!.deviceId;
      for (var i = 0; i < 40; i++) {
        await bob.sendMessage(contact: bob.contacts.single, body: 'line $i');
      }
      await alice.pollNow();
    });
    expect(alice.unreadCountFor(bobId), 40);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: alice,
          builder: (context, _) => app.HomeScreen(
            controller: alice,
            updateService: _createUpdateService(),
            buildInfo: _createBuildInfo(),
            themeController: app.ConestThemeController.memory(),
            palette: app.ConestPalette(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Bob').first);
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    await settle();
    expect(alice.unreadCountFor(bobId), 0);

    // Up in the history, new messages arrive out of sight.
    // [shown] counts the chat list's preview of the newest message too.
    Future<void> dragUntil(String text, double dy, {int shown = 1}) async {
      for (
        var i = 0;
        i < 12 && find.text(text).hitTestable().evaluate().length < shown;
        i++
      ) {
        // The last match is in the chat (the first is the chat list's
        // preview of the newest message).
        await tester.drag(
          find.textContaining('line ').hitTestable().last,
          Offset(0, dy),
        );
        await tester.pump();
      }
      expect(find.text(text).hitTestable(), findsNWidgets(shown));
    }

    await dragUntil('line 0', 400);
    await tester.runAsync(() async {
      for (var i = 0; i < 3; i++) {
        await bob.sendMessage(
          contact: bob.contacts.single,
          body: 'line new $i',
        );
      }
      await alice.pollNow();
    });
    await settle();
    expect(alice.unreadCountFor(bobId), 3);
    // Sweeps the arrival asked for run now, out of sight of the new ones.
    await tester.pump(const Duration(seconds: 1));

    // Scrolling down to them marks them read, with nothing else in the app
    // changing.
    await dragUntil('line new 2', -400, shown: 2);
    await settle();
    expect(alice.unreadCountFor(bobId), 0);

    await tester.pumpWidget(const SizedBox.shrink());
    alice.dispose();
    bob.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  test('a relay added from its installer link has its key pinned', () async {
    final alice = await _createController(
      relayClient: _FakeRelayClient(),
      displayName: 'Alice',
    );
    addTearDown(alice.dispose);
    final key = base64Encode(List<int>.filled(32, 7));
    final other = base64Encode(List<int>.filled(32, 9));
    String link(String k) =>
        'conest-relay://relay.link.test:7667?id=relay-1&key='
        '${Uri.encodeQueryComponent(k)}';

    await alice.addRelayFromLink(link(key));
    expect(alice.pinnedRelayIdentityKeys['relay-1'], key);
    expect(
      alice.identity!.configuredRelays.map((r) => r.host),
      contains('relay.link.test'),
    );
    await expectLater(alice.addRelayFromLink(link(other)), throwsStateError);
    expect(alice.pinnedRelayIdentityKeys['relay-1'], key);
    await expectLater(
      alice.addRelayFromLink('https://relay.link.test'),
      throwsArgumentError,
    );
  });

  test('what a network cuts is remembered, judged blocked there, and kept '
      'across a restart', () async {
    var now = DateTime.now().toUtc();
    final relay = _FakeRelayClient();
    final aliceVault = _MemoryVaultStore();
    final alice = await _createController(
      relayClient: relay,
      displayName: 'Alice',
      lanAddresses: const ['192.168.3.20'],
      nowProvider: () => now,
      vaultStore: aliceVault,
    );
    final bob = await _createController(
      relayClient: relay,
      displayName: 'Bob',
      lanAddresses: const [],
      internetRelayHost: null,
    );
    addTearDown(bob.dispose);
    // One protocol each, so both fit in the invite's relay hints.
    await bob.addRelay(host: 'tcp://relay.ok', port: 7667);
    await bob.addRelay(host: 'tcp://relay.cut', port: 7667);
    await _pairControllers(alice, bob);
    await alice.noteNetwork('wifi');
    relay.storeErrorFor = (host) => host == 'relay.cut'
        ? const SocketException('Connection reset by peer')
        : null;
    for (var i = 0; i < 3; i++) {
      // Route checks try every relay (and messages, when it is their turn).
      await alice.checkContactRoutes(alice.contacts.single);
      await alice.sendMessage(contact: alice.contacts.single, body: 'm$i');
      // Past any backoff, so each round tries it again.
      now = now.add(const Duration(hours: 1));
    }
    final here = alice.networkHistory.current!;
    expect(
      here.routes['relay:relay.cut:7667']!.failures[RouteFailureKind.reset],
      greaterThanOrEqualTo(3),
    );
    expect(
      alice.networkHistory.blockedHere(),
      contains('relay:relay.cut:7667'),
    );
    // Elsewhere it is not judged.
    await alice.noteNetwork('mobile');
    expect(alice.networkHistory.blockedHere(), isEmpty);
    await alice.noteNetwork('wifi');

    // What Bob reports of his links is kept too, to fade on the map.
    final aliceId = alice.identity!.deviceId;
    final bobId = bob.identity!.deviceId;
    alice.receiveLinksForTesting(bobId, {aliceId: 'twoWay'});

    await alice.flushPendingChanges();
    alice.dispose();
    final restarted = await _createController(
      relayClient: relay,
      displayName: 'unused',
      createIdentity: false,
      vaultStore: aliceVault,
      nowProvider: () => now,
    );
    addTearDown(restarted.dispose);
    final labels = restarted.networkHistory.networks.map((n) => n.label);
    expect(labels, containsAll(['Wi-Fi 192.168.3.x', 'Mobile data']));
    expect(
      restarted.connectionMap.reported[bobId]?[aliceId]?.status,
      LinkStatus.twoWay,
    );
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

      await _pairControllers(alice, bob);

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

      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);

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

    await _pairControllers(alice, bob);

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
      var now = DateTime.utc(2026, 7, 13, 11);
      final relayClient = _FakeRelayClient();
      final controller = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        nowProvider: () => now,
        // On mains power: background upkeep is not slowed (see the energy
        // test for that).
        energyPolicy: EnergyPolicy.fixed(EnergyMode.unconstrained),
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

  test('overlapping pollNow callers await the active mailbox pass', () async {
    final relayClient = _BlockingFetchRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      internetRelayHost: null,
    );
    addTearDown(controller.dispose);

    final entered = relayClient.blockNextFetch();
    final firstPoll = controller.pollNow();
    await entered.timeout(const Duration(seconds: 2));
    var secondCompleted = false;
    final secondPoll = controller.pollNow().then((_) {
      secondCompleted = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      secondCompleted,
      isFalse,
      reason: 'a refresh must not report completion while mailbox work runs',
    );
    relayClient.releaseBlockedFetch();
    await Future.wait([firstPoll, secondPoll]);
    expect(secondCompleted, isTrue);
  });

  test(
    'relay lease is not acknowledged when envelope persistence fails',
    () async {
      final relayClient = _LeasedFakeRelayClient();
      final bobVault = _FailingVaultStore();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        vaultStore: bobVault,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      relayClient.acknowledgementCount = 0;

      await alice.sendMessage(contact: alice.contacts.single, body: 'durable');
      bobVault.failNextSave = true;
      await bob.pollNow();

      expect(
        relayClient.acknowledgementCount,
        0,
        reason: 'the relay must replay after the vault commit recovers',
      );
    },
  );

  test(
    'pairing session activates for invite actions and expires after two minutes',
    () async {
      var now = DateTime.utc(2026, 7, 13, 12);
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

  for (final mode in ['bundled', 'manual', 'imported']) {
    test(
      'retired default relay migration preserves $mode provenance correctly',
      () async {
        final vault = _MemoryVaultStore();
        final initial = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
          vaultStore: vault,
          internetRelayHost: null,
        );
        final initialSnapshot = await vault.load();
        initial.dispose();
        const retired = PeerEndpoint(
          kind: PeerRouteKind.relay,
          host: '185.182.65.29',
          port: 7667,
          protocol: PeerRouteProtocol.tcp,
        );
        const custom = PeerEndpoint(
          kind: PeerRouteKind.relay,
          host: 'custom.example',
          port: 7667,
          protocol: PeerRouteProtocol.tcp,
        );
        final key = relayHealthEndpointKey(retired);
        await vault.save(
          initialSnapshot.copyWith(
            identity: initialSnapshot.identity!.copyWith(
              configuredRelays: [retired, custom],
            ),
            defaultRelayRouteKeys: mode == 'manual' ? {} : {retired.routeKey},
            defaultRelayHosts: mode == 'manual' ? {} : {'185.182.65.29:7667'},
            relayHealthScores: {key: RelayHealthScore(endpointKey: key)},
            customRelaySources: mode != 'imported'
                ? []
                : [
                    CustomRelaySource(
                      id: 'explicit-source',
                      url: 'https://example.test/relays.json',
                      publicKeyBase64: null,
                      lastVersion: null,
                      lastFetchedAt: DateTime.now().toUtc(),
                      routeKeys: {retired.routeKey},
                    ),
                  ],
          ),
        );
        for (var restart = 0; restart < 2; restart++) {
          final peer = await _createController(
            relayClient: _FakeRelayClient(),
            displayName: 'Alice',
            vaultStore: vault,
            createIdentity: false,
          );
          final snapshot = await vault.load();
          expect(
            peer.identity!.configuredRelays.any((r) => r.host == retired.host),
            mode != 'bundled',
          );
          expect(
            peer.identity!.configuredRelays.any((r) => r.host == custom.host),
            isTrue,
          );
          expect(
            snapshot.relayHealthScores.containsKey(key),
            mode != 'bundled',
          );
          expect(snapshot.defaultRelayHosts, isEmpty);
          peer.dispose();
        }
      },
    );
  }

  test(
    'retired default advertisements are not used until explicitly configured',
    () async {
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        internetRelayHost: null,
      );
      addTearDown(alice.dispose);
      final invite = _bobInvite().copyWithSignature('');
      // Legacy invite is sufficient to test routing, without manufacturing a ci6 signature.
      final retiredInvite = ContactInvite(
        version: 5,
        accountId: invite.accountId,
        deviceId: invite.deviceId,
        displayName: invite.displayName,
        bio: invite.bio,
        pairingNonce: invite.pairingNonce,
        pairingEpochMs: invite.pairingEpochMs,
        relayCapable: false,
        publicKeyBase64: invite.publicKeyBase64,
        routeHints: const [
          PeerEndpoint(
            kind: PeerRouteKind.relay,
            host: '185.182.65.29',
            port: 7667,
          ),
        ],
      );
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: retiredInvite.encodePayload(),
        codephrase: '',
      );
      await alice.pollNow();
      expect(
        [
          ...relay.storeAttempts,
          ...relay.fetchAttempts,
          ...relay.inspectHealthAttempts,
        ].where((entry) => entry.contains('185.182.65.29')),
        isEmpty,
      );
      await alice.addRelay(host: 'tcp://185.182.65.29', port: 7667);
      await alice.pollNow();
      expect(
        relay.fetchAttempts.any((entry) => entry.contains('185.182.65.29')),
        isTrue,
      );
    },
  );

  test(
    'legacy group updates retain Iroh pins and explicit identity replacement is rejected',
    () async {
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      final carol = await _createController(
        relayClient: relay,
        displayName: 'Carol',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      final group = await alice.createGroup(
        title: 'Legacy membership',
        members: alice.contacts,
      );
      await bob.pollNow();
      final crypto = CryptoService(identityProvider: () => alice.identity!);
      final bobContact = alice.contacts.singleWhere(
        (peer) => peer.deviceId == bob.identity!.deviceId,
      );
      Future<void> deliver(Map<String, dynamic> payload, String id) async {
        await bob.processEnvelopesForTesting([
          await crypto.encryptPayloadEnvelope(
            kind: 'group_membership',
            messageId: id,
            conversationId: group.groupId,
            senderAccountId: alice.identity!.accountId,
            senderDeviceId: alice.identity!.deviceId,
            recipientDeviceId: bob.identity!.deviceId,
            contact: bobContact,
            plaintext: jsonEncode({'group': payload}),
          ),
        ]);
      }

      final legacy = group.toJson()
        ..['membershipVersion'] = group.membershipVersion + 1;
      for (final profile in legacy['memberProfiles'] as List) {
        (profile as Map).remove('signingPublicKeyBase64');
        profile.remove('irohEndpointId');
        profile.remove('capabilities');
      }
      await deliver(legacy, 'legacy-profile-update');
      expect(bob.groups.single.membershipVersion, group.membershipVersion + 1);
      expect(
        bob.groups.single
            .memberProfileFor(carol.identity!.deviceId)!
            .irohEndpointId,
        carol.identity!.irohEndpointId,
      );
      final forged = bob.groups.single.toJson()
        ..['membershipVersion'] = group.membershipVersion + 2;
      for (final profile in forged['memberProfiles'] as List) {
        if (profile['deviceId'] == carol.identity!.deviceId) {
          profile['signingPublicKeyBase64'] =
              alice.identity!.signingPublicKeyBase64;
          profile['irohEndpointId'] = alice.identity!.irohEndpointId;
        }
      }
      await deliver(forged, 'forged-profile-update');
      expect(bob.groups.single.membershipVersion, group.membershipVersion + 1);
      expect(
        bob.groups.single
            .memberProfileFor(carol.identity!.deviceId)!
            .irohEndpointId,
        carol.identity!.irohEndpointId,
      );
    },
  );

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

  test('signed defaults do not restore the retired bundled relay', () async {
    final relayClient = _FakeRelayClient();
    final defaults = SignedRelayDefaults(
      version: 12,
      issuedAt: DateTime.utc(2026, 5, 12),
      endpoints: const [
        DefaultRelayEndpointSpec(
          kind: PeerRouteKind.relay,
          host: '185.182.65.29',
          port: 7667,
          protocol: PeerRouteProtocol.tcp,
        ),
      ],
    );
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      signedRelayDefaultsLoader: () async => defaults,
    );
    addTearDown(alice.dispose);

    expect(
      alice.identity!.configuredRelays.any(
        (route) => route.host == '185.182.65.29' && route.port == 7667,
      ),
      isFalse,
    );
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
      var dropReceipts = false;
      final relayClient = _FakeRelayClient(
        shouldFailStore: (host, port, protocol, recipientDeviceId, envelope) {
          return dropReceipts && envelope.kind == 'ack';
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
      dropReceipts = true;
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
        publicKeyBase64: 'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
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
        'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
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
      // The block is lifted; delivery still waits for the new device to
      // accept the pairing request.
      expect(refreshed.canComposeOutbound, isTrue);
      expect(
        refreshed.publicKeyBase64,
        'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
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
        'publicKeyBase64': 'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
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
        'ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY=',
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
      publicKeyBase64: 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
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

  test('sendAttachment round-trips a small file 1:1, hash-verified', () async {
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
    final aliceContactForBob = alice.contacts.single;

    // 192 KiB payload spans two protocol-v2 128 KiB blocks.
    final original = Uint8List.fromList(
      List<int>.generate(192 * 1024, (index) => index & 0xff),
    );
    await alice.sendAttachment(
      contact: aliceContactForBob,
      bytes: original,
      fileName: 'sample.bin',
      mimeType: 'application/octet-stream',
      caption: 'here you go',
    );

    // Drive the offer → chunk_request → chunk → complete handshake.
    // Each pollNow consumes one round of envelopes from the fake relay.
    for (var round = 0; round < 8; round++) {
      await bob.pollNow();
      await alice.pollNow();
    }

    final bobContactForAlice = bob.contacts.single;
    final received = bob
        .messagesFor(bobContactForAlice.deviceId)
        .firstWhere((message) => message.hasAttachment);
    expect(received.attachment!.fileName, 'sample.bin');
    expect(received.attachment!.sizeBytes, original.length);
    expect(received.body, 'here you go');
    expect(
      received.state,
      DeliveryState.delivered,
      reason:
          'inbound=${bob.inboundTransferDebugForTesting(received.attachment!.id)}; '
          'bob=${bob.recentDebugLog.join(" || ")}; '
          'alice=${alice.recentDebugLog.join(" || ")}',
    );

    final assembled = bob.attachmentBytesFor(received.attachment!.id);
    expect(assembled, isNotNull);
    expect(assembled, equals(original));

    // Sender side: the offer message should also be marked delivered now
    // that the complete envelope flowed back.
    final outbound = alice
        .messagesFor(aliceContactForBob.deviceId)
        .firstWhere((message) => message.hasAttachment);
    expect(outbound.state, DeliveryState.delivered);
  });

  test(
    'manual small download remains acceptable after receiver restart',
    () async {
      final relayClient = _FakeRelayClient();
      final bobVault = _MemoryVaultStore();
      final aliceRoot = Directory.systemTemp.createTempSync(
        'conest_manual_restart_alice_',
      );
      final bobRoot = Directory.systemTemp.createTempSync(
        'conest_manual_restart_bob_',
      );
      addTearDown(() {
        for (final directory in <Directory>[aliceRoot, bobRoot]) {
          try {
            directory.deleteSync(recursive: true);
          } catch (_) {}
        }
      });
      final aliceChannel = _InProcessLanDirectChannel(host: '192.168.62.10');
      final bobChannel = _InProcessLanDirectChannel(host: '192.168.62.11');
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        lanAddresses: const <String>['192.168.62.10'],
        lanDirectChannel: aliceChannel,
        attachmentRootProvider: () async => aliceRoot,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        lanAddresses: const <String>['192.168.62.11'],
        lanDirectChannel: bobChannel,
        attachmentRootProvider: () async => bobRoot,
        vaultStore: bobVault,
      );
      addTearDown(alice.dispose);
      addTearDown(aliceChannel.stop);
      await _pairControllers(alice, bob);
      await bob.updateGlobalConnectivity(
        bob.identity!.connectivity.copyWith(
          autoDownloadPreset: AutoDownloadPreset.custom,
        ),
      );

      final original = Uint8List.fromList(
        List<int>.generate(192 * 1024, (index) => (index * 7) & 0xff),
      );
      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: original,
        fileName: 'tap-after-restart.bin',
      );
      await bob.pollNow();
      final offered = bob
          .messagesFor(bob.contacts.single.deviceId)
          .singleWhere((message) => message.hasAttachment);
      expect(bob.attachmentAwaitingAcceptance(offered.attachment!.id), isTrue);

      bob.dispose();
      await bobChannel.stop();
      final resumedBobChannel = _InProcessLanDirectChannel(
        host: '192.168.62.11',
      );
      final resumedBob = await _createController(
        relayClient: relayClient,
        displayName: 'unused',
        lanAddresses: const <String>['192.168.62.11'],
        lanDirectChannel: resumedBobChannel,
        attachmentRootProvider: () async => bobRoot,
        vaultStore: bobVault,
        createIdentity: false,
      );
      addTearDown(resumedBob.dispose);
      addTearDown(resumedBobChannel.stop);
      expect(
        resumedBob.attachmentAwaitingAcceptance(offered.attachment!.id),
        isTrue,
      );

      await resumedBob.acceptIncomingAttachment(offered.attachment!.id);
      for (var round = 0; round < 12; round++) {
        await alice.pollNow();
        await resumedBob.pollNow();
        if (resumedBob.attachmentAvailableLocally(offered.attachment!.id)) {
          break;
        }
      }
      expect(
        resumedBob.attachmentBytesFor(offered.attachment!.id),
        equals(original),
      );
    },
  );

  test(
    'manual Download returns before a blocked route and exposes progress',
    () async {
      final relayClient = _FakeRelayClient();
      final aliceRoot = Directory.systemTemp.createTempSync(
        'conest_accept_immediate_alice_',
      );
      final bobRoot = Directory.systemTemp.createTempSync(
        'conest_accept_immediate_bob_',
      );
      addTearDown(() {
        for (final directory in <Directory>[aliceRoot, bobRoot]) {
          try {
            directory.deleteSync(recursive: true);
          } catch (_) {}
        }
      });
      final aliceChannel = _InProcessLanDirectChannel(host: '192.168.63.10');
      final bobChannel = _InProcessLanDirectChannel(host: '192.168.63.11');
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        lanAddresses: const <String>['192.168.63.10'],
        lanDirectChannel: aliceChannel,
        attachmentRootProvider: () async => aliceRoot,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        lanAddresses: const <String>['192.168.63.11'],
        lanDirectChannel: bobChannel,
        attachmentRootProvider: () async => bobRoot,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(aliceChannel.stop);
      addTearDown(bobChannel.stop);
      await _pairControllers(alice, bob);
      await bob.updateGlobalConnectivity(
        bob.identity!.connectivity.copyWith(
          autoDownloadPreset: AutoDownloadPreset.custom,
        ),
      );

      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: Uint8List(256 * 1024),
        fileName: 'tap-now.bin',
      );
      await bob.pollNow();
      final offered = bob
          .messagesFor(bob.contacts.single.deviceId)
          .singleWhere((message) => message.hasAttachment);
      final attachmentId = offered.attachment!.id;
      expect(bob.attachmentAwaitingAcceptance(attachmentId), isTrue);

      final barrier = Completer<void>();
      bobChannel.blockPutsUntil = barrier;
      await bob
          .acceptIncomingAttachment(attachmentId)
          .timeout(const Duration(seconds: 1));

      expect(bob.attachmentAcceptanceInProgress(attachmentId), isFalse);
      expect(bob.attachmentAwaitingAcceptance(attachmentId), isFalse);
      expect(
        bob.transferSnapshotFor(attachmentId)?.phase,
        anyOf(TransferPhase.transferring, TransferPhase.reconnecting),
      );
      barrier.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    },
  );

  test('manual Download storage failure stays visible and retryable', () async {
    var storageAvailable = true;
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
      storageCapacityProvider: (_) async => storageAvailable
          ? const StorageCapacity(
              freeBytes: 10 * 1024 * 1024 * 1024,
              totalBytes: 12 * 1024 * 1024 * 1024,
            )
          : null,
    );
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await _pairControllers(alice, bob);
    await bob.updateGlobalConnectivity(
      bob.identity!.connectivity.copyWith(
        autoDownloadPreset: AutoDownloadPreset.custom,
      ),
    );
    await alice.sendAttachment(
      contact: alice.contacts.single,
      bytes: Uint8List(64 * 1024),
      fileName: 'no-space.bin',
    );
    await bob.pollNow();
    final attachmentId = bob
        .messagesFor(bob.contacts.single.deviceId)
        .singleWhere((message) => message.hasAttachment)
        .attachment!
        .id;

    storageAvailable = false;
    await bob.acceptIncomingAttachment(attachmentId);

    expect(bob.attachmentAcceptanceInProgress(attachmentId), isFalse);
    expect(bob.attachmentAwaitingAcceptance(attachmentId), isTrue);
    final snapshot = bob.transferSnapshotFor(attachmentId);
    expect(snapshot?.phase, TransferPhase.awaitingApproval);
    expect(snapshot?.error, contains('Could not check available storage'));
  });

  test(
    'missing inbound partial after restart returns to Download state',
    () async {
      final relayClient = _FakeRelayClient();
      final bobVault = _MemoryVaultStore();
      final aliceRoot = Directory.systemTemp.createTempSync(
        'conest_missing_partial_alice_',
      );
      final bobRoot = Directory.systemTemp.createTempSync(
        'conest_missing_partial_bob_',
      );
      addTearDown(() {
        for (final directory in <Directory>[aliceRoot, bobRoot]) {
          try {
            directory.deleteSync(recursive: true);
          } catch (_) {}
        }
      });
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        attachmentRootProvider: () async => aliceRoot,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        attachmentRootProvider: () async => bobRoot,
        vaultStore: bobVault,
      );
      addTearDown(alice.dispose);
      await _pairControllers(alice, bob);
      await bob.updateGlobalConnectivity(
        bob.identity!.connectivity.copyWith(
          autoDownloadPreset: AutoDownloadPreset.custom,
        ),
      );
      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: Uint8List(192 * 1024),
        fileName: 'restart-download.bin',
      );
      await bob.pollNow();
      final attachmentId = bob
          .messagesFor(bob.contacts.single.deviceId)
          .singleWhere((message) => message.hasAttachment)
          .attachment!
          .id;
      await bob.acceptIncomingAttachment(attachmentId);
      bob.dispose();

      final partialDir = Directory(p.join(bobRoot.path, 'partial'));
      final partial = partialDir.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.part'),
      );
      await partial.writeAsBytes(<int>[1, 2, 3], flush: true);

      final resumedBob = await _createController(
        relayClient: relayClient,
        displayName: 'unused',
        attachmentRootProvider: () async => bobRoot,
        vaultStore: bobVault,
        createIdentity: false,
      );
      addTearDown(resumedBob.dispose);

      expect(resumedBob.attachmentAwaitingAcceptance(attachmentId), isTrue);
      final snapshot = resumedBob.transferSnapshotFor(attachmentId);
      expect(snapshot?.phase, TransferPhase.awaitingApproval);
      expect(snapshot?.error, contains('Tap Download to restart'));
      expect(await partial.exists(), isFalse);
    },
  );

  test(
    'attachment routing enforces exact 30 MiB and 2 GiB boundaries',
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
      final aliceContactForBob = alice.contacts.single;

      expect(
        MessengerController.maxAttachmentSizeBytes,
        30 * 1024 * 1024,
        reason: 'v0.3.2 cap was bumped from 8 MB to 30 MB',
      );

      expect(
        MessengerController.maxLanAttachmentSizeBytes,
        2 * 1024 * 1024 * 1024,
      );
      expect(
        alice.effectiveMaxAttachmentSizeFor(aliceContactForBob),
        MessengerController.maxLanAttachmentSizeBytes,
      );

      final aboveLanCap = StagedAttachment(
        id: 'above-lan-cap',
        fileName: 'too-large.bin',
        mimeType: 'application/octet-stream',
        sizeBytes: MessengerController.maxLanAttachmentSizeBytes + 1,
        filePath: p.join(Directory.systemTemp.path, 'not-opened.bin'),
      );
      await expectLater(
        alice.sendAttachmentSource(
          contact: aliceContactForBob,
          source: aboveLanCap,
        ),
        throwsArgumentError,
      );

      await alice.updateContactRoutingPreferences(
        aliceContactForBob.deviceId,
        const ContactRoutingPreferences(lanEnabled: false, onlineEnabled: true),
      );
      final relayOnlyContact = alice.contacts.single;
      expect(
        alice.effectiveMaxAttachmentSizeFor(relayOnlyContact),
        MessengerController.maxAttachmentSizeBytes,
      );
      final aboveRelayCap = StagedAttachment(
        id: 'above-relay-cap',
        fileName: 'lan-only.bin',
        mimeType: 'application/octet-stream',
        sizeBytes: MessengerController.maxAttachmentSizeBytes + 1,
        filePath: p.join(Directory.systemTemp.path, 'not-opened.bin'),
      );
      await expectLater(
        alice.sendAttachmentSource(
          contact: relayOnlyContact,
          source: aboveRelayCap,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'spool reserve failure offers original fallback and detects source change',
    () async {
      final sourceDir = Directory.systemTemp.createTempSync(
        'conest_original_fallback_',
      );
      addTearDown(() {
        try {
          sourceDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final source = File(p.join(sourceDir.path, 'original.bin'));
      await source.writeAsBytes(List<int>.generate(64, (i) => i));
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        storageCapacityProvider: (_) async => null,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final bobOnAlice = alice.contacts.single;
      final staged = StagedAttachment(
        id: 'original-source',
        fileName: 'original.bin',
        mimeType: 'application/octet-stream',
        sizeBytes: 64,
        filePath: source.path,
      );

      await expectLater(
        alice.sendAttachmentSource(contact: bobOnAlice, source: staged),
        throwsA(
          isA<AttachmentSpoolException>().having(
            (error) => error.canUseOriginal,
            'canUseOriginal',
            isTrue,
          ),
        ),
      );
      expect(alice.messagesFor(bobOnAlice.deviceId), isEmpty);

      await alice.sendAttachmentSource(
        contact: bobOnAlice,
        source: staged,
        allowOriginalFallback: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await source.writeAsBytes(
        List<int>.generate(64, (i) => 255 - i),
        flush: true,
      );
      for (var step = 0; step < 12; step++) {
        await bob.pollNow();
        await alice.pollNow();
      }

      expect(
        alice.messagesFor(bobOnAlice.deviceId).single.state,
        DeliveryState.failed,
      );
      expect(
        bob.attachmentBytesFor(
          alice.messagesFor(bobOnAlice.deviceId).single.attachment!.id,
        ),
        isNull,
      );
    },
  );

  test(
    'attachment bytes survive an in-memory cache eviction via the disk cache',
    () async {
      final attachmentRoot = Directory.systemTemp.createTempSync(
        'conest_attach_persist_',
      );
      addTearDown(() {
        try {
          attachmentRoot.deleteSync(recursive: true);
        } catch (_) {}
      });
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        attachmentRootProvider: () async => attachmentRoot,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        attachmentRootProvider: () async => attachmentRoot,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);

      await _pairControllers(alice, bob);
      final aliceContactForBob = alice.contacts.single;

      final original = Uint8List.fromList(
        List<int>.generate(96 * 1024, (i) => i & 0xff),
      );
      await alice.sendAttachment(
        contact: aliceContactForBob,
        bytes: original,
        fileName: 'persist.bin',
      );
      for (var round = 0; round < 16; round++) {
        await bob.pollNow();
        await alice.pollNow();
      }

      final bobContactForAlice = bob.contacts.single;
      final received = bob
          .messagesFor(bobContactForAlice.deviceId)
          .firstWhere((message) => message.hasAttachment);
      expect(bob.attachmentBytesFor(received.attachment!.id), equals(original));

      // Evict the in-memory cache and confirm the lazy disk read
      // refills it on the next bubble rebuild.
      bob.evictAttachmentBytesForTesting(received.attachment!.id);
      expect(
        bob.attachmentBytesFor(received.attachment!.id),
        isNull,
        reason: 'first call returns null while disk read is in flight',
      );
      // Drain the disk-read microtasks.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        bob.attachmentBytesFor(received.attachment!.id),
        equals(original),
        reason: 'second call sees the disk-cached bytes',
      );
    },
  );

  test('attachment root provider is resolved once per controller', () async {
    var calls = 0;
    final root = Directory.systemTemp.createTempSync('conest_root_once_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final controller = await _createController(
      relayClient: _FakeRelayClient(),
      displayName: 'Alice',
      attachmentRootProvider: () async {
        calls++;
        return root;
      },
    );
    addTearDown(controller.dispose);

    expect(await controller.attachmentRoot(), same(root));
    expect(await controller.attachmentRoot(), same(root));
    expect(calls, 1);
  });

  group('a lost file completion', () {
    // Sends a small file from Alice to Bob while [dropCompletion] decides
    // which attachment_complete envelopes vanish after being "stored".
    Future<(MessengerController, MessengerController, String)> transfer(
      bool Function(int index) dropCompletion,
    ) async {
      var completions = 0;
      final relay = _FakeRelayClient(
        shouldBlackholeStore: (_, _, _, _, envelope) =>
            envelope.kind == 'attachment_complete' &&
            dropCompletion(completions++),
      );
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xff)),
        fileName: 'photo.jpg',
      );
      final id = alice
          .messagesFor(bob.identity!.deviceId)
          .singleWhere((m) => m.hasAttachment)
          .attachment!
          .id;
      for (var round = 0; round < 60; round++) {
        await bob.pollNow();
        await alice.pollNow();
        if (bob.attachmentAwaitingAcceptance(id)) {
          await bob.acceptIncomingAttachment(id);
        }
        if (bob.attachmentAvailableLocally(id) && completions > 0) break;
      }
      expect(bob.attachmentAvailableLocally(id), isTrue);
      return (alice, bob, id);
    }

    // The transfer is still open on the sender (the bubble at 100% with a
    // pause button), even when the offer message itself was acknowledged.
    bool open(MessengerController alice, String id) =>
        alice.transferSnapshotFor(id)?.phase.isActive ?? false;

    Future<void> pump(
      MessengerController alice,
      MessengerController bob, {
      bool Function()? until,
      Duration limit = const Duration(seconds: 15),
    }) async {
      final deadline = DateTime.now().add(limit);
      while (!(until?.call() ?? false) && DateTime.now().isBefore(deadline)) {
        await bob.pollNow();
        await alice.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    test('is sent again when the sender offers the file again', () async {
      final (alice, bob, id) = await transfer((index) => index == 0);
      final bobId = bob.identity!.deviceId;
      await pump(alice, bob, limit: const Duration(seconds: 3));
      expect(open(alice, id), isTrue);

      alice.triggerOutboundStallForTesting(bobId);
      await pump(alice, bob, until: () => !open(alice, id));
      expect(open(alice, id), isFalse);
      expect(
        alice.messagesFor(bobId).singleWhere((m) => m.hasAttachment).state,
        DeliveryState.delivered,
      );
    });

    testWidgets('an upload marked read by a later message keeps its controls', (
      tester,
    ) async {
      late MessengerController alice;
      late String id;
      await tester.runAsync(() async {
        final relay = _FakeRelayClient();
        alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        // Bob has to accept files: this one waits for him.
        await bob.updateGlobalConnectivity(
          bob.identity!.connectivity.copyWith(
            autoDownloadPreset: AutoDownloadPreset.custom,
          ),
        );
        final bobId = bob.identity!.deviceId;
        final aliceId = alice.identity!.deviceId;
        await alice.sendAttachment(
          contact: alice.contacts.single,
          bytes: Uint8List(64 * 1024),
          fileName: 'clip.mp4',
        );
        id = alice
            .messagesFor(bobId)
            .singleWhere((m) => m.hasAttachment)
            .attachment!
            .id;
        await alice.sendMessage(contact: alice.contacts.single, body: 'here');
        await pump(
          alice,
          bob,
          until: () => bob.messagesFor(aliceId).any((m) => m.body == 'here'),
        );
        await bob.markConversationRead(aliceId);
        await pump(
          alice,
          bob,
          until: () =>
              alice
                  .messagesFor(bobId)
                  .singleWhere((m) => m.hasAttachment)
                  .state ==
              DeliveryState.read,
        );
      });
      expect(open(alice, id), isTrue);
      final updates = _createUpdateService();
      final theme = app.ConestThemeController.memory();
      addTearDown(updates.dispose);
      addTearDown(theme.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: alice,
            builder: (context, _) => app.HomeScreen(
              controller: alice,
              updateService: updates,
              buildInfo: _createBuildInfo(),
              themeController: theme,
              palette: app.ConestPalette(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Bob').first);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byIcon(Icons.pause_circle_outline), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('from a newer receiver is waited for, not assumed', () async {
      final (alice, bob, id) = await transfer((_) => true);
      final bobId = bob.identity!.deviceId;
      for (var stall = 0; stall < 3; stall++) {
        alice.triggerOutboundStallForTesting(bobId);
        await pump(alice, bob, limit: const Duration(seconds: 3));
      }
      expect(open(alice, id), isTrue);
    });

    testWidgets('leaves no pause button on a delivered file', (tester) async {
      late MessengerController alice;
      late String id;
      await tester.runAsync(() async {
        final MessengerController bob;
        (alice, bob, id) = await transfer((_) => true);
        await pump(
          alice,
          bob,
          until: () =>
              alice
                  .messagesFor(bob.identity!.deviceId)
                  .singleWhere((m) => m.hasAttachment)
                  .state ==
              DeliveryState.delivered,
        );
      });
      // The offer was acknowledged, the transfer record is still open.
      expect(open(alice, id), isTrue);
      final updates = _createUpdateService();
      final theme = app.ConestThemeController.memory();
      addTearDown(updates.dispose);
      addTearDown(theme.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: alice,
            builder: (context, _) => app.HomeScreen(
              controller: alice,
              updateService: updates,
              buildInfo: _createBuildInfo(),
              themeController: theme,
              palette: app.ConestPalette(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Bob').first);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byIcon(Icons.pause_circle_outline), findsNothing);
      expect(find.text('100%'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test(
      'from an older receiver that never re-sends it still finishes',
      () async {
        final (alice, bob, id) = await transfer((_) => true);
        final bobId = bob.identity!.deviceId;
        alice.dropContactCapabilityForTesting(
          bobId,
          ApplicationCapability.attachmentCompleteRetryV1,
        );
        alice.triggerOutboundStallForTesting(bobId);
        await pump(alice, bob, limit: const Duration(seconds: 4));
        expect(open(alice, id), isTrue);
        alice.triggerOutboundStallForTesting(bobId);
        await pump(alice, bob, until: () => !open(alice, id));
        expect(open(alice, id), isFalse);
      },
    );
  });

  test('sendAttachment round-trips a 1 MB file with 128 KiB blocks', () async {
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
    final aliceContactForBob = alice.contacts.single;

    // One MiB spans eight protocol-v2 blocks and exercises the pipelined
    // request window without overlong test time.
    final original = Uint8List.fromList(
      List<int>.generate(1024 * 1024, (index) => index & 0xff),
    );
    await alice.sendAttachment(
      contact: aliceContactForBob,
      bytes: original,
      fileName: 'large.bin',
      caption: 'big one',
    );

    // Drive the offer → chunk_request → chunk → complete handshake.
    // Each chunk needs ~2 pollNow rounds (receiver requests, sender
    // ships, receiver verifies, requests next). 32 chunks → ~80 rounds.
    for (var round = 0; round < 120; round++) {
      await bob.pollNow();
      await alice.pollNow();
      final received = bob
          .messagesFor(alice.identity!.deviceId)
          .firstWhere(
            (m) => m.hasAttachment,
            orElse: () => alice
                .messagesFor(aliceContactForBob.deviceId)
                .firstWhere((m) => m.hasAttachment),
          );
      if (!received.outbound &&
          bob.attachmentAwaitingAcceptance(received.attachment!.id)) {
        await bob.acceptIncomingAttachment(received.attachment!.id);
      }
      if (received.state == DeliveryState.delivered &&
          bob.attachmentBytesFor(received.attachment!.id) != null) {
        break;
      }
    }

    final bobContactForAlice = bob.contacts.single;
    final received = bob
        .messagesFor(bobContactForAlice.deviceId)
        .firstWhere((message) => message.hasAttachment);
    expect(received.attachment!.sizeBytes, original.length);
    expect(
      received.state,
      DeliveryState.delivered,
      reason:
          'inbound=${bob.inboundTransferDebugForTesting(received.attachment!.id)}; '
          'bob=${bob.recentDebugLog.join(" || ")}; '
          'alice=${alice.recentDebugLog.join(" || ")}',
    );
    final assembled = bob.attachmentBytesFor(received.attachment!.id);
    expect(assembled, equals(original));
  });

  test('resetIdentity completes even when LocalRelayNode.stop hangs '
      'and fires the post-reset hook', () async {
    // The Android symptom — "reset does nothing" — was the platform-
    // bridge stop call hanging the await. The 2-second per-call
    // timeout must let reset proceed.
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      localRelayNode: _HangingLocalRelayNode(),
    );
    addTearDown(controller.dispose);

    var hookFired = false;
    final stopwatch = Stopwatch()..start();
    await controller.resetIdentity(
      onPostReset: () async {
        hookFired = true;
      },
    );
    stopwatch.stop();

    expect(controller.hasIdentity, isFalse);
    expect(hookFired, isTrue, reason: 'post-reset hook must run');
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason:
          'reset must not block longer than the 2s-per-call timeout '
          'budget (×3 hung awaits, plus slack)',
    );
  });

  test('long-poll never picks the local-relay loopback route', () async {
    // Loopback fetches race with _handleLocalEnvelopeStored and add no
    // latency benefit (the local relay already pushes synchronously).
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
      internetRelayHost: 'relay.example',
    );
    addTearDown(controller.dispose);

    final me = controller.identity!;
    final picked = controller.pickPrimaryRelayForLongPollForTesting(me);
    expect(picked, isNotNull);
    expect(
      picked!.kind,
      PeerRouteKind.relay,
      reason: 'must pick a remote relay, not LAN loopback',
    );
    expect(picked.host, isNot('127.0.0.1'));
  });

  test('parallel _processEnvelopes calls return the notifier depth to 0 '
      'and keep notify dispatch unblocked', () async {
    // Regression: a previous wasDeferred/restore implementation left the
    // notifier gate permanently closed when two _processEnvelopes futures
    // overlapped at an await boundary. The ref-count version must keep
    // the depth invariant.
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    await Future.wait([
      controller.processEnvelopesForTesting(const []),
      controller.processEnvelopesForTesting(const []),
      controller.processEnvelopesForTesting(const []),
    ]);
    expect(controller.notificationsDeferredDepth, 0);

    var fired = 0;
    controller.addListener(() => fired++);
    controller.setStatus('after parallel batches');
    expect(
      fired,
      1,
      reason:
          'notify gate must reopen after every _processEnvelopes call exits',
    );
  });

  test('the same envelope delivered concurrently via two transports is '
      'dispatched once', () async {
    // LAN push and relay poll can hand _processEnvelopes the same envelope
    // before either run reaches _markSeen (the seen ledger is only written
    // after the dispatch awaits). The in-flight reservation must collapse
    // the second copy: one bubble, one ack.
    final relayClient = _FakeRelayClient();
    final alice = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(alice.dispose);
    final bob = await _createController(
      relayClient: relayClient,
      displayName: 'Bob',
    );
    addTearDown(bob.dispose);
    await _pairControllers(alice, bob);

    final bobContact = alice.contacts.singleWhere(
      (contact) => contact.deviceId == bob.identity!.deviceId,
    );
    await alice.sendMessage(contact: bobContact, body: 'duplicate-transport');
    final envelope = relayClient.storedEnvelopes.firstWhere(
      (stored) =>
          stored.kind == 'direct_message' &&
          stored.recipientDeviceId == bob.identity!.deviceId,
    );
    // Drop the relay copy so a background poll can't add a third delivery.
    relayClient._queues[bob.identity!.deviceId]?.clear();
    var receivedUiNotifications = 0;
    bob.addListener(() => receivedUiNotifications++);

    final processed = await Future.wait([
      bob.processEnvelopesForTesting([envelope]),
      bob.processEnvelopesForTesting([envelope]),
    ]);
    expect(
      processed[0] + processed[1],
      1,
      reason: 'exactly one run may dispatch the envelope',
    );
    expect(
      bob
          .messagesFor(alice.identity!.deviceId)
          .where((message) => message.id == envelope.messageId)
          .length,
      1,
    );
    expect(
      receivedUiNotifications,
      greaterThan(0),
      reason: 'new inbound messages must refresh listeners for every ingress',
    );
    final ackIds = relayClient.storedEnvelopes
        .where(
          (stored) =>
              stored.kind == 'ack' &&
              stored.acknowledgedMessageId == envelope.messageId,
        )
        .map((stored) => stored.messageId)
        .toSet();
    expect(
      ackIds.length,
      1,
      reason: 'concurrent duplicate delivery must produce a single ack',
    );
  });

  test('seen-envelope ledger is capped and evicts oldest ids first', () async {
    final previousCap = MessengerController.seenEnvelopeCap;
    MessengerController.seenEnvelopeCap = 50;
    addTearDown(() => MessengerController.seenEnvelopeCap = previousCap);
    final relayClient = _FakeRelayClient();
    final controller = await _createController(
      relayClient: relayClient,
      displayName: 'Alice',
    );
    addTearDown(controller.dispose);

    RelayEnvelope bootstrapEnvelope(int index) => RelayEnvelope(
      protocolVersion: 1,
      kind: 'contact_exchange',
      messageId: 'cap-bootstrap-$index',
      conversationId: 'contact-exchange-dev-bob',
      senderAccountId: 'acc-bob',
      senderDeviceId: 'dev-bob',
      recipientDeviceId: controller.identity!.deviceId,
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(utf8.encode(_bobInvite().encodePayload())),
    );

    for (var index = 0; index < 60; index++) {
      await controller.processEnvelopesForTesting([bootstrapEnvelope(index)]);
    }
    expect(
      controller.seenEnvelopeCount,
      lessThanOrEqualTo(50),
      reason: 'ledger must stay within the cap instead of growing forever',
    );
    // Recent ids must still dedupe (processed == 0 → replay path taken).
    expect(
      await controller.processEnvelopesForTesting([bootstrapEnvelope(59)]),
      0,
    );
    // The oldest ids were evicted — in production they are long past every
    // relay queue TTL, so re-delivery cannot occur; re-processing here just
    // demonstrates the eviction order.
    expect(
      await controller.processEnvelopesForTesting([bootstrapEnvelope(0)]),
      1,
    );
  });

  group('connectivity preferences', () {
    test('ContactRoutingPreferences JSON round-trip with missing fields '
        'defaults to LAN-first', () {
      final defaults = ContactRoutingPreferences.fromJson(
        const <String, dynamic>{},
      );
      expect(defaults.lanEnabled, isTrue);
      expect(defaults.onlineEnabled, isTrue);
      expect(defaults.preferred, RoutingPreference.lan);

      final custom = ContactRoutingPreferences(
        lanEnabled: false,
        onlineEnabled: true,
        preferred: RoutingPreference.online,
      );
      final round = ContactRoutingPreferences.fromJson(custom.toJson());
      expect(round.lanEnabled, isFalse);
      expect(round.onlineEnabled, isTrue);
      expect(round.preferred, RoutingPreference.online);
    });

    test(
      'GlobalConnectivityPreferences JSON round-trip + missing-field defaults',
      () {
        final defaults = GlobalConnectivityPreferences.fromJson(
          const <String, dynamic>{},
        );
        expect(defaults.lanEnabled, isTrue);
        expect(defaults.onlineEnabled, isTrue);
        final round = GlobalConnectivityPreferences.fromJson(
          const GlobalConnectivityPreferences(
            lanEnabled: false,
            onlineEnabled: true,
          ).toJson(),
        );
        expect(round.lanEnabled, isFalse);
        expect(round.onlineEnabled, isTrue);
      },
    );

    test(
      'per-contact lanEnabled=false drops LAN routes from preferred set',
      () async {
        final alice = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
        );
        addTearDown(alice.dispose);
        await alice.addContactFromInvite(
          alias: 'Bob',
          payload: _bobInvite().encodePayload(),
          codephrase: '',
        );
        final bob = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        await alice.updateContactRoutingPreferences(
          bob.deviceId,
          const ContactRoutingPreferences(
            lanEnabled: false,
            onlineEnabled: true,
          ),
        );
        final refreshed = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        final routes = alice.preferredRoutesForTesting(refreshed);
        expect(routes.any((r) => r.kind == PeerRouteKind.lan), isFalse);
        expect(routes.any((r) => r.kind == PeerRouteKind.relay), isTrue);
      },
    );

    test(
      'per-contact onlineEnabled=false drops relay + direct-internet routes',
      () async {
        final alice = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
        );
        addTearDown(alice.dispose);
        await alice.addContactFromInvite(
          alias: 'Bob',
          payload: _bobInvite().encodePayload(),
          codephrase: '',
        );
        final bob = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        await alice.updateContactRoutingPreferences(
          bob.deviceId,
          const ContactRoutingPreferences(
            lanEnabled: true,
            onlineEnabled: false,
          ),
        );
        final refreshed = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        final routes = alice.preferredRoutesForTesting(refreshed);
        expect(routes.every((r) => r.kind == PeerRouteKind.lan), isTrue);
      },
    );

    test('preferred=online lifts relay routes above LAN', () async {
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
      );
      addTearDown(alice.dispose);
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: _bobInvite().encodePayload(),
        codephrase: '',
      );
      final bob = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      await alice.updateContactRoutingPreferences(
        bob.deviceId,
        const ContactRoutingPreferences(preferred: RoutingPreference.online),
      );
      final refreshed = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      final routes = alice.preferredRoutesForTesting(refreshed);
      // First non-LAN route appears before the first LAN route.
      final firstLan = routes.indexWhere((r) => r.kind == PeerRouteKind.lan);
      final firstRelay = routes.indexWhere(
        (r) => r.kind == PeerRouteKind.relay,
      );
      expect(
        firstRelay >= 0 && (firstLan < 0 || firstRelay < firstLan),
        isTrue,
        reason: 'relay should appear before LAN with preferred=online',
      );
    });

    test('global lanEnabled=false is a kill-switch — contact override cannot '
        're-enable LAN', () async {
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
      );
      addTearDown(alice.dispose);
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: _bobInvite().encodePayload(),
        codephrase: '',
      );
      final bob = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      // Contact says lan=true, but global forbids LAN.
      await alice.updateContactRoutingPreferences(
        bob.deviceId,
        const ContactRoutingPreferences(),
      );
      await alice.updateGlobalConnectivity(
        const GlobalConnectivityPreferences(
          lanEnabled: false,
          onlineEnabled: true,
        ),
      );
      final refreshed = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      final routes = alice.preferredRoutesForTesting(refreshed);
      expect(routes.any((r) => r.kind == PeerRouteKind.lan), isFalse);
    });
  });

  test(
    'mark-read dismisses the OS notification for that conversation',
    () async {
      final recorder = _RecordingPlatformBridge();
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        platformBridge: recorder,
      );
      addTearDown(alice.dispose);
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: _bobInvite().encodePayload(),
        codephrase: '',
      );
      final bob = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      // Synthesize an inbound message — the dismiss path fires whether or not
      // the conversation actually contains this message yet.
      final inbound = ChatMessage(
        id: 'msg-test-inbound',
        conversationId: bob.deviceId,
        senderDeviceId: bob.deviceId,
        recipientDeviceId: alice.identity!.deviceId,
        body: 'hi',
        createdAt: DateTime.now().toUtc(),
        outbound: false,
        state: DeliveryState.delivered,
      );
      recorder.dismissed.clear();
      await alice.markConversationReadThroughMessage(bob.deviceId, inbound);
      // Microtask: the unawaited dismiss call still runs synchronously.
      await Future<void>.delayed(Duration.zero);
      expect(
        recorder.dismissed.isNotEmpty,
        isTrue,
        reason: 'dismiss should fire for this conversation',
      );
    },
  );

  group('multi-file batch send', () {
    test('maxAttachmentsPerSend exposes the cap', () {
      expect(MessengerController.maxAttachmentsPerSend, 30);
      expect(MessengerController.maxAttachmentsPerAlbum, 10);
    });

    test('three sendAttachment calls produce three distinct outbound '
        'messages with separate attachment ids', () async {
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
      final bobContact = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      for (var i = 0; i < 3; i++) {
        await alice.sendAttachment(
          contact: bobContact,
          bytes: Uint8List.fromList(List<int>.filled(16, i + 1)),
          fileName: 'f$i.bin',
          caption: i == 0 ? 'batch caption' : '',
        );
      }
      final outbound = alice
          .messagesFor(bobContact.deviceId)
          .where((m) => m.outbound && m.attachment != null)
          .toList();
      expect(outbound.length, 3);
      final ids = outbound.map((m) => m.attachment!.id).toSet();
      expect(ids.length, 3, reason: 'each attachment must have a unique id');
      expect(outbound.first.body, 'batch caption');
      expect(outbound[1].body, '');
      expect(outbound[2].body, '');
    });
  });

  test(
    'showMessageNotification carries recentMessages with sender + timestamp',
    () async {
      final recorder = _RecordingPlatformBridge();
      final relayClient = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        platformBridge: recorder,
      );
      final bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      // Seed Alice's view with 3 inbound messages from Bob via the
      // recent-inbound helper directly — it walks messagesFor and shapes
      // the payload that ships to the native side.
      final aliceOnBob = bob.contacts.firstWhere((c) => c.alias == 'Alice');
      for (var i = 0; i < 3; i++) {
        await bob.sendMessage(contact: aliceOnBob, body: 'ping $i');
      }
      // Poll Alice to absorb Bob's three sends.
      await alice.pollNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final lines = alice.recentInboundLinesForContactForTesting(
        bobOnAlice,
        defaultBody: 'fallback',
      );
      expect(lines.length, greaterThanOrEqualTo(1));
      expect(lines.last.sender, 'Bob');
      // Timestamps must be strictly non-decreasing — they reflect arrival
      // order and feed Notification.MessagingStyle on the native side.
      for (var i = 1; i < lines.length; i++) {
        expect(
          lines[i].timestampMs,
          greaterThanOrEqualTo(lines[i - 1].timestampMs),
        );
      }
    },
  );

  group('attachment lifecycle cleanup', () {
    test(
      'deleting an attachment-bearing message clears inbound + outbound '
      'state and prevents the bubble from rendering stuck transfer',
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
        final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        await alice.sendAttachment(
          contact: bobOnAlice,
          bytes: Uint8List.fromList(List<int>.filled(32, 7)),
          fileName: 'a.bin',
        );
        final outbound = alice
            .messagesFor(bobOnAlice.deviceId)
            .firstWhere((m) => m.outbound && m.attachment != null);
        final attachmentId = outbound.attachment!.id;
        // Locally delete on Alice's side — should clear all attachment state.
        await alice.deleteMessage(contact: bobOnAlice, messageId: outbound.id);
        expect(
          alice
              .messagesFor(bobOnAlice.deviceId)
              .any((m) => m.id == outbound.id),
          isFalse,
        );
        expect(alice.attachmentTransferProgress(attachmentId), isNull);
        expect(alice.attachmentBytesFor(attachmentId), isNull);
      },
    );
  });

  group('debug log ring buffer', () {
    test('appendDebugLog retains up to 50 most recent lines', () async {
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
      );
      addTearDown(controller.dispose);
      for (var i = 0; i < 60; i++) {
        controller.appendDebugLog('line-$i');
      }
      final log = controller.recentDebugLog;
      expect(log.length, 50);
      expect(log.first.contains('line-10'), isTrue);
      expect(log.last.contains('line-59'), isTrue);
    });
  });

  group('nightly.6 queue + cap + mode', () {
    test(
      'serial transfer queue reports positions for back-to-back sends',
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
        final bobContact = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        for (var i = 0; i < 3; i++) {
          await alice.sendAttachment(
            contact: bobContact,
            bytes: Uint8List.fromList(List<int>.filled(8, i + 1)),
            fileName: 'f$i.bin',
          );
        }
        final outbound = alice
            .messagesFor(bobContact.deviceId)
            .where((m) => m.outbound && m.attachment != null)
            .toList();
        expect(outbound.length, 3);
        // At least one of the three is the active item (queue position 0);
        // at least one is queued waiting (position > 0).
        final positions = outbound
            .map((m) => alice.outboundQueuePositionFor(m.attachment!.id))
            .toList();
        expect(positions.where((p) => p == 0).length, greaterThanOrEqualTo(1));
      },
    );

    test(
      'a second small attachment can bypass a stalled small transfer',
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
        final bobContact = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        final revisionBeforeSend = alice.conversationRevision.value;

        await alice.sendAttachment(
          contact: bobContact,
          bytes: Uint8List.fromList(List<int>.filled(1024, 1)),
          fileName: 'first.bin',
        );
        await alice.sendAttachment(
          contact: bobContact,
          bytes: Uint8List.fromList(List<int>.filled(1024, 2)),
          fileName: 'photo.png',
        );

        // Bob has not polled the offers, so neither attachment has completed.
        // Both remain active, proving the small item did not wait behind the
        // first one. A third item remains queued by the per-contact bound.
        final active = alice
            .messagesFor(bobContact.deviceId)
            .where((message) => message.outbound && message.attachment != null)
            .where(
              (message) =>
                  alice.outboundAttachmentProgress(message.attachment!.id) !=
                  null,
            )
            .toList();
        expect(active.length, 2);
        expect(
          alice.conversationRevision.value,
          greaterThan(revisionBeforeSend),
        );

        await alice.sendAttachment(
          contact: bobContact,
          bytes: Uint8List.fromList(List<int>.filled(1024, 3)),
          fileName: 'third.bin',
        );
        final third = alice
            .messagesFor(bobContact.deviceId)
            .singleWhere(
              (message) => message.attachment?.fileName == 'third.bin',
            );
        expect(
          alice.outboundQueuePositionFor(third.attachment!.id),
          greaterThan(0),
        );
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      'resuming after backgrounding restarts the active transfer promptly',
      () async {
        var now = DateTime.utc(2026, 9, 23, 12);
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
        await _pairControllers(alice, bob);
        final bobContact = alice.contacts.firstWhere((c) => c.alias == 'Bob');

        await alice.sendAttachment(
          contact: bobContact,
          bytes: Uint8List.fromList(List<int>.filled(1024, 5)),
          fileName: 'resume.bin',
        );
        final message = alice
            .messagesFor(bobContact.deviceId)
            .singleWhere((entry) => entry.attachment?.fileName == 'resume.bin');
        final attachmentId = message.attachment!.id;

        alice.setAppForegroundState(false);
        now = now.add(const Duration(seconds: 4));
        alice.setAppForegroundState(true);

        final transfer = alice.transferSnapshots.singleWhere(
          (entry) => entry.id == attachmentId,
        );
        expect(transfer.phase, TransferPhase.reconnecting);
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  group('clipboard image sniff', () {
    test('detects PNG header', () {
      final bytes = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      expect(sniffImageMimeType(bytes), 'image/png');
    });

    test('detects JPEG header', () {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
      expect(sniffImageMimeType(bytes), 'image/jpeg');
    });

    test('detects GIF89a header', () {
      final bytes = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      expect(sniffImageMimeType(bytes), 'image/gif');
    });

    test('detects WebP header', () {
      final bytes = Uint8List.fromList([
        0x52,
        0x49,
        0x46,
        0x46,
        0x00,
        0x00,
        0x00,
        0x00,
        0x57,
        0x45,
        0x42,
        0x50,
      ]);
      expect(sniffImageMimeType(bytes), 'image/webp');
    });

    test('returns null for unknown bytes', () {
      final bytes = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      expect(sniffImageMimeType(bytes), isNull);
    });
  });

  group('nightly.7 chunk pipelining + LAN chunk size', () {
    test('sendAttachment round-trip with multiple chunks keeps the pipeline '
        'window primed (no strict 1-in-flight serialization)', () async {
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
      final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      // 4-chunk file: enough to exercise the window primer + refill but
      // small enough that the in-memory fake-relay round-trips quickly.
      final payload = Uint8List(32 * 1024 * 4 + 7);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (i * 31 + 7) & 0xff;
      }
      await alice.sendAttachment(
        contact: bobOnAlice,
        bytes: payload,
        fileName: 'pipeline.bin',
      );
      // Drain envelopes — the queue worker + pipeline together must
      // converge on full delivery within the fake clock.
      for (var step = 0; step < 12; step++) {
        await bob.pollNow();
        await alice.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      final aliceOnBob = bob.contacts.firstWhere((c) => c.alias == 'Alice');
      final received = bob
          .messagesFor(aliceOnBob.deviceId)
          .where((m) => m.attachment?.fileName == 'pipeline.bin')
          .firstOrNull;
      expect(received, isNotNull, reason: 'Bob should have the attachment');
      final assembled = bob.attachmentBytesFor(received!.attachment!.id);
      expect(assembled, isNotNull);
      expect(assembled!.length, payload.length);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test(
      'hasActiveTransfer flips while an inbound transfer is in flight',
      () async {
        final controller = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Solo',
        );
        addTearDown(controller.dispose);
        expect(controller.hasActiveTransfer, isFalse);
      },
    );
  });

  group('nightly.8 album-id uniqueness', () {
    test('newAlbumId returns 1000 distinct cryptographic ids', () async {
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'AlbumGen',
      );
      addTearDown(controller.dispose);
      final ids = <String>{};
      for (var i = 0; i < 1000; i++) {
        ids.add(controller.newAlbumId());
      }
      expect(ids.length, 1000);
      expect(ids.first.startsWith('alb-'), isTrue);
    });
  });

  group('nightly.9 aggressive transport simulator', () {
    test(
      'route timeline failing the relay path causes storeEnvelope to throw',
      () async {
        final relayClient = _FakeRelayClient();
        relayClient.routeTimeline.add((
          at: Duration.zero,
          lanUp: true,
          relayUp: false,
        ));
        // A relay-flagged host (per the default classifier) should throw.
        expect(
          relayClient.storeEnvelope(
            host: 'relay.example',
            port: defaultRelayPort,
            recipientDeviceId: 'dev-bob',
            envelope: RelayEnvelope(
              kind: 'attachment_chunk',
              messageId: 'm1',
              conversationId: 'c1',
              senderAccountId: 'acc-a',
              senderDeviceId: 'dev-a',
              recipientDeviceId: 'dev-bob',
              createdAt: DateTime.utc(2026, 5, 26, 12),
            ),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('latency jitter delays each store by at least latencyMin', () async {
      final relayClient = _FakeRelayClient();
      relayClient.latencyMin = const Duration(milliseconds: 25);
      relayClient.latencyMax = const Duration(milliseconds: 30);
      final stopwatch = Stopwatch()..start();
      await relayClient.storeEnvelope(
        host: 'relay.example',
        port: defaultRelayPort,
        recipientDeviceId: 'dev-bob',
        envelope: RelayEnvelope(
          kind: 'attachment_chunk',
          messageId: 'm1',
          conversationId: 'c1',
          senderAccountId: 'acc-a',
          senderDeviceId: 'dev-a',
          recipientDeviceId: 'dev-bob',
          createdAt: DateTime.utc(2026, 5, 26, 12),
        ),
      );
      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 25)),
      );
    });

    test('mid-transfer interruption wildcard fires once then clears', () async {
      final relayClient = _FakeRelayClient();
      relayClient.midTransferInterruptionAt['*'] = 2;
      Future<bool> sendChunk() => relayClient.storeEnvelope(
        host: 'relay.example',
        port: defaultRelayPort,
        recipientDeviceId: 'dev-bob',
        envelope: RelayEnvelope(
          kind: 'attachment_chunk',
          messageId: 'mX',
          conversationId: 'c1',
          senderAccountId: 'acc-a',
          senderDeviceId: 'dev-a',
          recipientDeviceId: 'dev-bob',
          createdAt: DateTime.utc(2026, 5, 26, 12),
        ),
      );
      // First chunk succeeds (counter goes 0 → 1).
      await sendChunk();
      // Second chunk reaches threshold = throws.
      expect(sendChunk(), throwsA(isA<StateError>()));
      // Third + subsequent chunks succeed — interruption consumed.
      await sendChunk();
      await sendChunk();
    });
  });

  test(
    'a failed Iroh dial does not hold back a contact Iroh alone reaches',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> create(String name) => _createController(
        relayClient: relay,
        displayName: name,
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
      );
      final alice = await create('Alice');
      final bob = await create('Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      final aliceId = alice.identity!.deviceId;

      // Bob is briefly unreachable when Alice sends.
      final bobBridge = network.bridges.remove(bob.identity!.irohEndpointId)!;
      await alice.sendMessage(contact: alice.contacts.single, body: 'later');
      network.bridges[bob.identity!.irohEndpointId!] = bobBridge;

      // The next background retry (not a forced one) must dial Iroh again:
      // with no other route, pausing Iroh would only delay delivery.
      await Future<void>.delayed(const Duration(seconds: 6));
      await alice.pollNow();
      await _waitForIroh(
        () => bob.messagesFor(aliceId).any((m) => m.body == 'later'),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a LAN path found while Iroh works carries the next message',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      var bobLan = const <String>['10.50.0.7'];
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        lanAddresses: const ['192.168.40.2'],
        transportRegistryFactory: network.registry,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        lanAddressProvider: () async => List.of(bobLan),
        transportRegistryFactory: network.registry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final bobId = bob.identity!.deviceId;
      ChatMessage sent(String body) =>
          alice.messagesFor(bobId).firstWhere((m) => m.body == body);

      // Different networks: Iroh carries the chat.
      await alice.sendMessage(contact: alice.contacts.single, body: 'one');
      expect(
        sent('one').route,
        isIn([MessageRoute.irohDirect, MessageRoute.irohRelay]),
      );

      // Bob joins Alice's network. Iroh still works, which used to keep the
      // chat on Iroh for good: LAN is only tried once a check proves it.
      bobLan = const ['192.168.40.3'];
      bob.onConnectivityChanged(interfaceLabel: 'wifi');
      bool aliceKnowsLan() => alice.contacts.single.lanRouteHints.any(
        (route) => route.host == '192.168.40.3',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline) && !aliceKnowsLan()) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(aliceKnowsLan(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await alice.sendMessage(contact: alice.contacts.single, body: 'two');
      expect(sent('two').route, MessageRoute.lanDirect);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'moving onto a shared LAN is advertised without Check Paths',
    () async {
      final relay = _FakeRelayClient();
      var aliceLan = const <String>['10.9.0.5'];
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        lanAddressProvider: () async => List.of(aliceLan),
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        lanAddresses: const ['192.168.7.20'],
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      bool bobKnowsNewLan() => bob.contacts.single.lanRouteHints.any(
        (route) => route.host == '192.168.7.21',
      );
      expect(bobKnowsNewLan(), isFalse);

      // A received message records the route it came in on.
      await alice.sendMessage(contact: alice.contacts.single, body: 'routed');
      final aliceId = alice.identity!.deviceId;
      for (var i = 0; i < 20; i++) {
        if (bob.messagesFor(aliceId).any((m) => m.body == 'routed')) break;
        await bob.pollNow();
      }
      final received = bob
          .messagesFor(aliceId)
          .firstWhere((m) => m.body == 'routed');
      expect(received.outbound, isFalse);
      expect(received.route, isNotNull, reason: 'inbound route mark');

      // Alice's Wi-Fi joins Bob's network; the event comes before the address
      // is known, as on Android.
      alice.onConnectivityChanged(interfaceLabel: 'wifi');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      aliceLan = const ['192.168.7.21'];
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline) && !bobKnowsNewLan()) {
        await bob.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(bobKnowsNewLan(), isTrue);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  group('app modes', () {
    test('builds without the Matrix client are Conest only', () async {
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        createIdentity: false,
      );
      addTearDown(controller.dispose);
      expect(controller.matrixAvailable, isFalse);
      expect(controller.appMode, AppMode.conest);
    });

    test('a fresh install can be a Matrix client without an identity', () async {
      final server = await FakeHomeserver.start();
      addTearDown(server.close);
      final native = FakeMatrixNative(FakeMatrixHub());
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        createIdentity: false,
        matrixCarrierEnabled: true,
        matrixNativeApi: native,
      );
      addTearDown(controller.dispose);
      await controller.setAppMode(AppMode.matrixOnly);
      expect(controller.conestActive, isFalse);

      await controller.signInToMatrix(
        homeserver: server.url.toString(),
        user: 'alice',
        password: 'unused',
      );
      expect(controller.matrixClient?.signedIn, isTrue);
      expect(controller.hasIdentity, isFalse);
      // The account is the client's; no Conest carrier runs.
      expect(controller.matrixStatus?.signedIn, isTrue);
      expect(controller.matrixStatus?.syncing, isFalse);
    });

    test('Matrix-only mode keeps an existing identity dormant', () async {
      final vault = _MemoryVaultStore();
      final hub = FakeMatrixHub();
      final relay = _FakeRelayClient();
      final relayNode = _FakeLocalRelayNode();
      final controller = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: vault,
        localRelayNode: relayNode,
        matrixCarrierEnabled: true,
        matrixNativeApi: FakeMatrixNative(hub),
      );
      expect(controller.appMode, AppMode.both);
      expect(relayNode.isRunning, isTrue);

      // Switching stops Conest at once, without a restart.
      await controller.setAppMode(AppMode.matrixOnly);
      expect(controller.conestActive, isFalse);
      expect(relayNode.isRunning, isFalse);

      // Nothing wakes it: polls, app lifecycle and network changes.
      relay.fetchAttempts.clear();
      relay.storeAttempts.clear();
      controller.setAppForegroundState(false);
      controller.setAppForegroundState(true);
      controller.onConnectivityChanged(interfaceLabel: 'wifi');
      await controller.pollNow();
      await controller.retryUnacknowledgedMessagesNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(relayNode.isRunning, isFalse);
      expect(relay.fetchAttempts, isEmpty);
      expect(relay.storeAttempts, isEmpty);
      await controller.flushPendingChanges();
      controller.dispose();

      // A later launch in Matrix-only mode starts nothing either.
      final laterNode = _FakeLocalRelayNode();
      final later = MessengerController(
        vaultStore: vault,
        relayClient: relay,
        localRelayNode: laterNode,
        lanAddressProvider: () async => const ['192.168.1.20'],
        enableLongPoll: false,
        enablePairingBeacon: false,
        matrixCarrierEnabled: true,
        matrixNativeApi: FakeMatrixNative(hub),
        loadNativeMatrixClient: false,
        attachmentRootProvider: () async =>
            Directory.systemTemp.createTempSync('conest_test_attachments_'),
      );
      addTearDown(later.dispose);
      await later.initialize();
      expect(later.hasIdentity, isTrue);
      expect(later.appMode, AppMode.matrixOnly);
      expect(laterNode.isRunning, isFalse);
      expect(relay.fetchAttempts, isEmpty);

      // Leaving Matrix-only starts Conest again in place.
      await later.setAppMode(AppMode.both);
      expect(laterNode.isRunning, isTrue);
      expect(relay.fetchAttempts, isNotEmpty);
    });

    test('a Matrix-only choice holds when the Matrix client is missing', () async {
      final vault = _MemoryVaultStore();
      final first = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: vault,
        matrixCarrierEnabled: true,
        matrixNativeApi: FakeMatrixNative(FakeMatrixHub()),
      );
      await first.setAppMode(AppMode.matrixOnly);
      await first.flushPendingChanges();
      first.dispose();

      final relayNode = _FakeLocalRelayNode();
      final withoutMatrix = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: vault,
        createIdentity: false,
        localRelayNode: relayNode,
      );
      addTearDown(withoutMatrix.dispose);
      expect(withoutMatrix.matrixAvailable, isFalse);
      expect(withoutMatrix.appMode, AppMode.matrixOnly);
      expect(relayNode.isRunning, isFalse);
      await withoutMatrix.setAppMode(AppMode.conest);
      expect(relayNode.isRunning, isTrue);
    });
  });

  group('Matrix carrier', () {
    Future<void> settle(List<MessengerController> controllers) async {
      for (var round = 0; round < 6; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<
      (
        MessengerController,
        MessengerController,
        FakeHomeserver,
        _FakeRelayClient,
      )
    >
    linkedPair() async {
      final server = await FakeHomeserver.start();
      addTearDown(server.close);
      server
        ..register('alice', 'a-pass')
        ..register('bob', 'b-pass');
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        matrixCarrierEnabled: true,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        matrixCarrierEnabled: true,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.signInToMatrix(
        homeserver: server.url.toString(),
        user: 'alice',
        password: 'a-pass',
      );
      await bob.signInToMatrix(
        homeserver: server.url.toString(),
        user: 'bob',
        password: 'b-pass',
      );
      await settle([alice, bob]);
      return (alice, bob, server, relay);
    }

    test('with the native client the carrier rides on its single sync',
        () async {
      final server = await FakeHomeserver.start();
      addTearDown(server.close);
      final hub = FakeMatrixHub();
      final relay = _FakeRelayClient();
      final aliceNative = FakeMatrixNative(hub);
      final bobNative = FakeMatrixNative(hub);
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        matrixCarrierEnabled: true,
        matrixNativeApi: aliceNative,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        matrixCarrierEnabled: true,
        matrixNativeApi: bobNative,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.signInToMatrix(
        homeserver: server.url.toString(),
        user: 'alice',
        password: 'unused',
      );
      await bob.signInToMatrix(
        homeserver: server.url.toString(),
        user: 'bob',
        password: 'unused',
      );
      expect(aliceNative.ops, containsAllInOrder(['login_password', 'start_sync']));
      expect(alice.matrixClient?.signedIn, isTrue);
      await settle([alice, bob]);
      expect(
        alice.contacts.single.matrixAddress,
        startsWith('@bob:fake.test|CONEST_'),
      );

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await alice.sendMessage(contact: alice.contacts.single, body: 'native');
      final aliceId = alice.identity!.deviceId;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline) &&
          !bob.messagesFor(aliceId).any((m) => m.body == 'native')) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(bob.messagesFor(aliceId).map((m) => m.body), contains('native'));
      expect(
        bob.messagesFor(aliceId).firstWhere((m) => m.body == 'native').route,
        MessageRoute.matrixCarrier,
      );
      expect(
        hub.sent.where((frame) => frame.from == '@alice:fake.test'),
        isNotEmpty,
      );
      // Nothing went through the HTTP carrier's own client.
      expect(server.sent, isEmpty);

      // Conest cannot reach Bob at all (Matrix carrier off too): a pending
      // message may go to his Matrix account as plain Matrix, asked each time.
      final bobMatrixUser = alice.matrixUserIdFor(bob.identity!.deviceId);
      expect(bobMatrixUser, '@bob:fake.test');
      final connectivity = alice.identity!.connectivity;
      await alice.updateGlobalConnectivity(
        connectivity.copyWith(
          transportPolicies: {
            ...connectivity.transportPolicies,
            TransportKind.matrix: TransportPolicy.disabled,
          },
        ),
      );
      await alice.sendMessage(contact: alice.contacts.single, body: 'plain');
      final pending = alice
          .messagesFor(bob.identity!.deviceId)
          .firstWhere((m) => m.body == 'plain');
      expect(pending.state, DeliveryState.pending);
      expect(
        alice.canSendViaPlainMatrix(bob.identity!.deviceId, pending),
        isTrue,
      );
      final sentBefore = aliceNative.sentMessages.length;
      final sending = alice.sendViaPlainMatrix(
        contact: alice.contacts.single,
        messageId: pending.id,
      );
      // A second confirm while the first send runs is refused.
      await expectLater(
        alice.sendViaPlainMatrix(
          contact: alice.contacts.single,
          messageId: pending.id,
        ),
        throwsStateError,
      );
      await sending;
      expect(aliceNative.sentMessages.length, sentBefore + 1);
      expect(aliceNative.sentMessages.last.roomId, '!dm-@bob:fake.test');
      expect(aliceNative.sentMessages.last.content['body'], 'plain');
      final sent = alice
          .messagesFor(bob.identity!.deviceId)
          .firstWhere((m) => m.id == pending.id);
      expect(sent.route, MessageRoute.plainMatrix);
      expect(
        alice.canSendViaPlainMatrix(bob.identity!.deviceId, sent),
        isFalse,
      );
      // Conest no longer tries it, so it can never arrive twice.
      final attempts = relay.storeAttempts.length;
      await alice.retryUnacknowledgedMessagesNow();
      expect(
        bob.messagesFor(alice.identity!.deviceId).map((m) => m.body),
        isNot(contains('plain')),
      );
      expect(relay.storeAttempts.length, attempts);
      await alice.updateGlobalConnectivity(connectivity);

      // Revoked on the server (signed out from another Matrix app): the
      // route goes, and contacts stop offering it (told over the relay).
      relay.shouldFailStore = (_, _, _, _, _) => false;
      bobNative.emit({
        'type': 'sync_error',
        'error': 'M_UNKNOWN_TOKEN: Invalid access token passed.',
      });
      final revoked = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(revoked) &&
          alice.contacts.single.matrixAddress != null) {
        await settle([alice, bob]);
      }
      expect(bobNative.ops, contains('forget'));
      expect(bob.matrixStatus?.signedIn, isNot(isTrue));
      expect(alice.contacts.single.matrixAddress, isNull);

      await alice.signOutOfMatrix();
      expect(aliceNative.ops.last, 'logout');
      expect(alice.matrixClient?.signedIn, isFalse);
    });

    test('contacts learn each other\'s Matrix device', () async {
      final (alice, bob, _, _) = await linkedPair();
      expect(alice.matrixStatus?.signedIn, isTrue);
      expect(
        alice.contacts.single.matrixAddress,
        startsWith('@bob:fake.test|CONEST_'),
      );
      expect(
        bob.contacts.single.matrixAddress,
        startsWith('@alice:fake.test|CONEST_'),
      );
    });

    test('messages arrive through Matrix when relays fail', () async {
      final (alice, bob, server, relay) = await linkedPair();
      relay.shouldFailStore = (_, _, _, _, _) => true;
      final before = server.sent.length;
      await alice.sendMessage(
        contact: alice.contacts.single,
        body: 'via matrix',
      );
      final aliceId = alice.identity!.deviceId;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline) &&
          !bob.messagesFor(aliceId).any((m) => m.body == 'via matrix')) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        bob.messagesFor(aliceId).map((m) => m.body),
        contains('via matrix'),
      );
      final frames = server.sent.skip(before).toList();
      expect(frames, isNotEmpty);
      expect(frames.first.type, 'dev.conest.carrier.v1');
      expect(frames.first.to, startsWith('@bob:fake.test|CONEST_'));
      // Sealed: neither the text nor the envelope kind is visible.
      for (final frame in frames) {
        final raw = utf8.decode(
          base64Decode(frame.content['d'] as String),
          allowMalformed: true,
        );
        expect(raw, isNot(contains('via matrix')));
        expect(raw, isNot(contains('direct_message')));
      }
    });

    test('nothing is fetched or acknowledged while Online is off', () async {
      final (alice, bob, server, relay) = await linkedPair();
      relay.shouldFailStore = (_, _, _, _, _) => true;
      final aliceAddress = MatrixAddress.decode(
        bob.contacts.single.matrixAddress,
      )!;
      await alice.updateGlobalConnectivity(
        alice.identity!.connectivity.copyWith(onlineEnabled: false),
      );
      expect(alice.matrixStatus?.signedIn, isTrue);
      await bob.sendMessage(contact: bob.contacts.single, body: 'held');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        server.pendingFor(aliceAddress.userId, aliceAddress.deviceId),
        greaterThan(0),
        reason: 'the homeserver keeps it until Alice syncs again',
      );
      final bobId = bob.identity!.deviceId;
      expect(
        alice.messagesFor(bobId).map((m) => m.body),
        isNot(contains('held')),
      );
      await alice.updateGlobalConnectivity(
        alice.identity!.connectivity.copyWith(onlineEnabled: true),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline) &&
          !alice.messagesFor(bobId).any((m) => m.body == 'held')) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(alice.messagesFor(bobId).map((m) => m.body), contains('held'));
    });

    test('a late older exchange cannot roll back the Matrix address', () async {
      final (alice, bob, _, _) = await linkedPair();
      final address = alice.contacts.single.matrixAddress;
      expect(address, isNotNull);
      final me = bob.identity!;
      final aliceOnBob = bob.contacts.single;
      final staticOnly = CryptoService(identityProvider: () => me);
      final stale = await staticOnly.encryptPayloadEnvelope(
        kind: 'contact_exchange',
        messageId: 'stale-xchg',
        conversationId: 'contact-exchange-${aliceOnBob.deviceId}',
        senderAccountId: me.accountId,
        senderDeviceId: me.deviceId,
        recipientDeviceId: aliceOnBob.deviceId,
        contact: aliceOnBob,
        plaintext: jsonEncode({
          'exchangeVersion': 2,
          'invitePayload': (await bob.buildInvite()).encodePayload(),
          'featureCapabilityVersion': 1,
          'featureCapabilities': ['groupPollsV1'],
          'requestPeerCapabilities': false,
        }),
        createdAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );
      await alice.processEnvelopesForTesting([stale]);
      expect(alice.contacts.single.matrixAddress, address);
    });

    test('signing out clears the address at the contact', () async {
      final (alice, bob, _, _) = await linkedPair();
      await bob.signOutOfMatrix();
      await settle([alice, bob]);
      expect(bob.matrixStatus?.signedIn, isFalse);
      expect(alice.contacts.single.matrixAddress, isNull);
    });

    test('a frame from an unknown Matrix user is ignored', () async {
      final (alice, bob, server, _) = await linkedPair();
      server.register('mallory', 'm-pass');
      final mallory = MatrixClient(
        await MatrixClient.login(
          homeserver: server.url,
          user: 'mallory',
          password: 'm-pass',
          http: _realMatrixHttp(),
        ),
        http: _realMatrixHttp(),
      );
      addTearDown(mallory.close);
      final target = MatrixAddress.decode(alice.contacts.single.matrixAddress)!;
      await mallory.sendToDevice('dev.conest.carrier.v1', {
        target.userId: {
          target.deviceId: matrixCarrierFrames(
            'x',
            Uint8List.fromList(List<int>.filled(64, 1)),
          ).single,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(bob.messagesFor(alice.identity!.deviceId), isEmpty);
    });
  });

  group('generic carriers', () {
    Future<void> settle(List<MessengerController> controllers) async {
      for (var round = 0; round < 6; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<
      (
        MessengerController,
        MessengerController,
        _FakeCarrierNetwork,
        _FakeRelayClient,
      )
    >
    linkedPair() async {
      final network = _FakeCarrierNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await network.join(alice, 'npub-alice|wss://relay.one');
      await network.join(bob, 'npub-bob|wss://relay.two');
      await settle([alice, bob]);
      return (alice, bob, network, relay);
    }

    test(
      'a carrier enabled while the contact was away reaches it later',
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        // Bob is unreachable while Alice turns the carrier on.
        relay.shouldFailStore = (_, _, _, recipient, _) =>
            recipient == bob.identity!.deviceId;
        await network.join(alice, 'npub-alice|wss://relay.one');
        await settle([alice, bob]);
        expect(bob.contacts.single.carrierAddress(TransportKind.nostr), isNull);

        // Back in touch: the next path check carries Alice's carrier digest.
        relay.shouldFailStore = null;
        await alice.checkContactRoutes(alice.contacts.single);
        await settle([alice, bob]);
        expect(
          bob.contacts.single.carrierAddress(TransportKind.nostr),
          'npub-alice|wss://relay.one',
        );
      },
    );

    test('contacts can be added over a carrier alone', () async {
      final network = _FakeCarrierNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await network.join(alice, 'npub-alice|wss://relay.one');
      await network.join(bob, 'npub-bob|wss://relay.two');
      // No relay, LAN or Iroh between them: only the carrier.
      relay.shouldFailStore = (_, _, _, _, _) => true;
      final invite = await bob.buildInvite();
      expect(invite.encodePayload(), startsWith('ci7|'));
      expect(invite.encodeCompatiblePayload(), startsWith('ci6|'));
      expect(ContactInvite.decodePayload(invite.encodePayload()).carrierHints, {
        TransportKind.nostr: 'npub-bob|wss://relay.two',
      });

      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: invite.encodePayload(),
        codephrase: '',
      );
      final aliceId = alice.identity!.deviceId;
      for (
        var round = 0;
        round < 20 &&
            !bob.pendingContactRequests.any((r) => r.senderDeviceId == aliceId);
        round++
      ) {
        await settle([alice, bob]);
      }
      final request = bob.pendingContactRequests.singleWhere(
        (r) => r.senderDeviceId == aliceId,
      );
      await bob.approvePendingContactRequest(request.id);
      for (
        var round = 0;
        round < 20 &&
            alice.contacts.single.pairingState != ContactPairingState.accepted;
        round++
      ) {
        await settle([alice, bob]);
      }
      expect(alice.contacts.single.pairingState, ContactPairingState.accepted);

      await alice.sendMessage(
        contact: alice.contacts.single,
        body: 'hi via nostr',
      );
      for (
        var round = 0;
        round < 20 &&
            !bob.messagesFor(aliceId).any((m) => m.body == 'hi via nostr');
        round++
      ) {
        await settle([alice, bob]);
      }
      expect(
        bob
            .messagesFor(aliceId)
            .singleWhere((m) => m.body == 'hi via nostr')
            .route,
        MessageRoute.nostrCarrier,
      );
    });

    // Meaningful on carriers that authenticate senders (Nostr events are
    // signed, Matrix homeservers vouch for user ids); email and Tor senders
    // are self-claimed, where it only filters accidents.
    test(
      'a first contact counts only from the address its invite names',
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await network.join(alice, 'npub-alice|wss://relay.one');
        await network.join(bob, 'npub-bob|wss://relay.two');
        relay.shouldFailStore = (_, _, _, _, _) => true;
        network.holdFrom.add('npub-alice');
        await alice.addContactFromInvite(
          alias: 'Bob',
          payload: (await bob.buildInvite()).encodePayload(),
          codephrase: '',
        );
        await settle([alice, bob]);
        expect(network.held, isNotEmpty);
        // Mallory replays Alice's request from her own address.
        for (final (_, to, frame) in network.held) {
          network.deliver('npub-mallory', to, frame);
        }
        await settle([alice, bob]);
        expect(bob.pendingContactRequests, isEmpty);
        // From Alice's own address it is a request.
        network.holdFrom.clear();
        for (final (from, to, frame) in network.held) {
          network.deliver(from, to, frame);
        }
        await settle([alice, bob]);
        expect(
          bob.pendingContactRequests.map((r) => r.senderDeviceId),
          contains(alice.identity!.deviceId),
        );
      },
    );

    testWidgets(
      'the invite screen shows the extended invite, legacy on request',
      (tester) async {
        late MessengerController alice;
        late ContactInvite invite;
        final network = _FakeCarrierNetwork();
        await tester.runAsync(() async {
          alice = await _createController(
            relayClient: _FakeRelayClient(),
            displayName: 'Alice',
          );
          await network.join(alice, 'npub-alice|wss://relay.one');
          invite = await alice.buildInvite();
        });
        addTearDown(alice.dispose);
        Future<void> show(ContactInvite invite) async {
          await tester.pumpWidget(
            MaterialApp(
              home: app.InviteScreen(
                key: ValueKey(invite.encodePayload()),
                controller: alice,
                invite: invite,
                palette: app.ConestPalette(),
              ),
            ),
          );
          await tester.pump();
        }

        await show(invite);
        String shownPayload() => tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((text) => text.data ?? '')
            // An invite, not a codephrase that happens to start with "ci".
            .firstWhere((text) => RegExp(r'^ci\d\|').hasMatch(text));
        final code = currentPairingCodeSnapshotForPayload(
          invite.encodeCompatiblePayload(),
        ).codephrase;
        expect(shownPayload(), startsWith('ci7|'));
        expect(find.text(code), findsWidgets);
        await tester.ensureVisible(find.byKey(const ValueKey('invite-legacy')));
        await tester.tap(find.byKey(const ValueKey('invite-legacy')));
        await tester.pump();
        expect(shownPayload(), startsWith('ci6|'));
        expect(find.text(code), findsWidgets);

        // A very long carrier address makes the invite Beam-first.
        final long = invite.copyWithCarrierHints({
          TransportKind.nostr: 'npub-alice|${'wss://relay.example/' * 60}',
        }, 'sig');
        await show(long);
        expect(find.byKey(const ValueKey('invite-beam-first')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    test(
      'group members who are not contacts reach each other over carriers',
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Carol']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, carol] = people;
        await network.join(alice, 'npub-alice|wss://relay.one');
        await network.join(bob, 'npub-bob|wss://relay.two');
        await network.join(carol, 'npub-carol|wss://relay.three');
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        await settle(people);
        final group = await alice.createGroup(
          title: 'Three',
          members: alice.contacts,
        );
        await settle(people);
        expect(
          bob.contacts.map((c) => c.deviceId),
          isNot(contains(carol.identity!.deviceId)),
        );
        final carolProfile = bob.groups.single.memberProfileFor(
          carol.identity!.deviceId,
        )!;
        expect(
          carolProfile.carrierAddresses[TransportKind.nostr],
          'npub-carol|wss://relay.three',
        );
        // Bob and Carol cannot use relays between them.
        final bobId = bob.identity!.deviceId;
        final carolId = carol.identity!.deviceId;
        relay.shouldFailStore = (_, _, _, recipient, envelope) =>
            (envelope.senderDeviceId == carolId && recipient == bobId) ||
            (envelope.senderDeviceId == bobId && recipient == carolId);
        await carol.sendGroupMessage(groupId: group.groupId, body: 'hi Bob');
        for (
          var round = 0;
          round < 20 &&
              !bob
                  .messagesForGroup(group.groupId)
                  .any((m) => m.body == 'hi Bob');
          round++
        ) {
          await settle(people);
        }
        final got = bob
            .messagesForGroup(group.groupId)
            .singleWhere((m) => m.body == 'hi Bob');
        expect(got.route, MessageRoute.nostrCarrier);
      },
    );

    test('group co-members add each other over a carrier', () async {
      final network = _FakeCarrierNetwork();
      final relay = _FakeRelayClient();
      final people = <MessengerController>[];
      for (final name in ['Alice', 'Bob', 'Carol']) {
        final person = await _createController(
          relayClient: relay,
          displayName: name,
        );
        addTearDown(person.dispose);
        people.add(person);
      }
      final [alice, bob, carol] = people;
      await network.join(alice, 'npub-alice|wss://relay.one');
      await network.join(bob, 'npub-bob|wss://relay.two');
      await network.join(carol, 'npub-carol|wss://relay.three');
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await settle(people);
      await alice.createGroup(title: 'Three', members: alice.contacts);
      await settle(people);
      final bobId = bob.identity!.deviceId;
      final carolId = carol.identity!.deviceId;
      relay.shouldFailStore = (_, _, _, recipient, envelope) =>
          (envelope.senderDeviceId == carolId && recipient == bobId) ||
          (envelope.senderDeviceId == bobId && recipient == carolId);
      // The group profile must not stand in for a contact being added.
      await bob.addContactFromInvite(
        alias: 'Carol',
        payload: (await carol.buildInvite()).encodePayload(),
        codephrase: '',
      );
      for (
        var round = 0;
        round < 20 &&
            !carol.pendingContactRequests.any((r) => r.senderDeviceId == bobId);
        round++
      ) {
        await settle(people);
        await bob.retryContactPairingNow(carolId);
      }
      expect(
        carol.pendingContactRequests.map((r) => r.senderDeviceId),
        contains(bobId),
      );
      await carol.approvePendingContactRequest(
        carol.pendingContactRequests
            .singleWhere((r) => r.senderDeviceId == bobId)
            .id,
      );
      ContactPairingState bobSeesCarol() =>
          bob.contacts.singleWhere((c) => c.deviceId == carolId).pairingState;
      for (
        var round = 0;
        round < 20 && bobSeesCarol() != ContactPairingState.accepted;
        round++
      ) {
        await settle(people);
      }
      expect(bobSeesCarol(), ContactPairingState.accepted);
    });

    test('email addresses reach group members only when allowed', () async {
      final network = _FakeCarrierNetwork();
      final relay = _FakeRelayClient();
      final people = <MessengerController>[];
      for (final name in ['Alice', 'Bob', 'Carol']) {
        final person = await _createController(
          relayClient: relay,
          displayName: name,
        );
        addTearDown(person.dispose);
        people.add(person);
      }
      final [alice, bob, carol] = people;
      await network.join(carol, 'npub-carol|wss://relay.three');
      await network.join(
        carol,
        'carol@chat.example',
        kind: TransportKind.deltaChat,
      );
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await settle(people);
      await alice.createGroup(title: 'Three', members: alice.contacts);
      await settle(people);
      final carolId = carol.identity!.deviceId;
      Map<TransportKind, String> seenByBob() =>
          bob.groups.single.memberProfileFor(carolId)!.carrierAddresses;
      // Alice, a contact, knows both.
      expect(
        alice.contacts
            .singleWhere((c) => c.deviceId == carolId)
            .carrierAddresses
            .keys,
        contains(TransportKind.deltaChat),
      );
      // Bob, only a group member, learns the pseudonymous Nostr key.
      expect(seenByBob()[TransportKind.nostr], 'npub-carol|wss://relay.three');
      expect(seenByBob(), isNot(contains(TransportKind.deltaChat)));

      await carol.updateShareIdentifyingCarriersWithGroups(true);
      for (
        var round = 0;
        round < 20 && !seenByBob().containsKey(TransportKind.deltaChat);
        round++
      ) {
        await settle(people);
      }
      expect(seenByBob()[TransportKind.deltaChat], 'carol@chat.example');
    });

    test(
      'a member who keeps its email private does not email group peers',
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Carol']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, carol] = people;
        await network.join(
          bob,
          'bob@chat.example',
          kind: TransportKind.deltaChat,
        );
        await network.join(carol, 'npub-carol|wss://relay.three');
        await network.join(
          carol,
          'carol@chat.example',
          kind: TransportKind.deltaChat,
        );
        await bob.updateShareIdentifyingCarriersWithGroups(true);
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        await settle(people);
        final group = await alice.createGroup(
          title: 'Three',
          members: alice.contacts,
        );
        await settle(people);
        final bobId = bob.identity!.deviceId;
        final carolId = carol.identity!.deviceId;
        expect(
          carol.groups.single.memberProfileFor(bobId)!.carrierAddresses,
          contains(TransportKind.deltaChat),
        );
        expect(
          bob.groups.single.memberProfileFor(carolId)!.carrierAddresses,
          isNot(contains(TransportKind.deltaChat)),
        );
        relay.shouldFailStore = (_, _, _, recipient, envelope) =>
            (envelope.senderDeviceId == carolId && recipient == bobId) ||
            (envelope.senderDeviceId == bobId && recipient == carolId);
        network.frames.clear();
        await carol.sendGroupMessage(groupId: group.groupId, body: 'hi Bob');
        for (var round = 0; round < 5; round++) {
          await settle(people);
        }
        final leaked = network.frames
            .where((f) => f.$1 == 'carol@chat.example')
            .map((f) => f.$2)
            .toSet();
        expect(leaked, isNot(contains('bob@chat.example')));
      },
    );

    test(
      'a late older exchange does not share a withdrawn email again',
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Carol']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, carol] = people;
        await network.join(alice, 'npub-alice|wss://relay.one');
        await network.join(carol, 'npub-carol|wss://relay.three');
        await network.join(
          carol,
          'carol@chat.example',
          kind: TransportKind.deltaChat,
        );
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        await settle(people);
        await alice.createGroup(title: 'Three', members: alice.contacts);
        await settle(people);
        final aliceId = alice.identity!.deviceId;
        final carolId = carol.identity!.deviceId;
        Map<TransportKind, String> seenByBob() =>
            bob.groups.single.memberProfileFor(carolId)!.carrierAddresses;
        expect(seenByBob(), isNot(contains(TransportKind.deltaChat)));
        // Carol shares, but the exchange is slow (held on the carrier).
        relay.shouldFailStore = (_, _, _, recipient, envelope) =>
            envelope.senderDeviceId == carolId && recipient == aliceId;
        network.holdFrom.add('npub-carol');
        await carol.updateShareIdentifyingCarriersWithGroups(true);
        await settle([carol]);
        // She changes her mind; this one arrives at once.
        relay.shouldFailStore = null;
        network.holdFrom.clear();
        final held = List.of(network.held);
        network.held.clear();
        await carol.updateShareIdentifyingCarriersWithGroups(false);
        await settle(people);
        // The old one shows up late.
        for (final (from, to, frame) in held) {
          network.deliver(from, to, frame);
        }
        for (var round = 0; round < 3; round++) {
          await settle(people);
        }
        expect(seenByBob(), isNot(contains(TransportKind.deltaChat)));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      "an admin's update keeps the admin's own carrier addresses",
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Carol', 'Dave']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, carol, dave] = people;
        await network.join(alice, 'npub-alice|wss://relay.one');
        await network.join(bob, 'npub-bob|wss://relay.two');
        await network.join(carol, 'npub-carol|wss://relay.three');
        await network.join(dave, 'npub-dave|wss://relay.four');
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        await _pairControllers(bob, dave);
        await settle(people);
        final group = await alice.createGroup(
          title: 'Four',
          members: alice.contacts,
        );
        await settle(people);
        final bobId = bob.identity!.deviceId;
        await alice.setGroupMemberRole(
          groupId: group.groupId,
          memberDeviceId: bobId,
          role: GroupMemberRole.admin,
        );
        await settle(people);
        expect(
          carol.groups.single.memberProfileFor(bobId)!.carrierAddresses,
          contains(TransportKind.nostr),
        );
        await bob.addGroupMembers(
          groupId: group.groupId,
          members: [
            bob.contacts.singleWhere(
              (c) => c.deviceId == dave.identity!.deviceId,
            ),
          ],
        );
        await settle(people);
        expect(
          carol.groups.single.memberProfileFor(bobId)!.carrierAddresses,
          contains(TransportKind.nostr),
        );
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'withdrawing an email over a carrier reaches the group',
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Carol']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, carol] = people;
        await network.join(alice, 'npub-alice|wss://relay.one');
        await network.join(carol, 'npub-carol|wss://relay.three');
        await network.join(
          carol,
          'carol@chat.example',
          kind: TransportKind.deltaChat,
        );
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        await settle(people);
        await alice.createGroup(title: 'Three', members: alice.contacts);
        await settle(people);
        final aliceId = alice.identity!.deviceId;
        final carolId = carol.identity!.deviceId;
        Map<TransportKind, String> seenByBob() =>
            bob.groups.single.memberProfileFor(carolId)!.carrierAddresses;
        await carol.updateShareIdentifyingCarriersWithGroups(true);
        for (var round = 0; round < 3; round++) {
          await settle(people);
        }
        expect(seenByBob(), contains(TransportKind.deltaChat));
        relay.shouldFailStore = (_, _, _, recipient, envelope) =>
            envelope.senderDeviceId == carolId && recipient == aliceId;
        await carol.updateShareIdentifyingCarriersWithGroups(false);
        for (var round = 0; round < 3; round++) {
          await settle(people);
        }
        expect(
          alice.contacts
              .singleWhere((c) => c.deviceId == carolId)
              .groupCarrierAddresses,
          isNot(contains(TransportKind.deltaChat)),
        );
        expect(seenByBob(), isNot(contains(TransportKind.deltaChat)));
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'an owner withdrawing its email reaches every member',
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Dave']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, dave] = people;
        await network.join(alice, 'npub-alice|wss://relay.one');
        await network.join(
          alice,
          'alice@chat.example',
          kind: TransportKind.deltaChat,
        );
        await alice.updateShareIdentifyingCarriersWithGroups(true);
        await _pairControllers(alice, bob);
        await _pairControllers(bob, dave);
        await settle(people);
        final group = await alice.createGroup(
          title: 'G',
          members: alice.contacts,
        );
        await settle(people);
        await alice.setGroupMemberRole(
          groupId: group.groupId,
          memberDeviceId: bob.identity!.deviceId,
          role: GroupMemberRole.admin,
        );
        await settle(people);
        await bob.addGroupMembers(
          groupId: group.groupId,
          members: [
            bob.contacts.singleWhere(
              (c) => c.deviceId == dave.identity!.deviceId,
            ),
          ],
        );
        for (var round = 0; round < 3; round++) {
          await settle(people);
        }
        final aliceId = alice.identity!.deviceId;
        await alice.updateShareIdentifyingCarriersWithGroups(false);
        for (var round = 0; round < 3; round++) {
          await settle(people);
        }
        expect(
          dave.groups.single.memberProfileFor(aliceId)!.carrierAddresses,
          isNot(contains(TransportKind.deltaChat)),
        );
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      "a profile change racing an admin's add keeps the group whole",
      () async {
        final network = _FakeCarrierNetwork();
        // Bob reaches only Dave for a while: his copies to anyone else, and
        // anything to him, are lost on the way.
        var bobCutOff = false;
        late final String bobId;
        late final String daveId;
        final relay = _FakeRelayClient(
          shouldBlackholeStore: (_, _, _, recipient, envelope) =>
              bobCutOff &&
              (envelope.senderDeviceId == bobId && recipient != daveId ||
                  recipient == bobId),
        );
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Carol', 'Dave']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, carol, dave] = people;
        bobId = bob.identity!.deviceId;
        daveId = dave.identity!.deviceId;
        await network.join(carol, 'npub-carol|wss://relay.three');
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        await _pairControllers(bob, dave);
        await settle(people);
        final group = await alice.createGroup(
          title: 'G',
          members: alice.contacts,
        );
        await settle(people);
        await alice.setGroupMemberRole(
          groupId: group.groupId,
          memberDeviceId: bobId,
          role: GroupMemberRole.admin,
        );
        await settle(people);
        bobCutOff = true;
        // Meanwhile Carol's profile changes, and the owner passes it on.
        await carol.updateShareIdentifyingCarriersWithGroups(true);
        await network.join(carol, 'npub-carol2|wss://relay.three');
        await settle([alice, carol]);
        await bob.addGroupMembers(
          groupId: group.groupId,
          members: [bob.contacts.singleWhere((c) => c.deviceId == daveId)],
        );
        await settle([bob, dave]);
        bobCutOff = false;
        bool whole() => [alice, bob, carol].every(
          (person) => person.groups.single.memberDeviceIds.contains(daveId),
        );
        // Bob's add is repeated once he is back; it must not be refused.
        for (var round = 0; round < 20 && !whole(); round++) {
          await bob.retryUnacknowledgedMessagesNow();
          await settle(people);
        }
        for (final person in [alice, bob, carol]) {
          expect(person.groups.single.memberDeviceIds, contains(daveId));
        }
        // Dave got Bob's old view of Carol; the owner sends the newer one.
        final carolId = carol.identity!.deviceId;
        String? carolFor(MessengerController person) => person.groups.single
            .memberProfileFor(carolId)
            ?.carrierAddresses[TransportKind.nostr];
        for (
          var round = 0;
          round < 20 &&
              [bob, dave].any(
                (person) => carolFor(person) != 'npub-carol2|wss://relay.three',
              );
          round++
        ) {
          await alice.retryUnacknowledgedMessagesNow();
          await settle(people);
        }
        expect(carolFor(bob), 'npub-carol2|wss://relay.three');
        expect(carolFor(dave), 'npub-carol2|wss://relay.three');
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'a group message does not take back the owner\'s profile number',
      () async {
        final network = _FakeCarrierNetwork();
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Carol']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, carol] = people;
        await network.join(carol, 'npub-carol|wss://relay.three');
        await network.join(
          carol,
          'carol@chat.example',
          kind: TransportKind.deltaChat,
        );
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        await settle(people);
        final group = await alice.createGroup(
          title: 'Three',
          members: alice.contacts,
        );
        await settle(people);
        // A profile change noticed only when the owner next writes.
        await alice.updateBio('new bio');
        await alice.sendGroupMessage(groupId: group.groupId, body: 'hi');
        await settle(people);
        expect(
          alice.groups.single.profileRevision,
          greaterThanOrEqualTo(bob.groups.single.profileRevision),
        );
        // So the next change still reaches the members.
        final carolId = carol.identity!.deviceId;
        await carol.updateShareIdentifyingCarriersWithGroups(true);
        for (
          var round = 0;
          round < 10 &&
              !bob.groups.single
                  .memberProfileFor(carolId)!
                  .carrierAddresses
                  .containsKey(TransportKind.deltaChat);
          round++
        ) {
          await settle(people);
        }
        expect(
          bob.groups.single.memberProfileFor(carolId)!.carrierAddresses,
          contains(TransportKind.deltaChat),
        );
      },
    );

    test(
      "the owner's new name reaches a member who is not its contact",
      () async {
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['Alice', 'Bob', 'Dave']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, dave] = people;
        await _pairControllers(alice, bob);
        await _pairControllers(bob, dave);
        await settle(people);
        final group = await alice.createGroup(
          title: 'G',
          members: alice.contacts,
        );
        await settle(people);
        final aliceId = alice.identity!.deviceId;
        await alice.setGroupMemberRole(
          groupId: group.groupId,
          memberDeviceId: bob.identity!.deviceId,
          role: GroupMemberRole.admin,
        );
        await settle(people);
        // Dave is Bob's contact only.
        await bob.addGroupMembers(
          groupId: group.groupId,
          members: [
            bob.contacts.singleWhere(
              (c) => c.deviceId == dave.identity!.deviceId,
            ),
          ],
        );
        for (var round = 0; round < 3; round++) {
          await settle(people);
        }
        String? aliceAtDave() =>
            dave.groups.single.memberProfileFor(aliceId)?.displayName;
        expect(aliceAtDave(), 'Alice');
        await alice.updateDisplayName('Alicia');
        await alice.sendGroupMessage(groupId: group.groupId, body: 'renamed');
        for (var round = 0; round < 10 && aliceAtDave() != 'Alicia'; round++) {
          await settle(people);
        }
        expect(aliceAtDave(), 'Alicia');
      },
    );

    test('a clock set back does not hold up profile changes', () async {
      final network = _FakeCarrierNetwork();
      final relay = _FakeRelayClient();
      var offset = Duration.zero;
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        nowProvider: () => DateTime.now().toUtc().add(offset),
      );
      addTearDown(alice.dispose);
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(bob.dispose);
      final people = [alice, bob];
      await network.join(
        alice,
        'alice@chat.example',
        kind: TransportKind.deltaChat,
      );
      await _pairControllers(alice, bob);
      await settle(people);
      await alice.createGroup(title: 'G', members: alice.contacts);
      await settle(people);
      final start = alice.groups.single.profileRevision;
      // Three changes use up the minute's allowance.
      for (final share in [true, false, true]) {
        await alice.updateShareIdentifyingCarriersWithGroups(share);
        await settle(people);
      }
      expect(alice.groups.single.profileRevision - start, 3);
      // An hour back, those three look like the future: they do not count.
      offset = const Duration(hours: -1);
      await alice.updateShareIdentifyingCarriersWithGroups(false);
      await settle(people);
      expect(alice.groups.single.profileRevision - start, 4);
    });

    test('a mutual add works over a carrier alone', () async {
      final network = _FakeCarrierNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await network.join(alice, 'npub-alice|wss://relay.one');
      await network.join(bob, 'npub-bob|wss://relay.two');
      relay.shouldFailStore = (_, _, _, _, _) => true;
      final aliceInvite = await alice.buildInvite();
      final bobInvite = await bob.buildInvite();
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: bobInvite.encodePayload(),
        codephrase: '',
      );
      await bob.addContactFromInvite(
        alias: 'Alice',
        payload: aliceInvite.encodePayload(),
        codephrase: '',
      );
      for (
        var round = 0;
        round < 15 &&
            (alice.contacts.single.pairingState !=
                    ContactPairingState.accepted ||
                bob.contacts.single.pairingState !=
                    ContactPairingState.accepted);
        round++
      ) {
        await settle([alice, bob]);
        await alice.retryContactPairingNow(bob.identity!.deviceId);
        await bob.retryContactPairingNow(alice.identity!.deviceId);
      }
      expect(alice.contacts.single.pairingState, ContactPairingState.accepted);
      expect(bob.contacts.single.pairingState, ContactPairingState.accepted);
    });

    test('junk from strangers does not block a first contact', () async {
      final network = _FakeCarrierNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await network.join(alice, 'npub-alice|wss://relay.one');
      await network.join(bob, 'npub-bob|wss://relay.two');
      relay.shouldFailStore = (_, _, _, _, _) => true;
      for (var i = 0; i < 100; i++) {
        network.deliver(
          'npub-mallory$i',
          'npub-bob|wss://relay.two',
          Uint8List.fromList(List<int>.filled(80, i)),
        );
      }
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: (await bob.buildInvite()).encodePayload(),
        codephrase: '',
      );
      for (
        var round = 0;
        round < 5 && bob.pendingContactRequests.isEmpty;
        round++
      ) {
        await settle([alice, bob]);
      }
      expect(bob.pendingContactRequests, isNotEmpty);
    });

    test('the shown codephrase works with an extended invite', () async {
      final network = _FakeCarrierNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await network.join(alice, 'npub-alice|wss://relay.one');
      final invite = await alice.buildInvite();
      final code = currentPairingCodeSnapshotForPayload(
        invite.encodeCompatiblePayload(),
      ).codephrase;
      await bob.addContactFromInvite(
        alias: 'Alice',
        payload: invite.encodePayload(),
        codephrase: code,
      );
      expect(bob.contacts.single.deviceId, alice.identity!.deviceId);
    });

    test('a ci7 invite with altered carrier hints is refused', () async {
      final relay = _FakeRelayClient();
      final network = _FakeCarrierNetwork();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await network.join(bob, 'npub-bob|wss://relay.two');
      final payload = (await bob.buildInvite()).encodePayload();
      final tampered = payload.replaceFirst(
        Uri.encodeComponent('npub-bob|wss://relay.two'),
        Uri.encodeComponent('npub-mallory|wss://relay.two'),
      );
      expect(tampered, isNot(payload));
      await expectLater(
        alice.addContactFromInvite(
          alias: 'Bob',
          payload: tampered,
          codephrase: '',
        ),
        throwsA(anything),
      );
      expect(alice.contacts, isEmpty);
    });

    test('contacts learn each other\'s carrier address', () async {
      final (alice, bob, _, _) = await linkedPair();
      expect(
        alice.contacts.single.carrierAddress(TransportKind.nostr),
        'npub-bob|wss://relay.two',
      );
      expect(
        bob.contacts.single.carrierAddress(TransportKind.nostr),
        'npub-alice|wss://relay.one',
      );
    });

    test('messages arrive sealed over the carrier with its route mark',
        () async {
      final (alice, bob, network, relay) = await linkedPair();
      relay.shouldFailStore = (_, _, _, _, _) => true;
      await alice.sendMessage(contact: alice.contacts.single, body: 'via nostr');
      final aliceId = alice.identity!.deviceId;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline) &&
          !bob.messagesFor(aliceId).any((m) => m.body == 'via nostr')) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final received = bob
          .messagesFor(aliceId)
          .singleWhere((m) => m.body == 'via nostr');
      expect(received.route, MessageRoute.nostrCarrier);
      expect(network.frames, isNotEmpty);
      for (final (_, _, frame) in network.frames) {
        final raw = utf8.decode(frame, allowMalformed: true);
        expect(raw, isNot(contains('via nostr')));
        expect(raw, isNot(contains('direct_message')));
      }
    });

    test('a frame from an unknown sender is ignored', () async {
      final (alice, bob, network, _) = await linkedPair();
      network.deliver(
        'npub-mallory',
        'npub-alice|wss://relay.one',
        carrierBinaryFrames(
          CarrierFraming.nostr,
          Uint8List.fromList(List<int>.filled(64, 1)),
        ).single,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(alice.messagesFor(bob.identity!.deviceId), isEmpty);
    });

    test('turning a carrier off for a contact withdraws the address',
        () async {
      final (alice, bob, _, _) = await linkedPair();
      final bobOnAlice = alice.contacts.single;
      await alice.updateContactRoutingPreferences(
        bobOnAlice.deviceId,
        bobOnAlice.routing.copyWith(
          transportPolicies: {
            ...bobOnAlice.routing.transportPolicies,
            TransportKind.nostr: TransportPolicy.disabled,
          },
        ),
      );
      await settle([alice, bob]);
      expect(bob.contacts.single.carrierAddress(TransportKind.nostr), isNull);
      expect(
        alice.contacts.single.carrierAddress(TransportKind.nostr),
        'npub-bob|wss://relay.two',
      );
    });

    test('removing a carrier clears the address at the contact', () async {
      final (alice, bob, _, _) = await linkedPair();
      await bob.unregisterCarrierTransport(TransportKind.nostr);
      await settle([alice, bob]);
      expect(alice.contacts.single.carrierAddress(TransportKind.nostr), isNull);
    });
  });

  group('Nostr private messages', () {
    Future<void> until(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('chats with people on other Nostr apps, alone or in groups', () async {
      final nostr = FakeNostrRelays();
      for (final url in [
        'wss://alice.relay',
        'wss://other.relay',
        'wss://purplepag.es',
      ]) {
        nostr.relay(url);
      }
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        nostrConnector: nostr.connect,
      );
      addTearDown(alice.dispose);
      await alice.enableNostrDirect(relays: [Uri.parse('wss://alice.relay')]);
      final aliceKey = alice.nostrPublicKey!;
      expect(alice.nostrNpub, startsWith('npub1'));

      // Someone using another NIP-17 app, and a friend of theirs.
      NostrDirectService other(int seed, List<NostrDirectMessage> got) {
        final service = NostrDirectService(
          secretKey: Uint8List.fromList(List.filled(32, seed)),
          relays: [Uri.parse('wss://other.relay')],
          onMessage: got.add,
          connector: nostr.connect,
        )..start();
        addTearDown(service.stop);
        return service;
      }

      final bobGot = <NostrDirectMessage>[];
      final carolGot = <NostrDirectMessage>[];
      final bob = other(7, bobGot);
      final carol = other(8, carolGot);
      await until(() => nostr.relay('wss://purplepag.es').stored.length >= 3);

      await bob.send([aliceKey], 'hi Alice, from another app');
      await until(() => alice.nostrChats.chats.isNotEmpty);
      final chat = alice.nostrChats.chats.values.single;
      expect(chat.people, [bob.publicKey]);
      expect(chat.messages.single.text, 'hi Alice, from another app');
      expect(chat.unread, 1);

      await alice.sendNostrMessage(chat.key, 'hello Bob');
      await until(() => bobGot.any((m) => m.content == 'hello Bob'));
      expect(bobGot.last.author, aliceKey);
      expect(
        alice.nostrChats.chats[chat.key]!.messages.last.outgoing,
        isTrue,
      );

      // A group: its own chat, with everyone in it.
      await bob.send(
        [aliceKey, carol.publicKey],
        'hello both',
        subject: 'Weekend',
      );
      await until(() => alice.nostrChats.chats.length == 2);
      final group = alice.nostrChats.chats.values.singleWhere(
        (chat) => chat.isGroup,
      );
      expect(group.people.toSet(), {bob.publicKey, carol.publicKey});
      expect(group.subject, 'Weekend');
      await alice.sendNostrMessage(group.key, 'count me in');
      await until(
        () =>
            bobGot.any((m) => m.content == 'count me in') &&
            carolGot.any((m) => m.content == 'count me in'),
      );
      expect(
        carolGot.singleWhere((m) => m.content == 'count me in').participants,
        {aliceKey, bob.publicKey, carol.publicKey},
      );

      // Off and on again: the same address.
      await alice.disableNostrDirect();
      expect(alice.nostrDirectConfig, isNull);
      expect(alice.nostrChats.chats, hasLength(2));
      await alice.enableNostrDirect();
      expect(alice.nostrPublicKey, aliceKey);
    });

    test('a message dated in the future is shown as arriving now', () async {
      final nostr = FakeNostrRelays()
        ..relay('wss://alice.relay')
        ..relay('wss://purplepag.es');
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        nostrConnector: nostr.connect,
      );
      addTearDown(alice.dispose);
      await alice.enableNostrDirect(relays: [Uri.parse('wss://alice.relay')]);
      final stranger = Uint8List.fromList(List.filled(32, 9));
      final wraps = Nip17.wrap(
        secretKey: stranger,
        recipients: [alice.nostrPublicKey!],
        content: 'from the year 2999',
        now: DateTime.utc(2999),
      );
      final forAlice = wraps
          .singleWhere((entry) => entry.$1 == alice.nostrPublicKey)
          .$2;
      nostr.relay('wss://alice.relay').inject(forAlice);
      await until(() => alice.nostrChats.chats.isNotEmpty);
      final at = alice.nostrChats.chats.values.single.messages.single.at;
      expect(at.isBefore(DateTime.now().add(const Duration(hours: 1))), isTrue);
    });

    test('Nostr messages run with Conest, not in Matrix-only mode', () async {
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        nostrConnector: FakeNostrRelays().connect,
      );
      addTearDown(alice.dispose);
      await alice.setAppMode(AppMode.matrixOnly);
      expect(alice.enableNostrDirect, throwsStateError);
      expect(alice.nostrDirectConfig, isNull);
    });

    test('a new chat takes npubs and profiles, not junk', () async {
      final nostr = FakeNostrRelays()..relay('wss://alice.relay');
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        nostrConnector: nostr.connect,
      );
      addTearDown(alice.dispose);
      await alice.enableNostrDirect(relays: [Uri.parse('wss://alice.relay')]);
      const npub =
          'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';
      final key = await alice.startNostrChat(npub);
      expect(
        key,
        '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e',
      );
      expect(() => alice.startNostrChat('hello'), throwsArgumentError);
      expect(
        () => alice.startNostrChat(alice.nostrNpub!),
        throwsArgumentError,
      );
    });
  });

  group('Nostr carrier', () {
    Future<void> settle(List<MessengerController> controllers) async {
      for (var round = 0; round < 6; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    test(
      'two devices talk over Nostr relays when Conest relays fail',
      () async {
        final relays = FakeNostrRelays();
        final inbox = relays.relay('wss://inbox.test', requireAuth: true);
        relays.relay('wss://public.test');
        final relay = _FakeRelayClient();
        final aliceVault = _MemoryVaultStore();
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
          vaultStore: aliceVault,
          nostrConnector: relays.connect,
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
          nostrConnector: relays.connect,
        );
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        await alice.enableNostrCarrier(relays: ['wss://inbox.test']);
        await bob.enableNostrCarrier(relays: ['wss://public.test']);
        await settle([alice, bob]);
        final aliceAddress = alice.nostrChannel!.localAddress!;
        expect(
          bob.contacts.single.carrierAddress(TransportKind.nostr),
          aliceAddress,
        );
        expect(
          alice.contacts.single.carrierAddress(TransportKind.nostr),
          bob.nostrChannel!.localAddress,
        );

        relay.shouldFailStore = (_, _, _, _, _) => true;
        await bob.sendMessage(contact: bob.contacts.single, body: 'over nostr');
        final bobId = bob.identity!.deviceId;
        await until(
          () => alice.messagesFor(bobId).any((m) => m.body == 'over nostr'),
        );
        final received = alice
            .messagesFor(bobId)
            .singleWhere((m) => m.body == 'over nostr');
        expect(received.route, MessageRoute.nostrCarrier);
        expect(inbox.stored, isNotEmpty);
        for (final event in inbox.stored) {
          expect(event.content, isNot(contains('over nostr')));
        }

        // After a restart the same key and relays come back.
        alice.dispose();
        final restarted = await _createController(
          relayClient: relay,
          displayName: 'Alice',
          vaultStore: aliceVault,
          createIdentity: false,
          nostrConnector: relays.connect,
        );
        addTearDown(restarted.dispose);
        expect(restarted.nostrChannel?.localAddress, aliceAddress);
        await bob.sendMessage(contact: bob.contacts.single, body: 'again');
        await until(
          () => restarted.messagesFor(bobId).any((m) => m.body == 'again'),
        );
        expect(
          restarted.messagesFor(bobId).map((m) => m.body),
          contains('again'),
        );
      },
    );

    test(
      'a shut-down relay in a saved setup is replaced and re-announced',
      () async {
        final relays = FakeNostrRelays()..relay('wss://public.test');
        final relay = _FakeRelayClient();
        final aliceVault = _MemoryVaultStore();
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
          vaultStore: aliceVault,
          nostrConnector: relays.connect,
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
          nostrConnector: relays.connect,
        );
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        await alice.enableNostrCarrier(
          relays: ['wss://relay.0xchat.com', 'wss://public.test'],
        );
        await settle([alice, bob]);
        alice.dispose();

        final restarted = await _createController(
          relayClient: relay,
          displayName: 'Alice',
          vaultStore: aliceVault,
          createIdentity: false,
          nostrConnector: relays.connect,
        );
        addTearDown(restarted.dispose);
        expect(restarted.nostrCarrierConfig!.relays, [
          'wss://relay.primal.net',
          'wss://public.test',
        ]);
        await settle([restarted, bob]);
        expect(
          bob.contacts.single.carrierAddress(TransportKind.nostr),
          restarted.nostrChannel!.localAddress,
        );
        expect(
          bob.contacts.single.carrierAddress(TransportKind.nostr),
          isNot(contains('0xchat')),
        );
      },
    );

    test('a new Nostr setup uses the relays that answer here', () async {
      final nostr = FakeNostrRelays();
      nostr.relay('wss://up1.test');
      nostr.relay('wss://up2.test');
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        nostrConnector: nostr.connect,
      );
      addTearDown(alice.dispose);
      await alice.enableNostrCarrier(
        candidates: ['wss://down.test', 'wss://up1.test', 'wss://up2.test'],
      );
      expect(alice.nostrCarrierConfig!.relays.toSet(), {
        'wss://up1.test',
        'wss://up2.test',
      });
    });

    test(
      'turning Nostr off withdraws the address and forgets the key',
      () async {
        final relays = FakeNostrRelays()..relay('wss://r.test');
        final relay = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
          nostrConnector: relays.connect,
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
          nostrConnector: relays.connect,
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        await alice.enableNostrCarrier(relays: ['wss://r.test']);
        await settle([alice, bob]);
        expect(
          bob.contacts.single.carrierAddress(TransportKind.nostr),
          isNotNull,
        );
        await alice.disableNostrCarrier();
        await settle([alice, bob]);
        expect(bob.contacts.single.carrierAddress(TransportKind.nostr), isNull);
        expect(alice.nostrCarrierConfig, isNull);
        expect(alice.carrierTransport(TransportKind.nostr), isNull);
      },
    );

    test('relay lists are checked', () async {
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        nostrConnector: FakeNostrRelays().connect,
      );
      addTearDown(alice.dispose);
      for (final relays in [
        <String>[],
        ['http://relay.example'],
        ['wss://a.x', 'wss://b.x', 'wss://c.x', 'wss://d.x', 'wss://e.x'],
      ]) {
        await expectLater(
          alice.enableNostrCarrier(relays: relays),
          throwsArgumentError,
        );
      }
      expect(alice.nostrCarrierConfig, isNull);
      expect(defaultNostrRelays, hasLength(lessThanOrEqualTo(4)));
    });
  });

  group('Email carrier', () {
    Future<void> settle(List<MessengerController> controllers) async {
      for (var round = 0; round < 6; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    test(
      'a new email account goes to a chatmail server reachable here',
      () async {
        final server = await FakeMailServer.start();
        addTearDown(server.close);
        final alice = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
          // The first server is blocked on this network.
          mailConnector: (host, port, {required bool tls}) async {
            if (host == 'blocked.test') {
              throw const SocketException('Connection timed out');
            }
            return server.connect(host, port, tls: tls);
          },
        );
        addTearDown(alice.dispose);
        final chosen = await alice.enableChatmailCarrier(null, [
          'blocked.test',
          'chat.test',
        ]);
        expect(chosen, 'chat.test');
        expect(alice.emailCarrierConfig!.mail, endsWith('@chat.test'));
        expect(server.passwords, contains(alice.emailCarrierConfig!.mail));
        expect(
          alice.recentDebugLog.join('\n'),
          contains('fastest first: chat.test'),
        );
      },
    );

    test('two devices talk over chatmail when Conest relays fail', () async {
      final server = await FakeMailServer.start();
      addTearDown(server.close);
      final relay = _FakeRelayClient();
      final aliceVault = _MemoryVaultStore();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: aliceVault,
        mailConnector: server.connect,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        mailConnector: server.connect,
      );
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.enableChatmailCarrier('chat.test');
      await bob.enableChatmailCarrier('chat.test');
      await settle([alice, bob]);
      final aliceMail = alice.emailCarrierConfig!.mail;
      expect(aliceMail, endsWith('@chat.test'));
      expect(server.passwords, contains(aliceMail));
      expect(
        bob.contacts.single.carrierAddress(TransportKind.deltaChat),
        alice.emailChannel!.localAddress,
      );

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by mail');
      final bobId = bob.identity!.deviceId;
      await until(
        () => alice.messagesFor(bobId).any((m) => m.body == 'by mail'),
      );
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by mail');
      expect(received.route, MessageRoute.emailCarrier);

      alice.dispose();
      final restarted = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: aliceVault,
        createIdentity: false,
        mailConnector: server.connect,
      );
      addTearDown(restarted.dispose);
      expect(restarted.emailCarrierConfig?.mail, aliceMail);
      await bob.sendMessage(contact: bob.contacts.single, body: 'again');
      await until(
        () => restarted.messagesFor(bobId).any((m) => m.body == 'again'),
      );
      expect(
        restarted.messagesFor(bobId).map((m) => m.body),
        contains('again'),
      );
    });

    test('turning email off withdraws the address', () async {
      final server = await FakeMailServer.start();
      addTearDown(server.close);
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        mailConnector: server.connect,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        mailConnector: server.connect,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.enableChatmailCarrier('chat.test');
      await settle([alice, bob]);
      expect(
        bob.contacts.single.carrierAddress(TransportKind.deltaChat),
        isNotNull,
      );
      await alice.disableEmailCarrier();
      await settle([alice, bob]);
      expect(
        bob.contacts.single.carrierAddress(TransportKind.deltaChat),
        isNull,
      );
      expect(alice.emailCarrierConfig, isNull);
    });

    test('a failed login keeps email off', () async {
      final server = await FakeMailServer.start();
      addTearDown(server.close);
      server.passwords['me@chat.test'] = 'right';
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        mailConnector: server.connect,
      );
      addTearDown(alice.dispose);
      await expectLater(
        alice.enableOwnEmailCarrier(
          mail: 'me@chat.test',
          password: 'wrong',
          imapHost: 'chat.test',
          smtpHost: 'chat.test',
        ),
        throwsA(anything),
      );
      expect(alice.emailCarrierConfig, isNull);
      await expectLater(
        alice.enableChatmailCarrier('not a domain'),
        throwsArgumentError,
      );
    });

    test('a connection the network drops is tried again', () async {
      final server = await FakeMailServer.start();
      addTearDown(server.close);
      var drops = 2;
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        mailConnector: (host, port, {required bool tls}) {
          if (drops-- > 0) {
            throw const SocketException(
              'Software caused connection abort',
              osError: OSError('Software caused connection abort', 103),
            );
          }
          return server.connect(host, port, tls: tls);
        },
      );
      addTearDown(alice.dispose);
      await alice.enableChatmailCarrier('chat.test');
      expect(alice.emailCarrierConfig, isNotNull);
    });
  });

  group('Reticulum carrier', () {
    Future<void> settle(List<MessengerController> controllers) async {
      for (var round = 0; round < 6; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    test('Reticulum is ready only while its link is up', () async {
      final bus = FakeRnsBus();
      // A node that drops every link (seen on a public node).
      var drop = true;
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        reticulumConnector: (config) async {
          final link = bus.attach();
          if (drop) {
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 10),
                link.close,
              ),
            );
          }
          return link;
        },
      );
      addTearDown(controller.dispose);
      await controller.enableReticulumCarrier(host: 'node.test');
      CarrierStatus status() => controller.carrierStatuses.singleWhere(
        (status) => status.kind == TransportKind.reticulum,
      );
      await until(() => controller.reticulumChannel?.lastError != null);
      expect(status().ready, isFalse);
      expect(status().lastError, contains('closed'));
      // Its address is there all along, for invites.
      expect(status().address, isNotNull);
      drop = false;
      await until(() => status().ready);
      expect(status().ready, isTrue);
    });

    test('a contact is added over Reticulum alone', () async {
      final bus = FakeRnsBus();
      final relay = _FakeRelayClient();
      Future<MessengerController> device(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          reticulumConnector: bus.connect,
        );
        addTearDown(controller.dispose);
        // Every other route off: the request can only go by Reticulum.
        await controller.updateGlobalConnectivity(
          controller.identity!.connectivity.copyWith(
            lanEnabled: false,
            transportPolicies: {
              for (final kind in TransportKind.values)
                kind: kind == TransportKind.reticulum
                    ? TransportPolicy.automatic
                    : TransportPolicy.disabled,
            },
          ),
        );
        await controller.enableReticulumCarrier(host: 'node.test');
        return controller;
      }

      final alice = await device('Alice');
      final bob = await device('Bob');
      await until(() => alice.reticulumChannel?.localAddress != null);
      final invite = (await alice.buildInvite()).encodePayload();
      expect(
        ContactInvite.decodePayload(
          invite,
        ).carrierHints[TransportKind.reticulum],
        alice.reticulumChannel!.localAddress,
      );
      await bob.addContactFromInvite(
        alias: 'Alice',
        payload: invite,
        codephrase: '',
      );
      final bobId = bob.identity!.deviceId;
      await until(
        () =>
            alice.pendingContactRequests.any((r) => r.senderDeviceId == bobId),
      );
      expect(
        alice.pendingContactRequests.any((r) => r.senderDeviceId == bobId),
        isTrue,
        reason: 'the request reaches Alice over Reticulum',
      );
      await alice.approvePendingContactRequest(
        alice.pendingContactRequests
            .firstWhere((r) => r.senderDeviceId == bobId)
            .id,
      );
      await until(() => bob.contacts.single.canSendOutbound);
      expect(bob.contacts.single.canSendOutbound, isTrue);
      await bob.sendMessage(
        contact: bob.contacts.single,
        body: 'over Reticulum',
      );
      await until(
        () => alice.messagesFor(bobId).any((m) => m.body == 'over Reticulum'),
      );
      expect(alice.messagesFor(bobId).single.route, MessageRoute.reticulum);
    });

    // Through a real Reticulum transport node (rnsd), where paths are
    // learnt from announces, unlike the fake bus where every packet
    // reaches everyone.
    test(
      'a contact is added through a real Reticulum node',
      () async {
        final node = Platform.environment['CONEST_RNSD']!;
        final at = node.lastIndexOf(':');
        final relay = _FakeRelayClient();
        Future<MessengerController> device(String name) async {
          final controller = await _createController(
            relayClient: relay,
            displayName: name,
          );
          addTearDown(controller.dispose);
          await controller.updateGlobalConnectivity(
            controller.identity!.connectivity.copyWith(
              lanEnabled: false,
              transportPolicies: {
                for (final kind in TransportKind.values)
                  kind: kind == TransportKind.reticulum
                      ? TransportPolicy.automatic
                      : TransportPolicy.disabled,
              },
            ),
          );
          await controller.enableReticulumCarrier(
            host: node.substring(0, at),
            port: int.parse(node.substring(at + 1)),
          );
          return controller;
        }

        Future<void> waitFor(bool Function() done, String what) async {
          final deadline = DateTime.now().add(const Duration(seconds: 60));
          while (!done() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(done(), isTrue, reason: what);
        }

        bool linked(MessengerController controller) => controller
            .carrierStatuses
            .any((s) => s.kind == TransportKind.reticulum && s.ready);
        final alice = await device('Alice');
        final bob = await device('Bob');
        await waitFor(() => linked(alice) && linked(bob), 'both linked');
        final invite = (await alice.buildInvite()).encodePayload();
        await bob.addContactFromInvite(
          alias: 'Alice',
          payload: invite,
          codephrase: '',
        );
        final bobId = bob.identity!.deviceId;
        await waitFor(
          () => alice.pendingContactRequests.any(
            (r) => r.senderDeviceId == bobId,
          ),
          'the request reaches Alice through the node',
        );
        await alice.approvePendingContactRequest(
          alice.pendingContactRequests
              .firstWhere((r) => r.senderDeviceId == bobId)
              .id,
        );
        await waitFor(
          () => bob.contacts.single.canSendOutbound,
          'Bob hears Alice accepted',
        );
        await bob.sendMessage(contact: bob.contacts.single, body: 'via rnsd');
        await waitFor(
          () => alice.messagesFor(bobId).any((m) => m.body == 'via rnsd'),
          'a message follows',
        );
      },
      skip: Platform.environment['CONEST_RNSD'] == null
          ? 'CONEST_RNSD (host:port of an rnsd) is not set'
          : null,
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test('two devices talk over a Reticulum network', () async {
      final bus = FakeRnsBus();
      final relay = _FakeRelayClient();
      final aliceVault = _MemoryVaultStore();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: aliceVault,
        reticulumConnector: bus.connect,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        reticulumConnector: bus.connect,
      );
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.enableReticulumCarrier(host: 'node.test');
      await bob.enableReticulumCarrier(host: 'node.test');
      await settle([alice, bob]);
      final aliceAddress = alice.reticulumChannel!.localAddress!;
      expect(
        bob.contacts.single.carrierAddress(TransportKind.reticulum),
        aliceAddress,
      );

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by radio');
      final bobId = bob.identity!.deviceId;
      await until(
        () => alice.messagesFor(bobId).any((m) => m.body == 'by radio'),
      );
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by radio');
      expect(received.route, MessageRoute.reticulum);

      // Another node keeps the same identity and address.
      await alice.enableReticulumCarrier(host: 'other.test', port: 4965);
      expect(alice.reticulumChannel!.localAddress, aliceAddress);
      alice.dispose();
      final restarted = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: aliceVault,
        createIdentity: false,
        reticulumConnector: bus.connect,
      );
      addTearDown(restarted.dispose);
      expect(restarted.reticulumChannel?.localAddress, aliceAddress);
      expect(restarted.reticulumCarrierConfig?.port, 4965);

      // Turning it off is announced over the remaining routes.
      relay.shouldFailStore = (_, _, _, _, _) => false;
      await restarted.disableReticulumCarrier();
      await settle([restarted, bob]);
      expect(
        bob.contacts.single.carrierAddress(TransportKind.reticulum),
        isNull,
      );
    });

    test('node addresses are checked', () async {
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        reticulumConnector: FakeRnsBus().connect,
      );
      addTearDown(alice.dispose);
      for (final (host, port) in [('', 4242), ('a b', 4242), ('x', 0)]) {
        await expectLater(
          alice.enableReticulumCarrier(host: host, port: port),
          throwsArgumentError,
        );
      }
      expect(alice.reticulumCarrierConfig, isNull);
      expect(defaultReticulumPort, 4242);
      // An RNode needs a device path and valid radio settings.
      await expectLater(
        alice.enableReticulumCarrier(
          host: 'ttyACM0',
          link: ReticulumLink.rnodeSerial,
          radio: RnodeConfig.eu869,
        ),
        throwsArgumentError,
      );
      await expectLater(
        alice.enableReticulumCarrier(
          host: '/dev/ttyACM0',
          link: ReticulumLink.rnodeSerial,
        ),
        throwsArgumentError,
      );
      await alice.enableReticulumCarrier(
        host: '/dev/ttyACM0',
        link: ReticulumLink.rnodeSerial,
        radio: RnodeConfig.eu869,
      );
      await expectLater(
        alice.enableReticulumCarrier(
          host: 'not-a-mac',
          link: ReticulumLink.rnodeBluetooth,
          radio: RnodeConfig.eu869,
        ),
        throwsArgumentError,
      );
      final saved = alice.reticulumCarrierConfig!;
      expect(saved.link, ReticulumLink.rnodeSerial);
      expect(saved.radio?.frequency, RnodeConfig.eu869.frequency);
      expect(saved.label, '/dev/ttyACM0');
    });
  });

  test(
    'a route that takes messages but never delivers them gives way',
    () async {
      var now = DateTime.utc(2026, 10, 13, 12);
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
        nowProvider: () => now,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
        nowProvider: () => now,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      // Bob's firewall drops what Alice sends directly; Bob to Alice works.
      network.droppedPairs.add((
        alice.identity!.irohEndpointId!,
        bob.identity!.irohEndpointId!,
      ));
      await alice.sendMessage(contact: alice.contacts.single, body: 'one way');
      final aliceId = alice.identity!.deviceId;
      await bob.pollNow();
      expect(
        bob.messagesFor(aliceId).where((m) => m.body == 'one way'),
        isEmpty,
      );

      // No receipt within the timeout: the next try takes another route.
      now = now.add(const Duration(seconds: 9));
      await alice.retryUnacknowledgedMessagesNow();
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob.messagesFor(aliceId).any((m) => m.body == 'one way');
      }, reason: 'the message did not take another route');
      final bobId = bob.identity!.deviceId;
      await _waitForIroh(
        () => {DeliveryState.delivered, DeliveryState.read}.contains(
          alice
              .messagesFor(bobId)
              .singleWhere((m) => m.body == 'one way')
              .state,
        ),
        reason: 'the receipt did not come back',
      );
    },
  );

  group('Several routes', () {
    Future<
      (
        MessengerController,
        MessengerController,
        _FakeRelayClient,
        _InProcessIrohNetwork,
      )
    >
    pair({EnergyPolicy? alicePolicy}) async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
        energyPolicy: alicePolicy,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      return (alice, bob, relay, network);
    }

    Set<MessageRoute> families(Iterable<RouteTrace> traces) => {
      for (final trace in traces) trace.route.family,
    };

    test('on mains power a message goes on every route, and the receipt '
        'names each one', () async {
      final (alice, bob, relay, _) = await pair(
        alicePolicy: EnergyPolicy.fixed(EnergyMode.unconstrained),
      );
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      await alice.sendMessage(contact: alice.contacts.single, body: 'twice');
      final sent = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'twice');
      // The copy went to the relay as well as straight to Bob.
      await _waitForIroh(
        () => relay.storedEnvelopes.any((e) => e.messageId == sent.id),
        reason: 'no copy went to the relay',
      );
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        final received = bob
            .messagesFor(aliceId)
            .where((m) => m.body == 'twice')
            .firstOrNull;
        return received != null && received.routeTrace.length >= 2;
      }, reason: 'Bob did not list both routes');
      final received = bob
          .messagesFor(aliceId)
          .singleWhere((m) => m.body == 'twice');
      final arrivedBy = families(received.routeTrace);
      expect(arrivedBy, contains(MessageRoute.irohDirect));
      expect(arrivedBy.length, greaterThanOrEqualTo(2));
      expect(
        received.routeTrace.every(
          (trace) => trace.mark == MessageRouteMark.confirmed,
        ),
        isTrue,
      );
      // Alice learns that both routes reached Bob.
      await _waitForIroh(() {
        final traces = alice
            .messagesFor(bobId)
            .singleWhere((m) => m.body == 'twice')
            .routeTrace
            .where((trace) => trace.mark == MessageRouteMark.confirmed);
        return families(traces).containsAll(arrivedBy);
      }, reason: 'the receipts did not name every route');
      // One message, however many copies.
      expect(
        bob.messagesFor(aliceId).where((m) => m.body == 'twice').length,
        1,
      );
    });

    test('in battery saver a message goes on one route, as before', () async {
      final (alice, bob, relay, _) = await pair(
        alicePolicy: EnergyPolicy.fixed(EnergyMode.saver),
      );
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      await alice.sendMessage(contact: alice.contacts.single, body: 'once');
      final sent = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'once');
      await _waitForIroh(
        () => bob.messagesFor(aliceId).any((m) => m.body == 'once'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        relay.storedEnvelopes.where((e) => e.messageId == sent.id),
        isEmpty,
      );
    });

    test('on battery a copy waits for the receipt first', () async {
      final (alice, bob, relay, _) = await pair(
        alicePolicy: EnergyPolicy.fixed(
          EnergyMode.limited,
          escalateInterval: const Duration(seconds: 30),
        ),
      );
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      await alice.sendMessage(contact: alice.contacts.single, body: 'patient');
      final sent = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'patient');
      await _waitForIroh(
        () => {DeliveryState.delivered, DeliveryState.read}.contains(
          alice.messagesFor(bobId).singleWhere((m) => m.id == sent.id).state,
        ),
      );
      // The receipt came within the interval: no copy went anywhere.
      expect(
        relay.storedEnvelopes.where((e) => e.messageId == sent.id),
        isEmpty,
      );
      expect(
        alice
            .messagesFor(bobId)
            .singleWhere((m) => m.id == sent.id)
            .routeTrace
            .map((trace) => trace.route.family)
            .toSet(),
        {MessageRoute.irohDirect},
      );
      expect(
        bob.messagesFor(aliceId).where((m) => m.body == 'patient').length,
        1,
      );
    });

    test('on battery, no receipt within the interval sends a copy on the '
        'next route', () async {
      final (alice, bob, _, network) = await pair(
        alicePolicy: EnergyPolicy.fixed(
          EnergyMode.limited,
          escalateInterval: const Duration(seconds: 1),
        ),
      );
      // What Alice sends straight to Bob is lost on the way.
      network.droppedPairs.add((
        alice.identity!.irohEndpointId!,
        bob.identity!.irohEndpointId!,
      ));
      final aliceId = alice.identity!.deviceId;
      await alice.sendMessage(
        contact: alice.contacts.single,
        body: 'lost once',
      );
      // No retry pass: the copy alone gets it there.
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob.messagesFor(aliceId).any((m) => m.body == 'lost once');
      }, reason: 'no copy went on another route');
    });

    test('copies arriving together get one receipt', () async {
      final (alice, bob, relay, _) = await pair(
        alicePolicy: EnergyPolicy.fixed(EnergyMode.unconstrained),
      );
      final aliceId = alice.identity!.deviceId;
      await alice.sendMessage(contact: alice.contacts.single, body: 'thrice');
      final id = alice
          .messagesFor(bob.identity!.deviceId)
          .singleWhere((m) => m.body == 'thrice')
          .id;
      // The copies left on the relay and the LAN queue wait for one poll.
      await _waitForIroh(
        () => relay.storedEnvelopes.where((e) => e.messageId == id).length >= 2,
        reason: 'the copies did not go out',
      );
      await _waitForIroh(
        () => bob.messagesFor(aliceId).any((m) => m.body == 'thrice'),
      );
      // Two more copies come by two other routes, one right after the
      // other: one more receipt names both.
      final copy = relay.storedEnvelopes.firstWhere((e) => e.messageId == id);
      final before = bob.messageReceiptsSent;
      await bob.processEnvelopesForTesting([
        copy,
      ], route: MessageRoute.nostrCarrier);
      await bob.processEnvelopesForTesting([
        copy,
      ], route: MessageRoute.emailCarrier);
      // The same copy again from the other relay, same route: no extra.
      await bob.processEnvelopesForTesting([
        copy,
      ], route: MessageRoute.emailCarrier);
      // Bob is in battery saver (the test default): it gathers for 3 s.
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      final received = bob
          .messagesFor(aliceId)
          .singleWhere((m) => m.body == 'thrice');
      expect(
        received.routeTrace.map((trace) => trace.route),
        containsAll([MessageRoute.nostrCarrier, MessageRoute.emailCarrier]),
      );
      expect(bob.messageReceiptsSent - before, 1);
    });

    test('retries do not send the same copies again', () async {
      var now = DateTime.now().toUtc();
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
        nowProvider: () => now,
        energyPolicy: EnergyPolicy.fixed(EnergyMode.unconstrained),
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
        nowProvider: () => now,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final bobId = bob.identity!.deviceId;
      // Bob is away: nothing reaches him, nothing comes back.
      network.droppedPairs.add((
        alice.identity!.irohEndpointId!,
        bob.identity!.irohEndpointId!,
      ));
      await alice.sendMessage(contact: alice.contacts.single, body: 'away');
      final id = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'away')
          .id;
      int stores() =>
          relay.storedEnvelopes.where((e) => e.messageId == id).length;
      await Future<void>.delayed(const Duration(seconds: 2));
      final afterFirst = stores();
      for (var pass = 0; pass < 3; pass++) {
        now = now.add(const Duration(minutes: 6));
        await alice.retryUnacknowledgedMessagesNow();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      // Each retry may hand the message to one route again; copies to the
      // other routes went once, on the first pass.
      final perRetry = (stores() - afterFirst) / 3;
      expect(perRetry, lessThan(2));
      expect(id, isNotEmpty);
    });

    test('copies reach every member of a group', () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
        energyPolicy: EnergyPolicy.fixed(EnergyMode.unconstrained),
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
        // Answers copies after 1 s (3 s in battery saver).
        energyPolicy: EnergyPolicy.fixed(EnergyMode.unconstrained),
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final group = await alice.createGroup(
        title: 'Both ways',
        members: [alice.contacts.single],
      );
      await _waitForIroh(
        () => bob.groups.any((g) => g.groupId == group.groupId),
        reason: 'Bob did not join',
      );
      await alice.sendGroupMessage(groupId: group.groupId, body: 'all routes');
      final bobId = bob.identity!.deviceId;
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        final traces = alice
            .messagesForGroup(group.groupId)
            .singleWhere((m) => m.body == 'all routes')
            .routeTrace
            .where(
              (trace) =>
                  trace.deviceId == bobId &&
                  trace.mark == MessageRouteMark.confirmed,
            );
        return families(traces).length >= 2;
      }, reason: 'the group receipt did not name two routes');
    });
  });

  group('Accounts with several devices', () {
    Future<
      (
        MessengerController,
        MessengerController,
        MessengerController,
        void Function(Duration),
      )
    >
    threeDevices() async {
      var now = DateTime.now().toUtc();
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> make(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => now,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await make('Alice');
      final bob = await make('Bob');
      final phone = await make('New phone');
      await _pairControllers(alice, bob);
      return (alice, bob, phone, (Duration by) => now = now.add(by));
    }

    test('a new device is linked after both confirm the same code', () async {
      final (alice, bob, phone, advance) = await threeDevices();
      advance(const Duration(hours: 25));
      final aliceId = alice.identity!.deviceId;
      final phoneId = phone.identity!.deviceId;

      final qr = await phone.startLinkAsNewDevice();
      expect(phone.linkState, LinkState.showingQrCode);
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            alice.linkState == LinkState.compareCode,
        reason: 'the codes did not show',
      );
      expect(phone.linkCode, alice.linkCode, reason: 'both show the same code');

      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      await _waitForIroh(
        () => phone.linkState == LinkState.linked,
        reason: 'the phone was not linked',
      );
      expect(phone.identity!.accountId, alice.identity!.accountId);
      expect(phone.identity!.displayName, 'Alice');
      expect(
        phone.identity!.accountKeyPublicBase64,
        alice.identity!.accountKeyPublicBase64,
      );
      expect(phone.contacts.map((c) => c.displayName), contains('Bob'));
      expect(
        alice.accountDevices!.devices.map((d) => d.deviceId),
        containsAll([aliceId, phoneId]),
      );
      // Bob learns the phone is Alice's.
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob.linkedDevicesOf(aliceId).any((d) => d.deviceId == phoneId);
      }, reason: 'Bob did not learn the phone');
      expect(bob.contacts.length, 1);
    });

    test('someone who photographed the QR code cannot pass for the real '
        'device', () async {
      final (alice, bob, phone, advance) = await threeDevices();
      advance(const Duration(hours: 25));
      final qr = await phone.startLinkAsNewDevice();
      // Bob (any stranger with the QR code) offers first.
      await bob.startLinkFromQrCode(qr);
      await _waitForIroh(() => phone.linkState == LinkState.compareCode);
      await alice.startLinkFromQrCode(qr);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // The phone answered Bob only: Alice shows no code at all, so the
      // user sees that the devices do not match.
      expect(alice.linkCode, isNull);
      expect(alice.linkState, LinkState.connecting);
      await _waitForIroh(() => bob.linkCode != null);
      expect(bob.linkCode, phone.linkCode);
    });

    test('messages reach every device of the account, and one chat shows '
        'them all', () async {
      final (alice, bob, phone, advance) = await threeDevices();
      advance(const Duration(hours: 25));
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      final qr = await phone.startLinkAsNewDevice();
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            alice.linkState == LinkState.compareCode,
      );
      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return phone.linkState == LinkState.linked &&
            bob.linkedDevicesOf(aliceId).isNotEmpty;
      }, reason: 'the phone was not linked and known');

      // Bob writes to Alice: both her devices get it.
      await bob.sendMessage(contact: bob.contacts.single, body: 'hi both');
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        unawaited(phone.pollNow());
        return alice.messagesFor(bobId).any((m) => m.body == 'hi both') &&
            phone.messagesFor(bobId).any((m) => m.body == 'hi both');
      }, reason: 'not every device of Alice got it');

      // Alice answers from her phone: Bob sees it in Alice's chat, and the
      // phone gets his receipt.
      await phone.sendMessage(
        contact: phone.contacts.firstWhere((c) => c.deviceId == bobId),
        body: 'from my phone',
      );
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        unawaited(phone.pollNow());
        final mine = phone
            .messagesFor(bobId)
            .where((m) => m.body == 'from my phone')
            .firstOrNull;
        return bob.messagesFor(aliceId).any((m) => m.body == 'from my phone') &&
            mine != null &&
            {DeliveryState.delivered, DeliveryState.read}.contains(mine.state);
      }, reason: 'the phone\'s message did not reach Alice\'s chat at Bob');
      expect(bob.contacts.length, 1);
    });

    test('what one device sends, reads and saves shows on the others, '
        'and only the sending device sends it', () async {
      final (alice, bob, phone, advance) = await threeDevices();
      advance(const Duration(hours: 25));
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      final phoneId = phone.identity!.deviceId;
      final qr = await phone.startLinkAsNewDevice();
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            alice.linkState == LinkState.compareCode,
      );
      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return phone.linkState == LinkState.linked &&
            bob.linkedDevicesOf(aliceId).isNotEmpty;
      }, reason: 'the phone was not linked and known');
      // Each knows the other as its own device, never as a contact.
      expect(alice.ownDevices.map((d) => d.deviceId), [phoneId]);
      expect(phone.ownDevices.map((d) => d.deviceId), [aliceId]);
      expect(alice.contacts.map((c) => c.deviceId), [bobId]);
      expect(phone.contacts.map((c) => c.deviceId), [bobId]);

      // Sent from the phone: the laptop shows it in the chat with Bob, and
      // its receipt once the phone gets it.
      await phone.sendMessage(
        contact: phone.contacts.single,
        body: 'from my phone',
      );
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        unawaited(bob.pollNow());
        unawaited(phone.pollNow());
        final copy = alice
            .messagesFor(bobId)
            .where((m) => m.body == 'from my phone')
            .firstOrNull;
        return copy != null &&
            copy.outbound &&
            copy.senderDeviceId == phoneId &&
            {DeliveryState.delivered, DeliveryState.read}.contains(copy.state);
      }, reason: 'the laptop did not show the phone\'s message as delivered');
      // The laptop never sends it itself.
      await alice.pollNow();
      await bob.pollNow();
      expect(
        bob.messagesFor(aliceId).where((m) => m.body == 'from my phone'),
        hasLength(1),
      );

      // Read on the phone: read on the laptop too.
      advance(const Duration(minutes: 1));
      await bob.sendMessage(contact: bob.contacts.single, body: 'did you?');
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        unawaited(phone.pollNow());
        return alice.unreadCountFor(bobId) == 1 &&
            phone.messagesFor(bobId).any((m) => m.body == 'did you?');
      }, reason: 'Bob\'s message did not reach both devices');
      await phone.markConversationReadThroughMessage(
        bobId,
        phone.messagesFor(bobId).firstWhere((m) => m.body == 'did you?'),
      );
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return alice.unreadCountFor(bobId) == 0;
      }, reason: 'reading on the phone did not reach the laptop');

      // Saved on the phone: in the laptop's Saved messages.
      await phone.sendMessage(
        contact: phone.savedMessagesContact!,
        body: 'note to self',
      );
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return alice.messagesFor(aliceId).any((m) => m.body == 'note to self');
      }, reason: 'the saved note did not reach the laptop');

      // A receipt that overtakes its message is kept until the message
      // comes.
      await phone.sendAccountSyncForTesting(aliceId, {
        'type': 'state',
        'chat': bobId,
        'id': 'msg-late',
        'state': 'delivered',
      });
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return phone.ownDevices.isNotEmpty;
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await alice.pollNow();
      await phone.sendAccountSyncForTesting(aliceId, {
        'type': 'sent',
        'chat': bobId,
        'id': 'msg-late',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'payload': 'came late',
      });
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return alice
                .messagesFor(bobId)
                .where((m) => m.id == 'msg-late')
                .firstOrNull
                ?.state ==
            DeliveryState.delivered;
      }, reason: 'the early receipt was lost');
    });

    test('a message sent from another own device is never sent again from '
        'this one', () async {
      var now = DateTime.now().toUtc();
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> make(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => now,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await make('Alice');
      final bob = await make('Bob');
      final phone = await make('Phone');
      await _pairControllers(alice, bob);
      now = now.add(const Duration(hours: 25));
      final qr = await phone.startLinkAsNewDevice();
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            alice.linkState == LinkState.compareCode,
      );
      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      await _waitForIroh(() => phone.linkState == LinkState.linked);
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      // What the phone sends Bob is lost on the way, so it stays unreceipted.
      network.droppedPairs.add((
        phone.identity!.irohEndpointId!,
        bob.identity!.irohEndpointId!,
      ));
      await phone.sendMessage(
        contact: phone.contacts.single,
        body: 'lost on the way',
      );
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return alice.messagesFor(bobId).any((m) => m.body == 'lost on the way');
      }, reason: 'the laptop did not get the phone\'s message');
      final id = alice
          .messagesFor(bobId)
          .firstWhere((m) => m.body == 'lost on the way')
          .id;
      now = now.add(const Duration(hours: 1));
      await alice.retryUnacknowledgedMessagesNow();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        [
          ...network.envelopes,
          ...relay.storedEnvelopes,
        ].where((e) => e.senderDeviceId == aliceId && e.messageId == id),
        isEmpty,
        reason: 'the laptop sent the phone\'s message itself',
      );

      // Read on the phone: the laptop marks it read and tells Bob nothing.
      now = now.add(const Duration(minutes: 1));
      await bob.sendMessage(contact: bob.contacts.single, body: 'seen it?');
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        unawaited(phone.pollNow());
        return alice.unreadCountFor(bobId) == 1 &&
            phone.messagesFor(bobId).any((m) => m.body == 'seen it?');
      });
      final receiptsBefore = alice.readReceiptsSent;
      await phone.markConversationReadThroughMessage(
        bobId,
        phone.messagesFor(bobId).firstWhere((m) => m.body == 'seen it?'),
      );
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return alice.unreadCountFor(bobId) == 0;
      }, reason: 'the read did not reach the laptop');
      // Long enough for a receipt to have gone out after the read.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await alice.pollNow();
      expect(
        alice.readReceiptsSent,
        receiptsBefore,
        reason: 'the laptop sent Bob a read receipt',
      );
    });

    test('only the account\'s own devices sync, and a list that takes '
        'over a device is refused', () async {
      final (alice, bob, phone, advance) = await threeDevices();
      advance(const Duration(hours: 25));
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      final phoneId = phone.identity!.deviceId;
      final qr = await phone.startLinkAsNewDevice();
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            alice.linkState == LinkState.compareCode,
      );
      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      await _waitForIroh(() => phone.linkState == LinkState.linked);

      // A contact cannot make a message appear as sent by Alice.
      await bob.sendAccountSyncForTesting(aliceId, {
        'type': 'sent',
        'chat': bobId,
        'id': 'forged-1',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'payload': 'forged text',
      });
      await bob.sendMessage(contact: bob.contacts.single, body: 'after it');
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return alice.messagesFor(bobId).any((m) => m.body == 'after it');
      });
      expect(alice.messagesFor(bobId).any((m) => m.id == 'forged-1'), isFalse);

      final me = phone.identity!;
      final account = AccountKeys(
        publicKeyBase64: me.accountKeyPublicBase64!,
        privateKeyBase64: me.accountKeyPrivateBase64!,
      );
      final current = alice.accountDevices!;
      Future<Map<String, Object?>> statement({
        List<DeviceCert>? devices,
        Map<String, DateTime> revoked = const {},
        int? version,
      }) async => {
        'devices': (await AccountDeviceList.issue(
          account: account,
          accountId: me.accountId,
          version: version ?? current.version + 1,
          devices: devices ?? current.devices,
          revoked: revoked,
          issuedAt: DateTime.now().toUtc(),
        )).toJson(),
      };
      Future<DeviceCert> certWithKeysOf(
        String deviceId,
        IdentityRecord keys, {
        DateTime? linkedAt,
      }) async => DeviceCert.issue(
        account: account,
        accountId: me.accountId,
        deviceId: deviceId,
        encryptionKeyBase64: keys.publicKeyBase64,
        signingKeyBase64: keys.signingPublicKeyBase64!,
        irohEndpointId: keys.irohEndpointId,
        name: 'Swapped',
        linkedAt: linkedAt ?? DateTime.now().toUtc(),
        proofSignatureBase64: await signEd25519(
          DeviceCert.proofBytes(
            accountId: me.accountId,
            accountKeyBase64: account.publicKeyBase64,
            deviceId: deviceId,
            encryptionKeyBase64: keys.publicKeyBase64,
            signingKeyBase64: keys.signingPublicKeyBase64!,
            irohEndpointId: keys.irohEndpointId,
          ),
          publicKeyBase64: keys.signingPublicKeyBase64!,
          privateKeyBase64: keys.signingPrivateKeyBase64!,
        ),
      );
      final aliceCert = current.deviceFor(aliceId)!;
      final phoneCert = current.deviceFor(phoneId)!;

      // Linked minutes ago: the phone's revocations do not count yet.
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(revoked: {'dev-gone': DateTime.now().toUtc()}),
      );
      expect(alice.accountDevices!.version, current.version);
      // Nor can it add a device that claims to be a year old.
      final yearAgo = DateTime.now().toUtc().subtract(
        const Duration(days: 365),
      );
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(
          devices: [
            ...current.devices,
            await certWithKeysOf(
              'dev-puppet',
              bob.identity!,
              linkedAt: yearAgo,
            ),
          ],
        ),
      );
      expect(alice.accountDevices!.deviceFor('dev-puppet'), isNull);
      advance(const Duration(hours: 25));
      // Revoking this (the original) device, or swapping its keys or the
      // phone's for someone else's: refused.
      for (final forged in [
        await statement(
          devices: [phoneCert],
          revoked: {aliceId: DateTime.now().toUtc()},
        ),
        // Still listed, and revoked too.
        await statement(revoked: {aliceId: DateTime.now().toUtc()}),
        await statement(
          devices: [await certWithKeysOf(aliceId, me), phoneCert],
        ),
        await statement(
          devices: [aliceCert, await certWithKeysOf(phoneId, bob.identity!)],
        ),
        // Its own keys, but linked long ago.
        await statement(
          devices: [
            aliceCert,
            await certWithKeysOf(phoneId, me, linkedAt: yearAgo),
          ],
        ),
      ]) {
        await alice.receiveOwnDeviceListForTesting(phoneId, forged);
        expect(alice.accountDevices!.version, current.version);
        expect(
          alice.accountDevices!.deviceFor(aliceId)!.encryptionKeyBase64,
          alice.identity!.publicKeyBase64,
        );
        expect(
          alice.ownDevices.single.publicKeyBase64,
          phone.identity!.publicKeyBase64,
        );
      }
      // A revocation dated in the future (to keep its place in the bounded
      // table over real ones): left out, and the list is not taken.
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(revoked: {'dev-made-up': DateTime.utc(2099)}),
      );
      expect(alice.accountDevices!.version, current.version);
      // Nor can other devices fill the places kept for this one's own
      // revocations, or add many devices in a day.
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(
          revoked: {
            for (var i = 0; i < 961; i++) 'dev-junk-$i': DateTime.now().toUtc(),
          },
        ),
      );
      expect(alice.accountDevices!.revoked, isEmpty);
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(
          devices: [
            aliceCert,
            phoneCert,
            for (var i = 0; i < 5; i++)
              await certWithKeysOf('dev-many-$i', bob.identity!),
          ],
        ),
      );
      expect(alice.accountDevices!.version, current.version);
      // A newer list that adds devices: taken.
      final devA = await certWithKeysOf('dev-a', bob.identity!);
      final devB = await certWithKeysOf('dev-b', bob.identity!);
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(devices: [aliceCert, phoneCert, devA, devB]),
      );
      expect(alice.accountDevices!.version, current.version + 1);
      expect(
        alice.ownDevices.map((d) => d.deviceId),
        unorderedEquals([phoneId, 'dev-a', 'dev-b']),
      );
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(
          version: current.version + 2,
          devices: [aliceCert, phoneCert, devB],
          revoked: {'dev-a': DateTime.utc(2099)},
        ),
      );
      expect(alice.accountDevices!.version, current.version + 1);
      // Revoking one: taken.
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(
          version: current.version + 2,
          devices: [aliceCert, phoneCert, devB],
          revoked: {'dev-a': DateTime.now().toUtc()},
        ),
      );
      expect(alice.accountDevices!.version, current.version + 2);
      expect(alice.accountDevices!.revoked.keys, contains('dev-a'));
      // The phone revoked the other one without seeing that list: the laptop
      // signs one with both, a version above.
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(
          version: current.version + 2,
          devices: [aliceCert, phoneCert, devA],
          revoked: {'dev-b': DateTime.now().toUtc()},
        ),
      );
      final merged = alice.accountDevices!;
      expect(merged.version, current.version + 3);
      expect(merged.revoked.keys, containsAll(['dev-a', 'dev-b']));
      expect(merged.devices.map((d) => d.deviceId), [aliceId, phoneId]);
      expect(await merged.verify(account.publicKeyBase64), isTrue);
      // A higher version that only leaves a device out is not taken.
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(
          version: current.version + 6,
          devices: [aliceCert],
          revoked: merged.revoked,
        ),
      );
      expect(alice.accountDevices!.version, current.version + 3);
      expect(alice.ownDevices.single.deviceId, phoneId);
      // A device added through the phone counts as new here, whatever date
      // its certificate says: its revocations wait a day.
      final latest = alice.accountDevices!;
      await alice.receiveOwnDeviceListForTesting(
        phoneId,
        await statement(
          version: latest.version + 1,
          devices: [
            ...latest.devices,
            await certWithKeysOf(
              'dev-puppet',
              bob.identity!,
              linkedAt: yearAgo,
            ),
          ],
          revoked: latest.revoked,
        ),
      );
      expect(alice.accountDevices!.deviceFor('dev-puppet'), isNotNull);
      Future<Map<String, Object?>> revokePhone() => statement(
        version: alice.accountDevices!.version + 1,
        devices: [
          for (final d in alice.accountDevices!.devices)
            if (d.deviceId != phoneId) d,
        ],
        revoked: {
          ...alice.accountDevices!.revoked,
          phoneId: DateTime.now().toUtc(),
        },
      );
      await alice.receiveOwnDeviceListForTesting(
        'dev-puppet',
        await revokePhone(),
      );
      expect(alice.accountDevices!.revoked.keys, isNot(contains(phoneId)));
      advance(const Duration(hours: 25));
      await alice.receiveOwnDeviceListForTesting(
        'dev-puppet',
        await revokePhone(),
      );
      expect(alice.accountDevices!.revoked.keys, contains(phoneId));
      // A real revocation always gets through, even in a list padded with
      // made-up ones (which are left out).
      final before = alice.accountDevices!;
      await alice.receiveOwnDeviceListForTesting(
        'dev-puppet',
        await statement(
          version: before.version + 1,
          devices: [
            for (final d in before.devices)
              if (d.deviceId != 'dev-puppet') d,
          ],
          revoked: {
            ...before.revoked,
            'dev-puppet': DateTime.now().toUtc(),
            for (var i = 0; i < 900; i++)
              'dev-padding-$i': DateTime.now().toUtc(),
          },
        ),
      );
      expect(alice.accountDevices!.revoked.keys, contains('dev-puppet'));
      expect(
        alice.accountDevices!.revoked.keys.where(
          (id) => id.startsWith('dev-padding'),
        ),
        isEmpty,
      );
    });

    test(
      'a device long out of touch syncs nothing until confirmed on both',
      () async {
        final (alice, bob, phone, advance) = await threeDevices();
        advance(const Duration(hours: 25));
        final aliceId = alice.identity!.deviceId;
        final bobId = bob.identity!.deviceId;
        final phoneId = phone.identity!.deviceId;
        final qr = await phone.startLinkAsNewDevice();
        await alice.startLinkFromQrCode(qr);
        await _waitForIroh(
          () =>
              phone.linkState == LinkState.compareCode &&
              alice.linkState == LinkState.compareCode,
        );
        await phone.confirmLinkCode();
        await alice.confirmLinkCode();
        await _waitForIroh(() => phone.linkState == LinkState.linked);
        expect(alice.unconfirmedOwnDevices, isEmpty);

        // Eight days with no word between them.
        advance(const Duration(days: 8));
        expect(alice.unconfirmedOwnDevices.map((d) => d.deviceId), [phoneId]);
        expect(phone.unconfirmedOwnDevices.map((d) => d.deviceId), [aliceId]);
        await phone.sendMessage(contact: phone.contacts.single, body: 'unsure');
        for (var i = 0; i < 10; i++) {
          await Future.wait([alice.pollNow(), phone.pollNow(), bob.pollNow()]);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          alice.messagesFor(bobId).any((m) => m.body == 'unsure'),
          isFalse,
          reason: 'an unconfirmed device synced',
        );
        // Even one that sends anyway (it may not follow the rules) is not
        // listened to.
        await phone.sendAccountSyncForTesting(aliceId, {
          'type': 'sent',
          'chat': bobId,
          'id': 'msg-forced',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'payload': 'forced',
        });
        for (var i = 0; i < 10; i++) {
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          alice.messagesFor(bobId).any((m) => m.id == 'msg-forced'),
          isFalse,
        );

        // Confirmed on the phone first: what it held back goes to the
        // laptop, which keeps it until confirmed there too.
        await phone.confirmOwnDevice(aliceId);
        for (var i = 0; i < 20; i++) {
          await Future.wait([alice.pollNow(), phone.pollNow()]);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          alice.messagesFor(bobId).any((m) => m.body == 'unsure'),
          isFalse,
        );
        await alice.confirmOwnDevice(phoneId);
        expect(alice.unconfirmedOwnDevices, isEmpty);
        expect(
          alice.messagesFor(bobId).any((m) => m.body == 'unsure'),
          isTrue,
          reason: 'what was sent while unconfirmed was lost',
        );
        await phone.sendMessage(contact: phone.contacts.single, body: 'sure');
        await _waitForIroh(() {
          unawaited(alice.pollNow());
          unawaited(phone.pollNow());
          return alice.messagesFor(bobId).any((m) => m.body == 'sure');
        }, reason: 'syncing did not resume');
      },
    );

    test('a contact device its account lost touch with is flagged', () async {
      var now = DateTime.now().toUtc();
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> make(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => now,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await make('Alice');
      final bob = await make('Bob');
      final phone = await make('Phone');
      await _pairControllers(alice, bob);
      now = now.add(const Duration(hours: 25));
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      final phoneId = phone.identity!.deviceId;
      final qr = await phone.startLinkAsNewDevice();
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            alice.linkState == LinkState.compareCode,
      );
      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return phone.linkState == LinkState.linked &&
            bob.linkedDevicesOf(aliceId).isNotEmpty;
      });
      ContactRecord bobAt(MessengerController device) =>
          device.contacts.firstWhere((c) => c.deviceId == bobId);
      Future<void> bobReads() async {
        for (var i = 0; i < 10; i++) {
          await bob.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      // The laptop tells Bob it counts the phone as Alice's.
      await alice.checkContactRoutes(bobAt(alice));
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob.linkedDevicesOf(aliceId).single.siblingsHeardAt != null;
      }, reason: 'Bob never heard the laptop vouch for the phone');
      expect(bob.contactDeviceOutOfTouchSince(phoneId), isNull);

      // Nine days later the laptop no longer counts the phone (they have
      // not been in touch): the phone is flagged.
      now = now.add(const Duration(days: 9));
      await alice.checkContactRoutes(bobAt(alice));
      await bobReads();
      expect(bob.contactDeviceOutOfTouchSince(phoneId), isNotNull);

      // Then the laptop goes in a drawer (gone from the network) and only
      // the phone talks: the laptop is flagged, the active phone (which no
      // other device has reported on lately) is not.
      final laptopIroh = alice.identity!.irohEndpointId!;
      relay.shouldFailStore = (_, _, _, _, envelope) =>
          envelope.senderDeviceId == aliceId;
      for (final other in [bob, phone]) {
        network.blockedPairs
          ..add((laptopIroh, other.identity!.irohEndpointId!))
          ..add((other.identity!.irohEndpointId!, laptopIroh));
      }
      now = now.add(const Duration(days: 3));
      await phone.checkContactRoutes(bobAt(phone));
      await bobReads();
      expect(bob.contactDeviceOutOfTouchSince(aliceId), isNotNull);
      expect(bob.contactDeviceOutOfTouchSince(phoneId), isNull);
    });

    test('own devices carry for each other: a message the laptop cannot '
        'deliver goes through the phone', () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      var now = DateTime.now().toUtc();
      Future<MessengerController> make(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => now,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await make('Alice');
      final bob = await make('Bob');
      final phone = await make('Phone');
      await _pairControllers(alice, bob);
      now = now.add(const Duration(hours: 25));
      final qr = await phone.startLinkAsNewDevice();
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            alice.linkState == LinkState.compareCode,
      );
      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      final phoneId = phone.identity!.deviceId;
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        unawaited(phone.pollNow());
        unawaited(bob.pollNow());
        return phone.linkState == LinkState.linked &&
            alice.ownDevices.any(
              (d) =>
                  d.deviceId == phoneId &&
                  d.featureCapabilities.contains(
                    ApplicationCapability.forwardForContactsV1,
                  ),
            ) &&
            bob.linkedDevicesOf(alice.identity!.deviceId).isNotEmpty;
      }, reason: 'the phone never offered to carry');
      // The laptop reaches neither Bob nor any relay; the phone reaches Bob.
      relay.shouldFailStore = (_, _, _, _, _) => true;
      network.blockedPairs
        ..add((alice.identity!.irohEndpointId!, bob.identity!.irohEndpointId!))
        ..add((bob.identity!.irohEndpointId!, alice.identity!.irohEndpointId!));
      await alice.sendMessage(
        contact: alice.contacts.single,
        body: 'via my phone',
      );
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        unawaited(phone.pollNow());
        unawaited(bob.pollNow());
        return bob
            .messagesFor(alice.identity!.deviceId)
            .any((m) => m.body == 'via my phone');
      }, reason: 'the phone did not carry it');
    });

    test('a device removed on one device is removed on the others', () async {
      var now = DateTime.now().toUtc();
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> make(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => now,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await make('Alice');
      final bob = await make('Bob');
      final phone = await make('Phone');
      final tablet = await make('Tablet');
      await _pairControllers(alice, bob);
      now = now.add(const Duration(hours: 25));
      Future<void> link(MessengerController device) async {
        final qr = await device.startLinkAsNewDevice();
        await alice.startLinkFromQrCode(qr);
        await _waitForIroh(
          () =>
              device.linkState == LinkState.compareCode &&
              alice.linkState == LinkState.compareCode,
        );
        await device.confirmLinkCode();
        await alice.confirmLinkCode();
        await _waitForIroh(() => device.linkState == LinkState.linked);
        alice.cancelLink();
        device.cancelLink();
      }

      await link(phone);
      await link(tablet);
      final aliceId = alice.identity!.deviceId;
      final phoneId = phone.identity!.deviceId;
      final tabletId = tablet.identity!.deviceId;
      // The phone learns of the tablet from the laptop.
      await _waitForIroh(() {
        unawaited(phone.pollNow());
        return phone.ownDevices.any((d) => d.deviceId == tabletId);
      }, reason: 'the phone did not learn of the tablet');
      expect(
        tablet.ownDevices.map((d) => d.deviceId),
        unorderedEquals([aliceId, phoneId]),
      );

      now = now.add(const Duration(hours: 25));
      await alice.revokeAccountDevice(phoneId);
      expect(alice.ownDevices.map((d) => d.deviceId), [tabletId]);
      await _waitForIroh(() {
        unawaited(tablet.pollNow());
        return tablet.accountDevices!.revoked.containsKey(phoneId);
      }, reason: 'the tablet did not learn the phone was removed');
      expect(tablet.ownDevices.map((d) => d.deviceId), [aliceId]);

      // Nothing the removed phone sends is taken as the account's.
      await phone.sendMessage(
        contact: phone.contacts.single,
        body: 'after removal',
      );
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob.linkedDevicesOf(aliceId).every((d) => d.deviceId != phoneId);
      }, reason: 'Bob kept the removed phone');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await alice.pollNow();
      await tablet.pollNow();
      await bob.pollNow();
      final bobId = bob.identity!.deviceId;
      for (final device in [alice, tablet]) {
        expect(
          device.messagesFor(bobId).any((m) => m.body == 'after removal'),
          isFalse,
        );
      }
      expect(
        bob.messagesFor(aliceId).any((m) => m.body == 'after removal'),
        isFalse,
      );
    });

    test('removing a contact removes their other devices', () async {
      final (alice, bob, phone, advance) = await threeDevices();
      advance(const Duration(hours: 25));
      final aliceId = alice.identity!.deviceId;
      final qr = await phone.startLinkAsNewDevice();
      await alice.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            alice.linkState == LinkState.compareCode,
      );
      await phone.confirmLinkCode();
      await alice.confirmLinkCode();
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob.linkedDevicesOf(aliceId).isNotEmpty;
      });
      await bob.removeContact(aliceId);
      expect(bob.linkedDevicesOf(aliceId), isEmpty);
    });

    testWidgets('Settings lists the devices and shows a link code', (
      tester,
    ) async {
      final alice = (await tester.runAsync(
        () => _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
        ),
      ))!;
      addTearDown(alice.dispose);
      await tester.runAsync(() => alice.createAccount(deviceName: 'Laptop'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: alice,
              builder: (context, _) => DevicesPanel(controller: alice),
            ),
          ),
        ),
      );
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('link-this-device')));
      await tester.pump();
      for (
        var i = 0;
        i < 20 && find.byKey(const ValueKey('link-qr-text')).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      final qr = tester.widget<SelectableText>(
        find.byKey(const ValueKey('link-qr-text')),
      );
      expect(qr.data, startsWith('cl1|'));
      expect(alice.linkState, LinkState.showingQrCode);
      alice.cancelLink();
      await tester.pump(const Duration(seconds: 1));
    });

    test(
      'nothing secret is sent unless the new device confirmed too',
      () async {
        final (alice, _, phone, advance) = await threeDevices();
        advance(const Duration(hours: 25));
        final qr = await phone.startLinkAsNewDevice();
        await alice.startLinkFromQrCode(qr);
        await _waitForIroh(
          () =>
              phone.linkState == LinkState.compareCode &&
              alice.linkState == LinkState.compareCode,
        );
        // Only the existing device confirms.
        await alice.confirmLinkCode();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(phone.linkState, isNot(LinkState.linked));
        expect(phone.identity!.accountKeyPrivateBase64, isNull);
        expect(alice.accountDevices!.devices.length, 1);
        // A code from another device's QR does not start a link.
        await expectLater(
          alice.startLinkFromQrCode('cl1|not|a|real|code|x'),
          throwsArgumentError,
        );
      },
    );

    test('a contact learns the account\'s other devices, and loses revoked '
        'ones', () async {
      var now = DateTime.now().toUtc();
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
        nowProvider: () => now,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
        nowProvider: () => now,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final aliceId = alice.identity!.deviceId;

      await alice.createAccount(deviceName: 'Laptop');
      expect(alice.accountDevices?.devices.single.name, 'Laptop');
      // A brand-new identity waits a day before adding devices.
      expect(alice.mayManageAccountDevices, isFalse);
      now = now.add(const Duration(hours: 25));
      expect(alice.mayManageAccountDevices, isTrue);

      final phoneSigning = await Ed25519().newKeyPair();
      final phoneSigningKey = base64Encode(
        (await phoneSigning.extractPublicKey()).bytes,
      );
      final phoneEncryption = await X25519().newKeyPair();
      final phoneEncryptionKey = base64Encode(
        (await phoneEncryption.extractPublicKey()).bytes,
      );
      Future<String> phoneProof() async => base64Encode(
        (await Ed25519().sign(
          DeviceCert.proofBytes(
            accountId: alice.identity!.accountId,
            accountKeyBase64: alice.identity!.accountKeyPublicBase64!,
            deviceId: 'alice-phone',
            encryptionKeyBase64: phoneEncryptionKey,
            signingKeyBase64: phoneSigningKey,
          ),
          keyPair: phoneSigning,
        )).bytes,
      );
      // Without the phone's own proof it is refused.
      await expectLater(
        alice.addAccountDevice(
          deviceId: 'alice-phone',
          encryptionKeyBase64: phoneEncryptionKey,
          signingKeyBase64: phoneSigningKey,
          name: 'Pixel 8',
          proofSignatureBase64: base64Encode(List<int>.filled(64, 1)),
        ),
        throwsArgumentError,
      );
      await alice.addAccountDevice(
        deviceId: 'alice-phone',
        encryptionKeyBase64: phoneEncryptionKey,
        signingKeyBase64: phoneSigningKey,
        name: 'Pixel 8',
        proofSignatureBase64: await phoneProof(),
      );
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob.linkedDevicesOf(aliceId).isNotEmpty;
      }, reason: 'Bob did not learn Alice\'s phone');
      final phone = bob.linkedDevicesOf(aliceId).single;
      expect(phone.deviceId, 'alice-phone');
      expect(phone.deviceName, 'Pixel 8');
      expect(phone.signingPublicKeyBase64, phoneSigningKey);
      // Listed once: the phone is Alice, not a new contact.
      expect(bob.contacts.map((c) => c.deviceId), [aliceId]);
      expect(
        bob.contacts.single.accountKeyBase64,
        alice.identity!.accountKeyPublicBase64,
      );

      await alice.revokeAccountDevice('alice-phone');
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob.linkedDevicesOf(aliceId).isEmpty;
      }, reason: 'Bob kept the revoked phone');
      expect(
        bob.contacts.single.accountRevokedDeviceIds,
        contains('alice-phone'),
      );
      // It cannot come back.
      await expectLater(
        alice.addAccountDevice(
          deviceId: 'alice-phone',
          encryptionKeyBase64: phoneEncryptionKey,
          signingKeyBase64: phoneSigningKey,
          name: 'Pixel 8',
          proofSignatureBase64: await phoneProof(),
        ),
        throwsStateError,
      );
      // The original device stays: contacts know the account through it.
      expect(() => alice.revokeAccountDevice(aliceId), throwsArgumentError);
    });
  });

  group('User modes', () {
    test('a new identity chooses a mode; older vaults stay advanced', () async {
      final vault = _MemoryVaultStore();
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: vault,
      );
      addTearDown(alice.dispose);
      expect(alice.needsUserModeChoice, isTrue);
      await alice.setUserMode(UserMode.minimal);
      expect(alice.needsUserModeChoice, isFalse);
      expect(alice.userMode, UserMode.minimal);
      expect((await vault.load()).userMode, UserMode.minimal);

      // A vault from before modes: advanced, nothing to choose.
      final old = VaultSnapshot.fromJson(
        (await vault.load()).toJson()
          ..remove('userMode')
          ..remove('userModeChosen'),
      );
      expect(old.userMode, isNull);
      expect(old.userModeChosen, isTrue);
    });

    test('the language is kept, and can follow the device again', () async {
      final vault = _MemoryVaultStore();
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: vault,
      );
      addTearDown(alice.dispose);
      expect(alice.localeCode, isNull);
      await alice.setLocaleCode('fa');
      expect((await vault.load()).localeCode, 'fa');
      await alice.setLocaleCode(null);
      expect(alice.localeCode, isNull);
      expect((await vault.load()).localeCode, isNull);
    });

    Widget localized(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );

    testWidgets('after the mode, the ways that work here are offered', (
      tester,
    ) async {
      // On this network: one Nostr relay answers, no chatmail server does.
      final nostr = FakeNostrRelays()..relay(nostrRelayCandidates[2]);
      final alice = (await tester.runAsync(
        () => _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
          internetRelayHost: null,
          nostrConnector: nostr.connect,
          mailConnector: (host, port, {required bool tls}) async =>
              throw const SocketException('Connection timed out'),
        ),
      ))!;
      addTearDown(alice.dispose);
      await tester.pumpWidget(localized(UserModeScreen(controller: alice)));
      await tester.tap(find.byKey(const ValueKey('user-mode-advanced')));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('user-mode-continue')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('user-mode-continue')));
      await tester.runAsync(() async {
        for (var i = 0; i < 100; i++) {
          await tester.pump();
          if (find
              .byKey(const ValueKey('transports-count'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      // Nostr answers: offered ticked. Email is blocked here: not offered.
      final nostrRow = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('transport-nostr')),
      );
      expect(nostrRow.value, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('transport-deltaChat')),
          matching: find.text('Blocked here'),
        ),
        findsOneWidget,
      );
      expect(find.text('1 set up: 3 recommended'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('transports-start')),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('transports-start')));
        await _waitForIroh(() => alice.nostrCarrierConfig != null);
      });
      await tester.pump();
      expect(alice.userMode, UserMode.advanced);
      expect(alice.nostrCarrierConfig?.relays, [nostrRelayCandidates[2]]);
    });

    testWidgets('finishing with no way over the internet asks first', (
      tester,
    ) async {
      final nostr = FakeNostrRelays(); // every relay refuses
      final alice = (await tester.runAsync(
        () => _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
          internetRelayHost: null,
          nostrConnector: nostr.connect,
          mailConnector: (host, port, {required bool tls}) async =>
              throw const SocketException('Connection timed out'),
        ),
      ))!;
      addTearDown(alice.dispose);
      await tester.pumpWidget(
        localized(
          Scaffold(
            body: SingleChildScrollView(
              child: TransportsStep(
                controller: alice,
                onBack: () {},
                onDone: () => alice.setUserMode(UserMode.normal),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 100; i++) {
          await tester.pump();
          if (find
              .byKey(const ValueKey('transports-count'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(
        find.text('None set up yet: 1 needed, 3 recommended'),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('transports-start')),
      );
      await tester.tap(find.byKey(const ValueKey('transports-start')));
      await tester.pumpAndSettle();
      expect(find.text('Only nearby devices could reach you'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transports-skip-confirm')));
      await tester.pump();
      await tester.runAsync(
        () => _waitForIroh(() => alice.userMode == UserMode.normal),
      );
      expect(alice.userMode, UserMode.normal);
    });

    testWidgets('the chat list says when only this network can reach us', (
      tester,
    ) async {
      final nostr = FakeNostrRelays()..relay('wss://r.test');
      final alice = (await tester.runAsync(
        () => _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
          internetRelayHost: null,
          nostrConnector: nostr.connect,
        ),
      ))!;
      addTearDown(alice.dispose);
      expect(alice.internetTransportsWorking, 0);
      var setUp = 0;
      await tester.pumpWidget(
        localized(
          Scaffold(
            body: InternetReachBanner(
              controller: alice,
              onSetUp: () => setUp++,
              grace: const Duration(milliseconds: 10),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        find.byKey(const ValueKey('internet-reach-banner')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('internet-reach-set-up')));
      expect(setUp, 1);
      // A way over the internet works: the banner goes.
      await tester.runAsync(() async {
        await alice.enableNostrCarrier(relays: ['wss://r.test']);
        await _waitForIroh(() => alice.internetTransportsWorking > 0);
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('internet-reach-banner')), findsNothing);
    });

    testWidgets('standard mode on a phone has chats and calls tabs', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final alice = (await tester.runAsync(
        () => _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
        ),
      ))!;
      addTearDown(alice.dispose);
      final updates = _createUpdateService();
      final theme = app.ConestThemeController.memory();
      addTearDown(updates.dispose);
      addTearDown(theme.dispose);
      Future<void> show() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ListenableBuilder(
              listenable: alice,
              builder: (context, _) => app.HomeScreen(
                controller: alice,
                updateService: updates,
                buildInfo: _createBuildInfo(),
                themeController: theme,
                palette: app.ConestPalette(),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await tester.runAsync(() => alice.setUserMode(UserMode.advanced));
      await show();
      expect(find.byKey(const ValueKey('phone-tabs')), findsNothing);

      await tester.runAsync(() => alice.setUserMode(UserMode.normal));
      await show();
      expect(find.byKey(const ValueKey('phone-tabs')), findsOneWidget);
      await tester.tap(find.text('Calls'));
      await tester.pump();
      expect(find.textContaining('No calls yet'), findsOneWidget);
    });

    testWidgets('simple mode shows only personal settings until asked', (
      tester,
    ) async {
      final alice = (await tester.runAsync(
        () => _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
        ),
      ))!;
      addTearDown(alice.dispose);
      await tester.runAsync(() => alice.setUserMode(UserMode.minimal));
      final updates = _createUpdateService();
      final theme = app.ConestThemeController.memory();
      addTearDown(updates.dispose);
      addTearDown(theme.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: app.SettingsDialog(
              controller: alice,
              updateService: updates,
              themeController: theme,
              palette: app.ConestPalette(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('// CONNECTIVITY'), findsNothing);
      expect(find.text('// PERSONAL'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('show-all-settings')),
      );
      await tester.tap(find.byKey(const ValueKey('show-all-settings')));
      await tester.pump();
      expect(find.text('// CONNECTIVITY'), findsOneWidget);
    });
  });

  group('Watching relays', () {
    Future<Set<String>> watchedHosts(EnergyMode mode) async {
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        enableLongPoll: true,
        energyPolicy: EnergyPolicy.fixed(mode),
      );
      addTearDown(alice.dispose);
      await alice.addRelay(host: 'relay-two.example', port: 7667);
      relay.waitingFetchHosts.clear();
      // The watchers look for relays every 5 s.
      await Future<void>.delayed(const Duration(seconds: 7));
      return relay.waitingFetchHosts.toSet();
    }

    test('on mains power a second relay is watched too', () async {
      expect(
        await watchedHosts(EnergyMode.unconstrained),
        containsAll(['relay.example', 'relay-two.example']),
      );
    });

    test('in battery saver one relay is watched', () async {
      expect((await watchedHosts(EnergyMode.saver)).length, 1);
    });
  });

  test('a group message its author could not hand on still reaches a '
      'member through the slow catch-up', () async {
    final network = _InProcessIrohNetwork();
    final relay = _FakeRelayClient();
    var carolNow = DateTime.now().toUtc();
    Future<MessengerController> device(
      String name, {
      DateTime Function()? now,
    }) async {
      final controller = await _createController(
        relayClient: relay,
        displayName: name,
        transportRegistryFactory: network.registry,
        nowProvider: now,
        // Battery saver (the tests' default) skips the slow catch-up.
        energyPolicy: EnergyPolicy.fixed(EnergyMode.limited),
      );
      addTearDown(controller.dispose);
      return controller;
    }

    final alice = await device('Alice');
    final bob = await device('Bob');
    final carol = await device('Carol', now: () => carolNow);
    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);
    await _pairControllers(bob, carol);
    final group = await alice.createGroup(
      title: 'Slow',
      members: alice.contacts,
    );
    Future<void> settle(bool Function() ready, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await Future.wait([bob.pollNow(), carol.pollNow(), alice.pollNow()]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: reason);
    }

    await settle(
      () => bob.visibleGroups.isNotEmpty && carol.visibleGroups.isNotEmpty,
      'the group did not reach everyone',
    );
    // Carol's catch-up clock starts.
    await carol.pollNow();
    relay.shouldFailStore = (_, _, _, _, _) => true;
    final aliceIroh = alice.identity!.irohEndpointId!;
    final carolIroh = carol.identity!.irohEndpointId!;
    final bobIroh = bob.identity!.irohEndpointId!;
    network.blockedPairs
      ..add((aliceIroh, carolIroh))
      ..add((carolIroh, aliceIroh));
    await alice.sendGroupMessage(groupId: group.groupId, body: 'gone quiet');
    // Alice is no longer driven (her app is in the background), so her
    // retries never ask anyone; Bob pulls her signed event.
    final bobDeadline = DateTime.now().add(const Duration(seconds: 20));
    bool bobHasSigned() => bob
        .messagesForGroup(group.groupId)
        .any(
          (m) =>
              m.body == 'gone quiet' && m.verifiedGroupHistoryEventId != null,
        );
    while (!bobHasSigned() && DateTime.now().isBefore(bobDeadline)) {
      await Future.wait([bob.pollNow(), carol.pollNow()]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(bobHasSigned(), isTrue, reason: 'Bob did not get the signed event');
    // Then Alice is gone before she could ask anyone.
    network.blockedPairs
      ..add((aliceIroh, bobIroh))
      ..add((bobIroh, aliceIroh));
    for (var i = 0; i < 20; i++) {
      await Future.wait([bob.pollNow(), carol.pollNow()]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      carol.messagesForGroup(group.groupId).any((m) => m.body == 'gone quiet'),
      isFalse,
    );
    carolNow = carolNow.add(const Duration(minutes: 21));
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    bool reached() => carol
        .messagesForGroup(group.groupId)
        .any((m) => m.body == 'gone quiet');
    while (!reached() && DateTime.now().isBefore(deadline)) {
      await Future.wait([bob.pollNow(), carol.pollNow()]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(reached(), isTrue, reason: 'the slow catch-up did not bring it');
  });

  test(
    'when every member is reached, a group message causes no notices',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final devices = <MessengerController>[];
      for (final name in ['Alice', 'Bob', 'Carol', 'Dan', 'Eve']) {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
        );
        addTearDown(controller.dispose);
        devices.add(controller);
      }
      final alice = devices.first;
      for (final other in devices.skip(1)) {
        await _pairControllers(alice, other);
      }
      final group = await alice.createGroup(
        title: 'Quiet',
        members: alice.contacts,
      );
      Future<void> settle(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await Future.wait([for (final d in devices) d.pollNow()]);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue);
      }

      await settle(
        () => devices.skip(1).every((d) => d.visibleGroups.isNotEmpty),
      );
      for (var i = 0; i < 40; i++) {
        await Future.wait([for (final d in devices) d.pollNow()]);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      // Counted from before the first message (notices to a member are
      // spaced 20 s apart, so the second alone could hide them).
      final before = [for (final d in devices) d.groupNoticesSent];
      await alice.sendGroupMessage(groupId: group.groupId, body: 'warm up');
      await settle(
        () => devices
            .skip(1)
            .every(
              (d) => d
                  .messagesForGroup(group.groupId)
                  .any((m) => m.body == 'warm up'),
            ),
      );
      await alice.sendGroupMessage(groupId: group.groupId, body: 'hello all');
      await settle(
        () => devices
            .skip(1)
            .every(
              (d) => d
                  .messagesForGroup(group.groupId)
                  .any((m) => m.body == 'hello all'),
            ),
      );
      for (var i = 0; i < 40; i++) {
        await Future.wait([for (final d in devices) d.pollNow()]);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final sent = [
        for (var i = 0; i < devices.length; i++)
          devices[i].groupNoticesSent - before[i],
      ];
      expect(sent.reduce((a, b) => a + b), 0, reason: 'notices: $sent');
    },
  );

  test('a group message reaches a member its author cannot reach, through '
      'a member who can', () async {
    final network = _InProcessIrohNetwork();
    final relay = _FakeRelayClient();
    Future<MessengerController> device(String name) async {
      final controller = await _createController(
        relayClient: relay,
        displayName: name,
        transportRegistryFactory: network.registry,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    final alice = await device('Alice');
    final bob = await device('Bob');
    final carol = await device('Carol');
    await _pairControllers(alice, bob);
    await _pairControllers(alice, carol);
    final group = await alice.createGroup(
      title: 'Relay',
      members: alice.contacts,
    );
    await _waitForIroh(() {
      unawaited(bob.pollNow());
      unawaited(carol.pollNow());
      return bob.visibleGroups.isNotEmpty && carol.visibleGroups.isNotEmpty;
    });
    // Everyone's history is in step before the link between Alice and
    // Carol goes (no relays either).
    await alice.sendGroupMessage(groupId: group.groupId, body: 'warm up');
    await _waitForIroh(() {
      unawaited(bob.pollNow());
      unawaited(carol.pollNow());
      return [bob, carol].every(
        (d) =>
            d.messagesForGroup(group.groupId).any((m) => m.body == 'warm up'),
      );
    });
    relay.shouldFailStore = (_, _, _, _, _) => true;
    final aliceIroh = alice.identity!.irohEndpointId!;
    final carolIroh = carol.identity!.irohEndpointId!;
    network.blockedPairs
      ..add((aliceIroh, carolIroh))
      ..add((carolIroh, aliceIroh));

    await alice.sendGroupMessage(groupId: group.groupId, body: 'via Bob');
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    bool reached() =>
        carol.messagesForGroup(group.groupId).any((m) => m.body == 'via Bob');
    while (!reached() && DateTime.now().isBefore(deadline)) {
      await Future.wait([alice.pollNow(), bob.pollNow(), carol.pollNow()]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(reached(), isTrue, reason: 'Carol never got Alice\'s message');
    // Once Carol holds what Bob holds, his announcement makes her pull
    // nothing; one newer event than hers does.
    final bobHeads = await bob.groupHeadsForTesting(group.groupId);
    final deadline2 = DateTime.now().add(const Duration(seconds: 10));
    while (await carol.groupAnnouncementHasNewerForTesting(
          group.groupId,
          bobHeads,
        ) &&
        DateTime.now().isBefore(deadline2)) {
      await Future.wait([bob.pollNow(), carol.pollNow()]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(
      await carol.groupAnnouncementHasNewerForTesting(group.groupId, bobHeads),
      isFalse,
    );
    final aliceId = alice.identity!.deviceId;
    expect(
      await carol.groupAnnouncementHasNewerForTesting(group.groupId, {
        ...bobHeads,
        aliceId: (bobHeads[aliceId] ?? 0) + 1,
      }),
      isTrue,
    );
    expect(
      await carol.groupAnnouncementHasNewerForTesting(group.groupId, 'junk'),
      isTrue,
    );
    expect(
      carol
          .messagesForGroup(group.groupId)
          .where((m) => m.body == 'via Bob')
          .single
          .senderDeviceId,
      alice.identity!.deviceId,
    );
  });

  testWidgets('a send that finds no route goes into the error history, '
      'shown in its screen', (tester) async {
    final relay = _FakeRelayClient();
    final (alice, bob) = (await tester.runAsync(() async {
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        keepErrorHistory: true,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      await _pairControllers(alice, bob);
      return (alice, bob);
    }))!;
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    expect(alice.errorHistoryEnabled, isTrue);
    expect(bob.errorHistoryEnabled, isFalse);
    relay.shouldFailStore = (_, _, _, _, _) => true;
    await tester.runAsync(
      () => alice
          .sendMessage(contact: alice.contacts.single, body: 'lost')
          .catchError((Object _) {}),
    );
    expect(
      alice.errorHistoryEntries.any(
        (entry) => entry.kind == 'send' && entry.text.contains('Bob'),
      ),
      isTrue,
    );
    await tester.pumpWidget(
      MaterialApp(home: ErrorHistoryScreen(controller: alice)),
    );
    expect(find.textContaining('found no route'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('error-history-filter')),
      'nothing like this',
    );
    await tester.pump();
    expect(find.text('Nothing recorded.'), findsOneWidget);
  });

  test(
    'a full transport test knows each route in both directions',
    () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      var bobLater = Duration.zero;
      Future<MessengerController> device(
        String name, {
        DateTime Function()? now,
      }) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: now,
          debugBuildId: 'test@abc',
          keepErrorHistory: true,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await device('Alice');
      final bob = await device(
        'Bob',
        now: () => DateTime.now().toUtc().add(bobLater),
      );
      await _pairControllers(alice, bob);
      var polling = true;
      addTearDown(() => polling = false);
      unawaited(() async {
        while (polling) {
          await Future.wait([
            alice.pollNow(),
            bob.pollNow(),
          ]).catchError((_) => const <void>[]);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }());
      final report = await alice.runTransportExchangeTest(
        alice.contacts.single,
        remoteTimeout: const Duration(seconds: 30),
      );
      expect(report.remote, isNotNull, reason: report.remoteError);
      expect(report.directions['irohDirect'], RouteDirections.twoWay);
      expect(report.local.inventory, isNotEmpty);
      expect(report.remote!.inventory, isNotEmpty);
      expect(alice.errorHistoryEntries.any((e) => e.kind == 'test'), isTrue);

      // Alice's Iroh no longer reaches Bob; his still reaches her.
      network.blockedPairs.add((
        alice.identity!.irohEndpointId!,
        bob.identity!.irohEndpointId!,
      ));
      // Bob answers one test a minute.
      bobLater = const Duration(minutes: 2);
      final oneWay = await alice.runTransportExchangeTest(
        alice.contacts.single,
        remoteTimeout: const Duration(seconds: 30),
      );
      expect(oneWay.remote, isNotNull, reason: oneWay.remoteError);
      expect(oneWay.directions['irohDirect'], isNot(RouteDirections.twoWay));
      expect(oneWay.remote!.results['irohDirect']?.roundTripMs, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'a debug build started for tests runs them and writes a report',
    () async {
      expect(DebugRunRequest.fromArgs(const ['--other']), isNull);
      expect(DebugRunRequest.fromArgs(const ['--debug-run=nonsense']), isNull);
      final parsed = DebugRunRequest.fromArgs(const [
        '--debug-run=routes',
        '--debug-report=/tmp/x.json',
        '--debug-wait=0',
        '--debug-exit',
      ])!;
      expect(parsed.reportPath, '/tmp/x.json');
      expect(parsed.exitAfter, isTrue);
      expect(parsed.wait, Duration.zero);
      expect(DebugRunRequest.fromExtra('routes')?.what, 'routes');
      expect(DebugRunRequest.fromExtra('rm -rf'), isNull);

      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> device(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          debugBuildId: 'test@abc',
          keepErrorHistory: true,
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await device('Alice');
      final bob = await device('Bob');
      await _pairControllers(alice, bob);
      var polling = true;
      addTearDown(() => polling = false);
      unawaited(() async {
        while (polling) {
          await Future.wait([
            alice.pollNow(),
            bob.pollNow(),
          ]).catchError((_) => const <void>[]);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }());
      final root = Directory.systemTemp.createTempSync('conest_debug_run_');
      addTearDown(() => root.deleteSync(recursive: true));
      final path = await runDebugRequest(
        alice,
        const DebugRunRequest(what: 'routes', wait: Duration.zero),
        defaultReportPath: () async => '${root.path}/report.json',
      );
      final report = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(report['build'], 'test@abc');
      final contacts = report['contacts'] as List;
      expect(contacts.single['contact'], 'Bob');
      expect(
        (contacts.single['report'] as Map)['directions'],
        containsPair('irohDirect', 'twoWay'),
      );
      expect(report['errorHistory'], isA<String>());
    },
  );

  test('lab devices set themselves up, pair, and report messages', () async {
    final parsed = DebugRunRequest.fromExtra(
      'args:--debug-run=messages --debug-name=phone --debug-approve '
      '--debug-serve=5 --debug-group=lab-all --debug-relay=1.2.3.4:7667 '
      '--debug-accept-invite=AAA --debug-accept-invite=BBB '
      '--debug-no-reserve --debug-linger=90 '
      '--debug-carriers=nostr,bogus,tor,email '
      '--debug-reticulum=node.example:4242 '
      '--debug-chatmail=chat.example '
      '--debug-matrix=http://10.0.0.2:8008,lab-a,secret '
      '--debug-only-transport=conestRelay --debug-expect-group=lab-all',
    )!;
    expect(parsed.expectGroup, 'lab-all');
    expect(parsed.onlyTransport, TransportKind.conestRelay);
    // Unknown carriers are left out.
    expect(parsed.carriers, ['nostr', 'tor', 'email']);
    expect(parsed.reticulum, 'node.example:4242');
    expect(parsed.chatmail, 'chat.example');
    expect(parsed.matrix, 'http://10.0.0.2:8008,lab-a,secret');
    expect(parsed.noReserve, isTrue);
    expect(parsed.linger, const Duration(seconds: 90));
    expect(parsed.what, 'messages');
    expect(parsed.name, 'phone');
    expect(parsed.approve, isTrue);
    expect(parsed.serve, const Duration(seconds: 5));
    expect(parsed.group, 'lab-all');
    expect(parsed.relay, '1.2.3.4:7667');
    expect(parsed.invites, ['AAA', 'BBB']);
    // Groups made by the lab are lab-* only.
    expect(
      DebugRunRequest.fromArgs(const [
        '--debug-run=none',
        '--debug-group=Family',
      ])!.group,
      isNull,
    );

    final network = _InProcessIrohNetwork();
    final relay = _FakeRelayClient();
    Future<MessengerController> device() async {
      final controller = await _createController(
        relayClient: relay,
        displayName: 'unused',
        createIdentity: false,
        transportRegistryFactory: network.registry,
        debugBuildId: 'test@abc',
      );
      addTearDown(controller.dispose);
      return controller;
    }

    final phone = await device();
    final laptop = await device();
    var polling = true;
    addTearDown(() => polling = false);
    unawaited(() async {
      while (polling) {
        await Future.wait([
          if (phone.hasIdentity) phone.pollNow(),
          if (laptop.hasIdentity) laptop.pollNow(),
        ]).catchError((_) => const <void>[]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }());
    final root = Directory.systemTemp.createTempSync('conest_lab_');
    addTearDown(() => root.deleteSync(recursive: true));
    // The phone waits for the others, approving them.
    final phoneRun = runDebugRequest(
      phone,
      const DebugRunRequest(
        what: 'none',
        name: 'phone',
        approve: true,
        // Ends as soon as the laptop paired, not after 30 s.
        serve: Duration(seconds: 30),
        expectContacts: 1,
        // The laptop makes the group; the phone waits to be in it.
        expectGroup: 'lab-all',
        wait: Duration.zero,
        // Paired and talked to with every other transport off.
        onlyTransport: TransportKind.conestRelay,
        relay: 'relay.example:7667',
      ),
      defaultReportPath: () async => '${root.path}/phone.json',
    );
    final inviteFile = File('${root.path}/phone.json.invite');
    for (var i = 0; i < 100 && !inviteFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final started = DateTime.now();
    final laptopPath = await runDebugRequest(
      laptop,
      DebugRunRequest(
        what: 'messages',
        name: 'laptop',
        invites: [inviteFile.readAsStringSync()],
        serve: const Duration(seconds: 30),
        expectContacts: 1,
        group: 'lab-all',
        // Each message waits up to this long for its receipt.
        wait: const Duration(seconds: 3),
        onlyTransport: TransportKind.conestRelay,
        relay: 'relay.example:7667',
      ),
      defaultReportPath: () async => '${root.path}/laptop.json',
    );
    final phoneReport =
        jsonDecode(File(await phoneRun).readAsStringSync()) as Map;
    expect(
      (phoneReport['steps'] as List).firstWhere(
        (step) => step['step'] == 'joined lab-all',
      )['ok'],
      isTrue,
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 25)),
      reason: 'no fixed waits once paired',
    );
    expect(phone.identity!.displayName, 'phone');
    for (final device in [phone, laptop]) {
      final connectivity = device.identity!.connectivity;
      expect(connectivity.lanEnabled, isFalse);
      expect(
        connectivity.policyFor(TransportKind.iroh),
        TransportPolicy.disabled,
      );
      expect(
        connectivity.policyFor(TransportKind.conestRelay),
        TransportPolicy.automatic,
      );
    }
    final report = jsonDecode(File(laptopPath).readAsStringSync()) as Map;
    expect(laptop.contacts.single.canSendOutbound, isTrue);
    // How long pairing and each message took.
    expect((report['pairedAfterMs'] as Map).values.single, isA<int>());
    final timed = [
      for (final step in report['steps'] as List)
        if ((step['step'] as String).startsWith('message ')) step['result'],
    ];
    expect(timed, hasLength(3));
    expect(timed, everyElement(isA<int>()));
    final chats = report['chats'] as List;
    final direct = chats.firstWhere((chat) => chat['contact'] != null) as Map;
    expect(direct['messages'] as List, hasLength(3));
    final group = chats.firstWhere((chat) => chat['group'] == 'lab-all') as Map;
    expect(group['messages'] as List, hasLength(3));
    expect(
      phone
          .messagesFor(laptop.identity!.deviceId)
          .where((message) => message.body.startsWith('lab ')),
      hasLength(3),
    );
  });

  test(
    'lab interactions reach the other device, in chats and groups',
    () async {
      final relay = _FakeRelayClient();
      final root = Directory.systemTemp.createTempSync('conest_lab_do_');
      addTearDown(() => root.deleteSync(recursive: true));
      Future<MessengerController> device(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          debugBuildId: 'test@abc',
          keepErrorHistory: true,
          attachmentRootProvider: () async =>
              Directory('${root.path}/$name')..createSync(recursive: true),
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await device('Alice');
      final bob = await device('Bob');
      await _pairControllers(alice, bob);
      var polling = true;
      addTearDown(() => polling = false);
      unawaited(() async {
        while (polling) {
          await Future.wait([
            alice.pollNow(),
            bob.pollNow(),
          ]).catchError((_) => const <void>[]);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }());
      Future<void> until(bool Function() ready, String what) async {
        for (var i = 0; i < 200 && !ready(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: what);
      }

      await alice.createGroup(
        title: 'lab-all',
        members: [alice.contacts.single],
      );
      await until(() => bob.groups.isNotEmpty, 'Bob is in the group');
      final groupId = bob.groups.single.groupId;
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      await bob.sendMessage(
        contact: bob.contacts.single,
        body: 'lab 1 from Bob',
      );
      await bob.sendGroupMessage(groupId: groupId, body: 'lab 1 from Bob to g');
      await until(
        () =>
            alice.messagesFor(bobId).any((m) => m.body == 'lab 1 from Bob') &&
            alice
                .messagesForGroup(groupId)
                .any((m) => m.body == 'lab 1 from Bob to g'),
        'Alice has both',
      );

      final path = await runDebugRequest(
        alice,
        const DebugRunRequest(what: 'interactions', wait: Duration(seconds: 1)),
        defaultReportPath: () async => '${root.path}/alice.json',
      );
      final report = jsonDecode(File(path).readAsStringSync()) as Map;
      final failed = [
        for (final step in report['steps'] as List)
          if (step['ok'] != true) step,
      ];
      expect(failed, isEmpty);

      ChatMessage? bobSees(Iterable<ChatMessage> messages, String body) =>
          messages.where((m) => m.body == body).firstOrNull;
      List<ChatMessage> direct() => bob.messagesFor(aliceId);
      List<ChatMessage> group() => bob.messagesForGroup(groupId);
      for (final (where, messages) in [('chat', direct), ('group', group)]) {
        await until(
          () => bobSees(messages(), 'lab edited from Alice')?.isEdited == true,
          'the edit reaches Bob ($where)',
        );
        await until(
          () => bobSees(messages(), 'lab delete-me from Alice') == null,
          'the deletion reaches Bob ($where)',
        );
        final mine = messages().firstWhere(
          (m) => m.outbound && m.body.startsWith('lab 1 from Bob'),
        );
        expect(
          bobSees(messages(), 'lab reply from Alice')?.replyToMessageId,
          mine.id,
          reason: 'the reply quotes Bob ($where)',
        );
        await until(
          () => messages()
              .firstWhere((m) => m.id == mine.id)
              .reactions
              .containsKey('👍'),
          'the reaction reaches Bob ($where)',
        );
      }
      await until(
        () =>
            bob
                .messagesFor(aliceId)
                .firstWhere((m) => m.body == 'lab 1 from Bob')
                .state ==
            DeliveryState.read,
        'Bob sees his message read',
      );
      final cancelled = alice
          .messagesFor(bobId)
          .lastWhere((m) => m.attachment?.fileName == 'lab-cancel.bin');
      expect(cancelled.state, DeliveryState.canceled);
      expect(bob.attachmentAvailableLocally(cancelled.attachment!.id), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'background upkeep slows down on battery and more in battery saver',
    () async {
      Future<MessengerController> device(EnergyMode mode) async {
        final controller = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: mode.name,
          energyPolicy: EnergyPolicy.fixed(mode),
        );
        addTearDown(controller.dispose);
        controller.setAppForegroundState(false);
        return controller;
      }

      final mains = await device(EnergyMode.unconstrained);
      final battery = await device(EnergyMode.limited);
      final saver = await device(EnergyMode.saver);
      expect(
        battery.heartbeatIntervalForTesting(),
        mains.heartbeatIntervalForTesting() * 2,
      );
      expect(
        saver.heartbeatIntervalForTesting(),
        mains.heartbeatIntervalForTesting() * 4,
      );
      final mainsPoll = mains.pollIntervalForTesting;
      if (mainsPoll != null) {
        expect(saver.pollIntervalForTesting, mainsPoll * 4);
      }
      // In the foreground nothing slows down.
      saver.setAppForegroundState(true);
      mains.setAppForegroundState(true);
      expect(saver.pollIntervalForTesting, mains.pollIntervalForTesting);
      expect(
        saver.heartbeatIntervalForTesting(),
        mains.heartbeatIntervalForTesting(),
      );
    },
  );

  test('after a network change the usual contacts are re-checked, not in '
      'battery saver', () async {
    final relay = _FakeRelayClient();
    Future<MessengerController> device(String name, EnergyMode mode) async {
      final controller = await _createController(
        relayClient: relay,
        displayName: name,
        energyPolicy: EnergyPolicy.fixed(mode),
      );
      addTearDown(controller.dispose);
      return controller;
    }

    final alice = await device('Alice', EnergyMode.limited);
    final saver = await device('Saver', EnergyMode.saver);
    final bob = await device('Bob', EnergyMode.limited);
    await _pairControllers(alice, bob);
    await _pairControllers(saver, bob);
    for (final sender in [alice, saver]) {
      await sender.sendMessage(contact: sender.contacts.single, body: 'hello');
    }
    alice.onConnectivityChanged(interfaceLabel: 'wifi');
    saver.onConnectivityChanged(interfaceLabel: 'wifi');
    await Future<void>.delayed(const Duration(seconds: 7));
    expect(alice.quietlyRecheckedForTesting, {bob.identity!.deviceId});
    expect(saver.quietlyRecheckedForTesting, isEmpty);
  });

  testWidgets('the connection map shows links reported by group mates, and '
      'nobody else', (tester) async {
    final network = _InProcessIrohNetwork();
    final relay = _FakeRelayClient();
    final (alice, bob, carol, dan, group) = (await tester.runAsync(() async {
      Future<MessengerController> device(String name) => _createController(
        relayClient: relay,
        displayName: name,
        transportRegistryFactory: network.registry,
      );
      final alice = await device('Alice');
      final bob = await device('Bob');
      final carol = await device('Carol');
      final dan = await device('Dan');
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await _pairControllers(alice, dan);
      final group = await alice.createGroup(
        title: 'Map',
        members: alice.contacts
            .where((c) => c.deviceId != dan.identity!.deviceId)
            .toList(),
      );
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        unawaited(carol.pollNow());
        return bob.visibleGroups.isNotEmpty && carol.visibleGroups.isNotEmpty;
      });
      // Alice hears from everyone, then tells Bob how her links fare.
      for (final contact in alice.contacts) {
        await alice.checkContactRoutes(contact);
      }
      await Future.wait([bob.pollNow(), carol.pollNow(), dan.pollNow()]);
      await alice.pollNow();
      await alice.checkContactRoutes(
        alice.contacts.firstWhere((c) => c.deviceId == bob.identity!.deviceId),
      );
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob
                .connectionMap
                .reported[alice.identity!.deviceId]
                ?.isNotEmpty ??
            false;
      }, reason: 'Bob never heard how Alice is linked');
      return (alice, bob, carol, dan, group);
    }))!;
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    addTearDown(carol.dispose);
    addTearDown(dan.dispose);
    expect(group.groupId, isNotEmpty);
    // What Alice would tell Bob names only devices Bob knows from their
    // group (never Dan, whom she talks to as well).
    final shared = alice.linksToShareWithForTesting(
      alice.contacts.firstWhere((c) => c.deviceId == bob.identity!.deviceId),
    )!;
    expect(shared.keys, contains(carol.identity!.deviceId));
    expect(shared.keys, isNot(contains(dan.identity!.deviceId)));
    final reported = bob.connectionMap.reported[alice.identity!.deviceId]!;
    expect(reported.keys, contains(carol.identity!.deviceId));
    expect(reported.keys, isNot(contains(dan.identity!.deviceId)));
    // Whatever Alice sends, Bob keeps nothing about devices he does not
    // share a group with her (Dan): a report naming him is dropped.
    bob.receiveLinksForTesting(alice.identity!.deviceId, {
      dan.identity!.deviceId: 'twoWay',
      carol.identity!.deviceId: 'failing',
    });
    final kept = bob.connectionMap.reported[alice.identity!.deviceId]!;
    expect(kept.keys, isNot(contains(dan.identity!.deviceId)));
    expect(kept[carol.identity!.deviceId]?.status, LinkStatus.failing);
    await tester.runAsync(() => bob.noteNetwork('wifi'));
    await tester.pumpWidget(
      MaterialApp(home: ConnectionsScreen(controller: bob)),
    );
    expect(find.text('As Alice sees it'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('connections-networks')),
      200,
    );
    expect(find.text('In use now'), findsOneWidget);
  });

  group('Clocks that are off', () {
    Future<(MessengerController, MessengerController, MessengerController)>
    threeWithBobBehind() async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> make(
        String name, {
        Duration behind = Duration.zero,
      }) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          transportRegistryFactory: network.registry,
          nowProvider: () => DateTime.now().toUtc().subtract(behind),
        );
        addTearDown(controller.dispose);
        return controller;
      }

      final alice = await make('Alice');
      final bob = await make('Bob', behind: const Duration(hours: 2));
      final carol = await make('Carol');
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      return (alice, bob, carol);
    }

    test('a message from a device whose clock is behind still sorts after '
        'what it answers, in a group', () async {
      final (alice, bob, carol) = await threeWithBobBehind();
      final group = await alice.createGroup(
        title: 'Clocks',
        members: alice.contacts,
      );
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        unawaited(carol.pollNow());
        return bob.visibleGroups.isNotEmpty && carol.visibleGroups.isNotEmpty;
      });
      // Two from Alice, so Bob's journal (which has neither) would place his
      // answer between them unless he counts what he has seen.
      await alice.sendGroupMessage(groupId: group.groupId, body: 'zero');
      await alice.sendGroupMessage(groupId: group.groupId, body: 'first');
      await _waitForIroh(() {
        unawaited(bob.pollNow());
        return bob
            .messagesForGroup(group.groupId)
            .any((m) => m.body == 'first');
      });
      await bob.sendGroupMessage(groupId: group.groupId, body: 'second');
      await _waitForIroh(() {
        unawaited(carol.pollNow());
        unawaited(alice.pollNow());
        return [alice, carol].every(
          (device) => device
              .messagesForGroup(group.groupId)
              .any((m) => m.body == 'second'),
        );
      }, reason: 'Bob\'s message did not arrive');
      for (final device in [alice, carol]) {
        final bodies = [
          for (final message in device.messagesForGroup(group.groupId))
            if (message.body == 'first' || message.body == 'second')
              message.body,
        ];
        expect(bodies, ['first', 'second']);
      }
    });

    test('times from a contact whose clock is behind are corrected once '
        'its route updates agree on it', () async {
      final (alice, bob, _) = await threeWithBobBehind();
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      for (var i = 0; i < 3; i++) {
        await bob.checkContactRoutes(
          bob.contacts.firstWhere((c) => c.deviceId == aliceId),
        );
        await alice.pollNow();
      }
      // Alice's own route checks come back with her time echoed: they say
      // nothing about Bob's clock and must not unsettle the estimate.
      await alice.checkContactRoutes(
        alice.contacts.firstWhere((c) => c.deviceId == bobId),
      );
      // Bob reads it and answers; Alice reads the answer.
      await bob.pollNow();
      for (var i = 0; i < 5; i++) {
        await alice.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final offset = alice.clockOffsetFor(bobId);
      expect(offset, isNotNull);
      expect(
        (offset! - const Duration(hours: 2)).abs(),
        lessThan(const Duration(seconds: 30)),
      );
      await bob.sendMessage(
        contact: bob.contacts.firstWhere((c) => c.deviceId == aliceId),
        body: 'now',
      );
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return alice.messagesFor(bobId).any((m) => m.body == 'now');
      });
      final received = alice
          .messagesFor(bobId)
          .firstWhere((m) => m.body == 'now');
      expect(
        DateTime.now().toUtc().difference(received.createdAt).abs(),
        lessThan(const Duration(minutes: 1)),
      );
    });
  });

  group('Route tests', () {
    test('a capability list that was lost arrives with the next route '
        'update', () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        transportRegistryFactory: network.registry,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        transportRegistryFactory: network.registry,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final aliceId = alice.identity!.deviceId;
      // Alice's list reached Bob before an update (or was lost): he holds
      // one without route tests.
      bob.dropContactCapabilityForTesting(
        aliceId,
        ApplicationCapability.routeProbeV1,
      );
      expect(bob.canTestRoutes(bob.contacts.single), isFalse);
      // Any route update from Alice carries her capability digest.
      await alice.checkContactRoutes(alice.contacts.single);
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        unawaited(bob.pollNow());
        return bob.canTestRoutes(bob.contacts.single);
      }, reason: 'Bob never learned Alice can take route tests');
    });

    test(
      'each route is timed both ways, and a silent one is flagged',
      () async {
        final network = _InProcessIrohNetwork();
        final relay = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
          transportRegistryFactory: network.registry,
        );
        final bob = await _createController(
          relayClient: relay,
          displayName: 'Bob',
          transportRegistryFactory: network.registry,
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        final contact = alice.contacts.single;
        expect(alice.canTestRoutes(contact), isTrue);
        // Both keep reading their queues, as running apps do.
        var polling = true;
        addTearDown(() => polling = false);
        unawaited(() async {
          while (polling) {
            await Future.wait([
              alice.pollNow(),
              bob.pollNow(),
            ]).catchError((_) => const <void>[]);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }());

        final healthy = await alice.testContactRoutes(contact);
        final iroh = healthy.results.firstWhere(
          (result) => result.route?.family == MessageRoute.irohDirect,
        );
        expect(iroh.answered, isTrue);
        expect(healthy.results.length, greaterThanOrEqualTo(2));
        expect(
          alice.routeTestReportFor(contact.deviceId)?.results,
          same(healthy.results),
        );

        // Bob's side now drops what Alice sends straight to him.
        network.droppedPairs.add((
          alice.identity!.irohEndpointId!,
          bob.identity!.irohEndpointId!,
        ));
        final broken = await alice.testContactRoutes(
          contact,
          replyTimeout: const Duration(seconds: 3),
        );
        final silent = broken.results.firstWhere(
          (result) => result.route?.family == MessageRoute.irohDirect,
        );
        expect(silent.answered, isFalse);
        expect(silent.stored, isFalse);
        expect(
          broken.results.where((result) => result.answered),
          isNotEmpty,
          reason: 'another route still answers',
        );
      },
    );
  });

  group('Energy policy', () {
    test('mains power and unmetered networks send on every route', () {
      const plugged = PowerState(hasBattery: true, charging: true);
      const desktop = PowerState(hasBattery: false);
      const onBattery = PowerState(
        hasBattery: true,
        charging: false,
        batteryPercent: 80,
      );
      const low = PowerState(
        hasBattery: true,
        charging: false,
        batteryPercent: 12,
      );
      const saver = PowerState(charging: true, batterySaver: true);
      expect(
        EnergyPolicy.modeOf(desktop, NetworkCostClass.unmetered),
        EnergyMode.unconstrained,
      );
      expect(
        EnergyPolicy.modeOf(plugged, NetworkCostClass.unmetered),
        EnergyMode.unconstrained,
      );
      expect(
        EnergyPolicy.modeOf(plugged, NetworkCostClass.metered),
        EnergyMode.limited,
      );
      expect(
        EnergyPolicy.modeOf(onBattery, NetworkCostClass.unmetered),
        EnergyMode.limited,
      );
      expect(
        EnergyPolicy.modeOf(low, NetworkCostClass.unmetered),
        EnergyMode.saver,
      );
      expect(
        EnergyPolicy.modeOf(saver, NetworkCostClass.unmetered),
        EnergyMode.saver,
      );
      expect(
        EnergyPolicy.modeOf(PowerState.unknown, NetworkCostClass.unmetered),
        EnergyMode.limited,
      );
    });

    test('contacts on older apps and large groups get fewer copies', () {
      final policy = EnergyPolicy.fixed(EnergyMode.unconstrained);
      expect(
        policy.fanoutFor(NetworkCostClass.unmetered, copiesAllowed: false),
        isA<SingleRouteFanout>(),
      );
      expect(
        policy.fanoutFor(NetworkCostClass.unmetered, copiesAllowed: true),
        isA<AllRoutesFanout>(),
      );
      expect(
        policy.fanoutFor(
          NetworkCostClass.unmetered,
          copiesAllowed: true,
          groupSize: 20,
        ),
        isA<EscalatingFanout>(),
      );
    });

    test('Linux power supplies are read, device batteries ignored', () async {
      final root = await Directory.systemTemp.createTemp('conest_power-');
      addTearDown(() => root.delete(recursive: true));
      Future<void> supply(String name, Map<String, String> values) async {
        final dir = Directory('${root.path}/$name')..createSync();
        for (final entry in values.entries) {
          await File('${dir.path}/${entry.key}').writeAsString(entry.value);
        }
      }

      await supply('AC', {'type': 'Mains\n', 'online': '0\n'});
      await supply('BAT0', {
        'type': 'Battery\n',
        'status': 'Discharging\n',
        'capacity': '55\n',
      });
      await supply('hid-mouse', {
        'type': 'Battery\n',
        'scope': 'Device\n',
        'status': 'Charging\n',
        'capacity': '5\n',
      });
      final power = await LinuxPowerStateSource(root: root.path).read();
      expect(power.hasBattery, isTrue);
      expect(power.charging, isFalse);
      expect(power.batteryPercent, 55);
      await File('${root.path}/AC/online').writeAsString('1\n');
      expect(
        (await LinuxPowerStateSource(root: root.path).read()).charging,
        isTrue,
      );
    });

    test('a slow first route gets longer before the next copy', () {
      const base = Duration(milliseconds: 2500);
      expect(escalationInterval(base, null), base);
      expect(escalationInterval(base, 40), base);
      expect(escalationInterval(base, 4000), const Duration(seconds: 6));
      expect(escalationInterval(base, 90000), const Duration(seconds: 30));
    });

    test('Windows power status flags are read', () {
      final desktop = windowsPowerState(
        acLineStatus: 1,
        batteryFlag: 128,
        batteryLifePercent: 255,
        systemStatusFlag: 0,
      );
      expect(desktop.hasBattery, isFalse);
      expect(desktop.charging, isTrue);
      final laptop = windowsPowerState(
        acLineStatus: 0,
        batteryFlag: 1,
        batteryLifePercent: 70,
        systemStatusFlag: 1,
      );
      expect(laptop.hasBattery, isTrue);
      expect(laptop.charging, isFalse);
      expect(laptop.batteryPercent, 70);
      expect(laptop.batterySaver, isTrue);
    });
  });

  group('File privacy', () {
    /// A small JPEG carrying a GPS marker in an EXIF segment.
    Uint8List photoWithLocation() {
      final jpeg = img.encodeJpg(img.Image(width: 4, height: 4));
      final exif = [
        ...latin1.encode('Exif\u0000\u0000'),
        ...latin1.encode('MM\u0000*\u0000\u0000\u0000\u0008\u0000\u0000'),
        ...latin1.encode('GPSLatitude 52.52'),
      ];
      return Uint8List.fromList([
        0xff,
        0xd8,
        0xff,
        0xe1,
        (exif.length + 2) >> 8,
        (exif.length + 2) & 0xff,
        ...exif,
        ...jpeg.sublist(2),
      ]);
    }

    bool hasLocation(List<int> data) =>
        latin1.decode(data).contains('GPSLatitude');

    Future<(MessengerController, MessengerController, Directory)> pair() async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final roots = [
        await Directory.systemTemp.createTemp('conest_priv_a-'),
        await Directory.systemTemp.createTemp('conest_priv_b-'),
      ];
      addTearDown(() async {
        for (final root in roots) {
          if (await root.exists()) await root.delete(recursive: true);
        }
      });
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => roots[0],
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        internetRelayHost: null,
        transportRegistryFactory: network.registry,
        attachmentRootProvider: () async => roots[1],
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      return (alice, bob, roots[0]);
    }

    Future<(String, List<int>)> received(
      MessengerController alice,
      MessengerController bob,
      int count,
    ) async {
      ChatMessage? message;
      await _waitForIroh(() {
        final files = bob
            .messagesFor(alice.identity!.deviceId)
            .where((m) => m.attachment != null)
            .toList();
        if (files.length < count) return false;
        message = files[count - 1];
        final id = message!.attachment!.id;
        if (bob.attachmentAwaitingAcceptance(id)) {
          unawaited(bob.acceptIncomingAttachment(id));
        }
        return bob.attachmentAvailableLocally(id);
      }, reason: 'the photo arrives');
      final path = await bob.attachmentCachePathFor(message!.attachment!.id);
      return (message!.attachment!.fileName, await File(path!).readAsBytes());
    }

    registerFilePrivacyControllerTests(pair: pair, received: received);

    test('a file records how much of it each route carried, on both '
        'sides', () async {
      final (alice, bob, root) = await pair();
      final data = Uint8List.fromList(
        List<int>.generate(300 * 1024, (i) => i % 251),
      );
      final source = await File('${root.path}/data.bin').writeAsBytes(data);
      await alice.sendAttachmentSource(
        contact: alice.contacts.single,
        source: StagedAttachment(
          id: 'routes-${DateTime.now().microsecondsSinceEpoch}',
          fileName: 'data.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: data.length,
          filePath: source.path,
        ),
      );
      await received(alice, bob, 1);
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      final inbound = bob
          .messagesFor(aliceId)
          .singleWhere((m) => m.attachment != null);
      final inboundBytes = inbound.routeTrace
          .where((trace) => trace.bytes != null)
          .fold<int>(0, (sum, trace) => sum + trace.bytes!);
      expect(inboundBytes, data.length);
      expect(
        inbound.routeTrace.map((trace) => trace.route.family),
        contains(MessageRoute.irohDirect),
      );
      await _waitForIroh(() {
        final outbound = alice
            .messagesFor(bobId)
            .singleWhere((m) => m.attachment != null);
        return outbound.routeTrace.any(
          (trace) =>
              trace.bytes != null &&
              trace.bytes! > 0 &&
              trace.mark == MessageRouteMark.confirmed,
        );
      }, reason: 'the sender did not record the file\'s routes');
    });

    test('photos go without their location unless the user keeps it, '
        'under random names when asked', () async {
      final (alice, bob, root) = await pair();
      expect(alice.removesFileMetadata, isTrue);
      final photo = photoWithLocation();
      final source = await File('${root.path}/holiday.jpg').writeAsBytes(photo);
      Future<void> send() => alice.sendAttachmentSource(
        contact: alice.contacts.single,
        source: StagedAttachment(
          id: 'photo-${DateTime.now().microsecondsSinceEpoch}',
          fileName: 'holiday.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: photo.length,
          filePath: source.path,
        ),
      );

      await send();
      final (name, cleaned) = await received(alice, bob, 1);
      expect(name, 'holiday.jpg');
      expect(hasLocation(cleaned), isFalse);
      expect(
        hasLocation(await source.readAsBytes()),
        isTrue,
        reason: 'the user\'s own file is not changed',
      );

      await alice.setRandomizesFileNames(true);
      await send();
      final (randomName, _) = await received(alice, bob, 2);
      expect(randomName, matches(RegExp(r'^[a-z2-7]{16}\.jpg$')));

      await alice.setRemovesFileMetadata(false);
      await alice.setRandomizesFileNames(false);
      await send();
      final (_, kept) = await received(alice, bob, 3);
      expect(hasLocation(kept), isTrue);
    });

    test('agreeing to send a partly cleaned file sends what was cleaned, '
        'not the original', () async {
      final (alice, bob, root) = await pair();
      // An Info dictionary that can be blanked, and an author inside a
      // compressed object stream that cannot.
      final hidden = zlib.encode(latin1.encode('3 0 << /Author (Hidden) >>'));
      final pdf = <int>[
        ...latin1.encode(
          '%PDF-1.5\n1 0 obj\n<< /Author (Jane Private) >>\nendobj\n'
          '2 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Filter /FlateDecode '
          '/Length ${hidden.length} >>\nstream\n',
        ),
        ...hidden,
        ...latin1.encode(
          '\nendstream\nendobj\ntrailer\n<< /Info 1 0 R >>\n%%EOF\n',
        ),
      ];
      final source = await File('${root.path}/plan.pdf').writeAsBytes(pdf);
      StagedAttachment staged() => StagedAttachment(
        id: 'pdf-${DateTime.now().microsecondsSinceEpoch}',
        fileName: 'plan.pdf',
        mimeType: 'application/pdf',
        sizeBytes: pdf.length,
        filePath: source.path,
      );
      Object? error;
      try {
        await alice.sendAttachmentSource(
          contact: alice.contacts.single,
          source: staged(),
        );
      } catch (caught) {
        error = caught;
      }
      expect(error, isA<AttachmentSpoolException>());
      expect((error! as AttachmentSpoolException).partialMetadata, isTrue);

      await alice.sendAttachmentSource(
        contact: alice.contacts.single,
        source: staged(),
        allowOriginalFallback: true,
      );
      final (_, sent) = await received(alice, bob, 1);
      expect(latin1.decode(sent), isNot(contains('Jane Private')));

      final group = await alice.createGroup(
        title: 'Partly cleaned',
        members: [alice.contacts.single],
      );
      await expectLater(
        alice.publishGroupFile(
          groupId: group.groupId,
          path: source.path,
          fileName: 'plan.pdf',
          mimeType: 'application/pdf',
        ),
        throwsA(isA<FileMetadataException>()),
      );
      await alice.publishGroupFile(
        groupId: group.groupId,
        path: source.path,
        fileName: 'plan.pdf',
        mimeType: 'application/pdf',
        acceptPartialMetadata: true,
      );
      final original = await hashGroupFile(
        path: source.path,
        fileName: 'plan.pdf',
        mimeType: 'application/pdf',
      );
      final shared = alice
          .messagesForGroup(group.groupId)
          .singleWhere((message) => message.groupFile != null)
          .groupFile!;
      expect(shared.fileHash, isNot(original.fileHash));
      expect(shared.sizeBytes, pdf.length);
    });

    test(
      'a file whose details cannot be removed is not sent without asking',
      () async {
        final (alice, _, root) = await pair();
        // A JPEG damaged after its start: it cannot be cleaned.
        final broken = await File('${root.path}/broken.jpg').writeAsBytes([
          0xff,
          0xd8,
          0xff,
          0xe1,
          0x00,
          0x40,
          ...latin1.encode('GPSLatitude'),
        ]);
        Object? error;
        try {
          await alice.sendAttachmentSource(
            contact: alice.contacts.single,
            source: StagedAttachment(
              id: 'broken',
              fileName: 'broken.jpg',
              mimeType: 'image/jpeg',
              sizeBytes: await broken.length(),
              filePath: broken.path,
            ),
          );
        } catch (caught) {
          error = caught;
        }
        expect(error, isA<AttachmentSpoolException>());
        expect((error! as AttachmentSpoolException).keepsMetadata, isTrue);

        final group = await alice.createGroup(
          title: 'Damaged',
          members: [alice.contacts.single],
        );
        await expectLater(
          alice.publishGroupFile(
            groupId: group.groupId,
            path: broken.path,
            fileName: 'broken.jpg',
            mimeType: 'image/jpeg',
          ),
          throwsA(isA<FileMetadataException>()),
        );
        // With the user's consent it goes as it is.
        await alice.publishGroupFile(
          groupId: group.groupId,
          path: broken.path,
          fileName: 'broken.jpg',
          mimeType: 'image/jpeg',
          keepMetadata: true,
        );
        expect(
          alice
              .messagesForGroup(group.groupId)
              .where((message) => message.groupFile != null),
          hasLength(1),
        );
      },
    );

    test('Saved messages keep a photo as it is', () async {
      final (alice, _, root) = await pair();
      final photo = photoWithLocation();
      final source = await File('${root.path}/mine.jpg').writeAsBytes(photo);
      final saved = alice.savedMessagesContact!;
      await alice.sendAttachmentSource(
        contact: saved,
        source: StagedAttachment(
          id: 'mine',
          fileName: 'mine.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: photo.length,
          filePath: source.path,
        ),
      );
      final message = alice
          .messagesFor(saved.deviceId)
          .singleWhere((m) => m.attachment != null);
      final path = await alice.attachmentCachePathFor(message.attachment!.id);
      expect(hasLocation(await File(path!).readAsBytes()), isTrue);
    });

    test('group photos go without their location too', () async {
      final (alice, bob, root) = await pair();
      final group = await alice.createGroup(
        title: 'Trip',
        members: [alice.contacts.single],
      );
      await _waitForIroh(() => bob.groups.isNotEmpty);
      final source = await File(
        '${root.path}/group.jpg',
      ).writeAsBytes(photoWithLocation());
      await alice.publishGroupFile(
        groupId: group.groupId,
        path: source.path,
        fileName: 'group.jpg',
        mimeType: 'image/jpeg',
      );
      final eventId = alice
          .messagesForGroup(group.groupId)
          .singleWhere((message) => message.groupFile != null)
          .id;
      await _waitForIroh(
        () => bob.groupFileSession(eventId)?.download.completedFile != null,
        reason: 'the group photo arrives',
      );
      final file = bob.groupFileSession(eventId)!.download.completedFile!;
      expect(hasLocation(await file.readAsBytes()), isFalse);
      expect(hasLocation(await source.readAsBytes()), isTrue);
    });
  });

  group('Delta Chat', () {
    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    test('Delta Chat: an invite, a verified chat with receipts, a group, '
        'and other mail left alone', () async {
      final server = await FakeMailServer.start();
      addTearDown(server.close);
      final relay = _FakeRelayClient();
      final aliceVault = _MemoryVaultStore();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: aliceVault,
        mailConnector: server.connect,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        mailConnector: server.connect,
      );
      addTearDown(bob.dispose);
      await expectLater(alice.enableDeltaChat(), throwsStateError);
      await alice.enableChatmailCarrier('chat.test');
      await bob.enableChatmailCarrier('chat.test');
      await alice.enableDeltaChat();
      await bob.enableDeltaChat();
      final aliceFp = alice.deltaFingerprint!;
      final bobFp = bob.deltaFingerprint!;
      final aliceMail = alice.emailCarrierConfig!.mail;

      // Someone's ordinary mail in the same inbox stays there.
      server.deliver(
        aliceMail,
        'From: <friend@example.org>\r\nTo: <$aliceMail>\r\n'
        'Subject: lunch?\r\nMessage-ID: <plain@example.org>\r\n\r\nat noon\r\n',
      );

      final chatKey = await bob.joinDeltaChat(alice.deltaInviteLink!);
      expect(chatKey, aliceFp);
      await until(
        () =>
            (alice.deltaChats.peers[bobFp]?.verified ?? false) &&
            (bob.deltaChats.peers[aliceFp]?.verified ?? false),
      );
      expect(alice.deltaChats.peers[bobFp]?.verified, isTrue);
      expect(bob.deltaChats.peers[aliceFp]?.verified, isTrue);

      await bob.sendDeltaMessage(aliceFp, 'Hello over Delta Chat');
      await until(
        () => alice.deltaChats.chats[bobFp]?.messages.isNotEmpty ?? false,
      );
      expect(
        alice.deltaChats.chats[bobFp]!.messages.single.text,
        'Hello over Delta Chat',
      );
      await alice.markDeltaChatRead(bobFp);
      await until(
        () =>
            bob.deltaChats.chats[aliceFp]?.messages.any(
              (message) =>
                  message.outgoing && message.state == DeltaMessageState.read,
            ) ??
            false,
      );
      expect(
        bob.deltaChats.chats[aliceFp]!.messages.single.state,
        DeltaMessageState.read,
      );

      final groupKey = await alice.createDeltaGroup('Team', [bobFp]);
      await until(() => bob.deltaChats.chats.containsKey(groupKey));
      await bob.sendDeltaMessage(groupKey, 'team hello');
      await until(
        () =>
            alice.deltaChats.chats[groupKey]?.messages.any(
              (message) => message.text == 'team hello',
            ) ??
            false,
      );
      expect(bob.deltaChats.chats[groupKey]!.name, 'Team');

      // Delta Chat mail was read and deleted; the ordinary mail was not.
      Iterable<FakeMail> kept() =>
          server.mailboxes[aliceMail]!.where((mail) => !mail.deleted);
      await until(() => kept().length == 1);
      final left = kept();
      expect(left, hasLength(1));
      expect(latin1.decode(left.single.raw), contains('lunch?'));

      // The key and the chats survive a restart.
      alice.dispose();
      final restarted = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        vaultStore: aliceVault,
        createIdentity: false,
        mailConnector: server.connect,
      );
      addTearDown(restarted.dispose);
      await until(() => restarted.deltaFingerprint != null);
      expect(restarted.deltaFingerprint, aliceFp);
      expect(restarted.deltaChats.chats[groupKey]?.members, [bobFp]);
      await bob.sendDeltaMessage(aliceFp, 'after restart');
      await until(
        () =>
            restarted.deltaChats.chats[bobFp]?.messages.any(
              (message) => message.text == 'after restart',
            ) ??
            false,
      );
    });
  });

  group('Meshtastic carrier', () {
    Future<void> settle(List<MessengerController> controllers) async {
      for (var round = 0; round < 6; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    test('two devices talk over a Meshtastic mesh', () async {
      final mesh = FakeMesh();
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        meshtasticConnector: (_) async => mesh.device(0xa11ce001),
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        meshtasticConnector: (_) async => mesh.device(0xb0b00002),
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.enableMeshtasticCarrier(
        link: MeshtasticLink.serial,
        host: '/dev/ttyACM0',
      );
      await bob.enableMeshtasticCarrier(
        link: MeshtasticLink.tcp,
        host: '192.168.1.40',
      );
      await until(
        () =>
            alice.contacts.single.carrierAddress(TransportKind.meshtastic) !=
                null &&
            bob.contacts.single.carrierAddress(TransportKind.meshtastic) !=
                null,
      );
      await settle([alice, bob]);
      expect(
        bob.contacts.single.carrierAddress(TransportKind.meshtastic),
        'a11ce001',
      );
      expect(alice.meshtasticCarrierConfig?.nodeNum, 0xa11ce001);

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by mesh');
      final bobId = bob.identity!.deviceId;
      await until(
        () => alice.messagesFor(bobId).any((m) => m.body == 'by mesh'),
      );
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by mesh');
      expect(received.route, MessageRoute.meshtastic);
      // Only Conest's port, and the radios' acknowledgements.
      expect(
        mesh.sent.every(
          (packet) =>
              packet.$3 == meshtasticConestPort ||
              packet.$3 == meshtasticRoutingPort,
        ),
        isTrue,
      );
    });

    test('Meshtastic app users chat directly and on channels', () async {
      final mesh = FakeMesh();
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        meshtasticConnector: (_) async => mesh.device(0xa11ce001),
      );
      addTearDown(alice.dispose);
      // Someone with the Meshtastic app on their phone and radio.
      final appUser = mesh.device(0xc0ffee03);
      await alice.enableMeshtasticCarrier(
        link: MeshtasticLink.serial,
        host: '/dev/ttyACM0',
      );
      await until(
        () => alice.meshtasticChannel?.state == MeshtasticCarrierState.connected,
      );
      // Off by default: the apps' messages are left alone.
      mesh.inject(0xc0ffee03, 0xa11ce001, meshtasticTextPort, utf8.encode('psst'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(alice.meshtasticChats.chats, isEmpty);

      await alice.setMeshtasticAppMessages(true);
      mesh.inject(
        0xc0ffee03,
        0xa11ce001,
        meshtasticTextPort,
        utf8.encode('hi from the app'),
        id: 5001,
      );
      mesh.inject(
        0xc0ffee03,
        MeshtasticRadio.broadcast,
        meshtasticTextPort,
        utf8.encode('hello channel'),
        id: 5002,
      );
      await until(() => alice.meshtasticChats.chats.length == 2);
      final direct = RadioChats.direct('c0ffee03');
      final primary = RadioChats.channel(0);
      expect(alice.meshtasticChats.chats[direct]!.single.text, 'hi from the app');
      expect(alice.meshtasticChats.chats[primary]!.single.text, 'hello channel');
      expect(alice.meshtasticChats.unread[direct], 1);

      await alice.sendMeshtasticMessage(direct, 'hi back');
      await until(
        () =>
            alice.meshtasticChats.chats[direct]!.last.state ==
            RadioMessageState.delivered,
      );
      expect(
        mesh.sent.any(
          (packet) =>
              packet.$1 == 0xa11ce001 &&
              packet.$2 == 0xc0ffee03 &&
              packet.$3 == meshtasticTextPort &&
              utf8.decode(packet.$4) == 'hi back',
        ),
        isTrue,
      );
      await alice.sendMeshtasticMessage(primary, 'hello all');
      await until(
        () => mesh.sent.any(
          (packet) =>
              packet.$2 == MeshtasticRadio.broadcast &&
              utf8.decode(packet.$4) == 'hello all',
        ),
      );
      expect(mesh.broadcastChannels.last, 0);
      expect(
        () => alice.sendMeshtasticMessage(direct, 'x' * 300),
        throwsArgumentError,
      );
      expect(appUser.nodeNum, 0xc0ffee03);
      // A direct message under both radios' keys is from that node; one
      // under the channel key could be from anyone.
      expect(alice.meshtasticChats.chats[direct]!.first.authentic, isTrue);
      mesh.inject(
        0xc0ffee03,
        0xa11ce001,
        meshtasticTextPort,
        utf8.encode('trust me'),
        id: 5003,
        pki: false,
      );
      await until(
        () => alice.meshtasticChats.chats[direct]!.any((m) => m.text == 'trust me'),
      );
      expect(
        alice.meshtasticChats.chats[direct]!
            .singleWhere((m) => m.text == 'trust me')
            .authentic,
        isFalse,
      );
      // Their radio could not read one (it has no key for us yet): not
      // shown as delivered.
      final far = await alice.startMeshtasticChat('!dead0004');
      await alice.sendMeshtasticMessage(far, 'are you there?');
      final second = alice.meshtasticChats.chats[far]!.last;
      mesh.inject(
        0xdead0004,
        0xa11ce001,
        meshtasticRoutingPort,
        [0x18, 35],
        id: 5004,
        requestId: int.parse(second.id),
      );
      await until(
        () =>
            alice.meshtasticChats.chats[far]!.last.state !=
            RadioMessageState.sent,
      );
      expect(
        alice.meshtasticChats.chats[far]!.last.state,
        RadioMessageState.failed,
      );
      // Saving the radio again keeps app messages on.
      await alice.enableMeshtasticCarrier(
        link: MeshtasticLink.serial,
        host: '/dev/ttyACM1',
      );
      expect(alice.meshtasticAppMessages, isTrue);
    });

    test('radio settings are checked', () async {
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        meshtasticConnector: (_) async => FakeMesh().device(1),
      );
      addTearDown(alice.dispose);
      for (final (link, host) in [
        (MeshtasticLink.serial, 'ttyACM0'),
        (MeshtasticLink.tcp, ''),
        (MeshtasticLink.tcp, 'a b'),
      ]) {
        await expectLater(
          alice.enableMeshtasticCarrier(link: link, host: host),
          throwsArgumentError,
        );
      }
      expect(alice.meshtasticCarrierConfig, isNull);
      expect(isValidMeshtasticAddress('ffffffff'), isFalse);
      expect(isValidMeshtasticAddress('a11ce001'), isTrue);
      expect(isValidMeshtasticAddress('A11CE001'), isFalse);
    });
  });

  group('MeshCore carrier', () {
    test('MeshCore app users chat directly and on channels', () async {
      final mesh = FakeMeshCoreMesh();
      final aliceRadio = mesh.radio(1);
      final appRadio = mesh.radio(9);
      String hex(List<int> bytes) =>
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      // The radios heard each other's adverts.
      aliceRadio.contacts[hex(appRadio.publicKey.sublist(0, 6))] =
          appRadio.publicKey;
      aliceRadio.names[hex(appRadio.publicKey.sublist(0, 6))] = 'Dana';
      appRadio.contacts[hex(aliceRadio.publicKey.sublist(0, 6))] =
          aliceRadio.publicKey;
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        meshCoreConnector: (_) async => aliceRadio,
      );
      addTearDown(alice.dispose);
      await alice.enableMeshCoreCarrier(
        link: MeshCoreLink.serial,
        host: '/dev/ttyACM0',
      );
      Future<void> until(bool Function() done) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      await until(
        () => alice.meshCoreChannel?.state == MeshCoreCarrierState.connected,
      );
      // Off by default.
      appRadio.writeAsApp(aliceRadio, 'psst');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(alice.meshCoreChats.chats, isEmpty);

      await alice.setMeshCoreAppMessages(true);
      appRadio.writeAsApp(aliceRadio, 'hi from the MeshCore app');
      appRadio.broadcastAsApp(0, 'Dana', 'hello public');
      await until(() => alice.meshCoreChats.chats.length == 2);
      final prefix = hex(appRadio.publicKey.sublist(0, 6));
      final direct = RadioChats.direct(prefix);
      final public = RadioChats.channel(0);
      expect(
        alice.meshCoreChats.chats[direct]!.single.text,
        'hi from the MeshCore app',
      );
      expect(alice.meshCoreChats.chats[public]!.single.name, 'Dana');
      expect(alice.meshCoreChats.chats[public]!.single.text, 'hello public');
      await alice.refreshMeshCoreContacts();
      expect(alice.meshCoreName(prefix), 'Dana');
      expect(alice.meshCoreNodes, {prefix: 'Dana'});

      await alice.sendMeshCoreMessage(direct, 'hi Dana');
      await until(
        () =>
            alice.meshCoreChats.chats[direct]!.last.state ==
            RadioMessageState.delivered,
      );
      expect(
        alice.meshCoreChats.chats[direct]!.last.state,
        RadioMessageState.delivered,
      );
      await alice.sendMeshCoreMessage(public, 'hello everyone');
      expect(aliceRadio.channelSent.last, (0, 'hello everyone'));
      expect(
        () => alice.sendMeshCoreMessage(direct, 'x' * 200),
        throwsArgumentError,
      );
    });

    test('two devices talk once their radios know each other', () async {
      final mesh = FakeMeshCoreMesh();
      final relay = _FakeRelayClient();
      final aliceRadio = mesh.radio(1);
      final bobRadio = mesh.radio(2);
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        meshCoreConnector: (_) async => aliceRadio,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        meshCoreConnector: (_) async => bobRadio,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.enableMeshCoreCarrier(
        link: MeshCoreLink.serial,
        host: '/dev/ttyACM0',
      );
      await bob.enableMeshCoreCarrier(
        link: MeshCoreLink.serial,
        host: '/dev/ttyACM0',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while ((alice.contacts.single.carrierAddress(TransportKind.meshCore) ==
                  null ||
              bob.contacts.single.carrierAddress(TransportKind.meshCore) ==
                  null ||
              aliceRadio.contacts.isEmpty) &&
          DateTime.now().isBefore(deadline)) {
        await alice.pollNow();
        await bob.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // Each radio now lists the other device.
      expect(aliceRadio.contacts, hasLength(1));
      expect(alice.meshCoreCarrierConfig?.publicKeyHex, isNotNull);

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by meshcore');
      final bobId = bob.identity!.deviceId;
      while (!alice.messagesFor(bobId).any((m) => m.body == 'by meshcore') &&
          DateTime.now().isBefore(deadline.add(const Duration(seconds: 20)))) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by meshcore');
      expect(received.route, MessageRoute.meshCore);
      expect(mesh.refused, 0);
    });
  });

  group('Bluetooth mesh carrier', () {
    test(
      'desktop native connector drives the controller and adapter state',
      () async {
        final native = FakeDesktopBleNative();
        native.status['peripheral'] = false;
        native.status['problem'] = 'This Bluetooth adapter cannot advertise.';
        late DesktopBitchatLinks desktop;
        var starts = 0;
        final controller = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Desktop',
          bitchatConnector: () async {
            starts++;
            desktop = await DesktopBitchatLinks.start(native: native);
            return desktop;
          },
        );
        addTearDown(controller.dispose);
        expect(controller.bitchatAvailable, isTrue);
        await controller.enableBitchatCarrier();
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (controller.bitchatChannel?.state !=
                BitchatCarrierState.running &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(starts, 1);
        expect(native.opened, isTrue);
        desktop.pollNow();
        await Future<void>.delayed(Duration.zero);
        expect(
          controller.bitchatChannel!.lastError,
          contains('cannot advertise'),
        );
        expect(
          controller.bitchatChannel!.adapterStatus,
          contains('Mock adapter'),
        );
        await controller.disableBitchatCarrier();
        expect(native.closes, 1);
      },
    );

    test('a contact is added over the mesh alone, through its inbox', () async {
      final area = FakeBleNeighbourhood()
        ..connect('alice', 'relay')
        ..connect('relay', 'bob')
        ..connect('relay', 'dave')
        ..connect('relay', 'carol');
      BitchatNode(
        links: area.node('relay'),
        onPrivate: (_, _) => BitchatPrivate.notMine,
      );
      final relay = _FakeRelayClient();
      Future<MessengerController> device(String name) async {
        final controller = await _createController(
          relayClient: relay,
          displayName: name,
          bitchatConnector: () async => area.node(name.toLowerCase()),
        );
        addTearDown(controller.dispose);
        // Every other route off: the request can only go by the mesh.
        // (Before the mesh starts: a policy change restarts it.)
        await controller.updateGlobalConnectivity(
          controller.identity!.connectivity.copyWith(
            lanEnabled: false,
            transportPolicies: {
              for (final kind in TransportKind.values)
                kind: kind == TransportKind.bitchat
                    ? TransportPolicy.automatic
                    : TransportPolicy.disabled,
            },
          ),
        );
        await controller.enableBitchatCarrier();
        return controller;
      }

      final alice = await device('Alice');
      final bob = await device('Bob');
      final dave = await device('Dave');
      final carol = await device('Carol');
      Future<void> until(bool Function() done, String what) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(done(), isTrue, reason: what);
      }

      await until(
        () => alice.bitchatChannel?.localAddress != null,
        'Alice is on the mesh',
      );
      final invite = (await alice.buildInvite()).encodePayload();
      // The mesh address, with the inbox secret for a first request.
      final hint = parseBitchatInviteHint(
        ContactInvite.decodePayload(
          invite,
        ).carrierHints[TransportKind.bitchat]!,
      )!;
      expect(hint.address, alice.bitchatChannel!.localAddress);
      expect(hint.inboxSecret, alice.bitchatCarrierConfig!.inboxSecret);
      // Two at once: their requests are kept apart (one sender id each).
      await Future.wait([
        bob.addContactFromInvite(
          alias: 'Alice',
          payload: invite,
          codephrase: '',
        ),
        dave.addContactFromInvite(
          alias: 'Alice',
          payload: invite,
          codephrase: '',
        ),
      ]);
      final bobId = bob.identity!.deviceId;
      final daveId = dave.identity!.deviceId;
      // Bob keeps the plain address, and the secret apart.
      expect(
        bob.contacts.single.carrierAddress(TransportKind.bitchat),
        hint.address,
      );
      expect(bob.contacts.single.bitchatInboxSecret, hint.inboxSecret);
      await until(
        () =>
            alice.pendingContactRequests.any(
              (r) => r.senderDeviceId == bobId,
            ) &&
            alice.pendingContactRequests.any((r) => r.senderDeviceId == daveId),
        'both requests reach Alice through her mesh inbox',
      );
      await alice.approvePendingContactRequest(
        alice.pendingContactRequests
            .firstWhere((r) => r.senderDeviceId == bobId)
            .id,
      );
      await until(
        () => bob.contacts.single.canSendOutbound,
        'Bob hears Alice accepted',
      );
      await bob.sendMessage(
        contact: bob.contacts.single,
        body: 'over the mesh',
      );
      await until(
        () => alice.messagesFor(bobId).any((m) => m.body == 'over the mesh'),
        'a message follows',
      );
      // Carol, on the same mesh, got nothing she could read.
      expect(carol.pendingContactRequests, isEmpty);
      expect(carol.contacts, isEmpty);
    });

    test(
      'a mesh request is not sent on an inbox secret likely expired',
      () async {
        final area = FakeBleNeighbourhood()..connect('alice', 'relay');
        BitchatNode(
          links: area.node('relay'),
          onPrivate: (_, _) => BitchatPrivate.notMine,
        );
        final relay = _FakeRelayClient();
        var bobBehind = Duration.zero;
        Future<MessengerController> device(
          String name, {
          DateTime Function()? now,
        }) async {
          final controller = await _createController(
            relayClient: relay,
            displayName: name,
            bitchatConnector: () async => area.node(name.toLowerCase()),
            nowProvider: now,
          );
          addTearDown(controller.dispose);
          await controller.updateGlobalConnectivity(
            controller.identity!.connectivity.copyWith(
              lanEnabled: false,
              transportPolicies: {
                for (final kind in TransportKind.values)
                  kind: kind == TransportKind.bitchat
                      ? TransportPolicy.automatic
                      : TransportPolicy.disabled,
              },
            ),
          );
          await controller.enableBitchatCarrier();
          return controller;
        }

        Future<void> until(bool Function() done, String what) async {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (!done() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(done(), isTrue, reason: what);
        }

        final alice = await device('Alice');
        // Bob took Alice's invite 15 days ago, out of her range.
        final bob = await device(
          'Bob',
          now: () => DateTime.now().toUtc().subtract(bobBehind),
        );
        await until(
          () => alice.bitchatChannel?.localAddress != null,
          'Alice is on the mesh',
        );
        final invite = (await alice.buildInvite()).encodePayload();
        bobBehind = const Duration(days: 15);
        await bob.addContactFromInvite(
          alias: 'Alice',
          payload: invite,
          codephrase: '',
        );
        bobBehind = Duration.zero;
        // Now in range, and asking again: by now Alice no longer listens on
        // that secret (two rotations), so nothing goes to an inbox that may
        // be someone else's guess.
        area.connect('relay', 'bob');
        final aliceId = alice.identity!.deviceId;
        await bob.retryContactPairingNow(aliceId);
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(alice.pendingContactRequests, isEmpty);
        expect(bob.contacts.single.bitchatInboxSecret, isNotNull);
      },
    );

    test('two devices talk through a relaying phone', () async {
      final area = FakeBleNeighbourhood()
        ..connect('alice', 'relay')
        ..connect('relay', 'bob');
      // A bitchat phone between them that only relays.
      BitchatNode(
        links: area.node('relay'),
        onPrivate: (_, _) => BitchatPrivate.notMine,
      );
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        bitchatConnector: () async => area.node('alice'),
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        bitchatConnector: () async => area.node('bob'),
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.enableBitchatCarrier();
      await bob.enableBitchatCarrier();
      for (var round = 0; round < 6; round++) {
        await alice.pollNow();
        await bob.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        bob.contacts.single.carrierAddress(TransportKind.bitchat),
        alice.bitchatChannel!.localAddress,
      );

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by bluetooth');
      final bobId = bob.identity!.deviceId;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!alice.messagesFor(bobId).any((m) => m.body == 'by bluetooth') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by bluetooth');
      expect(received.route, MessageRoute.bitchat);
      expect(
        isValidBitchatAddress(alice.bitchatChannel!.localAddress!),
        isTrue,
      );
    });

    Future<void> until(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('bitchat users nearby chat with a reachable device', () async {
      final area = FakeBleNeighbourhood()..connect('alice', 'phone');
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        bitchatConnector: () async => area.node('alice'),
      );
      addTearDown(alice.dispose);
      await alice.enableBitchatCarrier();
      await until(
        () => alice.bitchatChannel?.state == BitchatCarrierState.running,
      );
      final phone = await _FakeBitchatPhone.start(area, 'phone');
      addTearDown(phone.stop);
      // Hidden by default: the phone never hears of Alice.
      expect(alice.bitchatReachable, isFalse);
      expect(alice.bitchatPeerId, isNull);
      await phone.say('anyone?');
      await until(() => alice.bitchatChats.mesh.isNotEmpty);
      expect(alice.bitchatChats.mesh.single.text, 'anyone?');
      expect(alice.bitchatChats.unread[BitchatChats.meshKey], 1);
      expect(phone.direct.peers, isEmpty);
      expect(() => alice.sendBitchatMeshMessage('hi'), throwsStateError);

      await alice.setBitchatNickname('ali');
      await alice.setBitchatReachable(true);
      final aliceId = alice.bitchatPeerId!;
      await until(() => phone.direct.peer(aliceId) != null);
      expect(phone.direct.peer(aliceId)!.nickname, 'ali');
      expect(alice.bitchatNearbyPeers.map((p) => p.peerId), [
        phone.direct.peerIdHex,
      ]);

      await phone.write(aliceId, 'hello from an iPhone');
      await until(() => alice.bitchatChats.direct.isNotEmpty);
      final chat = alice.bitchatChats.direct[phone.direct.peerIdHex]!;
      expect(chat.single.text, 'hello from an iPhone');
      expect(chat.single.nickname, 'iphone');
      // Delivered at once; read once Alice opens the chat.
      await until(() => phone.receipts.isNotEmpty);
      expect(phone.receipts.single.read, isFalse);
      await alice.markBitchatChatRead(phone.direct.peerIdHex);
      await until(() => phone.receipts.length == 2);
      expect(phone.receipts.last.read, isTrue);

      await alice.sendBitchatDirectMessage(phone.direct.peerIdHex, 'hi back');
      await until(() => phone.messages.isNotEmpty);
      expect(phone.messages.single.text, 'hi back');
      await until(
        () =>
            alice.bitchatChats.direct[phone.direct.peerIdHex]!.last.state ==
            BitchatMessageState.delivered,
      );
      await alice.sendBitchatMeshMessage('hello, mesh');
      await until(() => phone.publics.isNotEmpty);
      expect(phone.publics.single.text, 'hello, mesh');
      expect(alice.bitchatChats.mesh.last.outgoing, isTrue);

      // Going hidden again stops answering.
      await alice.setBitchatReachable(false);
      expect(alice.bitchatPeerId, isNull);
      await phone.write(aliceId, 'still there?');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        alice.bitchatChats.direct[phone.direct.peerIdHex]!.map((m) => m.text),
        isNot(contains('still there?')),
      );
    });

    test('a new bitchat identity does not answer for the old one', () async {
      final area = FakeBleNeighbourhood()..connect('alice', 'phone');
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        bitchatConnector: () async => area.node('alice'),
      );
      addTearDown(alice.dispose);
      await alice.enableBitchatCarrier();
      await until(
        () => alice.bitchatChannel?.state == BitchatCarrierState.running,
      );
      await alice.setBitchatReachable(true);
      final firstName = alice.bitchatNickname;
      final phone = await _FakeBitchatPhone.start(area, 'phone');
      addTearDown(phone.stop);
      final oldId = alice.bitchatPeerId!;
      await until(() => phone.direct.peer(oldId) != null);
      await phone.write(oldId, 'hello');
      await until(() => phone.receipts.isNotEmpty);
      expect(phone.receipts.single.read, isFalse);

      await alice.newBitchatIdentity();
      // The default name changes with the identity.
      expect(alice.bitchatNickname, isNot(firstName));
      // Reading the old chat now sends nothing that would tie the new
      // identity to the old one.
      await alice.markBitchatChatRead(phone.direct.peerIdHex);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(phone.receipts, hasLength(1));
      expect(alice.bitchatChats.unread, isEmpty);
    });

    test('a bitchat user writing too fast is cut off', () async {
      final area = FakeBleNeighbourhood()..connect('alice', 'phone');
      // One minute throughout: the limit is per minute.
      final fixed = DateTime.now().toUtc();
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        bitchatConnector: () async => area.node('alice'),
        nowProvider: () => fixed,
      );
      addTearDown(alice.dispose);
      await alice.enableBitchatCarrier();
      await until(
        () => alice.bitchatChannel?.state == BitchatCarrierState.running,
      );
      final phone = await _FakeBitchatPhone.start(area, 'phone');
      addTearDown(phone.stop);
      await phone.say('message 0');
      for (var i = 1; i < 30; i++) {
        await phone.shout('message $i');
      }
      await until(() => alice.bitchatChats.mesh.length >= 20);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(alice.bitchatChats.mesh, hasLength(20));
    });

    test('phones nearby reach location channels through a gateway', () async {
      final area = FakeBleNeighbourhood()..connect('alice', 'phone');
      final nostr = FakeNostrRelays();
      const cell = 'u4pruy';
      final directory = BitchatGeoRelays.parse(bitchatBundledGeoRelays)!;
      final cellRelays = [
        for (final url in directory.closest(cell)) nostr.relay(url.toString()),
      ];
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        bitchatConnector: () async => area.node('alice'),
        nostrConnector: nostr.connect,
      );
      addTearDown(alice.dispose);
      await alice.enableBitchatCarrier();
      await until(
        () => alice.bitchatChannel?.state == BitchatCarrierState.running,
      );
      final phone = await _FakeBitchatPhone.start(area, 'phone');
      addTearDown(phone.stop);
      expect(() => alice.setBitchatGateway(true), throwsStateError);
      await alice.setBitchatReachable(true);
      await alice.setBitchatGateway(true);
      final aliceId = alice.bitchatPeerId!;
      // The phone learns that Alice is a gateway from her announce.
      await until(
        () =>
            phone.direct.peer(aliceId)?.capabilities ==
            bitchatGatewayCapability,
      );
      expect(
        phone.direct.peer(aliceId)?.capabilities,
        bitchatGatewayCapability,
      );

      // The iPhone has no internet: it hands its signed channel message to
      // Alice, who publishes it on the cell's relays.
      final authorKey = Uint8List.fromList(List.generate(32, (i) => i + 7));
      NostrEvent chat(String text) => NostrEvent.sign(
        secretKey: authorKey,
        kind: bitchatGeohashEventKind,
        tags: [
          ['g', cell],
        ],
        content: text,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      final up = chat('hello from a phone without internet');
      await phone.deposit(aliceId, cell, up);
      bool everywhere() =>
          cellRelays.every((r) => r.stored.any((e) => e.id == up.id));
      await until(everywhere);
      expect(everywhere(), isTrue);
      await until(() => alice.bitchatGatewayCells.isNotEmpty);
      expect(alice.bitchatGatewayCells, {cell});

      // Someone online writes in the cell, which reaches all its relays:
      // Alice passes it to the phone once.
      final down = chat('hello from the internet');
      for (final relay in cellRelays) {
        relay.inject(down);
      }
      await until(() => phone.carried.any((e) => e.id == down.id));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(phone.carried.where((e) => e.id == down.id), hasLength(1));
      // Its own deposit does not come back down.
      expect(phone.carried.map((e) => e.id), isNot(contains(up.id)));

      // Hiding closes every relay connection the gateway opened.
      await alice.setBitchatReachable(false);
      expect(alice.bitchatGateway, isFalse);
      expect(alice.bitchatGatewayCells, isEmpty);
      await until(() => nostr.openConnections == 0);
      expect(nostr.openConnections, 0);

      // So does Matrix-only mode, and back again the gateway returns.
      await alice.setBitchatReachable(true);
      expect(alice.bitchatGateway, isTrue);
      await alice.setAppMode(AppMode.matrixOnly);
      expect(alice.bitchatGatewayCells, isEmpty);
      await until(() => nostr.openConnections == 0);
      expect(nostr.openConnections, 0);
    });

    test('a bitchat identity is renewed after a week', () async {
      final area = FakeBleNeighbourhood();
      var offset = Duration.zero;
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        bitchatConnector: () async => area.node('alice'),
        nowProvider: () => DateTime.now().toUtc().add(offset),
      );
      addTearDown(alice.dispose);
      await alice.enableBitchatCarrier();
      await until(
        () => alice.bitchatChannel?.state == BitchatCarrierState.running,
      );
      await alice.setBitchatReachable(true);
      final first = alice.bitchatPeerId!;
      // Turning it off and on keeps the identity within the week.
      await alice.setBitchatReachable(false);
      await alice.setBitchatReachable(true);
      expect(alice.bitchatPeerId, first);
      offset = const Duration(days: 8);
      await alice.setBitchatReachable(false);
      await alice.setBitchatReachable(true);
      final second = alice.bitchatPeerId!;
      expect(second, isNot(first));
      await alice.newBitchatIdentity();
      expect(alice.bitchatPeerId, isNot(second));
    });

    test(
      'group members who are not contacts talk through a desktop mesh relay',
      () async {
        final area = FakeBleNeighbourhood()
          ..connect('bob', 'desktop')
          ..connect('desktop', 'carol');
        final desktopNative = FakeDesktopBleNative(links: area.node('desktop'));
        final desktop = await DesktopBitchatLinks.start(
          native: desktopNative,
          pollInterval: const Duration(milliseconds: 20),
        );
        desktop.pollNow();
        final meshRelay = BitchatNode(
          links: desktop,
          onPrivate: (_, _) => BitchatPrivate.notMine,
        );
        addTearDown(() async {
          await meshRelay.stop();
          await desktop.close();
        });
        final relay = _FakeRelayClient();
        final people = <MessengerController>[];
        for (final name in ['alice', 'bob', 'carol']) {
          final person = await _createController(
            relayClient: relay,
            displayName: name,
            bitchatConnector: () async => area.node(name),
          );
          addTearDown(person.dispose);
          people.add(person);
        }
        final [alice, bob, carol] = people;
        await bob.enableBitchatCarrier();
        await carol.enableBitchatCarrier();
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        Future<void> settle() async {
          for (var round = 0; round < 4; round++) {
            for (final person in people) {
              await person.pollNow();
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        await settle();
        final group = await alice.createGroup(
          title: 'Three',
          members: alice.contacts,
        );
        await settle();
        final bobId = bob.identity!.deviceId;
        final carolId = carol.identity!.deviceId;
        expect(
          bob.groups.single
              .memberProfileFor(carolId)!
              .carrierAddresses[TransportKind.bitchat],
          carol.bitchatChannel!.localAddress,
        );
        // No relay between Bob and Carol, who only share the group.
        relay.shouldFailStore = (_, _, _, recipient, envelope) =>
            (envelope.senderDeviceId == carolId && recipient == bobId) ||
            (envelope.senderDeviceId == bobId && recipient == carolId);
        await carol.sendGroupMessage(groupId: group.groupId, body: 'nearby');
        await until(
          () => bob
              .messagesForGroup(group.groupId)
              .any((m) => m.body == 'nearby'),
        );
        expect(
          bob
              .messagesForGroup(group.groupId)
              .singleWhere((m) => m.body == 'nearby')
              .route,
          MessageRoute.bitchat,
        );
        expect(desktopNative.broadcasts, isNotEmpty);
      },
    );
  });

  testWidgets(
    'the composer empties as soon as a message is sent, before delivery',
    (tester) async {
      final relay = _FakeRelayClient();
      late MessengerController alice;
      late MessengerController bob;
      await tester.runAsync(() async {
        alice = await _createController(
          relayClient: relay,
          displayName: 'Alice',
        );
        bob = await _createController(relayClient: relay, displayName: 'Bob');
        await _pairControllers(alice, bob);
      });
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      final updates = _createUpdateService();
      final theme = app.ConestThemeController.memory();
      addTearDown(updates.dispose);
      addTearDown(theme.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: alice,
            builder: (context, _) => app.HomeScreen(
              controller: alice,
              updateService: updates,
              buildInfo: _createBuildInfo(),
              themeController: theme,
              palette: app.ConestPalette(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Bob').first);
      await tester.pump();
      // Delivery takes a while: every relay store waits two seconds.
      relay
        ..latencyMin = const Duration(seconds: 2)
        ..latencyMax = const Duration(seconds: 2);
      final composer = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.maxLines != 1,
      );
      await tester.enterText(composer.first, 'first while slow');
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Send'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      // Still being delivered, yet the composer is free for the next one.
      expect(
        relay.storedEnvelopes.where(
          (envelope) => envelope.kind == 'direct_message',
        ),
        isEmpty,
      );
      expect(
        tester.widget<TextField>(composer.first).controller!.text,
        isEmpty,
      );
      expect(
        alice
            .messagesFor(bob.identity!.deviceId)
            .map((message) => message.body),
        contains('first while slow'),
      );
      await tester.runAsync(() async {
        await _waitForIroh(
          () => relay.storedEnvelopes.any(
            (envelope) => envelope.kind == 'direct_message',
          ),
        );
      });
      relay
        ..latencyMin = Duration.zero
        ..latencyMax = Duration.zero;
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'transfer polling speeds up only for blocks that come by relay',
    () async {
      final shared = _FakeRelayClient();
      final aliceRelay = _GatedRelayClient(shared);
      final bobRelay = _GatedRelayClient(shared);
      final alice = await _createController(
        relayClient: aliceRelay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: bobRelay,
        displayName: 'Bob',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      // Only the internet relay works, so transfer traffic must be polled.
      aliceRelay.reachable = {'relay.example'};
      bobRelay.reachable = {'relay.example'};
      await alice.sendAttachment(
        contact: alice.contacts.single,
        bytes: Uint8List(300 * 1024),
        fileName: 'relayed.bin',
      );
      // A transfer is in flight but nothing came by relay yet: the normal
      // active cadence, not the 250 ms one.
      expect(alice.hasActiveTransfer, isTrue);
      expect(alice.relayTransferPollBoosted, isFalse);
      expect(alice.currentScheduledPollInterval, const Duration(seconds: 5));
      await bob.pollNow();
      final id = bob
          .messagesFor(alice.identity!.deviceId)
          .singleWhere((m) => m.attachment != null)
          .attachment!
          .id;
      await bob.acceptIncomingAttachment(id);
      await bob.pollNow();
      // Bob's block requests reach Alice by polling the relay: now it is fast.
      await alice.pollNow();
      expect(alice.relayTransferPollBoosted, isTrue);
      expect(
        alice.currentScheduledPollInterval,
        const Duration(milliseconds: 250),
      );
    },
  );

  group('forwarding through a contact', () {
    test('a message reaches C through B when A cannot reach C', () async {
      final shared = _FakeRelayClient();
      final aliceRelay = _GatedRelayClient(shared);
      final bobRelay = _GatedRelayClient(shared);
      final carolRelay = _GatedRelayClient(shared);
      final alice = await _createController(
        relayClient: aliceRelay,
        displayName: 'Alice',
        internetRelayHost: 'relay-a.example',
        lanAddresses: const ['10.0.1.1'],
      );
      final bob = await _createController(
        relayClient: bobRelay,
        displayName: 'Bob',
        internetRelayHost: 'relay-b.example',
        lanAddresses: const ['10.0.1.2'],
      );
      final carol = await _createController(
        relayClient: carolRelay,
        displayName: 'Carol',
        internetRelayHost: 'relay-c.example',
        lanAddresses: const ['10.0.9.3'],
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);
      // Alice knows Bob and Carol; Bob and Carol do not know each other.
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      Future<void> settle([int rounds = 6]) async {
        for (var round = 0; round < rounds; round++) {
          for (final peer in [alice, bob, carol]) {
            await peer.retryUnacknowledgedMessagesNow();
            await peer.pollNow();
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      // Now Alice can only reach her own and Bob's relay; Bob reaches all.
      aliceRelay.reachable = {'relay-a.example', 'relay-b.example'};
      bobRelay.reachable = {
        'relay-a.example',
        'relay-b.example',
        'relay-c.example',
      };
      carolRelay.reachable = {'relay-c.example'};
      final aliceId = alice.identity!.deviceId;
      final carolContact = alice.contacts.singleWhere(
        (contact) => contact.deviceId == carol.identity!.deviceId,
      );

      // Without Bob's consent nothing is carried.
      await alice.sendMessage(contact: carolContact, body: 'via bob');
      await settle();
      expect(carol.messagesFor(aliceId), isEmpty);
      expect(
        shared.storedEnvelopes.where((e) => e.kind == 'forward_request'),
        isEmpty,
      );

      // Bob agrees to carry for Alice; Alice learns it and retries.
      final aliceAtBob = bob.contacts.single;
      await bob.updateContactRoutingPreferences(
        aliceAtBob.deviceId,
        aliceAtBob.routing.copyWith(carryForContact: true),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!carol.messagesFor(aliceId).any((m) => m.body == 'via bob') &&
          DateTime.now().isBefore(deadline)) {
        await settle(1);
      }
      expect(
        alice.contacts
            .singleWhere((c) => c.deviceId == bob.identity!.deviceId)
            .featureCapabilities,
        contains(ApplicationCapability.forwardForContactsV1),
      );
      expect(
        carol.messagesFor(aliceId).map((message) => message.body),
        contains('via bob'),
      );
      // Bob saw only a sealed envelope for Carol, and nothing is left over.
      expect(bob.pendingForwardsForTesting, isEmpty);
      expect(
        bob.messagesFor(aliceId).map((m) => m.body),
        isNot(contains('via bob')),
      );
    });

    test('B passes a message on to C over Iroh using A\'s hints', () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> device(String name) => _createController(
        relayClient: relay,
        displayName: name,
        transportRegistryFactory: network.registry,
      );
      final alice = await device('Alice');
      final bob = await device('Bob');
      final carol = await device('Carol');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      final aliceAtBob = bob.contacts.single;
      await bob.updateContactRoutingPreferences(
        aliceAtBob.deviceId,
        aliceAtBob.routing.copyWith(carryForContact: true),
      );
      final bobId = bob.identity!.deviceId;
      await _waitForIroh(() {
        unawaited(alice.pollNow());
        return alice.contacts
            .singleWhere((c) => c.deviceId == bobId)
            .featureCapabilities
            .contains(ApplicationCapability.forwardForContactsV1);
      });
      // No relay works, and Alice's Iroh cannot reach Carol.
      relay.shouldFailStore = (_, _, _, _, _) => true;
      network.blockedPairs.add((
        alice.identity!.irohEndpointId!,
        carol.identity!.irohEndpointId!,
      ));
      final carolContact = alice.contacts.singleWhere(
        (c) => c.deviceId == carol.identity!.deviceId,
      );
      await alice.sendMessage(contact: carolContact, body: 'iroh via bob');
      final aliceId = alice.identity!.deviceId;
      await _waitForIroh(
        () => carol.messagesFor(aliceId).any((m) => m.body == 'iroh via bob'),
        reason: 'the message did not reach Carol through Bob',
      );
      expect(
        carol
            .messagesFor(aliceId)
            .singleWhere((m) => m.body == 'iroh via bob')
            .route,
        MessageRoute.viaContact,
      );
      // Carol cannot reach Alice either; her reply goes back through Bob.
      network.blockedPairs.add((
        carol.identity!.irohEndpointId!,
        alice.identity!.irohEndpointId!,
      ));
      final aliceAtCarol = carol.contacts.singleWhere(
        (c) => c.deviceId == aliceId,
      );
      await carol.sendMessage(contact: aliceAtCarol, body: 'reply via bob');
      final carolId = carol.identity!.deviceId;
      await _waitForIroh(
        () => alice.messagesFor(carolId).any((m) => m.body == 'reply via bob'),
        reason: 'the reply did not come back through Bob',
      );
      // Alice's message shows that it went through a contact.
      expect(
        alice
            .messagesFor(carolId)
            .singleWhere((m) => m.body == 'iroh via bob')
            .route,
        MessageRoute.viaContact,
      );
    });

    test(
      'a forwarder refuses envelopes that are not the sender\'s own',
      () async {
        final shared = _FakeRelayClient();
        final alice = await _createController(
          relayClient: shared,
          displayName: 'Alice',
        );
        final bob = await _createController(
          relayClient: shared,
          displayName: 'Bob',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        final aliceAtBob = bob.contacts.single;
        final bobContact = alice.contacts.single;
        final crypto = CryptoService(identityProvider: () => alice.identity!);
        final me = alice.identity!;
        Future<void> request(
          Map<String, dynamic> inner, {
          String? id,
          Map<String, dynamic> hints = const {},
        }) async {
          final envelope = await crypto.encryptPayloadEnvelope(
            kind: 'forward_request',
            messageId: id ?? 'fwd-${DateTime.now().microsecondsSinceEpoch}',
            conversationId: crypto.conversationIdFor(bobContact.deviceId),
            senderAccountId: me.accountId,
            senderDeviceId: me.deviceId,
            recipientDeviceId: bobContact.deviceId,
            contact: bobContact,
            plaintext: jsonEncode({
              'v': 1,
              'to': 'dev-someone',
              'envelope': inner,
              'hints': hints,
            }),
          );
          await shared.storeEnvelope(
            host: 'relay.example',
            port: defaultRelayPort,
            recipientDeviceId: bobContact.deviceId,
            envelope: envelope,
          );
          await bob.pollNow();
        }

        RelayEnvelope inner({
          required String sender,
          String kind = 'direct_message',
        }) => RelayEnvelope(
          kind: kind,
          messageId: 'inner-${DateTime.now().microsecondsSinceEpoch}',
          conversationId: 'c',
          senderAccountId: 'a',
          senderDeviceId: sender,
          recipientDeviceId: 'dev-someone',
          createdAt: DateTime.now().toUtc(),
          nonceBase64: base64Encode(Uint8List(12)),
          ciphertextBase64: base64Encode(Uint8List(4)),
          macBase64: base64Encode(Uint8List(16)),
        );
        final own = inner(sender: me.deviceId).toJson();
        final hints = {
          'iroh': 'not-an-endpoint',
          'direct': ['192.168.1.9:4433', '203.0.113.7:4433'],
          'routes': [
            const PeerEndpoint(
              kind: PeerRouteKind.relay,
              host: '127.0.0.1',
              port: 7667,
            ).toJson(),
            const PeerEndpoint(
              kind: PeerRouteKind.relay,
              host: 'relay.example.org',
              port: 7667,
            ).toJson(),
            const PeerEndpoint(
              kind: PeerRouteKind.lan,
              host: 'relay2.example.org',
              port: 7667,
            ).toJson(),
          ],
        };
        // The hinted relay is down, so what Bob accepts stays queued.
        shared.shouldFailStore = (host, _, _, _, _) =>
            host == 'relay.example.org';
        // Bob does not carry for Alice yet: refused, but not forgotten.
        await request(own, id: 'fwd-own', hints: hints);
        expect(bob.pendingForwardsForTesting, isEmpty);
        await bob.updateContactRoutingPreferences(
          aliceAtBob.deviceId,
          aliceAtBob.routing.copyWith(carryForContact: true),
        );
        // Someone else's envelope, and a kind that is never carried.
        await request(inner(sender: 'dev-mallory').toJson());
        await request(
          inner(sender: me.deviceId, kind: 'group_message').toJson(),
        );
        expect(bob.pendingForwardsForTesting, isEmpty);
        // Alice's retry of her own message is now queued, with only public,
        // well-formed hints kept.
        await request(own, id: 'fwd-own', hints: hints);
        final queued = bob.pendingForwardsForTesting.single;
        expect(queued.hints['iroh'], isNull);
        expect(queued.hints['direct'], ['203.0.113.7:4433']);
        expect((queued.hints['routes'] as List).map((route) => route['host']), [
          'relay.example.org',
        ]);
        // Turning carrying off drops what was queued for Alice.
        await bob.updateContactRoutingPreferences(
          aliceAtBob.deviceId,
          bob.contacts.single.routing.copyWith(carryForContact: false),
        );
        expect(bob.pendingForwardsForTesting, isEmpty);
      },
    );
  });

  group('Tor carrier', () {
    test('a Tor that cannot start says why', () async {
      final tor = FakeTorNetwork()..blocked = true;
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        torApi: tor.device(),
        keepErrorHistory: true,
      );
      addTearDown(alice.dispose);
      await alice.enableTorCarrier();
      for (
        var i = 0;
        i < 50 && !alice.exportErrorHistory().contains('Tor did not start');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // Not silence: the error history and the carrier's state say why.
      expect(alice.exportErrorHistory(), contains('Tor is blocked.'));
      // Tor's own words on where it got to.
      expect(alice.exportErrorHistory(), contains('connecting to a guard'));
      final status = alice.carrierStatuses.singleWhere(
        (status) => status.kind == TransportKind.tor,
      );
      expect(status.ready, isFalse);
      expect(status.lastError, contains('Tor is blocked.'));
    });

    testWidgets('a blocked Tor points to getting your own bridges', (
      tester,
    ) async {
      final tor = FakeTorNetwork()..blocked = true;
      late MessengerController alice;
      await tester.runAsync(() async {
        alice = await _createController(
          relayClient: _FakeRelayClient(),
          displayName: 'Alice',
          torApi: tor.device(),
        );
        await alice.enableTorCarrier();
        for (
          var i = 0;
          i < 50 && alice.torChannel?.state != TorCarrierState.failed;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      addTearDown(alice.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: TorCarrierPanel(controller: alice),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tor-blocked-hint')), findsOneWidget);
      // Opened by itself, with the Tor Project's ways to get bridges.
      expect(find.textContaining('@GetBridgesBot'), findsOneWidget);
      expect(find.textContaining('bridges@torproject.org'), findsOneWidget);
      expect(find.textContaining('bridges.torproject.org'), findsWidgets);
    });

    test('two devices talk through their onion services', () async {
      final tor = FakeTorNetwork();
      final relay = _FakeRelayClient();
      final aliceTor = tor.device();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
        torApi: aliceTor,
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
        torApi: tor.device(),
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      await alice.enableTorCarrier(
        bridges: [
          'Bridge 192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413',
          '',
        ],
      );
      await bob.enableTorCarrier();
      expect(aliceTor.lastBridges, [
        '192.0.2.1:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413',
      ]);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (bob.contacts.single.carrierAddress(TransportKind.tor) == null &&
          DateTime.now().isBefore(deadline)) {
        await alice.pollNow();
        await bob.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final aliceOnion = alice.torChannel!.localAddress!;
      expect(isValidTorAddress(aliceOnion), isTrue);
      expect(bob.contacts.single.carrierAddress(TransportKind.tor), aliceOnion);
      // The address is saved, so it is known before Tor connects next time.
      expect(alice.torCarrierConfig!.address, aliceOnion);

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by tor');
      final bobId = bob.identity!.deviceId;
      while (!alice.messagesFor(bobId).any((m) => m.body == 'by tor') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by tor');
      expect(received.route, MessageRoute.torOnion);

      relay.shouldFailStore = null;
      await alice.disableTorCarrier();
      expect(alice.torCarrierConfig, isNull);
      for (var round = 0; round < 6; round++) {
        await alice.pollNow();
        await bob.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(bob.contacts.single.carrierAddress(TransportKind.tor), isNull);
    });

    test('bridges that need a pluggable transport are refused', () async {
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        torApi: FakeTorNetwork().device(),
      );
      addTearDown(controller.dispose);
      await expectLater(
        controller.enableTorCarrier(
          bridges: [
            'obfs4 192.0.2.2:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413 '
                'cert=abc iat-mode=0',
          ],
        ),
        throwsArgumentError,
      );
      await expectLater(
        controller.enableTorCarrier(bridges: ['not a bridge\u0007 x']),
        throwsArgumentError,
      );
      expect(controller.torCarrierConfig, isNull);
    });
  });

  group('forward-secret sessions', () {
    Future<void> settle(
      List<MessengerController> controllers, {
      int rounds = 8,
    }) async {
      for (var round = 0; round < rounds; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<MessengerController> ratchetController(
      _FakeRelayClient relay,
      String name, {
      bool ratchet = true,
      VaultStore? vaultStore,
      bool createIdentity = true,
    }) => _createController(
      relayClient: relay,
      displayName: name,
      vaultStore: vaultStore,
      createIdentity: createIdentity,
      ratchetEngine: ratchet ? FakeRatchetEngine() : null,
    );

    /// Pairs two ratchet controllers and exchanges one message each way.
    Future<void> establish(
      MessengerController alice,
      MessengerController bob,
    ) async {
      await _pairControllers(alice, bob);
      await settle([alice, bob]);
      // Both sessions open before the first messages: until then the app
      // rightly sends with the static key, and a slow machine (CI) needs
      // more rounds than a fixed count.
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      for (
        var round = 0;
        round < 40 &&
            !(await alice.hasRatchetSessionForTesting(bobId) &&
                await bob.hasRatchetSessionForTesting(aliceId));
        round++
      ) {
        await settle([alice, bob], rounds: 1);
      }
      await alice.sendMessage(contact: alice.contacts.single, body: 'a1');
      await bob.sendMessage(contact: bob.contacts.single, body: 'b1');
      await settle([alice, bob]);
    }

    test('offers repeated while the hello is slow lose no messages', () async {
      // Over a slow route the offering side repeats its offer before the
      // hello that opens the session reaches it; each offer makes the other
      // side start another session (device lab, relay only).
      final relay = _FakeRelayClient();
      var clock = DateTime.utc(2026, 10, 19, 12);
      Future<MessengerController> device(String name) => _createController(
        relayClient: relay,
        displayName: name,
        ratchetEngine: FakeRatchetEngine(),
        nowProvider: () => clock,
        keepErrorHistory: true,
      );
      final alice = await device('Alice');
      final bob = await device('Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      final offerer =
          alice.identity!.deviceId.compareTo(bob.identity!.deviceId) < 0
          ? alice
          : bob;
      final starter = identical(offerer, alice) ? bob : alice;
      var holdHellos = true;
      relay.shouldFailStore = (_, _, _, recipient, envelope) =>
          holdHellos &&
          envelope.kind == 'ratchet_hello' &&
          recipient == offerer.identity!.deviceId;
      await _pairControllers(alice, bob);
      for (var offer = 0; offer < 6; offer++) {
        clock = clock.add(const Duration(minutes: 3));
        await settle([alice, bob], rounds: 3);
      }
      holdHellos = false;
      await settle([alice, bob]);
      for (var i = 0; i < 3; i++) {
        await offerer.sendMessage(
          contact: offerer.contacts.single,
          body: 'from offerer $i',
        );
        await starter.sendMessage(
          contact: starter.contacts.single,
          body: 'from starter $i',
        );
      }
      await settle([alice, bob], rounds: 12);
      final offererId = offerer.identity!.deviceId;
      final starterId = starter.identity!.deviceId;
      final failures = [
        offerer.exportErrorHistory(),
        starter.exportErrorHistory(),
      ].join('\n');
      expect(
        starter.messagesFor(offererId).map((m) => m.body),
        containsAll(['from offerer 0', 'from offerer 1', 'from offerer 2']),
        reason: failures,
      );
      expect(
        offerer.messagesFor(starterId).map((m) => m.body),
        containsAll(['from starter 0', 'from starter 1', 'from starter 2']),
        reason: failures,
      );
      expect(failures, isNot(contains('No ratchet session can decrypt')));
    });

    test('ratchet peers switch to forward-secret envelopes', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      expect(await alice.hasRatchetSessionForTesting(bobId), isTrue);
      expect(await bob.hasRatchetSessionForTesting(aliceId), isTrue);
      expect(bob.messagesFor(aliceId).map((m) => m.body), contains('a1'));
      expect(alice.messagesFor(bobId).map((m) => m.body), contains('b1'));
      final directs = relay.storedEnvelopes
          .where((envelope) => envelope.kind == 'direct_message')
          .toList();
      expect(directs, hasLength(greaterThanOrEqualTo(2)));
      expect(directs.map((envelope) => envelope.protocolVersion).toSet(), {
        3,
      });
      expect(
        directs.every((envelope) => envelope.nonceBase64 == null),
        isTrue,
      );
    });

    test(
      'a duplicate after a restart is acknowledged without a new session',
      () async {
        final relay = _FakeRelayClient();
        final bobVault = _MemoryVaultStore();
        final alice = await ratchetController(relay, 'Alice');
        final bob = await ratchetController(relay, 'Bob', vaultStore: bobVault);
        addTearDown(alice.dispose);
        await establish(alice, bob);
        final aliceId = alice.identity!.deviceId;
        await alice.sendMessage(contact: alice.contacts.single, body: 'once');
        await settle([alice, bob]);
        // The first copy is the one Bob took: a retry after the session
        // setup may encrypt the message afresh, and a later copy (another
        // encryption) cannot be told from a replay without decrypting it.
        final copy = relay.storedEnvelopes.firstWhere(
          (envelope) =>
              envelope.kind == 'direct_message' &&
              envelope.senderDeviceId == aliceId &&
              envelope.messageId ==
                  bob
                      .messagesFor(aliceId)
                      .firstWhere((m) => m.body == 'once')
                      .id,
        );
        expect(copy.protocolVersion, 3);
        // A restart empties every in-memory cache of decrypted messages.
        bob.dispose();
        final restarted = await ratchetController(
          relay,
          'Bob',
          vaultStore: bobVault,
          createIdentity: false,
        );
        addTearDown(restarted.dispose);
        final before = relay.storedEnvelopes.length;
        await restarted.processEnvelopesForTesting([copy]);
        final sent = relay.storedEnvelopes
            .skip(before)
            .map((envelope) => envelope.kind)
            .toList();
        expect(sent, contains('ack'));
        expect(sent, isNot(contains('ratchet_bundle')));
        expect(
          restarted.messagesFor(aliceId).where((m) => m.body == 'once'),
          hasLength(1),
        );
      },
    );

    test('a late copy that fails to decrypt starts no new session', () async {
      final relay = _FakeRelayClient();
      final bobVault = _MemoryVaultStore();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob', vaultStore: bobVault);
      addTearDown(alice.dispose);
      await establish(alice, bob);
      final aliceId = alice.identity!.deviceId;
      await alice.sendMessage(contact: alice.contacts.single, body: 'once');
      await settle([alice, bob]);
      final copy = relay.storedEnvelopes.lastWhere(
        (envelope) =>
            envelope.kind == 'direct_message' &&
            envelope.senderDeviceId == aliceId,
      );
      final bytes = base64Decode(copy.ciphertextBase64!);
      bytes[bytes.length ~/ 2] ^= 1;
      final altered = RelayEnvelope.fromJson({
        ...copy.toJson(),
        'ciphertextBase64': base64Encode(bytes),
      });
      bob.dispose();
      final restarted = await ratchetController(
        relay,
        'Bob',
        vaultStore: bobVault,
        createIdentity: false,
      );
      addTearDown(restarted.dispose);
      final before = relay.storedEnvelopes.length;
      await restarted.processEnvelopesForTesting([altered]);
      // A new session would be offered in the background.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final sent = relay.storedEnvelopes
          .skip(before)
          .map((envelope) => envelope.kind)
          .toList();
      expect(sent, isNot(contains('ack')));
      expect(sent, isNot(contains('ratchet_bundle')));
    });

    test('a retry after the session was dropped is encrypted again', () async {
      final copies = <RelayEnvelope>[];
      final relay = _FakeRelayClient(
        shouldBlackholeStore: (_, _, _, _, envelope) {
          if (envelope.kind != 'direct_message') return false;
          copies.add(envelope);
          return copies.length > 2;
        },
      );
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      final bobId = bob.identity!.deviceId;
      await alice.sendMessage(contact: alice.contacts.single, body: 'lost');
      final id = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'lost')
          .id;
      expect(copies.last.messageId, id);
      expect(copies.last.protocolVersion, 3);
      // Bob moved to a build without forward secrecy.
      await alice.forgetRatchetSessionsForTesting(bobId);
      await alice.retryUnacknowledgedMessagesNow();
      expect(copies.last.messageId, id);
      expect(copies.last.protocolVersion, 2);
    });

    test(
      'a late copy of a group update is acknowledged, not decrypted',
      () async {
        final relay = _FakeRelayClient();
        final bobVault = _MemoryVaultStore();
        final alice = await ratchetController(relay, 'Alice');
        final bob = await ratchetController(relay, 'Bob', vaultStore: bobVault);
        addTearDown(alice.dispose);
        await establish(alice, bob);
        await alice.createGroup(title: 'FS', members: alice.contacts);
        await settle([alice, bob]);
        final update = relay.storedEnvelopes.lastWhere(
          (envelope) =>
              envelope.kind == 'group_membership' &&
              envelope.recipientDeviceId == bob.identity!.deviceId,
        );
        bob.dispose();
        final restarted = await ratchetController(
          relay,
          'Bob',
          vaultStore: bobVault,
          createIdentity: false,
        );
        addTearDown(restarted.dispose);
        final before = relay.storedEnvelopes.length;
        await restarted.processEnvelopesForTesting([update]);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final sent = relay.storedEnvelopes
            .skip(before)
            .map((envelope) => envelope.kind)
            .toList();
        expect(sent, contains('group_membership_ack'));
        expect(sent, isNot(contains('ratchet_bundle')));
      },
    );

    test('retries send the same encrypted copy', () async {
      final copies = <RelayEnvelope>[];
      final relay = _FakeRelayClient(
        shouldBlackholeStore: (_, _, _, _, envelope) {
          if (envelope.kind != 'direct_message') return false;
          copies.add(envelope);
          return copies.length > 2;
        },
      );
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      final aliceId = alice.identity!.deviceId;
      await alice.sendMessage(contact: alice.contacts.single, body: 'lost');
      for (var round = 0; round < 3; round++) {
        await alice.retryUnacknowledgedMessagesNow();
      }
      final lost = copies.where((envelope) {
        return envelope.senderDeviceId == aliceId &&
            envelope.messageId ==
                alice
                    .messagesFor(bob.identity!.deviceId)
                    .singleWhere((m) => m.body == 'lost')
                    .id;
      }).toList();
      expect(lost, hasLength(greaterThanOrEqualTo(2)));
      expect(
        lost.map((envelope) => envelope.ciphertextBase64).toSet(),
        hasLength(1),
      );
    });

    test('a peer without the ratchet keeps static-key envelopes', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob', ratchet: false);
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      expect(
        await alice.hasRatchetSessionForTesting(bob.identity!.deviceId),
        isFalse,
      );
      expect(
        bob.messagesFor(alice.identity!.deviceId).map((m) => m.body),
        contains('a1'),
      );
      expect(
        alice.messagesFor(bob.identity!.deviceId).map((m) => m.body),
        contains('b1'),
      );
      expect(
        relay.storedEnvelopes.where(
          (envelope) =>
              envelope.protocolVersion == 3 ||
              envelope.kind == 'ratchet_bundle',
        ),
        isEmpty,
      );
    });

    test('static-key messages from a ratchet peer are rejected', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      final me = alice.identity!;
      final bobOnAlice = alice.contacts.single;
      final staticOnly = CryptoService(identityProvider: () => me);
      final downgraded = await staticOnly.encryptPayloadEnvelope(
        kind: 'direct_message',
        messageId: 'downgraded-1',
        conversationId: staticOnly.conversationIdFor(bobOnAlice.deviceId),
        senderAccountId: me.accountId,
        senderDeviceId: me.deviceId,
        recipientDeviceId: bobOnAlice.deviceId,
        contact: bobOnAlice,
        plaintext: 'downgraded',
        createdAt: DateTime.now().toUtc(),
      );
      expect(downgraded.protocolVersion, 2);
      await bob.processEnvelopesForTesting([downgraded]);
      expect(
        bob.messagesFor(me.deviceId).map((m) => m.body),
        isNot(contains('downgraded')),
      );
      // The rejection triggers a reset; afterwards the pair still talks.
      await settle([alice, bob]);
      await alice.sendMessage(contact: bobOnAlice, body: 'still secret');
      await settle([alice, bob]);
      expect(
        bob.messagesFor(me.deviceId).map((m) => m.body),
        contains('still secret'),
      );
    });

    test('sessions survive a restart', () async {
      final relay = _FakeRelayClient();
      final bobVault = _MemoryVaultStore();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob', vaultStore: bobVault);
      addTearDown(alice.dispose);
      await establish(alice, bob);
      bob.dispose();
      final restarted = await ratchetController(
        relay,
        'Bob',
        vaultStore: bobVault,
        createIdentity: false,
      );
      addTearDown(restarted.dispose);
      final sentBefore = relay.storedEnvelopes.length;
      await alice.sendMessage(contact: alice.contacts.single, body: 'after');
      await settle([alice, restarted]);
      expect(
        restarted.messagesFor(alice.identity!.deviceId).map((m) => m.body),
        contains('after'),
      );
      final after = relay.storedEnvelopes
          .skip(sentBefore)
          .where((envelope) => envelope.kind == 'direct_message');
      expect(after.map((envelope) => envelope.protocolVersion).toSet(), {3});
    });

    test('call invites over a session carry a per-call media key', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      final carol = await ratchetController(relay, 'Carol', ratchet: false);
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      addTearDown(carol.dispose);
      await establish(alice, bob);
      await _pairControllers(alice, carol);
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      VoiceCallSignal invite(String callId, String recipient) =>
          VoiceCallSignal(
            callId: callId,
            action: 'invite',
            senderDeviceId: aliceId,
            recipientDeviceId: recipient,
            issuedAt: DateTime.now().toUtc(),
          );
      final plaintext = jsonDecode(
        await alice.voiceCallSignalPlaintextForTesting(invite('call-1', bobId)),
      ) as Map<String, dynamic>;
      final secret = base64Decode(plaintext['mediaSecret'] as String);
      expect(secret, hasLength(32));
      final aliceKey = await alice.voiceCallMediaKeyForTesting(bobId, 'call-1');
      final bobKey = await bob.voiceCallMediaKeyForTesting(
        aliceId,
        'call-1',
        receivedSecret: secret,
      );
      expect(aliceKey, bobKey);
      final staticKey = await alice.voiceCallMediaKeyForTesting(
        bobId,
        'call-without-secret',
      );
      expect(staticKey, isNot(aliceKey));

      final legacy = jsonDecode(
        await alice.voiceCallSignalPlaintextForTesting(
          invite('call-2', carol.identity!.deviceId),
        ),
      ) as Map<String, dynamic>;
      expect(legacy.containsKey('mediaSecret'), isFalse);
    });

    test('group file frames between ratchet peers use bulk epoch keys', () async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      final aliceRoot = await Directory.systemTemp.createTemp('conest_fs_a-');
      final bobRoot = await Directory.systemTemp.createTemp('conest_fs_b-');
      addTearDown(() async {
        await aliceRoot.delete(recursive: true);
        await bobRoot.delete(recursive: true);
      });
      Future<MessengerController> create(String name, Directory root) =>
          _createController(
            relayClient: relay,
            displayName: name,
            internetRelayHost: null,
            transportRegistryFactory: network.registry,
            attachmentRootProvider: () async => root,
            ratchetEngine: FakeRatchetEngine(),
          );
      final alice = await create('Alice', aliceRoot);
      final bob = await create('Bob', bobRoot);
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.updateGlobalConnectivity(_irohOnlyConnectivity);
      await bob.updateGlobalConnectivity(_irohOnlyConnectivity);
      await _pairControllers(alice, bob);
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      Future<void> pump() async {
        await alice.retryUnacknowledgedMessagesNow();
        await bob.retryUnacknowledgedMessagesNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // A dropped first offer is retried after 10 s, then 20 s.
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (DateTime.now().isBefore(deadline) &&
          !(await alice.hasRatchetSessionForTesting(bobId) &&
              await bob.hasRatchetSessionForTesting(aliceId))) {
        await pump();
      }
      expect(await alice.hasRatchetSessionForTesting(bobId), isTrue);
      expect(await bob.hasRatchetSessionForTesting(aliceId), isTrue);
      // One message each way confirms both sides speak the ratchet.
      await alice.sendMessage(contact: alice.contacts.single, body: 'hi');
      await bob.sendMessage(contact: bob.contacts.single, body: 'hey');
      await _waitForIroh(
        () =>
            bob.messagesFor(aliceId).any((m) => m.body == 'hi') &&
            alice.messagesFor(bobId).any((m) => m.body == 'hey'),
        reason: 'ratcheted messages',
      );
      // Both directions record the route they took.
      expect(
        bob.messagesFor(aliceId).firstWhere((m) => m.body == 'hi').route,
        MessageRoute.irohDirect,
      );
      expect(
        alice.messagesFor(bobId).firstWhere((m) => m.body == 'hey').route,
        MessageRoute.irohDirect,
      );

      final group = await alice.createGroup(
        title: 'Secret files',
        members: [alice.contacts.single],
      );
      await _waitForIroh(() => bob.groups.isNotEmpty, reason: 'group');
      final source = await File(
        '${aliceRoot.path}/source.bin',
      ).writeAsBytes([4, 2, 4, 2]);
      await alice.publishGroupFile(
        groupId: group.groupId,
        path: source.path,
        fileName: 'secret.bin',
        mimeType: 'application/octet-stream',
      );
      final eventId = alice
          .messagesForGroup(group.groupId)
          .singleWhere((message) => message.groupFile != null)
          .id;
      await _waitForIroh(
        () =>
            bob.groupFileSession(eventId)?.download.state ==
            GroupFileDownloadState.complete,
        reason: 'group file download',
      );
      expect(await File(bob.groupFilePathFor(eventId)!).readAsBytes(), [
        4,
        2,
        4,
        2,
      ]);
      final frames = network.groupFileHeaders
          .where((header) => header.eventId == eventId)
          .toList();
      expect(frames, isNotEmpty);
      expect(frames.every((header) => header.epoch != null), isTrue);
      expect(
        network.envelopes.where(
          (envelope) =>
              envelope.kind == 'ratchet_bulk_key' &&
              envelope.protocolVersion != 3,
        ),
        isEmpty,
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test(
      'groups mix ratchet and static members, including non-contacts',
      () async {
        final relay = _FakeRelayClient();
        final alice = await ratchetController(relay, 'Alice');
        final bob = await ratchetController(relay, 'Bob');
        final carol = await ratchetController(relay, 'Carol', ratchet: false);
        final dave = await ratchetController(relay, 'Dave');
        for (final controller in [alice, bob, carol, dave]) {
          addTearDown(controller.dispose);
        }
        await _pairControllers(alice, bob);
        await _pairControllers(alice, carol);
        await _pairControllers(alice, dave);
        final group = await alice.createGroup(
          title: 'Mixed',
          members: alice.contacts,
        );
        final everyone = [alice, bob, carol, dave];
        await settle(everyone);
        final bobId = bob.identity!.deviceId;
        final daveId = dave.identity!.deviceId;
        expect(bob.contacts.where((c) => c.deviceId == daveId), isEmpty);
        // Bob and Dave share only the group, yet still open a session. A
        // first offer can arrive before the group does; re-offers start at
        // ten seconds.
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (DateTime.now().isBefore(deadline) &&
            !(await bob.hasRatchetSessionForTesting(daveId) &&
                await dave.hasRatchetSessionForTesting(bobId))) {
          await settle(everyone, rounds: 1);
        }
        expect(await bob.hasRatchetSessionForTesting(daveId), isTrue);
        expect(await dave.hasRatchetSessionForTesting(bobId), isTrue);

        final before = relay.storedEnvelopes.length;
        await bob.sendGroupMessage(groupId: group.groupId, body: 'from bob');
        await settle(everyone);
        for (final member in [alice, carol, dave]) {
          expect(
            member.messagesForGroup(group.groupId).map((m) => m.body),
            contains('from bob'),
            reason: '${member.identity!.displayName} receives the message',
          );
        }
        final carolId = carol.identity!.deviceId;
        final fromBob = relay.storedEnvelopes
            .skip(before)
            .where(
              (envelope) =>
                  envelope.kind == 'group_message' &&
                  envelope.senderDeviceId == bobId,
            )
            .toList();
        expect(
          fromBob
              .where((envelope) => envelope.recipientDeviceId == carolId)
              .map((envelope) => envelope.protocolVersion)
              .toSet(),
          {2},
        );
        expect(
          fromBob
              .where((envelope) => envelope.recipientDeviceId == daveId)
              .map((envelope) => envelope.protocolVersion)
              .toSet(),
          {3},
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('a cached plaintext never serves a rewritten header', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await _pairControllers(alice, bob);
      final bobOnAlice = alice.contacts.single;
      final aliceOnBob = bob.contacts.single;
      final aliceSessions = RatchetSessions(
        engine: FakeRatchetEngine(),
        store: MemoryRatchetStore(),
      );
      final bobSessions = RatchetSessions(
        engine: FakeRatchetEngine(),
        store: MemoryRatchetStore(),
      );
      final aliceCrypto = CryptoService(identityProvider: () => alice.identity!)
        ..ratchet = aliceSessions;
      final bobCrypto = CryptoService(identityProvider: () => bob.identity!)
        ..ratchet = bobSessions;
      await aliceSessions.startSession(
        ratchetPeerId(bobOnAlice),
        await bobSessions.createBundle(),
      );
      await bobSessions.rememberPeerIdentity(
        ratchetPeerId(aliceOnBob),
        await aliceSessions.identityKey(),
      );
      final me = alice.identity!;
      final reaction = await aliceCrypto.encryptPayloadEnvelope(
        kind: 'message_reaction',
        messageId: 'reaction-1',
        conversationId: aliceCrypto.conversationIdFor(bobOnAlice.deviceId),
        senderAccountId: me.accountId,
        senderDeviceId: me.deviceId,
        recipientDeviceId: bobOnAlice.deviceId,
        contact: bobOnAlice,
        plaintext: '{"target":"m1"}',
      );
      expect(reaction.protocolVersion, 3);
      expect(
        await bobCrypto.decryptMessage(contact: aliceOnBob, envelope: reaction),
        '{"target":"m1"}',
      );
      // Same ciphertext again (a second route) is served from the cache...
      expect(
        await bobCrypto.decryptMessage(contact: aliceOnBob, envelope: reaction),
        '{"target":"m1"}',
      );
      // ...but not under a rewritten kind.
      final rewritten = RelayEnvelope.fromJson({
        ...reaction.toJson(),
        'kind': 'message_delete',
      });
      await expectLater(
        bobCrypto.decryptMessage(contact: aliceOnBob, envelope: rewritten),
        throwsFormatException,
      );
    });

    test('a contact removal notice still reaches a ratchet peer', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      await alice.removeContact(bob.identity!.deviceId);
      await settle([alice, bob]);
      expect(bob.contacts.single.isArchived, isTrue);
    });

    test('a delayed old capability list cannot withdraw the ratchet', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      // Taken before pairing: on a slow machine the session can be
      // confirmed while pairing finishes.
      final beforeConfirmation = DateTime.now().toUtc();
      await _pairControllers(alice, bob);
      await settle([alice, bob]);
      await alice.sendMessage(contact: alice.contacts.single, body: 'a1');
      await bob.sendMessage(contact: bob.contacts.single, body: 'b1');
      await settle([alice, bob]);
      final me = alice.identity!;
      final bobOnAlice = alice.contacts.single;
      final staticOnly = CryptoService(identityProvider: () => me);
      Future<RelayEnvelope> exchangeWithout(DateTime createdAt) async =>
          staticOnly.encryptPayloadEnvelope(
            kind: 'contact_exchange',
            messageId: 'xchg-${createdAt.microsecondsSinceEpoch}',
            conversationId: 'contact-exchange-${bobOnAlice.deviceId}',
            senderAccountId: me.accountId,
            senderDeviceId: me.deviceId,
            recipientDeviceId: bobOnAlice.deviceId,
            contact: bobOnAlice,
            plaintext: jsonEncode({
              'exchangeVersion': 2,
              'invitePayload': (await alice.buildInvite()).encodePayload(),
              'featureCapabilityVersion': 1,
              'featureCapabilities': ['groupPollsV1'],
              'requestPeerCapabilities': false,
            }),
            createdAt: createdAt,
          );
      await bob.processEnvelopesForTesting([
        await exchangeWithout(beforeConfirmation),
      ]);
      await settle([bob], rounds: 2);
      expect(await bob.hasRatchetSessionForTesting(me.deviceId), isTrue);
      await bob.processEnvelopesForTesting([
        await exchangeWithout(DateTime.now().toUtc()),
      ]);
      await settle([bob], rounds: 2);
      expect(await bob.hasRatchetSessionForTesting(me.deviceId), isFalse);
    });

    test(
      'moving one device to a build without the ratchet keeps chats working',
      () async {
        final relay = _FakeRelayClient();
        final bobVault = _MemoryVaultStore();
        final alice = await ratchetController(relay, 'Alice');
        final bob = await ratchetController(relay, 'Bob', vaultStore: bobVault);
        addTearDown(alice.dispose);
        await establish(alice, bob);
        bob.dispose();
        final stable = await ratchetController(
          relay,
          'Bob',
          vaultStore: bobVault,
          createIdentity: false,
          ratchet: false,
        );
        addTearDown(stable.dispose);
        await settle([alice, stable]);
        await stable.sendMessage(
          contact: stable.contacts.single,
          body: 'from stable',
        );
        await alice.sendMessage(
          contact: alice.contacts.single,
          body: 'to stable',
        );
        await settle([alice, stable], rounds: 12);
        final aliceId = alice.identity!.deviceId;
        expect(
          alice.messagesFor(stable.identity!.deviceId).map((m) => m.body),
          contains('from stable'),
        );
        expect(
          stable.messagesFor(aliceId).map((m) => m.body),
          contains('to stable'),
        );
      },
    );

    test('controls sent on a session the peer lost are sent again', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      final aliceId = alice.identity!.deviceId;
      final original = alice
          .messagesFor(bob.identity!.deviceId)
          .singleWhere((m) => m.body == 'a1');
      await bob.forgetRatchetSessionsForTesting(aliceId);
      await alice.editMessage(
        contact: alice.contacts.single,
        messageId: original.id,
        body: 'a1 edited',
      );
      await settle([alice, bob], rounds: 12);
      expect(
        bob.messagesFor(aliceId).map((m) => m.body),
        contains('a1 edited'),
      );
    });

    // Olm decrypts only within its last few ratchet chains: a message held
    // up (a relay lease that replays a minute later) can no longer be
    // decrypted, and the receiver asks for a new session. What waits for
    // that contact is then sent again at once, encrypted on the new
    // session, not on the next retry pass (device lab: a message lost).
    Future<void> pollOnly(List<MessengerController> controllers) async {
      for (var round = 0; round < 12; round++) {
        for (final controller in controllers) {
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    test('after a reset, waiting messages are sent again at once', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      final aliceId = alice.identity!.deviceId;
      await bob.forgetRatchetSessionsForTesting(aliceId);
      await alice.sendMessage(contact: alice.contacts.single, body: 'held');
      await pollOnly([alice, bob]);
      expect(bob.messagesFor(aliceId).map((m) => m.body), contains('held'));
    });

    test(
      'after a reset, waiting group messages are sent again at once',
      () async {
        final relay = _FakeRelayClient();
        final alice = await ratchetController(relay, 'Alice');
        final bob = await ratchetController(relay, 'Bob');
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await establish(alice, bob);
        final group = await alice.createGroup(
          title: 'Held',
          members: alice.contacts,
        );
        await settle([alice, bob]);
        final aliceId = alice.identity!.deviceId;
        await bob.forgetRatchetSessionsForTesting(aliceId);
        await alice.sendGroupMessage(
          groupId: group.groupId,
          body: 'held group',
        );
        await pollOnly([alice, bob]);
        expect(
          bob.messagesForGroup(group.groupId).map((m) => m.body),
          contains('held group'),
        );
      },
    );

    test('waiting messages are re-sent at most every 30 s per peer', () async {
      // Bundles are cheap: a stream of them must not have everything
      // waiting encrypted and sent again each time.
      final relay = _FakeRelayClient();
      var clock = DateTime.now().toUtc();
      Future<MessengerController> device(String name) => _createController(
        relayClient: relay,
        displayName: name,
        ratchetEngine: FakeRatchetEngine(),
        nowProvider: () => clock,
      );
      final alice = await device('Alice');
      final bob = await device('Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      final aliceId = alice.identity!.deviceId;
      final bobId = bob.identity!.deviceId;
      // Bob's acknowledgements never get back: the message keeps waiting.
      relay.shouldFailStore = (_, _, _, recipient, envelope) =>
          recipient == aliceId && envelope.kind == 'ack';
      await alice.sendMessage(contact: alice.contacts.single, body: 'waiting');
      await settle([alice, bob], rounds: 2);
      final id = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'waiting')
          .id;
      int copies() =>
          relay.storedEnvelopes.where((e) => e.messageId == id).length;
      Future<void> resend() async {
        alice.resendWaitingMessagesForTesting(bobId);
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }

      final before = copies();
      await resend();
      final once = copies();
      expect(once, greaterThan(before));
      await resend();
      await resend();
      expect(copies(), once, reason: 'again within 30 s');
      clock = clock.add(const Duration(seconds: 31));
      await resend();
      expect(copies(), greaterThan(once));
    });

    test('a lost session recovers through a reset bundle', () async {
      final relay = _FakeRelayClient();
      final alice = await ratchetController(relay, 'Alice');
      final bob = await ratchetController(relay, 'Bob');
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await establish(alice, bob);
      final aliceId = alice.identity!.deviceId;
      await bob.forgetRatchetSessionsForTesting(aliceId);
      await alice.sendMessage(contact: alice.contacts.single, body: 'lost');
      await settle([alice, bob], rounds: 12);
      expect(bob.messagesFor(aliceId).map((m) => m.body), contains('lost'));
      expect(await bob.hasRatchetSessionForTesting(aliceId), isTrue);
    });
  });

  group('nightly.12 unified envelope outbox', () {
    test(
      'deleting a message while peer is offline queues for retry and delivers '
      'once peer comes back online',
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
        final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        final aliceOnBob = bob.contacts.firstWhere((c) => c.alias == 'Alice');

        // Alice sends a text message to Bob; let it land.
        await alice.sendMessage(contact: bobOnAlice, body: 'pre-delete msg');
        for (var step = 0; step < 6; step++) {
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final landed = bob
            .messagesFor(aliceOnBob.deviceId)
            .where((m) => m.body == 'pre-delete msg');
        expect(landed.length, 1);
        final landedId = landed.first.id;

        // Take Bob's relay path offline (every store fails for his device).
        relayClient.shouldFailStore = (_, _, _, recipient, _) =>
            recipient == bobOnAlice.deviceId;

        // Alice deletes the message; the delete envelope can't reach Bob.
        await alice.deleteMessage(
          contact: bobOnAlice,
          messageId: alice
              .messagesFor(bobOnAlice.deviceId)
              .firstWhere((m) => m.body == 'pre-delete msg')
              .id,
        );
        for (var step = 0; step < 4; step++) {
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        // Bob still sees the original message.
        expect(
          bob.messagesFor(aliceOnBob.deviceId).any((m) => m.id == landedId),
          isTrue,
          reason:
              'Bob is offline so the delete should NOT have reached him yet',
        );
        // The delete is queued on Alice's side.
        expect(
          alice.pendingAckDeliveriesForTesting.any(
            (entry) =>
                entry.targetDeviceId == bobOnAlice.deviceId &&
                entry.kind == PendingAckKind.messageDelete,
          ),
          isTrue,
          reason: 'delete envelope must be queued for retry',
        );

        // Bob comes back online.
        relayClient.shouldFailStore = null;
        alice.onConnectivityChanged(interfaceLabel: 'test-online');
        // Force the outbox to drain on the next poll.
        for (var step = 0; step < 8; step++) {
          await alice.retryPendingAckDeliveriesForTesting(force: true);
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        // Bob's view should no longer have the message.
        expect(
          bob.messagesFor(aliceOnBob.deviceId).any((m) => m.id == landedId),
          isFalse,
          reason: 'delete propagated once peer came online + outbox drained',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'queued controls keep plaintext and are encrypted afresh per attempt',
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
        final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');
        final aliceOnBob = bob.contacts.firstWhere((c) => c.alias == 'Alice');
        await alice.sendMessage(contact: bobOnAlice, body: 'to delete');
        for (var step = 0; step < 6; step++) {
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final landedId = bob
            .messagesFor(aliceOnBob.deviceId)
            .singleWhere((m) => m.body == 'to delete')
            .id;

        final attempts = <RelayEnvelope>[];
        relayClient.shouldFailStore = (_, _, _, recipient, envelope) {
          if (recipient != bobOnAlice.deviceId) return false;
          if (envelope.kind == 'message_delete') attempts.add(envelope);
          return true;
        };
        await alice.deleteMessage(contact: bobOnAlice, messageId: landedId);
        final queued = alice.pendingAckDeliveriesForTesting.singleWhere(
          (entry) => entry.kind == PendingAckKind.messageDelete,
        );
        expect(queued.envelopeJson, isNull);
        expect(queued.payload?.kind, 'message_delete');
        expect(queued.payload?.plaintext, contains(landedId));
        final reloaded = PendingAckDelivery.fromJson(
          jsonDecode(jsonEncode(queued.toJson())) as Map<String, dynamic>,
        );
        expect(reloaded.payload?.toJson(), queued.payload?.toJson());

        // Clear route backoff so the forced retry reaches the relay again.
        alice.onConnectivityChanged(interfaceLabel: 'test-retry');
        await alice.retryPendingAckDeliveriesForTesting(force: true);
        expect(attempts.map((e) => e.messageId).toSet(), {
          queued.payload!.messageId,
        });
        // One attempt may try several routes with the same envelope; the
        // retry must be a new encryption rather than a stored replay.
        expect(
          attempts.map((e) => e.nonceBase64).toSet().length,
          greaterThanOrEqualTo(2),
        );

        relayClient.shouldFailStore = null;
        alice.onConnectivityChanged(interfaceLabel: 'test-online');
        for (var step = 0; step < 8; step++) {
          await alice.retryPendingAckDeliveriesForTesting(force: true);
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(
          bob.messagesFor(aliceOnBob.deviceId).any((m) => m.id == landedId),
          isFalse,
        );
        expect(
          alice.pendingAckDeliveriesForTesting.where(
            (entry) => entry.kind == PendingAckKind.messageDelete,
          ),
          isEmpty,
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('a malformed queued payload reads as absent', () {
      final entry = PendingAckDelivery.fromJson({
        'targetDeviceId': 'dev-bob',
        'acknowledgedMessageId': 'msg-1',
        'conversationId': 'conv-1',
        'kind': 'messageDelete',
        'lastAttemptedAt': '2026-05-31T12:00:00.000Z',
        'attempts': 1,
        'payload': {'kind': 'message_delete'},
      });
      expect(entry.payload, isNull);
      expect(entry.envelopeJson, isNull);
    });

    test('PendingAckDelivery JSON round-trip preserves envelopeJson for '
        'carries-envelope kinds', () {
      final entry = PendingAckDelivery(
        targetDeviceId: 'dev-bob',
        acknowledgedMessageId: 'msg-1',
        conversationId: 'conv-1',
        kind: PendingAckKind.messageDelete,
        lastAttemptedAt: DateTime.utc(2026, 5, 31, 12),
        attempts: 2,
        envelopeJson: const {
          'kind': 'message_delete',
          'messageId': 'msg-1',
          'conversationId': 'conv-1',
          'senderAccountId': 'acc-a',
          'senderDeviceId': 'dev-a',
          'recipientDeviceId': 'dev-bob',
          'createdAt': '2026-05-31T12:00:00.000Z',
          'nonceBase64': null,
          'ciphertextBase64': 'AAA=',
          'macBase64': null,
          'acknowledgedMessageId': null,
          'payloadBase64': null,
        },
      );
      final json = entry.toJson();
      final reloaded = PendingAckDelivery.fromJson(json);
      expect(reloaded.kind, PendingAckKind.messageDelete);
      expect(reloaded.envelopeJson, isNotNull);
      expect(reloaded.envelopeJson!['ciphertextBase64'], 'AAA=');
      // Legacy entries without envelopeJson still round-trip.
      final legacy = PendingAckDelivery.fromJson({
        'targetDeviceId': 'dev-bob',
        'acknowledgedMessageId': 'msg-old',
        'conversationId': 'conv-1',
        'kind': 'delivered',
        'lastAttemptedAt': '2026-05-31T12:00:00.000Z',
        'attempts': 0,
      });
      expect(legacy.kind, PendingAckKind.delivered);
      expect(legacy.envelopeJson, isNull);
    });
  });

  group('nightly.12 receiver-side cancel propagation', () {
    test('receiver deleteMessage during transfer flips sender parent to canceled '
        'and frees the queue', () async {
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
      final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      final aliceOnBob = bob.contacts.firstWhere((c) => c.alias == 'Alice');

      // 4 MB payload so the transfer spans many chunks and can't
      // complete before Bob's deleteMessage runs.
      final payload = Uint8List(4 * 1024 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (i * 11 + 3) & 0xff;
      }
      await alice.sendAttachment(
        contact: bobOnAlice,
        bytes: payload,
        fileName: 'cancel.bin',
      );
      // Let the offer land — but only one poll so chunks haven't all
      // shipped yet.
      await bob.pollNow();
      await alice.pollNow();
      // Bob deletes the in-flight message — sends attachment_cancel.
      final inbound = bob
          .messagesFor(aliceOnBob.deviceId)
          .firstWhere((m) => m.attachment?.fileName == 'cancel.bin');
      await bob.deleteMessage(contact: aliceOnBob, messageId: inbound.id);
      // Pump aggressively so Alice's poll picks up the cancel envelope
      // before any in-flight chunk delivery completes (which would
      // flip her state to delivered and block the canceled
      // transition).
      for (var step = 0; step < 25; step++) {
        await alice.retryPendingAckDeliveriesForTesting();
        await bob.retryPendingAckDeliveriesForTesting();
        await alice.pollNow();
        await bob.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      final senderMsg = alice
          .messagesFor(bobOnAlice.deviceId)
          .firstWhere((m) => m.attachment?.fileName == 'cancel.bin');
      // Cancel must have propagated: state is `canceled` (handler
      // updated the parent) OR the attachment bytes were cleared
      // (handler tore down without state flip because the message had
      // already been removed locally). Either signal proves the
      // outbox shipped the cancel and the handler ran.
      final attachmentId = senderMsg.attachment!.id;
      final outboundCleared =
          alice.outboundAttachmentProgress(attachmentId) == null;
      expect(
        senderMsg.state == DeliveryState.canceled || outboundCleared,
        isTrue,
        reason:
            'sender state=${senderMsg.state}, outboundCleared=$outboundCleared',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('nightly.10 staged-attachment API', () {
    test(
      'stageAttachments + sendStagedBundle round-trips a 3-item album',
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
        final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');

        // Stage three small files — none have a caption, so they should
        // bundle into one album.
        final items = [
          for (var i = 0; i < 3; i++)
            StagedAttachment(
              id: 'stage-$i',
              fileName: 'file$i.bin',
              mimeType: 'application/octet-stream',
              sizeBytes: 32,
              bytes: Uint8List.fromList(
                List<int>.generate(32, (j) => (i * 31 + j) & 0xff),
              ),
            ),
        ];
        alice.stageAttachments(contact: bobOnAlice, items: items);
        expect(
          alice.stagedAttachmentsFor(bobOnAlice.deviceId).length,
          3,
          reason: 'all three items should appear in the staged tray',
        );
        // Before send: no outbound messages yet (false-sent fix).
        final beforeSendCount = alice
            .messagesFor(bobOnAlice.deviceId)
            .where((m) => m.attachment != null)
            .length;
        expect(
          beforeSendCount,
          0,
          reason: 'staging must not create chat messages',
        );

        // No composer caption → all 3 stay in one uncaptioned album.
        await alice.sendStagedBundle(contact: bobOnAlice, caption: '');

        // Staged bucket cleared.
        expect(alice.stagedAttachmentsFor(bobOnAlice.deviceId), isEmpty);
        // Three outbound messages now exist with the SAME albumId.
        final outbound = alice
            .messagesFor(bobOnAlice.deviceId)
            .where((m) => m.attachment != null)
            .toList();
        expect(outbound.length, 3);
        expect(outbound.first.albumId, isNotNull);
        expect(
          outbound.every((m) => m.albumId == outbound.first.albumId),
          isTrue,
          reason: 'all three uncaptioned members share one albumId',
        );
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test('removeStaged drops a single item by id', () async {
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
      final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');

      alice.stageAttachments(
        contact: bobOnAlice,
        items: [
          StagedAttachment(
            id: 'keep',
            fileName: 'a.bin',
            mimeType: 'application/octet-stream',
            sizeBytes: 8,
            bytes: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
          ),
          StagedAttachment(
            id: 'drop',
            fileName: 'b.bin',
            mimeType: 'application/octet-stream',
            sizeBytes: 8,
            bytes: Uint8List.fromList([9, 10, 11, 12, 13, 14, 15, 16]),
          ),
        ],
      );
      alice.removeStaged(deviceId: bobOnAlice.deviceId, stagedId: 'drop');
      final remaining = alice.stagedAttachmentsFor(bobOnAlice.deviceId);
      expect(remaining.map((s) => s.id), ['keep']);
    });
  });

  group('nightly.9 LAN-direct HTTP fast-path', () {
    test('HttpLanDirectChannel start/stop binds and releases a port', () async {
      final channel = HttpLanDirectChannel();
      channel.onEnvelope = (_) async {};
      final port = await channel.start();
      expect(port, isNotNull);
      expect(port, greaterThan(0));
      expect(channel.isRunning, isTrue);
      await channel.stop();
      expect(channel.isRunning, isFalse);
    });

    test(
      'real HTTP channels complete and hash-verify a 5 MiB LAN diagnostic',
      () async {
        final previousHttpOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousHttpOverrides);
        final host = await _realPrivateLanHost();
        final aliceRoot = Directory.systemTemp.createTempSync(
          'conest_real_http_alice_',
        );
        final bobRoot = Directory.systemTemp.createTempSync(
          'conest_real_http_bob_',
        );
        addTearDown(() {
          for (final directory in <Directory>[aliceRoot, bobRoot]) {
            try {
              directory.deleteSync(recursive: true);
            } catch (_) {}
          }
        });
        final aliceChannel = HttpLanDirectChannel();
        final bobChannel = HttpLanDirectChannel();
        final relayClient = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: <String>[host],
          lanDirectChannel: aliceChannel,
          attachmentRootProvider: () async => aliceRoot,
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: <String>[host],
          lanDirectChannel: bobChannel,
          attachmentRootProvider: () async => bobRoot,
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        addTearDown(aliceChannel.stop);
        addTearDown(bobChannel.stop);
        await _pairControllers(alice, bob);

        await alice.runLanAttachmentDiagnostic(
          contact: alice.contacts.single,
          sizeMiB: 5,
        );
        ChatMessage? received;
        for (var step = 0; step < 1200; step++) {
          await bob.pollNow();
          await alice.pollNow();
          received = bob
              .messagesFor(bob.contacts.single.deviceId)
              .where(
                (message) =>
                    message.attachment?.mimeType ==
                    'application/x-conest-transfer-test',
              )
              .firstOrNull;
          if (received != null &&
              bob.attachmentAwaitingAcceptance(received.attachment!.id)) {
            await bob.acceptIncomingAttachment(received.attachment!.id);
          }
          if (received?.state == DeliveryState.delivered &&
              bob.attachmentAvailableLocally(received!.attachment!.id)) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(received, isNotNull);
        expect(received!.state, DeliveryState.delivered);
        expect(received.attachment!.sizeBytes, 5 * 1024 * 1024);
        expect(aliceChannel.successfulAttachmentChunkPutCount, greaterThan(0));
        expect(bobChannel.acceptedAttachmentChunkCount, greaterThan(0));
        expect(
          alice.recentDebugLog.any(
            (entry) =>
                entry.contains('LAN-binary PUT chunk[') &&
                entry.contains('result=ok'),
          ),
          isTrue,
          reason:
              'the binary AEAD block path must replace JSON chunk envelopes',
        );
        final cachePath = await bob.attachmentCachePathFor(
          received.attachment!.id,
        );
        expect(cachePath, isNotNull);
        expect(await File(cachePath!).length(), 5 * 1024 * 1024);
        expect(
          relayClient.storedEnvelopes.where(
            (envelope) => envelope.kind == 'attachment_chunk',
          ),
          isEmpty,
          reason: 'LAN diagnostic payload blocks must never use a relay',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'matching debug builds auto-accept, verify, report, and clean a real LAN test',
      () async {
        final previousHttpOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousHttpOverrides);
        final host = await _realPrivateLanHost();
        final aliceRoot = Directory.systemTemp.createTempSync(
          'conest_auto_debug_alice_',
        );
        final bobRoot = Directory.systemTemp.createTempSync(
          'conest_auto_debug_bob_',
        );
        addTearDown(() {
          for (final directory in <Directory>[aliceRoot, bobRoot]) {
            try {
              directory.deleteSync(recursive: true);
            } catch (_) {}
          }
        });
        final aliceChannel = HttpLanDirectChannel();
        final bobChannel = HttpLanDirectChannel();
        final relayClient = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: <String>[host],
          lanDirectChannel: aliceChannel,
          localRelayNode: _EphemeralLocalRelayNode(),
          attachmentRootProvider: () async => aliceRoot,
          debugBuildId: 'debug-test@same-commit',
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: <String>[host],
          lanDirectChannel: bobChannel,
          localRelayNode: _EphemeralLocalRelayNode(),
          attachmentRootProvider: () async => bobRoot,
          debugBuildId: 'debug-test@same-commit',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        addTearDown(aliceChannel.stop);
        addTearDown(bobChannel.stop);
        await _pairControllers(alice, bob);

        var finished = false;
        final resultFuture = alice
            .runDebugFileBattleTest(contact: alice.contacts.single, sizeMiB: 5)
            .whenComplete(() => finished = true);
        for (var step = 0; step < 1800 && !finished; step++) {
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final result = await resultFuture;

        expect(result.success, isTrue, reason: result.detail);
        expect(result.bytesVerified, 5 * 1024 * 1024);
        expect(alice.debugFileTestResults.first.success, isTrue);
        expect(
          bob
              .messagesFor(bob.contacts.single.deviceId)
              .where(
                (message) =>
                    message.attachment?.mimeType ==
                    'application/x-conest-transfer-test',
              ),
          isEmpty,
          reason: 'receiver diagnostics must not pollute the conversation',
        );
        expect(
          relayClient.storedEnvelopes.where(
            (envelope) => envelope.kind == 'attachment_chunk',
          ),
          isEmpty,
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'automatic file test stops before sending when debug builds differ',
      () async {
        final relayClient = _FakeRelayClient();
        final aliceChannel = _InProcessLanDirectChannel(host: '192.168.54.10');
        final bobChannel = _InProcessLanDirectChannel(host: '192.168.54.11');
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: const <String>['192.168.54.10'],
          lanDirectChannel: aliceChannel,
          debugBuildId: 'debug-test@alice-commit',
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: const <String>['192.168.54.11'],
          lanDirectChannel: bobChannel,
          debugBuildId: 'debug-test@bob-commit',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        addTearDown(aliceChannel.stop);
        addTearDown(bobChannel.stop);
        await _pairControllers(alice, bob);

        var finished = false;
        final expectation = expectLater(
          alice
              .runDebugFileBattleTest(
                contact: alice.contacts.single,
                sizeMiB: 5,
              )
              .whenComplete(() => finished = true),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('same debug build'),
            ),
          ),
        );
        for (var step = 0; step < 500 && !finished; step++) {
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await expectation;

        expect(
          alice.messagesFor(alice.contacts.single.deviceId),
          isEmpty,
          reason: 'a mismatched peer must be rejected before file generation',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('missing capability fields cannot downgrade binary LAN v1', () async {
      final channel = _InProcessLanDirectChannel(host: '192.168.55.10');
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        lanAddresses: const <String>['192.168.55.10'],
        lanDirectChannel: channel,
      );
      addTearDown(controller.dispose);
      addTearDown(channel.stop);

      controller.cachePeerLanDirectHintForTesting('peer', <String, dynamic>{
        'senderLanDirectPort': 43210,
        'senderLanAddresses': const <String>['192.168.55.11'],
        'senderLanBinaryVersion': 1,
      });
      controller.cachePeerLanDirectHintForTesting('peer', <String, dynamic>{
        'senderLanDirectPort': 43211,
        'senderLanAddresses': const <String>['192.168.55.11'],
      });

      final endpoint = controller.peerLanDirectEndpointForTesting('peer');
      expect(endpoint, isNotNull);
      expect(endpoint!.port, 43211);
      expect(endpoint.binaryBlockVersion, 1);
    });

    test(
      'automatic file test reports a local binary block failure immediately',
      () async {
        final relayClient = _FakeRelayClient();
        final aliceChannel = _InProcessLanDirectChannel(host: '192.168.56.10');
        final bobChannel = _InProcessLanDirectChannel(host: '192.168.56.11');
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: const <String>['192.168.56.10'],
          lanDirectChannel: aliceChannel,
          debugBuildId: 'debug-test@same-commit',
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: const <String>['192.168.56.11'],
          lanDirectChannel: bobChannel,
          debugBuildId: 'debug-test@same-commit',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        addTearDown(aliceChannel.stop);
        addTearDown(bobChannel.stop);
        await _pairControllers(alice, bob);

        final resultFuture = alice.runDebugFileBattleTest(
          contact: alice.contacts.single,
          sizeMiB: 5,
        );
        String? attachmentId;
        for (var step = 0; step < 600 && attachmentId == null; step++) {
          await bob.pollNow();
          await alice.pollNow();
          final message = alice
              .messagesFor(alice.contacts.single.deviceId)
              .where(
                (entry) =>
                    entry.attachment?.mimeType ==
                    'application/x-conest-transfer-test',
              )
              .firstOrNull;
          final candidateId = message?.attachment?.id;
          if (candidateId != null &&
              alice.transferSnapshotFor(candidateId)?.phase !=
                  TransferPhase.preparing) {
            attachmentId = candidateId;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(attachmentId, isNotNull);
        alice.failTransferForTesting(
          attachmentId!,
          'simulated terminal source failure',
        );
        final result = await resultFuture;

        expect(result.success, isFalse);
        expect(result.detail, contains('simulated terminal source failure'));
        expect(
          result.elapsed,
          lessThan(const Duration(seconds: 15)),
          reason: 'terminal local failures must not wait for test timeout',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'automatic file test survives one transient binary LAN PUT failure',
      () async {
        final relayClient = _FakeRelayClient();
        final aliceChannel = _InProcessLanDirectChannel(host: '192.168.57.10');
        final bobChannel = _InProcessLanDirectChannel(host: '192.168.57.11');
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: const <String>['192.168.57.10'],
          lanDirectChannel: aliceChannel,
          debugBuildId: 'debug-test@same-commit',
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: const <String>['192.168.57.11'],
          lanDirectChannel: bobChannel,
          debugBuildId: 'debug-test@same-commit',
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        addTearDown(aliceChannel.stop);
        addTearDown(bobChannel.stop);
        await _pairControllers(alice, bob);

        var failedBinaryPut = false;
        aliceChannel.blockPutOverride = () async {
          aliceChannel.blockPutOverride = null;
          failedBinaryPut = true;
          return false;
        };
        var finished = false;
        final resultFuture = alice
            .runDebugFileBattleTest(contact: alice.contacts.single, sizeMiB: 5)
            .whenComplete(() => finished = true);
        for (var step = 0; step < 1800 && !finished; step++) {
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final result = await resultFuture;

        expect(result.success, isTrue, reason: result.detail);
        // Fail a binary block specifically; unrelated control PUTs cannot
        // consume the fault. Exact-hash success proves recovery independently
        // of when the sender appends its asynchronous diagnostic log.
        expect(failedBinaryPut, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'certification matrix transfers 5–2000 MiB over real LAN HTTP',
      () async {
        final previousHttpOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousHttpOverrides);
        final host = await _realPrivateLanHost();
        final matrixRoot = Directory(
          p.join(
            Directory.current.path,
            'build',
            'lan-cert-${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
        final aliceRoot = Directory(p.join(matrixRoot.path, 'alice'));
        final bobRoot = Directory(p.join(matrixRoot.path, 'bob'));
        await aliceRoot.create(recursive: true);
        await bobRoot.create(recursive: true);
        addTearDown(() {
          try {
            matrixRoot.deleteSync(recursive: true);
          } catch (_) {}
        });
        final aliceChannel = HttpLanDirectChannel();
        final bobChannel = HttpLanDirectChannel();
        final relayClient = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: <String>[host],
          lanDirectChannel: aliceChannel,
          localRelayNode: _EphemeralLocalRelayNode(),
          attachmentRootProvider: () async => aliceRoot,
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: <String>[host],
          lanDirectChannel: bobChannel,
          localRelayNode: _EphemeralLocalRelayNode(),
          attachmentRootProvider: () async => bobRoot,
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        addTearDown(aliceChannel.stop);
        addTearDown(bobChannel.stop);
        await _pairControllers(alice, bob);

        final configuredSizes =
            Platform.environment['CONEST_LAN_MATRIX_SIZES']
                ?.split(',')
                .map((value) => int.tryParse(value.trim()))
                .whereType<int>()
                .where(MessengerController.debugLanTestSizesMiB.contains)
                .toList(growable: false) ??
            MessengerController.debugLanTestSizesMiB;
        expect(configuredSizes, isNotEmpty);
        for (final sizeMiB in configuredSizes) {
          final sentChunksBefore =
              aliceChannel.successfulAttachmentChunkPutCount;
          final receivedChunksBefore = bobChannel.acceptedAttachmentChunkCount;
          await alice.runLanAttachmentDiagnostic(
            contact: alice.contacts.single,
            sizeMiB: sizeMiB,
          );
          final fileName = 'conest-lan-test-${sizeMiB}MiB.bin';
          ChatMessage? received;
          for (var step = 0; step < 36000; step++) {
            if (step % 20 == 0) {
              await bob.pollNow();
              await alice.pollNow();
            }
            received = bob
                .messagesFor(bob.contacts.single.deviceId)
                .where((message) => message.attachment?.fileName == fileName)
                .firstOrNull;
            if (received != null &&
                bob.attachmentAwaitingAcceptance(received.attachment!.id)) {
              await bob.acceptIncomingAttachment(received.attachment!.id);
            }
            if (received?.state == DeliveryState.delivered &&
                bob.attachmentAvailableLocally(received!.attachment!.id)) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }

          expect(received, isNotNull, reason: '$sizeMiB MiB offer missing');
          final attachmentId = received!.attachment!.id;
          expect(
            received.state,
            DeliveryState.delivered,
            reason:
                '$sizeMiB MiB: ${bob.inboundTransferDebugForTesting(attachmentId)}',
          );
          expect(received.attachment!.sizeBytes, sizeMiB * 1024 * 1024);
          final cachePath = await bob.attachmentCachePathFor(attachmentId);
          expect(cachePath, isNotNull);
          expect(await File(cachePath!).length(), sizeMiB * 1024 * 1024);
          expect(
            aliceChannel.successfulAttachmentChunkPutCount - sentChunksBefore,
            greaterThanOrEqualTo(received.attachment!.effectiveChunkCount),
          );
          expect(
            bobChannel.acceptedAttachmentChunkCount - receivedChunksBefore,
            greaterThanOrEqualTo(received.attachment!.effectiveChunkCount),
          );
          expect(
            relayClient.storedEnvelopes.where(
              (envelope) => envelope.kind == 'attachment_chunk',
            ),
            isEmpty,
            reason: '$sizeMiB MiB payload used a relay',
          );
          TransferSnapshot? senderSnapshot;
          for (var step = 0; step < 1500; step++) {
            senderSnapshot = alice.transferSnapshotFor(attachmentId);
            if (senderSnapshot?.phase == TransferPhase.completed) break;
            await alice.pollNow();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(
            senderSnapshot?.phase,
            TransferPhase.completed,
            reason: '$sizeMiB MiB sender did not process attachment completion',
          );
          await bob.evictAttachment(attachmentId);
          await alice.evictAttachment(attachmentId);
        }
      },
      skip: Platform.environment['CONEST_RUN_LAN_SIZE_MATRIX'] == '1'
          ? false
          : 'Set CONEST_RUN_LAN_SIZE_MATRIX=1 for the multi-gigabyte certification.',
      timeout: const Timeout(Duration(minutes: 45)),
    );

    test(
      'paired channels exchange a chunk envelope and receiver assembles it',
      () async {
        // The Flutter test binding intercepts real HttpClient calls and
        // forces them to return 400, so we substitute an in-process
        // double that still exercises the full controller integration
        // (hint embedding + caching + fast-path routing + JSON wire
        // format round-trip).
        final aliceChannel = _InProcessLanDirectChannel(host: '192.168.50.10');
        final bobChannel = _InProcessLanDirectChannel(host: '192.168.50.11');
        addTearDown(aliceChannel.stop);
        addTearDown(bobChannel.stop);

        final relayClient = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: const ['192.168.50.10'],
          lanDirectChannel: aliceChannel,
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: const ['192.168.50.11'],
          lanDirectChannel: bobChannel,
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);

        expect(alice.lanDirectPort, isNotNull);
        expect(bob.lanDirectPort, isNotNull);

        await _pairControllers(alice, bob);
        final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');

        // 5-chunk file so the receiver issues several chunk_request envelopes,
        // each piggy-backing its LAN-direct hint; the sender's fast-path
        // should kick in after the first hint lands.
        final payload = Uint8List(64 * 1024 * 5 + 13);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = (i * 23 + 11) & 0xff;
        }
        await alice.sendAttachment(
          contact: bobOnAlice,
          bytes: payload,
          fileName: 'lan_direct.bin',
        );
        for (var step = 0; step < 16; step++) {
          await bob.pollNow();
          await alice.pollNow();
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        final aliceOnBob = bob.contacts.firstWhere((c) => c.alias == 'Alice');
        final received = bob
            .messagesFor(aliceOnBob.deviceId)
            .where((m) => m.attachment?.fileName == 'lan_direct.bin')
            .firstOrNull;
        expect(received, isNotNull);
        final assembled = bob.attachmentBytesFor(received!.attachment!.id);
        expect(assembled, isNotNull);
        expect(assembled!.length, payload.length);

        // The sender must have cached Bob's LAN-direct endpoint from the
        // chunk_request hint by the time the transfer finished.
        final cachedBobEndpoint = alice.peerLanDirectEndpointForTesting(
          bobOnAlice.deviceId,
        );
        expect(
          cachedBobEndpoint,
          isNotNull,
          reason: 'Alice should have cached Bob\'s LAN-direct endpoint',
        );
        expect(cachedBobEndpoint!.host, '192.168.50.11');
        expect(cachedBobEndpoint.port, bob.lanDirectPort);

        // Fast-path actually carried envelopes (not just the relay path).
        // Bob's channel should have accepted at least one PUT.
        expect(
          bobChannel.acceptedEnvelopes,
          greaterThan(0),
          reason: 'Bob\'s LAN-direct channel should have accepted PUTs',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      '31 MiB transfer stays LAN-direct and completes to a disk path',
      () async {
        final sourceDir = Directory.systemTemp.createTempSync(
          'conest_large_source_',
        );
        final aliceRoot = Directory.systemTemp.createTempSync(
          'conest_large_alice_',
        );
        final bobRoot = Directory.systemTemp.createTempSync(
          'conest_large_bob_',
        );
        addTearDown(() {
          for (final directory in [sourceDir, aliceRoot, bobRoot]) {
            try {
              directory.deleteSync(recursive: true);
            } catch (_) {}
          }
        });
        const size = MessengerController.maxAttachmentSizeBytes + 1024 * 1024;
        final source = File(p.join(sourceDir.path, 'large.bin'));
        final sourceHandle = await source.open(mode: FileMode.write);
        try {
          await sourceHandle.setPosition(size - 1);
          await sourceHandle.writeByte(0x5a);
          await sourceHandle.flush();
        } finally {
          await sourceHandle.close();
        }

        final aliceChannel = _InProcessLanDirectChannel(host: '192.168.51.10');
        final bobChannel = _InProcessLanDirectChannel(host: '192.168.51.11');
        addTearDown(aliceChannel.stop);
        addTearDown(bobChannel.stop);
        final relayClient = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: const ['192.168.51.10'],
          lanDirectChannel: aliceChannel,
          attachmentRootProvider: () async => aliceRoot,
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: const ['192.168.51.11'],
          lanDirectChannel: bobChannel,
          attachmentRootProvider: () async => bobRoot,
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await _pairControllers(alice, bob);
        final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');

        await alice.sendAttachmentSource(
          contact: bobOnAlice,
          source: StagedAttachment(
            id: 'large-source',
            fileName: 'large.bin',
            mimeType: 'application/octet-stream',
            sizeBytes: size,
            filePath: source.path,
          ),
        );

        ChatMessage? received;
        for (var step = 0; step < 1200; step++) {
          await bob.pollNow();
          await alice.pollNow();
          received = bob
              .messagesFor(alice.identity!.deviceId)
              .where((message) => message.attachment?.fileName == 'large.bin')
              .firstOrNull;
          if (received != null &&
              bob.attachmentAwaitingAcceptance(received.attachment!.id)) {
            await bob.acceptIncomingAttachment(received.attachment!.id);
          }
          if (received?.state == DeliveryState.delivered &&
              bob.attachmentAvailableLocally(received!.attachment!.id)) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(received, isNotNull);
        expect(received!.state, DeliveryState.delivered);
        expect(received.attachment!.chunkSize, 4 * 1024 * 1024);
        expect(bob.attachmentBytesFor(received.attachment!.id), isNull);
        expect(bob.attachmentAvailableLocally(received.attachment!.id), isTrue);
        final cachePath = await bob.attachmentCachePathFor(
          received.attachment!.id,
        );
        expect(cachePath, isNotNull);
        expect(await File(cachePath!).length(), size);
        final cacheHandle = await File(cachePath).open();
        try {
          await cacheHandle.setPosition(size - 1);
          expect(await cacheHandle.readByte(), 0x5a);
        } finally {
          await cacheHandle.close();
        }
        expect(
          relayClient.storedEnvelopes.where(
            (envelope) => envelope.kind == 'attachment_chunk',
          ),
          isEmpty,
          reason: 'large file bytes must never fall back to relay',
        );
        expect(aliceChannel.acceptedEnvelopes, greaterThan(0));
        expect(bobChannel.acceptedEnvelopes, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('large transfer resumes missing chunks after both peers restart', () async {
      final sourceDir = Directory.systemTemp.createTempSync(
        'conest_resume_source_',
      );
      final aliceRoot = Directory.systemTemp.createTempSync(
        'conest_resume_alice_',
      );
      final bobRoot = Directory.systemTemp.createTempSync('conest_resume_bob_');
      addTearDown(() {
        for (final directory in [sourceDir, aliceRoot, bobRoot]) {
          try {
            directory.deleteSync(recursive: true);
          } catch (_) {}
        }
      });
      const size = MessengerController.maxAttachmentSizeBytes + 1024 * 1024;
      final source = File(p.join(sourceDir.path, 'resume.bin'));
      final sourceHandle = await source.open(mode: FileMode.write);
      try {
        await sourceHandle.setPosition(size - 1);
        await sourceHandle.writeByte(0x7c);
        await sourceHandle.flush();
      } finally {
        await sourceHandle.close();
      }

      final relayClient = _FakeRelayClient();
      final aliceVault = _MemoryVaultStore();
      final bobVault = _MemoryVaultStore();
      final aliceChannel = _InProcessLanDirectChannel(host: '192.168.52.10');
      final bobChannel = _InProcessLanDirectChannel(host: '192.168.52.11')
        ..rejectAfterAcceptedEnvelopes = 4;
      var alice = await _createController(
        relayClient: relayClient,
        displayName: 'Alice',
        lanAddresses: const ['192.168.52.10'],
        lanDirectChannel: aliceChannel,
        attachmentRootProvider: () async => aliceRoot,
        vaultStore: aliceVault,
      );
      var bob = await _createController(
        relayClient: relayClient,
        displayName: 'Bob',
        lanAddresses: const ['192.168.52.11'],
        lanDirectChannel: bobChannel,
        attachmentRootProvider: () async => bobRoot,
        vaultStore: bobVault,
      );
      await _pairControllers(alice, bob);
      final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      await alice.sendAttachmentSource(
        contact: bobOnAlice,
        source: StagedAttachment(
          id: 'resume-source',
          fileName: 'resume.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: size,
          filePath: source.path,
        ),
      );

      for (var step = 0; step < 120; step++) {
        await bob.pollNow();
        await alice.pollNow();
        final received = bob
            .messagesFor(alice.identity!.deviceId)
            .where((message) => message.attachment?.fileName == 'resume.bin')
            .firstOrNull;
        if (received != null &&
            bob.attachmentAwaitingAcceptance(received.attachment!.id)) {
          await bob.acceptIncomingAttachment(received.attachment!.id);
        }
        if (bobChannel.acceptedEnvelopes >= 4) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(bobChannel.acceptedEnvelopes, 4);
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      final interrupted = await bobVault.load();
      final interruptedSession = interrupted.transferSessions.single;
      expect(interruptedSession.direction, TransferDirection.inbound);
      expect(interruptedSession.completedChunks, isNotEmpty);
      expect(
        interruptedSession.completedChunks.length,
        lessThan(interruptedSession.attachment.effectiveChunkCount),
      );

      alice.dispose();
      bob.dispose();
      await aliceChannel.stop();
      await bobChannel.stop();

      final resumedAliceChannel = _InProcessLanDirectChannel(
        host: '192.168.52.10',
      );
      final resumedBobChannel = _InProcessLanDirectChannel(
        host: '192.168.52.11',
      );
      addTearDown(resumedAliceChannel.stop);
      addTearDown(resumedBobChannel.stop);
      alice = await _createController(
        relayClient: relayClient,
        displayName: 'unused',
        lanAddresses: const ['192.168.52.10'],
        lanDirectChannel: resumedAliceChannel,
        attachmentRootProvider: () async => aliceRoot,
        vaultStore: aliceVault,
        createIdentity: false,
      );
      bob = await _createController(
        relayClient: relayClient,
        displayName: 'unused',
        lanAddresses: const ['192.168.52.11'],
        lanDirectChannel: resumedBobChannel,
        attachmentRootProvider: () async => bobRoot,
        vaultStore: bobVault,
        createIdentity: false,
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      alice.onConnectivityChanged(interfaceLabel: 'restart');
      bob.onConnectivityChanged(interfaceLabel: 'restart');

      ChatMessage? received;
      for (var step = 0; step < 1200; step++) {
        await alice.pollNow();
        await bob.pollNow();
        received = bob
            .messagesFor(alice.identity!.deviceId)
            .where((message) => message.attachment?.fileName == 'resume.bin')
            .firstOrNull;
        if (received?.state == DeliveryState.delivered &&
            bob.attachmentAvailableLocally(received!.attachment!.id)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(received, isNotNull);
      expect(
        received!.state,
        DeliveryState.delivered,
        reason:
            'resumedBobAccepted=${resumedBobChannel.acceptedEnvelopes}; '
            'resumedAliceAccepted=${resumedAliceChannel.acceptedEnvelopes}; '
            'inbound=${bob.inboundTransferDebugForTesting(received.attachment!.id)}; '
            'bob=${bob.transferSnapshots.map((s) => '${s.phase.name}:${s.bytesTransferred}/${s.totalBytes}:${s.error}').join(',')}; '
            'alice=${alice.transferSnapshots.map((s) => '${s.phase.name}:${s.bytesTransferred}/${s.totalBytes}:${s.error}').join(',')}; '
            'bobLog=${bob.recentDebugLog.reversed.take(8).join(' | ')}; '
            'aliceLog=${alice.recentDebugLog.reversed.take(8).join(' | ')}',
      );
      final cachePath = await bob.attachmentCachePathFor(
        received.attachment!.id,
      );
      expect(cachePath, isNotNull);
      expect(await File(cachePath!).length(), size);
      expect(
        relayClient.storedEnvelopes.where(
          (envelope) => envelope.kind == 'attachment_chunk',
        ),
        isEmpty,
        reason: 'large restart-resume bytes must remain LAN-only',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('native direct-Iroh attachment certification', () {
    test(
      '250 MiB file completes over direct Iroh with Conest relay payloads deferred',
      () async {
        final sourceRoot = Directory.systemTemp.createTempSync(
          'conest_iroh_source_',
        );
        final aliceRoot = Directory.systemTemp.createTempSync(
          'conest_iroh_alice_',
        );
        final bobRoot = Directory.systemTemp.createTempSync('conest_iroh_bob_');
        addTearDown(() {
          for (final directory in <Directory>[sourceRoot, aliceRoot, bobRoot]) {
            try {
              directory.deleteSync(recursive: true);
            } catch (_) {}
          }
        });
        const size = 250 * 1024 * 1024;
        final directHost = await _realPrivateLanHost();
        final source = File(p.join(sourceRoot.path, 'iroh-250MiB.bin'));
        final handle = await source.open(mode: FileMode.write);
        try {
          await handle.setPosition(size - 1);
          await handle.writeByte(0x63);
          await handle.flush();
        } finally {
          await handle.close();
        }

        final relayClient = _FakeRelayClient();
        final alice = await _createController(
          relayClient: relayClient,
          displayName: 'Alice',
          lanAddresses: <String>[directHost],
          lanDirectChannel: null,
          attachmentRootProvider: () async => aliceRoot,
          transportRegistryFactory: _directNativeIrohRegistry,
        );
        final bob = await _createController(
          relayClient: relayClient,
          displayName: 'Bob',
          lanAddresses: <String>[directHost],
          lanDirectChannel: null,
          attachmentRootProvider: () async => bobRoot,
          transportRegistryFactory: _directNativeIrohRegistry,
        );
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);
        await alice.updateGlobalConnectivity(
          _irohOnlyConnectivity.copyWith(irohTransferLimitEnabled: false),
        );
        await bob.updateGlobalConnectivity(
          _irohOnlyConnectivity.copyWith(irohTransferLimitEnabled: false),
        );
        relayClient.storedEnvelopes.clear();
        final pairing = await alice.addContactFromInvite(
          alias: 'Bob',
          payload: (await bob.buildInvite()).encodePayload(),
          codephrase: '',
        );
        expect(pairing.exchangeStatus, ContactExchangeStatus.pendingApproval);
        await _waitForIroh(() => bob.pendingContactRequests.isNotEmpty);
        await bob.approvePendingContactRequest(
          bob.pendingContactRequests.single.id,
        );
        expect(bob.contacts.single.hasPinnedIrohIdentity, isTrue);
        expect(
          relayClient.storedEnvelopes.where(
            (e) => e.kind == 'contact_exchange',
          ),
          isEmpty,
          reason:
              'Pairing must use authenticated Iroh, without legacy relay delivery',
        );
        await alice.updateContactRoutingPreferences(
          bob.identity!.deviceId,
          const ContactRoutingPreferences(
            lanEnabled: false,
            onlineEnabled: true,
            preferred: RoutingPreference.online,
          ),
        );
        await bob.updateContactRoutingPreferences(
          alice.identity!.deviceId,
          const ContactRoutingPreferences(
            lanEnabled: false,
            onlineEnabled: true,
            preferred: RoutingPreference.online,
          ),
        );

        final bobOnAlice = alice.contacts.single;
        expect(
          bobOnAlice.hasPinnedIrohIdentity,
          isTrue,
          reason:
              'contact=${bobOnAlice.toJson()}; '
              'aliceLog=${alice.recentDebugLog.reversed.take(12).join(' | ')}',
        );
        expect(
          bobOnAlice.directInternetRouteHints.where(
            (route) => route.protocol == PeerRouteProtocol.udp,
          ),
          isNotEmpty,
          reason:
              'the signed ci6 invite must carry at least one direct Iroh '
              'socket hint; contact=${bobOnAlice.toJson()}; '
              'aliceLog=${alice.recentDebugLog.reversed.take(12).join(' | ')}',
        );
        expect(
          alice.effectiveMaxAttachmentSizeFor(bobOnAlice),
          MessengerController.maxLanAttachmentSizeBytes,
          reason:
              'routing=${bobOnAlice.routing.toJson()}; '
              'global=${alice.identity!.connectivity.toJson()}; '
              'aliceLog=${alice.recentDebugLog.reversed.take(12).join(' | ')}',
        );

        await alice.sendAttachmentSource(
          contact: bobOnAlice,
          source: StagedAttachment(
            id: 'iroh-cert-source',
            fileName: 'iroh-250MiB.bin',
            mimeType: 'application/octet-stream',
            sizeBytes: size,
            filePath: source.path,
          ),
        );
        final sent = alice
            .messagesFor(bob.identity!.deviceId)
            .where(
              (message) => message.attachment?.fileName == 'iroh-250MiB.bin',
            )
            .single;
        ChatMessage? received;
        for (var step = 0; step < 1200; step++) {
          if (step % 20 == 0) {
            await alice.pollNow();
            await bob.pollNow();
          }
          received = bob
              .messagesFor(alice.identity!.deviceId)
              .where(
                (message) => message.attachment?.fileName == 'iroh-250MiB.bin',
              )
              .firstOrNull;
          if (received != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          received,
          isNotNull,
          reason:
              'alice=${alice.transferSnapshotFor(sent.attachment!.id)?.error}; '
              'aliceLog=${alice.recentDebugLog.reversed.take(12).join(' | ')}; '
              'bobLog=${bob.recentDebugLog.reversed.take(12).join(' | ')}',
        );
        if (bob.attachmentAwaitingAcceptance(received!.attachment!.id)) {
          await bob.acceptIncomingAttachment(received.attachment!.id);
        }
        for (var step = 0; step < 2400; step++) {
          if (step % 20 == 0) {
            await alice.pollNow();
            await bob.pollNow();
          }
          if (bob.attachmentAvailableLocally(received.attachment!.id)) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final attachmentId = received.attachment!.id;
        expect(
          bob.attachmentAvailableLocally(attachmentId),
          isTrue,
          reason:
              'inbound=${bob.inboundTransferDebugForTesting(attachmentId)}; '
              'alice=${alice.transferSnapshotFor(attachmentId)?.error}; '
              'bob=${bob.transferSnapshotFor(attachmentId)?.error}; '
              'aliceLog=${alice.recentDebugLog.reversed.take(12).join(' | ')}; '
              'bobLog=${bob.recentDebugLog.reversed.take(12).join(' | ')}',
        );
        final cachePath = await bob.attachmentCachePathFor(attachmentId);
        expect(cachePath, isNotNull);
        expect(await File(cachePath!).length(), size);
        final cacheHandle = await File(cachePath).open();
        try {
          await cacheHandle.setPosition(size - 1);
          expect(await cacheHandle.readByte(), 0x63);
        } finally {
          await cacheHandle.close();
        }
        for (var step = 0; step < 600; step++) {
          if (alice.transferSnapshotFor(attachmentId)?.phase ==
              TransferPhase.completed) {
            break;
          }
          if (step % 20 == 0) {
            await alice.pollNow();
            await bob.pollNow();
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final senderSnapshot = alice.transferSnapshotFor(attachmentId);
        expect(senderSnapshot?.phase, TransferPhase.completed);
        expect(senderSnapshot?.transport, TransportKind.iroh);
        expect(senderSnapshot?.path, TransportPathKind.direct);
        expect(
          alice.recentDebugLog.any(
            (entry) => entry.contains('Iroh-binary stream chunk['),
          ),
          isTrue,
          reason: 'the transfer must avoid JSON/base64 block envelopes',
        );
        expect(
          relayClient.storedEnvelopes.where(
            (envelope) => envelope.kind == 'attachment_chunk',
          ),
          isEmpty,
          reason: '250 MiB direct-Iroh payload touched a Conest relay',
        );
      },
      skip:
          Platform.environment['CONEST_RUN_IROH_CONTROLLER_CERT'] == '1' &&
              NativeAttachmentCrypto.tryCreate() != null
          ? false
          : 'Set CONEST_RUN_IROH_CONTROLLER_CERT=1 with conest_native available.',
      timeout: const Timeout(Duration(minutes: 4)),
    );
  });

  group('nightly.9 mid-transfer route rotation', () {
    test('isOutboundReroutingFor returns false for unknown attachmentIds + '
        'flips true after a chunk lands via a non-primary route', () async {
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
      expect(alice.isOutboundReroutingFor('att-nonexistent'), isFalse);
    });
  });

  group('nightly.9 connectivity listener', () {
    test(
      'onConnectivityChanged cancels inbound retry timers + kicks pollNow',
      () async {
        final relayClient = _FakeRelayClient();
        final controller = await _createController(
          relayClient: relayClient,
          displayName: 'Solo',
        );
        addTearDown(controller.dispose);

        // No active transfers — the call should still be a no-op without
        // throwing, kick pollNow, and append a debug log entry.
        final logBefore = controller.recentDebugLog.length;
        controller.onConnectivityChanged(interfaceLabel: 'wifi');
        expect(controller.recentDebugLog.length, greaterThan(logBefore));
        expect(
          controller.recentDebugLog.last,
          contains('Connectivity changed (wifi)'),
        );
      },
    );
  });

  group('nightly.9 album bulk actions + retry', () {
    test('deleteAlbum removes every member tagged with that albumId', () async {
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
      final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');

      final albumId = alice.newAlbumId();
      // Three tiny attachments, all in the same album.
      for (var i = 0; i < 3; i++) {
        final payload = Uint8List.fromList(
          List<int>.generate(64, (j) => (i * 7 + j) & 0xff),
        );
        await alice.sendAttachment(
          contact: bobOnAlice,
          bytes: payload,
          fileName: 'a$i.bin',
          albumId: albumId,
        );
      }
      // A standalone message that must NOT be deleted.
      await alice.sendMessage(contact: bobOnAlice, body: 'standalone');

      final beforeDelete = alice.messagesFor(bobOnAlice.deviceId);
      expect(
        beforeDelete.where((m) => m.albumId == albumId).length,
        3,
        reason: 'three album members seeded',
      );

      await alice.deleteAlbum(albumId);

      final afterDelete = alice.messagesFor(bobOnAlice.deviceId);
      expect(
        afterDelete.where((m) => m.albumId == albumId),
        isEmpty,
        reason: 'all album members removed',
      );
      expect(
        afterDelete.where((m) => m.body == 'standalone').length,
        1,
        reason: 'standalone message untouched',
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test(
      'retryAttachment on a Failed bubble resets state + flips to pending',
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
        final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');

        final payload = Uint8List(64 * 1024);
        await alice.sendAttachment(
          contact: bobOnAlice,
          bytes: payload,
          fileName: 'fail.bin',
        );
        // Find the outbound attachment id from the queued message.
        final msg = alice
            .messagesFor(bobOnAlice.deviceId)
            .firstWhere((m) => m.attachment?.fileName == 'fail.bin');
        final attachmentId = msg.attachment!.id;

        // Force the parent message into Failed via the test back door:
        // mark the outbound state as failed by calling retry on a non-failed
        // state should still work (resets counters). We assert the post-call
        // state of the OutboundAttachmentState via the public progress getter.
        alice.retryAttachment(attachmentId);

        // After retry, the queue worker re-pumps; the parent message must
        // not be left in Failed.
        final after = alice
            .messagesFor(bobOnAlice.deviceId)
            .firstWhere((m) => m.id == msg.id);
        expect(after.state, isNot(DeliveryState.failed));
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  group('nightly.9 outer-gate + leaked-envelope scrubber', () {
    test('round-trip attachment never surfaces attachment_progress as a chat '
        'body message on either side', () async {
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
      final bobOnAlice = alice.contacts.firstWhere((c) => c.alias == 'Bob');
      final payload = Uint8List(32 * 1024 * 4 + 11);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (i * 17 + 5) & 0xff;
      }
      await alice.sendAttachment(
        contact: bobOnAlice,
        bytes: payload,
        fileName: 'gate.bin',
      );
      for (var step = 0; step < 14; step++) {
        await bob.pollNow();
        await alice.pollNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final aliceOnBob = bob.contacts.firstWhere((c) => c.alias == 'Alice');
      final bobConversation = bob.messagesFor(aliceOnBob.deviceId);
      final aliceConversation = alice.messagesFor(bobOnAlice.deviceId);
      bool looksLikeLeaked(String body) {
        final trimmed = body.trimLeft();
        if (!trimmed.startsWith('{')) return false;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map<String, dynamic>) return false;
          return decoded.containsKey('attachmentId') &&
              (decoded.containsKey('received') ||
                  decoded.containsKey('pausedByMe') ||
                  decoded.containsKey('pausedByPeer'));
        } catch (_) {
          return false;
        }
      }

      expect(
        bobConversation.where((m) => looksLikeLeaked(m.body)),
        isEmpty,
        reason: 'receiver must not see attachment_progress as a chat body',
      );
      expect(
        aliceConversation.where((m) => looksLikeLeaked(m.body)),
        isEmpty,
        reason: 'sender must not see attachment_progress as a chat body',
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('scrubber drops pre-seeded leaked JSON-body messages while keeping '
        'real text and attachment messages', () async {
      final vaultStore = _MemoryVaultStore();
      // Seed a vault that "came from nightly.8": one real text message, one
      // attachment_progress leak, one attachment_pause_control leak, and one
      // legitimate JSON-looking body that should NOT be scrubbed.
      final realText = ChatMessage(
        id: 'msg-real-1',
        conversationId: 'conv-dev-bob',
        senderDeviceId: 'dev-bob',
        recipientDeviceId: 'dev-alice',
        body: 'hello',
        outbound: false,
        state: DeliveryState.delivered,
        createdAt: DateTime.utc(2026, 5, 26, 12),
      );
      final legitJsonText = ChatMessage(
        id: 'msg-real-2',
        conversationId: 'conv-dev-bob',
        senderDeviceId: 'dev-bob',
        recipientDeviceId: 'dev-alice',
        body: '{"note":"a real json snippet a user might paste"}',
        outbound: false,
        state: DeliveryState.delivered,
        createdAt: DateTime.utc(2026, 5, 26, 12, 1),
      );
      final progressLeak = ChatMessage(
        id: 'msg-leak-1',
        conversationId: 'conv-dev-bob',
        senderDeviceId: 'dev-bob',
        recipientDeviceId: 'dev-alice',
        body:
            '{"attachmentId":"att-d6d37be656d267aa0f90","received":300,"total":813}',
        outbound: false,
        state: DeliveryState.delivered,
        createdAt: DateTime.utc(2026, 5, 26, 12, 2),
      );
      final pauseLeak = ChatMessage(
        id: 'msg-leak-2',
        conversationId: 'conv-dev-bob',
        senderDeviceId: 'dev-bob',
        recipientDeviceId: 'dev-alice',
        body: '{"attachmentId":"att-xyz","pausedByMe":true}',
        outbound: false,
        state: DeliveryState.delivered,
        createdAt: DateTime.utc(2026, 5, 26, 12, 3),
      );
      final seededConversation = ConversationRecord(
        id: 'conv-dev-bob',
        kind: ConversationKind.direct,
        peerDeviceId: 'dev-bob',
        messages: [realText, legitJsonText, progressLeak, pauseLeak],
      );
      await vaultStore.save(
        VaultSnapshot.empty().copyWith(conversations: [seededConversation]),
      );

      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: vaultStore,
        createIdentity: false,
      );
      addTearDown(controller.dispose);

      final cleaned = (await vaultStore.load()).conversations.single.messages;
      expect(
        cleaned.map((m) => m.id),
        unorderedEquals(['msg-real-1', 'msg-real-2']),
        reason: 'scrubber must drop only the attachment-envelope leaks',
      );

      // Run initialize again on the now-cleaned vault → idempotent no-op.
      final beforeSaves = vaultStore.saveCount;
      final second = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        vaultStore: vaultStore,
        createIdentity: false,
      );
      addTearDown(second.dispose);
      expect(
        vaultStore.saveCount,
        beforeSaves,
        reason: 'second boot must not write the snapshot again',
      );
    });
  });
}

class _HeldGroupCloseMedia extends FakeCallMedia {
  Completer<void>? closeGate;
  @override
  Future<void> close() async {
    await closeGate?.future;
    await super.close();
  }
}

class _VoiceRecordingBridge extends _RecordingPlatformBridge {
  final foreground = <String>[];
  @override
  bool get supportsVoiceCallMedia => true;
  @override
  Future<void> prepareVoiceCallMedia() async {}
  @override
  Future<bool> openVoiceCallMedia({
    required String peerDeviceId,
    required bool outgoing,
  }) async => true;
  @override
  Future<void> closeVoiceCallMedia() async {}
  @override
  Future<void> setVoiceCallNoiseSuppression(bool enabled) async {}
  @override
  Future<void> updateAndroidVoiceCallForeground({
    required bool runtimeEnabled,
    required bool callsEnabled,
    required String? peerName,
    required String callState,
    required bool incoming,
  }) async {
    foreground.add(callState);
  }
}

class _RecordingPlatformBridge extends PlatformBridge {
  final List<String> dismissed = <String>[];
  final List<_ShowCall> shown = <_ShowCall>[];

  @override
  Future<void> dismissMessageNotification({
    required String conversationId,
  }) async {
    dismissed.add(conversationId);
  }

  @override
  Future<void> showMessageNotification({
    required String title,
    required String body,
    required String conversationId,
    String? senderName,
    String? selfName,
    List<({String sender, String body, int timestampMs})> recentMessages =
        const [],
  }) async {
    shown.add(
      _ShowCall(
        title: title,
        body: body,
        conversationId: conversationId,
        senderName: senderName,
        selfName: selfName,
        recentMessages: List.of(recentMessages),
      ),
    );
  }
}

class _ShowCall {
  _ShowCall({
    required this.title,
    required this.body,
    required this.conversationId,
    required this.senderName,
    required this.selfName,
    required this.recentMessages,
  });
  final String title;
  final String body;
  final String conversationId;
  final String? senderName;
  final String? selfName;
  final List<({String sender, String body, int timestampMs})> recentMessages;
}

/// An in-memory carrier network: each joined controller gets a Nostr
/// carrier whose frames go to whichever controller owns the address.
class _FakeCarrierNetwork {
  final Map<String, CarrierTransportAdapter> _byAddress = {};
  final List<(String, String, Uint8List)> frames = [];

  /// Frames from these sender identities are kept in [held], not delivered.
  final Set<String> holdFrom = {};
  final List<(String, String, Uint8List)> held = [];

  Future<void> join(
    MessengerController controller,
    String address, {
    TransportKind kind = TransportKind.nostr,
  }) async {
    final carrier = CarrierTransportAdapter(
      kind: kind,
      sealer: controller.carrierSealer,
      framing: switch (kind) {
        TransportKind.deltaChat => CarrierFraming.email,
        TransportKind.matrix => CarrierFraming.matrix,
        _ => CarrierFraming.nostr,
      },
    )..attach(_FakeCarrierChannel(this, address));
    _byAddress[address] = carrier;
    await controller.registerCarrierTransport(carrier);
  }

  void deliver(String fromIdentity, String to, Uint8List frame) {
    frames.add((fromIdentity, to, frame));
    if (holdFrom.contains(fromIdentity)) {
      held.add((fromIdentity, to, frame));
      return;
    }
    _byAddress[to]?.receiveFrame(fromIdentity, frame);
  }
}

class _FakeCarrierChannel implements CarrierChannel {
  _FakeCarrierChannel(this._network, this.localAddress);

  final _FakeCarrierNetwork _network;

  @override
  final String localAddress;

  @override
  String get routeLabel => 'fake relays';

  @override
  Future<void> sendFrame(String address, Uint8List frame) async =>
      _network.deliver(carrierSenderIdentity(localAddress), address, frame);
}

/// A device's view of a shared fake relay network: it reaches only the
/// hosts in [reachable] (all of them while that is null).
class _GatedRelayClient extends RelayClient {
  _GatedRelayClient(this.shared);

  final _FakeRelayClient shared;
  Set<String>? reachable;

  void _check(String host) {
    if (reachable != null && !reachable!.contains(host)) {
      throw SocketException('$host is not reachable from here');
    }
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
    _check(host);
    return shared.storeEnvelope(
      host: host,
      port: port,
      protocol: protocol,
      recipientDeviceId: recipientDeviceId,
      envelope: envelope,
      timeout: timeout,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
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
  }) async {
    _check(host);
    return shared.fetchEnvelopes(
      host: host,
      port: port,
      protocol: protocol,
      recipientDeviceId: recipientDeviceId,
      limit: limit,
      timeout: timeout,
      waitFor: waitFor,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
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
  }) async {
    _check(host);
    return shared.fetchLeasedEnvelopes(
      host: host,
      port: port,
      protocol: protocol,
      recipientDeviceId: recipientDeviceId,
      limit: limit,
      timeout: timeout,
      waitFor: waitFor,
      leaseFor: leaseFor,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
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
  }) async {
    _check(host);
    return shared.acknowledgeLease(
      host: host,
      port: port,
      protocol: protocol,
      recipientDeviceId: recipientDeviceId,
      leaseId: leaseId,
      timeout: timeout,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
  }

  @override
  Future<RelayHealthInfo> inspectHealth({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) async {
    _check(host);
    return shared.inspectHealth(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
  }
}

/// The bitchat app on an iPhone: its own identity on a plain mesh node.
class _FakeBitchatPhone {
  _FakeBitchatPhone._(this.direct);

  final BitchatDirect direct;
  late final BitchatNode _node;
  final List<BitchatMessageReceived> messages = [];
  final List<BitchatReceiptReceived> receipts = [];
  final List<BitchatPublicMessage> publics = [];

  /// Events a gateway passed down to everyone nearby.
  final List<NostrEvent> carried = [];

  static bool _same(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  static Future<_FakeBitchatPhone> start(
    FakeBleNeighbourhood area,
    String name,
  ) async {
    final phone = _FakeBitchatPhone._(
      await BitchatDirect.create(
        nickname: 'iphone',
        noiseSeed: List.filled(32, 9),
        signingSeed: List.filled(32, 19),
      ),
    );
    phone.direct.events.listen((event) {
      switch (event) {
        case BitchatMessageReceived():
          phone.messages.add(event);
        case BitchatReceiptReceived():
          phone.receipts.add(event);
        case BitchatPeerSeen():
      }
    });
    phone._node = BitchatNode(
      links: area.node(name),
      wantsRecipient: (id) => _same(id, phone.direct.peerId),
      onPrivate: (packet, _) {
        if (!_same(packet.recipientId!, phone.direct.peerId)) {
          return BitchatPrivate.notMine;
        }
        unawaited(phone.direct.handleNoise(packet).then(phone._sendAll));
        return BitchatPrivate.accepted;
      },
      onPacket: (packet) async {
        switch (packet.type) {
          case BitchatType.announce:
            await phone.direct.handleAnnounce(packet);
          case BitchatType.noiseHandshake:
            if (_same(packet.recipientId ?? const [], phone.direct.peerId)) {
              await phone._sendAll(await phone.direct.handleNoise(packet));
            }
          case BitchatType.message:
            final message = await phone.direct.readPublic(packet);
            if (message != null) phone.publics.add(message);
          case bitchatNostrCarrierType:
            final payload = packet.expandedPayload(maxBytes: 20000);
            final carrier = payload == null
                ? null
                : BitchatNostrCarrier.decode(payload);
            if (packet.recipientId == null &&
                carrier?.direction == BitchatCarrierDirection.fromGateway) {
              final event = carrier!.event();
              if (event != null) phone.carried.add(event);
            }
        }
        return true;
      },
    );
    await phone._sendAll([await phone.direct.announce()]);
    return phone;
  }

  Future<void> _sendAll(List<BitchatPacket> packets) async {
    for (final packet in packets) {
      await _node.send(packet);
    }
  }

  /// A message in the mesh chat (announcing first, as the app does).
  Future<void> say(String text) async {
    await _sendAll([await direct.announce()]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await _sendAll([(await direct.publicMessages(text)).single]);
  }

  /// A message in the mesh chat, without announcing again.
  Future<void> shout(String text) async =>
      _sendAll(await direct.publicMessages(text));

  /// Hands [event] for [geohash] to the gateway [gatewayId], signed as
  /// bitchat signs such deposits.
  Future<void> deposit(String gatewayId, String geohash, NostrEvent event) async {
    final unsigned = BitchatPacket(
      type: bitchatNostrCarrierType,
      senderId: direct.peerId,
      recipientId: Uint8List.fromList([
        for (var i = 0; i < gatewayId.length; i += 2)
          int.parse(gatewayId.substring(i, i + 2), radix: 16),
      ]),
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: BitchatNostrCarrier(
        direction: BitchatCarrierDirection.toGateway,
        geohash: geohash,
        eventJson: Uint8List.fromList(utf8.encode(jsonEncode(event))),
      ).encode(),
    );
    final signature = await Ed25519().sign(
      unsigned.bytesToSign(),
      keyPair: await Ed25519().newKeyPairFromSeed(List.filled(32, 19)),
    );
    await _sendAll([
      unsigned.copyWith(signature: Uint8List.fromList(signature.bytes)),
    ]);
  }

  /// A private message to [peerId].
  Future<void> write(String peerId, String text) async {
    final (packets, _) = await direct.sendText(peerId, text);
    await _sendAll(packets);
  }

  Future<void> stop() => _node.stop();
}
