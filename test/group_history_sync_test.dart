import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_history_journal.dart';
import 'package:conest/src/group_history_sync.dart';
import 'package:conest/src/group_membership_history.dart';
import 'package:conest/src/models.dart';

void main() {
  late Directory directory;
  final keys = <String, SimpleKeyPair>{};
  final profiles = <String, GroupMemberProfile>{};
  final replicas = <String, GroupHistoryReplica>{};
  final previous = <String, GroupHistoryEvent>{};
  late GroupHistoryEvent root;
  var lamport = 0;
  final vaultKey = List<int>.generate(32, (index) => index);

  Future<GroupHistoryReplica> restore(String device) async {
    final journal = await GroupHistoryJournal.open(
      file: File('${directory.path}/$device.journal'),
      key: vaultKey,
      groupId: 'group',
    );
    final replica = await GroupHistoryReplica.restore(
      journal: journal,
      groupId: 'group',
      localDeviceId: device,
      trustedOwner: profiles['a']!,
    );
    replicas[device] = replica;
    return replica;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('conest-history-sync-');
    previous.clear();
    replicas.clear();
    lamport = 1;
    for (final device in ['a', 'b', 'c', 'd']) {
      final key = await Ed25519().newKeyPair();
      keys[device] = key;
      final public = (await key.extractPublicKey()).bytes;
      profiles[device] = GroupMemberProfile(
        accountId: 'account-$device',
        deviceId: device,
        displayName: device,
        bio: '',
        relayCapable: false,
        publicKeyBase64: base64Encode(
          List<int>.filled(32, device.codeUnitAt(0)),
        ),
        signingPublicKeyBase64: base64Encode(public),
        irohEndpointId: public
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
        routeHints: [],
      );
    }
    final snapshot = GroupRecord(
      groupId: 'group',
      title: 'Group',
      ownerDeviceId: 'a',
      adminDeviceIds: [],
      memberDeviceIds: ['a', 'b', 'c', 'd'],
      removedDeviceIds: [],
      memberProfiles: profiles.values.toList(),
      membershipVersion: 1,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    root = await GroupHistoryEvent.sign(
      groupId: 'group',
      authorAccountId: 'account-a',
      authorDeviceId: 'a',
      keyPair: keys['a']!,
      sequence: 1,
      previousEventId: null,
      lamport: 1,
      membershipId: GroupMembershipRecord.rootReference(
        'group',
        profiles['a']!.signingPublicKeyBase64!,
      ),
      kind: GroupEventKind.membership,
      payload: GroupMembershipRecord.payload(
        group: snapshot,
        parents: [],
        historyVisibility: GroupHistoryVisibility.allRetained,
        admissions: {'a': null, 'b': null, 'c': null, 'd': null},
      ),
    );
    previous['a'] = root;
    for (final device in ['a', 'b', 'c', 'd']) {
      final replica = await restore(device);
      await replica.importMembership(root);
    }
  });
  tearDown(() async {
    for (final replica in replicas.values) {
      await replica.journal.close();
    }
    await directory.delete(recursive: true);
  });

  Future<GroupHistoryEvent> send(String device) async {
    final last = previous[device];
    final event = await GroupHistoryEvent.sign(
      groupId: 'group',
      authorAccountId: 'account-$device',
      authorDeviceId: device,
      keyPair: keys[device]!,
      sequence: (last?.sequence ?? 0) + 1,
      previousEventId: last?.eventId,
      lamport: ++lamport,
      membershipId: root.eventId,
      kind: GroupEventKind.message,
      payload: {'text': 'Message from $device at $lamport'},
    );
    await replicas[device]!.importEvent(event, carrierDeviceId: device);
    previous[device] = event;
    return event;
  }

  Future<Set<String>> messages(String device) async {
    final result = <String>{};
    String? cursor;
    while (true) {
      final page = await replicas[device]!.journal.readPage(
        beforeEventId: cursor,
      );
      if (page.isEmpty) break;
      result.addAll(
        page
            .where((event) => event.kind == GroupEventKind.message)
            .map((event) => event.eventId),
      );
      cursor = page.last.eventId;
    }
    return result;
  }

  test(
    'A/B history reaches C, then C carries it to D without either author',
    () async {
      final a = await send('a');
      await replicas['b']!.pullFrom(replicas['a']!, carrierDeviceId: 'a');
      final b = await send('b');
      await replicas['a']!.pullFrom(replicas['b']!, carrierDeviceId: 'b');
      expect(
        await replicas['c']!.pullFrom(replicas['b']!, carrierDeviceId: 'b'),
        2,
      );
      expect(
        await replicas['d']!.pullFrom(replicas['c']!, carrierDeviceId: 'c'),
        2,
      );
      expect(await messages('d'), {a.eventId, b.eventId});
      expect(
        await replicas['d']!.pullFrom(replicas['c']!, carrierDeviceId: 'c'),
        0,
      );
    },
  );

  test(
    'independent partitions converge and remain deduplicated after restart',
    () async {
      await send('a');
      await send('b');
      await send('c');
      await send('d');
      await replicas['b']!.pullFrom(replicas['a']!, carrierDeviceId: 'a');
      await replicas['d']!.pullFrom(replicas['c']!, carrierDeviceId: 'c');
      await replicas['b']!.pullFrom(replicas['d']!, carrierDeviceId: 'd');
      for (final device in ['a', 'c', 'd']) {
        await replicas[device]!.pullFrom(replicas['b']!, carrierDeviceId: 'b');
      }
      await replicas['c']!.journal.close();
      await restore('c');
      expect(
        await replicas['c']!.pullFrom(replicas['d']!, carrierDeviceId: 'd'),
        0,
      );
      for (final device in ['a', 'b', 'c', 'd']) {
        expect(await messages(device), await messages('a'));
      }
      expect((await messages('a')).length, 4);
    },
  );

  test(
    'interrupted catch-up resumes after restart without requesting durable events again',
    () async {
      for (var index = 0; index < 70; index++) {
        await send('a');
      }
      final flaky = _InterruptedPeer(replicas['a']!, failRequest: 2);
      await expectLater(
        replicas['b']!.pullFrom(flaky, carrierDeviceId: 'a'),
        throwsStateError,
      );
      final retained = await messages('b');
      expect(retained, isNotEmpty);
      expect(retained.length, lessThan(70));
      await replicas['b']!.journal.close();
      await restore('b');
      final resumed = _InterruptedPeer(replicas['a']!);
      await replicas['b']!.pullFrom(resumed, carrierDeviceId: 'a');
      expect(resumed.requested.intersection(retained), isEmpty);
      expect(await messages('b'), await messages('a'));
    },
  );

  test(
    'one-page work budgets continue across restarts using encrypted cursors',
    () async {
      for (var index = 0; index < 40; index++) {
        await send('a');
      }
      var completed = false;
      for (var attempt = 0; attempt < 12; attempt++) {
        try {
          await replicas['b']!.pullFrom(
            replicas['a']!,
            carrierDeviceId: 'a',
            maxPages: 1,
          );
          completed = true;
          break;
        } on StateError catch (error) {
          expect(error.message, contains('work budget'));
        }
        final progress = await replicas['b']!.journal.syncProgress('a');
        expect(progress, isNotEmpty);
        final bytes = await File(
          '${directory.path}/b.journal.sync',
        ).readAsBytes();
        expect(
          utf8.decode(bytes, allowMalformed: true),
          isNot(contains(root.eventId)),
        );
        await replicas['b']!.journal.close();
        await restore('b');
        expect(await replicas['b']!.journal.syncProgress('a'), progress);
      }
      expect(completed, isTrue);
      expect(await messages('b'), await messages('a'));
      expect(await replicas['b']!.journal.syncProgress('a'), isEmpty);
    },
  );

  test(
    'bounded partial responses complete without treating the provider as missing',
    () async {
      for (var index = 0; index < 5; index++) {
        await send('a');
      }
      final peer = _InterruptedPeer(replicas['a']!, takeAtMost: 1);
      expect(await replicas['b']!.pullFrom(peer, carrierDeviceId: 'a'), 5);
      expect(peer.requests, 5);
      expect(await messages('b'), await messages('a'));
    },
  );

  test(
    'failed membership persistence cannot publish the candidate authority',
    () async {
      final group = GroupMembershipRecord.fromEvent(
        root,
      ).group.copyWith(title: 'Changed', membershipVersion: 2);
      final proof = await GroupHistoryEvent.sign(
        groupId: 'group',
        authorAccountId: 'account-a',
        authorDeviceId: 'a',
        keyPair: keys['a']!,
        sequence: 2,
        previousEventId: root.eventId,
        lamport: 2,
        membershipId: root.eventId,
        kind: GroupEventKind.membership,
        payload: GroupMembershipRecord.payload(
          group: group,
          parents: [root.eventId],
          historyVisibility: GroupHistoryVisibility.allRetained,
          admissions: {
            for (final device in ['a', 'b', 'c', 'd']) device: root.eventId,
          },
        ),
      );
      await replicas['b']!.journal.close();
      await expectLater(
        replicas['b']!.importMembership(proof),
        throwsStateError,
      );
      expect(replicas['b']!.membership.current!.id, root.eventId);
    },
  );
}

class _InterruptedPeer implements GroupHistoryExchange {
  _InterruptedPeer(this.delegate, {this.failRequest, this.takeAtMost});
  final GroupHistoryExchange delegate;
  final int? failRequest;
  final int? takeAtMost;
  var requests = 0;
  final requested = <String>{};

  @override
  Future<List<GroupHistoryEvent>> membershipPage(
    String requesterDeviceId, {
    String? afterEventId,
  }) => delegate.membershipPage(requesterDeviceId, afterEventId: afterEventId);
  @override
  Future<GroupSyncInventory> inventory(
    String requesterDeviceId, {
    GroupSyncCursor? cursor,
  }) => delegate.inventory(requesterDeviceId, cursor: cursor);
  @override
  Future<List<GroupHistoryEvent>> events(
    String requesterDeviceId,
    List<String> ids,
  ) async {
    if (++requests == failRequest) throw StateError('Simulated link loss.');
    requested.addAll(ids);
    final result = await delegate.events(requesterDeviceId, ids);
    return takeAtMost == null ? result : result.take(takeAtMost!).toList();
  }
}
