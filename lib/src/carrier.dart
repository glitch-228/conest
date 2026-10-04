import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
  }) : _now = now ?? DateTime.now;

  final CarrierFraming framing;
  final DateTime Function() _now;
  final Duration expiry;
  final int maxPending;
  final int maxPendingPerSender;
  final Map<String, _PendingEnvelope> _pending = {};

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
class CarrierTransportAdapter implements TransportAdapter {
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
  }) : _sealer = sealer,
       _isValidAddress = isValidAddress ?? isPlausibleCarrierAddress,
       _now = now ?? DateTime.now,
       _random = random,
       _reassembler = CarrierReassembler(framing: framing, now: now);

  @override
  final TransportKind kind;
  final CarrierFraming framing;
  final TransportPathKind path;
  final Duration sendAttemptTimeout;

  /// Pause between frames of one envelope, for networks that rate-limit.
  final Duration frameSpacing;
  final CarrierSealer _sealer;
  final bool Function(String address) _isValidAddress;
  final DateTime Function() _now;
  final Random? _random;
  final CarrierReassembler _reassembler;
  final _inbound = StreamController<TransportInboundEnvelope>.broadcast();
  final _paths = StreamController<RouteCandidate>.broadcast();
  final _status = StreamController<CarrierStatus>.broadcast();

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

  /// Uses [channel] from now on.
  void attach(CarrierChannel channel) {
    _channel = channel;
    _lastError = null;
    _generation++;
    _emitStatus();
  }

  /// Stops using the current channel; held frames are dropped.
  void detach() {
    _generation++;
    _channel = null;
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
    final sealed = await _sealer.seal(kind, peer.deviceId, envelope.bytes);
    final frames = carrierBinaryFrames(framing, sealed, random: _random);
    for (var index = 0; index < frames.length; index++) {
      if (index > 0 && frameSpacing > Duration.zero) {
        await Future<void>.delayed(frameSpacing);
      }
      await channel.sendFrame(address, frames[index]);
    }
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

  @override
  Future<void> cancel(String operationId) async {}

  Future<void> _receive(String sender, Uint8List frame, int generation) async {
    if (!_sealer.acceptsSender(kind, sender)) return;
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
