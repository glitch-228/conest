import 'dart:typed_data';

/// `CNS2`: what a v2 session's first bytes are (the relay tells protocols
/// apart by them).
const List<int> relayV2Magic = [0x43, 0x4e, 0x53, 0x32];
const int relayV2Version = 1;

/// A record on the wire: a 2-byte length, then at most this much
/// ciphertext.
const int relayV2MaxRecord = 65535;
const int relayV2Tag = 16;
const int relayV2MaxRecordPlaintext = relayV2MaxRecord - relayV2Tag;

/// `u32 length | u8 type | u32 stream`.
const int relayV2FrameHeader = 9;

/// Frame types (as in `native/conest_relay/src/session.rs`). 0x10–0x3f are
/// reserved for blobs, chunk sets and call media.
abstract final class RelayV2FrameType {
  static const int request = 0x01;
  static const int response = 0x02;
  static const int event = 0x03;
  static const int cancel = 0x04;
  static const int ping = 0x05;
  static const int pong = 0x06;
  static const int goaway = 0x07;
  static const int pad = 0x0f;
}

class RelayV2Frame {
  const RelayV2Frame(this.type, this.stream, this.payload);

  final int type;
  final int stream;
  final Uint8List payload;
}

Uint8List encodeRelayV2Frame(int type, int stream, List<int> payload) {
  final out = Uint8List(relayV2FrameHeader + payload.length);
  final view = ByteData.sublistView(out);
  view.setUint32(0, payload.length);
  view.setUint8(4, type);
  view.setUint32(5, stream);
  out.setRange(relayV2FrameHeader, out.length, payload);
  return out;
}

/// Bytes in, bytes out, without copying the whole buffer each time.
class RelayByteQueue {
  Uint8List _buffer = Uint8List(4096);
  int _start = 0;
  int _end = 0;

  int get length => _end - _start;

  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    if (_end + bytes.length > _buffer.length) {
      final needed = length + bytes.length;
      if (needed <= _buffer.length && _start > 0) {
        _buffer.setRange(0, length, _buffer, _start);
      } else {
        var size = _buffer.length;
        while (size < needed) {
          size *= 2;
        }
        final grown = Uint8List(size)..setRange(0, length, _buffer, _start);
        _buffer = grown;
      }
      _end = length;
      _start = 0;
    }
    _buffer.setRange(_end, _end + bytes.length, bytes);
    _end += bytes.length;
  }

  int peekByte(int offset) => _buffer[_start + offset];

  Uint8List take(int count) {
    if (count > length) throw StateError('Not enough bytes buffered.');
    final out = Uint8List.fromList(
      Uint8List.sublistView(_buffer, _start, _start + count),
    );
    _start += count;
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
    return out;
  }
}

/// Frames out of decrypted record bytes, each at most [maxPayload].
class RelayV2FrameDecoder {
  RelayV2FrameDecoder(this.maxPayload, {this.limitFor});

  final int maxPayload;

  /// A tighter limit for a frame of [type] on [stream] (read from its
  /// header, before its payload is waited for or buffered): null keeps
  /// [maxPayload].
  final int? Function(int type, int stream)? limitFor;
  final RelayByteQueue _queue = RelayByteQueue();

  void add(List<int> bytes) => _queue.add(bytes);

  /// The next whole frame, or null; throws [FormatException] for a frame
  /// over the limit (the session ends).
  RelayV2Frame? next() {
    if (_queue.length < relayV2FrameHeader) return null;
    final length =
        (_queue.peekByte(0) << 24) |
        (_queue.peekByte(1) << 16) |
        (_queue.peekByte(2) << 8) |
        _queue.peekByte(3);
    var limit = maxPayload;
    final tighter = limitFor;
    if (tighter != null && _queue.length >= relayV2FrameHeader) {
      final stream =
          (_queue.peekByte(5) << 24) |
          (_queue.peekByte(6) << 16) |
          (_queue.peekByte(7) << 8) |
          _queue.peekByte(8);
      final own = tighter(_queue.peekByte(4), stream);
      if (own != null && own < limit) limit = own;
    }
    if (length > limit) {
      throw FormatException('Relay frame too large: $length bytes.');
    }
    if (_queue.length < relayV2FrameHeader + length) return null;
    final header = _queue.take(relayV2FrameHeader);
    final view = ByteData.sublistView(header);
    final payload = _queue.take(length);
    return RelayV2Frame(view.getUint8(4), view.getUint32(5), payload);
  }
}
