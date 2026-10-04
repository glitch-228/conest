// Runs against a real mail server when CONEST_MAIL_HOST is set (the debug
// workflow starts GreenMail with plain IMAP on 3143 and SMTP on 3025), so
// the IMAP and SMTP clients meet a server implementation other than the
// test fake.
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/email/mail_socket.dart';
import 'package:conest/src/email_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = Platform.environment['CONEST_MAIL_HOST'];
  final skip = host == null ? 'CONEST_MAIL_HOST is not set' : null;

  test(
    'a carrier mail crosses a real IMAP/SMTP server',
    () async {
      Future<MailSocket> plain(String _, int port, {required bool tls}) =>
          connectMailSocket(host!, port, tls: false);
      EmailCarrierConfig account(String name) => EmailCarrierConfig(
        mail: '$name@conest.test',
        password: 'pw-$name',
        imapHost: host!,
        imapPort: 3143,
        smtpHost: host,
        smtpPort: 3025,
        mailboxKey: EmailCarrierConfig.newMailboxKey(),
      );
      final received = <(String, Uint8List)>[];
      final alice = EmailCarrierChannel(
        config: account('alice'),
        connector: plain,
        onFrame: (_, _) {},
      );
      final bob = EmailCarrierChannel(
        config: account('bob'),
        connector: plain,
        onFrame: (sender, frame) => received.add((sender, frame)),
        pollInterval: const Duration(seconds: 1),
        idleTimeout: const Duration(seconds: 5),
      );
      await EmailCarrierChannel.checkLogin(alice.config, connector: plain);
      alice.start();
      bob.start();
      addTearDown(alice.stop);
      addTearDown(bob.stop);
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (bob.state != EmailCarrierState.connected &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(bob.state, EmailCarrierState.connected, reason: bob.lastError);
      final frame = Uint8List.fromList(
        List<int>.generate(300 * 1024, (index) => index * 5 % 256),
      );
      await alice.sendFrame(bob.localAddress!, frame);
      while (received.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(received.single.$1, 'alice@conest.test');
      expect(received.single.$2, frame);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
