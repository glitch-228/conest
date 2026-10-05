// Interop with the official Python Reticulum (RNS) when CONEST_RNS_PYTHON
// names a Python that has `rns` installed; the debug workflow sets it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/nostr/secp256k1.dart' show hexDecode, hexEncode;
import 'package:conest/src/reticulum/endpoint.dart';
import 'package:conest/src/reticulum/identity.dart';
import 'package:conest/src/reticulum/packet.dart';
import 'package:conest/src/reticulum/tcp_interface.dart';
import 'package:conest/src/reticulum_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final python = Platform.environment['CONEST_RNS_PYTHON'];
  final skip = python == null ? 'CONEST_RNS_PYTHON is not set' : null;

  test(
    'a Dart endpoint and Python RNS exchange announces and data',
    () async {
      final port = 41000 + Random().nextInt(2000);
      final peer = await Process.start(python!, [
        'test/support/rns_peer.py',
        '$port',
      ]);
      addTearDown(() => peer.kill());
      final lines = StreamController<String>.broadcast();
      peer.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      final stderr = StringBuffer();
      peer.stderr.transform(utf8.decoder).listen(stderr.write);
      Future<String> expectLine(String prefix) => lines.stream
          .firstWhere((line) => line.startsWith(prefix))
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('$prefix\n$stderr'),
          );

      final ready = (await expectLine('READY')).split(' ');
      final pythonIdentity = RnsIdentity.fromPublicKey(hexDecode(ready[1])!)!;
      final pythonDestination = ready[2];

      RnsTcpInterface? link;
      for (var attempt = 0; attempt < 50 && link == null; attempt++) {
        try {
          link = await RnsTcpInterface.connect('127.0.0.1', port);
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      addTearDown(link!.close);
      final announces = <RnsAnnounce>[];
      final received = <Uint8List>[];
      final dart = RnsEndpoint(
        identity: await RnsIdentity.generate(),
        nameHash: rnsNameHash('conest', const ['carrier']),
        interface: link,
        onAnnounce: announces.add,
        onData: received.add,
        acceptAllAnnounces: true,
      );
      addTearDown(dart.close);

      // Python announces; the Dart side validates it and learns the path.
      peer.stdin.writeln('announce');
      await peer.stdin.flush();
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (announces.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(hexEncode(announces.single.destinationHash), pythonDestination);
      expect(announces.single.identity.publicKey, pythonIdentity.publicKey);

      // Dart to Python, encrypted to Python's identity.
      final toPython = Uint8List.fromList(
        List<int>.generate(rnsEncryptedMdu, (index) => index % 256),
      );
      await dart.sendTo(pythonIdentity, toPython);
      expect((await expectLine('DATA')).substring(5), hexEncode(toPython));

      // Dart announces; Python validates it and sends back.
      await dart.announce();
      expect(
        (await expectLine('ANNOUNCE')).substring(9),
        hexEncode(dart.destinationHash),
      );
      peer.stdin.writeln(
        'send ${hexEncode(dart.identity.publicKey)} ${hexEncode([1, 2, 3, 250])}',
      );
      await peer.stdin.flush();
      while (received.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(received.single, [1, 2, 3, 250]);
      peer.stdin.writeln('quit');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'two Dart carriers reach each other through a Python transport node',
    () async {
      final port = 43000 + Random().nextInt(2000);
      final peer = await Process.start(python!, [
        'test/support/rns_peer.py',
        '$port',
      ]);
      addTearDown(() => peer.kill());
      await peer.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line.startsWith('READY'))
          .timeout(const Duration(seconds: 30));
      Future<ReticulumCarrierChannel> channel(
        List<(String, Uint8List)> got,
      ) async => ReticulumCarrierChannel.create(
        config: ReticulumCarrierConfig(
          identityKeyHex: hexEncode(
            await (await RnsIdentity.generate()).privateKey(),
          ),
          nameHashHex: ReticulumCarrierConfig.newNameHashHex(),
          host: '127.0.0.1',
          port: port,
        ),
        onFrame: (sender, frame) => got.add((sender, frame)),
      );
      final aliceGot = <(String, Uint8List)>[];
      final bobGot = <(String, Uint8List)>[];
      final alice = await channel(aliceGot);
      final bob = await channel(bobGot);
      addTearDown(alice.stop);
      addTearDown(bob.stop);
      alice.start();
      bob.start();
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while ((alice.state != ReticulumCarrierState.connected ||
              bob.state != ReticulumCarrierState.connected) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final frame = Uint8List.fromList(List.generate(300, (i) => i % 256));
      await alice.sendFrame(bob.localAddress!, frame);
      while (bobGot.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(bobGot.single.$2, frame);
      await bob.sendFrame(alice.localAddress!, Uint8List.fromList([4, 2]));
      while (aliceGot.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(aliceGot.single.$2, [4, 2]);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
