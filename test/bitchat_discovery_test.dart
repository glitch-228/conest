import 'dart:typed_data';

import 'package:conest/src/bitchat/direct.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime clock;
  setUp(() => clock = DateTime.utc(2026, 10, 30, 12));

  Future<BitchatDirect> person(int seed, {bool listeningOnly = false}) async {
    final direct = await BitchatDirect.create(
      nickname: 'person $seed',
      noiseSeed: List.generate(32, (i) => (seed >> (i % 4 * 8)) & 0xff),
      signingSeed: List.generate(32, (i) => (seed + i + 100) & 0xff),
      listeningOnly: listeningOnly,
      now: () => clock,
    );
    addTearDown(direct.close);
    return direct;
  }

  test(
    'hidden discovery accepts verified announces and rejects forgeries',
    () async {
      final listener = await person(0, listeningOnly: true);
      final phone = await person(1);
      final announce = await phone.announce();
      expect(
        await listener.handleAnnounce(
          announce.copyWith(signature: Uint8List(64)),
        ),
        isFalse,
      );
      expect(listener.peers, isEmpty);
      await listener.handleAnnounce(announce);
      final peer = listener.peers.single;
      expect(peer.peerId, phone.peerIdHex);
      expect(peer.nickname, 'person 1');
      expect(peer.noiseKey, phone.noisePublicKey);
      expect(peer.signingKey, phone.signingPublicKey);
      expect(peer.lastSeen, clock);
      expect(peer.confirmed, isFalse);
    },
  );

  test(
    'overlapping announces cannot replace the first pinned signing key',
    () async {
      final listener = await person(0, listeningOnly: true);
      final phone = await person(1);
      final impostor = await BitchatDirect.create(
        nickname: 'impostor',
        noiseSeed: List.generate(32, (i) => (1 >> (i % 4 * 8)) & 0xff),
        signingSeed: List.filled(32, 88),
        now: () => clock,
      );
      addTearDown(impostor.close);
      final real = await phone.announce();
      final fake = await impostor.announce();
      await Future.wait([
        listener.handleAnnounce(real),
        listener.handleAnnounce(fake),
      ]);
      expect(listener.peers.single.signingKey, phone.signingPublicKey);
      expect(listener.peers.single.nickname, 'person 1');
    },
  );

  test('an announce finishing verification after close is discarded', () async {
    final listener = await person(0, listeningOnly: true);
    final phone = await person(1);
    final announce = await phone.announce();
    final pending = listener.handleAnnounce(announce);
    await listener.close();
    await pending;
    expect(listener.peers, isEmpty);
  });

  test(
    'hidden discovery enforces the 120 second timestamp window both ways',
    () async {
      final listener = await person(0, listeningOnly: true);
      final phone = await person(1);
      final start = clock;
      clock = start.subtract(const Duration(seconds: 121));
      final stale = await phone.announce();
      clock = start.add(const Duration(seconds: 121));
      final future = await phone.announce();
      clock = start;
      await listener.handleAnnounce(stale);
      await listener.handleAnnounce(future);
      expect(listener.peers, isEmpty);
      clock = start.subtract(const Duration(seconds: 120));
      final boundary = await phone.announce();
      clock = start;
      await listener.handleAnnounce(boundary);
      expect(listener.peers.single.peerId, phone.peerIdHex);
    },
  );

  test('hidden discovery is bounded even when verification overlaps', () async {
    final listener = await person(0, listeningOnly: true);
    final first = await person(1);
    await listener.handleAnnounce(await first.announce());
    clock = clock.add(const Duration(seconds: 1));
    for (var seed = 2; seed <= 255; seed++) {
      final phone = await person(seed);
      await listener.handleAnnounce(await phone.announce());
    }
    final packets = [
      for (var seed = 256; seed <= 259; seed++)
        await (await person(seed)).announce(),
    ];
    await Future.wait(packets.map(listener.handleAnnounce));
    expect(listener.peers, hasLength(256));
    expect(listener.peer(first.peerIdHex), isNull);
  });

  test(
    'hidden discovery expires unheard peers and retains refreshed peers',
    () async {
      final listener = await person(0, listeningOnly: true);
      final old = await person(1);
      final active = await person(2);
      await listener.handleAnnounce(await old.announce());
      await listener.handleAnnounce(await active.announce());
      clock = clock.add(const Duration(minutes: 4));
      await listener.handleAnnounce(await active.announce());
      clock = clock.add(const Duration(minutes: 1));
      expect(listener.prunePeers(), isTrue);
      expect(listener.peers.map((p) => p.peerId), [active.peerIdHex]);
      clock = clock.add(const Duration(minutes: 4));
      expect(listener.peers, isEmpty);
      expect(listener.prunePeers(), isFalse);
      // An expired hidden peer cannot be carried into the reachable identity.
      final visible = await person(3);
      visible.adoptPeers(listener.peers);
      expect(visible.peers, isEmpty);
    },
  );

  test(
    'visible discovery keeps its previous timestamp window and retention',
    () async {
      final visible = await person(0);
      final phone = await person(1);
      final announce = await phone.announce();
      clock = clock.add(const Duration(minutes: 3));
      await visible.handleAnnounce(announce);
      expect(visible.peers.single.peerId, phone.peerIdHex);
      clock = clock.add(const Duration(minutes: 6));
      expect(visible.prunePeers(), isFalse);
      expect(visible.peers.single.peerId, phone.peerIdHex);
    },
  );
}
