import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'packet.dart';

/// bitchat's fragment chunk when a link's limit is unknown.
const int bitchatDefaultFragmentChunk = 469;

/// Bytes a fragment adds around its chunk: the packet header with sender
/// and recipient, and the fragment header.
const int bitchatFragmentOverhead = 42;

const int _fragmentHeaderBytes = 8 + 2 + 2 + 1;

/// One FRAGMENT (0x20) payload: a slice of a whole encoded packet.
class BitchatFragment {
  const BitchatFragment({
    required this.fragmentId,
    required this.index,
    required this.total,
    required this.originalType,
    required this.chunk,
  });

  final Uint8List fragmentId;
  final int index;
  final int total;
  final int originalType;
  final Uint8List chunk;

  Uint8List encode() {
    final out = BytesBuilder(copy: false)
      ..add(fragmentId)
      ..add([index >> 8, index & 0xff, total >> 8, total & 0xff])
      ..addByte(originalType)
      ..add(chunk);
    return out.takeBytes();
  }

  static BitchatFragment? decode(Uint8List payload) {
    if (payload.length <= _fragmentHeaderBytes) return null;
    final index = (payload[8] << 8) | payload[9];
    final total = (payload[10] << 8) | payload[11];
    if (total == 0 || index >= total) return null;
    return BitchatFragment(
      fragmentId: Uint8List.fromList(payload.sublist(0, 8)),
      index: index,
      total: total,
      originalType: payload[12],
      chunk: Uint8List.sublistView(payload, _fragmentHeaderBytes),
    );
  }
}

/// Splits [original] into FRAGMENT packets whose chunks are at most
/// [chunkBytes] of its whole encoded (padded) form, as bitchat does for
/// packets larger than a link can carry.
List<BitchatPacket> bitchatFragmentsFor(
  BitchatPacket original, {
  int chunkBytes = bitchatDefaultFragmentChunk,
  Random? random,
}) {
  final encoded = original.encode();
  final size = max(16, chunkBytes);
  final total = (encoded.length + size - 1) ~/ size;
  if (total > 0xffff) throw ArgumentError('Too large to fragment.');
  final source = random ?? Random.secure();
  final id = Uint8List.fromList(List.generate(8, (_) => source.nextInt(256)));
  return [
    for (var index = 0; index < total; index++)
      BitchatPacket(
        version: original.route?.isNotEmpty ?? false ? 2 : 1,
        type: BitchatType.fragment,
        senderId: original.senderId,
        recipientId: original.recipientId,
        timestamp: original.timestamp,
        ttl: original.ttl,
        route: original.route,
        payload: BitchatFragment(
          fragmentId: id,
          index: index,
          total: total,
          originalType: original.type,
          chunk: Uint8List.sublistView(
            encoded,
            index * size,
            min((index + 1) * size, encoded.length),
          ),
        ).encode(),
      ),
  ];
}

/// Puts fragmented packets back together, with bounded memory: at most
/// [maxPending] packets at once, each at most [maxBytes], forgotten after
/// [lifetime].
class BitchatReassembler {
  BitchatReassembler({
    this.maxPending = 32,
    this.maxBytes = 64 * 1024,
    this.lifetime = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxPending;
  final int maxBytes;
  final Duration lifetime;
  final DateTime Function() _now;
  final LinkedHashMap<String, _Pending> _pending = LinkedHashMap();

  /// Adds the fragment carried by [packet]; returns the whole original
  /// packet's bytes once every fragment has arrived.
  Uint8List? add(BitchatPacket packet) {
    final fragment = BitchatFragment.decode(packet.payload);
    if (fragment == null ||
        fragment.total * fragment.chunk.length > maxBytes * 2) {
      return null;
    }
    final now = _now();
    _pending.removeWhere(
      (_, entry) => now.difference(entry.startedAt) > lifetime,
    );
    final key = '${_hex(packet.senderId)}:${_hex(fragment.fragmentId)}';
    var entry = _pending[key];
    if (entry == null) {
      if (_pending.length >= maxPending) _pending.remove(_pending.keys.first);
      entry = _Pending(fragment.total, now);
      _pending[key] = entry;
    }
    if (entry.total != fragment.total) {
      _pending.remove(key);
      return null;
    }
    if (!entry.chunks.containsKey(fragment.index)) {
      entry.bytes += fragment.chunk.length;
      if (entry.bytes > maxBytes) {
        _pending.remove(key);
        return null;
      }
      entry.chunks[fragment.index] = Uint8List.fromList(fragment.chunk);
    }
    if (entry.chunks.length < entry.total) return null;
    _pending.remove(key);
    final out = BytesBuilder(copy: false);
    for (var index = 0; index < entry.total; index++) {
      out.add(entry.chunks[index]!);
    }
    return out.takeBytes();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

class _Pending {
  _Pending(this.total, this.startedAt);
  final int total;
  final DateTime startedAt;
  final Map<int, Uint8List> chunks = {};
  int bytes = 0;
}
