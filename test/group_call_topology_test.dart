import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/group_call/group_call_models.dart';
import 'package:conest/src/group_call/group_call_policy.dart';
import 'package:conest/src/group_call/group_call_topology.dart';
import 'support/fake_call_network.dart';

void main() {
  Future<FakeCallNetwork> network(int count) async {
    final result = FakeCallNetwork();
    for (var i = 0; i < count; i++) {
      await result.add('p$i');
    }
    addTearDown(result.dispose);
    return result;
  }

  test(
    'seven participants agree on one forwarder and hear every sender',
    () async {
      final net = await network(7);
      for (final peer in net.peers.values) {
        peer.policy.stats = const GroupCallLinkStats(
          desktop: false,
          mains: false,
          metered: true,
        );
      }
      net.peers['p6']!.policy.stats = const GroupCallLinkStats(
        desktop: true,
        mains: true,
        metered: false,
      );
      await net.connect(net.peers.keys);
      await net.advance(const Duration(milliseconds: 1500));
      expect(net.peers.values.map((p) => p.service.active!.forwarder).toSet(), {
        'p6',
      });
      for (final peer in net.peers.values) {
        await peer.service.sendAudio(
          Uint8List.fromList([int.parse(peer.id.substring(1))]),
        );
        await net.flush();
      }
      for (final peer in net.peers.values) {
        expect(peer.media.played, hasLength(6));
        expect(peer.media.played.map((p) => p.$3.single).toSet(), {
          for (var i = 0; i < 7; i++)
            if ('p$i' != peer.id) i,
        });
      }
      // The forwarding hop preserves both ciphertext and sender signature.
      final sent = net.datagrams.lastWhere(
        (f) => f.sender == 'p2' && f.recipient == 'p6',
      );
      final forwarded = net.datagrams.lastWhere(
        (f) =>
            f.sender == 'p6' &&
            f.recipient == 'p1' &&
            f.bytes.length == sent.bytes.length &&
            f.bytes[13] == sent.bytes[13],
      );
      expect(forwarded.bytes, sent.bytes);
    },
  );

  test(
    'dropped forwarder is replaced within two seconds with lasting audio',
    () async {
      final net = await network(7);
      await net.connect(net.peers.keys);
      await net.advance(const Duration(seconds: 1));
      final old = net.peers['p1']!.service.active!.forwarder!;
      net.dropped.add(old);
      await net.advance(const Duration(seconds: 2));
      final survivors = net.peers.values.where((p) => p.id != old).toList();
      final elected = survivors.map((p) => p.service.active!.forwarder).toSet();
      expect(elected, hasLength(1));
      expect(elected.single, isNot(old));
      expect(elected.single, isNotNull);
      for (final peer in survivors) {
        expect(peer.service.active!.connected, true);
      }
      final speaker = survivors.last;
      await speaker.service.sendAudio(Uint8List.fromList([77]));
      await net.flush();
      for (final peer in survivors.where((p) => p != speaker)) {
        expect(peer.media.played.last.$3, [77]);
      }
      await net.advance(const Duration(seconds: 3));
      await speaker.service.sendAudio(Uint8List.fromList([78]));
      await net.flush();
      for (final peer in survivors.where((p) => p != speaker)) {
        expect(peer.media.played.last.$3, [78]);
      }
    },
  );

  test('poor mesh links held for three seconds select a forwarder', () async {
    final net = await network(3);
    await net.connect(net.peers.keys);
    net.peers['p2']!.policy.stats = const GroupCallLinkStats(
      desktop: false,
      mains: false,
      metered: true,
      rttMs: 700,
      loss: 0.3,
    );
    await net.advance(const Duration(seconds: 2));
    expect(
      net.peers.values.every((p) => p.service.active!.forwarder == null),
      true,
    );
    await net.advance(const Duration(seconds: 3));
    expect(net.peers.values.map((p) => p.service.active!.forwarder).toSet(), {
      'p0',
    });
    await net.peers['p2']!.service.sendAudio(Uint8List.fromList([12]));
    await net.flush();
    expect(net.peers['p1']!.media.played.last.$3, [12]);
  });

  test(
    'ping datagrams measure RTT and loss never blocks another participant',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      net.latency = const Duration(milliseconds: 100);
      net.loss = 0.15;
      await net.advance(const Duration(seconds: 4));
      expect(
        net.peers.values.any((p) => p.service.active!.measuredRttMs > 0),
        true,
      );
      net.loss = 0;
      net.latency = Duration.zero;
      await net.peers['p1']!.service.sendAudio(Uint8List.fromList([90]));
      await net.flush();
      expect(net.peers['p2']!.media.played.last.$3, [90]);
    },
  );

  test('election preference and tie break are deterministic', () {
    const peers = [
      GroupCallParticipant('z', 0),
      GroupCallParticipant('a', 1),
      GroupCallParticipant('b', 2),
    ];
    const stats = {
      'z': GroupCallLinkStats(desktop: false, mains: true, metered: false),
      'a': GroupCallLinkStats(desktop: true, mains: true, metered: false),
      'b': GroupCallLinkStats(desktop: true, mains: true, metered: false),
    };
    expect(electGroupCallForwarder(peers, stats), 'a');
    expect(electGroupCallForwarder(peers.reversed.toList(), stats), 'a');
    expect(
      () => parseGroupCallStatsSnapshot({
        'outsider': stats['a']!.toJson(),
      }, peers),
      throwsFormatException,
    );
  });
}
