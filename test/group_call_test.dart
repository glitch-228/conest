import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/group_call/group_call_crypto.dart';
import 'package:conest/src/group_call/group_call_models.dart';
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

  test('three person mesh decrypts and attributes every speaker', () async {
    final net = await network(3);
    await net.connect(net.peers.keys);
    for (final peer in net.peers.values) {
      expect(peer.service.active!.connected, true);
      expect(peer.service.active!.participants, hasLength(3));
      await peer.service.sendAudio(
        Uint8List.fromList([int.parse(peer.id.substring(1)), 42]),
      );
    }
    await net.flush();
    for (final peer in net.peers.values) {
      expect(peer.media.played, hasLength(2));
      for (final packet in peer.media.played) {
        final sender = peer.service.active!.participants.singleWhere(
          (p) => p.index == packet.$1,
        );
        expect(packet.$3.first, int.parse(sender.deviceId.substring(1)));
      }
    }
    expect(
      net.signals
          .where((s) => s.$3.action == 'key')
          .every((s) => s.$3.payload['recipient'] == s.$2),
      true,
    );
  });

  test('leaving rotates key; leaver cannot decrypt future frames', () async {
    final net = await network(3);
    await net.connect(net.peers.keys);
    final p0 = net.peers['p0']!;
    final p1 = net.peers['p1']!;
    final room = p1.service.active!;
    final keySignal = net.signals
        .lastWhere((s) => s.$2 == 'p1' && s.$3.action == 'key')
        .$3;
    final stolen = GroupCallCipher(
      groupId: 'group',
      callId: room.callId,
      localDeviceId: 'p1',
      sign: room.cipher.sign,
      verify: room.cipher.verify,
      now: () => net.time,
    );
    addTearDown(stolen.close);
    await stolen.install(
      room.epoch,
      Uint8List.fromList(base64Decode(keySignal.payload['key'] as String)),
      room.participants,
    );
    final epoch = room.epoch;
    await p1.service.leave();
    await net.flush();
    expect(p0.service.active!.epoch, greaterThan(epoch));
    // The departed member can learn public epoch/roster metadata and try
    // deriving fresh sender keys with its old call key. That must still fail.
    await stolen.install(
      p0.service.active!.epoch,
      Uint8List.fromList(base64Decode(keySignal.payload['key'] as String)),
      p0.service.active!.participants,
    );
    await p0.service.sendAudio(Uint8List.fromList([4]));
    await net.flush();
    expect(await stolen.decrypt(net.datagrams.last.bytes), isNull);
    expect(net.peers['p2']!.media.played.last.$3, [4]);
  });

  test('new joiner cannot decrypt pre-join frames', () async {
    final net = await network(3);
    await net.connect(['p0', 'p1']);
    await net.peers['p0']!.service.sendAudio(Uint8List.fromList([8]));
    await net.flush();
    final old = net.datagrams.last.bytes;
    final oldRoom = net.peers['p0']!.service.active!;
    final oldEpoch = oldRoom.epoch;
    final oldRoster = List<GroupCallParticipant>.of(oldRoom.participants);
    await net.peers['p2']!.service.join('group');
    await net.flush();
    final joined = net.peers['p2']!.service.active!;
    expect(await joined.cipher.decrypt(old), isNull);
    final disclosed = net.signals
        .lastWhere((s) => s.$2 == 'p2' && s.$3.action == 'key')
        .$3;
    final attacker = GroupCallCipher(
      groupId: 'group',
      callId: joined.callId,
      localDeviceId: 'p2',
      sign: joined.cipher.sign,
      verify: joined.cipher.verify,
      now: () => net.time,
    );
    addTearDown(attacker.close);
    await attacker.install(
      oldEpoch,
      Uint8List.fromList(base64Decode(disclosed.payload['key'] as String)),
      oldRoster,
    );
    expect(await attacker.decrypt(old), isNull);
    await net.peers['p0']!.service.sendAudio(Uint8List.fromList([9]));
    await net.flush();
    expect(net.peers['p2']!.media.played.single.$3, [9]);
  });

  test(
    'non-members, removed members and wrong call signals are refused',
    () async {
      final net = await network(3);
      await net.connect(['p0', 'p1']);
      final room = net.peers['p0']!.service.active!;
      GroupCallSignal signal(String sender, String call) => GroupCallSignal(
        groupId: 'group',
        callId: call,
        senderDeviceId: sender,
        action: 'join',
        issuedAt: net.time,
        payload: const {'admission': 'abcdefghijklmnopqrstuv'},
      );
      expect(
        await net.peers['p0']!.service.receiveSignal(
          signal('outsider', room.callId),
          authenticatedSender: 'outsider',
        ),
        false,
      );
      net.currentMembers.remove('p2');
      expect(
        await net.peers['p0']!.service.receiveSignal(
          signal('p2', room.callId),
          authenticatedSender: 'p2',
        ),
        false,
      );
      expect(
        await net.peers['p0']!.service.receiveSignal(
          signal('p1', 'wrong'),
          authenticatedSender: 'p1',
        ),
        false,
      );
      expect(
        await net.peers['p0']!.service.receiveSignal(
          signal('p1', room.callId),
          authenticatedSender: 'p2',
        ),
        false,
      );
      final current = room.epoch;
      net.currentMembers.remove('p1');
      await net.peers['p0']!.service.tick();
      await net.flush();
      expect(room.epoch, greaterThan(current));
      expect(room.participants.map((p) => p.deviceId), ['p0']);
    },
  );

  test(
    'replay, stale epoch, oversized and over-rate frames are dropped',
    () async {
      final net = await network(3);
      await net.connect(['p0', 'p1']);
      final sender = net.peers['p0']!;
      final receiver = net.peers['p1']!;
      await sender.service.sendAudio(Uint8List.fromList([1]));
      await net.flush();
      final replay = net.datagrams.last.bytes;
      await receiver.service.receiveDatagram('group', 'p0', replay);
      expect(receiver.media.played, hasLength(1));
      final old = await sender.service.active!.cipher.encrypt(
        Uint8List.fromList([0, 0, 0, 0, 2, 2]),
      );
      await net.peers['p2']!.service.join('group');
      await net.flush();
      await net.advance(const Duration(milliseconds: 300));
      await receiver.service.receiveDatagram('group', 'p0', old!);
      await receiver.service.receiveDatagram('group', 'p0', Uint8List(1201));
      expect(receiver.media.played, hasLength(1));
      for (var i = 0; i < 200; i++) {
        final frame = await sender.service.active!.cipher.encrypt(
          Uint8List.fromList([0, 0, 0, i ~/ 256, i % 256 + 3, 3]),
        );
        await receiver.service.receiveDatagram('group', 'p0', frame!);
      }
      expect(receiver.media.played.length, lessThanOrEqualTo(161));
      expect(receiver.media.played.length, greaterThan(1));
    },
  );

  test('a reopened audio device keeps who is heard and the mute', () async {
    final net = await network(3);
    await net.connect(['p0', 'p1', 'p2']);
    final peer = net.peers['p0']!;
    await peer.service.setMuted(true);
    final heard = {...peer.media.participants};
    expect(heard, hasLength(2));
    await peer.service.reopenMedia();
    expect(peer.media.opened, isTrue);
    expect(peer.media.participants, heard);
    expect(peer.media.muted, isTrue);
  });

  test('a signal not taken says why', () async {
    final net = await network(2);
    await net.connect(['p0', 'p1']);
    final p0 = net.peers['p0']!.service;
    final room = p0.active!;
    GroupCallSignal signal(DateTime issuedAt) => GroupCallSignal(
      groupId: 'group',
      callId: room.callId,
      senderDeviceId: 'p1',
      action: 'join',
      issuedAt: issuedAt,
      payload: const {'admission': 'abcdefghijklmnopqrstuv'},
    );
    expect(
      await p0.receiveSignal(
        signal(net.time.subtract(const Duration(seconds: 70))),
        authenticatedSender: 'p1',
      ),
      isFalse,
    );
    expect(p0.lastRefusal, 'too old (70 s)');
    expect(
      await p0.receiveSignal(
        signal(net.time.add(const Duration(seconds: 15))),
        authenticatedSender: 'p1',
      ),
      isFalse,
    );
    expect(p0.lastRefusal, 'from the future');
    expect(
      await p0.receiveSignal(signal(net.time), authenticatedSender: 'p0'),
      isFalse,
    );
    expect(p0.lastRefusal, 'not its sender');
  });

  test('a different listener cannot forge another sender signature', () async {
    final net = await network(3);
    await net.connect(net.peers.keys);
    final room = net.peers['p0']!.service.active!;
    final keySignal = net.signals
        .lastWhere((s) => s.$2 == 'p2' && s.$3.action == 'key')
        .$3;
    final attacker = GroupCallCipher(
      groupId: 'group',
      callId: room.callId,
      localDeviceId: 'p0',
      sign: net.peers['p2']!.service.active!.cipher.sign,
      verify: room.cipher.verify,
      now: () => net.time,
    );
    addTearDown(attacker.close);
    await attacker.install(
      room.epoch,
      Uint8List.fromList(base64Decode(keySignal.payload['key'] as String)),
      room.participants,
    );
    final forged = await attacker.encrypt(
      Uint8List.fromList([0, 0, 0, 0, 1, 99]),
    );
    await net.peers['p1']!.service.receiveDatagram('group', 'p0', forged!);
    expect(net.peers['p1']!.media.played, isEmpty);
  });

  test('mute, push-to-talk and noise setting reach group engine', () async {
    final net = await network(2);
    await net.connect(net.peers.keys);
    final peer = net.peers['p0']!;
    await peer.service.setNoiseSuppression(false);
    expect(peer.media.noise, [true, false]);
    await peer.service.setPushToTalk(true);
    expect(peer.media.muted, true);
    await peer.service.sendAudio(Uint8List.fromList([1]));
    expect(net.datagrams, isEmpty);
    await peer.service.setPushToTalk(true, held: true);
    expect(peer.media.muted, false);
    await peer.service.sendAudio(Uint8List.fromList([2]));
    await net.flush();
    expect(net.peers['p1']!.media.played.single.$3, [2]);
    await peer.service.setMuted(true);
    expect(peer.media.muted, true);
  });

  test('group-only members use the same call roster and keys', () async {
    final net = await network(3);
    // This transport has only the authenticated group member directory;
    // no contact directory or contact-only gate exists.
    await net.connect(net.peers.keys);
    expect(net.peers.values.every((p) => p.service.active!.connected), true);
    net.unsupported.add('p2');
    await net.peers['p0']!.service.tick();
    await net.flush();
    expect(
      net.peers['p0']!.service.active!.participants.map((p) => p.deviceId),
      ['p0', 'p1'],
    );
  });

  test(
    'leaving and rejoining a live call creates a new admission epoch',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      final peer = net.peers['p1']!;
      final id = peer.service.active!.callId;
      final epoch = peer.service.active!.epoch;
      await peer.service.leave();
      await net.flush();
      expect(peer.service.active, isNull);
      await peer.service.join('group');
      await net.flush();
      expect(peer.service.active!.callId, id);
      expect(peer.service.active!.epoch, greaterThan(epoch));
      expect(peer.service.active!.connected, true);
    },
  );

  test('signal and roster parser bounds hostile inputs', () {
    expect(() => GroupCallSignal.decode('x' * 16385), throwsFormatException);
    expect(
      () => GroupCallParticipant.parse(
        List.filled(17, {'deviceId': 'p0', 'index': 0}),
      ),
      throwsFormatException,
    );
    expect(
      () => GroupCallParticipant.parse([
        {'deviceId': 'p0', 'index': 0},
        {'deviceId': 'p1', 'index': 0},
      ]),
      throwsFormatException,
    );
  });

  test('frames sent, heard and not delivered are counted per member', () async {
    final net = await network(3);
    await net.connect(net.peers.keys);
    net.noRoute.add('p2');
    await net.peers['p0']!.service.sendAudio(Uint8List.fromList([1]));
    await net.flush();
    final sender = net.peers['p0']!.service.active!;
    expect(sender.framesSent['p1'], 1);
    expect(sender.frameTrouble['p2: no direct route'], 1);
    expect(net.peers['p1']!.service.active!.framesHeard['p0'], 1);
  });
}
