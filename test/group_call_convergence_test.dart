import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_call_network.dart';

/// Group calls on slow, lossy networks (the device lab saw controls take
/// 2-17 s and a phone's frames reach nobody): no false takeovers, and one
/// call again after a partition heals.
void main() {
  Future<FakeCallNetwork> network(int count) async {
    final net = FakeCallNetwork();
    for (var i = 0; i < count; i++) {
      await net.add('p$i');
    }
    addTearDown(net.dispose);
    return net;
  }

  Duration between(FakeCallNetwork net, int fromMs, int toMs) =>
      Duration(milliseconds: fromMs + net.random.nextInt(toMs - fromMs + 1));

  const never = Duration(days: 1);

  Set<(int, String, int)> authorities(FakeCallNetwork net) => {
    for (final peer in net.peers.values)
      if (peer.service.active case final room?)
        (room.term, room.coordinator, room.epoch),
  };

  Future<void> expectOneWorkingCall(FakeCallNetwork net) async {
    expect(authorities(net), hasLength(1));
    for (final peer in net.peers.values) {
      final room = peer.service.active!;
      expect(room.connected, true, reason: '${peer.id} connected');
      expect(room.participants, hasLength(net.peers.length));
    }
    net.linkDelay = null;
    for (final peer in net.peers.values) {
      peer.media.played.clear();
    }
    for (final peer in net.peers.values) {
      await peer.service.sendAudio(Uint8List.fromList([9]));
    }
    await net.flush();
    for (final peer in net.peers.values) {
      expect(
        peer.media.played,
        hasLength(net.peers.length - 1),
        reason: '${peer.id} hears everyone',
      );
    }
  }

  test(
    'slow controls and a coordinator whose frames are lost: no takeover',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      await net.advance(const Duration(seconds: 2));
      expect(authorities(net), hasLength(1));
      final before = authorities(net).single;
      net.linkDelay = (from, to, {required datagram}) => datagram
          ? (from == 'p0' ? never : const Duration(milliseconds: 80))
          : between(net, 2000, 17000);
      await net.advance(const Duration(seconds: 90));
      for (final peer in net.peers.values) {
        final room = peer.service.active!;
        expect(
          (room.term, room.coordinator),
          (before.$1, before.$2),
          reason: '${peer.id} kept the coordinator',
        );
        expect(room.participants, hasLength(3), reason: '${peer.id} roster');
      }
    },
  );

  test(
    'a 10 s stall in a slow coordinator\'s controls is not taken for its end',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      await net.advance(const Duration(seconds: 2));
      final before = authorities(net).single;
      // Controls take 3 s (a round trip of about 6 s is measured), the
      // coordinator's frames are lost, then its controls stall: those sent
      // in a 10 s window all arrive together, 10 s after the last one.
      final stall = net.time.add(const Duration(seconds: 30));
      net.linkDelay = (from, to, {required datagram}) {
        if (datagram) {
          return from == 'p0' ? never : const Duration(milliseconds: 80);
        }
        if (from == 'p0' &&
            !net.time.isBefore(stall) &&
            net.time.isBefore(stall.add(const Duration(seconds: 10)))) {
          return stall.add(const Duration(seconds: 13)).difference(net.time);
        }
        return const Duration(seconds: 3);
      };
      await net.advance(const Duration(seconds: 60));
      for (final peer in net.peers.values) {
        final room = peer.service.active!;
        expect(
          (room.term, room.coordinator),
          (before.$1, before.$2),
          reason: '${peer.id} kept the coordinator',
        );
        expect(room.participants, hasLength(3), reason: '${peer.id} roster');
      }
    },
  );

  test('controls that always take 20 s still make one call', () async {
    final net = await network(3);
    net.linkDelay = (from, to, {required datagram}) => datagram
        ? const Duration(milliseconds: 100)
        : const Duration(seconds: 20);
    await net.peers['p0']!.service.start('group');
    await net.advance(const Duration(seconds: 21));
    await net.peers['p1']!.service.join('group');
    await net.peers['p2']!.service.join('group');
    await net.advance(const Duration(seconds: 120));
    await expectOneWorkingCall(net);
  });

  test('a partition that heals with slow controls ends as one call', () async {
    final net = await network(4);
    await net.connect(net.peers.keys);
    await net.advance(const Duration(seconds: 2));
    net.dropped.add('p0');
    await net.advance(const Duration(seconds: 20));
    expect(net.peers['p1']!.service.active!.coordinator, 'p1');
    net.dropped.clear();
    net.linkDelay = (from, to, {required datagram}) =>
        datagram ? const Duration(milliseconds: 80) : between(net, 500, 3000);
    await net.advance(const Duration(seconds: 60));
    await expectOneWorkingCall(net);
  });

  test(
    'a coordinator the old one never admitted still brings it back',
    () async {
      final net = await network(3);
      await net.connect(['p0', 'p1']);
      await net.advance(const Duration(seconds: 2));
      // p0 goes away; p1 leads (term 1) and admits p2, whom p0 never saw.
      net.dropped.add('p0');
      await net.advance(const Duration(seconds: 20));
      expect(net.peers['p1']!.service.active!.coordinator, 'p1');
      await net.peers['p2']!.service.join('group');
      await net.advance(const Duration(seconds: 4));
      expect(net.peers['p2']!.service.active!.connected, true);
      // Then p1 goes away too; p2 leads (term 2).
      net.dropped
        ..remove('p0')
        ..add('p1');
      net.blockedLinks.addAll([('p0', 'p2'), ('p2', 'p0')]);
      await net.advance(const Duration(seconds: 20));
      expect(net.peers['p2']!.service.active!.coordinator, 'p2');
      net.dropped.clear();
      net.blockedLinks.clear();
      await net.advance(const Duration(seconds: 30));
      await expectOneWorkingCall(net);
    },
  );

  test(
    'a coordinator that is really gone is replaced within seconds',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      net.latency = const Duration(milliseconds: 100);
      await net.advance(const Duration(seconds: 3));
      net.dropped.add('p0');
      await net.advance(const Duration(seconds: 10));
      for (final id in ['p1', 'p2']) {
        final room = net.peers[id]!.service.active!;
        expect(room.coordinator, 'p1');
        expect(room.connected, true);
        expect(room.participants.map((p) => p.deviceId).toSet(), {'p1', 'p2'});
      }
    },
  );
}
