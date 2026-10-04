import 'dart:typed_data';

/// AES (FIPS-197) block encryption, the only direction OpenPGP's CFB mode
/// needs. Table-free and synchronous; mail frames are small.
class AesBlockCipher {
  AesBlockCipher(Uint8List key)
    : assert(key.length == 16 || key.length == 24 || key.length == 32),
      _rounds = key.length ~/ 4 + 6,
      _roundKeys = _expand(key);

  final int _rounds;
  final Uint8List _roundKeys;

  /// Encrypts one 16-byte block of [input] at [inOffset] into [output] at
  /// [outOffset].
  void encryptBlock(
    Uint8List input,
    int inOffset,
    Uint8List output,
    int outOffset,
  ) {
    final state = Uint8List(16)..setRange(0, 16, input, inOffset);
    _addRoundKey(state, 0);
    for (var round = 1; round < _rounds; round++) {
      _subBytes(state);
      _shiftRows(state);
      _mixColumns(state);
      _addRoundKey(state, round);
    }
    _subBytes(state);
    _shiftRows(state);
    _addRoundKey(state, _rounds);
    output.setRange(outOffset, outOffset + 16, state);
  }

  void _addRoundKey(Uint8List state, int round) {
    for (var index = 0; index < 16; index++) {
      state[index] ^= _roundKeys[round * 16 + index];
    }
  }

  static void _subBytes(Uint8List state) {
    for (var index = 0; index < 16; index++) {
      state[index] = _sbox[state[index]];
    }
  }

  // State is column-major: byte (row r, column c) at index 4c + r.
  static void _shiftRows(Uint8List s) {
    var t = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t;
    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;
    t = s[3];
    s[3] = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = t;
  }

  static int _xtime(int value) =>
      ((value << 1) ^ ((value & 0x80) != 0 ? 0x1b : 0)) & 0xff;

  static void _mixColumns(Uint8List s) {
    for (var column = 0; column < 4; column++) {
      final i = column * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      final all = a0 ^ a1 ^ a2 ^ a3;
      s[i] = a0 ^ all ^ _xtime(a0 ^ a1);
      s[i + 1] = a1 ^ all ^ _xtime(a1 ^ a2);
      s[i + 2] = a2 ^ all ^ _xtime(a2 ^ a3);
      s[i + 3] = a3 ^ all ^ _xtime(a3 ^ a0);
    }
  }

  static Uint8List _expand(Uint8List key) {
    final nk = key.length ~/ 4;
    final rounds = nk + 6;
    final words = Uint8List(16 * (rounds + 1))..setRange(0, key.length, key);
    var rcon = 1;
    for (var i = nk; i < 4 * (rounds + 1); i++) {
      final temp = Uint8List.sublistView(words, (i - 1) * 4, i * 4).toList();
      if (i % nk == 0) {
        final first = temp[0];
        temp[0] = _sbox[temp[1]] ^ rcon;
        temp[1] = _sbox[temp[2]];
        temp[2] = _sbox[temp[3]];
        temp[3] = _sbox[first];
        rcon = _xtime(rcon);
      } else if (nk > 6 && i % nk == 4) {
        for (var j = 0; j < 4; j++) {
          temp[j] = _sbox[temp[j]];
        }
      }
      for (var j = 0; j < 4; j++) {
        words[i * 4 + j] = words[(i - nk) * 4 + j] ^ temp[j];
      }
    }
    return words;
  }

  static final Uint8List _sbox = _buildSbox();

  static Uint8List _buildSbox() {
    final sbox = Uint8List(256);
    var p = 1, q = 1;
    do {
      // p walks the multiplicative group by 3, q by its inverse.
      p = p ^ ((p << 1) & 0xff) ^ ((p & 0x80) != 0 ? 0x1b : 0);
      q ^= q << 1;
      q ^= q << 2;
      q ^= q << 4;
      q &= 0xff;
      if ((q & 0x80) != 0) q ^= 0x09;
      final x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4);
      sbox[p] = (x ^ 0x63) & 0xff;
    } while (p != 1);
    sbox[0] = 0x63;
    return sbox;
  }

  static int _rotl8(int value, int shift) =>
      ((value << shift) | (value >> (8 - shift))) & 0xff;
}
