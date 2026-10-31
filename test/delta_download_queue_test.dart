import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/email/carrier_mail.dart';
import 'package:conest/src/email_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_mail_server.dart';

void main() {
  late FakeMailServer server;
  final channels = <EmailCarrierChannel>[];
  const user = 'bob@chat.test';
  EmailCarrierConfig account() => EmailCarrierConfig(
    mail: user,
    password: 'password',
    imapHost: 'chat.test',
    imapPort: 993,
    smtpHost: 'chat.test',
    smtpPort: 465,
    mailboxKey: EmailCarrierConfig.newMailboxKey(),
    uidValidity: 7,
  );
  String message(String id, {int bytes = 10, String extra = ''}) =>
      'From: <alice@chat.test>\r\nMessage-ID: <$id>\r\n$extra'
      'Content-Type: multipart/encrypted\r\n\r\n${'x' * bytes}';
  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('mail queue did not progress');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

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

  test(
    'Delta full deferred list preserves overflow UIDs and delivers later mail',
    () async {
      var saved = account();
      final received = <int>[];
      final channel = EmailCarrierChannel(
        config: saved,
        connector: server.connect,
        onFrame: (_, _) {},
        deferOtherMail: (size) => size > 64000,
        onOtherMailBatch: (mails, cursor) async {
          saved = cursor;
          received.addAll(mails.map((m) => m.uid));
          return List.filled(mails.length, true);
        },
      );
      channels.add(channel);
      for (var i = 0; i < 129; i++) {
        server.deliver(user, message('large-$i', bytes: 65000));
      }
      server.deliver(user, message('tail'));
      final tail = server.mailboxes[user]!.last;
      channel.start();
      await until(() => tail.deleted);
      expect(saved.deferred, hasLength(128));
      expect(saved.deferredFloorUid, 129);
      expect(saved.lastUid, tail.uid);
      expect(received, [tail.uid]);
      final restored = EmailCarrierConfig.fromJson(saved.toJson())!;
      expect(restored.deferredFloorUid, 129);
      await channel
          .downloadDeferred(7, saved.deferred.first.uid)
          .timeout(const Duration(seconds: 3));
      await until(() => saved.deferred.any((m) => m.uid == 129));
      expect(saved.deferred, hasLength(128));
      expect(saved.deferredFloorUid, isNull);
    },
  );

  test('Delta parking each batch reuses its UID discovery work', () async {
    var saved = account();
    final channel = EmailCarrierChannel(
      config: saved,
      connector: server.connect,
      onFrame: (_, _) {},
      deferOtherMail: (_) => false,
      onOtherMailBatch: (mails, cursor) async {
        if (mails.isNotEmpty) {
          throw OtherMailRetryException(
            deferredUids: mails.map((m) => m.uid).toList(),
          );
        }
        saved = cursor;
        return [];
      },
    );
    channels.add(channel);
    for (var i = 0; i < 100; i++) {
      server.deliver(user, message('small-file-$i'));
    }
    final last = server.mailboxes[user]!.last.uid;
    channel.start();
    await until(() => saved.lastUid == last);
    expect(saved.deferred, hasLength(100));
    expect(server.uidSearches, lessThanOrEqualTo(2));
  });

  test(
    'Delta optional malformed and long headers cannot block or lose a deferred UID',
    () async {
      var saved = account();
      final channel = EmailCarrierChannel(
        config: saved,
        connector: server.connect,
        onFrame: (_, _) {},
        deferOtherMail: (size) => size > 64000,
        onOtherMailBatch: (mails, cursor) async {
          saved = cursor;
          return List.filled(mails.length, true);
        },
      );
      channels.add(channel);
      server.deliver(
        user,
        message('header-big', bytes: 65000, extra: 'From: ${'z' * 20000}\r\n'),
      );
      server.deliver(user, message('z' * 300, bytes: 65000));
      server.deliver(
        user,
        message('invalid-name', bytes: 65000, extra: 'Invalid Name: x\r\n'),
      );
      server.deliver(user, message('tail'));
      final tail = server.mailboxes[user]!.last;
      channel.start();
      await until(() => tail.deleted);
      expect(saved.deferred, hasLength(3));
      expect(
        EmailCarrierConfig.fromJson(saved.toJson())!.deferred,
        hasLength(3),
      );
      expect(saved.deferred[1].messageId, isEmpty);
      expect(saved.deferred[2].from, isEmpty);
      expect(server.fetched, [tail.uid]);
    },
  );

  test(
    'Delta Download queued during an active fetch runs before IDLE',
    () async {
      var saved = account();
      final channel = EmailCarrierChannel(
        config: saved,
        connector: server.connect,
        onFrame: (_, _) {},
        deferOtherMail: (_) => true,
        onOtherMailBatch: (mails, cursor) async {
          saved = cursor;
          return List.filled(mails.length, true);
        },
      );
      channels.add(channel);
      server.deliver(user, message('first'));
      server.deliver(user, message('second'));
      channel.start();
      await until(() => saved.deferred.length == 2);
      final first = saved.deferred.first.uid, second = saved.deferred.last.uid;
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.beforeBodyFetch = (mail) async {
        if (mail.uid == first) {
          started.complete();
          await release.future;
        }
      };
      final firstDone = channel.downloadDeferred(7, first);
      await started.future;
      final secondDone = channel.downloadDeferred(7, second);
      release.complete();
      await Future.wait([
        firstDone,
        secondDone,
      ]).timeout(const Duration(seconds: 3));
      expect(server.fetched, [first, second]);
      expect(saved.deferred, isEmpty);
    },
  );

  test(
    'Delta unsavable mail is parked after bounded retries without blocking later mail',
    () async {
      var saved = account();
      var attempts = 0;
      final gaveUp = <int>[];
      final channel = EmailCarrierChannel(
        config: saved,
        connector: server.connect,
        onFrame: (_, _) {},
        deferOtherMail: (_) => false,
        onOtherMailGaveUp: gaveUp.add,
        onOtherMailBatch: (mails, cursor) async {
          if (mails.any((m) => m.uid == 1)) {
            attempts++;
            throw const OtherMailRetryException(uid: 1);
          }
          saved = cursor;
          return List.filled(mails.length, true);
        },
      );
      channels.add(channel);
      server.deliver(user, message('poison'));
      server.deliver(user, message('tail'));
      final tail = server.mailboxes[user]!.last;
      channel.start();
      await until(() => tail.deleted);
      expect(attempts, EmailCarrierChannel.maxOtherMailAttempts);
      expect(gaveUp, [1]);
      expect(saved.deferred.single.uid, 1);
      expect(server.mailboxes[user]!.single.deleted, isFalse);
    },
  );

  test(
    'Delta enabled preserves large Conest carrier delivery on metered links',
    () async {
      final config = account();
      final frames = <Uint8List>[];
      final channel = EmailCarrierChannel(
        config: config,
        connector: server.connect,
        onFrame: (_, frame) => frames.add(frame),
        deferOtherMail: (size) => size > 64000,
        onOtherMailBatch: (mails, cursor) async =>
            List.filled(mails.length, false),
      );
      channels.add(channel);
      final frame = Uint8List(100000)..[0] = 17;
      server.deliver(
        user,
        CarrierMail.build(
          from: 'alice@chat.test',
          to: user,
          mailboxKey: config.mailboxKey,
          frame: frame,
          date: DateTime.now(),
        ),
      );
      channel.start();
      await until(() => frames.isNotEmpty);
      expect(frames.single, frame);
      expect(channel.config.deferred, isEmpty);
      expect(server.prefixesFetched, [1]);
    },
  );
}
