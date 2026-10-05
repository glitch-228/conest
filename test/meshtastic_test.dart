import 'dart:typed_data';

import 'package:conest/src/meshtastic/protobuf.dart';
import 'package:conest/src/meshtastic/radio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_meshtastic.dart';

void main() {
  group('protobuf', () {
    test('fields round-trip', () {
      final bytes =
          (ProtoWriter()
                ..uint(1, 300)
                ..fixed32(2, 0xdeadbeef)
                ..bytes(3, [1, 2, 3])
                ..string(4, 'hi')
                ..boolean(5, true)
                ..uint(6, 0))
              .toBytes();
      final fields = ProtoReader.fields(bytes);
      expect(fields[1], 300);
      expect(fields[2], 0xdeadbeef);
      expect(fields[3], [1, 2, 3]);
      expect(fields[4], 'hi'.codeUnits);
      expect(fields[5], 1);
      expect(fields.containsKey(6), isFalse);
    });

    test('malformed input is refused', () {
      for (final bad in [
        [0x08],
        [0x12, 0x05, 1],
        [0x0d, 1, 2],
        [0x0b],
      ]) {
        expect(
          () => ProtoReader.fields(Uint8List.fromList(bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('framing', () {
    test('frames survive debug text and splits', () {
      final stream = [
        ...'log line\r\n'.codeUnits,
        ...MeshtasticFraming.frame([1, 2, 3]),
        ...'more \x94 text'.codeUnits,
        ...MeshtasticFraming.frame([4]),
      ];
      for (var split = 0; split <= stream.length; split++) {
        final deframer = MeshtasticDeframer();
        final frames = [
          ...deframer.add(stream.sublist(0, split)),
          ...deframer.add(stream.sublist(split)),
        ];
        expect(frames, [
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([4]),
        ], reason: 'split at $split');
      }
    });
  });

  group('radio', () {
    test('reads its node and exchanges direct messages', () async {
      final mesh = FakeMesh();
      final alice = await MeshtasticRadio.open(mesh.device(0x11111111));
      final bob = await MeshtasticRadio.open(mesh.device(0x22222222));
      addTearDown(alice.close);
      addTearDown(bob.close);
      expect(alice.myNodeNum, 0x11111111);
      expect(alice.myPublicKey, hasLength(32));
      final got = <MeshtasticPacket>[];
      bob.packets.listen(got.add);
      await alice.send(to: 0x22222222, portnum: 300, payload: [9, 8, 7]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got.single.from, 0x11111111);
      expect(got.single.portnum, 300);
      expect(got.single.payload, [9, 8, 7]);
      expect(got.single.pkiEncrypted, isTrue);
    });

    test('a device that does not answer is refused', () async {
      await expectLater(
        MeshtasticRadio.open(
          FakeMesh().device(1, answers: false),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsStateError,
      );
    });
  });
}
