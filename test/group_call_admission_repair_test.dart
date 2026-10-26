import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/group_call/group_call_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_call_network.dart';

void main() {
  Future<FakeCallNetwork> network(int count) async {
    final net = FakeCallNetwork();
    for (var i = 0; i < count; i++) {
      await net.add('p$i');
    }
    addTearDown(net.dispose);
    return net;
  }

  test('connected stale roster repairs before the discovery beacon', () async {
    final net = await network(3);
    await net.connect(['p0', 'p1']);
    final starter = net.peers['p0']!;
    final stale = net.peers['p1']!;
    net.droppedSignals.addAll([
      for (final action in ['roster', 'key', 'start']) ('p0', 'p1', action),
    ]);
    await net.peers['p2']!.service.join('group');
    await net.flush();
    expect(stale.service.active!.connected, true);
    expect(stale.service.active!.participants, hasLength(2));
    net.droppedSignals.clear();
    await net.advance(const Duration(seconds: 2));
    expect(stale.service.active!.participants, hasLength(3));
    expect(stale.service.active!.cipher.epoch, starter.service.active!.epoch);
    await net.peers['p2']!.service.sendAudio(Uint8List.fromList([7]));
    await net.flush();
    expect(stale.media.played.single.$3, [7]);
    final epoch = starter.service.active!.epoch;
    net.signals.clear();
    await net.advance(const Duration(seconds: 2));
    expect(starter.service.active!.epoch, epoch);
    expect(net.signals.where((s) => s.$3.action == 'key'), isEmpty);
  });

  test(
    'authenticated join intent repairs a missed new leader roster',
    () async {
      final net = await network(3);
      await net.connect(['p0', 'p2']);
      net.droppedSignals.addAll([
        for (final action in ['roster', 'key', 'start']) ('p0', 'p2', action),
      ]);
      await net.peers['p1']!.service.join('group');
      await net.flush();
      final stale = net.peers['p2']!;
      expect(stale.service.active!.participants.map((p) => p.deviceId), [
        'p0',
        'p2',
      ]);
      expect(stale.service.active!.allParticipants, isNot(contains('p1')));
      net.dropped.add('p0');
      await net.advance(const Duration(seconds: 7));
      for (final id in ['p1', 'p2']) {
        final room = net.peers[id]!.service.active!;
        expect(room.coordinator, 'p1');
        expect(room.connected, true);
        expect(room.participants.map((p) => p.deviceId).toSet(), {'p1', 'p2'});
      }
      await net.peers['p1']!.service.sendAudio(Uint8List.fromList([8]));
      await net.flush();
      expect(stale.media.played.single.$3, [8]);
    },
  );

  test('delayed previous admission key cannot reopen a fresh join', () async {
    final net = await network(4);
    await net.connect(['p0', 'p1', 'p2']);
    final receiver = net.peers['p1']!;
    final starter = net.peers['p0']!;
    final gate = Completer<void>();
    net.signalGates[('p0', 'p1', 'key')] = gate.future;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    net.droppedSignals.addAll([
      for (final action in ['roster', 'start']) ('p0', 'p1', action),
    ]);
    await net.peers['p3']!.service.join('group');
    await net.flush();
    await starter.service.sendAudio(Uint8List.fromList([90]));
    await net.flush();
    final oldFrame = net.datagrams
        .lastWhere((d) => d.sender == 'p0' && d.recipient == 'p1')
        .bytes;
    final oldAdmission = receiver.service.active!.admission;
    net.droppedSignals.addAll([
      for (final id in ['p0', 'p2', 'p3'])
        for (final action in ['leave', 'join']) ('p1', id, action),
    ]);
    await receiver.service.leave();
    await net.flush();
    await receiver.service.join('group');
    await net.flush();
    final room = receiver.service.active!;
    expect(room.admission, isNot(oldAdmission));
    final before = (
      room.term,
      room.coordinator,
      room.version,
      room.epoch,
      room.cipher,
      room.needsAdmission,
      room.participants,
    );
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await net.flush();
    expect((
      room.term,
      room.coordinator,
      room.version,
      room.epoch,
      room.cipher,
      room.needsAdmission,
      room.participants,
    ), before);
    expect(room.connected, false);
    await receiver.service.receiveDatagram('group', 'p0', oldFrame);
    expect(receiver.media.played, isEmpty);
    net.signalGates.clear();
    net.droppedSignals.clear();
    await net.advance(const Duration(seconds: 2));
    expect(receiver.service.active!.connected, true);
    await starter.service.sendAudio(Uint8List.fromList([91]));
    await net.flush();
    expect(receiver.media.played.single.$3, [91]);
  });

  test('delayed old join cannot replace the latest admission', () async {
    final net = await network(3);
    await net.connect(net.peers.keys);
    final oldJoin = net.signals
        .firstWhere(
          (s) => s.$1 == 'p1' && s.$2 == 'p0' && s.$3.action == 'join',
        )
        .$3;
    final rejoining = net.peers['p1']!;
    net.droppedSignals.addAll([('p1', 'p0', 'leave'), ('p1', 'p2', 'leave')]);
    // Immediate rejoin must have a strictly newer authenticated issue time.
    await rejoining.service.leave();
    await net.flush();
    await rejoining.service.join('group');
    await net.flush();
    expect(rejoining.service.active!.connected, true);
    final room = net.peers['p0']!.service.active!;
    final current = (
      room.version,
      room.epoch,
      room.participants,
      room.admissions['p1'],
    );
    expect(
      await net.peers['p0']!.service.receiveSignal(
        oldJoin,
        authenticatedSender: 'p1',
      ),
      false,
    );
    expect((
      room.version,
      room.epoch,
      room.participants,
      room.admissions['p1'],
    ), current);
    await rejoining.service.sendAudio(Uint8List.fromList([9]));
    await net.flush();
    expect(net.peers['p2']!.media.played.single.$3, [9]);
  });

  test('invalid join term cannot become an authority witness', () async {
    final net = await network(3);
    await net.connect(['p0', 'p2']);
    final receiver = net.peers['p2']!.service;
    final room = receiver.active!;
    for (final term in [-1, '1', 0x80000000]) {
      expect(
        await receiver.receiveSignal(
          GroupCallSignal(
            groupId: 'group',
            callId: room.callId,
            senderDeviceId: 'p1',
            action: 'join',
            issuedAt: net.time,
            payload: {'term': term, 'admission': 'AAAAAAAAAAAAAAAAAAAAAA'},
          ),
          authenticatedSender: 'p1',
        ),
        false,
      );
    }
    expect(room.allParticipants, isNot(contains('p1')));
    expect(room.participants.map((p) => p.deviceId), ['p0', 'p2']);
  });
}
