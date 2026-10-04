import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'aes.dart';

/// Password-based OpenPGP messages (RFC 4880: an SKESK v4 with an iterated
/// and salted SHA-256 S2K, then AES-256 in a SEIPD v1 with MDC), the form
/// `gpg --symmetric` writes.
///
/// Chatmail servers relay only OpenPGP-encrypted mail, so the email carrier
/// wraps its already sealed frames in one; the seal inside is what protects
/// and authenticates them.
abstract final class OpenPgpSymmetric {
  static const int _aes256 = 9;
  static const int _sha256 = 8;

  /// S2K count byte: 65536 bytes hashed. The password is a random key, so
  /// stretching adds nothing but time.
  static const int _s2kCount = 0x60;

  /// Encrypts [data] under [password] into a binary OpenPGP message.
  static Uint8List encrypt(
    Uint8List data,
    List<int> password, {
    Random? random,
  }) {
    final source = random ?? Random.secure();
    List<int> randomBytes(int length) =>
        List<int>.generate(length, (_) => source.nextInt(256));
    final salt = randomBytes(8);
    final key = _s2k(password, salt, _countBytes(_s2kCount));
    final skesk = _packet(3, [4, _aes256, 3, _sha256, ...salt, _s2kCount]);

    final literal = _packet(11, [
      0x62, // 'b': binary
      0, // no file name
      0, 0, 0, 0, // no date
      ...data,
    ]);
    final prefix = randomBytes(16);
    final clear = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(prefix.sublist(14))
      ..add(literal)
      ..add([0xd3, 0x14]);
    final mdcInput = clear.toBytes();
    final mdc = sha1.convert(mdcInput).bytes;
    final plaintext = Uint8List.fromList([...mdcInput, ...mdc]);
    final encrypted = _cfb(AesBlockCipher(key), plaintext, encrypt: true);
    final seipd = _packet(18, [1, ...encrypted]);
    return Uint8List.fromList([...skesk, ...seipd]);
  }

  /// Decrypts a message made by [encrypt] (or by `gpg --symmetric` with
  /// AES-256, SHA-256 S2K and MDC); throws [FormatException] otherwise.
  static Uint8List decrypt(Uint8List message, List<int> password) {
    final packets = _readPackets(message);
    if (packets.length != 2 || packets[0].$1 != 3 || packets[1].$1 != 18) {
      throw const FormatException('Not a password-encrypted OpenPGP message.');
    }
    final skesk = packets[0].$2;
    if (skesk.length != 13 ||
        skesk[0] != 4 ||
        skesk[1] != _aes256 ||
        skesk[2] != 3 ||
        skesk[3] != _sha256) {
      throw const FormatException('Unsupported OpenPGP password packet.');
    }
    // The count is the sender's choice; a large one would make every mail
    // cost seconds of hashing, so only Conest's own (or less) is accepted.
    if (skesk[12] > _s2kCount) {
      throw const FormatException('OpenPGP password stretching too costly.');
    }
    final key = _s2k(password, skesk.sublist(4, 12), _countBytes(skesk[12]));
    final seipd = packets[1].$2;
    if (seipd.isEmpty || seipd[0] != 1 || seipd.length < 1 + 18 + 22) {
      throw const FormatException('Unsupported OpenPGP data packet.');
    }
    final plain = _cfb(
      AesBlockCipher(key),
      Uint8List.sublistView(seipd, 1),
      encrypt: false,
    );
    if (plain[14] != plain[16] || plain[15] != plain[17]) {
      throw const FormatException('Wrong OpenPGP password.');
    }
    final body = Uint8List.sublistView(plain, 0, plain.length - 20);
    final mdc = Uint8List.sublistView(plain, plain.length - 20);
    final expected = sha1.convert(body).bytes;
    var difference = 0;
    for (var index = 0; index < 20; index++) {
      difference |= expected[index] ^ mdc[index];
    }
    if (difference != 0 ||
        body[body.length - 2] != 0xd3 ||
        body[body.length - 1] != 0x14) {
      throw const FormatException('OpenPGP integrity check failed.');
    }
    final inner = _readPackets(
      Uint8List.sublistView(body, 18, body.length - 2),
    );
    if (inner.length != 1 || inner.single.$1 != 11) {
      throw const FormatException('OpenPGP message holds no literal data.');
    }
    final literal = inner.single.$2;
    if (literal.length < 6) {
      throw const FormatException('OpenPGP literal data is truncated.');
    }
    final nameLength = literal[1];
    final start = 2 + nameLength + 4;
    if (start > literal.length) {
      throw const FormatException('OpenPGP literal data is truncated.');
    }
    return Uint8List.sublistView(literal, start);
  }

  static int _countBytes(int coded) =>
      (16 + (coded & 15)) << ((coded >> 4) + 6);

  /// Iterated and salted S2K with SHA-256: a 32-byte AES-256 key.
  static Uint8List _s2k(List<int> password, List<int> salt, int count) {
    final unit = [...salt, ...password];
    final total = max(count, unit.length);
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    var remaining = total;
    while (remaining > 0) {
      final take = min(remaining, unit.length);
      input.add(take == unit.length ? unit : unit.sublist(0, take));
      remaining -= take;
    }
    input.close();
    return Uint8List.fromList(sink.value!.bytes);
  }

  /// OpenPGP CFB (no resynchronisation) with a zero IV.
  static Uint8List _cfb(
    AesBlockCipher cipher,
    Uint8List input, {
    required bool encrypt,
  }) {
    final output = Uint8List(input.length);
    final register = Uint8List(16);
    final keystream = Uint8List(16);
    for (var offset = 0; offset < input.length; offset += 16) {
      cipher.encryptBlock(register, 0, keystream, 0);
      final end = min(16, input.length - offset);
      for (var index = 0; index < end; index++) {
        output[offset + index] = input[offset + index] ^ keystream[index];
      }
      final cipherBlock = encrypt ? output : input;
      if (end == 16) {
        register.setRange(0, 16, cipherBlock, offset);
      }
    }
    return output;
  }

  static List<int> _packet(int tag, List<int> body) {
    final length = body.length;
    final header = <int>[0xc0 | tag];
    if (length < 192) {
      header.add(length);
    } else if (length < 8384) {
      header
        ..add(((length - 192) >> 8) + 192)
        ..add((length - 192) & 0xff);
    } else {
      header.addAll([
        0xff,
        (length >> 24) & 0xff,
        (length >> 16) & 0xff,
        (length >> 8) & 0xff,
        length & 0xff,
      ]);
    }
    return [...header, ...body];
  }

  /// Reads new- and old-format packets with definite lengths, and new-format
  /// partial lengths (gpg writes those for data it streams).
  static List<(int, Uint8List)> _readPackets(Uint8List data) {
    final packets = <(int, Uint8List)>[];
    var offset = 0;
    while (offset < data.length) {
      final first = data[offset++];
      if ((first & 0x80) == 0) {
        throw const FormatException('Malformed OpenPGP packet header.');
      }
      if ((first & 0x40) != 0) {
        final tag = first & 0x3f;
        final body = BytesBuilder(copy: false);
        while (true) {
          if (offset >= data.length) {
            throw const FormatException('Truncated OpenPGP packet.');
          }
          final l1 = data[offset++];
          int length;
          var partial = false;
          if (l1 < 192) {
            length = l1;
          } else if (l1 < 224) {
            if (offset >= data.length) {
              throw const FormatException('Truncated OpenPGP packet.');
            }
            length = ((l1 - 192) << 8) + data[offset++] + 192;
          } else if (l1 == 255) {
            if (offset + 4 > data.length) {
              throw const FormatException('Truncated OpenPGP packet.');
            }
            length =
                (data[offset] << 24) |
                (data[offset + 1] << 16) |
                (data[offset + 2] << 8) |
                data[offset + 3];
            offset += 4;
          } else {
            length = 1 << (l1 & 0x1f);
            partial = true;
          }
          if (length < 0 || offset + length > data.length) {
            throw const FormatException('Truncated OpenPGP packet.');
          }
          body.add(Uint8List.sublistView(data, offset, offset + length));
          offset += length;
          if (!partial) break;
        }
        packets.add((tag, body.takeBytes()));
      } else {
        final tag = (first >> 2) & 0x0f;
        final type = first & 3;
        int length;
        if (type == 3) {
          length = data.length - offset;
        } else {
          final size = 1 << type;
          if (offset + size > data.length) {
            throw const FormatException('Truncated OpenPGP packet.');
          }
          length = 0;
          for (var index = 0; index < size; index++) {
            length = (length << 8) | data[offset + index];
          }
          offset += size;
        }
        if (offset + length > data.length) {
          throw const FormatException('Truncated OpenPGP packet.');
        }
        packets.add((
          tag,
          Uint8List.sublistView(data, offset, offset + length),
        ));
        offset += length;
      }
    }
    return packets;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// ASCII armor (RFC 4880 section 6) for OpenPGP messages.
abstract final class OpenPgpArmor {
  static const _begin = '-----BEGIN PGP MESSAGE-----';
  static const _end = '-----END PGP MESSAGE-----';

  static String encode(Uint8List data) {
    final body = base64Encode(data);
    final lines = StringBuffer('$_begin\r\n\r\n');
    for (var offset = 0; offset < body.length; offset += 64) {
      lines
        ..write(body.substring(offset, min(offset + 64, body.length)))
        ..write('\r\n');
    }
    final crc = _crc24(data);
    lines
      ..write('=')
      ..write(base64Encode([(crc >> 16) & 0xff, (crc >> 8) & 0xff, crc & 0xff]))
      ..write('\r\n$_end\r\n');
    return lines.toString();
  }

  static Uint8List decode(String armored) {
    final lines = armored.replaceAll('\r', '').split('\n');
    final start = lines.indexWhere((line) => line.trim() == _begin);
    final end = lines.indexWhere((line) => line.trim() == _end);
    if (start < 0 || end <= start) {
      throw const FormatException('No armored OpenPGP message.');
    }
    var index = start + 1;
    // Skip armor headers up to the blank line.
    while (index < end && lines[index].trim().isNotEmpty) {
      index++;
    }
    final body = StringBuffer();
    String? checksum;
    for (index++; index < end; index++) {
      final line = lines[index].trim();
      if (line.startsWith('=')) {
        checksum = line.substring(1);
      } else {
        body.write(line);
      }
    }
    final data = base64Decode(body.toString());
    if (checksum != null) {
      final crc = base64Decode(checksum);
      final expected = _crc24(data);
      if (crc.length != 3 ||
          ((crc[0] << 16) | (crc[1] << 8) | crc[2]) != expected) {
        throw const FormatException('OpenPGP armor checksum mismatch.');
      }
    }
    return data;
  }

  static int _crc24(List<int> data) {
    var crc = 0xb704ce;
    for (final byte in data) {
      crc ^= byte << 16;
      for (var bit = 0; bit < 8; bit++) {
        crc <<= 1;
        if ((crc & 0x1000000) != 0) crc ^= 0x1864cfb;
      }
    }
    return crc & 0xffffff;
  }
}
