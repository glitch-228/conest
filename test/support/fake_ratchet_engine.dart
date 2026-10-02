import 'dart:convert';
import 'dart:math';

import 'package:conest/src/ratchet.dart';

/// Deterministic stand-in with Olm's observable rules: pre-key messages
/// until a reply arrives, one use per message index, one-time keys consumed
/// once, and identity keys bound to the session.
class FakeRatchetEngine implements RatchetEngine {
  FakeRatchetEngine({Random? random}) : _random = random ?? Random();

  final Random _random;

  String _key() => base64Encode(
    List<int>.generate(32, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');

  static String _pack(Map<String, Object?> value) =>
      base64Encode(utf8.encode(jsonEncode(value)));

  static Map<String, dynamic> _unpack(Object? value) =>
      jsonDecode(utf8.decode(base64Decode(value as String)))
          as Map<String, dynamic>;

  @override
  Map<String, dynamic> call(Map<String, Object?> request) {
    if (request['pickleKey'] is! String) {
      throw const RatchetEngineException('missing pickle key');
    }
    switch (request['op']) {
      case 'account_new':
        final account = {
          'identity': _key(),
          'otks': <String>[],
          'fallback': null,
          'previous': null,
        };
        return {'account': _pack(account), 'identityKey': account['identity']};
      case 'bundle':
        final account = _unpack(request['account']);
        account['fallback'] ??= _key();
        String? oneTime;
        if (request['oneTimeKey'] == true) {
          oneTime = _key();
          (account['otks'] as List).add(oneTime);
        }
        return {
          'account': _pack(account),
          'identityKey': account['identity'],
          'fallbackKey': account['fallback'],
          'oneTimeKey': oneTime,
        };
      case 'rotate_fallback':
        final account = _unpack(request['account']);
        account['previous'] = account['fallback'];
        account['fallback'] = _key();
        return {'account': _pack(account), 'fallbackKey': account['fallback']};
      case 'outbound':
        final account = _unpack(request['account']);
        final session = {
          'id': _key(),
          'me': account['identity'],
          'peer': request['peerIdentityKey'],
          'otk': request['peerOneTimeKey'],
          'next': 0,
          'received': false,
          'seen': <int>[],
        };
        return {'session': _pack(session), 'sessionId': session['id']};
      case 'encrypt':
        final session = _unpack(request['session']);
        final index = session['next'] as int;
        session['next'] = index + 1;
        final message = {
          'id': session['id'],
          'n': index,
          'from': session['me'],
          'otk': session['otk'],
          'pt': request['plaintext'],
        };
        return {
          'session': _pack(session),
          'sessionId': session['id'],
          'messageType': session['received'] == true ? 1 : 0,
          'ciphertext': base64Encode(utf8.encode(jsonEncode(message))),
        };
      case 'decrypt':
        final session = _unpack(request['session']);
        final message = _message(request);
        final seen = (session['seen'] as List).cast<int>();
        if (message['id'] != session['id'] || seen.contains(message['n'])) {
          throw const RatchetEngineException('bad mac');
        }
        session['seen'] = [...seen, message['n']];
        session['received'] = true;
        return {
          'session': _pack(session),
          'sessionId': session['id'],
          'plaintext': message['pt'],
        };
      case 'inbound':
        final account = _unpack(request['account']);
        final message = _message(request);
        final otks = (account['otks'] as List).cast<String>();
        final otk = message['otk'];
        final known =
            otks.contains(otk) ||
            otk == account['fallback'] ||
            otk == account['previous'];
        if (request['messageType'] != 0 ||
            message['from'] != request['peerIdentityKey'] ||
            !known) {
          throw const RatchetEngineException('cannot open session');
        }
        account['otks'] = [
          for (final key in otks)
            if (key != otk) key,
        ];
        final session = {
          'id': message['id'],
          'me': account['identity'],
          'peer': message['from'],
          'otk': null,
          'next': 0,
          'received': true,
          'seen': [message['n']],
        };
        return {
          'account': _pack(account),
          'session': _pack(session),
          'sessionId': session['id'],
          'plaintext': message['pt'],
        };
    }
    throw const RatchetEngineException('unknown op');
  }

  Map<String, dynamic> _message(Map<String, Object?> request) {
    try {
      return jsonDecode(
            utf8.decode(base64Decode(request['ciphertext'] as String)),
          )
          as Map<String, dynamic>;
    } catch (_) {
      throw const RatchetEngineException('undecodable message');
    }
  }
}
