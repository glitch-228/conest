import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/email/carrier_mail.dart';
import 'package:conest/src/email/delta_content.dart';
import 'package:conest/src/email/mail_socket.dart';
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

  test(
    'a connection that fails is closed at once, not after the wait',
    () async {
      // The server counts open connections per account; failed ones left open
      // through the backoff piled up until it refused new ones.
      final sockets = <_BreakableSocket>[];
      final bob = EmailCarrierChannel(
        config: account('bob'),
        connector: (host, port, {required bool tls}) async {
          final socket = _BreakableSocket(
            await server.connect(host, port, tls: tls),
          );
          sockets.add(socket);
          return socket;
        },
        onFrame: (_, _) {},
        pollInterval: const Duration(milliseconds: 200),
      );
      channels.add(bob);
      bob.start();
      await until(() => bob.state == EmailCarrierState.connected);
      sockets.single.breakNow();
      await until(() => bob.state == EmailCarrierState.failed);
      // The first backoff is 2 s; the broken connection is closed well before.
      await until(() => sockets.first.closed);
      expect(sockets, hasLength(1), reason: 'still waiting out the backoff');
    },
  );

  test('chatmail servers are ranked by how fast they answer here', () async {
    final closed = <String>[];
    final reachable = await reachableChatmailServers(
      ['slow.test', 'blocked.test', 'fast.test', 'silent.test'],
      connector: (host, port, {required bool tls}) async {
        switch (host) {
          case 'blocked.test':
            throw const SocketException('Connection timed out');
          case 'silent.test':
            // Connects and never speaks: still waiting at the deadline.
            await Completer<void>().future;
          case 'slow.test':
            await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        final socket = _BreakableSocket(
          await server.connect(host, port, tls: tls),
        );
        socket.onClose = () => closed.add(host);
        return socket;
      },
      timeout: const Duration(seconds: 2),
    );
    expect(reachable, ['fast.test', 'slow.test']);
    // Probes only: every connection that answered is closed again.
    await until(() => closed.length == 2);
    expect(closed.toSet(), {'fast.test', 'slow.test'});
    expect(server.passwords, isEmpty);
  });

  test('a server whose mail port stalls is found on port 443', () async {
    // The device lab's network: TLS on 993 stalls longer than the probe.
    chatmailReachedViaHttps.remove('stalled.test');
    final reachable = await reachableChatmailServers(
      ['stalled.test'],
      connector: (host, port, {required bool tls}) async {
        await Completer<void>().future;
        throw StateError('unreachable');
      },
      viaHttpsPort: (host, alpn) => server.connect(host, 993, tls: false),
      timeout: const Duration(seconds: 2),
    );
    expect(reachable, ['stalled.test']);
    // Sign-up and reading then go to 443 first.
    expect(chatmailReachedViaHttps, contains('stalled.test'));
  });

  test('servers are probed a few at a time, not all at once', () async {
    // A burst of connections was held back like a port scan on the lab.
    var inFlight = 0;
    var most = 0;
    Future<MailSocket> slow(String host) async {
      most = max(most, ++inFlight);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      inFlight--;
      return server.connect(host, 993, tls: false);
    }

    final reachable = await reachableChatmailServers(
      [for (var i = 0; i < 8; i++) 's$i.test'],
      connector: (host, port, {required bool tls}) => slow(host),
      viaHttpsPort: (host, alpn) => slow(host),
      parallel: 2,
      enough: 8,
      // Only answers free a slot here (a loaded machine can be slower than
      // a head start).
      headStart: const Duration(minutes: 1),
      timeout: const Duration(seconds: 5),
    );
    expect(reachable, hasLength(8));
    // Two servers at a time, both ports each.
    expect(most, lessThanOrEqualTo(4));
  });

  test('probing stops waiting once enough servers answered', () async {
    final watch = Stopwatch()..start();
    final reachable = await reachableChatmailServers(
      ['a.test', 'b.test', 'silent.test'],
      connector: (host, port, {required bool tls}) async {
        if (host == 'silent.test') await Completer<void>().future;
        return server.connect(host, port, tls: tls);
      },
      enough: 2,
      timeout: const Duration(seconds: 5),
    );
    expect(reachable.toSet(), {'a.test', 'b.test'});
    expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
  });

  test('no server is tried after enough answered', () async {
    final tried = <String>[];
    final reachable = await reachableChatmailServers(
      ['a.test', 'b.test', 'c.test'],
      connector: (host, port, {required bool tls}) {
        tried.add(host);
        return server.connect(host, port, tls: tls);
      },
      parallel: 1,
      enough: 1,
      timeout: const Duration(seconds: 5),
    );
    expect(reachable, ['a.test']);
    expect(tried, ['a.test']);
  });

  test('a server at its connection limit is left alone for a while', () async {
    server.refuseLogin =
        '[UNAVAILABLE] Maximum number of connections from user+IP exceeded';
    final lines = <String>[];
    final bob = EmailCarrierChannel(
      config: account('bob'),
      connector: server.connect,
      onFrame: (_, _) {},
      log: lines.add,
      connectionLimitWait: const Duration(minutes: 10),
    );
    channels.add(bob);
    bob.start();
    await until(() => lines.isNotEmpty);
    expect(lines.first, contains('next try in 600 s'));
  });

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

  test(
    'ordinary and explicit Delta budgets refuse mail before body fetch',
    () async {
      for (final larger in [false, true]) {
        final config = account(larger ? 'delta' : 'ordinary');
        final cursors = <int>[];
        final client = EmailCarrierChannel(
          config: config,
          connector: server.connect,
          onFrame: (_, _) {},
          onCursor: (_, uid) => cursors.add(uid),
          onOtherMail: larger ? (_) async => false : null,
          otherMailMaxBytes: larger ? () => DeltaLimits.fileMailBytes : null,
        );
        channels.add(client);
        client.start();
        await until(() => client.state == EmailCarrierState.connected);
        server.deliver(
          config.mail,
          'From: <alice@chat.test>\r\nContent-Type: multipart/encrypted\r\n\r\nsmall',
        );
        final uid = server.mailboxes[config.mail]!.last.uid;
        server.reportedSizes[uid] =
            (larger ? DeltaLimits.fileMailBytes : maxCarrierMailBytes) + 1;
        await until(() => cursors.contains(uid));
        expect(server.fetched, isNot(contains(uid)));
        expect(server.mailboxes[config.mail], hasLength(1));
      }
    },
  );

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

  test(
    'recognized unsaved mail is retried without advancing its UID',
    () async {
      var attempts = 0;
      final client = EmailCarrierChannel(
        config: account('retry'),
        connector: server.connect,
        onFrame: (_, _) {},
        onOtherMail: (_) async {
          attempts++;
          if (attempts < 2) throw const OtherMailRetryException();
          return true;
        },
      );
      channels.add(client);
      client.start();
      await until(() => client.state == EmailCarrierState.connected);
      server.deliver(
        'retry@chat.test',
        'From: <a@chat.test>\r\n'
            'Content-Type: multipart/encrypted\r\n\r\nunavailable',
      );
      final uid = server.mailboxes['retry@chat.test']!.last.uid;
      await until(() => attempts == 1);
      expect(client.config.lastUid, lessThan(uid));
      await until(() => attempts >= 2);
      await until(() => server.mailboxes['retry@chat.test']!.isEmpty);
    },
  );

  test('mail that can never be saved is skipped, and mail after it '
      'still arrives', () async {
    var attempts = 0;
    final gaveUp = <int>[];
    final got = <Uint8List>[];
    final bob = EmailCarrierChannel(
      config: account('stuck'),
      connector: server.connect,
      onFrame: (_, frame) => got.add(frame),
      onOtherMail: (_) async {
        attempts++;
        throw const OtherMailRetryException();
      },
      onOtherMailGaveUp: gaveUp.add,
    );
    channels.add(bob);
    bob.start();
    await until(() => bob.state == EmailCarrierState.connected);
    server.deliver(
      'stuck@chat.test',
      'From: <a@chat.test>\r\n'
          'Content-Type: multipart/encrypted\r\n\r\nno room for it',
    );
    final stuckUid = server.mailboxes['stuck@chat.test']!.last.uid;
    final alice = channel(account('alice'), [])..start();
    await until(() => alice.state == EmailCarrierState.connected);
    await alice.sendFrame(bob.localAddress!, frame);

    await until(() => got.isNotEmpty);
    expect(attempts, EmailCarrierChannel.maxOtherMailAttempts);
    expect(gaveUp, [stuckUid]);
    // Left on the server, not deleted.
    expect(
      server.mailboxes['stuck@chat.test']!.map((m) => m.uid),
      contains(stuckUid),
    );
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

/// A mail connection a test can break, which records being closed.
class _BreakableSocket implements MailSocket {
  _BreakableSocket(this._inner) {
    _inner.input.listen(
      _input.add,
      onError: _input.addError,
      onDone: _input.close,
    );
  }

  final MailSocket _inner;
  final _input = StreamController<Uint8List>();
  bool closed = false;
  void Function()? onClose;

  void breakNow() => _input.addError(const SocketException('broken'));

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  void write(List<int> bytes) => _inner.write(bytes);

  @override
  Future<void> close() async {
    closed = true;
    onClose?.call();
    await _inner.close();
  }
}
