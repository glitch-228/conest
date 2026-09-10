import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_membership_history.dart';
import 'package:conest/src/models.dart';

void main() {
  final keys = <String, SimpleKeyPair>{};
  final profiles = <String, GroupMemberProfile>{};
  final previous = <String, GroupHistoryEvent>{};
  var lamport = 0;
  final epoch = DateTime.utc(2026, 9, 10);

  setUp(() async {
    previous.clear();
    lamport = 0;
    for (final name in ['alice', 'bob', 'carol', 'dave', 'eve']) {
      final key = await Ed25519().newKeyPair();
      final signing = (await key.extractPublicKey()).bytes;
      keys[name] = key;
      profiles[name] = GroupMemberProfile(
        accountId: 'account-$name',
        deviceId: name,
        displayName: name,
        bio: '',
        relayCapable: false,
        publicKeyBase64: base64Encode(
          (await (await X25519().newKeyPair()).extractPublicKey()).bytes,
        ),
        signingPublicKeyBase64: base64Encode(signing),
        irohEndpointId: signing
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
        routeHints: [],
        capabilities: [TransportKind.iroh],
      );
    }
  });

  GroupMembershipHistory history() => GroupMembershipHistory(
    groupId: 'group-1',
    trustedOwner: profiles['alice']!,
  );

  Future<GroupHistoryEvent> signed({
    required String author,
    required String membershipId,
    required GroupEventKind kind,
    required Map<String, Object?> payload,
    String? signingAs,
  }) async {
    final prior = previous[author];
    final event = await GroupHistoryEvent.sign(
      groupId: 'group-1',
      authorAccountId: 'account-$author',
      authorDeviceId: author,
      keyPair: keys[signingAs ?? author]!,
      sequence: (prior?.sequence ?? 0) + 1,
      previousEventId: prior?.eventId,
      lamport: ++lamport,
      membershipId: membershipId,
      kind: kind,
      payload: payload,
    );
    previous[author] = event;
    return event;
  }

  Future<GroupMembershipRecord> membership({
    List<GroupMembershipRecord> parents = const [],
    String author = 'alice',
    String owner = 'alice',
    String title = 'Group',
    List<String> members = const ['alice', 'bob'],
    List<String> admins = const [],
    GroupHistoryVisibility? visibility,
    Map<String, String?>? admissions,
    Map<String, GroupHistoryCheckpoint> checkpoints = const {},
    Map<String, GroupMemberProfile> overrides = const {},
  }) async {
    final parentIds = parents.map((parent) => parent.id).toList()..sort();
    final automaticAdmissions = <String, String?>{};
    for (final member in members) {
      final earlier = parents
          .map((parent) => parent.admissions[member])
          .toSet();
      automaticAdmissions[member] =
          parents.isNotEmpty && earlier.length == 1 && !earlier.contains(null)
          ? earlier.single
          : null;
    }
    final group = GroupRecord(
      groupId: 'group-1',
      title: title,
      ownerDeviceId: owner,
      adminDeviceIds: admins,
      memberDeviceIds: members,
      removedDeviceIds: [],
      memberProfiles: members
          .map((member) => overrides[member] ?? profiles[member]!)
          .toList(),
      membershipVersion: parents.isEmpty
          ? 1
          : parents
                    .map((parent) => parent.group.membershipVersion)
                    .reduce((a, b) => a > b ? a : b) +
                1,
      createdAt: epoch,
      updatedAt: epoch,
    );
    return GroupMembershipRecord.fromEvent(
      await signed(
        author: author,
        membershipId: parentIds.isEmpty
            ? GroupMembershipRecord.rootReference(
                'group-1',
                profiles['alice']!.signingPublicKeyBase64!,
              )
            : parentIds.first,
        kind: GroupEventKind.membership,
        payload: GroupMembershipRecord.payload(
          group: group,
          parents: parentIds,
          historyVisibility:
              visibility ??
              (parents.isEmpty
                  ? GroupHistoryVisibility.allRetained
                  : parents.first.historyVisibility),
          admissions: admissions ?? automaticAdmissions,
          checkpoints: checkpoints,
        ),
      ),
    );
  }

  Future<GroupHistoryEvent> message(
    GroupMembershipRecord membership, {
    String author = 'alice',
    String? signingAs,
  }) => signed(
    author: author,
    membershipId: membership.id,
    kind: GroupEventKind.message,
    payload: {'text': 'Hello from $author'},
    signingAs: signingAs,
  );

  test(
    'approved owner anchors history and carriers preserve original authorship',
    () async {
      final index = history();
      final root = await membership(members: ['alice', 'bob', 'carol', 'dave']);
      expect(await index.import(root), GroupMembershipImport.accepted);
      final original = await message(root);
      expect(
        await index.canForward(
          original,
          carrierDeviceId: 'carol',
          recipientDeviceId: 'dave',
        ),
        isTrue,
      );
      expect(
        await index.canForward(
          original,
          carrierDeviceId: 'eve',
          recipientDeviceId: 'dave',
        ),
        isFalse,
      );
      expect(
        await index.canReceive(
          await message(root, signingAs: 'bob'),
          recipientDeviceId: 'carol',
        ),
        isFalse,
      );
      final strangerRoot = await membership(author: 'bob', owner: 'bob');
      await expectLater(history().import(strangerRoot), throwsFormatException);
    },
  );

  test(
    'missing membership dependencies retry and rebuild after restart',
    () async {
      final root = await membership();
      final addition = await membership(
        parents: [root],
        members: ['alice', 'bob', 'carol'],
      );
      final text = await message(root, author: 'bob');
      final index = history();
      expect(
        await index.import(addition),
        GroupMembershipImport.missingParents,
      );
      expect(index.heads, isEmpty);
      await index.import(root);
      await index.import(addition);
      expect(await index.import(addition), GroupMembershipImport.duplicate);
      expect(await index.canReceive(text, recipientDeviceId: 'carol'), isTrue);
      final restored = history();
      for (final record in [root, addition]) {
        await restored.import(
          GroupMembershipRecord.fromEvent(
            GroupHistoryEvent.decode(record.proof.encode()),
          ),
        );
      }
      expect(restored.heads, index.heads);
      expect(
        await restored.canReceive(text, recipientDeviceId: 'carol'),
        isTrue,
      );
    },
  );

  test(
    'history policy changes affect future admissions, never rewrite prior grants',
    () async {
      final index = history();
      final root = await membership();
      await index.import(root);
      final old = await message(root, author: 'bob');
      final restricted = await membership(
        parents: [root],
        members: ['alice', 'bob', 'carol'],
        visibility: GroupHistoryVisibility.sinceAdmission,
        checkpoints: {
          'bob': GroupHistoryCheckpoint(
            sequence: old.sequence,
            eventId: old.eventId,
          ),
        },
      );
      await index.import(restricted);
      expect(await index.canReceive(old, recipientDeviceId: 'bob'), isTrue);
      expect(await index.canReceive(old, recipientDeviceId: 'carol'), isFalse);
      // A concurrent old-epoch message remains outside Carol's admission even
      // when its counter is larger than the checkpoint the owner had seen.
      expect(
        await index.canReceive(
          await message(root, author: 'bob'),
          recipientDeviceId: 'carol',
        ),
        isFalse,
      );
      expect(
        await index.canReceive(
          await message(restricted, author: 'bob'),
          recipientDeviceId: 'carol',
        ),
        isTrue,
      );
      final publicAgain = await membership(
        parents: [restricted],
        members: ['alice', 'bob', 'carol', 'dave'],
        visibility: GroupHistoryVisibility.allRetained,
      );
      await index.import(publicAgain);
      expect(await index.canReceive(old, recipientDeviceId: 'dave'), isTrue);
      expect(await index.canReceive(old, recipientDeviceId: 'carol'), isFalse);
      final rewrite = await membership(
        parents: [publicAgain],
        members: ['alice', 'bob', 'carol', 'dave'],
        admissions: {...publicAgain.admissions, 'carol': null},
      );
      await expectLater(index.import(rewrite), throwsFormatException);
    },
  );

  test(
    'removal stops serving recipients while retaining authentic older authors',
    () async {
      final root = await membership(members: ['alice', 'bob', 'carol']);
      final old = await message(root, author: 'bob');
      final removed = await membership(
        parents: [root],
        members: ['alice', 'carol'],
      );
      final index = history();
      await index.import(root);
      await index.import(removed);
      expect(await index.canReceive(old, recipientDeviceId: 'bob'), isFalse);
      expect(
        await index.canForward(
          old,
          carrierDeviceId: 'bob',
          recipientDeviceId: 'carol',
        ),
        isFalse,
      );
      expect(
        await index.canForward(
          old,
          carrierDeviceId: 'alice',
          recipientDeviceId: 'carol',
        ),
        isTrue,
      );
      expect(
        await index.canReceive(
          await message(removed, author: 'bob'),
          recipientDeviceId: 'carol',
        ),
        isFalse,
      );
      final readmitted = await membership(
        parents: [removed],
        members: ['alice', 'bob', 'carol'],
        visibility: GroupHistoryVisibility.sinceAdmission,
      );
      await index.import(readmitted);
      expect(await index.canReceive(old, recipientDeviceId: 'bob'), isFalse);
      expect(
        await index.canReceive(
          await message(readmitted),
          recipientDeviceId: 'bob',
        ),
        isTrue,
      );
    },
  );

  test(
    'admins can manage ordinary members but cannot extend their authority',
    () async {
      final root = await membership(
        members: ['alice', 'bob', 'carol'],
        admins: ['bob'],
      );
      final index = history();
      await index.import(root);
      for (final invalid in [
        await membership(
          parents: [root],
          author: 'carol',
          members: ['alice', 'bob', 'carol'],
          admins: ['bob', 'carol'],
        ),
        await membership(
          parents: [root],
          author: 'bob',
          members: ['alice', 'bob', 'carol'],
          admins: ['bob'],
          visibility: GroupHistoryVisibility.sinceAdmission,
        ),
        await membership(
          parents: [root],
          author: 'bob',
          members: ['alice', 'bob', 'carol'],
          admins: ['bob', 'carol'],
        ),
        await membership(
          parents: [root],
          author: 'bob',
          owner: 'bob',
          members: ['alice', 'bob', 'carol'],
        ),
      ]) {
        await expectLater(index.import(invalid), throwsFormatException);
      }
      final allowed = await membership(
        parents: [root],
        author: 'bob',
        members: ['alice', 'bob', 'dave'],
        admins: ['bob'],
      );
      expect(await index.import(allowed), GroupMembershipImport.accepted);
    },
  );

  test(
    'partition membership conflicts freeze serving until owner resolution',
    () async {
      final root = await membership(
        members: ['alice', 'bob', 'carol', 'dave'],
        admins: ['bob', 'carol'],
      );
      final left = await membership(
        parents: [root],
        author: 'bob',
        members: ['alice', 'bob', 'carol'],
        admins: ['bob', 'carol'],
      );
      final right = await membership(
        parents: [root],
        author: 'carol',
        members: ['alice', 'bob', 'carol', 'dave', 'eve'],
        admins: ['bob', 'carol'],
      );
      final old = await message(root);
      final one = history();
      final two = history();
      for (final item in [root, left, right]) {
        await one.import(item);
      }
      for (final item in [root, right, left]) {
        await two.import(item);
      }
      expect(one.heads, two.heads);
      expect(one.hasConflict, isTrue);
      expect(await one.canReceive(old, recipientDeviceId: 'bob'), isFalse);
      final invalid = await membership(
        parents: [left, right],
        author: 'bob',
        members: ['alice', 'bob', 'carol'],
        admins: ['bob', 'carol'],
      );
      await expectLater(one.import(invalid), throwsFormatException);
      final resolved = await membership(
        parents: [left, right],
        members: ['alice', 'bob', 'carol', 'dave', 'eve'],
        admins: ['bob', 'carol'],
      );
      await one.import(resolved);
      await two.import(resolved);
      expect(one.hasConflict, isFalse);
      expect(one.heads, two.heads);
      expect(await one.canReceive(old, recipientDeviceId: 'eve'), isTrue);
    },
  );

  test(
    'conflicting owner handoff is resolved by the common ancestor owner',
    () async {
      final root = await membership();
      final handoff = await membership(parents: [root], owner: 'bob');
      final rename = await membership(parents: [root], title: 'Renamed');
      final resolved = await membership(
        parents: [handoff, rename],
        owner: 'bob',
        title: 'Renamed',
      );
      final index = history();
      for (final record in [root, handoff, rename, resolved]) {
        await index.import(record);
      }
      expect(index.current!.group.ownerDeviceId, 'bob');
      final bobUpdate = await membership(
        parents: [resolved],
        author: 'bob',
        owner: 'bob',
        title: 'By new owner',
      );
      await index.import(bobUpdate);
      expect(index.current!.group.title, 'By new owner');
    },
  );

  test(
    'even the owner cannot replace an existing pinned member identity',
    () async {
      final root = await membership();
      final index = history();
      await index.import(root);
      final replacement = profiles['bob']!.copyWith(
        signingPublicKeyBase64: profiles['eve']!.signingPublicKeyBase64,
        irohEndpointId: profiles['eve']!.irohEndpointId,
      );
      final changed = await membership(
        parents: [root],
        overrides: {'bob': replacement},
      );
      await expectLater(index.import(changed), throwsFormatException);
      expect(index.current!.id, root.id);
      // Mutating a returned legacy GroupRecord cannot alter the signed authority.
      index.current!.group.memberDeviceIds.clear();
      expect(index.current!.group.hasActiveMember('bob'), isTrue);
    },
  );
}
