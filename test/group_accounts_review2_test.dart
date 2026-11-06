// Review round 2 of groups by account (M29): the deputy's record has one
// designated signer, a fork the owner can merge, and the local send rule.
import 'package:conest/src/account/account_model.dart';
import 'package:conest/src/group_account_member.dart';
import 'package:conest/src/group_accounts.dart';
import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_membership_history.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/group_accounts_fixture.dart';
import 'support/legacy_group_membership_history.dart';

void main() {
  late GroupFixture fx;
  late TestDevice alice, carol, bob1, bob2, bob3, dan1, dan2, dan3;
  late TestAccount bobAcc, danAcc;

  setUp(() async {
    fx = GroupFixture();
    alice = await TestDevice.create('alice', 'acc-alice');
    carol = await TestDevice.create('carol', 'acc-carol');
    bobAcc = await TestAccount.create('acc-bob');
    bob1 = await TestDevice.create('bob1', 'acc-bob');
    bob2 = await TestDevice.create('bob2', 'acc-bob');
    bob3 = await TestDevice.create('bob3', 'acc-bob');
    danAcc = await TestAccount.create('acc-dan');
    dan1 = await TestDevice.create('dan1', 'acc-dan');
    dan2 = await TestDevice.create('dan2', 'acc-dan');
    dan3 = await TestDevice.create('dan3', 'acc-dan');
  });

  Future<GroupMembershipRecord> root() =>
      fx.record(owner: alice, author: alice, deviceOnly: [carol]);

  /// The record after which Bob's account has three devices in the group.
  Future<GroupMembershipRecord> withBob(GroupMembershipRecord parent) async {
    final list = await bobAcc.list(1, [bob1, bob2, bob3]);
    return fx.record(
      owner: alice,
      author: alice,
      parents: [parent],
      deviceOnly: [carol],
      accounts: [
        AccountSpec(bobAcc, list, [bob1, bob2, bob3]),
      ],
    );
  }

  group('H1: one designated signer for the deputy record', () {
    test('the deputy record is taken right after the record that admitted '
        'its account and another account', () async {
      // Neither account has been pinned again since it was admitted, so the
      // records name them with no admission of their own.
      final r1 = await root();
      final r2 = await withBob(r1);
      final dl1 = await danAcc.list(1, [dan1, dan2]);
      final r3 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, await bobAcc.list(1, [bob1, bob2, bob3]), [
            bob1,
            bob2,
            bob3,
          ]),
          AccountSpec(danAcc, dl1, [dan1, dan2]),
        ],
      );
      final l2 = await bobAcc.list(2, [bob1, bob2], revoked: ['bob3']);
      final pin = await fx.record(
        owner: alice,
        author: bob1,
        parents: [r3],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, l2, [bob1, bob2]),
          AccountSpec(danAcc, dl1, [dan1, dan2]),
        ],
      );
      final history = fx.history(owner: alice);
      for (final r in [r1, r2, r3]) {
        await history.import(r);
      }
      expect(r3.group.memberAccounts.last.admission, isNull);
      expect(await history.import(pin), GroupMembershipImport.accepted);
    });

    test('only the smallest projected device that is not revoked may pin the '
        'revocation of its account', () async {
      final r1 = await root();
      final r2 = await withBob(r1);
      final l2 = await bobAcc.list(2, [bob1, bob2], revoked: ['bob3']);
      Future<GroupMembershipRecord> pin(TestDevice author) => fx.record(
        owner: alice,
        author: author,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, l2, [bob1, bob2]),
        ],
      );
      final history = fx.history(owner: alice);
      for (final r in [r1, r2]) {
        await history.import(r);
      }
      // bob2 is projected and not revoked, but bob1 is smaller.
      await expectLater(
        history.import(await pin(bob2)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unauthorized'),
          ),
        ),
      );
      expect(
        await history.import(await pin(bob1)),
        GroupMembershipImport.accepted,
      );
    });

    test('when the smallest device is the revoked one, the next smallest '
        'signs', () async {
      final r1 = await root();
      final r2 = await withBob(r1);
      final l2 = await bobAcc.list(2, [bob2, bob3], revoked: ['bob1']);
      Future<GroupMembershipRecord> pin(TestDevice author) => fx.record(
        owner: alice,
        author: author,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, l2, [bob2, bob3]),
        ],
      );
      final history = fx.history(owner: alice);
      for (final r in [r1, r2]) {
        await history.import(r);
      }
      await expectLater(history.import(await pin(bob3)), throwsFormatException);
      expect(
        await history.import(await pin(bob2)),
        GroupMembershipImport.accepted,
      );
    });
  });

  /// What the owner's app signs for a fork: the merged group, every head as
  /// a parent, the admissions the heads agree on.
  Future<GroupMembershipRecord> ownerMerge(
    GroupMembershipHistory history,
    TestDevice owner,
  ) async {
    final merged = history.mergedHeads()!;
    final next = history.forNextRecord(merged);
    return GroupMembershipRecord.fromEvent(
      await fx.sign(
        author: owner,
        membershipId: history.heads.first,
        kind: GroupEventKind.membership,
        payload: GroupMembershipRecord.payload(
          group: next,
          parents: history.heads,
          historyVisibility: GroupHistoryVisibility.allRetained,
          admissions: {
            for (final device in next.activeMemberDeviceIds)
              device: history.nextAdmission(device),
          },
        ),
      ),
    );
  }

  group('H1: the owner merges a fork', () {
    test('two accounts pin their revocations at once; the owner resolves '
        'the fork with one record and every device reaches one head', () async {
      final r1 = await root();
      final bl1 = await bobAcc.list(1, [bob1, bob2, bob3]);
      final dl1 = await danAcc.list(1, [dan1, dan2, dan3]);
      final r2 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, bl1, [bob1, bob2, bob3]),
          AccountSpec(danAcc, dl1, [dan1, dan2, dan3]),
        ],
      );
      final bl2 = await bobAcc.list(2, [bob1, bob2], revoked: ['bob3']);
      final dl2 = await danAcc.list(2, [dan1, dan2], revoked: ['dan3']);
      final bobPin = await fx.record(
        owner: alice,
        author: bob1,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, bl2, [bob1, bob2]),
          AccountSpec(danAcc, dl1, [dan1, dan2, dan3]),
        ],
      );
      final danPin = await fx.record(
        owner: alice,
        author: dan1,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, bl1, [bob1, bob2, bob3]),
          AccountSpec(danAcc, dl2, [dan1, dan2]),
        ],
      );
      final history = fx.history(owner: alice);
      final other = fx.history(owner: alice);
      for (final r in [r1, r2, bobPin, danPin]) {
        await history.import(r);
      }
      for (final r in [r1, r2, danPin, bobPin]) {
        await other.import(r);
      }
      expect(history.hasConflict, isTrue);
      expect(other.hasConflict, isTrue);
      final merge = await ownerMerge(history, alice);
      final group = merge.group;
      expect(group.membershipVersion, r2.group.membershipVersion + 2);
      expect(group.memberAccounts.map((e) => e.listVersion), [2, 2]);
      expect(
        group.activeMemberDeviceIds,
        unorderedEquals(['alice', 'carol', 'bob1', 'bob2', 'dan1', 'dan2']),
      );
      expect(await history.import(merge), GroupMembershipImport.accepted);
      expect(await other.import(merge), GroupMembershipImport.accepted);
      expect(history.hasConflict, isFalse);
      expect(history.current!.id, other.current!.id);
      // The group works again: the owner's next record follows.
      expect(
        await history.import(
          await fx.record(
            owner: alice,
            author: alice,
            parents: [merge],
            deviceOnly: [carol],
            accounts: [
              AccountSpec(bobAcc, bl2, [bob1, bob2]),
              AccountSpec(danAcc, dl2, [dan1, dan2]),
            ],
          ),
        ),
        GroupMembershipImport.accepted,
      );
    });

    test('a removal on either branch stays removed, and the old validator '
        'accepts the merge', () async {
      final frank = await TestDevice.create('frank', 'acc-frank');
      final zed = await TestDevice.create('zed', 'acc-zed');
      final eve = await TestDevice.create('eve', 'acc-eve');
      final nic = await TestDevice.create('nic', 'acc-nic');
      final r1 = await fx.record(
        owner: alice,
        author: alice,
        deviceOnly: [carol, frank, zed],
        admins: ['carol', 'frank'],
      );
      // carol adds eve, frank removes zed: both fine alone, a fork together.
      final adds = await fx.record(
        owner: alice,
        author: carol,
        parents: [r1],
        deviceOnly: [carol, frank, zed, eve],
        admins: ['carol', 'frank'],
      );
      // The adding branch is the longer one: it is the base of the merge.
      final adds2 = await fx.record(
        owner: alice,
        author: carol,
        parents: [adds],
        deviceOnly: [carol, frank, zed, eve, nic],
        admins: ['carol', 'frank'],
      );
      final removes = await fx.record(
        owner: alice,
        author: frank,
        parents: [r1],
        deviceOnly: [carol, frank],
        admins: ['carol', 'frank'],
      );
      final modern = fx.history(owner: alice);
      final legacy = LegacyGroupMembershipHistory(
        groupId: fx.groupId,
        trustedOwner: alice.profile(),
      );
      for (final r in [r1, adds, adds2, removes]) {
        expect(await modern.import(r), GroupMembershipImport.accepted);
        expect(await legacy.import(r), GroupMembershipImport.accepted);
      }
      expect(modern.hasConflict, isTrue);
      final merge = await ownerMerge(modern, alice);
      expect(merge.group.hasActiveMember('zed'), isFalse);
      expect(merge.group.hasActiveMember('nic'), isTrue);
      legacyShapeCheck(merge);
      expect(await modern.import(merge), GroupMembershipImport.accepted);
      expect(await legacy.import(merge), GroupMembershipImport.accepted);
      expect(modern.hasConflict, isFalse);
      expect(modern.current!.id, legacy.current!.id);
    });
  });

  group('H1: a revoked author does not decide the merge', () {
    test('what a thief admin added on its own branch is not merged', () async {
      final eve = await TestDevice.create('eve', 'acc-eve');
      final nic = await TestDevice.create('nic', 'acc-nic');
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1, bob2, bob3]);
      AccountSpec bobAdmin(AccountDeviceList list, List<TestDevice> devices) =>
          AccountSpec(bobAcc, list, devices, role: GroupAccountRole.admin);
      final r2 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [
          bobAdmin(l1, [bob1, bob2, bob3]),
        ],
      );
      // bob3 is stolen: it adds two members while bob1 pins its revocation.
      final thief1 = await fx.record(
        owner: alice,
        author: bob3,
        parents: [r2],
        deviceOnly: [carol, eve],
        accounts: [
          bobAdmin(l1, [bob1, bob2, bob3]),
        ],
      );
      final thief2 = await fx.record(
        owner: alice,
        author: bob3,
        parents: [thief1],
        deviceOnly: [carol, eve, nic],
        accounts: [
          bobAdmin(l1, [bob1, bob2, bob3]),
        ],
      );
      final l2 = await bobAcc.list(2, [bob1, bob2], revoked: ['bob3']);
      final pin = await fx.record(
        owner: alice,
        author: bob1,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          bobAdmin(l2, [bob1, bob2]),
        ],
      );
      final history = fx.history(owner: alice);
      for (final r in [r1, r2, thief1, thief2, pin]) {
        expect(await history.import(r), GroupMembershipImport.accepted);
      }
      expect(history.hasConflict, isTrue);
      final merge = await ownerMerge(history, alice);
      expect(
        merge.group.activeMemberDeviceIds,
        unorderedEquals(['alice', 'carol', 'bob1', 'bob2']),
      );
      expect(await history.import(merge), GroupMembershipImport.accepted);
      expect(history.hasConflict, isFalse);
    });
  });

  group('H2: the local send rule does not cut members off for good', () {
    late TestAccount admAcc;
    late TestDevice adm1, adm2;
    late GroupMembershipRecord r2, r3;
    late GroupHistoryEvent firstEvent;
    late AccountDeviceList al1, al2, bl1;
    late DeviceListView view;
    late GroupMembershipHistory history;

    /// An admin device of an account admits Bob's account. [firstMessage]
    /// puts one event of the admin before the admitting record.
    Future<void> admit({bool firstMessage = false}) async {
      admAcc = await TestAccount.create('acc-adm');
      adm1 = await TestDevice.create('adm1', 'acc-adm');
      adm2 = await TestDevice.create('adm2', 'acc-adm');
      final r1 = await root();
      al1 = await admAcc.list(1, [adm1, adm2]);
      r2 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(admAcc, al1, [adm1], role: GroupAccountRole.admin),
        ],
      );
      if (firstMessage) firstEvent = await fx.message(r2, adm1);
      bl1 = await bobAcc.list(1, [bob1]);
      r3 = await fx.record(
        owner: alice,
        author: adm1,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(admAcc, al1, [adm1], role: GroupAccountRole.admin),
          AccountSpec(bobAcc, bl1, [bob1]),
        ],
      );
      al2 = await admAcc.list(2, [adm2], revoked: ['adm1']);
      view = DeviceListView(groupId: fx.groupId)
        ..offerVerified(al1, accountKey: admAcc.keys.publicKeyBase64)
        ..offerVerified(bl1, accountKey: bobAcc.keys.publicKeyBase64);
      history = fx.history(owner: alice, view: view);
      for (final r in [r1, r2, r3]) {
        await history.import(r);
      }
    }

    Future<AccountCutoff> cutoff(GroupHistoryEvent at) => AccountCutoff.sign(
      groupId: fx.groupId,
      accountId: 'acc-adm',
      deviceId: 'adm1',
      sequence: at.sequence,
      eventId: at.eventId,
      signerDeviceId: adm2.id,
      signerPublicKeyBase64: adm2.signingPublicKey,
      signerPrivateKeyBase64: adm2.signingPrivateKey,
    );

    test(
      'a record the admin signed before its cutoff does not count',
      () async {
        await admit();
        // The admin's later events; the sibling signs where it ends.
        await fx.message(r3, adm1);
        final last = await fx.message(r3, adm1);
        view.offerVerified(al2, accountKey: admAcc.keys.publicKeyBase64);
        // The admin is revoked and nobody has said where it ends yet.
        expect(history.admittedByRevokedAuthors(), {'bob1'});
        expect(await view.offerCutoff(await cutoff(last)), isTrue);
        // Bob was admitted well before: he receives again.
        expect(history.admittedByRevokedAuthors(), isEmpty);
      },
    );

    test('a cutoff below the admitting record leaves the device waiting '
        'for the owner', () async {
      await admit(firstMessage: true);
      // The admin's first event came before the admitting record.
      final first = firstEvent;
      view.offerVerified(al2, accountKey: admAcc.keys.publicKeyBase64);
      expect(await view.offerCutoff(await cutoff(first)), isTrue);
      expect(r3.proof.sequence, greaterThan(first.sequence));
      expect(history.admittedByRevokedAuthors(), {'bob1'});
    });

    test('an owner record after the revocation pin that still lists the '
        'device answers the wait', () async {
      await admit();
      view.offerVerified(al2, accountKey: admAcc.keys.publicKeyBase64);
      expect(history.admittedByRevokedAuthors(), {'bob1'});
      final pin = await fx.record(
        owner: alice,
        author: alice,
        parents: [r3],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(admAcc, al2, [adm2], role: GroupAccountRole.admin),
          AccountSpec(bobAcc, bl1, [bob1]),
        ],
      );
      expect(await history.import(pin), GroupMembershipImport.accepted);
      expect(history.current!.id, pin.id);
      expect(history.admittedByRevokedAuthors(), isEmpty);
    });
  });
}
