import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'fragment.dart';
import 'packet.dart';

/// The Bluetooth side of the mesh: every connected neighbour, as links that
/// carry whole bitchat packets.
abstract interface class BitchatLinkLayer {
  /// Packets from neighbours, with the link they came on.
  Stream<(String, Uint8List)> get received;

  /// Sends [packet] to every neighbour except the link [except]. A packet
  /// of this device's own (no [except]) fails when no neighbour is there.
  Future<void> broadcast(Uint8List packet, {String? except});

  /// Why the mesh cannot work right now (such as Bluetooth being off), or
  /// null once it can again.
  Stream<String?> get problems;

  /// The largest packet each connected neighbour takes in one write, by
  /// link. Links that take less than a packet get it as fragments.
  Map<String, int> get linkLimits;

  /// Sends [packet] to the neighbour on [link] only.
  Future<void> sendTo(String link, Uint8List packet);

  Future<void> close();
}

/// What a private packet addressed to someone turned out to be.
enum BitchatPrivate {
  /// For another device: relay it.
  notMine,

  /// For this device, read.
  accepted,

  /// Addressed to this device but not authentic: dropped, and not
  /// remembered, so the genuine packet still gets through.
  rejected,
}

/// Largest Conest payload per packet: with the header, both ids and a
/// signature, small enough that bitchat never needs to fragment the packet
/// (512-byte BLE frames with padding).
const int bitchatPayloadBytes = 400;

/// Packet types relayed for others: bitchat's own. Anything else is
/// dropped rather than flooded.
const Set<int> _relayedTypes = {
  BitchatType.announce,
  BitchatType.message,
  BitchatType.leave,
  BitchatType.noiseHandshake,
  BitchatType.noiseEncrypted,
  BitchatType.fragment,
  0x21, // sync request
  0x22, // file transfer
};

/// Packets further than this from the local clock are neither relayed nor
/// read, so old packets cannot come back once forgotten.
const Duration bitchatClockWindow = Duration(minutes: 10);

/// A bitchat mesh participant: relays other peers' packets (bitchat's
/// flooding with TTL) and sends and receives private packets. It never
/// announces itself, so nothing on the air names or tracks this device.
class BitchatNode {
  BitchatNode({
    required BitchatLinkLayer links,
    required this.onPrivate,
    this.wantsRecipient,
    this.maxPacketBytes = 512,
    this.relay = true,
    DateTime Function()? now,
  }) : _links = links,
       _now = now ?? DateTime.now,
       _reassembler = BitchatReassembler(now: now) {
    _subscription = _links.received.listen(
      (event) =>
          unawaited(_handle(event.$1, event.$2).catchError((Object _) {})),
    );
  }

  final BitchatLinkLayer _links;
  final DateTime Function() _now;

  /// Relay other peers' packets, as every bitchat device does.
  final bool relay;

  /// A private packet with a recipient, with its payload expanded.
  final BitchatPrivate Function(BitchatPacket packet, Uint8List payload)
  onPrivate;

  /// Whether a recipient id is one of this device's, so fragments sent to
  /// it are put back together (others are only relayed).
  final bool Function(Uint8List recipientId)? wantsRecipient;

  /// Largest packet sent whole; bigger ones go as bitchat fragments.
  final int maxPacketBytes;

  final BitchatReassembler _reassembler;

  late final StreamSubscription<(String, Uint8List)> _subscription;
  final LinkedHashSet<String> _seen = LinkedHashSet();
  static const int _maxSeen = 8192;

  /// Relayed packets per minute, overall and per link, so neither a flood
  /// nor one noisy neighbour can use the radio forever.
  int _relayMinute = 0;
  int _relayedThisMinute = 0;
  final Map<String, int> _relayedByLink = {};
  static const int _maxRelaysPerMinute = 600;
  static const int _maxRelaysPerLinkPerMinute = 200;

  Future<void> stop() => _subscription.cancel();

  /// Sends a packet of this device's own.
  Future<void> send(BitchatPacket packet) async {
    _remember(packet.dedupKey);
    final encoded = packet.encode();
    if (encoded.length <= maxPacketBytes) {
      await _sendFitting(packet, encoded);
      return;
    }
    for (final fragment in bitchatFragmentsFor(
      packet,
      chunkBytes: maxPacketBytes - bitchatFragmentOverhead,
    )) {
      _remember(fragment.dedupKey);
      await _sendFitting(fragment, fragment.encode());
    }
  }

  /// Sends [encoded] ([packet]) to every neighbour but [except]: whole to
  /// links that take it, as fragments sized to the link to the others.
  Future<void> _sendFitting(
    BitchatPacket packet,
    Uint8List encoded, {
    String? except,
  }) async {
    final limits = _links.linkLimits;
    if (!limits.entries.any(
      (link) => link.key != except && link.value < encoded.length,
    )) {
      await _links.broadcast(encoded, except: except);
      return;
    }
    for (final MapEntry(key: link, value: limit) in limits.entries) {
      if (link == except) continue;
      try {
        if (limit >= encoded.length) {
          await _links.sendTo(link, encoded);
          continue;
        }
        for (final fragment in bitchatFragmentsFor(
          packet,
          chunkBytes: max(16, limit - bitchatFragmentOverhead),
        )) {
          _remember(fragment.dedupKey);
          await _links.sendTo(link, fragment.encode());
        }
      } catch (_) {
        // That neighbour is gone; the others still get it.
      }
    }
  }

  Future<void> _handle(
    String link,
    Uint8List raw, {
    bool reassembled = false,
  }) async {
    final packet = BitchatPacket.decode(raw);
    if (packet == null) return;
    final skew = _now().millisecondsSinceEpoch - packet.timestamp;
    if (skew.abs() > bitchatClockWindow.inMilliseconds) return;
    final key = packet.dedupKey;
    if (_seen.contains(key)) return;
    if (packet.type == BitchatType.noiseEncrypted &&
        packet.recipientId != null) {
      final payload = packet.compressed
          ? _inflate(packet.payload, packet.version)
          : packet.payload;
      final kind = payload == null
          ? BitchatPrivate.notMine
          : onPrivate(packet, payload);
      if (kind == BitchatPrivate.accepted) _remember(key);
      if (kind != BitchatPrivate.notMine) return;
    }
    // A packet put back together here is never relayed: its fragments were.
    if (reassembled) return;
    final recipient = packet.recipientId;
    if (packet.type == BitchatType.fragment &&
        recipient != null &&
        (wantsRecipient?.call(recipient) ?? false)) {
      _remember(key);
      final whole = _reassembler.add(packet);
      if (whole != null) await _handle(link, whole, reassembled: true);
      return;
    }
    // A copy that goes no further is not remembered: a copy sent with TTL 0
    // must not stop the original from being relayed.
    if (packet.ttl == 0) return;
    _remember(key);
    if (!relay ||
        !_relayedTypes.contains(packet.type) ||
        !_relayAllowed(link)) {
      return;
    }
    // Relay as received, with one hop less (byte 2 is the TTL), never
    // further than a fresh bitchat packet goes.
    final forward = Uint8List.fromList(raw)
      ..[2] = min(packet.ttl, bitchatDefaultTtl) - 1;
    await _sendFitting(packet.copyWith(ttl: forward[2]), forward, except: link);
  }

  bool _relayAllowed(String link) {
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    if (minute != _relayMinute) {
      _relayMinute = minute;
      _relayedThisMinute = 0;
      _relayedByLink.clear();
    }
    final byLink = (_relayedByLink[link] ?? 0) + 1;
    if (byLink > _maxRelaysPerLinkPerMinute ||
        _relayedThisMinute >= _maxRelaysPerMinute) {
      return false;
    }
    _relayedByLink[link] = byLink;
    _relayedThisMinute++;
    return true;
  }

  /// False when [key] was seen before.
  bool _remember(String key) {
    if (_seen.contains(key)) return false;
    _seen.add(key);
    if (_seen.length > _maxSeen) _seen.remove(_seen.first);
    return true;
  }

  /// A compressed payload: the original size, then raw deflate. Inflating
  /// stops as soon as it passes the stated size, so a small packet cannot
  /// expand into megabytes.
  static Uint8List? _inflate(Uint8List payload, int version) {
    final sizeBytes = version >= 2 ? 4 : 2;
    if (payload.length <= sizeBytes) return null;
    var size = 0;
    for (var index = 0; index < sizeBytes; index++) {
      size = (size << 8) | payload[index];
    }
    if (size == 0 || size > 2048) return null;
    final out = _BoundedSink(size);
    try {
      ZLibDecoder(raw: true).startChunkedConversion(out)
        ..add(Uint8List.sublistView(payload, sizeBytes))
        ..close();
    } catch (_) {
      bitchatInflatedBytes = out.bytes.length;
      return null;
    }
    final bytes = out.bytes.takeBytes();
    bitchatInflatedBytes = bytes.length;
    return bytes.length == size ? bytes : null;
  }
}

/// Random bytes, for a new mesh address.
Uint8List randomBitchatBytes(int length, [Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => source.nextInt(256)));
}

/// Bytes the last compressed payload expanded to before it was kept or
/// dropped; tests check that a bomb stops early.
int bitchatInflatedBytes = 0;

class _TooLarge implements Exception {}

/// Collects inflated bytes and throws once there are more than [limit].
class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.limit);

  final int limit;
  final bytes = BytesBuilder(copy: true);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) throw _TooLarge();
    bytes.add(chunk);
  }

  @override
  void close() {}
}
