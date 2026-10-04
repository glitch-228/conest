import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'secp256k1.dart';

/// NIP-44 version 2 encryption between two Nostr keys: ECDH on secp256k1,
/// HKDF-SHA256, ChaCha20 and HMAC-SHA256, with length-hiding padding.
abstract final class Nip44 {
  static const int minPlaintextBytes = 1;
  static const int maxPlaintextBytes = 65535;

  /// The key both sides derive from their own secret key and the other
  /// side's public key.
  static Uint8List conversationKey(Uint8List secretKey, Uint8List publicKey) =>
      Uint8List.fromList(
        Hmac(
          sha256,
          utf8.encode('nip44-v2'),
        ).convert(Secp256k1.sharedX(secretKey, publicKey)).bytes,
      );

  /// ChaCha20 key, ChaCha20 nonce and HMAC key for one message.
  static ({Uint8List chachaKey, Uint8List chachaNonce, Uint8List hmacKey})
  messageKeys(Uint8List conversationKey, Uint8List nonce) {
    if (conversationKey.length != 32 || nonce.length != 32) {
      throw ArgumentError('Conversation keys and nonces are 32 bytes.');
    }
    final okm = _hkdfExpand(conversationKey, nonce, 76);
    return (
      chachaKey: Uint8List.sublistView(okm, 0, 32),
      chachaNonce: Uint8List.sublistView(okm, 32, 44),
      hmacKey: Uint8List.sublistView(okm, 44, 76),
    );
  }

  static int paddedLength(int length) {
    if (length <= 32) return 32;
    final nextPower = 1 << ((length - 1).bitLength);
    final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
    return chunk * ((length - 1) ~/ chunk + 1);
  }

  /// Encrypts [plaintext] into a base64 payload.
  static String encrypt(
    Uint8List plaintext,
    Uint8List conversationKey, {
    Uint8List? nonce,
  }) {
    if (plaintext.length < minPlaintextBytes ||
        plaintext.length > maxPlaintextBytes) {
      throw ArgumentError('Plaintext size is outside the NIP-44 limits.');
    }
    final usedNonce = nonce ?? _randomBytes(32);
    final keys = messageKeys(conversationKey, usedNonce);
    final padded = Uint8List(2 + paddedLength(plaintext.length))
      ..[0] = plaintext.length >> 8
      ..[1] = plaintext.length & 0xff
      ..setRange(2, 2 + plaintext.length, plaintext);
    final ciphertext = chacha20(keys.chachaKey, keys.chachaNonce, padded);
    final mac = Hmac(
      sha256,
      keys.hmacKey,
    ).convert([...usedNonce, ...ciphertext]).bytes;
    return base64Encode([2, ...usedNonce, ...ciphertext, ...mac]);
  }

  /// Decrypts a base64 payload; throws [FormatException] when it is
  /// malformed or was not made with [conversationKey].
  static Uint8List decrypt(String payload, Uint8List conversationKey) {
    if (payload.isEmpty || payload.startsWith('#')) {
      throw const FormatException('Unknown NIP-44 version.');
    }
    if (payload.length < 132 || payload.length > 87472) {
      throw const FormatException('NIP-44 payload size is invalid.');
    }
    final Uint8List data;
    try {
      data = base64Decode(payload);
    } on FormatException {
      throw const FormatException('NIP-44 payload is not base64.');
    }
    if (data.length < 99 || data.length > 65603) {
      throw const FormatException('NIP-44 payload size is invalid.');
    }
    if (data[0] != 2) throw const FormatException('Unknown NIP-44 version.');
    final nonce = Uint8List.sublistView(data, 1, 33);
    final ciphertext = Uint8List.sublistView(data, 33, data.length - 32);
    final mac = Uint8List.sublistView(data, data.length - 32);
    final keys = messageKeys(conversationKey, nonce);
    final expected = Hmac(
      sha256,
      keys.hmacKey,
    ).convert([...nonce, ...ciphertext]).bytes;
    var difference = 0;
    for (var index = 0; index < 32; index++) {
      difference |= expected[index] ^ mac[index];
    }
    if (difference != 0) throw const FormatException('NIP-44 MAC mismatch.');
    final padded = chacha20(keys.chachaKey, keys.chachaNonce, ciphertext);
    final length = (padded[0] << 8) | padded[1];
    if (length < minPlaintextBytes ||
        padded.length != 2 + paddedLength(length)) {
      throw const FormatException('NIP-44 padding is invalid.');
    }
    return Uint8List.sublistView(padded, 2, 2 + length);
  }

  static Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
    final out = BytesBuilder(copy: false);
    var previous = <int>[];
    for (var counter = 1; out.length < length; counter++) {
      previous = Hmac(
        sha256,
        prk,
      ).convert([...previous, ...info, counter]).bytes;
      out.add(previous);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}

/// RFC 8439 ChaCha20 with a 12-byte nonce and the block counter starting at
/// zero, as NIP-44 uses it.
Uint8List chacha20(Uint8List key, Uint8List nonce, Uint8List input) {
  if (key.length != 32 || nonce.length != 12) {
    throw ArgumentError('ChaCha20 takes a 32-byte key and a 12-byte nonce.');
  }
  final keyWords = ByteData.sublistView(key);
  final nonceWords = ByteData.sublistView(nonce);
  final state = Uint32List(16)
    ..[0] = 0x61707865
    ..[1] = 0x3320646e
    ..[2] = 0x79622d32
    ..[3] = 0x6b206574;
  for (var index = 0; index < 8; index++) {
    state[4 + index] = keyWords.getUint32(index * 4, Endian.little);
  }
  for (var index = 0; index < 3; index++) {
    state[13 + index] = nonceWords.getUint32(index * 4, Endian.little);
  }
  final output = Uint8List(input.length);
  final working = Uint32List(16);
  final block = Uint8List(64);
  final blockWords = ByteData.sublistView(block);
  for (var offset = 0, counter = 0; offset < input.length; offset += 64) {
    state[12] = counter++;
    working.setAll(0, state);
    for (var round = 0; round < 10; round++) {
      _quarter(working, 0, 4, 8, 12);
      _quarter(working, 1, 5, 9, 13);
      _quarter(working, 2, 6, 10, 14);
      _quarter(working, 3, 7, 11, 15);
      _quarter(working, 0, 5, 10, 15);
      _quarter(working, 1, 6, 11, 12);
      _quarter(working, 2, 7, 8, 13);
      _quarter(working, 3, 4, 9, 14);
    }
    for (var index = 0; index < 16; index++) {
      blockWords.setUint32(
        index * 4,
        (working[index] + state[index]) & 0xffffffff,
        Endian.little,
      );
    }
    final end = min(64, input.length - offset);
    for (var index = 0; index < end; index++) {
      output[offset + index] = input[offset + index] ^ block[index];
    }
  }
  return output;
}

int _rotl(int value, int shift) =>
    ((value << shift) | (value >> (32 - shift))) & 0xffffffff;

void _quarter(Uint32List s, int a, int b, int c, int d) {
  s[a] = (s[a] + s[b]) & 0xffffffff;
  s[d] = _rotl(s[d] ^ s[a], 16);
  s[c] = (s[c] + s[d]) & 0xffffffff;
  s[b] = _rotl(s[b] ^ s[c], 12);
  s[a] = (s[a] + s[b]) & 0xffffffff;
  s[d] = _rotl(s[d] ^ s[a], 8);
  s[c] = (s[c] + s[d]) & 0xffffffff;
  s[b] = _rotl(s[b] ^ s[c], 7);
}
