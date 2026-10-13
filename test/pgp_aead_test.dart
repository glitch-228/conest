import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/email/aes_ocb.dart';
import 'package:conest/src/email/openpgp.dart';
import 'package:conest/src/email/pgp_aead.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String text) {
  final clean = text.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var index = 0; index < clean.length; index += 2)
      int.parse(clean.substring(index, index + 2), radix: 16),
  ]);
}

void main() {
  test('AES-OCB matches RFC 7253 sample results', () {
    final ocb = AesOcb(hex('000102030405060708090A0B0C0D0E0F'));
    final vectors = [
      ('BBAA99887766554433221100', '', '', '785407BFFFC8AD9EDCC5520AC9111EE6'),
      (
        'BBAA99887766554433221101',
        '0001020304050607',
        '0001020304050607',
        '6820B3657B6F615A5725BDA0D3B4EB3A257C9AF1F8F03009',
      ),
      (
        'BBAA99887766554433221102',
        '0001020304050607',
        '',
        '81017F8203F081277152FADE694A0A00',
      ),
      (
        'BBAA99887766554433221103',
        '',
        '0001020304050607',
        '45DD69F8F5AAE72414054CD1F35D82760B2CD00D2F99BFA9',
      ),
      (
        'BBAA99887766554433221104',
        '000102030405060708090A0B0C0D0E0F',
        '000102030405060708090A0B0C0D0E0F',
        '571D535B60B277188BE5147170A9A22C3AD7A4FF3835B8C5'
            '701C1CCEC8FC3358',
      ),
      (
        'BBAA99887766554433221107',
        '000102030405060708090A0B0C0D0E0F1011121314151617',
        '000102030405060708090A0B0C0D0E0F1011121314151617',
        '1CA2207308C87C010756104D8840CE1952F09673A448A122'
            'C92C62241051F57356D7F3C90BB0E07F',
      ),
      (
        'BBAA9988776655443322110A',
        '000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F',
        '000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F',
        'BD6F6C496201C69296C11EFD138A467ABD3C707924B964DE'
            'AFFC40319AF5A48540FBBA186C5553C68AD9F592A79A4240',
      ),
    ];
    for (final (nonce, associated, plain, cipher) in vectors) {
      final encrypted = ocb.encrypt(hex(nonce), hex(associated), hex(plain));
      expect(encrypted, hex(cipher), reason: nonce);
      expect(
        ocb.decrypt(hex(nonce), hex(associated), encrypted),
        hex(plain),
        reason: nonce,
      );
    }
    final changed = hex(vectors[1].$4)..[0] ^= 1;
    expect(
      () => ocb.decrypt(hex(vectors[1].$1), hex(vectors[1].$2), changed),
      throwsFormatException,
    );
  });

  test('reads RFC 9580\'s AEAD-OCB sample message', () {
    final message = OpenPgpArmor.decode(
      '-----BEGIN PGP MESSAGE-----\n\n'
      'wz8GHQcCCwMIVqKY0vXjZFP/z8xcEWZO2520JZDX3EawckG2EsOBLP/76gDyNHsl\n'
      'ZBEj+IeuYNT9YU4IN9gZ02zSaQIHAgYgpmH3MfyaMDK1YjMmAn46XY21dI6+/wsM\n'
      'WRDQns3WQf+f04VidYA1vEl1TOG/P/+n2tCjuBBPUTPPQqQQCoPu9MobSAGohGv0\n'
      'K82nyM6dZeIS8wHLzZj9yt5pSod61CRzI/boVw==\n'
      '-----END PGP MESSAGE-----\n',
    );
    // The sample stretches the password over 65 MB; mail is refused that.
    expect(OpenPgpAead.decrypt(message, [utf8.encode('password')]), isNull);
    final (inner, password) = OpenPgpAead.decrypt(
      message,
      [utf8.encode('wrong'), utf8.encode('password')],
      maxS2kBytes: 65011712,
      iteratedS2k: true,
    )!;
    expect(utf8.decode(password), 'password');
    expect(
      inner,
      hex(
        'cb 13 62 00 00 00 00 00 48 65 6c 6c 6f 2c 20 77 6f 72 6c 64 21 '
        'd5 0e ae 6a a1 64 9b 56 aa 83 5b 26 13 90 2b d2',
      ),
    );
  });

  test('writes messages it reads back, larger than a chunk', () {
    final inner = Uint8List.fromList(
      List.generate(200000, (index) => index % 251),
    );
    final message = OpenPgpAead.encrypt(inner, utf8.encode('secret'));
    expect(OpenPgpAead.decrypt(message, [utf8.encode('other')]), isNull);
    final (read, _) = OpenPgpAead.decrypt(message, [utf8.encode('secret')])!;
    expect(read, inner);

    // A changed byte, or a dropped last chunk, is refused.
    final changed = Uint8List.fromList(message)..[message.length - 40] ^= 1;
    expect(
      () => OpenPgpAead.decrypt(changed, [utf8.encode('secret')]),
      throwsFormatException,
    );
    final empty = OpenPgpAead.encrypt(Uint8List(0), utf8.encode('secret'));
    expect(OpenPgpAead.decrypt(empty, [utf8.encode('secret')])!.$1, isEmpty);
  });

  test('a mail full of password packets is not tried', () {
    final message = OpenPgpAead.encrypt(
      Uint8List.fromList([1, 2, 3]),
      utf8.encode('secret'),
    );
    final packets = OpenPgpSymmetric.readPackets(message);
    final skesk = OpenPgpSymmetric.packet(3, packets.first.$2);
    Uint8List withSkesks(int count) => Uint8List.fromList([
      for (var index = 0; index < count; index++) ...skesk,
      ...OpenPgpSymmetric.packet(18, packets.last.$2),
    ]);
    expect(OpenPgpAead.decrypt(withSkesks(5), [utf8.encode('secret')]), isNull);
    expect(
      OpenPgpAead.decrypt(withSkesks(4), [utf8.encode('secret')]),
      isNotNull,
    );
  });
}
