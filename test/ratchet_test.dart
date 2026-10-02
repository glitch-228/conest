import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conest/src/ratchet.dart';
import 'package:conest/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RatchetSessions with a fake engine', () {
    _sessionContract(() => _FakeRatchetEngine());

    test('a failed store write never releases ciphertext', () async {
      final engine = _FakeRatchetEngine();
      final alice = _Device(engine);
      final bob = _Device(engine);
      await alice.sessions.startSession(
        'bob',
        await bob.sessions.createBundle(),
      );
      final first = await alice.sessions.encrypt('bob', utf8.encode('one'));
      alice.store.failWrites = true;
      await expectLater(
        alice.sessions.encrypt('bob', utf8.encode('two')),
        throwsA(isA<StateError>()),
      );
      alice.store.failWrites = false;
      // The stored state never advanced, so the next message reuses the
      // counter the failed attempt would have used; nothing was sent.
      final next = await alice.sessions.encrypt('bob', utf8.encode('three'));
      expect(_fakeIndex(next), _fakeIndex(first) + 1);
    });

    test('a failed decrypt leaves stored state untouched', () async {
      final engine = _FakeRatchetEngine();
      final alice = _Device(engine);
      final bob = _Device(engine);
      await alice.sessions.startSession(
        'bob',
        await bob.sessions.createBundle(),
      );
      final first = await alice.sessions.encrypt('bob', utf8.encode('hi'));
      await bob.sessions.decrypt(
        'alice',
        first,
        peerIdentityKey: await alice.sessions.identityKey(),
      );
      final before = Map.of(bob.store.peers);
      await expectLater(
        bob.sessions.decrypt(
          'alice',
          RatchetMessage(type: 1, ciphertext: utf8.encode('garbage')),
        ),
        throwsA(isA<RatchetDecryptException>()),
      );
      expect(bob.store.peers, before);
    });

    test('concurrent encrypts for one peer never lose a step', () async {
      final engine = _FakeRatchetEngine();
      final alice = _Device(engine);
      final bob = _Device(engine);
      await alice.sessions.startSession(
        'bob',
        await bob.sessions.createBundle(),
      );
      final messages = await Future.wait([
        for (var index = 0; index < 20; index++)
          alice.sessions.encrypt('bob', utf8.encode('m$index')),
      ]);
      expect(messages.map(_fakeIndex).toSet(), hasLength(20));
    });
  });

  group('RatchetSessions with the native engine', () {
    final engine = NativeRatchetEngine.tryCreate();
    if (engine == null) {
      if (Platform.environment['CONEST_REQUIRE_NATIVE_RATCHET'] == '1') {
        test('native library is required', () {
          fail('CONEST_NATIVE_LIBRARY has no conest_ratchet_call.');
        });
        return;
      }
      test(
        'native library unavailable',
        () {},
        skip: 'Set CONEST_NATIVE_LIBRARY to a build with conest_ratchet_call.',
      );
      return;
    }
    _sessionContract(() => engine);

    test('thirty messages delivered in reverse all decrypt', () async {
      final alice = _Device(engine);
      final bob = _Device(engine);
      await _establish(alice, bob);
      final sent = [
        for (var index = 0; index < 30; index++)
          await alice.sessions.encrypt('bob', utf8.encode('m$index')),
      ];
      for (var index = sent.length - 1; index >= 0; index--) {
        expect(
          utf8.decode(await bob.sessions.decrypt('alice', sent[index])),
          'm$index',
        );
      }
    });

    test('sessions survive a restart through the vault-backed store', () async {
      final directory = await Directory.systemTemp.createTemp(
        'conest-ratchet-',
      );
      addTearDown(() => directory.delete(recursive: true));
      VaultStore vault() => VaultStore(
        vaultFileProvider: () async => File('${directory.path}/vault'),
        keyProvider: FileVaultKeyProvider(
          fileProvider: () async => File('${directory.path}/key'),
        ),
      );
      final aliceStore = await vault().openRatchetStore();
      final alice = RatchetSessions(engine: engine, store: aliceStore);
      final bob = _Device(engine);
      await alice.startSession('bob', await bob.sessions.createBundle());
      final first = await alice.encrypt('bob', utf8.encode('before'));
      await bob.sessions.decrypt(
        'alice',
        first,
        peerIdentityKey: await alice.identityKey(),
      );
      final reply = await bob.sessions.encrypt('alice', utf8.encode('reply'));

      final restarted = RatchetSessions(
        engine: engine,
        store: await vault().openRatchetStore(),
      );
      expect(utf8.decode(await restarted.decrypt('bob', reply)), 'reply');
      final after = await restarted.encrypt('bob', utf8.encode('after'));
      expect(utf8.decode(await bob.sessions.decrypt('alice', after)), 'after');

      await vault().clear();
      expect(
        await Directory('${directory.path}/vault.ratchet').exists(),
        isFalse,
      );
    });
  });

  group('RatchetBundle', () {
    final key = base64Encode(List<int>.filled(32, 3)).replaceAll('=', '');

    test('round-trips and prefers the one-time key', () {
      final bundle = RatchetBundle.fromJson(
        jsonDecode(
          jsonEncode(
            RatchetBundle(
              identityKey: key,
              fallbackKey: key,
              oneTimeKey: key,
            ).toJson(),
          ),
        ),
      );
      expect(bundle.sessionKey, key);
      expect(
        RatchetBundle(identityKey: key, fallbackKey: 'f' * 43).sessionKey,
        'f' * 43,
      );
    });

    test('rejects malformed keys and versions', () {
      for (final json in <Object?>[
        null,
        {'version': 2, 'identityKey': key, 'fallbackKey': key},
        {'version': 1, 'identityKey': 'short', 'fallbackKey': key},
        {'version': 1, 'identityKey': key, 'fallbackKey': '$key='},
        {'version': 1, 'identityKey': key, 'fallbackKey': key, 'oneTimeKey': 4},
      ]) {
        expect(() => RatchetBundle.fromJson(json), throwsFormatException);
      }
    });
  });
}

/// Behaviour every engine must give [RatchetSessions].
void _sessionContract(RatchetEngine Function() engineFactory) {
  test(
    'a bundle opens a session and replies switch to normal messages',
    () async {
      final engine = engineFactory();
      final alice = _Device(engine);
      final bob = _Device(engine);
      await alice.sessions.startSession(
        'bob',
        await bob.sessions.createBundle(),
      );
      expect(await alice.sessions.hasSession('bob'), isTrue);
      final first = await alice.sessions.encrypt('bob', utf8.encode('hello'));
      expect(first.opensSession, isTrue);
      expect(
        utf8.decode(
          await bob.sessions.decrypt(
            'alice',
            first,
            peerIdentityKey: await alice.sessions.identityKey(),
          ),
        ),
        'hello',
      );
      final reply = await bob.sessions.encrypt('alice', utf8.encode('hi'));
      expect(reply.opensSession, isFalse);
      expect(utf8.decode(await alice.sessions.decrypt('bob', reply)), 'hi');
      final next = await alice.sessions.encrypt('bob', utf8.encode('again'));
      expect(next.opensSession, isFalse);
      expect(utf8.decode(await bob.sessions.decrypt('alice', next)), 'again');
    },
  );

  test('a pre-key message needs a known peer identity', () async {
    final engine = engineFactory();
    final alice = _Device(engine);
    final bob = _Device(engine);
    await alice.sessions.startSession('bob', await bob.sessions.createBundle());
    final first = await alice.sessions.encrypt('bob', utf8.encode('hello'));
    await expectLater(
      bob.sessions.decrypt('alice', first),
      throwsA(isA<RatchetDecryptException>()),
    );
  });

  test('a replayed message is rejected', () async {
    final engine = engineFactory();
    final alice = _Device(engine);
    final bob = _Device(engine);
    await _establish(alice, bob);
    final message = await alice.sessions.encrypt('bob', utf8.encode('once'));
    await bob.sessions.decrypt('alice', message);
    await expectLater(
      bob.sessions.decrypt('alice', message),
      throwsA(isA<RatchetDecryptException>()),
    );
  });

  test('simultaneous starts converge and keep at most four sessions', () async {
    final engine = engineFactory();
    final alice = _Device(engine);
    final bob = _Device(engine);
    final aliceIdentity = await alice.sessions.identityKey();
    final bobIdentity = await bob.sessions.identityKey();
    for (var round = 0; round < 3; round++) {
      await alice.sessions.startSession(
        'bob',
        await bob.sessions.createBundle(),
      );
      await bob.sessions.startSession(
        'alice',
        await alice.sessions.createBundle(),
      );
      final fromAlice = await alice.sessions.encrypt(
        'bob',
        utf8.encode('a$round'),
      );
      final fromBob = await bob.sessions.encrypt(
        'alice',
        utf8.encode('b$round'),
      );
      expect(
        utf8.decode(
          await bob.sessions.decrypt(
            'alice',
            fromAlice,
            peerIdentityKey: aliceIdentity,
          ),
        ),
        'a$round',
      );
      expect(
        utf8.decode(
          await alice.sessions.decrypt(
            'bob',
            fromBob,
            peerIdentityKey: bobIdentity,
          ),
        ),
        'b$round',
      );
    }
    final aliceState = await alice.store.readPeer('bob');
    expect(aliceState!.sessions.length, RatchetSessions.maxSessionsPerPeer);
    final again = await alice.sessions.encrypt('bob', utf8.encode('still'));
    expect(utf8.decode(await bob.sessions.decrypt('alice', again)), 'still');
  });

  test('forget drops every session with a peer', () async {
    final engine = engineFactory();
    final alice = _Device(engine);
    final bob = _Device(engine);
    await _establish(alice, bob);
    await alice.sessions.forget('bob');
    expect(await alice.sessions.hasSession('bob'), isFalse);
    await expectLater(
      alice.sessions.encrypt('bob', utf8.encode('x')),
      throwsA(isA<StateError>()),
    );
  });
}

class _Device {
  factory _Device(RatchetEngine engine) {
    final store = _RecordingStore();
    return _Device._(store, RatchetSessions(engine: engine, store: store));
  }
  _Device._(this.store, this.sessions);

  final _RecordingStore store;
  final RatchetSessions sessions;
}

/// Opens a session from [alice] to [bob] and confirms it with a reply.
Future<void> _establish(_Device alice, _Device bob) async {
  await alice.sessions.startSession('bob', await bob.sessions.createBundle());
  final first = await alice.sessions.encrypt('bob', utf8.encode('open'));
  await bob.sessions.decrypt(
    'alice',
    first,
    peerIdentityKey: await alice.sessions.identityKey(),
  );
  final reply = await bob.sessions.encrypt('alice', utf8.encode('ok'));
  await alice.sessions.decrypt('bob', reply);
}

class _RecordingStore extends MemoryRatchetStore {
  bool failWrites = false;

  @override
  Future<void> writePeer(String deviceId, RatchetPeerState state) async {
    if (failWrites) throw StateError('disk full');
    await super.writePeer(deviceId, state);
  }
}

int _fakeIndex(RatchetMessage message) =>
    (jsonDecode(utf8.decode(message.ciphertext)) as Map)['n'] as int;

/// Deterministic stand-in with Olm's observable rules: pre-key messages
/// until a reply arrives, one use per message index, one-time keys consumed
/// once, and identity keys bound to the session.
class _FakeRatchetEngine implements RatchetEngine {
  final _random = Random(7);

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
