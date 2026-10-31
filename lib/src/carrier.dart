import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'limits/network_limiter.dart';
import 'transport.dart';
import 'transport_models.dart';

/// Seals envelopes for one Conest peer on a carrier network, so the network
/// sees only its own addresses, timing and sizes, and authenticates what
/// arrives. One sealer serves every carrier kind; each kind has its own key.
abstract interface class CarrierSealer {
  Future<Uint8List> seal(
    TransportKind kind,
    String peerDeviceId,
    Uint8List envelope,
  );

  /// Whether frames from [sender] may be buffered at all: only senders
  /// pinned by a contact, so strangers cannot fill the reassembly buffer.
  bool acceptsSender(TransportKind kind, String sender);

  /// Opens a sealed envelope from [sender], returning the authenticated
  /// Conest device it came from, or null when no known contact sealed it.
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    TransportKind kind,
    String sender,
    Uint8List sealed,
  );
}

/// Size limits of one carrier network.
class CarrierFraming {
  const CarrierFraming({required this.maxSealedBytes, required this.chunkBytes})
    : assert(chunkBytes > 0 && maxSealedBytes >= chunkBytes);

  /// Largest sealed envelope sent; bigger ones use other routes.
  final int maxSealedBytes;

  /// Sealed bytes per frame.
  final int chunkBytes;

  /// Matrix to-device events: well under the 64 KiB event limit after
  /// base64 and framing.
  static const matrix = CarrierFraming(
    maxSealedBytes: 256 * 1024,
    chunkBytes: 40 * 1024,
  );

  /// Nostr events: public relays commonly cap events near 64 KiB, and the
  /// frame is NIP-44 encrypted and base64-encoded inside the event.
  static const nostr = CarrierFraming(
    maxSealedBytes: 128 * 1024,
    chunkBytes: 24 * 1024,
  );

  /// One mail per envelope.
  static const email = CarrierFraming(
    maxSealedBytes: 1024 * 1024,
    chunkBytes: 1024 * 1024,
  );

  /// A bitchat private payload inside one Noise session message.
  static const bitchat = CarrierFraming(
    maxSealedBytes: 16 * 1024,
    chunkBytes: 16 * 1024,
  );

  /// Most frames one envelope may need.
  int get maxFrames => (maxSealedBytes + chunkBytes - 1) ~/ chunkBytes;

  /// Largest envelope a route can take: the seal adds a nonce and a tag.
  int get maxEnvelopeBytes => maxSealedBytes - 64;

  int frameCount(int sealedLength) =>
      (sealedLength + chunkBytes - 1) ~/ chunkBytes;

  void _checkSealed(Uint8List sealed) {
    if (sealed.isEmpty || sealed.length > maxSealedBytes) {
      throw ArgumentError('Sealed envelope size is outside the carrier limit.');
    }
  }

  Uint8List _chunk(Uint8List sealed, int index) => Uint8List.sublistView(
    sealed,
    index * chunkBytes,
    min((index + 1) * chunkBytes, sealed.length),
  );
}

/// Splits a sealed envelope into JSON frame contents `{v,id,i,n,d}`, as
/// Matrix to-device events carry them.
List<Map<String, Object?>> carrierJsonFrames(
  CarrierFraming framing,
  String id,
  Uint8List sealed,
) {
  framing._checkSealed(sealed);
  final count = framing.frameCount(sealed.length);
  return [
    for (var index = 0; index < count; index++)
      {
        'v': 1,
        'id': id,
        'i': index,
        'n': count,
        'd': base64Encode(framing._chunk(sealed, index)),
      },
  ];
}

/// Version byte of a binary carrier frame.
const int carrierBinaryFrameVersion = 1;

/// Header of a binary frame: version, 8-byte envelope id, index, count.
const int carrierBinaryFrameHeaderBytes = 1 + 8 + 1 + 1;

/// Splits a sealed envelope into binary frames
/// `version | id (8 bytes) | index | count | data`, for carriers that move
/// bytes rather than JSON.
List<Uint8List> carrierBinaryFrames(
  CarrierFraming framing,
  Uint8List sealed, {
  Random? random,
}) {
  framing._checkSealed(sealed);
  final count = framing.frameCount(sealed.length);
  if (count > 255) {
    throw ArgumentError('A binary carrier envelope has at most 255 frames.');
  }
  final source = random ?? Random.secure();
  final id = List<int>.generate(8, (_) => source.nextInt(256));
  return [
    for (var index = 0; index < count; index++)
      Uint8List.fromList([
        carrierBinaryFrameVersion,
        ...id,
        index,
        count,
        ...framing._chunk(sealed, index),
      ]),
  ];
}

/// Reassembles carrier frames per sender with bounded memory. Frames from
/// one sender usually arrive in order, but nothing here depends on that.
class CarrierReassembler {
  CarrierReassembler({
    this.framing = CarrierFraming.matrix,
    DateTime Function()? now,
    this.expiry = const Duration(minutes: 10),
    this.maxPending = 64,
    this.maxPendingPerSender = 8,
    this.strangerPrefix,
    this.maxStrangerPending = 12,
  }) : _now = now ?? DateTime.now;

  final CarrierFraming framing;
  final DateTime Function() _now;
  final Duration expiry;
  final int maxPending;
  final int maxPendingPerSender;
  final Map<String, _PendingEnvelope> _pending = {};

  /// Senders starting with this are strangers (requests to a mesh inbox,
  /// which anyone holding an invite can make): kept apart in a small pool
  /// of their own, so they never push out contacts' partial envelopes, and
  /// keyed with the frame count, so another sender reusing an id cannot
  /// delete or overwrite a request in progress.
  final String? strangerPrefix;
  final int maxStrangerPending;
  final Map<String, _PendingEnvelope> _strangers = {};

  /// Adds a JSON frame (see [carrierJsonFrames]); returns the complete
  /// sealed envelope once its last frame arrives.
  Uint8List? add(String sender, Map<String, dynamic> content) {
    final id = content['id'];
    final index = content['i'];
    final count = content['n'];
    final data = content['d'];
    if (content['v'] != 1 ||
        id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        index is! int ||
        count is! int ||
        data is! String) {
      return null;
    }
    final Uint8List chunk;
    try {
      chunk = base64Decode(data);
    } on FormatException {
      return null;
    }
    return _accept(sender, id, index, count, chunk);
  }

  /// Adds a binary frame (see [carrierBinaryFrames]).
  Uint8List? addBinary(String sender, Uint8List frame) {
    if (frame.length <= carrierBinaryFrameHeaderBytes ||
        frame[0] != carrierBinaryFrameVersion) {
      return null;
    }
    final id = base64Encode(Uint8List.sublistView(frame, 1, 9));
    return _accept(
      sender,
      id,
      frame[9],
      frame[10],
      Uint8List.sublistView(frame, carrierBinaryFrameHeaderBytes),
    );
  }

  Uint8List? _accept(
    String sender,
    String id,
    int index,
    int count,
    Uint8List chunk,
  ) {
    if (count < 1 ||
        count > framing.maxFrames ||
        index < 0 ||
        index >= count ||
        chunk.isEmpty ||
        chunk.length > framing.chunkBytes) {
      return null;
    }
    if (count == 1) return chunk;
    final now = _now();
    _pending.removeWhere(
      (_, entry) => now.difference(entry.startedAt) > expiry,
    );
    if (strangerPrefix case final prefix? when sender.startsWith(prefix)) {
      _strangers.removeWhere(
        (_, entry) => now.difference(entry.startedAt) > expiry,
      );
      final key = '$sender|$id|$count';
      final entry = _strangers.putIfAbsent(key, () {
        if (_strangers.length >= maxStrangerPending) {
          _strangers.remove(_strangers.keys.first);
        }
        return _PendingEnvelope(count, now);
      });
      // The first chunk received for an index stays.
      entry.chunks.putIfAbsent(index, () => chunk);
      if (entry.chunks.length < count) return null;
      _strangers.remove(key);
      final builder = BytesBuilder(copy: false);
      for (var part = 0; part < count; part++) {
        builder.add(entry.chunks[part]!);
      }
      return builder.takeBytes();
    }
    final key = '$sender|$id';
    final entry = _pending.putIfAbsent(key, () {
      // One sender can only displace its own oldest partial envelope.
      final own = _pending.keys
          .where((existing) => existing.startsWith('$sender|'))
          .toList(growable: false);
      if (own.length >= maxPendingPerSender) {
        _pending.remove(own.first);
      } else if (_pending.length >= maxPending) {
        _pending.remove(_pending.keys.first);
      }
      return _PendingEnvelope(count, now);
    });
    if (entry.count != count) {
      _pending.remove(key);
      return null;
    }
    entry.chunks[index] = chunk;
    if (entry.chunks.length < count) return null;
    _pending.remove(key);
    final builder = BytesBuilder(copy: false);
    for (var part = 0; part < count; part++) {
      builder.add(entry.chunks[part]!);
    }
    return builder.takeBytes();
  }
}

class _PendingEnvelope {
  _PendingEnvelope(this.count, this.startedAt);
  final int count;
  final DateTime startedAt;
  final Map<int, Uint8List> chunks = {};
}

/// The network side of a carrier: a native client that owns the account,
/// the connection and its own address.
abstract interface class CarrierChannel {
  /// This device's address on the network, sent to contacts in the
  /// authenticated contact exchange; null until the account is ready.
  String? get localAddress;

  /// A short description of where frames go, such as a relay host.
  String get routeLabel;

  /// Sends one frame to [address], a contact's [localAddress].
  Future<void> sendFrame(String address, Uint8List frame);
}

/// A channel that can bring a first request to a would-be contact's inbox
/// (the Bluetooth mesh), which recognises it without knowing the sender.
abstract interface class InboxCarrierChannel implements CarrierChannel {
  /// Sends one frame of an envelope to [address]'s inbox, under
  /// [senderId]: one random id per envelope, so the receiver keeps each
  /// request apart and nothing links the envelope to this device.
  Future<void> sendInboxFrame(
    String address,
    Uint8List frame,
    Uint8List senderId,
    Uint8List inboxKey,
  );
}

/// A sealer that tells which of the envelopes it sealed go to a would-be
/// contact's inbox, and under which key.
abstract interface class InboxCarrierSealer {
  /// The target's inbox key for [sealed], a first request; null for any
  /// other envelope.
  Uint8List? inboxKeyFor(Uint8List sealed);
}

/// A channel whose network confirms that a frame reached the other device
/// (a radio's delivery acknowledgement).
abstract interface class AcknowledgingCarrierChannel implements CarrierChannel {
  /// Sends [frame] like [sendFrame]; returns the network's id for it, which
  /// [frameAcks] later names.
  Future<int> sendTrackedFrame(String address, Uint8List frame);

  /// Frames the other device's radio confirmed ([ok]) or refused.
  Stream<({int frameId, bool ok})> get frameAcks;
}

/// A channel that sends a frame as something larger than its bytes (a radio
/// that carries text, so the frame is encoded): its airtime is counted on
/// the encoded size.
abstract interface class AirtimeSizedCarrierChannel implements CarrierChannel {
  /// The bytes sent on air for a frame of [frameLength] bytes.
  int airBytes(int frameLength);
}

/// One envelope going out frame by frame on a channel that confirms frames.
class _RadioEnvelope {
  _RadioEnvelope(this.envelopeId, this.deviceId);

  final String envelopeId;
  final String deviceId;

  /// Frames sent and not yet confirmed.
  final Set<int> waiting = {};
  bool tracked = false;

  /// A frame the network gave no id to confirm it by: the envelope cannot
  /// be reported as delivered.
  bool unconfirmable = false;
  bool allSent = false;
  bool refused = false;
  bool reported = false;
}

/// What [CarrierTransportAdapter.cancel] takes: one envelope to one device
/// (a group message goes to each member separately).
String carrierSendId(String deviceId, String envelopeId) =>
    transportOperationId(deviceId, envelopeId);

/// The other device's radio confirmed every frame of envelope [envelopeId]
/// for [deviceId].
class CarrierDeliveryReceipt {
  const CarrierDeliveryReceipt({
    required this.kind,
    required this.envelopeId,
    required this.deviceId,
  });

  final TransportKind kind;
  final String envelopeId;
  final String deviceId;
}

/// A channel with its own connections, opened while its carrier runs, so
/// nothing is fetched while the carrier is off.
abstract interface class ManagedCarrierChannel implements CarrierChannel {
  void start();
  Future<void> stop();
}

/// A channel that must know its peers ahead of time, such as a MeshCore
/// radio that only accepts messages from contacts on the radio.
abstract interface class PeerAwareCarrierChannel implements CarrierChannel {
  /// The addresses of every contact that may use this carrier.
  void updatePeers(Set<String> addresses);
}

/// Observable state of a carrier for settings and diagnostics.
class CarrierStatus {
  const CarrierStatus({
    required this.kind,
    required this.ready,
    this.address,
    this.lastError,
  });

  final TransportKind kind;
  final bool ready;
  final String? address;
  final String? lastError;
}

/// Store-and-forward route over a carrier network: envelopes are sealed,
/// split into binary frames and sent through a [CarrierChannel]; frames the
/// channel receives come in through [receiveFrame].
class CarrierTransportAdapter implements TransportAdapter, RateLimited {
  CarrierTransportAdapter({
    required this.kind,
    required CarrierSealer sealer,
    required this.framing,
    this.path = TransportPathKind.storeForward,
    this.sendAttemptTimeout = const Duration(seconds: 60),
    this.frameSpacing = Duration.zero,
    bool Function(String address)? isValidAddress,
    DateTime Function()? now,
    Random? random,
    String? strangerSenderPrefix,
  }) : _sealer = sealer,
       _isValidAddress = isValidAddress ?? isPlausibleCarrierAddress,
       _now = now ?? DateTime.now,
       _random = random,
       _reassembler = CarrierReassembler(
         framing: framing,
         now: now,
         strangerPrefix: strangerSenderPrefix,
       );

  @override
  final TransportKind kind;
  final CarrierFraming framing;
  final TransportPathKind path;
  final Duration sendAttemptTimeout;

  /// Pause between frames of one envelope, for networks that rate-limit.
  final Duration frameSpacing;

  /// The account's turn-taking on this network (see [NetworkBudgets]): every
  /// frame passes it, whichever chat, group or own device sends it. Set by
  /// the controller; null where the network names no limit.
  @override
  NetworkLimiter? limiter;

  /// True where the channel takes the limiter's turns itself (one mail is
  /// one turn): the adapter then only reports the limiter to the dispatcher.
  bool channelPacesFrames = false;
  final CarrierSealer _sealer;
  final bool Function(String address) _isValidAddress;
  final DateTime Function() _now;
  final Random? _random;
  final CarrierReassembler _reassembler;
  final _inbound = StreamController<TransportInboundEnvelope>.broadcast();
  final _paths = StreamController<RouteCandidate>.broadcast();
  final _status = StreamController<CarrierStatus>.broadcast();
  final _receipts = StreamController<CarrierDeliveryReceipt>.broadcast();

  /// Envelopes the other device's radio confirmed (channels that report it).
  Stream<CarrierDeliveryReceipt> get deliveryReceipts => _receipts.stream;

  /// Frames sent and not yet confirmed, by frame id.
  final Map<int, _RadioEnvelope> _unconfirmedFrames = {};
  static const int _maxUnconfirmedFrames = 512;
  StreamSubscription<({int frameId, bool ok})>? _frameAckSubscription;

  /// When each envelope stopped being worth sending (its receipt came), by
  /// [carrierSendId]: sends that started before then stop.
  final Map<String, DateTime> _cancelled = {};
  static const int _maxCancelled = 256;

  /// Frames received while stopped: the channel has already taken them off
  /// the network, so they wait here instead of being dropped.
  final List<(String, Uint8List)> _held = [];
  static const int _maxHeld = 256;

  CarrierChannel? _channel;
  bool _started = false;
  int _generation = 0;
  String? _lastError;

  @override
  TransportCapabilities get capabilities => TransportCapabilities(
    requiresPeerOnline: false,
    supportsStoreForward: path == TransportPathKind.storeForward,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: false,
    reportsPath: true,
    maximumPayloadBytes: framing.maxEnvelopeBytes,
    sendAttemptTimeout: sendAttemptTimeout,
  );

  CarrierChannel? get channel => _channel;

  /// This device's address, or null while the carrier is not ready.
  String? get localAddress => _channel?.localAddress;

  CarrierStatus get status => CarrierStatus(
    kind: kind,
    ready: _channel?.localAddress != null,
    address: _channel?.localAddress,
    lastError: _lastError,
  );

  Stream<CarrierStatus> get statusChanges => _status.stream;

  /// Uses [channel] from now on; a running carrier opens it.
  void attach(CarrierChannel channel) {
    _channel = channel;
    _lastError = null;
    _generation++;
    unawaited(_frameAckSubscription?.cancel());
    _frameAckSubscription = channel is AcknowledgingCarrierChannel
        ? channel.frameAcks.listen(_onFrameAck)
        : null;
    if (_started && channel is ManagedCarrierChannel) channel.start();
    _emitStatus();
  }

  /// Stops using the current channel; held frames are dropped.
  Future<void> detach() async {
    _generation++;
    final previous = _channel;
    _channel = null;
    await _frameAckSubscription?.cancel();
    _frameAckSubscription = null;
    _unconfirmedFrames.clear();
    if (previous case final ManagedCarrierChannel managed) {
      await managed.stop();
    }
    _held.clear();
    _emitStatus();
  }

  /// Records a network error for the status line.
  void reportError(String? error) {
    _lastError = error;
    _emitStatus();
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (_channel case final ManagedCarrierChannel managed) managed.start();
    final held = List.of(_held);
    _held.clear();
    for (final (sender, frame) in held) {
      receiveFrame(sender, frame);
    }
  }

  @override
  Future<void> stop() async {
    _started = false;
    _generation++;
    if (_channel case final ManagedCarrierChannel managed) {
      await managed.stop();
    }
  }

  /// A frame the channel received from [sender] (as the network names it).
  void receiveFrame(String sender, Uint8List frame) {
    if (!_started || _channel == null) {
      if (_held.length >= _maxHeld) _held.removeAt(0);
      _held.add((sender, frame));
      return;
    }
    unawaited(
      _receive(sender, frame, _generation).catchError((Object _) {
        // An unreadable frame is dropped.
      }),
    );
  }

  @override
  Stream<RouteCandidate> get pathChanges => _paths.stream;

  @override
  Stream<TransportInboundEnvelope> get inboundEnvelopes => _inbound.stream;

  @override
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer) async {
    final channel = _channel;
    final address = peer.transportAddresses[kind];
    if (channel == null ||
        channel.localAddress == null ||
        address == null ||
        !_isValidAddress(address)) {
      return const <RouteCandidate>[];
    }
    return [
      RouteCandidate(
        transport: kind,
        path: path,
        routeId: '${kind.name}:$address',
        label: '${kind.label} (${channel.routeLabel})',
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
    final channel = _channel;
    final address = peer.transportAddresses[kind];
    if (channel == null || address == null || !_isValidAddress(address)) {
      throw StateError('${kind.label} is not available for this contact.');
    }
    final generation = _generation;
    final startedAt = _now();
    final sendId = carrierSendId(peer.deviceId, envelope.id);
    final sealed = await _sealer.seal(kind, peer.deviceId, envelope.bytes);
    final frames = carrierBinaryFrames(framing, sealed, random: _random);
    // A first request over a channel with inboxes: decided per envelope,
    // so other envelopes to the same address meanwhile are not affected.
    final sealer = _sealer;
    final random = _random ?? Random.secure();
    final inboxKey =
        channel is InboxCarrierChannel && sealer is InboxCarrierSealer
        ? (sealer as InboxCarrierSealer).inboxKeyFor(sealed)
        : null;
    final inboxSender = inboxKey == null
        ? null
        : Uint8List.fromList(List.generate(8, (_) => random.nextInt(256)));
    // Registered before the first frame: confirmations of early frames
    // can come while later ones are still going out.
    final pending = _RadioEnvelope(envelope.id, peer.deviceId);
    // A burst that cannot get its turns in time is refused before the first
    // frame goes out, so no half-sent envelope is left behind.
    final turns = channelPacesFrames ? null : limiter;
    // The registry gives up on this attempt after [sendAttemptTimeout]: the
    // limiter's waits end before that, so a send is never cut off (and
    // marked failed) while it only waits for its turn.
    final attemptWatch = Stopwatch()..start();
    Duration timeLeft() {
      final left = sendAttemptTimeout - attemptWatch.elapsed - _attemptMargin;
      return left.isNegative ? Duration.zero : left;
    }

    if (turns != null) {
      final wait = turns.projectedWaitFor(
        frames.length,
        cost: turns.budget.costInBytes
            ? frames.fold<int>(0, (total, frame) => total + airBytes(frame))
            : 1,
      );
      if (wait > _admissionWait(turns, timeLeft())) {
        throw LimiterRefused(LimiterRefusal.wouldWait, retryIn: wait);
      }
    }
    // Stops a frame that waited for its turn after the send was cancelled.
    Future<T> Function() guarded<T>(Future<T> Function() send) => () {
      if (_cancelled[sendId] case final cancelledAt?
          when !cancelledAt.isBefore(startedAt)) {
        throw TransportSendCancelled('${kind.label}: no longer needed.');
      }
      return send();
    };
    for (var index = 0; index < frames.length; index++) {
      if (index > 0 && frameSpacing > Duration.zero) {
        await Future<void>.delayed(frameSpacing);
      }
      // Turned off or switched to another channel meanwhile: send no more.
      if (!_started || generation != _generation) {
        throw StateError('${kind.label} stopped while sending.');
      }
      // Its receipt came by another route: the rest of the airtime is
      // saved.
      if (_cancelled[sendId] case final cancelledAt?
          when !cancelledAt.isBefore(startedAt)) {
        throw TransportSendCancelled('${kind.label}: no longer needed.');
      }
      if (channel is AcknowledgingCarrierChannel) {
        final id = await _paced(
          guarded(() => channel.sendTrackedFrame(address, frames[index])),
          cost: airBytes(frames[index]),
          started: index > 0,
          timeLeft: timeLeft(),
        );
        if (id == 0) {
          // No ack code (a radio that does not confirm this kind of
          // message): not tracked, and the envelope is never "delivered".
          pending.unconfirmable = true;
        } else {
          pending.tracked = true;
          pending.waiting.add(id);
          _unconfirmedFrames.remove(id);
          _unconfirmedFrames[id] = pending;
          while (_unconfirmedFrames.length > _maxUnconfirmedFrames) {
            _unconfirmedFrames.remove(_unconfirmedFrames.keys.first);
          }
          // Its confirmation beat the send's own return.
          final early = _takeEarlyAck(id);
          if (early != null) _onFrameAck((frameId: id, ok: early));
        }
      } else if (inboxSender != null) {
        await _paced(
          cost: airBytes(frames[index]),
          started: index > 0,
          timeLeft: timeLeft(),
          guarded(
            () => (channel as InboxCarrierChannel).sendInboxFrame(
              address,
              frames[index],
              inboxSender,
              inboxKey!,
            ),
          ),
        );
      } else {
        await _paced(
          guarded(() => channel.sendFrame(address, frames[index])),
          cost: airBytes(frames[index]),
          started: index > 0,
          timeLeft: timeLeft(),
        );
      }
    }
    pending.allSent = true;
    _maybeReceipt(pending);
    return DeliveryReceipt(
      state: path == TransportPathKind.storeForward
          ? DeliveryReceiptState.storedForPeer
          : DeliveryReceiptState.acceptedByTransport,
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
    detail: '${kind.label} carries messages, not file streams.',
  );

  /// One frame, when the account's limiter lets it go; a server's
  /// "slow down" in the error is obeyed by the limiter.
  Future<T> _paced<T>(
    Future<T> Function() send, {
    int cost = 1,
    bool started = false,
    required Duration timeLeft,
  }) {
    final turns = channelPacesFrames ? null : limiter;
    if (turns == null) return send();
    // An envelope that has begun is finished, not dropped half-way, but not
    // past the attempt's end.
    final wait = started ? const Duration(minutes: 10) : turns.budget.maxWait;
    return turns.run(
      send,
      cost: turns.budget.costInBytes ? cost : 1,
      maxWait: wait < timeLeft ? wait : timeLeft,
    );
  }

  static const Duration _attemptMargin = Duration(seconds: 2);

  /// The longest an envelope may be held back before its first frame: the
  /// budget's wait, and for an airtime budget the time the largest sealed
  /// envelope needs (a long message on a radio waits for its minutes
  /// instead of being refused), never past the attempt.
  Duration _admissionWait(NetworkLimiter turns, Duration timeLeft) {
    var allowed = turns.budget.maxWait;
    final quota = turns.budget.quota;
    if (turns.budget.costInBytes && quota != null && quota > 0) {
      // Counted in bytes on air of the largest framed envelope (the
      // channel may encode frames, as MeshCore's base64 does).
      final count = framing.frameCount(framing.maxSealedBytes);
      final lastChunk =
          framing.maxSealedBytes - (count - 1) * framing.chunkBytes;
      final air =
          (count - 1) *
              _airLength(framing.chunkBytes + carrierBinaryFrameHeaderBytes) +
          _airLength(lastChunk + carrierBinaryFrameHeaderBytes);
      allowed += turns.budget.window * ((air - 1) ~/ quota);
    }
    return allowed < timeLeft ? allowed : timeLeft;
  }

  @override
  Future<void> cancel(String operationId) async {
    _cancelled.remove(operationId);
    _cancelled[operationId] = _now();
    while (_cancelled.length > _maxCancelled) {
      _cancelled.remove(_cancelled.keys.first);
    }
  }

  /// The bytes on air for [frame] (the channel may encode it).
  int airBytes(Uint8List frame) => _airLength(frame.length);

  int _airLength(int frameLength) {
    final channel = _channel;
    return channel is AirtimeSizedCarrierChannel
        ? channel.airBytes(frameLength)
        : frameLength;
  }

  /// Confirmations that came before their frame was registered (bounded,
  /// and forgotten after [earlyAckLife]).
  final Map<int, (bool, DateTime)> _earlyFrameAcks = {};
  static const Duration earlyAckLife = Duration(seconds: 30);

  bool? _takeEarlyAck(int id) {
    final entry = _earlyFrameAcks.remove(id);
    if (entry == null) return null;
    return _now().difference(entry.$2) > earlyAckLife ? null : entry.$1;
  }

  void _onFrameAck(({int frameId, bool ok}) ack) {
    final entry = _unconfirmedFrames.remove(ack.frameId);
    if (entry == null) {
      final now = _now();
      _earlyFrameAcks.removeWhere(
        (_, early) => now.difference(early.$2) > earlyAckLife,
      );
      _earlyFrameAcks.remove(ack.frameId);
      _earlyFrameAcks[ack.frameId] = (ack.ok, now);
      while (_earlyFrameAcks.length > 32) {
        _earlyFrameAcks.remove(_earlyFrameAcks.keys.first);
      }
      return;
    }
    if (!ack.ok) {
      entry.refused = true;
      return;
    }
    entry.waiting.remove(ack.frameId);
    _maybeReceipt(entry);
  }

  void _maybeReceipt(_RadioEnvelope entry) {
    // Untracked: a channel that does not confirm frames.
    if (!entry.tracked ||
        entry.unconfirmable ||
        !entry.allSent ||
        entry.refused ||
        entry.reported ||
        entry.waiting.isNotEmpty) {
      return;
    }
    entry.reported = true;
    _receipts.add(
      CarrierDeliveryReceipt(
        kind: kind,
        envelopeId: entry.envelopeId,
        deviceId: entry.deviceId,
      ),
    );
  }

  Future<void> _receive(String sender, Uint8List frame, int generation) async {
    // A single-frame envelope is never buffered: it goes straight to open,
    // which keeps only what it can authenticate. Only frames that would
    // wait in the reassembly buffer need a known (or budgeted) sender, so
    // junk from strangers cannot crowd out a first-contact request.
    final singleFrame =
        frame.length > carrierBinaryFrameHeaderBytes &&
        frame[0] == carrierBinaryFrameVersion &&
        frame[10] == 1;
    if (!singleFrame && !_sealer.acceptsSender(kind, sender)) return;
    final sealed = _reassembler.addBinary(sender, frame);
    if (sealed == null) return;
    final opened = await _sealer.open(kind, sender, sealed);
    if (opened == null) return;
    if (generation != _generation) {
      throw StateError('${kind.label} carrier stopped while receiving.');
    }
    _inbound.add(
      TransportInboundEnvelope(
        transport: kind,
        path: path,
        senderTransportIdentity: opened.peerDeviceId,
        bytes: opened.envelope,
        receivedAt: _now().toUtc(),
      ),
    );
  }

  void _emitStatus() {
    if (!_status.isClosed) _status.add(status);
  }
}

/// Longest carrier address accepted from a contact.
const int maxCarrierAddressLength = 4096;

/// A carrier address a contact may advertise: non-empty, bounded, printable.
bool isPlausibleCarrierAddress(String address) =>
    address.isNotEmpty &&
    address.length <= maxCarrierAddressLength &&
    !address.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

/// The part of a carrier address that names the sender on the network: the
/// text before the first `|` (the rest holds routing hints such as relays).
String carrierSenderIdentity(String address) {
  final split = address.indexOf('|');
  return split < 0 ? address : address.substring(0, split);
}
