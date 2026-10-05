import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'packet.dart';

/// The Bluetooth side of the mesh: every connected neighbour, as links that
/// carry whole bitchat packets.
abstract interface class BitchatLinkLayer {
  /// Packets from neighbours, with the link they came on.
  Stream<(String, Uint8List)> get received;

  /// Sends [packet] to every neighbour except the link [except].
  Future<void> broadcast(Uint8List packet, {String? except});

  Future<void> close();
}

/// Largest Conest payload per packet: small enough that bitchat never
/// needs to fragment the packet (512-byte BLE frames with padding).
const int bitchatPayloadBytes = 443;

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
    this.relay = true,
    DateTime Function()? now,
  }) : _links = links,
       _now = now ?? DateTime.now {
    _subscription = _links.received.listen(
      (event) =>
          unawaited(_handle(event.$1, event.$2).catchError((Object _) {})),
    );
  }

  final BitchatLinkLayer _links;
  final DateTime Function() _now;

  /// Relay other peers' packets, as every bitchat device does.
  final bool relay;

  /// A private packet with a recipient, with its payload expanded; returns
  /// true when it was for this device, which then does not relay it.
  final bool Function(BitchatPacket packet, Uint8List payload) onPrivate;

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
    await _links.broadcast(packet.encode());
  }

  Future<void> _handle(String link, Uint8List raw) async {
    final packet = BitchatPacket.decode(raw);
    if (packet == null) return;
    final skew = _now().millisecondsSinceEpoch - packet.timestamp;
    if (skew.abs() > bitchatClockWindow.inMilliseconds) return;
    if (!_remember(packet.dedupKey)) return;
    if (packet.type == BitchatType.noiseEncrypted &&
        packet.recipientId != null) {
      final payload = packet.compressed
          ? _inflate(packet.payload, packet.version)
          : packet.payload;
      if (payload != null && onPrivate(packet, payload)) return;
    }
    if (!relay ||
        packet.ttl == 0 ||
        !_relayedTypes.contains(packet.type) ||
        !_relayAllowed(link)) {
      return;
    }
    // Relay as received, with one hop less (byte 2 is the TTL), never
    // further than a fresh bitchat packet goes.
    final forward = Uint8List.fromList(raw)
      ..[2] = min(packet.ttl, bitchatDefaultTtl) - 1;
    await _links.broadcast(forward, except: link);
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

  /// A compressed payload: the original size, then raw deflate.
  static Uint8List? _inflate(Uint8List payload, int version) {
    final sizeBytes = version >= 2 ? 4 : 2;
    if (payload.length <= sizeBytes) return null;
    var size = 0;
    for (var index = 0; index < sizeBytes; index++) {
      size = (size << 8) | payload[index];
    }
    if (size == 0 || size > 4096) return null;
    try {
      final out = ZLibDecoder(
        raw: true,
      ).convert(Uint8List.sublistView(payload, sizeBytes));
      return out.length == size ? Uint8List.fromList(out) : null;
    } catch (_) {
      return null;
    }
  }
}

/// Random bytes, for a new mesh address.
Uint8List randomBitchatBytes(int length, [Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => source.nextInt(256)));
}
