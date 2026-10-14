import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:conest/src/ratchet.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ratchet_engine.dart';

void main() {
  for (final lookup in ['availability', 'confirmation', 'bulk key']) {
    test(
      'concurrent $lookup lookup preserves the ratchet send counter',
      () async {
        final engine = FakeRatchetEngine(random: Random(7));
        final store = _PausedRatchetStore();
        final alice = RatchetSessions(engine: engine, store: store);
        final bob = RatchetSessions(
          engine: engine,
          store: MemoryRatchetStore(),
        );
        addTearDown(() {
          if (!store.allowWrite.isCompleted) store.allowWrite.complete();
          if (!store.allowRead.isCompleted) store.allowRead.complete();
        });
        await alice.startSession('bob', await bob.createBundle());
        final identity = await alice.identityKey();

        // The next write invalidates the cache and waits before persisting.
        // An unlocked lookup can read the old pickle and finish after the write.
        store.pauseNextWrite = true;
        store.pauseReads = true;
        final pending = alice.encrypt('bob', [1]);
        await store.writeStarted.future;
        final query = switch (lookup) {
          'availability' => alice.hasSession('bob'),
          'confirmation' => alice.confirmedAt('bob'),
          _ => alice.receivedBulkKey('bob', 'ab' * 16),
        };
        await Future<void>.delayed(Duration.zero);
        store.allowWrite.complete();
        final first = await pending;
        store.allowRead.complete();
        await query;

        final second = await alice.encrypt('bob', [2]);
        expect(_index(second), _index(first) + 1);
        expect(await bob.decrypt('alice', first, peerIdentityKey: identity), [
          1,
        ]);
        expect(await bob.decrypt('alice', second), [2]);
      },
    );
  }
}

int _index(RatchetMessage message) =>
    (jsonDecode(utf8.decode(message.ciphertext)) as Map)['n'] as int;

class _PausedRatchetStore extends MemoryRatchetStore {
  bool pauseNextWrite = false;
  bool pauseReads = false;
  final writeStarted = Completer<void>();
  final allowWrite = Completer<void>();
  final allowRead = Completer<void>();

  @override
  Future<RatchetPeerState?> readPeer(String deviceId) async {
    final snapshot = await super.readPeer(deviceId);
    if (pauseReads) await allowRead.future;
    return snapshot;
  }

  @override
  Future<void> writePeer(String deviceId, RatchetPeerState state) async {
    if (pauseNextWrite) {
      pauseNextWrite = false;
      writeStarted.complete();
      await allowWrite.future;
    }
    await super.writePeer(deviceId, state);
  }
}
