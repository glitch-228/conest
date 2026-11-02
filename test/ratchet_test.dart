import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conest/src/ratchet.dart';
import 'package:conest/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ratchet_engine.dart';

void main() {
  group('RatchetSessions with a fake engine', () {
    _sessionContract(() => FakeRatchetEngine(random: Random(7)));

    test('a failed store write never releases ciphertext', () async {
      final engine = FakeRatchetEngine(random: Random(7));
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

    test('the strict fake: chains follow the DH ratchet, 5 are kept, keys '
        'per chain are limited', () async {
      final engine = FakeRatchetEngine(
        random: Random(7),
        skippedKeyLimit: 40,
        receivingChains: 5,
      );
      final a = _Device(engine);
      final b = _Device(engine);
      await a.sessions.startSession('b', await b.sessions.createBundle());
      Future<RatchetMessage> send(_Device from, String to, String text) =>
          from.sessions.encrypt(to, utf8.encode(text));
      Future<void> read(_Device at, String from, RatchetMessage m) async {
        await at.sessions.decrypt(
          from,
          m,
          peerIdentityKey: await (identical(at, a) ? b : a).sessions
              .identityKey(),
        );
      }

      // A reply that crosses a message in flight does not start a chain.
      final a0 = await send(a, 'b', 'a0');
      await read(b, 'a', a0);
      final b0 = await send(b, 'a', 'b0');
      final a1 = await send(a, 'b', 'a1'); // a has not read b0 yet
      await read(a, 'b', b0);
      await read(b, 'a', a1); // still the first chain of a: readable
      // After reading b0, a's next message starts a chain.
      final a2 = await send(a, 'b', 'a2');
      expect(_fakeChain(a2), 1);
      expect(_fakeChain(a1), 0);
      // An envelope held back while the conversation turns 6 times is lost,
      // and so is every older chain once 5 newer ones are known.
      final held = await send(b, 'a', 'held'); // b chain 1 after reading a1?
      for (var i = 0; i < 6; i++) {
        final m = await send(a, 'b', 'x$i');
        await read(b, 'a', m);
        final r = await send(b, 'a', 'y$i');
        await read(a, 'b', r);
      }
      await expectLater(
        read(a, 'b', held),
        throwsA(isA<RatchetDecryptException>()),
        reason: 'a chain older than the ones kept was still readable',
      );
      // 41 messages of one chain: the first one is out of reach.
      final burst = <RatchetMessage>[];
      for (var i = 0; i < 42; i++) {
        burst.add(await send(a, 'b', 'n$i'));
      }
      await read(b, 'a', burst.last);
      await expectLater(
        read(b, 'a', burst.first),
        throwsA(isA<RatchetDecryptException>()),
      );
      await read(b, 'a', burst[5]);
    });

    test('a late type 1 message is stale while a session works, and plain '
        'after the runtime state is cleared', () async {
      final engine = FakeRatchetEngine(random: Random(7));
      final a = _Device(engine);
      final b = _Device(engine);
      await a.sessions.startSession('b', await b.sessions.createBundle());
      final first = await a.sessions.encrypt('b', utf8.encode('hi'));
      await b.sessions.decrypt(
        'a',
        first,
        peerIdentityKey: await a.sessions.identityKey(),
      );
      final garbage = RatchetMessage(type: 1, ciphertext: utf8.encode('x'));
      await expectLater(
        b.sessions.decrypt('a', garbage),
        throwsA(isA<RatchetStaleMessageException>()),
      );
      b.sessions.clearRuntime();
      await expectLater(
        b.sessions.decrypt('a', garbage),
        throwsA(
          isA<RatchetDecryptException>().having(
            (e) => e is RatchetStaleMessageException,
            'stale',
            false,
          ),
        ),
      );
    });

    test('a pre-key message from a peer not known yet says so; one that '
        'cannot be read otherwise does not', () async {
      final engine = FakeRatchetEngine(random: Random(7));
      final alice = _Device(engine);
      final bob = _Device(engine);
      await alice.sessions.startSession(
        'bob',
        await bob.sessions.createBundle(),
      );
      final first = await alice.sessions.encrypt('bob', utf8.encode('hi'));
      await expectLater(
        bob.sessions.decrypt('alice', first),
        throwsA(isA<RatchetUnknownPeerException>()),
      );
      await bob.sessions.decrypt(
        'alice',
        first,
        peerIdentityKey: await alice.sessions.identityKey(),
      );
      await expectLater(
        bob.sessions.decrypt(
          'alice',
          RatchetMessage(type: 1, ciphertext: utf8.encode('garbage')),
        ),
        throwsA(
          isA<RatchetDecryptException>().having(
            (error) => error is RatchetUnknownPeerException,
            'unknown peer',
            false,
          ),
        ),
      );
    });

    test('a failed decrypt leaves stored state untouched', () async {
      final engine = FakeRatchetEngine(random: Random(7));
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
      final engine = FakeRatchetEngine(random: Random(7));
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

  group('bulk keys', () {
    test(
      'rotate daily, expire after retention and stay sealed at rest',
      () async {
        var now = DateTime.utc(2026, 10, 2, 12);
        final store = MemoryRatchetStore(pickleKey: List<int>.filled(32, 9));
        final sessions = RatchetSessions(
          engine: FakeRatchetEngine(random: Random(3)),
          store: store,
          now: () => now,
        );
        final (first, created) = await sessions.sendBulkKey('bob');
        expect(created, isTrue);
        expect(first.key, hasLength(32));
        final (again, createdAgain) = await sessions.sendBulkKey('bob');
        expect(createdAgain, isFalse);
        expect(again.id, first.id);
        now = now.add(RatchetSessions.bulkKeyRotation);
        final (rotated, rotatedCreated) = await sessions.sendBulkKey('bob');
        expect(rotatedCreated, isTrue);
        expect(rotated.id, isNot(first.id));

        await sessions.rememberReceivedBulkKey(
          'bob',
          RatchetBulkKey(
            id: 'ab' * 16,
            key: List<int>.filled(32, 5),
            createdAtMs: now.millisecondsSinceEpoch,
          ),
        );
        expect(
          await sessions.receivedBulkKey('bob', 'ab' * 16),
          List.filled(32, 5),
        );
        expect(await sessions.receivedBulkKey('bob', 'cd' * 16), isNull);
        expect(
          store.peers['bob'],
          isNot(contains(base64Encode(List.filled(32, 5)))),
        );
        expect(store.peers['bob'], isNot(contains(base64Encode(rotated.key))));

        now = now.add(RatchetSessions.receivedBulkKeyRetention);
        expect(await sessions.receivedBulkKey('bob', 'ab' * 16), isNull);
      },
    );

    test('bulk keys survive session changes for the same peer', () async {
      final engine = FakeRatchetEngine(random: Random(4));
      final alice = _Device(engine);
      final bob = _Device(engine);
      final (key, _) = await alice.sessions.sendBulkKey('bob');
      await alice.sessions.startSession(
        'bob',
        await bob.sessions.createBundle(),
      );
      await alice.sessions.encrypt('bob', utf8.encode('x'));
      final (same, created) = await alice.sessions.sendBulkKey('bob');
      expect(created, isFalse);
      expect(same.id, key.id);
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

int _fakeChain(RatchetMessage message) =>
    (jsonDecode(utf8.decode(message.ciphertext)) as Map)['c'] as int;

int _fakeIndex(RatchetMessage message) =>
    (jsonDecode(utf8.decode(message.ciphertext)) as Map)['n'] as int;
