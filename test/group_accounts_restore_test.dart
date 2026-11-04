// A crash between the journal append of a record and the save of the device
// lists it pins must not lock a group out of its history (M29, N2).
import 'dart:io';

import 'package:conest/src/group_accounts.dart';
import 'package:conest/src/group_history_journal.dart';
import 'package:conest/src/group_history_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/group_accounts_fixture.dart';

void main() {
  late Directory directory;
  final vaultKey = List<int>.generate(32, (index) => index);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('conest-accounts-');
  });
  tearDown(() => directory.delete(recursive: true));

  Future<GroupHistoryReplica> open(
    String name,
    TestDevice owner,
    String localDevice,
    PinnedListStore lists, {
    Future<void> Function()? beforeAppend,
  }) async => GroupHistoryReplica.restore(
    journal: await GroupHistoryJournal.open(
      file: File('${directory.path}/$name.journal'),
      key: vaultKey,
      groupId: 'group-acc',
    ),
    groupId: 'group-acc',
    localDeviceId: localDevice,
    trustedOwner: owner.profile(),
    lists: lists,
    beforeAppend: beforeAppend,
  );

  test('lists are saved before the record is appended, and a restart that '
      'lost them catches up instead of failing', () async {
    final fx = GroupFixture(groupId: 'group-acc');
    final alice = await TestDevice.create('alice', 'acc-alice');
    final carol = await TestDevice.create('carol', 'acc-carol');
    final bobAcc = await TestAccount.create('acc-bob');
    final bob1 = await TestDevice.create('bob1', 'acc-bob');
    final r1 = await fx.record(
      owner: alice,
      author: alice,
      deviceOnly: [carol],
    );
    final l1 = await bobAcc.list(1, [bob1]);
    final r2 = await fx.record(
      owner: alice,
      author: alice,
      parents: [r1],
      deviceOnly: [carol],
      accounts: [AccountSpec(bobAcc, l1, [bob1])],
    );
    // Alice holds everything.
    final aliceReplica = await open('alice', alice, 'alice', fx.lists);
    await aliceReplica.importMembership(r1.proof);
    await aliceReplica.importMembership(r2.proof);

    // Carol saves the lists before each append.
    final carolLists = PinnedListStore();
    var savedBeforeAppend = false;
    var journalHadRecord = true;
    late GroupHistoryJournal carolJournal;
    carolJournal = await GroupHistoryJournal.open(
      file: File('${directory.path}/carol.journal'),
      key: vaultKey,
      groupId: 'group-acc',
    );
    final carolReplica = await GroupHistoryReplica.restore(
      journal: carolJournal,
      groupId: 'group-acc',
      localDeviceId: 'carol',
      trustedOwner: alice.profile(),
      lists: carolLists,
      beforeAppend: () async {
        journalHadRecord =
            (await carolJournal.readMembershipPage(limit: 8)).length >= 2;
        savedBeforeAppend = carolLists.length > 0;
      },
    );
    await carolReplica.importMembership(r1.proof);
    carolLists.put(l1);
    expect(
      await carolReplica.importMembership(r2.proof),
      anything,
    );
    expect(savedBeforeAppend, isTrue);
    expect(journalHadRecord, isFalse);
    await carolJournal.close();

    // The restart finds the record but not the list (the vault save was
    // lost): the replica is behind, not broken.
    final restarted = await open('carol', alice, 'carol', PinnedListStore());
    expect(restarted.behind, isTrue);
    expect(restarted.membership.current!.id, r1.id);
    // Nothing is signed while it is behind; a catch-up from a member fixes it.
    final pulled = await restarted.pullFrom(
      aliceReplica,
      carrierDeviceId: 'alice',
    );
    expect(pulled, greaterThanOrEqualTo(0));
    expect(restarted.behind, isFalse);
    expect(restarted.membership.current!.id, r2.id);
  });
}
