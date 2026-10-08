import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/bitchat/direct.dart';
import 'package:conest/src/bitchat/noise.dart';
import 'package:conest/src/bitchat/packet.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var clock = DateTime.utc(2026, 10, 7, 12);
  setUp(() => clock = DateTime.utc(2026, 10, 7, 12));
  Future<BitchatDirect> person(String name, int seed) => BitchatDirect.create(
    nickname: name,
    noiseSeed: List.filled(32, seed),
    signingSeed: List.filled(32, seed + 100),
    now: () => clock,
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

  test('a lost handshake message is retried after its deadline', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    final got = <String>[];
    bob.events.listen((e) {
      if (e is BitchatMessageReceived) got.add(e.text);
    });
    // The first message never reaches Bob.
    final (lost, _) = await alice.sendText(bob.peerIdHex, 'eventually');
    expect(lost.single.type, BitchatType.noiseHandshake);
    // Before the deadline nothing is resent; after it, a new handshake.
    expect(await alice.tick(), isEmpty);
    clock = clock.add(const Duration(seconds: 11));
    final retry = await alice.tick();
    expect(retry.single.type, BitchatType.noiseHandshake);
    await exchange(retry, [alice, bob]);
    await Future<void>.delayed(Duration.zero);
    expect(got, ['eventually']);
  });

  test('a malformed handshake answer does not stall the pair', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    final got = <String>[];
    bob.events.listen((e) {
      if (e is BitchatMessageReceived) got.add(e.text);
    });
    final (first, _) = await alice.sendText(bob.peerIdHex, 'one');
    final answer = (await bob.handleNoise(
      BitchatPacket.decode(first.single.encode())!,
    )).single;
    final broken = Uint8List.fromList(answer.payload)..[50] ^= 1;
    expect(
      await alice.handleNoise(
        BitchatPacket(
          type: answer.type,
          senderId: answer.senderId,
          recipientId: answer.recipientId,
          timestamp: answer.timestamp,
          payload: broken,
        ),
      ),
      isEmpty,
    );
    // The broken handshake is gone: the next message starts a fresh one.
    final (again, _) = await alice.sendText(bob.peerIdHex, 'two');
    expect(again.single.type, BitchatType.noiseHandshake);
    await exchange(again, [alice, bob]);
    await Future<void>.delayed(Duration.zero);
    expect(got, containsAll(['one', 'two']));
  });

  test('a spoofed handshake does not cut off a working session', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    final mallory = await person('mallory', 3);
    final got = <String>[];
    bob.events.listen((e) {
      if (e is BitchatMessageReceived) got.add(e.text);
    });
    await exchange((await alice.sendText(bob.peerIdHex, 'first')).$1, [
      alice,
      bob,
    ]);
    // Mallory sends Bob a first handshake message claiming to be Alice.
    final (fake, _) = await mallory.sendText(bob.peerIdHex, 'x');
    await bob.handleNoise(
      BitchatPacket(
        type: fake.single.type,
        senderId: alice.peerId,
        recipientId: bob.peerId,
        timestamp: fake.single.timestamp,
        payload: fake.single.payload,
      ),
    );
    // Alice's next message, on the session she has, still gets through.
    await exchange((await alice.sendText(bob.peerIdHex, 'second')).$1, [
      alice,
      bob,
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(got, ['first', 'second']);
  });

  test('handshakes are rate-limited per peer', () async {
    final bob = await person('bob', 2);
    final alice = await person('alice', 1);
    var answered = 0;
    // Twelve fresh first messages from "Alice" within one minute.
    for (var attempt = 0; attempt < 12; attempt++) {
      final handshake = await NoiseXXHandshake.start(
        initiator: true,
        staticSeed: List.filled(32, 1),
      );
      answered += (await bob.handleNoise(
        BitchatPacket(
          type: BitchatType.noiseHandshake,
          senderId: alice.peerId,
          recipientId: bob.peerId,
          timestamp: clock.millisecondsSinceEpoch,
          payload: await handshake.writeMessage(),
        ),
      )).length;
    }
    expect(answered, 10);
  });

  test('the responder refuses a key that is not the claimed id\'s', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    final mallory = await person('mallory', 3);
    // Mallory starts a handshake with Bob, claiming Alice's id.
    final (first, _) = await mallory.sendText(bob.peerIdHex, 'x');
    final asAlice = BitchatPacket(
      type: first.single.type,
      senderId: alice.peerId,
      recipientId: bob.peerId,
      timestamp: first.single.timestamp,
      payload: first.single.payload,
    );
    final second = (await bob.handleNoise(asAlice)).single;
    // Bob's answer goes to "Alice"; Mallory reads it as if sent to her.
    final third = await mallory.handleNoise(
      BitchatPacket(
        type: second.type,
        senderId: bob.peerId,
        recipientId: mallory.peerId,
        timestamp: second.timestamp,
        payload: second.payload,
      ),
    );
    await bob.handleNoise(
      BitchatPacket(
        type: third.first.type,
        senderId: alice.peerId,
        recipientId: bob.peerId,
        timestamp: third.first.timestamp,
        payload: third.first.payload,
      ),
    );
    expect(bob.hasSession(alice.peerIdHex), isFalse);
    // The real Alice can still reach Bob afterwards.
    clock = clock.add(const Duration(seconds: 21));
    final got = <String>[];
    bob.events.listen((e) {
      if (e is BitchatMessageReceived) got.add(e.text);
    });
    await exchange((await alice.sendText(bob.peerIdHex, 'real')).$1, [
      alice,
      bob,
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(got, ['real']);
  });

  test('public messages are read only from checked announcers', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    BitchatPacket air(BitchatPacket packet) =>
        BitchatPacket.decode(packet.encode())!;
    final hello = air((await alice.publicMessages('hello everyone')).single);
    expect(hello.recipientId, isNull);
    // Unknown sender: nobody to check the signature against.
    expect(await bob.readPublic(hello), isNull);
    await bob.handleAnnounce(air(await alice.announce()));
    final read = (await bob.readPublic(hello))!;
    expect(read.text, 'hello everyone');
    expect(read.nickname, 'alice');
    expect(read.peerId, alice.peerIdHex);
    expect(
      read.id,
      bitchatPublicMessageId(
        alice.peerIdHex,
        hello.timestamp,
        'hello'
        ' everyone',
      ),
    );
    expect(read.id, hasLength(32));
    // Our own copy relayed back is not shown again.
    expect(await alice.readPublic(hello), isNull);
    // Changed on the way: the signature no longer matches.
    final altered = BitchatPacket(
      type: hello.type,
      senderId: hello.senderId,
      timestamp: hello.timestamp,
      payload: Uint8List.fromList('hello evil'.codeUnits),
      signature: hello.signature,
    );
    expect(await bob.readPublic(altered), isNull);
    // Someone else claiming Alice's id cannot sign for her.
    final mallory = await person('mallory', 3);
    final forged = (await mallory.publicMessages('I am alice')).single;
    expect(
      await bob.readPublic(
        BitchatPacket(
          type: forged.type,
          senderId: alice.peerId,
          timestamp: forged.timestamp,
          payload: forged.payload,
          signature: forged.signature,
        ),
      ),
      isNull,
    );
    // Too old to show.
    clock = clock.add(const Duration(hours: 7));
    await bob.handleAnnounce(air(await alice.announce()));
    clock = clock.subtract(const Duration(hours: 7));
    final stale = air((await alice.publicMessages('old news')).single);
    clock = clock.add(const Duration(hours: 7));
    expect(await bob.readPublic(stale), isNull);
  });

  test(
    'long mesh chat text goes as messages bitchat never compresses',
    () async {
      final alice = await person('alice', 1);
      final bob = await person('bob', 2);
      await bob.handleAnnounce(
        BitchatPacket.decode((await alice.announce()).encode())!,
      );
      final text = List.generate(45, (i) => 'word$i').join(' ');
      final packets = await alice.publicMessages(text);
      expect(packets.length, greaterThan(1));
      for (final packet in packets) {
        expect(packet.payload.length, lessThan(bitchatCompressionThreshold));
      }
      final read = [
        for (final packet in packets)
          (await bob.readPublic(BitchatPacket.decode(packet.encode())!))!,
      ];
      expect(read.map((m) => m.text).join(' '), text);
      expect(read.map((m) => m.id).toSet(), hasLength(packets.length));
      // More than an iPhone takes at once is refused, not cut.
      expect(() => alice.publicMessages('word ' * 200), throwsArgumentError);
    },
  );

  test('a long nickname is cut so the announce is never compressed', () async {
    final alice = await BitchatDirect.create(
      nickname: 'a very long nickname that goes on and on and on',
      noiseSeed: List.filled(32, 1),
      signingSeed: List.filled(32, 101),
      now: () => clock,
    );
    final announce = await alice.announce();
    expect(announce.payload.length, lessThan(bitchatCompressionThreshold));
    final bob = await person('bob', 2);
    await bob.handleAnnounce(BitchatPacket.decode(announce.encode())!);
    expect(
      'a very long nickname that goes on and on and on',
      startsWith(bob.peer(alice.peerIdHex)!.nickname),
    );
  });

  test('compressed announces and messages from bitchat are read', () async {
    // What a bitchat phone sends for long payloads: the size, then raw
    // deflate, flagged compressed, and signed in that form.
    final iphone = await person('iphone', 7);
    final bob = await person('bob', 2);
    Uint8List compressed(List<int> plain) => Uint8List.fromList([
      plain.length >> 8,
      plain.length & 0xff,
      ...ZLibEncoder(raw: true).convert(plain),
    ]);
    Future<BitchatPacket> signedByPhone(BitchatPacket unsigned) async {
      // bitchat signs its own encoding: TTL 0, compressed, padded.
      final signature = await Ed25519().sign(
        unsigned.copyWith(ttl: 0).encode(pad: true),
        keyPair: await Ed25519().newKeyPairFromSeed(List.filled(32, 107)),
      );
      return unsigned.copyWith(signature: Uint8List.fromList(signature.bytes));
    }

    final plainAnnounce = (await iphone.announce()).payload;
    final announce = await signedByPhone(
      BitchatPacket(
        type: BitchatType.announce,
        senderId: iphone.peerId,
        timestamp: clock.millisecondsSinceEpoch,
        payload: compressed(plainAnnounce),
        compressed: true,
      ),
    );
    await bob.handleAnnounce(BitchatPacket.decode(announce.encode())!);
    expect(bob.peer(iphone.peerIdHex)?.nickname, 'iphone');

    final text = 'a long message that bitchat would compress ' * 4;
    final message = await signedByPhone(
      BitchatPacket(
        type: BitchatType.message,
        senderId: iphone.peerId,
        timestamp: clock.millisecondsSinceEpoch,
        payload: compressed(utf8.encode(text)),
        compressed: true,
      ),
    );
    final read = await bob.readPublic(BitchatPacket.decode(message.encode())!);
    expect(read?.text, text);
    expect(
      read?.id,
      bitchatPublicMessageId(iphone.peerIdHex, message.timestamp, text),
    );
  });

  test('a peer\'s first signing key stays, as bitchat keeps it', () async {
    final alice = await person('alice', 1);
    final bob = await person('bob', 2);
    BitchatPacket air(BitchatPacket packet) =>
        BitchatPacket.decode(packet.encode())!;
    await bob.handleAnnounce(air(await alice.announce()));
    // Mallory announces Alice's Noise key with her own signing key.
    final mallory = await BitchatDirect.create(
      nickname: 'alice',
      noiseSeed: List.filled(32, 1),
      signingSeed: List.filled(32, 103),
      now: () => clock,
    );
    clock = clock.add(const Duration(seconds: 1));
    await bob.handleAnnounce(air(await mallory.announce()));
    final forged = (await mallory.publicMessages('send me money')).single;
    expect(await bob.readPublic(air(forged)), isNull);
    final real = (await alice.publicMessages('it is really me')).single;
    expect((await bob.readPublic(air(real)))?.text, 'it is really me');
  });

  test('junk announces do not keep a real new peer out', () async {
    final bob = await person('bob', 2);
    final alice = await person('alice', 1);
    final real = await alice.announce();
    // Copies of Alice's announce with broken signatures: refused, and they
    // do not use up the room for new peers (only checking time, of which
    // a minute has room for this many).
    for (var i = 0; i < 250; i++) {
      final junk = BitchatPacket(
        type: real.type,
        senderId: real.senderId,
        timestamp: real.timestamp - i - 1,
        payload: real.payload,
        signature: Uint8List(64)..[0] = i % 256,
      );
      expect(await bob.handleAnnounce(junk), isFalse);
    }
    expect(bob.peer(alice.peerIdHex), isNull);
    expect(await bob.handleAnnounce(real), isTrue);
    expect(bob.peer(alice.peerIdHex)?.nickname, 'alice');
  });
}
