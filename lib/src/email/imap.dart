import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'mail_socket.dart';

/// An IMAP server refused a command.
class ImapException implements Exception {
  const ImapException(this.message);
  final String message;
  @override
  String toString() => 'IMAP: $message';
}

/// One untagged response line, with the literals it carried.
class ImapResponse {
  const ImapResponse(this.text, this.literals);

  /// The line with each literal replaced by `{n}` as sent.
  final String text;
  final List<Uint8List> literals;
}

/// The small part of IMAP4rev1 the email carrier needs: login, one folder,
/// UID search/fetch/delete and IDLE.
class ImapClient {
  ImapClient._(this._socket) : _reader = MailLineReader(_socket.input);

  static Future<ImapClient> connect(
    String host,
    int port, {
    bool tls = true,
    MailConnector? connector,
  }) async {
    final socket = await (connector ?? connectMailSocket)(host, port, tls: tls);
    final client = ImapClient._(socket);
    try {
      final greeting = await client._reader.readLine();
      if (!greeting.startsWith('* OK') && !greeting.startsWith('* PREAUTH')) {
        throw ImapException('unexpected greeting: $greeting');
      }
    } catch (_) {
      await client.close();
      rethrow;
    }
    return client;
  }

  final MailSocket _socket;
  final MailLineReader _reader;
  int _tag = 0;
  Set<String> _capabilities = const {};
  bool _newMail = false;

  bool get supportsIdle => _capabilities.contains('IDLE');
  bool get supportsUidPlus => _capabilities.contains('UIDPLUS');

  Future<void> login(String user, String password) async {
    if (RegExp(r'[\r\n\x00]').hasMatch('$user$password')) {
      throw const ImapException('line breaks are not allowed in credentials');
    }
    await _command('LOGIN ${_quote(user)} ${_quote(password)}');
    final capabilities = await _command('CAPABILITY');
    _capabilities = {
      for (final response in capabilities)
        if (response.text.startsWith('* CAPABILITY '))
          ...response.text.substring(13).toUpperCase().split(' '),
    };
  }

  /// Selects [mailbox]; returns its UIDVALIDITY and UIDNEXT (null when the
  /// server does not say).
  Future<(int, int?)> select(String mailbox) async {
    final responses = await _command('SELECT ${_quote(mailbox)}');
    int? validity;
    int? next;
    for (final response in responses) {
      final text = response.text;
      validity ??= int.tryParse(
        RegExp(r'\[UIDVALIDITY (\d+)\]').firstMatch(text)?.group(1) ?? '',
      );
      next ??= int.tryParse(
        RegExp(r'\[UIDNEXT (\d+)\]').firstMatch(text)?.group(1) ?? '',
      );
    }
    if (validity == null) throw const ImapException('no UIDVALIDITY');
    return (validity, next);
  }

  /// Whether the server announced new mail since this was last asked.
  bool takeNewMail() {
    final arrived = _newMail;
    _newMail = false;
    return arrived;
  }

  /// UIDs above [after] of PGP/MIME messages, the only kind carrier mail
  /// is, so other mail is never downloaded.
  Future<List<int>> uidsAfter(int after) async {
    final responses = await _command(
      'UID SEARCH UID ${after + 1}:* HEADER Content-Type "multipart/encrypted"',
    );
    final uids = <int>[];
    for (final response in responses) {
      if (!response.text.startsWith('* SEARCH')) continue;
      for (final part in response.text.substring(8).trim().split(' ')) {
        final uid = int.tryParse(part);
        // "n:*" also matches the newest message when it is below n.
        if (uid != null && uid > after) uids.add(uid);
      }
    }
    uids.sort();
    return uids;
  }

  /// The size of message [uid], or null when it is gone.
  Future<int?> size(int uid) async {
    final responses = await _command('UID FETCH $uid (RFC822.SIZE)');
    for (final response in responses) {
      final match = RegExp(r'RFC822\.SIZE (\d+)').firstMatch(response.text);
      if (match != null && _uidOf(response.text) == uid) {
        return int.parse(match.group(1)!);
      }
    }
    return null;
  }

  /// The whole of message [uid] without marking it seen; a body larger
  /// than [maxBytes] is refused.
  Future<Uint8List?> fetch(int uid, {required int maxBytes}) async {
    final responses = await _command(
      'UID FETCH $uid (BODY.PEEK[])',
      maxLiteral: maxBytes,
    );
    for (final response in responses) {
      if (_uidOf(response.text) == uid && response.literals.isNotEmpty) {
        return response.literals.first;
      }
    }
    return null;
  }

  /// Deletes message [uid] for good. Without UIDPLUS it is only flagged: a
  /// plain EXPUNGE would also remove mail other clients flagged.
  Future<void> delete(int uid) async {
    await _command('UID STORE $uid +FLAGS.SILENT (\\Deleted)');
    if (supportsUidPlus) await _command('UID EXPUNGE $uid');
  }

  /// Waits up to [timeout] for new mail with IDLE (RFC 2177); returns
  /// whether the server announced any. [stop] ends the wait early.
  Future<bool> idle(Duration timeout, {Future<void>? stop}) async {
    final tag = _nextTag();
    _socket.write(latin1.encode('$tag IDLE\r\n'));
    var arrived = false;
    while (true) {
      final line = await _reader.readLine();
      if (line.startsWith('+')) break;
      if (line.startsWith('$tag ')) throw ImapException('IDLE refused: $line');
      // Untagged news before the continuation still counts.
      if (_isExists(line)) arrived = true;
    }
    final deadline = DateTime.now().add(timeout);
    var stopped = false;
    var waiting = true;
    unawaited(
      stop?.then((_) {
        stopped = true;
        // Only this wait: a late stop must not cut a later command short.
        if (waiting) _reader.interrupt();
      }),
    );
    while (!arrived && !stopped) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      try {
        final line = await _reader.readLine(timeout: left);
        if (_isExists(line)) arrived = true;
      } on TimeoutException {
        break;
      }
    }
    waiting = false;
    _socket.write(latin1.encode('DONE\r\n'));
    await _collect(tag);
    if (arrived) _newMail = false;
    return arrived;
  }

  Future<void> logout() async {
    try {
      await _command('LOGOUT');
    } catch (_) {}
    await close();
  }

  Future<void> close() async {
    await _reader.cancel();
    await _socket.close();
  }

  String _nextTag() => 'C${++_tag}';

  Future<List<ImapResponse>> _command(
    String command, {
    int maxLiteral = 64 * 1024,
  }) async {
    final tag = _nextTag();
    // UTF-8: quoted strings such as passwords may hold any character.
    _socket.write(utf8.encode('$tag $command\r\n'));
    return _collect(tag, maxLiteral: maxLiteral);
  }

  /// Most untagged responses one command may bring.
  static const int _maxResponses = 4096;

  Future<List<ImapResponse>> _collect(
    String tag, {
    int maxLiteral = 64 * 1024,
  }) async {
    final responses = <ImapResponse>[];
    while (true) {
      final response = await _readResponse(maxLiteral);
      if (response.text.startsWith('$tag ')) {
        final status = response.text.substring(tag.length + 1);
        if (!status.startsWith('OK')) throw ImapException(status);
        return responses;
      }
      // New mail announced in the middle of another command.
      if (_isExists(response.text)) _newMail = true;
      if (responses.length >= _maxResponses) {
        throw const ImapException('too many responses');
      }
      responses.add(response);
    }
  }

  static bool _isExists(String line) =>
      RegExp(r'^\* \d+ EXISTS').hasMatch(line);

  /// A full response: a line plus any `{n}` literals and their
  /// continuations.
  Future<ImapResponse> _readResponse(int maxLiteral) async {
    final text = StringBuffer();
    final literals = <Uint8List>[];
    while (true) {
      final line = await _reader.readLine();
      text.write(line);
      final literal = RegExp(r'\{(\d+)\}$').firstMatch(line);
      if (literal == null) break;
      final length = int.parse(literal.group(1)!);
      if (length > maxLiteral) {
        throw const ImapException('literal too large');
      }
      literals.add(await _reader.readBytes(length));
    }
    return ImapResponse(text.toString(), literals);
  }

  static int? _uidOf(String text) {
    final match = RegExp(r'UID (\d+)').firstMatch(text);
    return match == null ? null : int.parse(match.group(1)!);
  }

  static String _quote(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
