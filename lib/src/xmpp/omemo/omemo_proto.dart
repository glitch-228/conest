import 'dart:typed_data';

/// The small slice of Protocol Buffers OMEMO needs: varint and
/// length-delimited fields, written in field-number order (as the reference
/// libraries do) and read with hard bounds.
class OmemoProtoException implements Exception {
  const OmemoProtoException(this.message);
  final String message;
  @override
  String toString() => 'OMEMO message: $message';
}

class ProtoWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void _varint(int value) {
    var rest = value;
    while (rest >= 0x80) {
      _out.addByte((rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    _out.addByte(rest);
  }

  /// A uint32 field.
  void uint(int field, int value) {
    if (value < 0 || value > 0xffffffff) {
      throw const OmemoProtoException('number out of range');
    }
    _varint(field << 3);
    _varint(value);
  }

  /// A bytes (or embedded message) field.
  void bytes(int field, List<int> value) {
    _varint((field << 3) | 2);
    _varint(value.length);
    _out.add(value);
  }

  Uint8List toBytes() => _out.toBytes();
}

class ProtoReader {
  ProtoReader._(this.numbers, this.blobs);

  final Map<int, int> numbers;
  final Map<int, Uint8List> blobs;

  /// Bytes parsed at most; OMEMO messages are far smaller.
  static const int maxLength = 64 * 1024;

  static ProtoReader parse(List<int> data) {
    if (data.length > maxLength) {
      throw const OmemoProtoException('too large');
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final numbers = <int, int>{};
    final blobs = <int, Uint8List>{};
    var offset = 0;

    int varint() {
      var result = 0;
      var shift = 0;
      while (true) {
        if (offset >= bytes.length || shift > 63) {
          throw const OmemoProtoException('truncated number');
        }
        final byte = bytes[offset++];
        // Dart ints are 64-bit; anything above 32 bits is rejected by the
        // callers that read numbers.
        if (shift < 63) result |= (byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
      }
    }

    while (offset < bytes.length) {
      final tag = varint();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 0) throw const OmemoProtoException('bad field number');
      switch (wire) {
        case 0:
          numbers[field] = varint();
        case 2:
          final length = varint();
          if (length < 0 || length > bytes.length - offset) {
            throw const OmemoProtoException('truncated field');
          }
          blobs[field] = Uint8List.sublistView(bytes, offset, offset + length);
          offset += length;
        case 1:
          if (bytes.length - offset < 8) {
            throw const OmemoProtoException('truncated field');
          }
          offset += 8;
        case 5:
          if (bytes.length - offset < 4) {
            throw const OmemoProtoException('truncated field');
          }
          offset += 4;
        default:
          throw const OmemoProtoException('unsupported field type');
      }
    }
    return ProtoReader._(numbers, blobs);
  }

  int requiredUint(int field) {
    final value = numbers[field];
    if (value == null || value < 0 || value > 0xffffffff) {
      throw OmemoProtoException('missing or invalid number $field');
    }
    return value;
  }

  Uint8List requiredBytes(int field) {
    final value = blobs[field];
    if (value == null) throw OmemoProtoException('missing field $field');
    return value;
  }

  Uint8List? optionalBytes(int field) => blobs[field];
}
