import 'dart:async';
import 'dart:collection';
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

/// The keys contact pairs derive their mesh ids and MACs from, looked up by
/// the contact's mesh address: one per contact with that address (normally
/// one), none for no contact.
typedef BitchatKeyLookup = Future<List<Uint8List>> Function(String address);

enum BitchatCarrierState { stopped, starting, running, failed }

/// The ids and MAC key one contact pair uses on the air. Each pair's ids
/// change at its own minute of the hour, so pairs do not all change
/// together.
class _Pair {
  _Pair(this.address, this.key)
    : offset =
          ByteData.sublistView(
            Uint8List.fromList(
              Hmac(
                sha256,
                key,
              ).convert(utf8.encode('conest.bitchat.offset')).bytes,
            ),
          ).getUint32(0) %
          bitchatIdPeriod.inMilliseconds;

  final String address;
  final Uint8List key;
  final int offset;

  int period(int milliseconds) =>
      (milliseconds + offset) ~/ bitchatIdPeriod.inMilliseconds;
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

  Map<String, List<_Pair>> _pairs = {};
  Set<String> _peerAddresses = const {};
  bool _reloading = false;
  bool _reloadAgain = false;
  StreamSubscription<String?>? _problems;

  /// Recipient id (hex) → the pair it belongs to and its period, for the
  /// periods around the minute [_tableMinute].
  Map<String, (_Pair, int)> _table = const {};
  int? _tableMinute;

  /// MACs of frames already read, so a replay is not read twice even after
  /// relays have forgotten it. Only authentic frames get in, so strangers
  /// cannot flush it.
  final LinkedHashSet<String> _readMacs = LinkedHashSet();
  static const int _maxReadMacs = 16384;

  BitchatCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress => config.address;

  @override
  String get routeLabel => 'nearby phones';

  @override
  void updatePeers(Set<String> addresses) {
    // Settings are saved often: reloads run one at a time, and calls during
    // one only mark that another is needed, which then uses the latest set.
    // Every reload reads keys afresh, so re-keyed contacts are picked up.
    _peerAddresses = {...addresses};
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    _reloading = true;
    unawaited(() async {
      do {
        _reloadAgain = false;
        final wanted = _peerAddresses;
        final next = <String, List<_Pair>>{};
        for (final address in wanted) {
          try {
            final keys = await _keyFor(address);
            if (keys.isNotEmpty) {
              next[address] = [for (final key in keys) _Pair(address, key)];
            }
          } catch (_) {
            // That contact is skipped until the next reload.
          }
        }
        _pairs = next;
        _tableMinute = null;
      } while (_reloadAgain);
      _reloading = false;
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
        _problems = links.problems.listen((problem) {
          _lastError = problem;
          onStatusChanged?.call();
        });
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
    await _problems?.cancel();
    _problems = null;
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
    var pairs = _pairs[address];
    if (pairs == null) {
      final keys = await _keyFor(address);
      if (keys.isEmpty) throw StateError('No contact has this mesh address.');
      pairs = [for (final key in keys) _Pair(address, key)];
    }
    final timestamp = _now().millisecondsSinceEpoch;
    // Normally one pair; when contacts share an address, the frame goes to
    // each and only the right one can read it.
    for (final pair in pairs) {
      final period = pair.period(timestamp);
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
          // bitchat signs its private packets but nobody checks their
          // signatures; random bytes make these look the same.
          signature: randomBitchatBytes(64),
        ),
      );
    }
  }

  BitchatPrivate _private(BitchatPacket packet, Uint8List payload) {
    final now = _now().millisecondsSinceEpoch;
    final entry = _recipients(now)[hexEncode(packet.recipientId!)];
    if (entry == null) return BitchatPrivate.notMine;
    final (pair, period) = entry;
    if (!_equal(packet.senderId, _id(pair.key, 's', pair.address, period)) ||
        payload.length <= _macBytes) {
      // Addressed to this device but not from the contact: not relayed.
      return BitchatPrivate.rejected;
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
      final key = hexEncode(mac);
      if (!_readMacs.add(key)) return BitchatPrivate.rejected;
      if (_readMacs.length > _maxReadMacs) _readMacs.remove(_readMacs.first);
      onFrame(pair.address, frame);
      return BitchatPrivate.accepted;
    }
    return BitchatPrivate.rejected;
  }

  /// Ids this device answers to, for each pair's current period and its
  /// neighbours (clocks differ); rebuilt every minute.
  Map<String, (_Pair, int)> _recipients(int now) {
    final minute = now ~/ 60000;
    if (_tableMinute == minute) return _table;
    _table = {
      for (final pair in _pairs.values.expand((pairs) => pairs))
        for (final candidate in [
          pair.period(now) - 1,
          pair.period(now),
          pair.period(now) + 1,
        ])
          hexEncode(_id(pair.key, 'r', config.address, candidate)): (
            pair,
            candidate,
          ),
    };
    _tableMinute = minute;
    return _table;
  }

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
