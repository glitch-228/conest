import 'dart:typed_data';

import 'package:conest/src/bitchat/direct.dart';
import 'package:conest/src/bitchat/packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<BitchatDirect> person(String name, int seed) => BitchatDirect.create(
    nickname: name,
    noiseSeed: List.filled(32, seed),
    signingSeed: List.filled(32, seed + 100),
  );

  /// Delivers [packets] to whichever of [people] they are addressed to,
  /// until nothing more is sent; returns everything that crossed.
  Future<List<BitchatPacket>> exchange(
    List<BitchatPacket> packets,
    List<BitchatDirect> people,
  ) async {
    final crossed = <BitchatPacket>[];
    var queue = packets;
    while (queue.isNotEmpty) {
      final next = <BitchatPacket>[];
      for (final packet in queue) {
        crossed.add(packet);
        // Over the air: encoded and decoded again.
        final received = BitchatPacket.decode(packet.encode())!;
        for (final someone in people) {
          next.addAll(await someone.handleNoise(received));
        }
      }
      queue = next;
    }
    return crossed;
  }

  test('announces are signed, checked and pinned', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    await bob.handleAnnounce(
      BitchatPacket.decode((await alice.announce()).encode())!,
    );
    expect(bob.peer(alice.peerIdHex)?.nickname, 'alice');

    // A forged announce for Alice's id, signed by someone else's key.
    final mallory = await person('mallory', 3);
    final forged = await mallory.announce();
    final claim = BitchatPacket(
      type: BitchatType.announce,
      senderId: alice.peerId,
      timestamp: forged.timestamp,
      payload: forged.payload,
      signature: forged.signature,
    );
    final carol = await person('carol', 4);
    await carol.handleAnnounce(claim);
    expect(carol.peer(alice.peerIdHex), isNull);

    // A bad signature on an otherwise right announce.
    final real = await alice.announce();
    await carol.handleAnnounce(real.copyWith(signature: Uint8List(64)));
    expect(carol.peer(alice.peerIdHex), isNull);
  });

  test(
    'a message waits for the handshake, then arrives with receipts',
    () async {
      final alice = await person('alice', 1);
      final bob = await person('bob', 2);
      final aliceEvents = <BitchatDirectEvent>[];
      final bobEvents = <BitchatDirectEvent>[];
      alice.events.listen(aliceEvents.add);
      bob.events.listen(bobEvents.add);

      final (first, id) = await alice.sendText(bob.peerIdHex, 'hi from conest');
      // Only the handshake goes first.
      expect(first.single.type, BitchatType.noiseHandshake);
      final crossed = await exchange(first, [alice, bob]);
      await Future<void>.delayed(Duration.zero);
      expect(crossed.map((p) => p.type), [
        BitchatType.noiseHandshake,
        BitchatType.noiseHandshake,
        BitchatType.noiseHandshake,
        BitchatType.noiseEncrypted, // the message
        BitchatType.noiseEncrypted, // Bob's delivery receipt
      ]);
      final received = bobEvents.whereType<BitchatMessageReceived>().single;
      expect(received.text, 'hi from conest');
      expect(received.messageId, id);
      expect(received.peerId, alice.peerIdHex);
      final delivered = aliceEvents.whereType<BitchatReceiptReceived>().single;
      expect(delivered.messageId, id);
      expect(delivered.read, isFalse);

      // With the session up, messages go straight away, both ways.
      final (reply, _) = await bob.sendText(alice.peerIdHex, 'hello back');
      expect(reply.single.type, BitchatType.noiseEncrypted);
      await exchange(
        [...reply, ...await bob.sendReadReceipt(alice.peerIdHex, id)],
        [alice, bob],
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        aliceEvents.whereType<BitchatMessageReceived>().single.text,
        'hello back',
      );
      expect(
        aliceEvents.whereType<BitchatReceiptReceived>().where((r) => r.read),
        hasLength(1),
      );

      // A replayed message is not read twice.
      final (again, _) = await alice.sendText(bob.peerIdHex, 'once');
      await exchange(again, [alice, bob]);
      await exchange(again, [alice, bob]);
      await Future<void>.delayed(Duration.zero);
      expect(
        bobEvents.whereType<BitchatMessageReceived>().where(
          (m) => m.text == 'once',
        ),
        hasLength(1),
      );
    },
  );

  test('a handshake answered under someone else\'s id is dropped', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    final mallory = await person('mallory', 3);
    final (first, _) = await alice.sendText(bob.peerIdHex, 'for bob only');
    // Mallory intercepts Alice's handshake and answers as if she were Bob.
    final redirected = BitchatPacket(
      type: first.single.type,
      senderId: alice.peerId,
      recipientId: mallory.peerId,
      timestamp: first.single.timestamp,
      payload: first.single.payload,
    );
    final answer = (await mallory.handleNoise(redirected)).single;
    final spoofed = BitchatPacket(
      type: answer.type,
      senderId: bob.peerId,
      recipientId: alice.peerId,
      timestamp: answer.timestamp,
      payload: answer.payload,
    );
    final sent = await alice.handleNoise(spoofed);
    // Mallory's key is not the one Bob's id stands for: nothing is sent.
    expect(sent.where((p) => p.type == BitchatType.noiseEncrypted), isEmpty);
  });

  test('both sides starting at once still end with one session', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    final aliceGot = <String>[];
    final bobGot = <String>[];
    alice.events.listen((e) {
      if (e is BitchatMessageReceived) aliceGot.add(e.text);
    });
    bob.events.listen((e) {
      if (e is BitchatMessageReceived) bobGot.add(e.text);
    });
    final (fromAlice, _) = await alice.sendText(bob.peerIdHex, 'a');
    final (fromBob, _) = await bob.sendText(alice.peerIdHex, 'b');
    await exchange([...fromAlice, ...fromBob], [alice, bob]);
    await Future<void>.delayed(Duration.zero);
    expect(aliceGot, ['b']);
    expect(bobGot, ['a']);
  });
}
