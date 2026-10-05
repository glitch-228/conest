import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/nostr/secp256k1.dart' show hexEncode;
import 'package:conest/src/reticulum/endpoint.dart';
import 'package:conest/src/reticulum/framing.dart';
import 'package:conest/src/reticulum/identity.dart';
import 'package:conest/src/reticulum/packet.dart';
import 'package:conest/src/reticulum/tcp_interface.dart';
import 'package:conest/src/reticulum_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_rns_bus.dart';

void main() {
  group('framing', () {
    final payload = Uint8List.fromList([
      0x7e, 0x7d, 0xc0, 0xdb, 1, 2, 0x7e, 0xdc, 0xdd, //
    ]);

    test('HDLC frames round-trip across arbitrary splits', () {
      final stream = [
        ...HdlcFraming.frame(payload),
        ...HdlcFraming.frame([9, 9]),
      ];
      for (var split = 0; split <= stream.length; split++) {
        final deframer = HdlcDeframer();
        final frames = [
          ...deframer.add(stream.sublist(0, split)),
          ...deframer.add(stream.sublist(split)),
        ];
        expect(frames, [
          payload,
          Uint8List.fromList([9, 9]),
        ]);
      }
    });

    test('KISS frames round-trip with their command', () {
      final deframer = KissDeframer();
      final frames = deframer.add([
        ...KissFraming.frame(KissFraming.cmdData, payload),
        ...KissFraming.frame(0x05, [1]),
      ]);
      expect(frames.first.$1, KissFraming.cmdData);
      expect(frames.first.$2, payload);
      expect(frames.last.$1, 0x05);
    });

    test('oversized frames are dropped', () {
      final deframer = HdlcDeframer(maxFrame: 4);
      expect(
        deframer.add([
          ...HdlcFraming.frame([1, 2, 3, 4, 5]),
          ...HdlcFraming.frame([7]),
        ]),
        [
          Uint8List.fromList([7]),
        ],
      );
    });
  });

  group('packets and identities', () {
    test('packets round-trip, with and without a transport id', () {
      final destination = Uint8List.fromList(List.filled(16, 3));
      for (final transport in [null, Uint8List.fromList(List.filled(16, 9))]) {
        final packet = RnsPacket(
          packetType: RnsPacketType.data,
          destinationType: RnsDestinationType.single,
          destinationHash: destination,
          data: Uint8List.fromList([1, 2, 3]),
          transportId: transport,
          hops: 2,
        );
        final parsed = RnsPacket.unpack(packet.pack())!;
        expect(parsed.destinationHash, destination);
        expect(parsed.transportId, transport);
        expect(parsed.data, [1, 2, 3]);
        expect(parsed.hops, 2);
        // The hash ignores hops and transport id, as Reticulum's does.
        expect(
          parsed.hash,
          RnsPacket.unpack(
            RnsPacket(
              packetType: RnsPacketType.data,
              destinationType: RnsDestinationType.single,
              destinationHash: destination,
              data: Uint8List.fromList([1, 2, 3]),
            ).pack(),
          )!.hash,
        );
      }
      expect(RnsPacket.unpack(Uint8List(5)), isNull);
    });

    test('encryption round-trips and fails closed', () async {
      final alice = await RnsIdentity.generate();
      final bob = await RnsIdentity.generate();
      final box = await bob.encrypt([1, 2, 3]);
      expect(await bob.decrypt(box), [1, 2, 3]);
      expect(await alice.decrypt(box), isNull);
      box[box.length - 40] ^= 1;
      expect(await bob.decrypt(box), isNull);
      final restored = await RnsIdentity.fromPrivateKey(await bob.privateKey());
      expect(restored.publicKey, bob.publicKey);
    });

    test('announces validate, and a forged one does not', () async {
      final identity = await RnsIdentity.generate();
      final name = rnsNameHash('conest', ['carrier']);
      final packet = await RnsAnnounce.build(
        identity,
        name,
        appData: [7],
        timeSeconds: 1700000000,
      );
      final announce = (await RnsAnnounce.validate(packet))!;
      expect(announce.identity.publicKey, identity.publicKey);
      expect(announce.appData, [7]);
      final forged = RnsPacket(
        packetType: packet.packetType,
        destinationType: packet.destinationType,
        destinationHash: packet.destinationHash,
        data: Uint8List.fromList(packet.data)..[packet.data.length - 1] ^= 1,
      );
      expect(await RnsAnnounce.validate(forged), isNull);
    });
  });

  group('endpoints on a shared medium', () {
    test('learn each other from announces and exchange data', () async {
      final bus = FakeRnsBus();
      final aliceGot = <Uint8List>[];
      final bobGot = <Uint8List>[];
      final alice = RnsEndpoint(
        identity: await RnsIdentity.generate(),
        nameHash: rnsNameHash('conest', const ['carrier']),
        interface: bus.attach(),
        onData: aliceGot.add,
      );
      final bob = RnsEndpoint(
        identity: await RnsIdentity.generate(),
        nameHash: rnsNameHash('conest', const ['carrier']),
        interface: bus.attach(),
        onData: bobGot.add,
      );
      // Announces of destinations nobody asked for are not even checked.
      await bob.announce();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alice.pathTo(bob.destinationHash), isNull);
      alice.watch(bob.destinationHash);
      await bob.announce();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alice.pathTo(bob.destinationHash)?.hops, 1);
      await alice.sendTo(bob.identity, [5, 6]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bobGot.single, [5, 6]);
      expect(aliceGot, isEmpty);
      // The same packet again (a rebroadcast) is delivered once.
      bus.attach().send(bus.sent.last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bobGot, hasLength(1));
    });
  });

  group('endpoint behaviour', () {
    Future<(FakeRnsBus, RnsEndpoint, RnsEndpoint)> pair() async {
      final bus = FakeRnsBus();
      final name = rnsNameHash('conest', const ['carrier']);
      final a = RnsEndpoint(
        identity: await RnsIdentity.generate(),
        nameHash: name,
        interface: bus.attach(),
      );
      final b = RnsEndpoint(
        identity: await RnsIdentity.generate(),
        nameHash: name,
        interface: bus.attach(),
      );
      return (bus, a, b);
    }

    test('a path request is answered by the destination itself', () async {
      final (_, alice, bob) = await pair();
      expect(
        await alice.requestPath(
          bob.destinationHash,
          timeout: const Duration(seconds: 2),
        ),
        isTrue,
      );
      // A repeated answer (the same announce) still restores a path.
      expect(
        await alice.requestPath(
          bob.destinationHash,
          timeout: const Duration(seconds: 2),
        ),
        isTrue,
      );
    });

    test('an older announce does not replace a fresher path', () async {
      final bus = FakeRnsBus();
      final name = rnsNameHash('conest', const ['carrier']);
      final bobIdentity = await RnsIdentity.generate();
      final alice = RnsEndpoint(
        identity: await RnsIdentity.generate(),
        nameHash: name,
        interface: bus.attach(),
      );
      final injector = bus.attach();
      final destination = rnsDestinationHash(name, bobIdentity.hash);
      alice.watch(destination);
      final fresh = await RnsAnnounce.build(
        bobIdentity,
        name,
        timeSeconds: 2000000000,
      );
      final stale = await RnsAnnounce.build(
        bobIdentity,
        name,
        timeSeconds: 1000000000,
      );
      await injector.send(fresh.pack());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final relayed = RnsPacket(
        packetType: stale.packetType,
        destinationType: stale.destinationType,
        destinationHash: stale.destinationHash,
        data: stale.data,
        hops: 3,
        transportId: Uint8List.fromList(List.filled(16, 7)),
      );
      await injector.send(relayed.pack());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alice.pathTo(destination)?.hops, 1);
      expect(alice.pathTo(destination)?.emittedAt, 2000000000);
    });

    test('overlapping sends on a TCP link all arrive', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final frames = <Uint8List>[];
      final deframer = HdlcDeframer();
      server.listen(
        (socket) =>
            socket.listen((bytes) => frames.addAll(deframer.add(bytes))),
      );
      final link = await RnsTcpInterface.connect('127.0.0.1', server.port);
      addTearDown(link.close);
      await Future.wait([
        for (var index = 0; index < 50; index++)
          link.send(Uint8List.fromList([index, 1, 2, 3])),
      ]);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (frames.length < 50 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(frames.map((frame) => frame.first), List.generate(50, (i) => i));
    });

    test('local and internet hosts are told apart', () {
      for (final host in [
        'localhost',
        '127.0.0.1',
        '192.168.1.5',
        '10.0.0.2',
        '172.20.1.1',
        'node.local',
        'fd00::1',
        'fe80::1',
      ]) {
        expect(isLocalNetworkHost(host), isTrue, reason: host);
      }
      for (final host in [
        '8.8.8.8',
        'example.org',
        '172.32.0.1',
        '2001:db8::1',
      ]) {
        expect(isLocalNetworkHost(host), isFalse, reason: host);
      }
    });
  });

  group('carrier channel', () {
    test('frames travel between two channels and name their sender', () async {
      final bus = FakeRnsBus();
      Future<ReticulumCarrierChannel> channel(
        List<(String, Uint8List)> got,
      ) async => ReticulumCarrierChannel.create(
        config: ReticulumCarrierConfig(
          identityKeyHex: hexEncode(
            await (await RnsIdentity.generate()).privateKey(),
          ),
          nameHashHex: ReticulumCarrierConfig.newNameHashHex(),
          host: 'node.test',
          port: 4242,
        ),
        connector: bus.connect,
        onFrame: (sender, frame) => got.add((sender, frame)),
        pathTimeout: const Duration(milliseconds: 300),
      );
      final bobGot = <(String, Uint8List)>[];
      final alice = await channel([]);
      final bob = await channel(bobGot);
      addTearDown(alice.stop);
      addTearDown(bob.stop);
      alice.start();
      bob.start();
      while (alice.state != ReticulumCarrierState.connected ||
          bob.state != ReticulumCarrierState.connected) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final frame = Uint8List.fromList(
        List.generate(reticulumFraming.chunkBytes + 11, (index) => index % 256),
      );
      await alice.sendFrame(bob.localAddress!, frame);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(bobGot.single.$2, frame);
      expect(bobGot.single.$1, alice.localAddress!.split('|').first);
    });

    test('addresses are checked against their key', () async {
      final identity = await RnsIdentity.generate();
      final destination = rnsDestinationHash(
        rnsNameHash('conest', ['carrier']),
        identity.hash,
      );
      final good = ReticulumAddress(
        destination: destination,
        identity: identity,
        nameHash: rnsNameHash('conest', ['carrier']),
      ).encode();
      expect(isValidReticulumAddress(good), isTrue);
      final other = await RnsIdentity.generate();
      expect(
        isValidReticulumAddress(
          '${hexEncode(destination)}|${hexEncode(other.publicKey)}|'
          '${good.split('|').last}',
        ),
        isFalse,
      );
      expect(isValidReticulumAddress(good.toUpperCase()), isFalse);
      // Another name hash names another destination.
      expect(
        isValidReticulumAddress(
          '${good.substring(0, good.lastIndexOf('|'))}|${'0' * 20}',
        ),
        isFalse,
      );
      expect(isValidReticulumAddress('abc|def'), isFalse);
    });
  });
}
