import 'package:conest/src/group_account_member.dart';
import 'package:conest/src/group_accounts.dart';
import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_membership_history.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/group_accounts_fixture.dart';

void main() {
  late GroupFixture fx;
  late TestDevice alice, carol, bob1, bob2, bob3, dan1, dan2, eve;
  late TestAccount bobAcc, danAcc;

  setUp(() async {
    fx = GroupFixture();
    alice = await TestDevice.create('alice', 'acc-alice');
    carol = await TestDevice.create('carol', 'acc-carol');
    eve = await TestDevice.create('eve', 'acc-eve');
    bobAcc = await TestAccount.create('acc-bob');
    bob1 = await TestDevice.create('bob1', 'acc-bob');
    bob2 = await TestDevice.create('bob2', 'acc-bob');
    bob3 = await TestDevice.create('bob3', 'acc-bob');
    danAcc = await TestAccount.create('acc-dan');
    dan1 = await TestDevice.create('dan1', 'acc-dan');
    dan2 = await TestDevice.create('dan2', 'acc-dan');
  });

  Future<GroupMembershipRecord> root({List<TestDevice>? members}) =>
      fx.record(owner: alice, author: alice, deviceOnly: members ?? [carol]);

  group('pure acceptance', () {
    test('a record pinning a list that is not here is retried, not refused, '
        'and the order records arrive in does not matter', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1]);
      final r2 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [AccountSpec(bobAcc, l1, [bob1])],
      );
      final l2 = await bobAcc.list(2, [bob1, bob2]);
      final r3 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [AccountSpec(bobAcc, l2, [bob1, bob2])],
      );
      // A device that has no lists yet.
      final late = fx.history(owner: alice, store: PinnedListStore());
      expect(await late.import(r1), GroupMembershipImport.accepted);
      expect(await late.import(r3), GroupMembershipImport.missingParents);
      expect(await late.import(r2), GroupMembershipImport.missingDeviceLists);
      expect(late.missingListDigests(r2), isNotEmpty);
      late.lists.put(l1);
      expect(await late.import(r2), GroupMembershipImport.accepted);
      expect(await late.import(r3), GroupMembershipImport.missingDeviceLists);
      late.lists.put(l2);
      expect(await late.import(r3), GroupMembershipImport.accepted);
      // The same records the other way round reach the same head.
      final other = fx.history(owner: alice);
      expect(await other.import(r3), GroupMembershipImport.missingParents);
      expect(await other.import(r2), GroupMembershipImport.missingParents);
      expect(await other.import(r1), GroupMembershipImport.accepted);
      expect(await other.import(r2), GroupMembershipImport.accepted);
      expect(await other.import(r3), GroupMembershipImport.accepted);
      expect(other.current!.id, late.current!.id);
    });

    test('a sibling the signed projection does not hold cannot sign a '
        'record, even with a verified list', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [AccountSpec(bobAcc, l1, [bob1])],
      );
      final history = fx.history(owner: alice);
      await history.import(r1);
      expect(await history.import(r2), GroupMembershipImport.accepted);
      // bob2 is in the list but not in the projection.
      final forged = await fx.record(
        owner: alice,
        author: bob2,
        parents: [r2],
        deviceOnly: [carol, eve],
        accounts: [AccountSpec(bobAcc, l1, [bob1])],
      );
      expect(() => history.import(forged), throwsFormatException);
    });
  });

  group('revocation', () {
    test('a revoked device counts only up to its cutoff, on its own chain; '
        'a revocation pinned in an ancestor stays', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [AccountSpec(bobAcc, l1, [bob1, bob2])],
      );
      final e1 = await fx.message(r2, bob2);
      final e2 = await fx.message(r2, bob2);
      final e3 = await fx.message(r2, bob2);
      // A fill-in with the same sequence number as e1 but another chain.
      final fork = await fx.sign(
        author: bob2,
        membershipId: r2.id,
        kind: GroupEventKind.message,
        payload: {'text': 'backdated'},
        sequence: 1,
        track: false,
      );
      final chain = {e1.eventId, e2.eventId};
      final l2 = await bobAcc.list(2, [bob1], revoked: ['bob2']);
      final r3 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [AccountSpec(bobAcc, l2, [bob1])],
        checkpoints: {
          'bob2': GroupHistoryCheckpoint(
            sequence: e2.sequence,
            eventId: e2.eventId,
          ),
        },
      );
      final history = fx.history(
        owner: alice,
        chain: (event, cutoff) async => chain.contains(event.eventId),
      );
      for (final r in [r1, r2, r3]) {
        await history.import(r);
      }
      Future<bool> counts(GroupHistoryEvent e) =>
          history.canReceive(e, recipientDeviceId: 'carol');
      expect(await counts(e1), isTrue);
      expect(await counts(e2), isTrue);
      expect(await counts(e3), isFalse);
      expect(await counts(fork), isFalse);
      // No later record may project the device again, even pinning an older
      // list that does not know the revocation.
      final back = await fx.record(
        owner: alice,
        author: alice,
        parents: [r3],
        deviceOnly: [carol],
        accounts: [AccountSpec(bobAcc, l1, [bob1, bob2])],
      );
      expect(() => history.import(back), throwsFormatException);
      // The device is no longer effective for message events either.
      final view = DeviceListView(groupId: fx.groupId)
        ..offerVerified(l1, accountKey: bobAcc.keys.publicKeyBase64)
        ..offerVerified(l2, accountKey: bobAcc.keys.publicKeyBase64);
      expect(view.revoked('acc-bob'), contains('bob2'));
      expect(
        view.effectiveCerts(
          history.current!.group.memberAccounts.single,
          confirmNewDevices: false,
        ),
        hasLength(1),
      );
    });

    test('a thief owner revoked in the ancestry cannot sign a resolution '
        'that hands ownership to an accomplice', () async {
      final aliceAcc = await TestAccount.create('acc-alice');
      final alice1 = await TestDevice.create('alice1', 'acc-alice');
      final alice2 = await TestDevice.create('alice2', 'acc-alice');
      final r1 = await fx.record(owner: alice1, author: alice1, deviceOnly: [carol]);
      final l1 = await aliceAcc.list(1, [alice1, alice2]);
      // The owner folds into its account (the proof is embedded).
      final r2 = await fx.record(
        owner: alice1,
        author: alice1,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(
            aliceAcc,
            l1,
            [alice1, alice2],
            role: GroupAccountRole.owner,
            upgrade: await aliceAcc.upgrade(alice1),
            admission: r1.admissions['alice1'],
          ),
        ],
      );
      final history = fx.history(owner: alice1);
      for (final r in [r1, r2]) {
        expect(await history.import(r), GroupMembershipImport.accepted);
      }
      // The honest sibling takes over (O1): the owner device is revoked.
      final l2 = await aliceAcc.list(2, [alice2], revoked: ['alice1']);
      final o1 = await fx.record(
        owner: alice2,
        author: alice2,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(aliceAcc, l2, [alice2], role: GroupAccountRole.owner),
        ],
      );
      // The thief's concurrent record while it was still owner.
      final thief = await fx.record(
        owner: alice1,
        author: alice1,
        parents: [r2],
        deviceOnly: [carol, eve],
        accounts: [
          AccountSpec(
            aliceAcc,
            l1,
            [alice1, alice2],
            role: GroupAccountRole.owner,
          ),
        ],
      );
      expect(await history.import(o1), GroupMembershipImport.accepted);
      expect(await history.import(thief), GroupMembershipImport.accepted);
      expect(history.hasConflict, isTrue);
      // The thief resolves the fork and gives the group to carol.
      final resolution = await fx.record(
        owner: carol,
        author: alice1,
        parents: [o1, thief],
        deviceOnly: [eve],
        accounts: [
          AccountSpec(aliceAcc, l2, [alice2], role: GroupAccountRole.owner),
        ],
      );
      expect(
        () => history.import(resolution),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('revoked'),
          ),
        ),
      );
    });

    test('an owner device its account revoked is replaced only when every '
        'member knows accounts', () async {
      final aliceAcc = await TestAccount.create('acc-alice');
      final alice1 = await TestDevice.create('alice1', 'acc-alice');
      final alice2 = await TestDevice.create('alice2', 'acc-alice');
      final old = await TestDevice.create('old', 'acc-old');
      Future<GroupMembershipHistory> build({required bool carolCapable}) async {
        final f = GroupFixture();
        final r1 = await f.record(
          owner: alice1,
          author: alice1,
          deviceOnly: [carol],
          profileOverrides: {'carol': carol.profile(capable: carolCapable)},
        );
        final l1 = await aliceAcc.list(1, [alice1, alice2]);
        final r2 = await f.record(
          owner: alice1,
          author: alice1,
          parents: [r1],
          deviceOnly: [carol],
          profileOverrides: {'carol': carol.profile(capable: carolCapable)},
          accounts: [
            AccountSpec(
              aliceAcc,
              l1,
              [alice1, alice2],
              role: GroupAccountRole.owner,
              upgrade: await aliceAcc.upgrade(alice1),
              admission: r1.admissions['alice1'],
            ),
          ],
        );
        final l2 = await aliceAcc.list(2, [alice2], revoked: ['alice1']);
        final o1 = await f.record(
          owner: alice2,
          author: alice2,
          parents: [r2],
          deviceOnly: [carol],
          profileOverrides: {'carol': carol.profile(capable: carolCapable)},
          accounts: [
            AccountSpec(aliceAcc, l2, [alice2], role: GroupAccountRole.owner),
          ],
        );
        final h = f.history(owner: alice1);
        await h.import(r1);
        await h.import(r2);
        if (!carolCapable) {
          // An older validator would reject a non-owner ownership change.
          expect(() => h.import(o1), throwsFormatException);
        } else {
          await h.import(o1);
        }
        return h;
      }

      final capable = await build(carolCapable: true);
      expect(capable.current!.group.ownerDeviceId, 'alice2');
      final incapable = await build(carolCapable: false);
      expect(incapable.current!.group.ownerDeviceId, 'alice1');
      expect(old.id, 'old');
    });
  });
}
