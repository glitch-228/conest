import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/email/aes.dart';
import 'package:conest/src/email/openpgp.dart';
import 'package:conest/src/nostr/secp256k1.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String value) => hexDecode(value)!;

void main() {
  group('AES (FIPS-197 appendix C)', () {
    final plain = _hex('00112233445566778899aabbccddeeff');
    for (final (key, cipher) in [
      ('000102030405060708090a0b0c0d0e0f', '69c4e0d86a7b0430d8cdb78070b4c55a'),
      (
        '000102030405060708090a0b0c0d0e0f1011121314151617',
        'dda97ca4864cdfe06eaf70a0ec0d7191',
      ),
      (
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
        '8ea2b7ca516745bfeafc49904b496089',
      ),
    ]) {
      test('${key.length * 4}-bit key', () {
        final out = Uint8List(16);
        AesBlockCipher(_hex(key)).encryptBlock(plain, 0, out, 0);
        expect(hexEncode(out), cipher);
      });
    }
  });

  group('OpenPGP password messages', () {
    final password = utf8.encode('Qm9vbS1rZXktZm9yLXRlc3RpbmctMTIz');
    final data = Uint8List.fromList(
      List<int>.generate(70000, (index) => index * 13 % 256),
    );

    test('round-trip, armored', () {
      final message = OpenPgpSymmetric.encrypt(data, password);
      final armored = OpenPgpArmor.encode(message);
      expect(armored, startsWith('-----BEGIN PGP MESSAGE-----'));
      expect(
        OpenPgpSymmetric.decrypt(OpenPgpArmor.decode(armored), password),
        data,
      );
    });

    test('a wrong password or a changed byte is refused', () {
      final message = OpenPgpSymmetric.encrypt(data, password);
      expect(
        () => OpenPgpSymmetric.decrypt(message, utf8.encode('wrong')),
        throwsFormatException,
      );
      final changed = Uint8List.fromList(message)..[message.length - 30] ^= 1;
      expect(
        () => OpenPgpSymmetric.decrypt(changed, password),
        throwsFormatException,
      );
      expect(
        () => OpenPgpSymmetric.decrypt(Uint8List(3), password),
        throwsFormatException,
      );
    });

    final gpg = Process.runSync('which', ['gpg']).exitCode == 0;
    final skip = gpg ? null : 'gpg is not installed';

    Future<ProcessResult> runGpg(List<String> args, List<int> input) async {
      final home = Directory.systemTemp.createTempSync('conest_gpg_');
      addTearDown(() => home.deleteSync(recursive: true));
      final process = await Process.start('gpg', [
        '--homedir',
        home.path,
        '--batch',
        '--pinentry-mode',
        'loopback',
        '--passphrase',
        utf8.decode(password),
        ...args,
      ]);
      process.stdin.add(input);
      await process.stdin.close();
      final out = await process.stdout.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      final err = await process.stderr.transform(utf8.decoder).join();
      return ProcessResult(process.pid, await process.exitCode, out, err);
    }

    test('gpg decrypts what Conest encrypts', () async {
      final armored = OpenPgpArmor.encode(
        OpenPgpSymmetric.encrypt(data, password),
      );
      final result = await runGpg(['--decrypt'], utf8.encode(armored));
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, data);
    }, skip: skip);

    test('Conest decrypts what gpg encrypts', () async {
      final result = await runGpg([
        '--symmetric',
        '--armor',
        '--rfc4880',
        '--cipher-algo',
        'AES256',
        '--s2k-digest-algo',
        'SHA256',
        '--s2k-count',
        '65536',
        '--compress-algo',
        'none',
      ], data);
      expect(result.exitCode, 0, reason: result.stderr as String);
      final armored = utf8.decode(result.stdout as List<int>);
      expect(
        OpenPgpSymmetric.decrypt(OpenPgpArmor.decode(armored), password),
        data,
      );
    }, skip: skip);
  });
}
