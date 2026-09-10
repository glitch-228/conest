import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_history_journal.dart';

void main() {
  late SimpleKeyPair alice;
  late SimpleKeyPair bob;
  late String aliceKey;
  late Directory root;
  late File file;
  final vaultKey = List<int>.generate(32, (index) => index);
  final membership = hashes.sha256
      .convert(utf8.encode('membership'))
      .toString();

  setUp(() async {
    alice = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, 1));
    bob = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, 2));
    aliceKey = base64Encode((await alice.extractPublicKey()).bytes);
    root = await Directory.systemTemp.createTemp('conest-group-history-');
    file = File('${root.path}/history.journal');
  });
  tearDown(() => root.delete(recursive: true));

  Future<GroupHistoryEvent> event({
    String author = 'alice',
    int sequence = 1,
    GroupHistoryEvent? previous,
    int? lamport,
    String group = 'group-1',
    Map<String, Object?>? payload,
  }) => GroupHistoryEvent.sign(
    groupId: group,
    authorAccountId: 'account-$author',
    authorDeviceId: author,
    keyPair: author == 'alice' ? alice : bob,
    sequence: sequence,
    previousEventId: previous?.eventId,
    lamport: lamport ?? sequence,
    membershipId: membership,
    kind: GroupEventKind.message,
    payload: payload ?? {'text': 'Private message $sequence'},
  );

  Future<bool> verify(GroupHistoryEvent event) => event.verify(
    expectedGroupId: 'group-1',
    expectedAccountId: 'account-alice',
    expectedDeviceId: 'alice',
    expectedSigningKeyBase64: aliceKey,
  );

  Future<GroupHistoryJournal> open({
    List<int>? key,
    String group = 'group-1',
  }) => GroupHistoryJournal.open(
    file: file,
    key: key ?? vaultKey,
    groupId: group,
  );

  test(
    'forwarded events retain authorship and canonical nested payloads',
    () async {
      final original = await event(
        payload: {
          'text': 'Hello',
          'reply': {'id': 'message-a', 'author': 'bob'},
        },
      );
      final reordered = await event(
        payload: {
          'reply': {'author': 'bob', 'id': 'message-a'},
          'text': 'Hello',
        },
      );
      expect(reordered.eventId, original.eventId);
      expect(reordered.signatureBase64, original.signatureBase64);
      final carried = GroupHistoryEvent.decode(original.encode());
      expect(await verify(carried), isTrue);
      expect(await verify(await event(author: 'bob')), isFalse);
      expect(
        await carried.verify(
          expectedGroupId: 'another-group',
          expectedAccountId: 'account-alice',
          expectedDeviceId: 'alice',
          expectedSigningKeyBase64: aliceKey,
        ),
        isFalse,
      );
    },
  );

  test(
    'payload is immutable after signing, including nested containers',
    () async {
      final nested = <String, Object?>{'text': 'Original'};
      final original = await event(
        payload: {
          'items': [nested],
        },
      );
      nested['text'] = 'Changed';
      expect(
        ((original.payload['items'] as List).single as Map)['text'],
        'Original',
      );
      expect(
        () => original.payload['text'] = 'Changed',
        throwsUnsupportedError,
      );
      expect(
        () => (original.payload['items'] as List).add('Changed'),
        throwsUnsupportedError,
      );
      expect(await verify(original), isTrue);
    },
  );

  test(
    'tampering cannot be hidden by recomputing the content digest',
    () async {
      final original = await event();
      final json = original.toJson();
      json['payload'] = {'text': 'Forged text'};
      expect(
        () => GroupHistoryEvent.decode(jsonEncode(json)),
        throwsFormatException,
      );
      // Recompute the canonical digest while retaining the original signature.
      final body = Map<String, Object?>.of(json)
        ..remove('eventId')
        ..remove('signatureBase64');
      Object? canonical(Object? value) {
        if (value is Map<String, Object?>) {
          final keys = value.keys.toList()..sort();
          return {for (final key in keys) key: canonical(value[key])};
        }
        if (value is List) return value.map(canonical).toList();
        return value;
      }

      json['eventId'] = hashes.sha256
          .convert(
            utf8.encode(
              'conest.group-event.v1\n${jsonEncode(canonical(body))}',
            ),
          )
          .toString();
      final forged = GroupHistoryEvent.decode(jsonEncode(json));
      expect(await verify(forged), isFalse);
      final journal = await open();
      try {
        await expectLater(journal.append(forged), throwsStateError);
        expect(await journal.readPage(), isEmpty);
      } finally {
        await journal.close();
      }
    },
  );

  test('wire version, counters, payload size and depth are bounded', () async {
    final original = await event();
    expect(
      () => GroupHistoryEvent.decode(
        jsonEncode({...original.toJson(), 'version': 2}),
      ),
      throwsFormatException,
    );
    await expectLater(event(sequence: 0), throwsFormatException);
    await expectLater(event(sequence: 2), throwsFormatException);
    await expectLater(
      event(lamport: groupEventMaxCounter + 1),
      throwsFormatException,
    );
    await expectLater(event(payload: {'float': 1.5}), throwsFormatException);
    await expectLater(
      event(payload: {'text': 'x' * groupEventMaxBytes}),
      throwsFormatException,
    );
    Object? nested = 'text';
    for (var i = 0; i < 20; i++) {
      nested = [nested];
    }
    await expectLater(
      event(payload: {'nested': nested}),
      throwsFormatException,
    );
  });

  test(
    'partitions converge with reordered duplicate arrivals and restart',
    () async {
      final a1 = await event();
      final a2 = await event(sequence: 2, previous: a1, lamport: 4);
      final b1 = await event(author: 'bob', lamport: 2);
      final b2 = await event(
        author: 'bob',
        sequence: 2,
        previous: b1,
        lamport: 4,
      );
      final otherFile = File('${root.path}/other.journal');
      var left = await open();
      final right = await GroupHistoryJournal.open(
        file: otherFile,
        key: vaultKey,
        groupId: 'group-1',
      );
      try {
        await Future.wait([
          left.append(a2),
          left.append(a1),
          left.append(b2),
          left.append(b1),
        ]);
        for (final value in [b1, a1, b2, a2]) {
          await right.append(value);
        }
        expect(await left.append(a1), isFalse);
        final before = await file.readAsBytes();
        await left.close();
        left = await open();
        expect(await left.append(a2), isFalse);
        expect(await file.readAsBytes(), before);
        final leftIds = (await left.readPage())
            .map((value) => value.eventId)
            .toList();
        expect(
          leftIds,
          (await right.readPage()).map((value) => value.eventId).toList(),
        );
        expect(leftIds, [b2.eventId, a2.eventId, b1.eventId, a1.eventId]);
        expect(await left.rangesForAuthor('alice'), [(start: 1, end: 2)]);
        expect(await left.authors(limit: 1), ['alice']);
        expect(await left.authors(after: 'alice'), ['bob']);
        expect(
          utf8.decode(before, allowMalformed: true),
          isNot(contains('Private message')),
        );
        expect(
          utf8.decode(before, allowMalformed: true),
          isNot(contains('account-alice')),
        );
      } finally {
        await left.close();
        await right.close();
      }
    },
  );

  test('inventory gaps and page anchors survive late older history', () async {
    final a1 = await event();
    final a2 = await event(sequence: 2, previous: a1);
    final a3 = await event(sequence: 3, previous: a2);
    final journal = await open();
    try {
      await journal.append(a3);
      await journal.append(a1);
      expect(await journal.rangesForAuthor('alice'), [
        (start: 1, end: 1),
        (start: 3, end: 3),
      ]);
      expect(await journal.rangesForAuthor('alice', limit: 1), [
        (start: 1, end: 1),
      ]);
      expect(await journal.rangesForAuthor('alice', afterSequence: 1), [
        (start: 3, end: 3),
      ]);
      final page = await journal.readPage(limit: 1);
      await journal.append(a2);
      expect(
        (await journal.readPage(
          beforeEventId: page.single.eventId,
        )).map((value) => value.eventId),
        [a2.eventId, a1.eventId],
      );
      expect(
        (await journal.readAuthorRange(
          'alice',
          start: 2,
          end: 3,
          limit: 1,
        )).single.eventId,
        a2.eventId,
      );
      expect(await journal.rangesForAuthor('alice'), [(start: 1, end: 3)]);
      await expectLater(journal.readPage(limit: 129), throwsStateError);
      await expectLater(
        journal.readPage(beforeEventId: 'unknown'),
        throwsStateError,
      );
    } finally {
      await journal.close();
    }
  });

  test(
    'source message IDs are scoped by author and cannot rewrite signed messages',
    () async {
      final a1 = await event(
        payload: {'messageId': 'shared-id', 'body': 'Alice'},
      );
      final b1 = await event(
        author: 'bob',
        payload: {'messageId': 'shared-id', 'body': 'Bob'},
      );
      final replacement = await event(
        sequence: 2,
        previous: a1,
        payload: {'messageId': 'shared-id', 'body': 'Replacement'},
      );
      final journal = await open();
      try {
        await journal.append(a1);
        await journal.append(b1);
        await expectLater(journal.append(replacement), throwsStateError);
        expect(
          (await journal.sourceMessage('alice', 'shared-id'))!.eventId,
          a1.eventId,
        );
        expect(
          (await journal.sourceMessage('bob', 'shared-id'))!.eventId,
          b1.eventId,
        );
        expect((await journal.authorHead('alice'))!.eventId, a1.eventId);
      } finally {
        await journal.close();
      }
    },
  );

  test(
    'same-author forks and contradictory predecessors are rejected',
    () async {
      final a1 = await event();
      final fork = await event(payload: {'text': 'Fork'});
      final a2 = await event(sequence: 2, previous: a1);
      final journal = await open();
      try {
        await journal.append(a2);
        await expectLater(journal.append(fork), throwsStateError);
        await journal.append(a1);
        await expectLater(journal.append(fork), throwsStateError);
        expect((await journal.readPage()).length, 2);
        await expectLater(
          journal.append(await event(group: 'another-group')),
          throwsStateError,
        );
      } finally {
        await journal.close();
      }
    },
  );

  for (final partialHeader in [false, true]) {
    test(
      'restart recovers only a torn last frame header=$partialHeader',
      () async {
        final a1 = await event();
        final a2 = await event(sequence: 2, previous: a1);
        var journal = await open();
        await journal.append(a1);
        await journal.close();
        final original = await file.readAsBytes();
        final fragment = partialHeader
            ? [0, 0]
            : [
                ...(ByteData(4)..setUint32(0, 100)).buffer.asUint8List(),
                1,
                2,
                3,
              ];
        await file.writeAsBytes(fragment, mode: FileMode.append, flush: true);
        journal = await open();
        try {
          expect(await file.readAsBytes(), original);
          await journal.append(a2);
          expect((await journal.readPage()).map((value) => value.eventId), [
            a2.eventId,
            a1.eventId,
          ]);
        } finally {
          await journal.close();
        }
      },
    );
  }

  test(
    'wrong key, cross-group replay and complete corruption never erase history',
    () async {
      final journal = await open();
      await journal.append(await event());
      await journal.close();
      final original = await file.readAsBytes();
      await expectLater(
        open(key: List<int>.filled(32, 9)),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        open(group: 'another-group'),
        throwsA(isA<Exception>()),
      );
      expect(await file.readAsBytes(), original);
      final corrupt = Uint8List.fromList(original)..[original.length - 1] ^= 1;
      await file.writeAsBytes(corrupt, flush: true);
      await expectLater(open(), throwsA(isA<Exception>()));
      expect(await file.readAsBytes(), corrupt);
    },
  );

  test(
    'closing rejects late operations without losing queued appends',
    () async {
      final journal = await open();
      final a1 = await event();
      final pending = journal.append(a1);
      final closed = journal.close();
      await expectLater(journal.append(a1), throwsStateError);
      expect(await pending, isTrue);
      await closed;
      final reopened = await open();
      try {
        expect((await reopened.readPage()).single.eventId, a1.eventId);
      } finally {
        await reopened.close();
      }
    },
  );

  test(
    'a second local worker cannot append with a stale journal index',
    () async {
      final journal = await open();
      try {
        await expectLater(open(), throwsStateError);
        await journal.append(await event());
      } finally {
        await journal.close();
      }
      final reopened = await open();
      await reopened.close();
    },
  );

  test(
    'payload page budget preserves the continuation without skipping events',
    () async {
      final journal = await open();
      try {
        GroupHistoryEvent? previous;
        for (var sequence = 1; sequence <= 12; sequence++) {
          final next = await event(
            sequence: sequence,
            previous: previous,
            payload: {'text': 'x' * (110 * 1024)},
          );
          await journal.append(next);
          previous = next;
        }
        final page = await journal.readPage(limit: 128);
        expect(page.length, allOf(greaterThan(0), lessThan(12)));
        expect(
          page.fold<int>(
            0,
            (bytes, event) => bytes + utf8.encode(event.encode()).length,
          ),
          lessThanOrEqualTo(1024 * 1024),
        );
        final rest = await journal.readPage(beforeEventId: page.last.eventId);
        expect(
          [...page, ...rest].map((event) => event.sequence),
          List.generate(12, (index) => 12 - index),
        );
      } finally {
        await journal.close();
      }
    },
  );
}
