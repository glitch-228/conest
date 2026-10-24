import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/group_call/group_call_models.dart';
import 'package:conest/src/group_call/group_call_crypto.dart';
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

  Future<GroupCallSignal> discovery(
    FakeCallNetwork net,
    String groupId, {
    String callId = 'same_call',
  }) async {
    final started = net.time;
    final signature = await net.peers['p0']!.service.sign(
      groupCallStartBytes(groupId, callId, 'p0', started),
    );
    return GroupCallSignal(
      groupId: groupId,
      callId: callId,
      senderDeviceId: 'p0',
      action: 'start',
      issuedAt: net.time,
      payload: {
        'startedBy': 'p0',
        'startedAt': started.toIso8601String(),
        'startSignature': base64Encode(signature),
        'term': 0,
        'coordinator': 'p0',
        'epoch': 1,
        'version': 1,
        'participants': [const GroupCallParticipant('p0', 0).toJson()],
      },
    );
  }

  test(
    'restored asymmetric links converge on one authority and working audio',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      final old = await net.peers['p0']!.service.active!.cipher.encrypt(
        Uint8List.fromList([0, 0, 0, 0, 1, 99]),
      );
      await net.advance(const Duration(seconds: 1));
      net.blockedLinks.add(('p0', 'p1'));
      await net.advance(const Duration(seconds: 7));
      expect(net.peers['p1']!.service.active!.term, greaterThan(0));
      net.blockedLinks.clear();
      await net.advance(const Duration(seconds: 6));
      final rooms = net.peers.values.map((p) => p.service.active!).toList();
      expect(
        rooms.map((r) => (r.term, r.coordinator, r.epoch)).toSet(),
        hasLength(1),
      );
      for (final peer in net.peers.values) {
        expect(peer.service.active!.connected, true);
        expect(peer.service.active!.participants, hasLength(3));
        peer.media.played.clear();
        expect(await peer.service.active!.cipher.decrypt(old!), isNull);
        await peer.service.sendAudio(Uint8List.fromList([7]));
        await net.flush();
      }
      // Clear once more, then require every receiver to hear both other peers.
      for (final peer in net.peers.values) {
        peer.media.played.clear();
      }
      for (final peer in net.peers.values) {
        await peer.service.sendAudio(Uint8List.fromList([8]));
      }
      await net.flush();
      for (final peer in net.peers.values) {
        expect(peer.media.played, hasLength(2));
      }
    },
  );

  test(
    'restored full partition reconciles a leader missing from the local roster',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      net.blockedLinks.addAll([
        ('p0', 'p1'),
        ('p0', 'p2'),
        ('p1', 'p0'),
        ('p2', 'p0'),
      ]);
      await net.advance(const Duration(seconds: 8));
      expect(net.peers['p0']!.service.active!.participants, hasLength(1));
      net.blockedLinks.clear();
      final replacement = net.signals
          .lastWhere(
            (s) => s.$1 == 'p1' && s.$2 == 'p0' && s.$3.action == 'start',
          )
          .$3;
      // Reconcile a historically admitted leader before a repair join can
      // happen to put it back into the old coordinator's current roster.
      expect(
        await net.peers['p0']!.service.receiveSignal(
          replacement,
          authenticatedSender: 'p1',
        ),
        true,
      );
      await net.advance(const Duration(seconds: 6));
      final authorities = net.peers.values
          .map(
            (p) => (
              p.service.active!.term,
              p.service.active!.coordinator,
              p.service.active!.epoch,
            ),
          )
          .toSet();
      expect(authorities, hasLength(1));
      for (final peer in net.peers.values) {
        expect(peer.service.active!.participants, hasLength(3));
        expect(peer.service.active!.connected, true);
        await peer.service.sendAudio(Uint8List.fromList([5]));
      }
      await net.flush();
      for (final peer in net.peers.values) {
        expect(peer.media.played, hasLength(2));
      }
    },
  );

  test(
    'pending admission survives slow signalling until its first key arrives',
    () async {
      final net = await network(3);
      await net.connect(['p0']);
      final joining = net.peers['p1']!;
      final gate = Completer<void>();
      net.signalGates[('p1', 'p0', 'join')] = gate.future;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      net.blockedLinks.add(('p0', 'p1'));
      await joining.service.join('group');
      await net.advance(const Duration(seconds: 6));
      expect(joining.service.active, isNotNull);
      expect(joining.service.active!.connected, false);
      expect(joining.service.active!.term, 0);
      expect(joining.service.active!.coordinator, 'p0');
      net.blockedLinks.clear();
      gate.complete();
      await net.advance(const Duration(seconds: 2));
      expect(joining.service.active!.connected, true);
      await net.peers['p0']!.service.sendAudio(Uint8List.fromList([8]));
      await net.flush();
      expect(joining.media.played.single.$3, [8]);
    },
  );

  test(
    'unjoined observer expires discovery without electing or tombstoning a live call',
    () async {
      final net = await network(3);
      await net.connect(['p0', 'p1']);
      final observer = net.peers['p2']!;
      net.blockedLinks.addAll([
        ('p0', 'p2'),
        ('p1', 'p2'),
        ('p2', 'p0'),
        ('p2', 'p1'),
      ]);
      await net.advance(const Duration(seconds: 3));
      expect(observer.service.roomFor('group')!.term, 0);
      expect(observer.service.roomFor('group')!.coordinator, 'p0');
      await net.advance(const Duration(seconds: 14));
      expect(observer.service.roomFor('group'), isNull);
      net.blockedLinks.clear();
      await net.advance(const Duration(seconds: 6));
      expect(observer.service.roomFor('group'), isNotNull);
      await observer.service.join('group');
      await net.flush();
      expect(observer.service.active!.connected, true);
      await net.peers['p0']!.service.sendAudio(Uint8List.fromList([7]));
      await net.flush();
      expect(observer.media.played.single.$3, [7]);
    },
  );

  test(
    'starter leaves and rejoins in the new authority term without another join',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      final starter = net.peers['p0']!;
      await starter.service.leave();
      await net.flush();
      await starter.service.join('group');
      await net.flush();
      expect(starter.service.active!.connected, true);
      expect(starter.service.active!.coordinator, 'p1');
      for (final peer in net.peers.values) {
        expect(peer.service.active!.participants, hasLength(3));
        await peer.service.sendAudio(Uint8List.fromList([4]));
      }
      await net.flush();
      for (final peer in net.peers.values) {
        expect(peer.media.played, hasLength(2));
      }
    },
  );

  test('stalled key sends cannot delay mute, PTT release or leave', () async {
    final net = await network(3);
    await net.connect(['p0', 'p1']);
    final gate = Completer<void>();
    net.signalGates[('p0', 'p1', 'key')] = gate.future;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final local = net.peers['p0']!;
    await local.service.setPushToTalk(true, held: true);
    await net.peers['p2']!.service.join('group');
    await net.flush();
    expect(
      net.signals
          .lastWhere((s) => s.$2 == 'p1' && s.$3.action == 'key')
          .$3
          .payload['epoch'],
      3,
    );
    net.datagrams.clear();
    final release = local.service.setPushToTalk(true);
    // The privacy gate applies in this synchronous turn, before awaiting it.
    expect(local.service.active!.microphoneMuted, true);
    await local.service.sendAudio(Uint8List.fromList([1]));
    await release.timeout(const Duration(seconds: 1));
    expect(net.datagrams, isEmpty);
    await local.service.setPushToTalk(true, held: true);
    final mute = local.service.setMuted(true);
    expect(local.service.active!.microphoneMuted, true);
    await local.service.sendAudio(Uint8List.fromList([2]));
    await mute.timeout(const Duration(seconds: 1));
    expect(net.datagrams, isEmpty);
    await local.service.setMuted(false);
    final leave = local.service.leave();
    await local.service.sendAudio(Uint8List.fromList([3]));
    await leave.timeout(const Duration(seconds: 1));
    expect(net.datagrams, isEmpty);
    expect(local.media.opened, false);
    // Repeated controls cannot queue more sends behind the stalled route.
    await net.advance(const Duration(seconds: 3));
    gate.complete();
    await net.flush();
  });

  test(
    'lost leave controls still permit immediate audio after rejoining',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      final sender = net.peers['p1']!;
      final receiver = net.peers['p2']!;
      receiver.media.enforceJitterSequences = true;
      for (var i = 0; i < 70; i++) {
        await sender.service.sendAudio(Uint8List.fromList([4]));
        await net.flush();
      }
      final oldSequence = sender.service.active!.outgoingAudioSequence;
      final generation = receiver.service.active!.participants
          .singleWhere((p) => p.deviceId == 'p1')
          .version;
      net.droppedSignals.addAll([('p1', 'p0', 'leave'), ('p1', 'p2', 'leave')]);
      await sender.service.leave();
      await net.flush();
      await sender.service.join('group');
      await net.flush();
      expect(sender.service.active!.outgoingAudioSequence, oldSequence);
      expect(
        receiver.service.active!.participants
            .singleWhere((p) => p.deviceId == 'p1')
            .version,
        greaterThan(generation),
      );
      receiver.media.played.clear();
      await sender.service.sendAudio(Uint8List.fromList([5]));
      await net.flush();
      expect(receiver.media.played.single.$3, [5]);
    },
  );

  test(
    'fresh sender admission resets retained receiver jitter state',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      final sender = net.peers['p1']!;
      final receiver = net.peers['p2']!;
      receiver.media.enforceJitterSequences = true;
      for (var i = 0; i < 30; i++) {
        await sender.service.sendAudio(Uint8List.fromList([4]));
        await net.flush();
      }
      net.droppedSignals.addAll([('p1', 'p0', 'leave'), ('p1', 'p2', 'leave')]);
      await sender.service.leave();
      await net.flush();
      // A restarted capture/session cannot preserve its previous audio counter.
      sender.service.roomFor('group')!.outgoingAudioSequence = 0;
      await sender.service.join('group');
      await net.flush();
      receiver.media.played.clear();
      await sender.service.sendAudio(Uint8List.fromList([6]));
      await net.flush();
      expect(receiver.media.played.single.$3, [6]);
    },
  );

  test('late call discovery recovers a missed initial start', () async {
    final net = await network(3);
    net.droppedSignals.add(('p0', 'p2', 'start'));
    await net.connect(['p0', 'p1']);
    expect(net.peers['p2']!.service.roomFor('group'), isNull);
    await net.advance(const Duration(seconds: 20));
    net.droppedSignals.clear();
    await net.advance(const Duration(seconds: 6));
    expect(
      net.peers['p2']!.service.roomFor('group')!.participants,
      hasLength(2),
    );
    await net.peers['p2']!.service.join('group');
    await net.flush();
    expect(net.peers['p2']!.service.active!.connected, true);
    await net.peers['p0']!.service.sendAudio(Uint8List.fromList([9]));
    await net.flush();
    expect(net.peers['p2']!.media.played.single.$3, [9]);
  });

  test('terminal call identities are scoped to their group', () async {
    final net = await network(2);
    final room = await net.peers['p0']!.service.start('group');
    await net.flush();
    final fake = await discovery(net, 'other', callId: room.callId);
    final receiver = net.peers['p1']!;
    expect(
      await receiver.service.receiveSignal(fake, authenticatedSender: 'p0'),
      true,
    );
    expect(
      await receiver.service.receiveSignal(
        GroupCallSignal(
          groupId: 'other',
          callId: room.callId,
          senderDeviceId: 'p0',
          action: 'leave',
          issuedAt: net.time,
          payload: {'epoch': 1, 'term': 0},
        ),
        authenticatedSender: 'p0',
      ),
      true,
    );
    await receiver.service.join('group');
    await net.flush();
    expect(receiver.service.active!.connected, true);
    await net.peers['p0']!.service.sendAudio(Uint8List.fromList([1]));
    await net.flush();
    expect(receiver.media.played.single.$3, [1]);
  });

  test(
    'old in-flight audio cannot poison a new admission while its key is pending',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      final receiver = net.peers['p2']!;
      final sender = net.peers['p1']!;
      final room = receiver.service.active!;
      receiver.media.enforceJitterSequences = true;
      room.forwarder = 'p2';
      final payload = Uint8List.fromList([0, 0, 0, 0, 0, 8]);
      ByteData.sublistView(payload).setUint32(1, 700, Endian.big);
      final old = await sender.service.active!.cipher.encrypt(payload);
      final gate = Completer<void>();
      net.verificationGates[('p2', 'p1')] = gate.future;
      final receiving = receiver.service.receiveDatagram('group', 'p1', old!);
      await Future<void>.delayed(Duration.zero);
      final roster = room.participants
          .map(
            (p) => p.deviceId == 'p1'
                ? GroupCallParticipant(p.deviceId, p.index, p.version + 1)
                : p,
          )
          .toList();
      final proposed = <String, dynamic>{
        'coordinator': 'p0',
        'term': room.term,
        'epoch': room.epoch + 1,
        'version': room.version + 1,
        'participants': roster.map((p) => p.toJson()).toList(),
      };
      GroupCallSignal signal(String action, Map<String, dynamic> body) =>
          GroupCallSignal(
            groupId: 'group',
            callId: room.callId,
            senderDeviceId: 'p0',
            action: action,
            issuedAt: net.time,
            payload: body,
          );
      expect(
        await receiver.service.receiveSignal(
          signal('roster', proposed),
          authenticatedSender: 'p0',
        ),
        true,
      );
      expect(room.connected, false);
      gate.complete();
      await receiving;
      expect(receiver.media.played, isEmpty);
      expect(
        net.datagrams,
        isEmpty,
        reason: 'Never forward an obsolete admission',
      );
      net.verificationGates.clear();
      final key = GroupCallCipher.randomKey();
      expect(
        await receiver.service.receiveSignal(
          signal('key', {
            ...proposed,
            'recipient': 'p2',
            'admission': room.admission,
            'key': base64Encode(key),
          }),
          authenticatedSender: 'p0',
        ),
        true,
      );
      final restarted = GroupCallCipher(
        groupId: 'group',
        callId: room.callId,
        localDeviceId: 'p1',
        sign: sender.service.sign,
        verify: sender.service.verify,
        now: () => net.time,
        authority: room.cipher.authority,
      );
      addTearDown(restarted.close);
      await restarted.install(room.epoch, key, roster);
      final fresh = await restarted.encrypt(
        Uint8List.fromList([0, 0, 0, 0, 1, 9]),
      );
      await receiver.service.receiveDatagram('group', 'p1', fresh!);
      expect(receiver.media.played.single.$2, 1);
      expect(receiver.media.played.single.$3, [9]);
    },
  );

  test(
    'muting discards audio already waiting for its sender signature',
    () async {
      final net = await network(2);
      await net.connect(net.peers.keys);
      final gate = Completer<void>();
      net.signingGates['p0'] = gate.future;
      final sending = net.peers['p0']!.service.sendAudio(
        Uint8List.fromList([9]),
      );
      await Future<void>.delayed(Duration.zero);
      await net.peers['p0']!.service.setMuted(true);
      gate.complete();
      await sending;
      await net.flush();
      expect(net.datagrams, isEmpty);
      expect(net.peers['p1']!.media.played, isEmpty);
    },
  );

  test(
    'discovery cannot forge another starter or another call identity',
    () async {
      final net = await network(2);
      final valid = await discovery(net, 'group');
      for (final invalid in [
        GroupCallSignal(
          groupId: valid.groupId,
          callId: valid.callId,
          senderDeviceId: 'p0',
          action: 'start',
          issuedAt: net.time,
          payload: {...valid.payload, 'startedBy': 'p1'},
        ),
        GroupCallSignal(
          groupId: valid.groupId,
          callId: 'different_call',
          senderDeviceId: 'p0',
          action: 'start',
          issuedAt: net.time,
          payload: valid.payload,
        ),
      ]) {
        expect(
          await net.peers['p1']!.service.receiveSignal(
            invalid,
            authenticatedSender: 'p0',
          ),
          false,
        );
        expect(net.peers['p1']!.service.rooms, isEmpty);
        expect(net.incoming, isEmpty);
      }
    },
  );

  test(
    'rejected higher-term keys leave current authority and audio intact',
    () async {
      final net = await network(3);
      await net.connect(net.peers.keys);
      final receiver = net.peers['p0']!;
      final room = receiver.service.active!;
      final original = (room.term, room.coordinator, room.epoch, room.cipher);
      final proposed = {
        'term': room.term + 1,
        'coordinator': 'p1',
        'epoch': 1,
        'version': 1,
        'participants': room.participants.map((p) => p.toJson()).toList(),
        'recipient': 'p0',
        'admission': room.admission,
        'key': base64Encode(Uint8List(32)),
      };
      for (final payload in [
        {...proposed, 'recipient': 'p2'},
        {...proposed, 'key': List.filled(44, '!').join()},
        {...proposed, 'key': base64Encode(Uint8List(31))},
        {
          ...proposed,
          'participants': [const GroupCallParticipant('p1', 1).toJson()],
        },
      ]) {
        expect(
          await receiver.service.receiveSignal(
            GroupCallSignal(
              groupId: 'group',
              callId: room.callId,
              senderDeviceId: 'p1',
              action: 'key',
              issuedAt: net.time,
              payload: payload,
            ),
            authenticatedSender: 'p1',
          ),
          false,
        );
        expect((
          room.term,
          room.coordinator,
          room.epoch,
          room.cipher,
        ), original);
        expect(room.connected, true);
      }
      await net.peers['p1']!.service.sendAudio(Uint8List.fromList([4]));
      await net.flush();
      expect(receiver.media.played.single.$3, [4]);
    },
  );

  test(
    'start flood limits survive eviction across nine authorized groups',
    () async {
      final net = await network(2);
      final receiver = net.peers['p1']!.service;
      var accepted = 0;
      for (var i = 0; i < 27; i++) {
        final signal = await discovery(net, 'group${i % 9}', callId: 'call$i');
        if (await receiver.receiveSignal(signal, authenticatedSender: 'p0')) {
          accepted++;
        }
      }
      expect(accepted, 8);
      expect(net.incoming, hasLength(8));
      expect(receiver.rooms, hasLength(8));
      net.time = net.time.add(const Duration(seconds: 1));
      expect(
        await receiver.receiveSignal(
          await discovery(net, 'group8'),
          authenticatedSender: 'p0',
        ),
        true,
      );
      expect(receiver.rooms, hasLength(8));
    },
  );
}
