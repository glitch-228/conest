import 'dart:async';
import 'dart:collection';
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
    this.onPacket,
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

  /// Whether a recipient id is one of this device's: fragments sent to it
  /// are not relayed, and what they carry is.
  final bool Function(Uint8List recipientId)? wantsRecipient;

  /// Every other packet that reaches this device (announces, handshakes),
  /// including packets put back together from fragments. False means its
  /// signature failed against a known key: that copy is neither
  /// remembered nor passed on, so the genuine packet still gets through.
  final Future<bool> Function(BitchatPacket packet)? onPacket;

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
    await _sendFitting(packet, packet.encode());
  }

  /// Neighbours that can carry packets, and the largest each takes.
  Map<String, int> _usableLinks(String? except) => {
    for (final MapEntry(key: link, value: limit) in _links.linkLimits.entries)
      if (link != except && limit >= bitchatMinLinkLimit)
        link: min(limit, maxPacketBytes),
  };

  /// Sends [encoded] ([packet]) to every neighbour but [except]. A packet
  /// bigger than the smallest link goes once as fragments that fit every
  /// link; a fragment is never cut up again, and only goes where it fits.
  Future<void> _sendFitting(
    BitchatPacket packet,
    Uint8List encoded, {
    String? except,
  }) async {
    final links = _usableLinks(except);
    if (links.isEmpty) {
      // Own packets fail here when no neighbour is there.
      await _links.broadcast(encoded, except: except);
      return;
    }
    final smallest = links.values.reduce(min);
    if (encoded.length <= smallest) {
      await _links.broadcast(encoded, except: except);
      return;
    }
    if (packet.type == BitchatType.fragment) {
      for (final MapEntry(key: link, value: limit) in links.entries) {
        if (encoded.length > limit) continue;
        try {
          await _links.sendTo(link, encoded);
        } catch (_) {}
      }
      return;
    }
    final List<BitchatPacket> fragments;
    try {
      fragments = bitchatFragmentsFor(packet, maxPacketBytes: smallest);
    } catch (_) {
      return;
    }
    for (final fragment in fragments) {
      _remember(fragment.dedupKey);
      await _links.broadcast(fragment.encode(), except: except);
    }
  }

  Future<void> _handle(
    String link,
    Uint8List raw, {
    bool reassembled = false,
    bool relayReassembled = false,
    int? expectedType,
  }) async {
    final packet = BitchatPacket.decode(raw);
    if (packet == null) return;
    if (expectedType != null && packet.type != expectedType) return;
    final skew = _now().millisecondsSinceEpoch - packet.timestamp;
    if (skew.abs() > bitchatClockWindow.inMilliseconds) return;
    final key = packet.dedupKey;
    if (_seen.contains(key)) return;
    if (packet.type == BitchatType.noiseEncrypted &&
        packet.recipientId != null) {
      final payload = packet.compressed
          ? bitchatInflate(packet.payload, packet.version)
          : packet.payload;
      final kind = payload == null
          ? BitchatPrivate.notMine
          : onPrivate(packet, payload);
      if (kind == BitchatPrivate.accepted) _remember(key);
      if (kind != BitchatPrivate.notMine) return;
    }
    if (packet.type == BitchatType.fragment) {
      // Fragments to this device are not passed on; the packet they make
      // is, if it is not for this device.
      final toMe =
          packet.recipientId != null &&
          (wantsRecipient?.call(packet.recipientId!) ?? false);
      if (toMe || packet.ttl == 0) _remember(key);
      final whole = _reassembler.add(packet);
      if (whole != null) {
        await _handle(
          link,
          whole.$1,
          reassembled: true,
          relayReassembled: toMe,
          expectedType: whole.$2,
        );
      }
      if (toMe) return;
    } else if (onPacket != null && packet.type != BitchatType.noiseEncrypted) {
      if (!await onPacket!(packet)) return;
    }
    // A packet put back together here is relayed only when its fragments
    // were not (they were addressed to this device).
    if (reassembled && !relayReassembled) return;
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
}

/// Random bytes, for a new mesh address.
Uint8List randomBitchatBytes(int length, [Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => source.nextInt(256)));
}
