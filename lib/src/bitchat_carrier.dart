import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bitchat/mesh.dart';
import 'bitchat/packet.dart';
import 'carrier.dart';
import 'nostr/secp256k1.dart' show hexEncode;
import 'transport_models.dart';

/// Bytes of the MAC closing each Conest packet.
const int _macBytes = 8;

/// Frames sized so a bitchat packet never needs fragmenting; envelopes up
/// to 16 KiB.
const CarrierFraming bitchatCarrierFraming = CarrierFraming(
  maxSealedBytes: 16 * 1024,
  chunkBytes: bitchatPayloadBytes - _macBytes - carrierBinaryFrameHeaderBytes,
);

/// How long the ids of a pair of contacts stay the same on the air.
const Duration bitchatIdPeriod = Duration(hours: 1);

const String _addressPrefix = 'bc1:';

/// A device's address on the Bluetooth mesh: a random id, sent only to
/// contacts and never over the air. What goes over the air are ids derived
/// from it and the pair's key, which change every [bitchatIdPeriod].
bool isValidBitchatAddress(String address) =>
    address.length == _addressPrefix.length + 32 &&
    address.startsWith(_addressPrefix) &&
    RegExp(
      r'^[0-9a-f]{32}$',
    ).hasMatch(address.substring(_addressPrefix.length));

/// The saved Bluetooth mesh setup: this device's mesh address.
class BitchatCarrierConfig {
  const BitchatCarrierConfig({required this.address});

  /// A new address, so turning the mesh off and on again unlinks the past.
  factory BitchatCarrierConfig.create() => BitchatCarrierConfig(
    address: '$_addressPrefix${hexEncode(randomBitchatBytes(16))}',
  );

  final String address;

  Map<String, Object?> toJson() => {'address': address};

  static BitchatCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final address = json['address'];
    if (address is! String || !isValidBitchatAddress(address)) return null;
    return BitchatCarrierConfig(address: address);
  }
}

typedef BitchatConnector = Future<BitchatLinkLayer> Function();

/// The key a pair of contacts derives its mesh ids and MACs from, looked up
/// by the contact's mesh address; null for no contact.
typedef BitchatKeyLookup = Future<Uint8List?> Function(String address);

enum BitchatCarrierState { stopped, starting, running, failed }

/// The ids and MAC key one contact pair uses on the air.
class _Pair {
  _Pair(this.address, this.key);
  final String address;
  final Uint8List key;
}

/// The Bluetooth mesh side of the carrier: a bitchat mesh node that relays
/// for its neighbours and carries Conest frames to Conest peers.
///
/// Each frame travels as a bitchat private (Noise-type) packet whose sender
/// and recipient ids are derived from the pair's key, this hour and each
/// side's address, followed by a MAC over the ids, time and frame. Relays
/// and bitchat users see unrelated ids that change every hour, which they
/// cannot tell apart from bitchat's own private messages or link to a
/// device; only the contact can recognise and check them.
class BitchatCarrierChannel
    implements ManagedCarrierChannel, PeerAwareCarrierChannel {
  BitchatCarrierChannel({
    required this.config,
    required BitchatConnector connector,
    required BitchatKeyLookup keyFor,
    required this.onFrame,
    this.onStatusChanged,
    DateTime Function()? now,
  }) : _connector = connector,
       _keyFor = keyFor,
       _now = now ?? DateTime.now;

  final BitchatCarrierConfig config;
  final BitchatConnector _connector;
  final BitchatKeyLookup _keyFor;
  final DateTime Function() _now;

  /// A frame from the contact whose mesh address is [sender].
  final void Function(String sender, Uint8List frame) onFrame;
  final void Function()? onStatusChanged;

  BitchatNode? _node;
  BitchatLinkLayer? _links;
  BitchatCarrierState _state = BitchatCarrierState.stopped;
  String? _lastError;
  int _generation = 0;

  final Map<String, _Pair> _pairs = {};
  int _peersVersion = 0;

  /// Recipient id (hex) → the pair it belongs to and its period, for the
  /// periods around [_tablePeriod].
  Map<String, (_Pair, int)> _table = const {};
  int? _tablePeriod;

  BitchatCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress => config.address;

  @override
  String get routeLabel => 'nearby phones';

  @override
  void updatePeers(Set<String> addresses) {
    final version = ++_peersVersion;
    _pairs.removeWhere((address, _) => !addresses.contains(address));
    _tablePeriod = null;
    unawaited(() async {
      for (final address in addresses) {
        if (_pairs.containsKey(address)) continue;
        final key = await _keyFor(address);
        if (version != _peersVersion) return;
        if (key != null) _pairs[address] = _Pair(address, key);
      }
      _tablePeriod = null;
    }());
  }

  @override
  void start() {
    if (_state != BitchatCarrierState.stopped &&
        _state != BitchatCarrierState.failed) {
      return;
    }
    final generation = ++_generation;
    _setState(BitchatCarrierState.starting);
    unawaited(() async {
      try {
        final links = await _connector();
        if (generation != _generation) {
          await links.close();
          return;
        }
        _links = links;
        _node = BitchatNode(links: links, onPrivate: _private, now: _now);
        _lastError = null;
        _setState(BitchatCarrierState.running);
      } catch (error) {
        if (generation != _generation) return;
        _lastError = '$error';
        _setState(BitchatCarrierState.failed);
      }
    }());
  }

  @override
  Future<void> stop() async {
    _generation++;
    final node = _node;
    final links = _links;
    _node = null;
    _links = null;
    await node?.stop();
    await links?.close();
    _setState(BitchatCarrierState.stopped);
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    final node = _node;
    if (node == null) throw StateError('The Bluetooth mesh is not running.');
    if (!isValidBitchatAddress(address)) {
      throw ArgumentError('Not a Bluetooth mesh address.');
    }
    if (frame.length + _macBytes > bitchatPayloadBytes) {
      throw ArgumentError('The frame is too large for one bitchat packet.');
    }
    var pair = _pairs[address];
    if (pair == null) {
      final key = await _keyFor(address);
      if (key == null) throw StateError('No contact has this mesh address.');
      pair = _Pair(address, key);
    }
    final timestamp = _now().millisecondsSinceEpoch;
    final period = _period(timestamp);
    final sender = _id(pair.key, 's', config.address, period);
    final recipient = _id(pair.key, 'r', address, period);
    await node.send(
      BitchatPacket(
        type: BitchatType.noiseEncrypted,
        senderId: sender,
        recipientId: recipient,
        timestamp: timestamp,
        payload: Uint8List.fromList([
          ...frame,
          ..._mac(pair.key, sender, recipient, timestamp, frame),
        ]),
      ),
    );
  }

  bool _private(BitchatPacket packet, Uint8List payload) {
    final now = _now().millisecondsSinceEpoch;
    final entry = _recipients(_period(now))[hexEncode(packet.recipientId!)];
    if (entry == null) return false;
    final (pair, period) = entry;
    if (!_equal(packet.senderId, _id(pair.key, 's', pair.address, period)) ||
        payload.length <= _macBytes) {
      // Addressed to this device but not from the contact: not relayed.
      return true;
    }
    final frame = Uint8List.sublistView(payload, 0, payload.length - _macBytes);
    final mac = Uint8List.sublistView(payload, payload.length - _macBytes);
    if (_equal(
      mac,
      _mac(
        pair.key,
        packet.senderId,
        packet.recipientId!,
        packet.timestamp,
        frame,
      ),
    )) {
      onFrame(pair.address, frame);
    }
    return true;
  }

  /// Ids this device answers to, for the current period and its
  /// neighbours (clocks differ).
  Map<String, (_Pair, int)> _recipients(int period) {
    if (_tablePeriod == period) return _table;
    _table = {
      for (final pair in _pairs.values)
        for (final candidate in [period - 1, period, period + 1])
          hexEncode(_id(pair.key, 'r', config.address, candidate)): (
            pair,
            candidate,
          ),
    };
    _tablePeriod = period;
    return _table;
  }

  static int _period(int milliseconds) =>
      milliseconds ~/ bitchatIdPeriod.inMilliseconds;

  /// An 8-byte id: [role] `s` names the sender with its own [address], `r`
  /// the recipient with its.
  static Uint8List _id(
    List<int> key,
    String role,
    String address,
    int period,
  ) => Uint8List.fromList(
    Hmac(sha256, key)
        .convert(utf8.encode('conest.bitchat.id|$role|$address|$period'))
        .bytes
        .sublist(0, 8),
  );

  static Uint8List _mac(
    List<int> key,
    List<int> sender,
    List<int> recipient,
    int timestamp,
    List<int> frame,
  ) {
    final time = ByteData(8)..setUint64(0, timestamp);
    return Uint8List.fromList(
      Hmac(sha256, key)
          .convert([
            ...utf8.encode('conest.bitchat.mac'),
            ...sender,
            ...recipient,
            ...time.buffer.asUint8List(),
            ...frame,
          ])
          .bytes
          .sublist(0, _macBytes),
    );
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var index = 0; index < a.length; index++) {
      difference |= a[index] ^ b[index];
    }
    return difference == 0;
  }

  void _setState(BitchatCarrierState state) {
    if (_state == state) return;
    _state = state;
    onStatusChanged?.call();
  }
}

/// A Bluetooth mesh carrier adapter.
CarrierTransportAdapter createBitchatCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.bitchat,
  sealer: sealer,
  framing: bitchatCarrierFraming,
  frameSpacing: const Duration(milliseconds: 60),
  sendAttemptTimeout: const Duration(seconds: 90),
  isValidAddress: isValidBitchatAddress,
  now: now,
);
