import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/bitchat/fragment.dart';
import 'package:conest/src/bitchat/mesh.dart';
import 'package:conest/src/bitchat/packet.dart';
import 'package:conest/src/bitchat_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ble_mesh.dart';

void main() {
  group('packets', () {
    final sender = Uint8List.fromList(List.generate(8, (i) => i + 1));
    final recipient = Uint8List.fromList(List.filled(8, 0xab));

    test('encode and decode, padded and not, v1 and v2', () {
      for (final version in [1, 2]) {
        final packet = BitchatPacket(
          version: version,
          type: BitchatType.noiseEncrypted,
          senderId: sender,
          recipientId: recipient,
          timestamp: 1759651200123,
          payload: Uint8List.fromList(List.generate(300, (i) => i % 256)),
          route: version == 2 ? [Uint8List.fromList(List.filled(8, 5))] : null,
        );
        for (final pad in [false, true]) {
          final bytes = packet.encode(pad: pad);
          if (pad) expect(bytes.length, 512);
          final back = BitchatPacket.decode(bytes)!;
          expect(back.version, version);
          expect(back.type, BitchatType.noiseEncrypted);
          expect(back.ttl, bitchatDefaultTtl);
          expect(back.timestamp, 1759651200123);
          expect(back.senderId, sender);
          expect(back.recipientId, recipient);
          expect(back.payload, packet.payload);
          expect(back.route?.single, version == 2 ? List.filled(8, 5) : null);
          expect(back.dedupKey, packet.dedupKey);
        }
      }
    });

    test('the header layout is bitchat\'s', () {
      final bytes = BitchatPacket(
        type: BitchatType.message,
        senderId: sender,
        timestamp: 0x0102030405060708,
        payload: Uint8List.fromList([9, 9]),
      ).encode(pad: false);
      expect(bytes.sublist(0, 14), [
        1, 0x02, 7, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 2, //
      ]);
      expect(bytes.sublist(14, 22), sender);
      expect(bytes.sublist(22), [9, 9]);
    });

    test('padding round-trips and stays within a byte', () {
      for (final size in [1, 200, 239, 240, 496, 497, 1100, 2100]) {
        final data = Uint8List.fromList(List.generate(size, (i) => i & 0x7f));
        final padded = bitchatPad(data);
        expect(bitchatUnpad(padded), data, reason: '$size');
      }
    });

    test('malformed input is refused', () {
      expect(BitchatPacket.decode(Uint8List(5)), isNull);
      final bytes = BitchatPacket(
        type: 1,
        senderId: sender,
        timestamp: 1,
        payload: Uint8List(10),
      ).encode(pad: false);
      expect(BitchatPacket.decode(bytes.sublist(0, bytes.length - 3)), isNull);
      expect(
        BitchatPacket.decode(Uint8List.fromList([9, ...bytes.skip(1)])),
        isNull,
      );
    });
  });

  group('fragments', () {
    BitchatPacket big() => BitchatPacket(
      type: BitchatType.noiseEncrypted,
      senderId: Uint8List.fromList(List.filled(8, 1)),
      recipientId: Uint8List.fromList(List.filled(8, 2)),
      timestamp: 1759651200123,
      payload: Uint8List.fromList(List.generate(1500, (i) => i * 13 % 256)),
    );

    test('round-trip at the link sizes iPhones use', () {
      for (final mtu in [23, 185, 512]) {
        final original = big();
        final fragments = bitchatFragmentsFor(
          original,
          chunkBytes: mtu - 3 - bitchatFragmentOverhead,
        );
        expect(fragments.length, greaterThan(1));
        final reassembler = BitchatReassembler();
        Uint8List? whole;
        // Out of order, with a duplicate.
        for (final fragment in [...fragments.reversed, fragments.first]) {
          final decoded = BitchatPacket.decode(fragment.encode())!;
          expect(decoded.type, BitchatType.fragment);
          expect(decoded.recipientId, original.recipientId);
          whole = reassembler.add(decoded) ?? whole;
        }
        expect(whole, original.encode(), reason: 'MTU $mtu');
      }
    });

    test('reassembly is bounded', () {
      final reassembler = BitchatReassembler(maxBytes: 1000);
      final fragments = bitchatFragmentsFor(big(), chunkBytes: 100);
      Uint8List? whole;
      for (final fragment in fragments) {
        whole = reassembler.add(fragment) ?? whole;
      }
      // 1.5 KB does not fit in 1000 bytes.
      expect(whole, isNull);
      // A fragment that claims an impossible index is refused.
      expect(
        BitchatFragment.decode(
          Uint8List.fromList([...List.filled(8, 0), 0, 5, 0, 5, 0x11, 1]),
        ),
        isNull,
      );
    });
  });

  group('mesh', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i * 7));
    final aliceAddress = 'bc1:${'a' * 32}';
    final daveAddress = 'bc1:${'d' * 32}';
    var clock = DateTime.utc(2026, 10, 5, 12, 30);

    BitchatNode relay(FakeBleNeighbourhood area, String name) => BitchatNode(
      links: area.node(name),
      onPrivate: (_, _) => BitchatPrivate.notMine,
      now: () => clock,
    );

    Future<BitchatCarrierChannel> channel(
      FakeBleNeighbourhood area,
      String name,
      String address,
      String peer,
      List<(String, Uint8List)> got, {
      List<Uint8List> extraKeys = const [],
      List<Uint8List> Function()? keys,
    }) async {
      final result = BitchatCarrierChannel(
        config: BitchatCarrierConfig(address: address),
        connector: () async => area.node(name),
        keyFor: (candidate) async => [
          if (candidate == peer) ...?keys?.call(),
          if (candidate == peer && keys == null) ...[key, ...extraKeys],
        ],
        onFrame: (sender, frame) => got.add((sender, frame)),
        now: () => clock,
      )..updatePeers({peer});
      result.start();
      while (result.state != BitchatCarrierState.running) {
        await Future<void>.delayed(Duration.zero);
      }
      return result;
    }

    Uint8List frame([int length = 0]) => Uint8List.fromList(
      List.generate(
        length == 0 ? bitchatCarrierFraming.chunkBytes + 11 : length,
        (i) => i % 256,
      ),
    );

    setUp(() => clock = DateTime.utc(2026, 10, 5, 12, 30));

    test('a frame crosses two relays and arrives once', () async {
      final area = FakeBleNeighbourhood()
        ..connect('a', 'b')
        ..connect('b', 'c')
        ..connect('c', 'd')
        ..connect('b', 'd');
      final aliceGot = <(String, Uint8List)>[];
      final daveGot = <(String, Uint8List)>[];
      final alice = await channel(
        area,
        'a',
        aliceAddress,
        daveAddress,
        aliceGot,
      );
      relay(area, 'b');
      relay(area, 'c');
      await channel(area, 'd', daveAddress, aliceAddress, daveGot);
      final sent = frame();
      await alice.sendFrame(daveAddress, sent);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(daveGot.single.$1, aliceAddress);
      expect(daveGot.single.$2, sent);
      expect(aliceGot, isEmpty);
      // Every packet fits one BLE frame and is a plain bitchat private
      // packet: no marker, and no address on the air.
      expect(area.airtime.every((packet) => packet.length == 512), isTrue);
      final packet = BitchatPacket.decode(area.airtime.first)!;
      expect(packet.type, BitchatType.noiseEncrypted);
      // Signed like bitchat's own private packets (with random bytes).
      expect(packet.signature, hasLength(64));
      final hexIds = [
        packet.senderId,
        packet.recipientId!,
      ].map((id) => id.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
      expect(hexIds.any((id) => aliceAddress.contains(id)), isFalse);
      expect(hexIds.any((id) => daveAddress.contains(id)), isFalse);
    });

    test('ids on the air change every hour and still arrive', () async {
      final area = FakeBleNeighbourhood()..connect('a', 'd');
      final daveGot = <(String, Uint8List)>[];
      final alice = await channel(area, 'a', aliceAddress, daveAddress, []);
      await channel(area, 'd', daveAddress, aliceAddress, daveGot);
      await alice.sendFrame(daveAddress, frame(20));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      clock = clock.add(const Duration(hours: 1));
      await alice.sendFrame(daveAddress, frame(21));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(daveGot, hasLength(2));
      final first = BitchatPacket.decode(area.airtime[0])!;
      final second = BitchatPacket.decode(area.airtime[1])!;
      expect(first.senderId, isNot(second.senderId));
      expect(first.recipientId, isNot(second.recipientId));
    });

    test('tampered, replayed or stale packets are dropped', () async {
      // Mallory sits between Alice and Dave and forwards by hand.
      final area = FakeBleNeighbourhood()
        ..connect('a', 'm')
        ..connect('m', 'd');
      final daveGot = <(String, Uint8List)>[];
      final alice = await channel(area, 'a', aliceAddress, daveAddress, []);
      await channel(area, 'd', daveAddress, aliceAddress, daveGot);
      final captured = <Uint8List>[];
      final mallory = area.node('m');
      mallory.received.listen((event) => captured.add(event.$2));
      Future<void> forward(Uint8List bytes) async {
        await mallory.broadcast(bytes, except: 'a');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await alice.sendFrame(daveAddress, frame(40));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final original = BitchatPacket.decode(captured.single)!;
      await forward(captured.single);
      expect(daveGot, hasLength(1));

      BitchatPacket altered({Uint8List? payload, int? timestamp}) =>
          BitchatPacket(
            type: original.type,
            senderId: original.senderId,
            recipientId: original.recipientId,
            timestamp: timestamp ?? original.timestamp,
            payload: payload ?? original.payload,
          );
      // The frame header, a byte of data, the time; then a plain replay.
      await forward(
        altered(
          payload: Uint8List.fromList(original.payload)..[0] ^= 1,
        ).encode(),
      );
      await forward(
        altered(
          payload: Uint8List.fromList(original.payload)..[20] ^= 1,
        ).encode(),
      );
      await forward(altered(timestamp: original.timestamp + 1).encode());
      await forward(captured.single);
      expect(daveGot, hasLength(1));

      // Sent with a clock 30 minutes ahead: outside the window, unread.
      clock = clock.add(const Duration(minutes: 30));
      await alice.sendFrame(daveAddress, frame(41));
      clock = clock.subtract(const Duration(minutes: 30));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await forward(captured.last);
      expect(daveGot, hasLength(1));
    });

    test('compressed packets from bitchat relays are expanded', () async {
      final area = FakeBleNeighbourhood()
        ..connect('a', 'm')
        ..connect('m', 'd');
      final daveGot = <(String, Uint8List)>[];
      final alice = await channel(area, 'a', aliceAddress, daveAddress, []);
      await channel(area, 'd', daveAddress, aliceAddress, daveGot);
      final captured = <Uint8List>[];
      area.node('m').received.listen((event) => captured.add(event.$2));
      final sent = Uint8List(200);
      await alice.sendFrame(daveAddress, sent);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final original = BitchatPacket.decode(captured.single)!;
      // bitchat's compressed form: the original size, then raw deflate.
      final size = original.payload.length;
      final bytes = BitchatPacket(
        type: original.type,
        senderId: original.senderId,
        recipientId: original.recipientId,
        timestamp: original.timestamp,
        payload: Uint8List.fromList([
          size >> 8,
          size & 0xff,
          ...ZLibEncoder(raw: true).convert(original.payload),
        ]),
      ).encode(pad: false);
      bytes[11] |= 0x04; // the compressed flag
      await area.node('m').broadcast(bytes, except: 'a');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(daveGot.single.$2, sent);
    });

    test(
      'relays clamp TTL and drop unknown, stale and flooding packets',
      () async {
        final area = FakeBleNeighbourhood()
          ..connect('x', 'r')
          ..connect('r', 'y');
        relay(area, 'r');
        final forwarded = <Uint8List>[];
        area.node('y').received.listen((event) => forwarded.add(event.$2));
        Future<void> send(BitchatPacket packet) async {
          await area.node('x').broadcast(packet.encode());
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        final sender = Uint8List.fromList(List.filled(8, 3));
        var serial = 0;
        BitchatPacket packet({int type = 0x02, int ttl = 7, DateTime? at}) =>
            BitchatPacket(
              type: type,
              ttl: ttl,
              senderId: sender,
              timestamp: (at ?? clock).millisecondsSinceEpoch,
              payload: Uint8List.fromList([serial++]),
            );
        await send(packet(ttl: 200));
        expect(BitchatPacket.decode(forwarded.single)!.ttl, 6);
        await send(packet(type: 0x7f));
        await send(packet(at: clock.subtract(const Duration(hours: 1))));
        expect(forwarded, hasLength(1));
        for (var i = 0; i < 250; i++) {
          await area.node('x').broadcast(packet().encode());
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // One neighbour gets at most 200 relays a minute.
        expect(forwarded, hasLength(200));
      },
    );

    test(
      'a TTL-0 or re-encoded copy cannot suppress or repeat a frame',
      () async {
        final area = FakeBleNeighbourhood()
          ..connect('a', 'm')
          ..connect('m', 'r')
          ..connect('r', 'd');
        final daveGot = <(String, Uint8List)>[];
        final alice = await channel(area, 'a', aliceAddress, daveAddress, []);
        relay(area, 'r');
        await channel(area, 'd', daveAddress, aliceAddress, daveGot);
        final captured = <Uint8List>[];
        final mallory = area.node('m');
        mallory.received.listen((event) => captured.add(event.$2));
        await alice.sendFrame(daveAddress, frame(30));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // Mallory first sends a copy that goes no further, then the original:
        // the relay must still pass the original on.
        final dead = Uint8List.fromList(captured.single)..[2] = 0;
        await mallory.broadcast(dead, except: 'a');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await mallory.broadcast(captured.single, except: 'a');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(daveGot, hasLength(1));
        // The same packet as version 2 has another dedup key but the same
        // MAC: read once only.
        final original = BitchatPacket.decode(captured.single)!;
        await mallory.broadcast(
          BitchatPacket(
            version: 2,
            type: original.type,
            senderId: original.senderId,
            recipientId: original.recipientId,
            timestamp: original.timestamp,
            payload: original.payload,
            signature: original.signature,
          ).encode(),
          except: 'a',
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(daveGot, hasLength(1));
      },
    );

    test('a compressed packet cannot expand past its stated size', () async {
      final area = FakeBleNeighbourhood()..connect('m', 'd');
      final daveGot = <(String, Uint8List)>[];
      await channel(area, 'd', daveAddress, aliceAddress, daveGot);
      final bytes = BitchatPacket(
        type: BitchatType.noiseEncrypted,
        senderId: Uint8List(8),
        recipientId: Uint8List(8),
        timestamp: clock.millisecondsSinceEpoch,
        payload: Uint8List.fromList([
          0,
          100,
          ...ZLibEncoder(raw: true).convert(Uint8List(4 << 20)),
        ]),
      ).encode(pad: false);
      bytes[11] |= 0x04;
      bitchatInflatedBytes = -1;
      await area.node('m').broadcast(bytes);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(daveGot, isEmpty);
      // Inflating ran and stopped near the stated 100 bytes, not at 4 MiB.
      expect(bitchatInflatedBytes, inInclusiveRange(0, 100));
    });

    test('contacts sharing an address both still get through', () async {
      // Carol claims Dave's address; Alice has both as contacts.
      final area = FakeBleNeighbourhood()
        ..connect('a', 'd')
        ..connect('a', 'c');
      final daveGot = <(String, Uint8List)>[];
      final carolGot = <(String, Uint8List)>[];
      final aliceGot = <(String, Uint8List)>[];
      final carolKey = Uint8List.fromList(List.filled(32, 9));
      final alice = await channel(
        area,
        'a',
        aliceAddress,
        daveAddress,
        aliceGot,
        extraKeys: [carolKey],
      );
      final dave = await channel(area, 'd', daveAddress, aliceAddress, daveGot);
      final carol = await channel(
        area,
        'c',
        daveAddress,
        aliceAddress,
        carolGot,
        keys: () => [carolKey],
      );
      await alice.sendFrame(daveAddress, frame(12));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Each reads only the copy sealed with its own pair key.
      expect(daveGot, hasLength(1));
      expect(carolGot, hasLength(1));
      await dave.sendFrame(aliceAddress, frame(13));
      await carol.sendFrame(aliceAddress, frame(14));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(aliceGot.map((got) => got.$2.length), unorderedEquals([13, 14]));
    });

    test('a contact\'s new key is picked up on the next peer update', () async {
      final area = FakeBleNeighbourhood()..connect('a', 'd');
      final daveGot = <(String, Uint8List)>[];
      var daveKey = key;
      final alice = await channel(area, 'a', aliceAddress, daveAddress, []);
      final dave = await channel(
        area,
        'd',
        daveAddress,
        aliceAddress,
        daveGot,
        keys: () => [daveKey],
      );
      await alice.sendFrame(daveAddress, frame(10));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(daveGot, hasLength(1));
      // Alice re-keys (same address): Dave's old key no longer matches
      // until his peers update, with the same address set.
      final newKey = Uint8List.fromList(List.filled(32, 77));
      final aliceRekeyed = await channel(
        area,
        'a',
        aliceAddress,
        daveAddress,
        [],
        keys: () => [newKey],
      );
      await aliceRekeyed.sendFrame(daveAddress, frame(11));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(daveGot, hasLength(1));
      daveKey = newKey;
      dave.updatePeers({aliceAddress});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await aliceRekeyed.sendFrame(daveAddress, frame(12));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(daveGot.map((got) => got.$2.length), [10, 12]);
    });

    test('problems and missing neighbours reach the carrier', () async {
      final area = FakeBleNeighbourhood();
      final alone = await channel(area, 'a', aliceAddress, daveAddress, []);
      await expectLater(
        alone.sendFrame(daveAddress, frame(5)),
        throwsStateError,
      );
      area.node('a').problemReports.add('Bluetooth is off.');
      await Future<void>.delayed(Duration.zero);
      expect(alone.lastError, 'Bluetooth is off.');
      area.node('a').problemReports.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(alone.lastError, isNull);
    });

    test('a frame split by an iPhone into small fragments is read', () async {
      final area = FakeBleNeighbourhood()
        ..connect('a', 'i')
        ..connect('i', 'd');
      final daveGot = <(String, Uint8List)>[];
      final alice = await channel(area, 'a', aliceAddress, daveAddress, []);
      await channel(area, 'd', daveAddress, aliceAddress, daveGot);
      final captured = <Uint8List>[];
      final iphone = area.node('i');
      iphone.received.listen((event) => captured.add(event.$2));
      final sent = frame();
      await alice.sendFrame(daveAddress, sent);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The iPhone's link to Dave carries 185-byte writes: it forwards the
      // packet as fragments.
      final original = BitchatPacket.decode(captured.single)!;
      for (final fragment in bitchatFragmentsFor(
        original,
        chunkBytes: 185 - 3 - bitchatFragmentOverhead,
      )) {
        await iphone.broadcast(fragment.encode(), except: 'a');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(daveGot.single.$2, sent);
    });

    test('TTL limits how far a packet travels', () async {
      final area = FakeBleNeighbourhood();
      final names = List.generate(10, (i) => 'n$i');
      for (var i = 0; i + 1 < names.length; i++) {
        area.connect(names[i], names[i + 1]);
      }
      final got = <(String, Uint8List)>[];
      final first = await channel(
        area,
        names.first,
        aliceAddress,
        daveAddress,
        [],
      );
      for (final name in names.sublist(1, names.length - 1)) {
        relay(area, name);
      }
      await channel(area, names.last, daveAddress, aliceAddress, got);
      await first.sendFrame(daveAddress, frame(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Nine hops away: beyond the 7-hop TTL.
      expect(got, isEmpty);
    });
  });
}
