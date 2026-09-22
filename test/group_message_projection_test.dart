import 'dart:io';

import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_history_journal.dart';
import 'package:conest/src/group_message_projection.dart';
import 'package:conest/src/models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'message tombstones persist while legacy messages default to visible',
    () {
      final message = ChatMessage(
        id: 'message',
        conversationId: 'group',
        senderDeviceId: 'alice',
        recipientDeviceId: 'group',
        body: 'original',
        outbound: true,
        state: DeliveryState.pending,
        createdAt: DateTime.utc(2026),
      );
      final deleted = message.copyWith(body: '', deleted: true);
      expect(ChatMessage.fromJson(deleted.toJson()).deleted, isTrue);
      expect(deleted.copyWith(state: DeliveryState.delivered).deleted, isTrue);
      expect(ChatMessage.fromJson(message.toJson()).deleted, isFalse);
    },
  );
  late SimpleKeyPair alice;
  late SimpleKeyPair bob;
  late GroupHistoryEvent original;
  final membership = 'a' * 64;

  Future<GroupHistoryEvent> mutation({
    required GroupHistoryEvent previous,
    GroupEventKind kind = GroupEventKind.edit,
    String author = 'alice',
    String? target,
    String body = 'Edited',
    String changedAt = '2026-09-15T12:00:00.000Z',
  }) => GroupHistoryEvent.sign(
    groupId: 'group',
    authorAccountId: 'account-$author',
    authorDeviceId: author,
    keyPair: author == 'alice' ? alice : bob,
    sequence: author == 'alice' ? previous.sequence + 1 : 1,
    previousEventId: author == 'alice' ? previous.eventId : null,
    lamport: previous.lamport + 1,
    membershipId: membership,
    kind: kind,
    payload: {
      'targetEventId': target ?? original.eventId,
      'changedAt': changedAt,
      if (kind == GroupEventKind.edit) 'body': body,
    },
  );

  setUp(() async {
    alice = await Ed25519().newKeyPairFromSeed(List.filled(32, 1));
    bob = await Ed25519().newKeyPairFromSeed(List.filled(32, 2));
    original = await GroupHistoryEvent.sign(
      groupId: 'group',
      authorAccountId: 'account-alice',
      authorDeviceId: 'alice',
      keyPair: alice,
      sequence: 1,
      previousEventId: null,
      lamport: 1,
      membershipId: membership,
      kind: GroupEventKind.message,
      payload: {'messageId': 'legacy-id', 'body': 'Original'},
    );
  });

  test('only original signed author can edit or delete the event', () async {
    final edit = await mutation(previous: original);
    final otherAuthor = await mutation(previous: edit, author: 'bob');
    final otherDeletion = await mutation(
      previous: edit,
      author: 'bob',
      kind: GroupEventKind.deletion,
    );
    final otherTarget = await mutation(previous: edit, target: 'b' * 64);
    final malformed = await mutation(previous: edit, changedAt: 'invalid');
    final result = GroupMessageProjection.reduce(original, [
      otherAuthor,
      otherDeletion,
      otherTarget,
      malformed,
      edit,
    ])!;
    expect(result.body, 'Edited');
    expect(result.deleted, isFalse);
    expect(result.edit?.eventId, edit.eventId);
  });

  test(
    'deletion dominates reordered, duplicate and later offline edits',
    () async {
      final edit = await mutation(previous: original);
      final deletion = await mutation(
        previous: edit,
        kind: GroupEventKind.deletion,
      );
      final laterEdit = await mutation(
        previous: deletion,
        body: 'Offline edit',
      );
      for (final events in [
        [edit, deletion, laterEdit],
        [laterEdit, deletion, edit, deletion, laterEdit],
        [deletion, laterEdit, edit],
      ]) {
        final result = GroupMessageProjection.reduce(original, events)!;
        expect(result.deleted, isTrue);
        expect(result.body, isEmpty);
        expect(result.deletion?.eventId, deletion.eventId);
      }
    },
  );

  test('edit order uses signed counters, not skewed wall clocks', () async {
    final first = await mutation(
      previous: original,
      body: 'First',
      changedAt: '2099-01-01T00:00:00Z',
    );
    final second = await mutation(
      previous: first,
      body: 'Second',
      changedAt: '2000-01-01T00:00:00Z',
    );
    expect(
      GroupMessageProjection.reduce(original, [second, first])!.body,
      'Second',
    );
  });

  test(
    'reactions are signed per actor, deterministic, and persist in messages',
    () async {
      final bobOn = await GroupHistoryEvent.sign(
        groupId: 'group',
        authorAccountId: 'account-bob',
        authorDeviceId: 'bob',
        keyPair: bob,
        sequence: 1,
        previousEventId: null,
        lamport: 2,
        membershipId: membership,
        kind: GroupEventKind.reaction,
        payload: {
          'targetEventId': original.eventId,
          'changedAt': '2026-09-15T12:00:00.000Z',
          'emoji': '👍',
          'active': true,
        },
      );
      final bobOff = await GroupHistoryEvent.sign(
        groupId: 'group',
        authorAccountId: 'account-bob',
        authorDeviceId: 'bob',
        keyPair: bob,
        sequence: 2,
        previousEventId: bobOn.eventId,
        lamport: 3,
        membershipId: membership,
        kind: GroupEventKind.reaction,
        payload: {
          'targetEventId': original.eventId,
          'changedAt': '2026-09-15T12:01:00.000Z',
          'emoji': '👍',
          'active': false,
        },
      );
      final aliceOn = await GroupHistoryEvent.sign(
        groupId: 'group',
        authorAccountId: 'account-alice',
        authorDeviceId: 'alice',
        keyPair: alice,
        sequence: 2,
        previousEventId: original.eventId,
        lamport: 4,
        membershipId: membership,
        kind: GroupEventKind.reaction,
        payload: {
          'targetEventId': original.eventId,
          'changedAt': '2026-09-15T12:02:00.000Z',
          'emoji': '👍',
          'active': true,
        },
      );
      final projection = GroupMessageProjection.reduce(original, [
        aliceOn,
        bobOff,
        bobOn,
      ])!;
      expect(projection.reactions, {
        '👍': {'alice'},
      });
      final message = ChatMessage(
        id: 'message',
        conversationId: 'group',
        senderDeviceId: 'alice',
        recipientDeviceId: 'group',
        body: 'hello',
        outbound: true,
        state: DeliveryState.delivered,
        createdAt: DateTime.utc(2026),
        reactions: projection.reactions,
      );
      expect(ChatMessage.fromJson(message.toJson()).reactions, {
        '👍': {'alice'},
      });
    },
  );

  test('mutation index survives restart and arrival before original', () async {
    final root = await Directory.systemTemp.createTemp('conest-mutations-');
    final file = File('${root.path}/history');
    Future<GroupHistoryJournal> open() => GroupHistoryJournal.open(
      file: file,
      key: List.filled(32, 3),
      groupId: 'group',
    );
    final edit = await mutation(previous: original);
    final deletion = await mutation(
      previous: edit,
      kind: GroupEventKind.deletion,
    );
    final malformed = await mutation(previous: deletion, changedAt: 'invalid');
    final otherAuthor = await mutation(previous: malformed, author: 'bob');
    var journal = await open();
    try {
      for (final event in [deletion, otherAuthor, malformed, edit, original]) {
        await journal.append(event);
      }
      expect(await journal.append(deletion), isFalse);
      await journal.close();
      journal = await open();
      final mutations = await journal.messageMutations(original);
      expect(mutations.map((event) => event.eventId).toSet(), {
        edit.eventId,
        deletion.eventId,
      });
      expect(
        GroupMessageProjection.reduce(original, mutations)!.deleted,
        isTrue,
      );
    } finally {
      await journal.close();
      await root.delete(recursive: true);
    }
  });
}
