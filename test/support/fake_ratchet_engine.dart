import 'dart:convert';
import 'dart:math';

import 'package:conest/src/ratchet.dart';

/// Deterministic stand-in with Olm's observable rules: pre-key messages
/// until a reply arrives, one use per message index, one-time keys consumed
/// once, and identity keys bound to the session.
class FakeRatchetEngine implements RatchetEngine {
  FakeRatchetEngine({
    Random? random,
    this.skippedKeyLimit,
    this.receivingChains,
  }) : _random = random ?? Random();

  final Random _random;

  /// Like Olm, a message that arrives more than this many places behind the
  /// newest one received can no longer be read (its key was dropped). Null:
  /// no limit.
  final int? skippedKeyLimit;

  /// Like Olm, only the last this many receiving chains are kept (every
  /// change of direction of the sender starts one); a message of an older
  /// chain can no longer be read. Null: no limit.
  final int? receivingChains;

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
        if (session['rx'] == true) {
          session['turn'] = ((session['turn'] as int?) ?? 0) + 1;
          session['rx'] = false;
        }
        final message = {
          'c': (session['turn'] as int?) ?? 0,
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
        final chain = (message['c'] as int?) ?? 0;
        final chains = ((session['chains'] as List?) ?? const []).cast<int>();
        final chainLimit = receivingChains;
        if (chainLimit != null &&
            !chains.contains(chain) &&
            chains.isNotEmpty &&
            chain < chains.last) {
          throw const RatchetEngineException('the chain was dropped');
        }
        if (!chains.contains(chain)) {
          final kept = [...chains, chain];
          session['chains'] = chainLimit != null && kept.length > chainLimit
              ? kept.sublist(kept.length - chainLimit)
              : kept;
        }
        session['rx'] = true;
        final newest = (session['newest'] as int?) ?? -1;
        final limit = skippedKeyLimit;
        if (limit != null && (message['n'] as int) < newest - limit) {
          throw const RatchetEngineException('the key was dropped');
        }
        session['newest'] = max(newest, message['n'] as int);
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
          'newest': message['n'],
          'chains': [(message['c'] as int?) ?? 0],
          'rx': true,
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
