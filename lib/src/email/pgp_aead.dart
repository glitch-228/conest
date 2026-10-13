/// Password-encrypted OpenPGP v6 messages (RFC 9580): a v6 SKESK and a v2
/// SEIPD with AES-OCB, the form Delta Chat's Securejoin v3 messages take.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'aes_ocb.dart';
import 'openpgp.dart';

/// Writing and reading v6 SKESK + v2 SEIPD (AES-OCB) messages.
abstract final class OpenPgpAead {
  static const int _ocb = 2;
  static const int _aes128 = 7;

  /// Largest chunk size octet accepted (RFC 9580 allows up to 16).
  static const int _maxChunkOctet = 16;

  /// Most S2K hashing accepted, for a sender's iteration count.
  static const int _maxS2kBytes = 0x100000;

  static int _keyLength(int cipher) => switch (cipher) {
    7 => 16,
    8 => 24,
    9 => 32,
    _ => throw const FormatException('Unsupported OpenPGP cipher.'),
  };

  /// [inner] (OpenPGP packets) encrypted with [password]: a v6 SKESK with
  /// a salted SHA-256 S2K, then a v2 SEIPD with AES-128-OCB.
  static Uint8List encrypt(
    Uint8List inner,
    List<int> password, {
    Random? random,
  }) {
    final source = random ?? Random.secure();
    Uint8List randomBytes(int length) =>
        Uint8List.fromList(List.generate(length, (_) => source.nextInt(256)));
    const cipher = _aes128;
    final sessionKey = randomBytes(16);
    final salt = randomBytes(8);
    final s2k = [1, 8, ...salt]; // salted, SHA-256
    final s2kKey = _s2k(s2k, password, 16, _maxS2kBytes);
    final info = Uint8List.fromList([0xc3, 6, cipher, _ocb]);
    final kek = _hkdf(s2kKey, Uint8List(0), info, 16);
    final iv = randomBytes(15);
    final wrapped = AesOcb(kek).encrypt(iv, info, sessionKey);
    final skesk = OpenPgpSymmetric.packet(3, [
      6,
      3 + s2k.length + iv.length,
      cipher,
      _ocb,
      s2k.length,
      ...s2k,
      ...iv,
      ...wrapped,
    ]);

    const chunkOctet = 10; // 64 KiB chunks
    final seipdSalt = randomBytes(32);
    final header = Uint8List.fromList([0xd2, 2, cipher, _ocb, chunkOctet]);
    final derived = _hkdf(sessionKey, seipdSalt, header, 16 + 7);
    final ocb = AesOcb(Uint8List.sublistView(derived, 0, 16));
    final iv7 = Uint8List.sublistView(derived, 16);
    const chunkSize = 1 << (chunkOctet + 6);
    final body = BytesBuilder(copy: false)
      ..add([2, cipher, _ocb, chunkOctet])
      ..add(seipdSalt);
    var index = 0;
    for (var offset = 0; offset < inner.length; offset += chunkSize) {
      body.add(
        ocb.encrypt(
          _nonce(iv7, index++),
          header,
          Uint8List.sublistView(
            inner,
            offset,
            min(offset + chunkSize, inner.length),
          ),
        ),
      );
    }
    body.add(
      ocb.encrypt(
        _nonce(iv7, index),
        Uint8List.fromList([...header, ..._be64(inner.length)]),
        Uint8List(0),
      ),
    );
    return Uint8List.fromList([
      ...skesk,
      ...OpenPgpSymmetric.packet(18, body.takeBytes()),
    ]);
  }

  /// The inner packets of [message] if one of [passwords] opens it (with
  /// the password that did), or null when none does or it is not this
  /// form. Throws [FormatException] when the data was changed.
  static (Uint8List, List<int>)? decrypt(
    Uint8List message,
    List<List<int>> passwords, {
    int maxS2kBytes = _maxS2kBytes,
  }) {
    final packets = OpenPgpSymmetric.readPackets(message);
    Uint8List? seipd;
    final skesks = <Uint8List>[];
    for (final (tag, body) in packets) {
      if (tag == 3) {
        skesks.add(body);
      } else if (tag == 18) {
        seipd = body;
      } else if (tag != 1 && tag != 10) {
        return null;
      }
    }
    if (seipd == null || seipd.isEmpty || seipd[0] != 2) return null;
    for (final skesk in skesks) {
      for (final password in passwords) {
        final sessionKey = _openSkesk(skesk, password, maxS2kBytes);
        if (sessionKey != null) {
          return (_openSeipd(seipd, sessionKey), password);
        }
      }
    }
    return null;
  }

  static Uint8List? _openSkesk(
    Uint8List body,
    List<int> password,
    int maxS2kBytes,
  ) {
    try {
      if (body.length < 6 || body[0] != 6) return null;
      final cipher = body[2];
      if (body[3] != _ocb) return null;
      final s2kLength = body[4];
      if (5 + s2kLength + 15 > body.length) return null;
      final s2k = Uint8List.sublistView(body, 5, 5 + s2kLength);
      final iv = Uint8List.sublistView(body, 5 + s2kLength, 20 + s2kLength);
      final wrapped = Uint8List.sublistView(body, 20 + s2kLength);
      final keyLength = _keyLength(cipher);
      final info = Uint8List.fromList([0xc3, 6, cipher, _ocb]);
      final kek = _hkdf(
        _s2k(s2k, password, keyLength, maxS2kBytes),
        Uint8List(0),
        info,
        keyLength,
      );
      final sessionKey = AesOcb(kek).decrypt(iv, info, wrapped);
      return sessionKey.length == keyLength ? sessionKey : null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List _openSeipd(Uint8List body, Uint8List sessionKey) {
    if (body.length < 4 + 32 + 16) {
      throw const FormatException('Truncated OpenPGP v2 data.');
    }
    final cipher = body[1];
    final chunkOctet = body[3];
    if (body[2] != _ocb || chunkOctet > _maxChunkOctet) {
      throw const FormatException('Unsupported OpenPGP v2 data.');
    }
    final keyLength = _keyLength(cipher);
    if (sessionKey.length != keyLength) {
      throw const FormatException('Wrong session key size.');
    }
    final header = Uint8List.fromList([0xd2, 2, cipher, _ocb, chunkOctet]);
    final derived = _hkdf(
      sessionKey,
      Uint8List.sublistView(body, 4, 36),
      header,
      keyLength + 7,
    );
    final ocb = AesOcb(Uint8List.sublistView(derived, 0, keyLength));
    final iv7 = Uint8List.sublistView(derived, keyLength);
    final chunkSize = 1 << (chunkOctet + 6);
    final data = Uint8List.sublistView(body, 36, body.length - 16);
    final finalTag = Uint8List.sublistView(body, body.length - 16);
    final out = BytesBuilder(copy: false);
    var index = 0;
    for (var offset = 0; offset < data.length; offset += chunkSize + 16) {
      final end = min(offset + chunkSize + 16, data.length);
      out.add(
        ocb.decrypt(
          _nonce(iv7, index++),
          header,
          Uint8List.sublistView(data, offset, end),
        ),
      );
      if (out.length > 8 * 1024 * 1024) {
        throw const FormatException('OpenPGP message too large.');
      }
    }
    final plaintext = out.takeBytes();
    ocb.decrypt(
      _nonce(iv7, index),
      Uint8List.fromList([...header, ..._be64(plaintext.length)]),
      finalTag,
    );
    return plaintext;
  }

  static Uint8List _nonce(Uint8List iv, int index) =>
      Uint8List.fromList([...iv, ..._be64(index)]);

  static List<int> _be64(int value) => [
    for (var shift = 56; shift >= 0; shift -= 8) (value >> shift) & 0xff,
  ];

  /// A key of [length] bytes from S2K specifier [s2k] (simple, salted or
  /// iterated and salted; SHA-256 or SHA-512).
  static Uint8List _s2k(
    List<int> s2k,
    List<int> password,
    int length,
    int maxBytes,
  ) {
    if (s2k.length < 2) throw const FormatException('Malformed S2K.');
    final hash = switch (s2k[1]) {
      8 => sha256,
      10 => sha512,
      _ => throw const FormatException('Unsupported S2K hash.'),
    };
    final sink = _DigestSink();
    final input = hash.startChunkedConversion(sink);
    switch (s2k[0]) {
      case 0:
        input.add(password);
      case 1:
        if (s2k.length != 10) throw const FormatException('Malformed S2K.');
        input
          ..add(s2k.sublist(2, 10))
          ..add(password);
      case 3:
        if (s2k.length != 11) throw const FormatException('Malformed S2K.');
        final coded = s2k[10];
        final count = (16 + (coded & 15)) << ((coded >> 4) + 6);
        if (count > maxBytes) {
          throw const FormatException(
            'OpenPGP password stretching too costly.',
          );
        }
        final unit = [...s2k.sublist(2, 10), ...password];
        var remaining = max(count, unit.length);
        while (remaining > 0) {
          final take = min(remaining, unit.length);
          input.add(take == unit.length ? unit : unit.sublist(0, take));
          remaining -= take;
        }
      default:
        throw const FormatException('Unsupported S2K.');
    }
    input.close();
    final digest = sink.value!.bytes;
    if (digest.length < length) throw const FormatException('S2K too short.');
    return Uint8List.fromList(digest.sublist(0, length));
  }

  /// HKDF with SHA-256 (RFC 5869).
  static Uint8List _hkdf(
    Uint8List ikm,
    Uint8List salt,
    Uint8List info,
    int length,
  ) {
    final prk = Hmac(
      sha256,
      salt.isEmpty ? Uint8List(32) : salt,
    ).convert(ikm).bytes;
    final out = <int>[];
    var previous = <int>[];
    for (var counter = 1; out.length < length; counter++) {
      previous = Hmac(
        sha256,
        prk,
      ).convert([...previous, ...info, counter]).bytes;
      out.addAll(previous);
    }
    return Uint8List.fromList(out.sublist(0, length));
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
