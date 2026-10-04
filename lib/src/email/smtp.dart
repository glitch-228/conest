import 'dart:convert';

import 'mail_socket.dart';

/// An SMTP server refused a command.
class SmtpException implements Exception {
  const SmtpException(this.code, this.message);
  final int code;
  final String message;

  /// 4xx replies may succeed later.
  bool get temporary => code >= 400 && code < 500;

  @override
  String toString() => 'SMTP $code: $message';
}

/// Sends one message per connection: EHLO, AUTH PLAIN, MAIL, RCPT, DATA.
abstract final class SmtpSender {
  static Future<void> send({
    required String host,
    required int port,
    required String user,
    required String password,
    required String from,
    required String to,
    required String message,
    bool tls = true,
    MailConnector? connector,
  }) async {
    final socket = await (connector ?? connectMailSocket)(host, port, tls: tls);
    final reader = MailLineReader(socket.input);
    Future<(int, String)> reply() async {
      final lines = <String>[];
      while (true) {
        final line = await reader.readLine();
        if (line.length < 3) throw SmtpException(0, line);
        lines.add(line.length > 4 ? line.substring(4) : '');
        if (line.length == 3 || line[3] != '-') {
          return (int.tryParse(line.substring(0, 3)) ?? 0, lines.join(' '));
        }
      }
    }

    Future<String> expect(int code, [String? command]) async {
      if (command != null) socket.write(latin1.encode('$command\r\n'));
      final (got, text) = await reply();
      if (got ~/ 100 != code ~/ 100) throw SmtpException(got, text);
      return text;
    }

    try {
      await expect(220);
      await expect(250, 'EHLO localhost');
      await expect(
        235,
        'AUTH PLAIN ${base64Encode(utf8.encode('\u0000$user\u0000$password'))}',
      );
      await expect(250, 'MAIL FROM:<$from>');
      await expect(250, 'RCPT TO:<$to>');
      await expect(354, 'DATA');
      final body = message
          .replaceAll('\r\n', '\n')
          .split('\n')
          .map((line) => line.startsWith('.') ? '.$line' : line)
          .join('\r\n');
      socket.write(latin1.encode('$body\r\n.\r\n'));
      await expect(250);
      socket.write(latin1.encode('QUIT\r\n'));
    } finally {
      await reader.cancel();
      await socket.close();
    }
  }
}
