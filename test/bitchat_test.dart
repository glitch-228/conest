import 'dart:typed_data';

import 'package:conest/src/bitchat/mesh.dart';
import 'package:conest/src/bitchat/packet.dart';
import 'package:cryptography/cryptography.dart';
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

  group('mesh', () {
    Future<BitchatNode> node(
      FakeBleNeighbourhood area,
      String name,
      List<(String, Uint8List)> got,
    ) async {
      final (noise, signing) = newBitchatSeeds();
      return BitchatNode(
        identity: await BitchatIdentity.fromSeeds(noise, signing),
        nickname: 'anon',
        links: area.node(name),
        onFrame: (sender, frame) => got.add((sender, frame)),
      );
    }

    test('a frame crosses two relays and arrives once', () async {
      final area = FakeBleNeighbourhood()
        ..connect('a', 'b')
        ..connect('b', 'c')
        ..connect('c', 'd')
        ..connect('b', 'd');
      final aliceGot = <(String, Uint8List)>[];
      final daveGot = <(String, Uint8List)>[];
      final alice = await node(area, 'a', aliceGot);
      await node(area, 'b', []);
      await node(area, 'c', []);
      final dave = await node(area, 'd', daveGot);
      final frame = Uint8List.fromList(
        List.generate(bitchatFrameBytes, (i) => i % 256),
      );
      await alice.sendFrame(dave.peerIdHex, frame);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(daveGot.single.$1, alice.peerIdHex);
      expect(daveGot.single.$2, frame);
      expect(aliceGot, isEmpty);
      // Every packet fits one BLE frame.
      expect(area.airtime.every((packet) => packet.length <= 512), isTrue);
    });

    test('TTL limits how far a packet travels', () async {
      final area = FakeBleNeighbourhood();
      final names = List.generate(10, (i) => 'n$i');
      for (var i = 0; i + 1 < names.length; i++) {
        area.connect(names[i], names[i + 1]);
      }
      final got = <(String, Uint8List)>[];
      final first = await node(area, names.first, []);
      for (final name in names.sublist(1, names.length - 1)) {
        await node(area, name, []);
      }
      final last = await node(area, names.last, got);
      await first.sendFrame(last.peerIdHex, Uint8List.fromList([1]));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Nine hops away: beyond the 7-hop TTL.
      expect(got, isEmpty);
    });

    test('announces are signed the way bitchat checks them', () async {
      final area = FakeBleNeighbourhood()..connect('a', 'b');
      final alice = await node(area, 'a', []);
      final heard = <Uint8List>[];
      area.node('b').received.listen((event) => heard.add(event.$2));
      await alice.announce();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final packet = BitchatPacket.decode(heard.single)!;
      expect(packet.type, BitchatType.announce);
      final announcement = BitchatAnnouncement.decode(packet.payload)!;
      expect(announcement.nickname, 'anon');
      expect(bitchatPeerId(announcement.noisePublicKey), packet.senderId);
      final valid = await Ed25519().verify(
        packet.bytesToSign(),
        signature: Signature(
          packet.signature!,
          publicKey: SimplePublicKey(
            announcement.signingPublicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );
      expect(valid, isTrue);
    });
  });
}
