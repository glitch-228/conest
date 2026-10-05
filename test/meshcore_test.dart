import 'dart:typed_data';

import 'package:conest/src/meshcore/companion.dart';
import 'package:conest/src/meshcore_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_meshcore.dart';

void main() {
  test('frames survive splits and junk', () {
    final stream = [
      1,
      2,
      3,
      MeshCoreFraming.fromRadio,
      2,
      0,
      9,
      8,
      MeshCoreFraming.fromRadio,
      1,
      0,
      7,
    ];
    for (var split = 0; split <= stream.length; split++) {
      final deframer = MeshCoreDeframer();
      expect(
        [
          ...deframer.add(stream.sublist(0, split)),
          ...deframer.add(stream.sublist(split)),
        ],
        [
          Uint8List.fromList([9, 8]),
          Uint8List.fromList([7]),
        ],
      );
    }
  });

  test('two channels exchange frames once each knows the other', () async {
    final mesh = FakeMeshCoreMesh();
    final aliceRadio = mesh.radio(1);
    final bobRadio = mesh.radio(2);
    final bobGot = <(String, Uint8List)>[];
    MeshCoreCarrierChannel channel(
      Object radio,
      List<(String, Uint8List)> got,
    ) => MeshCoreCarrierChannel(
      config: const MeshCoreCarrierConfig(
        link: MeshCoreLink.serial,
        host: '/dev/ttyACM0',
      ),
      connector: (_) async => radio as FakeMeshCoreRadio,
      onFrame: (sender, frame) => got.add((sender, frame)),
    );
    final alice = channel(aliceRadio, []);
    final bob = channel(bobRadio, bobGot);
    addTearDown(alice.stop);
    addTearDown(bob.stop);
    alice.start();
    bob.start();
    while (alice.state != MeshCoreCarrierState.connected ||
        bob.state != MeshCoreCarrierState.connected) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final frame = Uint8List.fromList(
      List.generate(meshCoreFraming.chunkBytes + 11, (i) => i % 256),
    );
    // Bob's radio does not know Alice yet: the message is refused there.
    await alice.sendFrame(bob.localAddress!, frame);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(bobGot, isEmpty);
    expect(mesh.refused, 1);
    bob.updatePeers({alice.localAddress!});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await alice.sendFrame(bob.localAddress!, frame);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(bobGot.single.$2, frame);
    expect(bobGot.single.$1, alice.localAddress!.split('|').first);
  });

  test('Bluetooth radios take frames without the serial header', () async {
    final mesh = FakeMeshCoreMesh();
    final got = <(String, Uint8List)>[];
    MeshCoreCarrierChannel channel(
      FakeMeshCoreRadio radio,
      List<(String, Uint8List)> into,
    ) => MeshCoreCarrierChannel(
      config: const MeshCoreCarrierConfig(
        link: MeshCoreLink.bluetooth,
        host: 'AA:BB:CC:DD:EE:FF',
      ),
      connector: (_) async => radio,
      onFrame: (sender, frame) => into.add((sender, frame)),
    );
    final alice = channel(mesh.radio(1, bluetooth: true), []);
    final bobRadio = mesh.radio(2, bluetooth: true);
    final bob = channel(bobRadio, got);
    addTearDown(alice.stop);
    addTearDown(bob.stop);
    alice.start();
    bob.start();
    while (alice.state != MeshCoreCarrierState.connected ||
        bob.state != MeshCoreCarrierState.connected) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    bob.updatePeers({alice.localAddress!});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await alice.sendFrame(bob.localAddress!, Uint8List.fromList([5, 6, 7]));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(got.single.$2, [5, 6, 7]);
    // Contacts get neutral names; ones already listed keep theirs.
    expect(bobRadio.names.values.single, isNot(contains('Conest')));
    expect(bobRadio.names.values.single, hasLength(8));
  });

  test('a contact already on the radio is not overwritten', () async {
    final mesh = FakeMeshCoreMesh();
    final aliceRadio = mesh.radio(1);
    final bobRadio = mesh.radio(2);
    final prefix = bobRadio.publicKey
        .sublist(0, 6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    aliceRadio.contacts[prefix] = bobRadio.publicKey;
    aliceRadio.names[prefix] = 'Bob (named by me)';
    final alice = MeshCoreCarrierChannel(
      config: const MeshCoreCarrierConfig(
        link: MeshCoreLink.serial,
        host: '/dev/ttyACM0',
      ),
      connector: (_) async => aliceRadio,
      onFrame: (_, _) {},
    );
    addTearDown(alice.stop);
    alice.start();
    while (alice.state != MeshCoreCarrierState.connected) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    alice.updatePeers({MeshCoreAddress(bobRadio.publicKey).encode()});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(aliceRadio.names[prefix], 'Bob (named by me)');
  });

  test('addresses are checked', () {
    final key = List.generate(32, (i) => i);
    final good = MeshCoreAddress(Uint8List.fromList(key)).encode();
    expect(isValidMeshCoreAddress(good), isTrue);
    expect(isValidMeshCoreAddress(good.toUpperCase()), isFalse);
    expect(
      isValidMeshCoreAddress('ffffffffffff|${good.split('|').last}'),
      isFalse,
    );
    expect(isValidMeshCoreAddress('abc'), isFalse);
  });
}
