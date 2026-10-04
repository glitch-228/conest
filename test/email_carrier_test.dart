import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/email/carrier_mail.dart';
import 'package:conest/src/email/smtp.dart';
import 'package:conest/src/email_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_mail_server.dart';

void main() {
  late FakeMailServer server;
  final channels = <EmailCarrierChannel>[];

  setUp(() async {
    server = await FakeMailServer.start();
    channels.clear();
  });
  tearDown(() async {
    for (final channel in channels) {
      await channel.stop();
    }
    await server.close();
  });

  EmailCarrierConfig account(String name) => EmailCarrierConfig(
    mail: '$name@chat.test',
    password: 'pw-$name',
    imapHost: 'chat.test',
    imapPort: 993,
    smtpHost: 'chat.test',
    smtpPort: 465,
    mailboxKey: EmailCarrierConfig.newMailboxKey(),
  );

  EmailCarrierChannel channel(
    EmailCarrierConfig config,
    List<(String, Uint8List)> received, {
    void Function(int, int)? onCursor,
  }) {
    final result = EmailCarrierChannel(
      config: config,
      connector: server.connect,
      onFrame: (sender, frame) => received.add((sender, frame)),
      onCursor: onCursor,
      pollInterval: const Duration(milliseconds: 200),
    );
    channels.add(result);
    return result;
  }

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  final frame = Uint8List.fromList(List<int>.generate(5000, (i) => i % 11));

  test('a frame arrives as encrypted mail and the mail is deleted', () async {
    final aliceGot = <(String, Uint8List)>[];
    final bobGot = <(String, Uint8List)>[];
    final alice = channel(account('alice'), aliceGot)..start();
    final bob = channel(account('bob'), bobGot)..start();
    await until(() => bob.state == EmailCarrierState.connected);

    await alice.sendFrame(bob.localAddress!, frame);
    await until(() => bobGot.isNotEmpty);
    expect(bobGot.single.$1, 'alice@chat.test');
    expect(bobGot.single.$2, frame);
    await until(() => server.mailboxes['bob@chat.test']!.isEmpty);
    expect(aliceGot, isEmpty);
  });

  test('other mail in the inbox is left alone and never downloaded', () async {
    final bobConfig = account('bob');
    final bobGot = <(String, Uint8List)>[];
    final cursors = <int>[];
    final bob = channel(
      bobConfig,
      bobGot,
      onCursor: (_, uid) => cursors.add(uid),
    )..start();
    await until(() => bob.state == EmailCarrierState.connected);
    server.deliver(
      'bob@chat.test',
      'From: <friend@else.test>\r\nSubject: hi\r\n\r\nhello\r\n',
    );
    // Carrier mail sealed for another mailbox key is not ours either.
    server.deliver(
      'bob@chat.test',
      CarrierMail.build(
        from: 'eve@chat.test',
        to: 'bob@chat.test',
        mailboxKey: EmailCarrierConfig.newMailboxKey(),
        frame: frame,
        date: DateTime.utc(2026),
      ),
    );
    final eveUid = server.mailboxes['bob@chat.test']!.last.uid;
    await until(() => cursors.contains(eveUid));
    expect(bobGot, isEmpty);
    expect(server.mailboxes['bob@chat.test'], hasLength(2));
    expect(server.fetched, isNot(contains(eveUid - 1)));
  });

  test('mail from before the account was set up is never read', () async {
    for (var index = 0; index < 50; index++) {
      server.deliver(
        'bob@chat.test',
        CarrierMail.build(
          from: 'old@chat.test',
          to: 'bob@chat.test',
          mailboxKey: EmailCarrierConfig.newMailboxKey(),
          frame: frame,
          date: DateTime.utc(2026),
        ),
      );
    }
    final cursors = <int>[];
    final bob = channel(
      account('bob'),
      [],
      onCursor: (_, uid) => cursors.add(uid),
    )..start();
    await until(() => bob.state == EmailCarrierState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cursors.first, server.mailboxes['bob@chat.test']!.last.uid);
    expect(server.fetched, isEmpty);
  });

  test('mail is read without IDLE by polling', () async {
    await server.close();
    server = await FakeMailServer.start(idle: false);
    final bobGot = <(String, Uint8List)>[];
    final alice = channel(account('alice'), [])..start();
    final bob = channel(account('bob'), bobGot)..start();
    await until(() => bob.state == EmailCarrierState.connected);
    await alice.sendFrame(bob.localAddress!, frame);
    await until(() => bobGot.isNotEmpty);
  });

  test('reading resumes after the server drops the connection', () async {
    final bobGot = <(String, Uint8List)>[];
    final alice = channel(account('alice'), [])..start();
    final bob = channel(account('bob'), bobGot)..start();
    await until(() => bob.state == EmailCarrierState.connected);
    await server.dropConnections();
    await alice.sendFrame(bob.localAddress!, frame);
    await until(() => bobGot.isNotEmpty);
  });

  test('a stopped channel sends nothing', () async {
    final alice = channel(account('alice'), []);
    final bob = channel(account('bob'), []);
    await expectLater(
      alice.sendFrame(bob.localAddress!, frame),
      throwsStateError,
    );
  });

  test('a wrong password is reported', () async {
    server.passwords['bob@chat.test'] = 'right';
    await expectLater(
      EmailCarrierChannel.checkLogin(account('bob'), connector: server.connect),
      throwsA(anything),
    );
    await EmailCarrierChannel.checkLogin(
      account('carol'),
      connector: server.connect,
    );
    expect(server.passwords, contains('carol@chat.test'));
  });

  test('unencrypted mail is refused by a chatmail-like server', () async {
    await expectLater(
      SmtpSender.send(
        host: 'chat.test',
        port: 465,
        user: 'alice@chat.test',
        password: 'pw',
        from: 'alice@chat.test',
        to: 'bob@chat.test',
        message: 'From: <alice@chat.test>\r\nSubject: hi\r\n\r\nplain\r\n',
        connector: server.connect,
      ),
      throwsA(isA<SmtpException>().having((e) => e.code, 'code', 523)),
    );
  });

  group('addresses and accounts', () {
    test('addresses round-trip and are checked', () {
      final address = EmailAddress(
        mail: 'abc@chat.test',
        mailboxKey: EmailCarrierConfig.newMailboxKey(),
      );
      final parsed = EmailAddress.tryParse(address.encode())!;
      expect(parsed.mail, 'abc@chat.test');
      expect(parsed.mailboxKey, address.mailboxKey);
      for (final bad in [
        'abc@chat.test',
        'abc@chat.test|short',
        'ABC@chat.test|${base64Url.encode(List.filled(32, 1))}',
        'a b@chat.test|${base64Url.encode(List.filled(32, 1))}',
        'abc@localhost|${base64Url.encode(List.filled(32, 1))}',
      ]) {
        expect(isValidEmailCarrierAddress(bad), isFalse, reason: bad);
      }
    });

    test('chatmail accounts get a random name, password and key', () {
      final a = EmailCarrierConfig.chatmail('nine.testrun.org');
      final b = EmailCarrierConfig.chatmail('nine.testrun.org');
      expect(a.mail, matches(RegExp(r'^[a-z0-9]{9}@nine\.testrun\.org$')));
      expect(a.mail, isNot(b.mail));
      expect(a.password, hasLength(32));
      expect((a.imapPort, a.smtpPort), (993, 465));
      final restored = EmailCarrierConfig.fromJson(
        jsonDecode(jsonEncode(a.copyWith(lastUid: 9).toJson())),
      )!;
      expect(restored.mail, a.mail);
      expect(restored.mailboxKey, a.mailboxKey);
      expect(restored.lastUid, 9);
      expect(restored.toString(), isNot(contains(a.password)));
    });
  });
}
