import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/email/delta_mail.dart';
import 'package:conest/src/email/mime.dart';
import 'package:conest/src/email/openpgp.dart';
import 'package:conest/src/email/pgp.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(String text) => Uint8List.fromList(latin1.encode(text));

void main() {
  group('MIME', () {
    test('reads nested parts, encodings and encoded words', () {
      final entity = MimeEntity.parse(
        bytes(
          'From: =?utf-8?b?w4lsb2RpZQ==?= <e@example.org>\r\n'
          'Subject: =?utf-8?q?caf=C3=A9?= =?utf-8?q?_ouvert?=\r\n'
          'Content-Type: multipart/mixed;\r\n boundary="outer"\r\n'
          '\r\n'
          'preamble\r\n'
          '--outer\r\n'
          'Content-Type: multipart/alternative; boundary=inner\r\n'
          '\r\n'
          '--inner\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          'Content-Transfer-Encoding: quoted-printable\r\n'
          '\r\n'
          'caf=C3=A9 au =\r\nlait\r\n'
          '--inner--\r\n'
          '--outerx\r\n'
          'not a delimiter\r\n'
          '--outer\r\n'
          'Content-Type: application/octet-stream\r\n'
          "Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.txt\r\n"
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'aGVs\r\nbG8=\r\n'
          '--outer\r\n'
          '\r\n'
          'no headers\r\n'
          '--outer--\r\n',
        ),
      );
      expect(entity.headers['from'], 'Élodie <e@example.org>');
      expect(entity.headers['subject'], 'café ouvert');
      expect(entity.parts, hasLength(3));
      final alternative = entity.parts[0];
      expect(alternative.mimeType, 'multipart/alternative');
      expect(alternative.parts.single.text, 'café au lait');
      expect(
        latin1.decode(entity.parts[0].raw),
        contains('--outerx\r\nnot a delimiter'),
        reason: 'a longer boundary is not ours',
      );
      final attachment = entity.parts[1];
      expect(attachment.fileName, 'résumé.txt');
      expect(attachment.disposition, 'attachment');
      expect(utf8.decode(attachment.body), 'hello');
      expect(entity.parts[2].text, 'no headers');
      expect(entity.parts[2].mimeType, 'text/plain');
    });

    test('reads LF-only mail', () {
      final entity = MimeEntity.parse(
        bytes(
          'Content-Type: multipart/mixed; boundary=b\n\n'
          '--b\nContent-Type: text/plain\n\nhi\n--b--\n',
        ),
      );
      expect(entity.parts.single.text, 'hi');
    });
  });

  group('Delta Chat mail', () {
    late PgpSecretKey alice;
    late PgpSecretKey bob;
    late PgpSecretKey eve;
    final date = DateTime.utc(2026, 10, 13, 12, 30);

    setUpAll(() async {
      alice = await PgpSecretKey.generate('<alice@example.org>');
      bob = await PgpSecretKey.generate('<bob@example.org>');
      eve = await PgpSecretKey.generate('<eve@example.org>');
    });

    Future<String> fromAlice(
      String text, {
      List<(String, String)> extra = const [],
    }) => DeltaMail.build(
      key: alice,
      from: 'alice@example.org',
      fromName: 'Alice Ä',
      to: [(addr: 'bob@example.org', key: bob.publicKey)],
      gossip: [(addr: 'bob@example.org', key: bob.publicKey)],
      text: text,
      messageId: 'Mr.1@example.org',
      date: date,
      extraHeaders: extra,
      requestReadReceipt: true,
      random: Random(1),
    );

    test('a message reads back, signed, with protected headers', () async {
      final mail = await fromAlice(
        'Hello Bob\n\nsecond line',
        extra: [('Secure-Join', 'vc-contact-confirm')],
      );
      // Nothing but routing outside.
      final outer = mail.substring(0, mail.indexOf('\r\n\r\n'));
      expect(outer, isNot(contains('Secure-Join')));
      expect(outer, isNot(contains('bob@')));
      expect(outer, contains('Subject: [...]'));

      final read = await DeltaMail.read(bytes(mail), bob);
      expect(read, isNotNull);
      expect(read!.from, 'alice@example.org');
      expect(read.fromName, 'Alice Ä');
      expect(read.to, ['bob@example.org']);
      expect(read.messageId, 'Mr.1@example.org');
      expect(read.date, date);
      expect(read.encrypted, isTrue);
      expect(read.isChat, isTrue);
      expect(read.text, 'Hello Bob\n\nsecond line');
      expect(read.secureJoin, 'vc-contact-confirm');
      expect(read.signer?.fingerprintHex, alice.publicKey.fingerprintHex);
      expect(read.autocryptKey?.fingerprintHex, alice.publicKey.fingerprintHex);
      expect(
        read.gossip['bob@example.org']?.fingerprintHex,
        bob.publicKey.fingerprintHex,
      );
      expect(read.header('chat-disposition-notification-to'), isNotNull);

      // Someone else cannot read it.
      expect(await DeltaMail.read(bytes(mail), eve), isNull);
    });

    test('outer headers cannot change what a signed message means', () async {
      final mail = await fromAlice('just text');
      final wrapped = mail.replaceFirst(
        'Chat-Version: 1.0\r\n',
        'Chat-Version: 1.0\r\nSecure-Join: vc-contact-confirm\r\n'
            'Chat-Group-ID: forged\r\n',
      );
      final read = await DeltaMail.read(bytes(wrapped), bob);
      expect(read!.signer, isNotNull);
      expect(read.secureJoin, isNull);
      expect(read.header('chat-group-id'), isNull);
    });

    test('a From that differs inside is refused', () async {
      final mail = await fromAlice('hi');
      final forged = mail.replaceFirst(
        'From: <alice@example.org>',
        'From: <mallory@example.org>',
      );
      expect(await DeltaMail.read(bytes(forged), bob), isNull);
    });

    test('gossip about people the mail is not to is not read', () async {
      final mail = await DeltaMail.build(
        key: alice,
        from: 'alice@example.org',
        to: [(addr: 'bob@example.org', key: bob.publicKey)],
        gossip: [
          (addr: 'bob@example.org', key: bob.publicKey),
          (addr: 'eve@example.org', key: eve.publicKey),
        ],
        text: 'hi',
        messageId: 'Mr.6@example.org',
        date: date,
      );
      final read = await DeltaMail.read(bytes(mail), bob);
      expect(read!.gossip.keys, ['bob@example.org']);
    });

    test('a key claiming someone\'s address signs only as itself', () async {
      final mail = await DeltaMail.build(
        key: eve,
        from: 'alice@example.org',
        to: [(addr: 'bob@example.org', key: bob.publicKey)],
        text: 'I am Alice',
        messageId: 'Mr.2@example.org',
        date: date,
      );
      final read = await DeltaMail.read(
        bytes(mail),
        bob,
        knownKeys: (addr) => [alice.publicKey],
      );
      expect(read!.signer?.fingerprintHex, eve.publicKey.fingerprintHex);
      expect(
        read.signer?.fingerprintHex,
        isNot(alice.publicKey.fingerprintHex),
      );
    });

    test(
      'the Securejoin request has the shape chatmail lets through',
      () async {
        final mail = DeltaMail.buildRequest(
          key: bob,
          from: 'bob@example.org',
          to: 'alice@example.org',
          step: 'vc-request',
          invitenumber: 'inv123',
          messageId: 'Mr.3@example.org',
          date: date,
          random: Random(2),
        );
        final entity = MimeEntity.parse(bytes(mail));
        // chatmail's filtermail: a multipart with exactly one text/plain part
        // whose body is the step.
        expect(entity.mimeType, 'multipart/mixed');
        expect(entity.parts, hasLength(1));
        expect(entity.parts.single.mimeType, 'text/plain');
        expect(
          entity.parts.single.text.trim().toLowerCase(),
          'secure-join: vc-request',
        );
        expect(entity.headers['secure-join'], 'vc-request');

        final read = await DeltaMail.read(bytes(mail), alice);
        expect(read!.encrypted, isFalse);
        expect(read.signer, isNull);
        expect(read.secureJoin, 'vc-request');
        expect(read.header('secure-join-invitenumber'), 'inv123');
        expect(read.autocryptKey?.fingerprintHex, bob.publicKey.fingerprintHex);
      },
    );

    test('a read receipt names the message it is for', () async {
      final mail = await DeltaMail.buildReadReceipt(
        key: bob,
        from: 'bob@example.org',
        to: (addr: 'alice@example.org', key: alice.publicKey),
        original: 'Mr.1@example.org',
        additional: ['Mr.0@example.org'],
        messageId: 'Mr.4@example.org',
        date: date,
      );
      final read = await DeltaMail.read(bytes(mail), alice);
      expect(read!.receiptsFor, ['Mr.1@example.org', 'Mr.0@example.org']);
      expect(read.text, isEmpty);
      expect(read.signer?.fingerprintHex, bob.publicKey.fingerprintHex);
    });

    test('reads Delta Chat\'s single-part flowed text', () async {
      final inner =
          'Content-Type: text/plain; charset="utf-8"; format=flowed; '
          'delsp=no; protected-headers="v1"\r\n'
          'From: <alice@example.org>\r\n'
          'To: <bob@example.org>\r\n'
          'Message-ID: <Mr.5@example.org>\r\n'
          'Chat-Version: 1.0\r\n'
          '${foldedHeader('Autocrypt', AutocryptHeader(addr: 'alice@example.org', keydata: alice.publicKey.bytes, mutual: true).encode())}\r\n'
          'Content-Transfer-Encoding: quoted-printable\r\n'
          '\r\n'
          'This is a long line that =\r\nwas flowed \r\nacross lines\r\n'
          '-- \r\nsig\r\n';
      final encrypted = await Pgp.encrypt(
        Uint8List.fromList(utf8.encode(inner)),
        [bob.publicKey],
        signer: alice,
      );
      final mail =
          'From: <alice@example.org>\r\n'
          'Message-ID: <Mr.5@example.org>\r\n'
          'Content-Type: multipart/encrypted; protocol="application/pgp-encrypted"; boundary="x"\r\n'
          '\r\n--x\r\nContent-Type: application/pgp-encrypted\r\n\r\nVersion: 1\r\n'
          '--x\r\nContent-Type: application/octet-stream\r\n\r\n'
          '${OpenPgpArmor.encode(encrypted)}\r\n--x--\r\n';
      final read = await DeltaMail.read(bytes(mail), bob);
      expect(
        read!.text,
        'This is a long line that was flowed across lines\n-- \nsig',
      );
      expect(read.signer?.fingerprintHex, alice.publicKey.fingerprintHex);
    });

    test('Autocrypt headers with unknown critical attributes are refused', () {
      expect(
        AutocryptHeader.parse('addr=a@b.org; keydata=AAAA; unknown=1'),
        isNull,
      );
      expect(
        AutocryptHeader.parse('addr=a@b.org; _optional=1; keydata=AA AA'),
        isNotNull,
      );
    });
  });
}
