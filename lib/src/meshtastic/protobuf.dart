import 'dart:convert';
import 'dart:typed_data';

/// The few protobuf wire types Meshtastic's messages use.
abstract final class WireType {
  static const int varint = 0;
  static const int fixed64 = 1;
  static const int lengthDelimited = 2;
  static const int fixed32 = 5;
}

/// Writes protobuf fields in field order.
class ProtoWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void _key(int field, int wireType) => _varint((field << 3) | wireType);

  void _varint(int value) {
    var remaining = value;
    while (true) {
      final byte = remaining & 0x7f;
      remaining >>>= 7;
      if (remaining == 0) {
        _out.addByte(byte);
        return;
      }
      _out.addByte(byte | 0x80);
    }
  }

  void uint(int field, int value) {
    if (value == 0) return;
    _key(field, WireType.varint);
    _varint(value);
  }

  void boolean(int field, bool value) {
    if (!value) return;
    uint(field, 1);
  }

  void fixed32(int field, int value) {
    if (value == 0) return;
    _key(field, WireType.fixed32);
    final bytes = ByteData(4)..setUint32(0, value & 0xffffffff, Endian.little);
    _out.add(bytes.buffer.asUint8List());
  }

  void bytes(int field, List<int> value) {
    if (value.isEmpty) return;
    _key(field, WireType.lengthDelimited);
    _varint(value.length);
    _out.add(value);
  }

  void string(int field, String value) => bytes(field, utf8.encode(value));

  void message(int field, ProtoWriter value) => bytes(field, value.toBytes());

  /// A message field with no content (written even though it is empty).
  void emptyMessage(int field) {
    _key(field, WireType.lengthDelimited);
    _varint(0);
  }

  Uint8List toBytes() => _out.toBytes();
}

/// Reads protobuf fields; unknown fields are skipped. Throws
/// [FormatException] on malformed input.
class ProtoReader {
  ProtoReader(this._data);

  final Uint8List _data;
  int _offset = 0;

  bool get done => _offset >= _data.length;

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_offset >= _data.length || shift > 63) {
        throw const FormatException('Malformed protobuf varint.');
      }
      final byte = _data[_offset++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  /// The next field as (number, wire type, value): an int for varint and
  /// fixed types, bytes for length-delimited ones.
  (int, int, Object) next() {
    final key = _readVarint();
    final field = key >> 3;
    final type = key & 7;
    switch (type) {
      case WireType.varint:
        return (field, type, _readVarint());
      case WireType.fixed32:
        if (_offset + 4 > _data.length) {
          throw const FormatException('Truncated protobuf field.');
        }
        final value = ByteData.sublistView(
          _data,
          _offset,
          _offset + 4,
        ).getUint32(0, Endian.little);
        _offset += 4;
        return (field, type, value);
      case WireType.fixed64:
        if (_offset + 8 > _data.length) {
          throw const FormatException('Truncated protobuf field.');
        }
        final value = ByteData.sublistView(
          _data,
          _offset,
          _offset + 8,
        ).getUint64(0, Endian.little);
        _offset += 8;
        return (field, type, value);
      case WireType.lengthDelimited:
        final length = _readVarint();
        if (length < 0 || _offset + length > _data.length) {
          throw const FormatException('Truncated protobuf field.');
        }
        final value = Uint8List.sublistView(_data, _offset, _offset + length);
        _offset += length;
        return (field, type, value);
      default:
        throw FormatException('Unsupported protobuf wire type $type.');
    }
  }

  /// All fields as a map from number to the last value seen.
  static Map<int, Object> fields(Uint8List data) {
    final reader = ProtoReader(data);
    final result = <int, Object>{};
    while (!reader.done) {
      final (field, _, value) = reader.next();
      result[field] = value;
    }
    return result;
  }
}
