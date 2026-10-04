import 'dart:async';
import 'dart:typed_data';

import 'carrier.dart';
import 'matrix_client.dart';
import 'transport.dart';
import 'transport_models.dart';

/// A peer's Conest-specific Matrix device.
class MatrixAddress {
  const MatrixAddress({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;

  /// The form carried in [TransportPeer.transportAddresses].
  String encode() => '$userId|$deviceId';

  static MatrixAddress? decode(String? value) {
    if (value == null) return null;
    final split = value.lastIndexOf('|');
    if (split <= 0) return null;
    return tryCreate(value.substring(0, split), value.substring(split + 1));
  }

  Map<String, Object?> toJson() => {'userId': userId, 'deviceId': deviceId};

  static MatrixAddress? fromJson(Object? json) => json is Map<String, dynamic>
      ? tryCreate(json['userId'], json['deviceId'])
      : null;

  static MatrixAddress? tryCreate(Object? userId, Object? deviceId) {
    if (userId is! String ||
        !isMatrixUserId(userId) ||
        deviceId is! String ||
        deviceId.isEmpty ||
        deviceId.length > 255 ||
        deviceId.contains('|')) {
      return null;
    }
    return MatrixAddress(userId: userId, deviceId: deviceId);
  }

  @override
  bool operator ==(Object other) =>
      other is MatrixAddress &&
      other.userId == userId &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(userId, deviceId);
}

/// Seals envelopes for one Conest peer so the homeserver sees only accounts,
/// timing and sizes, and authenticates what arrives.
abstract interface class MatrixCarrierSealer {
  Future<Uint8List> seal(String peerDeviceId, Uint8List envelope);

  /// Whether frames from this Matrix user may be buffered at all: only users
  /// pinned by a contact, so strangers cannot fill the reassembly buffer.
  bool acceptsSender(String senderUserId);

  /// Opens a sealed envelope from a Matrix user, returning the authenticated
  /// Conest device it came from, or null when no known contact sealed it.
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    String senderUserId,
    Uint8List sealed,
  );
}

const String matrixCarrierEventType = 'dev.conest.carrier.v1';

/// Largest sealed envelope sent over Matrix; bigger ones use other routes.
const int matrixCarrierMaxSealedBytes = 256 * 1024;

/// Payload per to-device event, well under the 64 KiB event limit after
/// base64 and framing.
const int matrixCarrierChunkBytes = 40 * 1024;

/// Splits a sealed envelope into to-device frame contents.
List<Map<String, Object?>> matrixCarrierFrames(String id, Uint8List sealed) =>
    carrierJsonFrames(CarrierFraming.matrix, id, sealed);

/// Reassembles Matrix carrier frames per sender with bounded memory.
typedef MatrixCarrierReassembler = CarrierReassembler;

/// Sends carrier frames through a Matrix client that owns the device's only
/// `/sync` (the full Matrix client); its to-device frames come back through
/// [MatrixTransportAdapter.receiveExternal].
abstract interface class MatrixCarrierChannel {
  Future<void> sendFrame(
    MatrixAddress to,
    Map<String, Object?> frame,
    String transactionId,
  );
}

/// Observable state for settings and diagnostics.
class MatrixCarrierStatus {
  const MatrixCarrierStatus({
    required this.signedIn,
    required this.syncing,
    this.userId,
    this.lastError,
  });

  final bool signedIn;
  final bool syncing;
  final String? userId;
  final String? lastError;
}

/// Store-and-forward route through the user's Matrix account: Conest
/// envelopes are sealed, chunked and sent as to-device messages to the
/// peer's Conest-specific Matrix device, and read back from `/sync`.
class MatrixTransportAdapter implements TransportAdapter {
  MatrixTransportAdapter({
    required MatrixCarrierSealer sealer,
    MatrixClient Function(MatrixSession session)? clientFactory,
    void Function(String nextBatch, bool hadEvents)? onSyncToken,
    void Function()? onSessionRevoked,
    Duration syncTimeout = const Duration(seconds: 30),
    DateTime Function()? now,
    MatrixCarrierChannel? channel,
  }) : _sealer = sealer,
       _channel = channel,
       _clientFactory = clientFactory ?? MatrixClient.new,
       _onSyncToken = onSyncToken,
       _onSessionRevoked = onSessionRevoked,
       _syncTimeout = syncTimeout,
       _now = now ?? DateTime.now,
       _reassembler = MatrixCarrierReassembler(now: now);

  final MatrixCarrierSealer _sealer;
  final MatrixCarrierChannel? _channel;
  MatrixSession? _externalSession;

  /// Frames forwarded while stopped: the owning client has already
  /// acknowledged them, so they wait here instead of being dropped.
  final List<MatrixToDeviceEvent> _held = [];
  static const int _maxHeld = 256;
  final MatrixClient Function(MatrixSession session) _clientFactory;
  final void Function(String nextBatch, bool hadEvents)? _onSyncToken;
  final void Function()? _onSessionRevoked;
  final Duration _syncTimeout;
  final DateTime Function() _now;
  final MatrixCarrierReassembler _reassembler;
  final _inbound = StreamController<TransportInboundEnvelope>.broadcast();
  final _paths = StreamController<RouteCandidate>.broadcast();
  final _status = StreamController<MatrixCarrierStatus>.broadcast();

  MatrixClient? _client;
  String? _since;
  bool _started = false;
  int _generation = 0;
  bool _syncing = false;
  String? _lastError;

  @override
  TransportKind get kind => TransportKind.matrix;

  @override
  TransportCapabilities get capabilities => const TransportCapabilities(
    requiresPeerOnline: false,
    supportsStoreForward: true,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: false,
    reportsPath: true,
    // Envelope plus the seal's nonce and tag must fit the carrier limit.
    maximumPayloadBytes: matrixCarrierMaxSealedBytes - 64,
    // Several frames go out in sequence and a short rate limit may be
    // waited out; a cut-off attempt would keep sending in the background
    // while the caller falls back.
    sendAttemptTimeout: Duration(seconds: 60),
  );

  MatrixSession? get session => _client?.session ?? _externalSession;

  MatrixCarrierStatus get status => MatrixCarrierStatus(
    signedIn: session != null,
    syncing: _channel != null ? session != null : _syncing,
    userId: session?.userId,
    lastError: _lastError,
  );

  Stream<MatrixCarrierStatus> get statusChanges => _status.stream;

  /// Uses [session] from now on, resuming `/sync` after [since].
  void attach(MatrixSession session, {String? since}) {
    if (_channel != null) {
      // The owning client syncs; this adapter only seals and reassembles.
      _externalSession = session;
      _lastError = null;
      _generation++;
      _emitStatus();
      return;
    }
    _client?.close();
    _client = _clientFactory(session);
    _since = since;
    _lastError = null;
    _generation++;
    if (_started) unawaited(_syncLoop(_generation));
    _emitStatus();
  }

  /// Stops using the current session without signing it out.
  void detach() {
    _generation++;
    _externalSession = null;
    _held.clear();
    _client?.close();
    _client = null;
    _since = null;
    _syncing = false;
    _emitStatus();
  }

  /// Signs the Conest device out of the homeserver, then detaches.
  Future<void> signOut() async {
    final client = _client;
    detach();
    // With a channel, the owning client signs the device out.
    if (client == null) return;
    final temporary = _clientFactory(client.session);
    try {
      await temporary.logout();
    } finally {
      temporary.close();
    }
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (_client != null) unawaited(_syncLoop(_generation));
    final held = List.of(_held);
    _held.clear();
    for (final event in held) {
      receiveExternal(event);
    }
  }

  /// A carrier frame from the owning client's sync.
  void receiveExternal(MatrixToDeviceEvent event) {
    if (event.type != matrixCarrierEventType) return;
    if (!_started || session == null) {
      if (_held.length >= _maxHeld) _held.removeAt(0);
      _held.add(event);
      return;
    }
    unawaited(
      _receive(event, _generation).catchError((Object _) {
        // An unreadable frame is dropped, as in the own sync loop.
      }),
    );
  }

  @override
  Future<void> stop() async {
    _started = false;
    _generation++;
    _syncing = false;
    _client?.close();
    _client = null;
  }

  @override
  Stream<RouteCandidate> get pathChanges => _paths.stream;

  @override
  Stream<TransportInboundEnvelope> get inboundEnvelopes => _inbound.stream;

  @override
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer) async {
    final current = session;
    final address = MatrixAddress.decode(
      peer.transportAddresses[TransportKind.matrix],
    );
    if (current == null || address == null) return const <RouteCandidate>[];
    return [
      RouteCandidate(
        transport: TransportKind.matrix,
        path: TransportPathKind.storeForward,
        routeId: 'matrix:${address.encode()}',
        label: 'Matrix (${current.homeserver.host})',
        trust: TransportTrustState.pinnedTransport,
        maximumPayloadBytes: capabilities.maximumPayloadBytes,
      ),
    ];
  }

  @override
  Future<DeliveryReceipt> sendEnvelope({
    required TransportPeer peer,
    required RouteCandidate route,
    required TransportEnvelope envelope,
  }) async {
    final client = _client;
    final channel = _channel;
    final address = MatrixAddress.decode(
      peer.transportAddresses[TransportKind.matrix],
    );
    if ((client == null && (channel == null || session == null)) ||
        address == null) {
      throw StateError('Matrix is not available for this contact.');
    }
    final sealed = await _sealer.seal(peer.deviceId, envelope.bytes);
    final frames = matrixCarrierFrames(MatrixClient.newTransactionId(), sealed);
    for (final frame in frames) {
      final transactionId = MatrixClient.newTransactionId();
      if (channel != null) {
        await channel.sendFrame(address, frame, transactionId);
        continue;
      }
      Future<void> send() => client!.sendToDevice(matrixCarrierEventType, {
        address.userId: {address.deviceId: frame},
      }, transactionId: transactionId);
      try {
        await send();
      } on MatrixException catch (error) {
        final wait = error.retryAfter;
        if (!error.isRateLimited ||
            wait == null ||
            wait > const Duration(seconds: 5)) {
          rethrow;
        }
        // Same transaction id: the homeserver treats it as a retry.
        await Future<void>.delayed(wait);
        await send();
      }
    }
    return DeliveryReceipt(
      state: DeliveryReceiptState.storedForPeer,
      route: route,
      at: _now().toUtc(),
    );
  }

  @override
  Future<DeliveryReceipt> sendAttachmentRange({
    required TransportPeer peer,
    required RouteCandidate route,
    required AttachmentRange range,
  }) async => DeliveryReceipt(
    state: DeliveryReceiptState.failed,
    route: route,
    at: _now().toUtc(),
    detail: 'Matrix carries messages, not file streams.',
  );

  @override
  Future<void> cancel(String operationId) async {}

  Future<void> _syncLoop(int generation) async {
    var backoff = const Duration(seconds: 2);
    while (_started && generation == _generation) {
      final client = _client;
      if (client == null) return;
      try {
        _setSyncing(true);
        final result = await client.sync(since: _since, timeout: _syncTimeout);
        if (generation != _generation) return;
        for (final event in result.toDevice) {
          if (event.type != matrixCarrierEventType) continue;
          try {
            await _receive(event, generation);
          } catch (_) {
            // One bad frame must not hold back the acknowledgement of the
            // batch, or the homeserver would redeliver it forever.
          }
        }
        // Stopped or re-attached meanwhile: do not commit a token whose
        // batch may not have been handed on (or belongs to another account).
        if (generation != _generation) return;
        // The next request carries this token, acknowledging the batch;
        // everything in it was handed on above.
        _since = result.nextBatch;
        _onSyncToken?.call(result.nextBatch, result.toDevice.isNotEmpty);
        _lastError = null;
        backoff = const Duration(seconds: 2);
      } on MatrixException catch (error) {
        if (generation != _generation) return;
        _lastError = error.message;
        if (error.isUnknownToken) {
          detach();
          _onSessionRevoked?.call();
          return;
        }
        _setSyncing(false);
        await Future<void>.delayed(error.retryAfter ?? _nextBackoff(backoff));
        backoff = _nextBackoff(backoff);
      } catch (error) {
        if (generation != _generation) return;
        _lastError = '$error';
        _setSyncing(false);
        await Future<void>.delayed(backoff);
        backoff = _nextBackoff(backoff);
      }
    }
  }

  Future<void> _receive(MatrixToDeviceEvent event, int generation) async {
    if (!_sealer.acceptsSender(event.sender)) return;
    final sealed = _reassembler.add(event.sender, event.content);
    if (sealed == null) return;
    final opened = await _sealer.open(event.sender, sealed);
    if (opened == null) return;
    if (generation != _generation) {
      throw StateError('Matrix carrier stopped while receiving.');
    }
    _inbound.add(
      TransportInboundEnvelope(
        transport: TransportKind.matrix,
        path: TransportPathKind.storeForward,
        senderTransportIdentity: opened.peerDeviceId,
        bytes: opened.envelope,
        receivedAt: _now().toUtc(),
      ),
    );
  }

  Duration _nextBackoff(Duration current) {
    final doubled = current * 2;
    return doubled > const Duration(minutes: 1)
        ? const Duration(minutes: 1)
        : doubled;
  }

  void _setSyncing(bool value) {
    if (_syncing == value) return;
    _syncing = value;
    _emitStatus();
  }

  void _emitStatus() {
    if (!_status.isClosed) _status.add(status);
  }
}
