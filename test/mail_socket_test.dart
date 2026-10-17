import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/email/mail_socket.dart';
import 'package:flutter_test/flutter_test.dart';

class _Socket implements MailSocket {
  _Socket(this.where);

  final String where;

  @override
  Stream<Uint8List> get input => const Stream.empty();

  @override
  void write(List<int> bytes) {}

  @override
  Future<void> close() async {}
}

void main() {
  test(
    'a blocked mail port falls back to 443 with ALPN, and stays there',
    () async {
      final direct = <String>[];
      final viaHttps = <String>[];
      final connect = chatmailFallback(
        direct: (host, port, {required tls}) async {
          direct.add('$host:$port');
          if (port == 465) {
            throw const SocketException('Connection timed out');
          }
          return _Socket('$host:$port');
        },
        viaHttpsPort: (host, alpn) async {
          viaHttps.add('$host:$alpn');
          return _Socket('$host:443/$alpn');
        },
      );

      final smtp = await connect('mail.test', 465, tls: true) as _Socket;
      expect(smtp.where, 'mail.test:443/smtp');
      // Next time straight to 443: no second wait on the blocked port.
      await connect('mail.test', 465, tls: true);
      expect(direct, ['mail.test:465']);
      expect(viaHttps, ['mail.test:smtp', 'mail.test:smtp']);

      // IMAP on another server that works: its own port.
      final imap = await connect('other.test', 993, tls: true) as _Socket;
      expect(imap.where, 'other.test:993');
      // Other ports, and plain connections (tests), are left alone.
      final plain = await connect('mail.test', 1465, tls: false) as _Socket;
      expect(plain.where, 'mail.test:1465');
    },
  );

  test('when 443 fails too, the mail port\'s error is reported', () async {
    final connect = chatmailFallback(
      direct: (host, port, {required tls}) async =>
          throw const SocketException('port 465 blocked'),
      viaHttpsPort: (host, alpn) async =>
          throw const SocketException('443 blocked'),
    );
    await expectLater(
      connect('mail.test', 465, tls: true),
      throwsA(
        isA<SocketException>().having(
          (error) => error.message,
          'message',
          'port 465 blocked',
        ),
      ),
    );
  });
}
