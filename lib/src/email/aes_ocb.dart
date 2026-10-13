import 'dart:typed_data';

import 'aes.dart';

/// AES-OCB (RFC 7253) with 128-bit tags, the AEAD mode OpenPGP v6 messages
/// (RFC 9580) use by default.
class AesOcb {
  AesOcb(Uint8List key) : _cipher = AesBlockCipher(key) {
    _cipher.encryptBlock(Uint8List(16), 0, _lStar, 0);
    _lDollar.setAll(0, _double(_lStar));
    _l.add(_double(_lDollar));
  }

  static const int tagLength = 16;

  final AesBlockCipher _cipher;
  final _lStar = Uint8List(16);
  final _lDollar = Uint8List(16);
  final List<Uint8List> _l = [];

  /// [plaintext] encrypted, with the tag appended.
  Uint8List encrypt(
    Uint8List nonce,
    Uint8List associated,
    Uint8List plaintext,
  ) {
    final out = Uint8List(plaintext.length + tagLength);
    final tag = _crypt(nonce, associated, plaintext, out, encrypt: true);
    out.setRange(plaintext.length, out.length, tag);
    return out;
  }

  /// The plaintext of [ciphertext] (tag appended); throws [FormatException]
  /// when the tag does not match.
  Uint8List decrypt(
    Uint8List nonce,
    Uint8List associated,
    Uint8List ciphertext,
  ) {
    if (ciphertext.length < tagLength) {
      throw const FormatException('OCB ciphertext too short.');
    }
    final length = ciphertext.length - tagLength;
    final out = Uint8List(length);
    final tag = _crypt(
      nonce,
      associated,
      Uint8List.sublistView(ciphertext, 0, length),
      out,
      encrypt: false,
    );
    var difference = 0;
    for (var index = 0; index < tagLength; index++) {
      difference |= tag[index] ^ ciphertext[length + index];
    }
    if (difference != 0) {
      throw const FormatException('OCB authentication failed.');
    }
    return out;
  }

  Uint8List _lAt(int index) {
    while (_l.length <= index) {
      _l.add(_double(_l.last));
    }
    return _l[index];
  }

  static Uint8List _double(Uint8List block) {
    final out = Uint8List(16);
    for (var index = 0; index < 16; index++) {
      out[index] =
          ((block[index] << 1) | (index < 15 ? block[index + 1] >> 7 : 0)) &
          0xff;
    }
    if (block[0] & 0x80 != 0) out[15] ^= 0x87;
    return out;
  }

  static int _ntz(int value) {
    var count = 0;
    while (value & 1 == 0) {
      value >>= 1;
      count++;
    }
    return count;
  }

  static void _xorInto(Uint8List target, List<int> other, [int offset = 0]) {
    for (var index = 0; index < 16; index++) {
      target[index] ^= other[offset + index];
    }
  }

  Uint8List _offset0(Uint8List nonce) {
    if (nonce.isEmpty || nonce.length > 15) {
      throw ArgumentError('OCB nonces are 1 to 15 bytes.');
    }
    final block = Uint8List(16);
    // TAGLEN mod 128 is 0 for 128-bit tags; a 1 bit, then the nonce.
    block.setRange(16 - nonce.length, 16, nonce);
    block[15 - nonce.length] |= 1;
    final bottom = block[15] & 0x3f;
    block[15] &= 0xc0;
    final top = Uint8List(16);
    _cipher.encryptBlock(block, 0, top, 0);
    final stretch = Uint8List(24)..setAll(0, top);
    for (var index = 0; index < 8; index++) {
      stretch[16 + index] = top[index] ^ top[index + 1];
    }
    final shift = bottom % 8;
    final start = bottom ~/ 8;
    final offset = Uint8List(16);
    for (var index = 0; index < 16; index++) {
      final high = stretch[start + index];
      final low = start + index + 1 < 24 ? stretch[start + index + 1] : 0;
      offset[index] = shift == 0
          ? high
          : ((high << shift) | (low >> (8 - shift))) & 0xff;
    }
    return offset;
  }

  Uint8List _hash(Uint8List associated) {
    final sum = Uint8List(16);
    final offset = Uint8List(16);
    final block = Uint8List(16);
    final full = associated.length ~/ 16;
    for (var index = 1; index <= full; index++) {
      _xorInto(offset, _lAt(_ntz(index)));
      for (var byte = 0; byte < 16; byte++) {
        block[byte] = associated[(index - 1) * 16 + byte] ^ offset[byte];
      }
      _cipher.encryptBlock(block, 0, block, 0);
      _xorInto(sum, block);
    }
    final rest = associated.length - full * 16;
    if (rest > 0) {
      _xorInto(offset, _lStar);
      block.fillRange(0, 16, 0);
      block.setRange(0, rest, associated, full * 16);
      block[rest] = 0x80;
      _xorInto(block, offset);
      _cipher.encryptBlock(block, 0, block, 0);
      _xorInto(sum, block);
    }
    return sum;
  }

  /// Fills [out] and returns the tag.
  Uint8List _crypt(
    Uint8List nonce,
    Uint8List associated,
    Uint8List input,
    Uint8List out, {
    required bool encrypt,
  }) {
    final offset = _offset0(nonce);
    final checksum = Uint8List(16);
    final block = Uint8List(16);
    final full = input.length ~/ 16;
    for (var index = 1; index <= full; index++) {
      final at = (index - 1) * 16;
      _xorInto(offset, _lAt(_ntz(index)));
      for (var byte = 0; byte < 16; byte++) {
        block[byte] = input[at + byte] ^ offset[byte];
      }
      if (encrypt) {
        _cipher.encryptBlock(block, 0, block, 0);
      } else {
        _cipher.decryptBlock(block, 0, block, 0);
      }
      for (var byte = 0; byte < 16; byte++) {
        out[at + byte] = block[byte] ^ offset[byte];
      }
      _xorInto(checksum, encrypt ? input : out, at);
    }
    final rest = input.length - full * 16;
    if (rest > 0) {
      final at = full * 16;
      _xorInto(offset, _lStar);
      final pad = Uint8List(16);
      _cipher.encryptBlock(offset, 0, pad, 0);
      for (var byte = 0; byte < rest; byte++) {
        out[at + byte] = input[at + byte] ^ pad[byte];
      }
      final plain = encrypt ? input : out;
      final last = Uint8List(16)..setRange(0, rest, plain, at);
      last[rest] = 0x80;
      _xorInto(checksum, last);
    }
    final tag = Uint8List(16)..setAll(0, checksum);
    _xorInto(tag, offset);
    _xorInto(tag, _lDollar);
    _cipher.encryptBlock(tag, 0, tag, 0);
    _xorInto(tag, _hash(associated));
    return tag;
  }
}
