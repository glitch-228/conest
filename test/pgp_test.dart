import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/email/openpgp.dart';
import 'package:conest/src/email/pgp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late PgpSecretKey alice;
  late PgpSecretKey bob;

  setUpAll(() async {
    alice = await PgpSecretKey.generate('<alice@example.org>');
    bob = await PgpSecretKey.generate('<bob@example.org>');
  });

  test('a key reads back from its own bytes', () async {
    final parsed = await PgpPublicKey.parse(alice.publicKey.bytes);
    expect(parsed.fingerprintHex, alice.publicKey.fingerprintHex);
    expect(parsed.userIds, ['<alice@example.org>']);
    expect(
      parsed.encryptionSubkey.fingerprint,
      alice.publicKey.encryptionSubkey.fingerprint,
    );
    expect(parsed.bytes, alice.publicKey.bytes);
    final restored = await PgpSecretKey.fromJson(
      jsonDecode(jsonEncode(alice.toJson())) as Map<String, dynamic>,
    );
    expect(restored.publicKey.bytes, alice.publicKey.bytes);
  });

  test('a message decrypts for each recipient with a good signature', () async {
    final data = Uint8List.fromList(utf8.encode('Hello Bob'));
    final message = await Pgp.encrypt(data, [bob.publicKey], signer: alice);

    final forBob = await Pgp.decrypt(message, bob, senders: [alice.publicKey]);
    expect(utf8.decode(forBob.data), 'Hello Bob');
    expect(forBob.signed, isTrue);
    expect(forBob.signer?.fingerprintHex, alice.publicKey.fingerprintHex);

    // The sender's own copy stays readable.
    final forAlice = await Pgp.decrypt(message, alice);
    expect(utf8.decode(forAlice.data), 'Hello Bob');
    expect(forAlice.signer, isNull, reason: 'no sender keys were given');

    final eve = await PgpSecretKey.generate('<eve@example.org>');
    await expectLater(Pgp.decrypt(message, eve), throwsFormatException);

    // A signature checked against the wrong key is not good.
    final wrong = await Pgp.decrypt(message, bob, senders: [eve.publicKey]);
    expect(wrong.signed, isTrue);
    expect(wrong.signer, isNull);
  });

  test('a changed message is refused', () async {
    final message = await Pgp.encrypt(Uint8List.fromList(List.filled(100, 7)), [
      bob.publicKey,
    ], signer: alice);
    final tampered = Uint8List.fromList(message);
    tampered[tampered.length - 30] ^= 1;
    await expectLater(Pgp.decrypt(tampered, bob), throwsFormatException);
  });

  test('a subkey the key did not sign is not used', () async {
    // Alice's primary key and user id with Bob's subkey and binding.
    final alicePackets = OpenPgpSymmetric.readPackets(alice.publicKey.bytes);
    final bobPackets = OpenPgpSymmetric.readPackets(bob.publicKey.bytes);
    final spliced = Uint8List.fromList([
      for (final (tag, body) in [
        ...alicePackets.take(3),
        ...bobPackets.skip(3),
      ])
        ...OpenPgpSymmetric.packet(tag, body),
    ]);
    await expectLater(PgpPublicKey.parse(spliced), throwsFormatException);

    // An unsigned user id is dropped too.
    final noCertification = Uint8List.fromList([
      for (final (tag, body) in alicePackets)
        if (tag != 2 || body[1] != 0x13) ...OpenPgpSymmetric.packet(tag, body),
    ]);
    await expectLater(
      PgpPublicKey.parse(noCertification),
      throwsFormatException,
    );
  });

  group('with gpg', () {
    late Directory home;
    late Map<String, String> environment;
    var available = false;
    late String bobFingerprint;
    late PgpPublicKey gpgBob;

    Future<ProcessResult> gpg(
      List<String> arguments, {
      List<int>? stdin,
    }) async {
      final process = await Process.start('gpg', [
        '--batch',
        '--pinentry-mode',
        'loopback',
        '--passphrase',
        '',
        '--trust-model',
        'always',
        ...arguments,
      ], environment: environment);
      final out = BytesBuilder();
      final err = StringBuffer();
      final reading = [
        process.stdout.forEach(out.add),
        process.stderr.transform(utf8.decoder).forEach(err.write),
      ];
      if (stdin != null) process.stdin.add(stdin);
      await process.stdin.close();
      await Future.wait(reading);
      return ProcessResult(
        process.pid,
        await process.exitCode,
        out.takeBytes(),
        err.toString(),
      );
    }

    setUpAll(() async {
      try {
        available = (await Process.run('gpg', ['--version'])).exitCode == 0;
      } on ProcessException {
        available = false;
      }
      if (!available) return;
      home = await Directory.systemTemp.createTemp('conest-gpg');
      environment = {'GNUPGHOME': home.path};
      final created = await gpg([
        '--quick-gen-key',
        'Bob <bob@example.org>',
        'ed25519',
        'sign',
        'never',
      ]);
      expect(created.exitCode, 0, reason: '${created.stderr}');
      final listing = await gpg(['--list-keys', '--with-colons']);
      bobFingerprint = utf8
          .decode(listing.stdout as List<int>)
          .split('\n')
          .firstWhere((line) => line.startsWith('fpr:'))
          .split(':')[9];
      final added = await gpg([
        '--quick-add-key',
        bobFingerprint,
        'cv25519',
        'encr',
        'never',
      ]);
      expect(added.exitCode, 0, reason: '${added.stderr}');
      final exported = await gpg(['--export', bobFingerprint]);
      gpgBob = await PgpPublicKey.parse(
        Uint8List.fromList(exported.stdout as List<int>),
      );
      final ours = File('${home.path}/alice.pgp')
        ..writeAsBytesSync(alice.publicKey.bytes);
      final imported = await gpg(['--import', ours.path]);
      expect(imported.exitCode, 0, reason: '${imported.stderr}');
    });

    tearDownAll(() async {
      if (!available) return;
      await Process.run('gpgconf', [
        '--kill',
        'gpg-agent',
      ], environment: environment);
      await home.delete(recursive: true);
    });

    test('reads gpg\'s key', () {
      if (!available) return markTestSkipped('gpg is not installed');
      expect(gpgBob.fingerprintHex, bobFingerprint);
      expect(gpgBob.userIds, ['Bob <bob@example.org>']);
    });

    test('gpg reads and checks what Conest sends', () async {
      if (!available) return markTestSkipped('gpg is not installed');
      final message = await Pgp.encrypt(
        Uint8List.fromList(utf8.encode('From Conest to gpg')),
        [gpgBob],
        signer: alice,
      );
      final result = await gpg([
        '--status-fd',
        '2',
        '--decrypt',
      ], stdin: message);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(utf8.decode(result.stdout as List<int>), 'From Conest to gpg');
      expect(
        result.stderr as String,
        contains('VALIDSIG ${alice.publicKey.fingerprintHex}'),
      );
    });

    test('Conest reads and checks what gpg sends', () async {
      if (!available) return markTestSkipped('gpg is not installed');
      for (final extra in [
        <String>[], // compressed, gpg's default
        ['--compress-algo', 'none'],
        ['--compress-algo', 'zip'],
        ['--textmode'],
      ]) {
        final result = await gpg([
          '--encrypt',
          '--sign',
          '--local-user',
          bobFingerprint,
          '--recipient',
          alice.publicKey.fingerprintHex,
          ...extra,
        ], stdin: utf8.encode('From gpg to Conest\n${'x' * 3000}'));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final decrypted = await Pgp.decrypt(
          Uint8List.fromList(result.stdout as List<int>),
          alice,
          senders: [gpgBob],
        );
        // Text mode keeps lines in CR LF form, as MIME has them.
        expect(
          utf8.decode(decrypted.data).replaceAll('\r\n', '\n'),
          'From gpg to Conest\n${'x' * 3000}',
          reason: '$extra',
        );
        expect(
          decrypted.signer?.fingerprintHex,
          bobFingerprint,
          reason: '$extra',
        );
      }
    });

    test('Conest reads armored gpg output', () async {
      if (!available) return markTestSkipped('gpg is not installed');
      final result = await gpg([
        '--armor',
        '--encrypt',
        '--recipient',
        alice.publicKey.fingerprintHex,
      ], stdin: utf8.encode('armored'));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final decrypted = await Pgp.decrypt(
        OpenPgpArmor.decode(utf8.decode(result.stdout as List<int>)),
        alice,
      );
      expect(utf8.decode(decrypted.data), 'armored');
      expect(decrypted.signed, isFalse);
    });
  });

  test(
    'a key stuffed with signatures is read quickly, a huge one not',
    () async {
      final packets = OpenPgpSymmetric.readPackets(alice.publicKey.bytes);
      final certification = packets[2];
      final stuffed = Uint8List.fromList([
        for (final (index, (tag, body)) in packets.indexed) ...[
          ...OpenPgpSymmetric.packet(tag, body),
          if (index == 2)
            for (var copy = 0; copy < 400; copy++)
              ...OpenPgpSymmetric.packet(2, certification.$2),
        ],
      ]);
      expect(stuffed.length, lessThan(maxKeyBytes));
      final watch = Stopwatch()..start();
      final parsed = await PgpPublicKey.parse(stuffed);
      expect(watch.elapsedMilliseconds, lessThan(500));
      expect(parsed.fingerprintHex, alice.publicKey.fingerprintHex);
      final huge = Uint8List.fromList([
        ...stuffed,
        for (var copy = 0; copy < 200; copy++)
          ...OpenPgpSymmetric.packet(2, certification.$2),
      ]);
      await expectLater(PgpPublicKey.parse(huge), throwsFormatException);
    },
  );

  test('others\' certifications do not hide the key\'s own', () async {
    final eveCertification = OpenPgpSymmetric.readPackets(
      (await PgpSecretKey.generate('<eve@example.org>')).publicKey.bytes,
    )[2];
    final packets = OpenPgpSymmetric.readPackets(alice.publicKey.bytes);
    final withOthers = Uint8List.fromList([
      for (final (index, (tag, body)) in packets.indexed) ...[
        ...OpenPgpSymmetric.packet(tag, body),
        if (index == 1)
          for (var copy = 0; copy < 6; copy++)
            ...OpenPgpSymmetric.packet(2, eveCertification.$2),
      ],
    ]);
    final parsed = await PgpPublicKey.parse(withOthers);
    expect(parsed.userIds, ['<alice@example.org>']);
    // An honest key costs two checks; a budget of one is not enough.
    await expectLater(
      PgpPublicKey.parse(alice.publicKey.bytes, budget: PgpCheckBudget(1)),
      throwsFormatException,
    );
    expect(
      (await PgpPublicKey.parse(
        alice.publicKey.bytes,
        budget: PgpCheckBudget(2),
      )).fingerprintHex,
      alice.publicKey.fingerprintHex,
    );
  });

  test('many packets for no key do not hide the one for this key', () async {
    final message = await Pgp.encrypt(
      Uint8List.fromList(utf8.encode('found')),
      [bob.publicKey],
      signer: alice,
    );
    final packets = OpenPgpSymmetric.readPackets(message);
    final forBob = packets.firstWhere(
      (packet) =>
          packet.$1 == 1 &&
          _sameBytes(
            packet.$2.sublist(1, 9),
            bob.publicKey.encryptionSubkey.keyId,
          ),
    );
    final anonymous = Uint8List.fromList(forBob.$2)..fillRange(1, 9, 0);
    final crowded = Uint8List.fromList([
      for (var index = 0; index < 50; index++)
        ...OpenPgpSymmetric.packet(1, anonymous..[20] ^= 1),
      for (final (tag, body) in packets) ...OpenPgpSymmetric.packet(tag, body),
    ]);
    final read = await Pgp.decrypt(crowded, bob);
    expect(utf8.decode(read.data), 'found');
  });
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
