import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/tor_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_tor.dart';

void main() {
  test('bridge lines are normalized and classified', () {
    const fingerprint = '4352E58420E68F5E40BF7C74FADDCCD9D1349413';
    expect(
      normalizeBridgeLine('  Bridge   192.0.2.1:443\t$fingerprint  '),
      '192.0.2.1:443 $fingerprint',
    );
    expect(
      normalizeBridgeLine(
        'Bridge OBFS4 192.0.2.1:443 $fingerprint cert=abc+/= iat-mode=0',
      ),
      'obfs4 192.0.2.1:443 $fingerprint cert=abc+/= iat-mode=0',
    );
    expect(
      normalizeBridgeLine('webtunnel [2001:db8::1]:443 $fingerprint url=x'),
      isNotNull,
    );
    expect(normalizeBridgeLine('192.0.2.1:443'), isNull);
    expect(normalizeBridgeLine('192.0.2.1:443 ABCD'), isNull);
    expect(normalizeBridgeLine('bridge 192.0.2.1:443 AB\u0000'), isNull);
    // The type comes first, and only types the bundled client has.
    expect(normalizeBridgeLine('192.0.2.1:443 obfs4 $fingerprint'), isNull);
    expect(normalizeBridgeLine('$fingerprint 192.0.2.1:443'), isNull);
    expect(normalizeBridgeLine('obfs5 192.0.2.1:443 $fingerprint'), isNull);
    expect(normalizeBridgeLine('obfs4 $fingerprint cert=x'), isNull);
    expect(bridgeNeedsTransport('192.0.2.1:443 ABCD'), isFalse);
    expect(bridgeNeedsTransport('[2001:db8::1]:443 ABCD'), isFalse);
    expect(bridgeNeedsTransport('obfs4 192.0.2.1:443 ABCD cert=x'), isTrue);
  });

  test('the saved config keeps only a valid onion address', () {
    final address = '${'a' * 56}.onion';
    final config = TorCarrierConfig.fromJson(
      jsonDecode(
            jsonEncode(
              TorCarrierConfig(
                bridges: ['192.0.2.1:443 AB'],
                address: address,
              ).toJson(),
            ),
          )
          as Map<String, dynamic>,
    )!;
    expect(config.bridges, ['192.0.2.1:443 AB']);
    expect(config.address, address);
    expect(
      TorCarrierConfig.fromJson({'bridges': [], 'address': 'x.onion'})!.address,
      isNull,
    );
  });

  test(
    'frames carry the sender onion and malformed ones are dropped',
    () async {
      final tor = FakeTorNetwork();
      final received = <(String, List<int>)>[];
      TorCarrierChannel channel(FakeTorApi api, String state) =>
          TorCarrierChannel(
            config: const TorCarrierConfig(),
            api: api,
            stateDirectory: state,
            cacheDirectory: '$state-cache',
            onFrame: (sender, frame) => received.add((sender, frame)),
          );
      final aliceApi = tor.device();
      final alice = channel(aliceApi, 'alice');
      final bob = channel(tor.device(), 'bob');
      await expectLater(
        bob.sendFrame(alice.localAddress ?? '${'a' * 56}.onion', Uint8List(1)),
        throwsStateError,
      );
      alice.start();
      bob.start();
      while (alice.state != TorCarrierState.connected ||
          bob.state != TorCarrierState.connected) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(alice.progress, 1);
      await bob.sendFrame(alice.localAddress!, Uint8List.fromList([1, 2, 3]));
      // Not a frame: a wrong version and a bad sender address.
      await bob.sendFrame(alice.localAddress!, Uint8List(0));
      final bobApi = tor.device();
      await bobApi.start(
        stateDirectory: 'mallory',
        cacheDirectory: 'm',
        bridges: const [],
      );
      await bobApi.send(alice.localAddress!, Uint8List.fromList([2, 1, 2, 3]));
      await bobApi.send(
        alice.localAddress!,
        Uint8List.fromList([1, ...ascii.encode('${'A' * 56}.onion'), 9]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, hasLength(1));
      expect(received.single.$1, bob.localAddress);
      expect(received.single.$2, [1, 2, 3]);
      await alice.stop();
      expect(alice.state, TorCarrierState.stopped);
    },
  );
}
