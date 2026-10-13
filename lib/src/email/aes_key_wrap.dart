import 'dart:typed_data';

import 'aes.dart';

/// AES key wrap (RFC 3394), as OpenPGP's ECDH uses it to carry a session
/// key.
abstract final class AesKeyWrap {
  static const List<int> _iv = [
    0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, //
  ];

  /// Wraps [plain] (a multiple of 8 bytes, at least 16) under [kek].
  static Uint8List wrap(Uint8List kek, Uint8List plain) {
    if (plain.length % 8 != 0 || plain.length < 16) {
      throw ArgumentError('Key wrap takes whole 8-byte blocks, two or more.');
    }
    final cipher = AesBlockCipher(kek);
    final n = plain.length ~/ 8;
    final a = Uint8List.fromList(_iv);
    final r = [
      for (var i = 0; i < n; i++)
        Uint8List.sublistView(plain, i * 8, i * 8 + 8),
    ].map(Uint8List.fromList).toList();
    final block = Uint8List(16);
    for (var j = 0; j <= 5; j++) {
      for (var i = 0; i < n; i++) {
        block
          ..setRange(0, 8, a)
          ..setRange(8, 16, r[i]);
        cipher.encryptBlock(block, 0, block, 0);
        final t = n * j + i + 1;
        a.setRange(0, 8, block);
        for (var k = 0; k < 8; k++) {
          a[7 - k] ^= (t >> (8 * k)) & 0xff;
        }
        r[i].setRange(0, 8, block, 8);
      }
    }
    return Uint8List.fromList([...a, for (final part in r) ...part]);
  }

  /// Unwraps [wrapped]; throws [FormatException] when its check value is
  /// wrong (the wrong key, or a changed message).
  static Uint8List unwrap(Uint8List kek, Uint8List wrapped) {
    if (wrapped.length % 8 != 0 || wrapped.length < 24) {
      throw const FormatException('Not a wrapped key.');
    }
    final cipher = AesBlockCipher(kek);
    final n = wrapped.length ~/ 8 - 1;
    final a = Uint8List.fromList(wrapped.sublist(0, 8));
    final r = [
      for (var i = 0; i < n; i++)
        Uint8List.fromList(wrapped.sublist(8 + i * 8, 16 + i * 8)),
    ];
    final block = Uint8List(16);
    for (var j = 5; j >= 0; j--) {
      for (var i = n - 1; i >= 0; i--) {
        final t = n * j + i + 1;
        for (var k = 0; k < 8; k++) {
          a[7 - k] ^= (t >> (8 * k)) & 0xff;
        }
        block
          ..setRange(0, 8, a)
          ..setRange(8, 16, r[i]);
        cipher.decryptBlock(block, 0, block, 0);
        a.setRange(0, 8, block);
        r[i].setRange(0, 8, block, 8);
      }
    }
    var difference = 0;
    for (var k = 0; k < 8; k++) {
      difference |= a[k] ^ _iv[k];
    }
    if (difference != 0) throw const FormatException('Key unwrap failed.');
    return Uint8List.fromList([for (final part in r) ...part]);
  }
}
