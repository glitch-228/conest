// An app that never heard of accounts must still accept every record a new
// app produces while it is a member of the group (it sees only the
// projection). The frozen validator in test/support is the pre-accounts
// code; each record of a long scenario runs through both.
import 'package:conest/src/group_account_member.dart';
import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_membership_history.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/group_accounts_fixture.dart';
import 'support/legacy_group_membership_history.dart';

void main() {
  test('every kind of record a new app emits passes the old validator',
      () async {
    final fx = GroupFixture();
    final alice = await TestDevice.create('alice', 'acc-alice');
    final carol = await TestDevice.create('carol', 'acc-carol');
    final carol2 = await TestDevice.create('carol2', 'acc-carol');
    final frank = await TestDevice.create('frank', 'acc-frank');
    final bob1 = await TestDevice.create('bob1', 'acc-bob');
    final bob2 = await TestDevice.create('bob2', 'acc-bob');
    final bob3 = await TestDevice.create('bob3', 'acc-bob');
    final dan1 = await TestDevice.create('dan1', 'acc-dan');
    final dan2 = await TestDevice.create('dan2', 'acc-dan');
    final carolAcc = await TestAccount.create('acc-carol');
    final frankAcc = await TestAccount.create('acc-frank');
    final bobAcc = await TestAccount.create('acc-bob');
    final danAcc = await TestAccount.create('acc-dan');

    final modern = fx.history(owner: alice);
    final legacy = LegacyGroupMembershipHistory(
      groupId: fx.groupId,
      trustedOwner: alice.profile(),
    );
    final kinds = <String>[];
    Future<GroupMembershipRecord> step(
      String kind,
      Future<GroupMembershipRecord> Function() make,
    ) async {
      final record = await make();
      expect(
        await modern.import(record),
        GroupMembershipImport.accepted,
        reason: 'new validator, $kind',
      );
      legacyShapeCheck(record);
      expect(
        await legacy.import(record),
        GroupMembershipImport.accepted,
        reason: 'old validator, $kind',
      );
      kinds.add(kind);
      return record;
    }

    final r1 = await step(
      'root with a device-only admin and member',
      () async => fx.record(
        owner: alice,
        author: alice,
        deviceOnly: [carol, frank, dan1],
        admins: ['carol', 'frank'],
      ),
    );
    final bl1 = await bobAcc.list(1, [bob1]);
    final r2 = await step(
      'admin adds an account',
      () async => fx.record(
        owner: alice,
        author: carol,
        parents: [r1],
        deviceOnly: [carol, frank, dan1],
        admins: ['carol', 'frank'],
        accounts: [AccountSpec(bobAcc, bl1, [bob1])],
      ),
    );
    final bl2 = await bobAcc.list(2, [bob1, bob2]);
    final r3 = await step(
      'admin re-pins a member account with a new device',
      () async => fx.record(
        owner: alice,
        author: carol,
        parents: [r2],
        deviceOnly: [carol, frank, dan1],
        admins: ['carol', 'frank'],
        accounts: [AccountSpec(bobAcc, bl2, [bob1, bob2])],
      ),
    );
    final dl1 = await danAcc.list(1, [dan1, dan2]);
    final r4 = await step(
      'admin folds a device-only member, siblings projected as members',
      () async => fx.record(
        owner: alice,
        author: carol,
        parents: [r3],
        deviceOnly: [carol, frank],
        admins: ['carol', 'frank'],
        accounts: [
          AccountSpec(bobAcc, bl2, [bob1, bob2]),
          AccountSpec(
            danAcc,
            dl1,
            [dan1, dan2],
            upgrade: await danAcc.upgrade(dan1),
            admission: r3.admissions['dan1'],
          ),
        ],
      ),
    );
    final fl1 = await frankAcc.list(1, [frank]);
    final r5 = await step(
      'admin folds another admin, projecting only that admin',
      () async => fx.record(
        owner: alice,
        author: carol,
        parents: [r4],
        deviceOnly: [carol],
        admins: ['carol'],
        accounts: [
          AccountSpec(bobAcc, bl2, [bob1, bob2]),
          AccountSpec(danAcc, dl1, [dan1, dan2]),
          AccountSpec(
            frankAcc,
            fl1,
            [frank],
            role: GroupAccountRole.admin,
            upgrade: await frankAcc.upgrade(frank),
            admission: r4.admissions['frank'],
          ),
        ],
      ),
    );
    final cl1 = await carolAcc.list(1, [carol]);
    final r6 = await step(
      'owner folds an admin',
      () async => fx.record(
        owner: alice,
        author: alice,
        parents: [r5],
        accounts: [
          AccountSpec(bobAcc, bl2, [bob1, bob2]),
          AccountSpec(danAcc, dl1, [dan1, dan2]),
          AccountSpec(frankAcc, fl1, [frank], role: GroupAccountRole.admin),
          AccountSpec(
            carolAcc,
            cl1,
            [carol],
            role: GroupAccountRole.admin,
            upgrade: await carolAcc.upgrade(carol),
            admission: r5.admissions['carol'],
          ),
        ],
      ),
    );
    final cl2 = await carolAcc.list(2, [carol, carol2]);
    final r7 = await step(
      'owner re-pins a new device of an admin account into the admin list',
      () async => fx.record(
        owner: alice,
        author: alice,
        parents: [r6],
        accounts: [
          AccountSpec(bobAcc, bl2, [bob1, bob2]),
          AccountSpec(danAcc, dl1, [dan1, dan2]),
          AccountSpec(frankAcc, fl1, [frank], role: GroupAccountRole.admin),
          AccountSpec(
            carolAcc,
            cl2,
            [carol, carol2],
            role: GroupAccountRole.admin,
          ),
        ],
      ),
    );
    final cl3 = await carolAcc.list(3, [carol], revoked: ['carol2']);
    final r8 = await step(
      'owner pins a revocation and drops the device',
      () async => fx.record(
        owner: alice,
        author: alice,
        parents: [r7],
        accounts: [
          AccountSpec(bobAcc, bl2, [bob1, bob2]),
          AccountSpec(danAcc, dl1, [dan1, dan2]),
          AccountSpec(frankAcc, fl1, [frank], role: GroupAccountRole.admin),
          AccountSpec(carolAcc, cl3, [carol], role: GroupAccountRole.admin),
        ],
        checkpoints: {
          'carol2': GroupHistoryCheckpoint(sequence: 1, eventId: 'a' * 64),
        },
      ),
    );
    final r9 = await step(
      'owner switches device confirmation on',
      () async => fx.record(
        owner: alice,
        author: alice,
        parents: [r8],
        confirmNewDevices: true,
        accounts: [
          AccountSpec(
            bobAcc,
            bl2,
            [bob1, bob2],
            approved: ['bob1', 'bob2'],
          ),
          AccountSpec(
            danAcc,
            dl1,
            [dan1, dan2],
            approved: ['dan1', 'dan2'],
          ),
          AccountSpec(
            frankAcc,
            fl1,
            [frank],
            role: GroupAccountRole.admin,
            approved: ['frank'],
          ),
          AccountSpec(
            carolAcc,
            cl3,
            [carol],
            role: GroupAccountRole.admin,
            approved: ['carol'],
          ),
        ],
      ),
    );
    final bl3 = await bobAcc.list(3, [bob1, bob2, bob3]);
    final r10 = await step(
      'admin approves a new device',
      () async => fx.record(
        owner: alice,
        author: frank,
        parents: [r9],
        confirmNewDevices: true,
        accounts: [
          AccountSpec(
            bobAcc,
            bl3,
            [bob1, bob2, bob3],
            approved: ['bob1', 'bob2', 'bob3'],
          ),
          AccountSpec(
            danAcc,
            dl1,
            [dan1, dan2],
            approved: ['dan1', 'dan2'],
          ),
          AccountSpec(
            frankAcc,
            fl1,
            [frank],
            role: GroupAccountRole.admin,
            approved: ['frank'],
          ),
          AccountSpec(
            carolAcc,
            cl3,
            [carol],
            role: GroupAccountRole.admin,
            approved: ['carol'],
          ),
        ],
      ),
    );
    final r11 = await step(
      'admin excludes a device',
      () async => fx.record(
        owner: alice,
        author: carol,
        parents: [r10],
        confirmNewDevices: true,
        accounts: [
          AccountSpec(
            bobAcc,
            bl3,
            [bob1, bob3],
            approved: ['bob1', 'bob2', 'bob3'],
            excluded: ['bob2'],
          ),
          AccountSpec(
            danAcc,
            dl1,
            [dan1, dan2],
            approved: ['dan1', 'dan2'],
          ),
          AccountSpec(
            frankAcc,
            fl1,
            [frank],
            role: GroupAccountRole.admin,
            approved: ['frank'],
          ),
          AccountSpec(
            carolAcc,
            cl3,
            [carol],
            role: GroupAccountRole.admin,
            approved: ['carol'],
          ),
        ],
      ),
    );
    await step(
      'admin removes a member account',
      () async => fx.record(
        owner: alice,
        author: carol,
        parents: [r11],
        confirmNewDevices: true,
        accounts: [
          AccountSpec(
            danAcc,
            dl1,
            [dan1, dan2],
            approved: ['dan1', 'dan2'],
          ),
          AccountSpec(
            frankAcc,
            fl1,
            [frank],
            role: GroupAccountRole.admin,
            approved: ['frank'],
          ),
          AccountSpec(
            carolAcc,
            cl3,
            [carol],
            role: GroupAccountRole.admin,
            approved: ['carol'],
          ),
        ],
      ),
    );
    expect(kinds, hasLength(12));
    expect(modern.current!.id, legacy.current!.id);
  });

  test('records the old validator would reject are refused by the new one '
      'unless every member knows accounts', () async {
    // A non-owner admin folding an admin account and projecting a sibling
    // is rejected by both.
    final fx = GroupFixture();
    final alice = await TestDevice.create('alice', 'acc-alice');
    final carol = await TestDevice.create('carol', 'acc-carol');
    final frank = await TestDevice.create('frank', 'acc-frank');
    final frank2 = await TestDevice.create('frank2', 'acc-frank');
    final frankAcc = await TestAccount.create('acc-frank');
    final modern = fx.history(owner: alice);
    final legacy = LegacyGroupMembershipHistory(
      groupId: fx.groupId,
      trustedOwner: alice.profile(),
    );
    final r1 = await fx.record(
      owner: alice,
      author: alice,
      deviceOnly: [carol, frank],
      admins: ['carol', 'frank'],
    );
    await modern.import(r1);
    await legacy.import(r1);
    final bad = await fx.record(
      owner: alice,
      author: carol,
      parents: [r1],
      deviceOnly: [carol],
      admins: ['carol'],
      accounts: [
        AccountSpec(
          frankAcc,
          await frankAcc.list(1, [frank, frank2]),
          [frank, frank2],
          role: GroupAccountRole.admin,
          upgrade: await frankAcc.upgrade(frank),
          admission: r1.admissions['frank'],
        ),
      ],
    );
    expect(() => legacy.import(bad), throwsFormatException);
    expect(() => modern.import(bad), throwsFormatException);
  });
}
