import 'dart:typed_data';

import 'package:conest/src/reticulum/endpoint.dart';
import 'package:conest/src/reticulum/identity.dart';
import 'package:conest/src/reticulum/rnode_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_rnode.dart';

void main() {
  test('two endpoints on RNodes with the same settings talk', () async {
    final air = FakeAir();
    final aliceRadio = await RnodeInterface.open(
      air.radio(),
      RnodeConfig.eu869,
    );
    final bobRadio = await RnodeInterface.open(air.radio(), RnodeConfig.eu869);
    addTearDown(aliceRadio.close);
    addTearDown(bobRadio.close);
    expect(aliceRadio.firmwareVersion, '1.82');
    final got = <Uint8List>[];
    final alice = RnsEndpoint(
      identity: await RnsIdentity.generate(),
      nameHash: rnsNameHash('conest', const ['carrier']),
      interface: aliceRadio,
    );
    final bob = RnsEndpoint(
      identity: await RnsIdentity.generate(),
      nameHash: rnsNameHash('conest', const ['carrier']),
      interface: bobRadio,
      onData: got.add,
    );
    alice.watch(bob.destinationHash);
    await bob.announce();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(alice.pathTo(bob.destinationHash), isNotNull);
    await alice.sendTo(bob.identity, [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(got.single, [1, 2, 3]);
  });

  test('radios on another channel hear nothing', () async {
    final air = FakeAir();
    final eu = await RnodeInterface.open(air.radio(), RnodeConfig.eu869);
    final us = await RnodeInterface.open(air.radio(), RnodeConfig.us915);
    addTearDown(eu.close);
    addTearDown(us.close);
    final heard = <Uint8List>[];
    us.packets.listen(heard.add);
    await eu.send(Uint8List.fromList(List.filled(40, 1)));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(heard, isEmpty);
  });

  test('a device that is not an RNode is refused', () async {
    final air = FakeAir();
    await expectLater(
      RnodeInterface.open(
        air.radio(answersDetect: false),
        RnodeConfig.eu869,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsStateError,
    );
    await expectLater(
      RnodeInterface.open(
        air.radio(acceptsSettings: false),
        RnodeConfig.eu869,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsStateError,
    );
  });

  test('settings are checked and saved', () {
    expect(RnodeConfig.eu869.problem, isNull);
    expect(
      const RnodeConfig(
        frequency: 868000000,
        bandwidth: 123,
        txPower: 14,
        spreadingFactor: 8,
        codingRate: 5,
      ).problem,
      isNotNull,
    );
    final restored = RnodeConfig.fromJson(RnodeConfig.eu869.toJson())!;
    expect(restored.frequency, 869525000);
    expect(restored.longTermAirtimeLimit, 10);
    expect(RnodeConfig.fromJson({'frequency': 'x'}), isNull);
  });

  test('closing turns the radio off', () async {
    final air = FakeAir();
    final link = air.radio();
    final radio = await RnodeInterface.open(link, RnodeConfig.eu869);
    expect(link.on, isTrue);
    final settings = link.settings;
    await radio.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settings[RnodeCommand.radioState], [0]);
  });
}
