import 'dart:typed_data';

import 'package:conest/src/email/aes.dart';
import 'package:conest/src/email/aes_key_wrap.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

void main() {
  test('AES decrypts what it encrypts (FIPS-197 C.3)', () {
    final key = hex(
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
    );
    final plain = hex('00112233445566778899aabbccddeeff');
    final cipher = AesBlockCipher(key);
    final out = Uint8List(16);
    cipher.encryptBlock(plain, 0, out, 0);
    expect(out, hex('8ea2b7ca516745bfeafc49904b496089'));
    final back = Uint8List(16);
    cipher.decryptBlock(out, 0, back, 0);
    expect(back, plain);
  });

  // RFC 3394, 4.1 and 4.6.
  test('key wrap matches RFC 3394', () {
    final data = hex('00112233445566778899aabbccddeeff');
    final kek128 = hex('000102030405060708090a0b0c0d0e0f');
    final wrapped = AesKeyWrap.wrap(kek128, data);
    expect(wrapped, hex('1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5'));
    expect(AesKeyWrap.unwrap(kek128, wrapped), data);

    final kek256 = hex(
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
    );
    final data256 = hex(
      '00112233445566778899aabbccddeeff000102030405060708090a0b0c0d0e0f',
    );
    expect(
      AesKeyWrap.wrap(kek256, data256),
      hex(
        '28c9f404c4b810f4cbccb35cfb87f8263f5786e2d80ed326'
        'cbc7f0e71a99f43bfb988b9b7a02dd21',
      ),
    );
    // The wrong key is caught.
    expect(() => AesKeyWrap.unwrap(kek256, wrapped), throwsFormatException);
  });
}
