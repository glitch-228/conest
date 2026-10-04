import 'dart:typed_data';

import 'package:conest/src/nostr/event.dart';
import 'package:conest/src/nostr/secp256k1.dart';
import 'package:conest/src/nostr_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_nostr_relay.dart';

void main() {
  late FakeNostrRelays relays;
  final channels = <NostrCarrierChannel>[];

  setUp(() {
    relays = FakeNostrRelays();
    channels.clear();
  });
  tearDown(() async {
    for (final channel in channels) {
      await channel.stop();
    }
  });

  NostrCarrierChannel channel(
    List<String> urls,
    List<(String, Uint8List)> received, {
    Uint8List? secretKey,
    void Function(int)? onCursor,
  }) {
    final result = NostrCarrierChannel(
      secretKey: secretKey ?? Secp256k1.generateSecretKey(),
      relays: urls.map(Uri.parse).toList(),
      connector: relays.connect,
      onFrame: (sender, frame) => received.add((sender, frame)),
      onCursor: onCursor,
    );
    channels.add(result);
    return result;
  }

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  final frame = Uint8List.fromList(List<int>.generate(3000, (i) => i % 7));

  test(
    'a frame reaches the recipient, hiding the sender from relays',
    () async {
      final relayA = relays.relay('wss://a.test');
      relays.relay('wss://b.test');
      final aliceGot = <(String, Uint8List)>[];
      final bobGot = <(String, Uint8List)>[];
      final alice = channel(['wss://a.test'], aliceGot)..start();
      final bob = channel(['wss://b.test'], bobGot)..start();

      await alice.sendFrame(bob.localAddress!, frame);
      await until(() => bobGot.isNotEmpty);
      expect(bobGot.single.$1, alice.publicKey);
      expect(bobGot.single.$2, frame);

      final event = relays.relay('wss://b.test').stored.single;
      expect(event.kind, NostrKind.giftWrap);
      expect(event.tag('p'), bob.publicKey);
      expect(event.pubkey, isNot(alice.publicKey));
      expect(event.content, isNot(contains(alice.publicKey)));
      expect(
        int.parse(event.tag('expiration')!) - event.createdAt,
        nostrCarrierExpiry.inSeconds,
      );
      expect(relayA.stored, isEmpty, reason: 'published to Bob\'s relays only');
    },
  );

  test('frames stored while the recipient was away arrive once', () async {
    relays.relay('wss://one.test');
    relays.relay('wss://two.test');
    final bobKey = Secp256k1.generateSecretKey();
    final address = NostrAddress(
      publicKey: hexEncode(Secp256k1.publicKey(bobKey)),
      relays: [Uri.parse('wss://one.test'), Uri.parse('wss://two.test')],
    ).encode();
    final alice = channel(['wss://one.test'], [])..start();
    await alice.sendFrame(address, frame);
    expect(relays.relay('wss://one.test').stored, hasLength(1));
    expect(relays.relay('wss://two.test').stored, hasLength(1));

    final bobGot = <(String, Uint8List)>[];
    channel(
      ['wss://one.test', 'wss://two.test'],
      bobGot,
      secretKey: bobKey,
    ).start();
    await until(() => bobGot.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(bobGot, hasLength(1));
  });

  test(
    'inbox relays that require authentication are read after AUTH',
    () async {
      relays.relay('wss://inbox.test', requireAuth: true);
      final bobGot = <(String, Uint8List)>[];
      final bob = channel(['wss://inbox.test'], bobGot)..start();
      final alice = channel(['wss://inbox.test'], [])..start();
      await alice.sendFrame(bob.localAddress!, frame);
      await until(() => bobGot.isNotEmpty);
      expect(bobGot.single.$2, frame);
    },
  );

  test('reading resumes after the relay drops the connection', () async {
    final relay = relays.relay('wss://flaky.test');
    final bobGot = <(String, Uint8List)>[];
    final bob = channel(['wss://flaky.test'], bobGot)..start();
    final alice = channel(['wss://flaky.test'], [])..start();
    await alice.sendFrame(bob.localAddress!, frame);
    await until(() => bobGot.length == 1);
    await relay.dropConnections();
    await alice.sendFrame(bob.localAddress!, Uint8List.fromList([1, 2, 3]));
    await until(() => bobGot.length == 2);
    expect(bobGot.last.$2, [1, 2, 3]);
  });

  test('sending fails only when no relay stores the frame', () async {
    relays.relay('wss://good.test');
    relays.relay('wss://bad.test').rejectWith = 'blocked: no';
    final bob = channel(['wss://good.test', 'wss://bad.test'], []);
    final alice = channel(['wss://good.test'], [])..start();
    await alice.sendFrame(bob.localAddress!, frame);
    relays.relay('wss://good.test').rejectWith = 'rate-limited: slow down';
    await expectLater(
      alice.sendFrame(bob.localAddress!, frame),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('slow down'),
        ),
      ),
    );
  });

  test(
    'events that do not decrypt or are not addressed here are ignored',
    () async {
      final relay = relays.relay('wss://r.test');
      final bobGot = <(String, Uint8List)>[];
      final bob = channel(['wss://r.test'], bobGot)..start();
      await until(() => bob.relayStates.values.single.$1.name == 'connected');
      final stranger = Secp256k1.generateSecretKey();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (final event in [
        NostrEvent.sign(
          secretKey: stranger,
          kind: NostrKind.giftWrap,
          tags: [
            ['p', bob.publicKey],
          ],
          content: 'not nip44',
          createdAt: now,
        ),
        NostrEvent.sign(
          secretKey: stranger,
          kind: NostrKind.giftWrap,
          tags: [
            ['p', hexEncode(Secp256k1.publicKey(stranger))],
          ],
          content: 'x',
          createdAt: now,
        ),
      ]) {
        relay.stored.add(event);
      }
      await relay.dropConnections();
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(bobGot, isEmpty);
    },
  );

  test('the read position advances with received events', () async {
    relays.relay('wss://r.test');
    final cursors = <int>[];
    final bob = channel(['wss://r.test'], [], onCursor: cursors.add)..start();
    final alice = channel(['wss://r.test'], [])..start();
    final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await alice.sendFrame(bob.localAddress!, frame);
    await until(() => cursors.isNotEmpty);
    expect(cursors.last, greaterThan(before));
  });

  test('publishing never signs in with the carrier key', () async {
    final inbox = relays.relay('wss://inbox.test', requireAuth: true);
    relays.relay('wss://alice.test');
    final bobGot = <(String, Uint8List)>[];
    final bob = channel(['wss://inbox.test'], bobGot)..start();
    final alice = channel(['wss://alice.test'], [])..start();
    await alice.sendFrame(bob.localAddress!, frame);
    await until(() => bobGot.isNotEmpty);
    expect(inbox.authedPubkeys, contains(bob.publicKey));
    expect(inbox.authedPubkeys, isNot(contains(alice.publicKey)));
  });

  test('a stopped channel sends nothing', () async {
    relays.relay('wss://r.test');
    final bob = channel(['wss://r.test'], []);
    final alice = channel(['wss://r.test'], [])..start();
    await alice.stop();
    await expectLater(
      alice.sendFrame(bob.localAddress!, frame),
      throwsStateError,
    );
    expect(relays.relay('wss://r.test').stored, isEmpty);
  });

  test('hex is decoded strictly', () {
    expect(hexDecode('-1'), isNull);
    expect(hexDecode('+f'), isNull);
    expect(hexDecode('0aFf'), [0x0a, 0xff]);
  });

  group('addresses', () {
    final key = hexEncode(Secp256k1.publicKey(Secp256k1.generateSecretKey()));

    test('valid forms', () {
      for (final address in [
        '$key|wss://relay.example',
        '$key|wss://a.example,wss://b.example:444/path',
      ]) {
        expect(isValidNostrAddress(address), isTrue, reason: address);
      }
      // A contact cannot point Conest at services on this machine.
      for (final address in [
        '$key|ws://localhost:7777',
        '$key|ws://127.0.0.1:7777',
        '$key|wss://localhost',
      ]) {
        expect(isValidNostrAddress(address), isFalse, reason: address);
        expect(
          NostrAddress.tryParse(address, allowLoopback: true),
          isNotNull,
          reason: address,
        );
      }
      final parsed = NostrAddress.tryParse('$key|wss://a.example')!;
      expect(parsed.encode(), '$key|wss://a.example');
    });

    test('invalid forms', () {
      for (final address in [
        'wss://relay.example',
        '$key|',
        '$key|https://relay.example',
        '$key|ws://relay.example',
        '${key.toUpperCase()}|wss://relay.example',
        '${'0' * 64}|wss://relay.example',
        '$key|wss://a,wss://b,wss://c,wss://d,wss://e',
        '$key|wss://user@relay.example',
        '${'+f' * 32}|wss://relay.example',
      ]) {
        expect(isValidNostrAddress(address), isFalse, reason: address);
      }
    });
  });

  test('saved configuration round-trips and drops bad relays', () {
    final config = NostrCarrierConfig.fromJson({
      'secretKey': hexEncode(Secp256k1.generateSecretKey()),
      'relays': ['wss://ok.example', 'http://bad.example', 3],
      'since': 42,
    })!;
    expect(config.relays, ['wss://ok.example']);
    expect(config.since, 42);
    expect(NostrCarrierConfig.fromJson({'secretKey': 'zz'}), isNull);
    expect(config.toString(), isNot(contains(config.secretKeyHex)));
  });
}
