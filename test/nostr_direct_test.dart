import 'dart:typed_data';

import 'package:conest/src/nostr/event.dart';
import 'package:conest/src/nostr/nip17.dart';
import 'package:conest/src/nostr/secp256k1.dart';
import 'package:conest/src/nostr_direct.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_nostr_relay.dart';

void main() {
  Uint8List key(int seed) =>
      Uint8List.fromList(List.generate(32, (i) => (i * 11 + seed) % 251 + 1));

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('people on Nostr write to each other at their own relays', () async {
    final relays = FakeNostrRelays();
    for (final url in [
      'wss://alice.relay',
      'wss://bob.relay',
      'wss://carol.relay',
      'wss://purplepag.es',
    ]) {
      relays.relay(url);
    }
    NostrDirectService person(
      int seed,
      String relay,
      List<NostrDirectMessage> got,
    ) {
      final service = NostrDirectService(
        secretKey: key(seed),
        relays: [Uri.parse(relay)],
        onMessage: got.add,
        connector: relays.connect,
      )..start();
      addTearDown(service.stop);
      return service;
    }

    final aliceGot = <NostrDirectMessage>[];
    final bobGot = <NostrDirectMessage>[];
    final carolGot = <NostrDirectMessage>[];
    final alice = person(1, 'wss://alice.relay', aliceGot);
    final bob = person(2, 'wss://bob.relay', bobGot);
    final carol = person(3, 'wss://carol.relay', carolGot);
    // Each publishes where it reads, at the indexer.
    await until(() => relays.relay('wss://purplepag.es').stored.length == 3);
    expect(
      relays
          .relay('wss://purplepag.es')
          .stored
          .every((event) => event.kind == Nip17Kind.dmRelays),
      isTrue,
    );

    final sent = await alice.send([bob.publicKey], 'hi Bob');
    await until(() => bobGot.isNotEmpty);
    expect(bobGot.single.content, 'hi Bob');
    expect(bobGot.single.author, alice.publicKey);
    expect(bobGot.single.id, sent.id);
    // Found through Bob's list: only Bob's relay has his copy.
    expect(
      relays
          .relay('wss://bob.relay')
          .stored
          .any((event) => event.tag('p') == bob.publicKey),
      isTrue,
    );
    expect(
      relays
          .relay('wss://alice.relay')
          .stored
          .any((event) => event.tag('p') == bob.publicKey),
      isFalse,
    );
    // Alice's own copy, for her other devices.
    await until(() => aliceGot.isNotEmpty);
    expect(aliceGot.single.id, sent.id);

    // A group: everyone in it gets the same message.
    await bob.send(
      [alice.publicKey, carol.publicKey],
      'hello both',
      subject: 'Plans',
    );
    await until(() => carolGot.isNotEmpty && aliceGot.length == 2);
    expect(carolGot.single.subject, 'Plans');
    expect(carolGot.single.participants, {
      alice.publicKey,
      bob.publicKey,
      carol.publicKey,
    });
    expect(aliceGot.last.content, 'hello both');
    // A copy read twice (two relays) counts once.
    expect(bobGot.where((m) => m.content == 'hello both'), hasLength(1));
  });

  test('a key with nowhere to write is reported', () async {
    final relays = FakeNostrRelays()..relay('wss://alice.relay');
    final alice = NostrDirectService(
      secretKey: key(1),
      relays: [Uri.parse('wss://alice.relay')],
      onMessage: (_) {},
      connector: relays.connect,
      indexers: const [],
    )..start();
    addTearDown(alice.stop);
    // Someone whose relays refuse connections.
    final stranger = hexEncode(Secp256k1.publicKey(key(5)));
    expect(
      alice.send(
        [stranger],
        'anyone?',
        hints: {
          stranger: [Uri.parse('wss://gone.relay')],
        },
      ),
      throwsStateError,
    );
  });

  test('a forged relay list does not redirect messages', () async {
    final relays = FakeNostrRelays();
    for (final url in [
      'wss://alice.relay',
      'wss://bob.relay',
      'wss://evil.relay',
      'wss://purplepag.es',
    ]) {
      relays.relay(url);
    }
    final bobGot = <NostrDirectMessage>[];
    final bob = NostrDirectService(
      secretKey: key(2),
      relays: [Uri.parse('wss://bob.relay')],
      onMessage: bobGot.add,
      connector: relays.connect,
    )..start();
    addTearDown(bob.stop);
    await until(() => relays.relay('wss://purplepag.es').stored.isNotEmpty);
    // A newer list under Bob's key, but not signed by him.
    final real = relays.relay('wss://purplepag.es').stored.single;
    relays
        .relay('wss://purplepag.es')
        .inject(
          NostrEvent(
            id: 'f' * 64,
            pubkey: bob.publicKey,
            createdAt: real.createdAt + 100,
            kind: Nip17Kind.dmRelays,
            tags: [
              ['relay', 'wss://evil.relay'],
            ],
            content: '',
            sig: '0' * 128,
          ),
        );
    final alice = NostrDirectService(
      secretKey: key(1),
      relays: [Uri.parse('wss://alice.relay')],
      onMessage: (_) {},
      connector: relays.connect,
    )..start();
    addTearDown(alice.stop);
    expect((await alice.relaysOf(bob.publicKey)).map((uri) => uri.host), [
      'bob.relay',
    ]);
  });

  test('without a relay list, nothing is sent (as NIP-17 asks)', () async {
    final relays = FakeNostrRelays()
      ..relay('wss://alice.relay')
      ..relay('wss://purplepag.es');
    final alice = NostrDirectService(
      secretKey: key(1),
      relays: [Uri.parse('wss://alice.relay')],
      onMessage: (_) {},
      connector: relays.connect,
    )..start();
    addTearDown(alice.stop);
    final stranger = hexEncode(Secp256k1.publicKey(key(5)));
    await expectLater(alice.send([stranger], 'anyone?'), throwsStateError);
    // A private address from a pasted profile is not used either.
    await expectLater(
      alice.relaysOf(
        stranger,
        hints: [
          Uri.parse('wss://192.168.1.1'),
          Uri.parse('ws://plain.example'),
        ],
      ),
      throwsStateError,
    );
  });

  test('nothing stays connected once stopped', () async {
    final relays = FakeNostrRelays()
      ..relay('wss://alice.relay')
      ..relay('wss://purplepag.es')
      ..relay('wss://bob.relay');
    final bob = NostrDirectService(
      secretKey: key(2),
      relays: [Uri.parse('wss://bob.relay')],
      onMessage: (_) {},
      connector: relays.connect,
      indexers: const [],
    )..start();
    final alice = NostrDirectService(
      secretKey: key(1),
      relays: [Uri.parse('wss://alice.relay')],
      onMessage: (_) {},
      connector: relays.connect,
    )..start();
    // Stopped while a send is still looking up where to write.
    final sending = alice.send(
      [bob.publicKey],
      'late',
      hints: {
        bob.publicKey: [Uri.parse('wss://bob.relay')],
      },
    );
    await alice.stop();
    await bob.stop();
    await expectLater(sending, throwsStateError);
    await until(() => relays.openConnections == 0);
    expect(relays.openConnections, 0);
  });

  test('a group message goes to nobody if someone cannot be reached', () async {
    final relays = FakeNostrRelays();
    for (final url in [
      'wss://alice.relay',
      'wss://bob.relay',
      'wss://purplepag.es',
    ]) {
      relays.relay(url);
    }
    final bobGot = <NostrDirectMessage>[];
    final bob = NostrDirectService(
      secretKey: key(2),
      relays: [Uri.parse('wss://bob.relay')],
      onMessage: bobGot.add,
      connector: relays.connect,
    )..start();
    addTearDown(bob.stop);
    final aliceGot = <NostrDirectMessage>[];
    final alice = NostrDirectService(
      secretKey: key(1),
      relays: [Uri.parse('wss://alice.relay')],
      onMessage: aliceGot.add,
      connector: relays.connect,
    )..start();
    addTearDown(alice.stop);
    await until(() => relays.relay('wss://purplepag.es').stored.length == 2);
    final nobody = hexEncode(Secp256k1.publicKey(key(5)));
    await expectLater(
      alice.send([bob.publicKey, nobody], 'all or nothing'),
      throwsStateError,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Bob got nothing (a retry would not be a duplicate), and nothing
    // shows as sent.
    expect(bobGot, isEmpty);
    expect(aliceGot, isEmpty);
  });

  test('someone\'s relay list cannot point into this network', () async {
    final relays = FakeNostrRelays()
      ..relay('wss://alice.relay')
      ..relay('wss://purplepag.es');
    final alice = NostrDirectService(
      secretKey: key(1),
      relays: [Uri.parse('wss://alice.relay')],
      onMessage: (_) {},
      connector: relays.connect,
    )..start();
    addTearDown(alice.stop);
    final mallory = key(6);
    relays
        .relay('wss://purplepag.es')
        .inject(
          Nip17.dmRelayList(mallory, [
            Uri.parse('wss://192.168.1.1'),
            Uri.parse('wss://router.local'),
          ], DateTime.now()),
        );
    await expectLater(
      alice.relaysOf(hexEncode(Secp256k1.publicKey(mallory))),
      throwsStateError,
    );
  });

  test('a flood of junk does not lose a real message', () async {
    final relays = FakeNostrRelays()..relay('wss://alice.relay');
    var clock = DateTime.utc(2026, 10, 8, 12, 0, 58);
    final got = <NostrDirectMessage>[];
    final alice = NostrDirectService(
      secretKey: key(1),
      relays: [Uri.parse('wss://alice.relay')],
      onMessage: got.add,
      connector: relays.connect,
      indexers: const [],
      now: () => clock,
    )..start();
    addTearDown(alice.stop);
    await until(() => alice.reading);
    final relay = relays.relay('wss://alice.relay');
    // More junk than a minute's budget, then a real message.
    for (var i = 0; i < 650; i++) {
      relay.inject(
        NostrEvent.sign(
          secretKey: key(100 + i % 50),
          kind: NostrKind.giftWrap,
          tags: [
            ['p', alice.publicKey],
          ],
          content: 'junk $i',
          createdAt: clock.millisecondsSinceEpoch ~/ 1000 - i,
        ),
      );
    }
    final (_, real) = Nip17.wrap(
      secretKey: key(2),
      recipients: [alice.publicKey],
      content: 'still here',
      now: clock,
    ).firstWhere((entry) => entry.$1 == alice.publicKey);
    relay.inject(real);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(got, isEmpty);
    // The next minute it is read.
    clock = clock.add(const Duration(minutes: 1));
    await until(() => got.isNotEmpty);
    expect(got.single.content, 'still here');
  });
}
