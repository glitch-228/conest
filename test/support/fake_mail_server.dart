import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/email/mail_socket.dart';

/// A local mail server speaking enough IMAP and SMTP for the email carrier.
/// Accounts are created on first login (as on chatmail), and like chatmail
/// it refuses mail that is not OpenPGP-encrypted when [requireEncryption].
class FakeMailServer {
  FakeMailServer._(this._imap, this._smtp, this.requireEncryption, this.idle);

  static Future<FakeMailServer> start({
    bool requireEncryption = true,
    bool idle = true,
  }) async {
    final server = FakeMailServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      requireEncryption,
      idle,
    );
    server._imap.listen(server._serveImap);
    server._smtp.listen(server._serveSmtp);
    return server;
  }

  final ServerSocket _imap;
  final ServerSocket _smtp;
  final bool requireEncryption;
  final bool idle;
  final Map<String, String> passwords = {};
  final Map<String, List<FakeMail>> mailboxes = {};

  /// UIDs whose bodies were downloaded.
  final List<int> fetched = [];
  final List<Socket> _open = [];
  final _arrivals = StreamController<String>.broadcast();
  int _nextUid = 1;

  int get imapPort => _imap.port;
  int get smtpPort => _smtp.port;

  /// Connects to this server whatever host and TLS the client asked for.
  Future<MailSocket> connect(String host, int port, {required bool tls}) =>
      connectMailSocket(
        '127.0.0.1',
        port == 993 || port == imapPort ? imapPort : smtpPort,
        tls: false,
      );

  /// Puts a message straight into [user]'s inbox.
  void deliver(String user, String message) {
    mailboxes
        .putIfAbsent(user, () => [])
        .add(FakeMail(_nextUid++, Uint8List.fromList(latin1.encode(message))));
    _arrivals.add(user);
  }

  /// Drops every open connection, as a server restart would.
  Future<void> dropConnections() async {
    for (final socket in List.of(_open)) {
      socket.destroy();
    }
    _open.clear();
  }

  Future<void> close() async {
    await dropConnections();
    await _imap.close();
    await _smtp.close();
  }

  bool _login(String user, String password) {
    final known = passwords.putIfAbsent(user, () => password);
    mailboxes.putIfAbsent(user, () => []);
    return known == password;
  }

  void _serveSmtp(Socket socket) {
    _open.add(socket);
    socket.done.catchError((Object _) {});
    String? user;
    String? to;
    var inData = false;
    final data = StringBuffer();
    void reply(String line) => socket.write('$line\r\n');
    reply('220 fake ESMTP');
    _lines(socket).listen((line) {
      if (inData) {
        if (line == '.') {
          inData = false;
          final message = data.toString();
          data.clear();
          if (requireEncryption && !_encrypted(message)) {
            reply('523 Encryption Needed: Invalid Unencrypted Mail');
          } else {
            deliver(to!, message);
            reply('250 OK queued');
          }
        } else {
          data.write('${line.startsWith('..') ? line.substring(1) : line}\r\n');
        }
        return;
      }
      final upper = line.toUpperCase();
      if (upper.startsWith('EHLO')) {
        reply('250-fake');
        reply('250 AUTH PLAIN');
      } else if (upper.startsWith('AUTH PLAIN ')) {
        final parts = utf8
            .decode(base64Decode(line.substring(11)))
            .split('\u0000');
        if (parts.length == 3 && _login(parts[1], parts[2])) {
          user = parts[1];
          reply('235 OK');
        } else {
          reply('535 bad credentials');
        }
      } else if (upper.startsWith('MAIL FROM:')) {
        final from = RegExp(r'<([^>]*)>').firstMatch(line)?.group(1);
        reply(user != null && from == user ? '250 OK' : '553 not yours');
      } else if (upper.startsWith('RCPT TO:')) {
        to = RegExp(r'<([^>]*)>').firstMatch(line)?.group(1);
        reply('250 OK');
      } else if (upper == 'DATA') {
        inData = true;
        reply('354 go');
      } else if (upper == 'QUIT') {
        reply('221 bye');
        socket.destroy();
      } else {
        reply('502 unknown');
      }
    }, onError: (Object _) {});
  }

  /// Chatmail's check: PGP/MIME whose payload is an encrypted OpenPGP
  /// message (here: an armored block, an SKESK/PKESK then a SEIPD packet).
  static bool _encrypted(String message) {
    if (!message.contains('multipart/encrypted')) return false;
    final begin = message.indexOf('-----BEGIN PGP MESSAGE-----');
    final end = message.indexOf('-----END PGP MESSAGE-----');
    if (begin < 0 || end < begin) return false;
    final body = message
        .substring(begin, end)
        .split('\r\n')
        .skip(1)
        .where((line) => line.isNotEmpty && !line.startsWith('='))
        .join();
    final bytes = base64Decode(body);
    final tags = <int>[];
    var offset = 0;
    while (offset < bytes.length) {
      final tag = bytes[offset] & 0x3f;
      final l1 = bytes[offset + 1];
      var length = l1;
      var header = 2;
      if (l1 >= 192 && l1 < 224) {
        length = ((l1 - 192) << 8) + bytes[offset + 2] + 192;
        header = 3;
      } else if (l1 == 255) {
        length = ByteData.sublistView(
          bytes,
          offset + 2,
          offset + 6,
        ).getUint32(0);
        header = 6;
      }
      tags.add(tag);
      offset += header + length;
    }
    return tags.length >= 2 &&
        tags.last == 18 &&
        tags.sublist(0, tags.length - 1).every((tag) => tag == 1 || tag == 3);
  }

  void _serveImap(Socket socket) {
    _open.add(socket);
    socket.done.catchError((Object _) {});
    String? user;
    String? idleTag;
    StreamSubscription<String>? idleWatch;
    // Mail count last reported to this client. As real servers do, mail
    // that arrived since is announced when IDLE starts.
    var reported = 0;
    void reply(String line) => socket.write('$line\r\n');
    List<FakeMail> box() => mailboxes[user] ?? const [];
    reply('* OK fake IMAP ready');
    _lines(socket).listen(
      (line) {
        if (idleTag != null) {
          if (line.toUpperCase() == 'DONE') {
            unawaited(idleWatch?.cancel());
            reply('$idleTag OK IDLE done');
            idleTag = null;
          }
          return;
        }
        final space = line.indexOf(' ');
        if (space < 0) return;
        final tag = line.substring(0, space);
        final command = line.substring(space + 1);
        final upper = command.toUpperCase();
        if (upper.startsWith('LOGIN ')) {
          final args = RegExp(r'"((?:[^"\\]|\\.)*)"')
              .allMatches(command)
              .map((m) => m.group(1)!.replaceAll(r'\"', '"'))
              .toList();
          if (args.length == 2 && _login(args[0], args[1])) {
            user = args[0];
            reply('$tag OK logged in');
          } else {
            reply('$tag NO bad credentials');
          }
        } else if (upper == 'CAPABILITY') {
          reply('* CAPABILITY IMAP4rev1 UIDPLUS${idle ? ' IDLE' : ''}');
          reply('$tag OK');
        } else if (upper.startsWith('SELECT')) {
          reported = box().length;
          reply('* ${box().length} EXISTS');
          reply('* OK [UIDVALIDITY 7] ok');
          reply('* OK [UIDNEXT $_nextUid] ok');
          reply('$tag OK [READ-WRITE] selected');
        } else if (upper.startsWith('UID SEARCH UID ')) {
          reported = box().length;
          final from = int.parse(command.substring(15).split(':').first);
          final encryptedOnly = upper.contains(
            'HEADER CONTENT-TYPE "MULTIPART/ENCRYPTED"',
          );
          final uids = box()
              .where(
                (mail) =>
                    mail.uid >= from &&
                    (!encryptedOnly ||
                        latin1
                            .decode(mail.raw)
                            .toLowerCase()
                            .contains('content-type: multipart/encrypted')),
              )
              .map((m) => m.uid);
          final all = uids.isEmpty && box().isNotEmpty
              ? [box().last.uid]
              : uids;
          reply('* SEARCH ${all.join(' ')}'.trimRight());
          reply('$tag OK');
        } else if (upper.startsWith('UID FETCH ')) {
          final uid = int.parse(command.split(' ')[2]);
          final index = box().indexWhere((mail) => mail.uid == uid);
          if (index >= 0) {
            final mail = box()[index];
            if (!upper.contains('RFC822.SIZE')) fetched.add(uid);
            if (upper.contains('RFC822.SIZE')) {
              reply(
                '* ${index + 1} FETCH (UID $uid RFC822.SIZE ${mail.raw.length})',
              );
            } else {
              socket.write(
                '* ${index + 1} FETCH (UID $uid BODY[] {${mail.raw.length}}\r\n',
              );
              socket.add(mail.raw);
              reply(')');
            }
          }
          reply('$tag OK');
        } else if (upper.startsWith('UID STORE ')) {
          final uid = int.parse(command.split(' ')[2]);
          for (final mail in box().where((mail) => mail.uid == uid)) {
            mail.deleted = true;
          }
          reply('$tag OK');
        } else if (upper.startsWith('UID EXPUNGE') || upper == 'EXPUNGE') {
          box().removeWhere((mail) => mail.deleted);
          reply('$tag OK');
        } else if (upper == 'IDLE' && idle) {
          idleTag = tag;
          reply('+ idling');
          if (box().length > reported) {
            reported = box().length;
            reply('* $reported EXISTS');
          }
          idleWatch = _arrivals.stream.where((to) => to == user).listen((_) {
            if (box().length > reported) {
              reported = box().length;
              reply('* $reported EXISTS');
            }
          });
        } else if (upper == 'LOGOUT') {
          reply('* BYE');
          reply('$tag OK');
          socket.destroy();
        } else if (upper == 'NOOP') {
          reply('$tag OK');
        } else {
          reply('$tag BAD unknown');
        }
      },
      onError: (Object _) {},
      onDone: () => idleWatch?.cancel(),
    );
  }

  static Stream<String> _lines(Socket socket) => socket
      .cast<List<int>>()
      .transform(latin1.decoder)
      .transform(const LineSplitter());
}

class FakeMail {
  FakeMail(this.uid, this.raw);
  final int uid;
  final Uint8List raw;
  bool deleted = false;
}
