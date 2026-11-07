// Review round 2 of groups by account (M29): the deputy's record has one
// designated signer, a fork the owner can merge, and the local send rule.
import 'package:conest/src/account/account_model.dart';
import 'package:conest/src/group_account_member.dart';
import 'package:conest/src/group_accounts.dart';
import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_membership_history.dart';
import 'package:conest/src/group_message_projection.dart';
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

  group('R3-H2: a revoked device cannot fork the group', () {
    late GroupMembershipRecord r1, r2, pin;
    late AccountDeviceList l1, l2;

    AccountSpec bobAdmin(AccountDeviceList list, List<TestDevice> devices) =>
        AccountSpec(bobAcc, list, devices, role: GroupAccountRole.admin);

    /// Bob's admin account has three devices; bob1 pins the revocation of
    /// the stolen bob3.
    Future<void> setUpPin() async {
      r1 = await root();
      l1 = await bobAcc.list(1, [bob1, bob2, bob3]);
      r2 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [
          bobAdmin(l1, [bob1, bob2, bob3]),
        ],
      );
      l2 = await bobAcc.list(2, [bob1, bob2], revoked: ['bob3']);
      pin = await fx.record(
        owner: alice,
        author: bob1,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          bobAdmin(l2, [bob1, bob2]),
        ],
      );
    }

    /// The stolen bob3 adds [device] on an old parent.
    Future<GroupMembershipRecord> thiefAdds(
      GroupMembershipRecord parent,
      List<TestDevice> members,
    ) => fx.record(
      owner: alice,
      author: bob3,
      parents: [parent],
      deviceOnly: [carol, ...members],
      accounts: [
        bobAdmin(l1, [bob1, bob2, bob3]),
      ],
    );

    test(
      'twenty records a revoked device signs on old parents are no '
      'heads: the group keeps one effective head and keeps working',
      () async {
        await setUpPin();
        final history = fx.history(owner: alice);
        for (final r in [r1, r2, pin]) {
          await history.import(r);
        }
        final extra = <TestDevice>[];
        for (var i = 0; i < 20; i++) {
          final device = await TestDevice.create('thief-$i', 'acc-thief-$i');
          extra.add(device);
          final record = await thiefAdds(r2, [device]);
          expect(await history.import(record), GroupMembershipImport.accepted);
        }
        // 21 competing heads in the DAG, one that counts.
        expect(history.hasConflict, isFalse);
        expect(history.heads, [pin.id]);
        expect(history.current!.id, pin.id);
        expect(history.mergedHeads(), isNull);
        // The owner's next record follows the effective head and is taken.
        final next = await fx.record(
          owner: alice,
          author: alice,
          parents: [pin],
          deviceOnly: [carol, dan1],
          accounts: [
            bobAdmin(l2, [bob1, bob2]),
          ],
        );
        expect(await history.import(next), GroupMembershipImport.accepted);
        expect(history.current!.id, next.id);
        expect(history.hasConflict, isFalse);
      },
    );

    test('an honest record on top of a thief record does not make its branch '
        'a head', () async {
      await setUpPin();
      final thief = await thiefAdds(r2, [dan1]);
      // The owner builds on the thief's record before it knows better.
      final onTop = await fx.record(
        owner: alice,
        author: alice,
        parents: [thief],
        deviceOnly: [carol, dan1, dan2],
        accounts: [
          bobAdmin(l1, [bob1, bob2, bob3]),
        ],
      );
      final history = fx.history(owner: alice);
      for (final r in [r1, r2, thief, onTop, pin]) {
        expect(await history.import(r), GroupMembershipImport.accepted);
      }
      // The branch since the fork holds a record of the revoked device.
      expect(history.hasConflict, isFalse);
      expect(history.current!.id, pin.id);
    });

    test(
      'a revoked device seen only in the local view counts the same',
      () async {
        await setUpPin();
        final thief = await thiefAdds(r2, [dan1]);
        // The pin is not here yet: only the view knows bob3 is revoked.
        final view = DeviceListView(groupId: fx.groupId)
          ..offerVerified(l1, accountKey: bobAcc.keys.publicKeyBase64);
        final history = fx.history(owner: alice, view: view);
        final other = await fx.record(
          owner: alice,
          author: alice,
          parents: [r2],
          deviceOnly: [carol, dan2],
          accounts: [
            bobAdmin(l1, [bob1, bob2, bob3]),
          ],
        );
        for (final r in [r1, r2, thief, other]) {
          await history.import(r);
        }
        expect(history.hasConflict, isTrue);
        view.offerVerified(l2, accountKey: bobAcc.keys.publicKeyBase64);
        expect(history.hasConflict, isFalse);
        expect(history.current!.id, other.id);
      },
    );

    test('at most sixteen heads are merged per record, and the merge goes on '
        'until one is left', () async {
      final r1 = await root();
      final history = fx.history(owner: alice);
      await history.import(r1);
      for (var i = 0; i < 17; i++) {
        final record = await fx.record(
          owner: alice,
          author: alice,
          parents: [r1],
          deviceOnly: [carol],
          title: 'title-$i',
        );
        expect(await history.import(record), GroupMembershipImport.accepted);
      }
      expect(history.hasConflict, isTrue);
      expect(history.heads, hasLength(16));
      final first = await ownerMerge(history, alice);
      expect(first.parents, hasLength(16));
      expect(await history.import(first), GroupMembershipImport.accepted);
      // One head was left out; it and the merge are the two that remain.
      expect(history.hasConflict, isTrue);
      final second = await ownerMerge(history, alice);
      expect(second.parents, hasLength(2));
      expect(await history.import(second), GroupMembershipImport.accepted);
      expect(history.hasConflict, isFalse);
    });
  });

  group('MEDIUM: the merge keeps what every branch changed', () {
    test('additions, a role change and the title of one branch are kept with '
        'the other branch\'s additions and removal', () async {
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
      // The owner adds eve, renames the group and makes frank a moderator.
      final left = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol, frank, zed, eve],
        admins: ['carol'],
        moderators: ['frank'],
        title: 'Renamed',
      );
      // frank (still an admin on his branch) removes zed and adds nic.
      final right = await fx.record(
        owner: alice,
        author: frank,
        parents: [r1],
        deviceOnly: [carol, frank, nic],
        admins: ['carol', 'frank'],
        removed: ['zed'],
      );
      final history = fx.history(owner: alice);
      for (final r in [r1, left, right]) {
        expect(await history.import(r), GroupMembershipImport.accepted);
      }
      expect(history.hasConflict, isTrue);
      final merge = await ownerMerge(history, alice);
      final group = merge.group;
      expect(
        group.activeMemberDeviceIds,
        unorderedEquals(['alice', 'carol', 'frank', 'eve', 'nic']),
      );
      expect(group.removedDeviceIds, ['zed']);
      expect(group.title, 'Renamed');
      expect(group.roleFor('frank'), GroupMemberRole.moderator);
      expect(group.roleFor('carol'), GroupMemberRole.admin);
      expect(await history.import(merge), GroupMembershipImport.accepted);
      expect(history.hasConflict, isFalse);
    });

    test('a merge never holds more than sixteen members', () async {
      final r1 = await root();
      Future<GroupMembershipRecord> adds(String prefix, int n) async {
        final devices = [
          for (var i = 0; i < n; i++)
            await TestDevice.create('$prefix$i', 'acc-$prefix$i'),
        ];
        return fx.record(
          owner: alice,
          author: alice,
          parents: [r1],
          deviceOnly: [carol, ...devices],
        );
      }

      final left = await adds('l', 7);
      final right = await adds('r', 7);
      final history = fx.history(owner: alice);
      for (final r in [r1, left, right]) {
        await history.import(r);
      }
      final merge = await ownerMerge(history, alice);
      // alice, carol and fourteen more would be sixteen: exactly fits.
      expect(merge.group.activeMemberDeviceIds, hasLength(16));
      expect(await history.import(merge), GroupMembershipImport.accepted);
      final more = await adds('x', 7);
      final again = await adds('y', 7);
      final history2 = fx.history(owner: alice);
      for (final r in [r1, more, again, left]) {
        await history2.import(r);
      }
      final merge2 = await ownerMerge(history2, alice);
      expect(merge2.group.activeMemberDeviceIds, hasLength(16));
      expect(await history2.import(merge2), GroupMembershipImport.accepted);
    });

    test('a device removed before the fork and added again on one branch '
        'stays added', () async {
      final zed = await TestDevice.create('zed', 'acc-zed');
      final r1 = await fx.record(
        owner: alice,
        author: alice,
        deviceOnly: [carol, zed],
      );
      final removed = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        removed: ['zed'],
      );
      final readded = await fx.record(
        owner: alice,
        author: alice,
        parents: [removed],
        deviceOnly: [carol, zed],
      );
      final other = await fx.record(
        owner: alice,
        author: alice,
        parents: [removed],
        deviceOnly: [carol],
        removed: ['zed'],
        title: 'Other',
      );
      final history = fx.history(owner: alice);
      for (final r in [r1, removed, readded, other]) {
        await history.import(r);
      }
      expect(history.hasConflict, isTrue);
      final merge = await ownerMerge(history, alice);
      expect(merge.group.hasActiveMember('zed'), isTrue);
      expect(merge.group.removedDeviceIds, isNot(contains('zed')));
      expect(merge.group.title, 'Other');
      expect(await history.import(merge), GroupMembershipImport.accepted);
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
    // The events the author's own chain holds (what the journal would say).
    late Set<String> onChain;

    /// An admin device of an account admits Bob's account. [firstMessage]
    /// puts one event of the admin before the admitting record.
    Future<void> admit({
      bool firstMessage = false,
      bool admitsOnChain = true,
    }) async {
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
      onChain = {
        if (admitsOnChain) r3.proof.eventId,
        if (firstMessage) firstEvent.eventId,
      };
      al2 = await admAcc.list(2, [adm2], revoked: ['adm1']);
      view = DeviceListView(groupId: fx.groupId)
        ..offerVerified(al1, accountKey: admAcc.keys.publicKeyBase64)
        ..offerVerified(bl1, accountKey: bobAcc.keys.publicKeyBase64);
      history = fx.history(
        owner: alice,
        view: view,
        chain: (event, cutoff) async => onChain.contains(event.eventId),
      );
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

    /// The owner's record pinning the admin account's revocation, keeping
    /// everything else (Bob's account included).
    Future<GroupMembershipRecord> ownerPin(
      GroupMembershipRecord parent, {
      Map<String, GroupHistoryCheckpoint> checkpoints = const {},
    }) => fx.record(
      owner: alice,
      author: alice,
      parents: [parent],
      deviceOnly: [carol],
      checkpoints: checkpoints,
      accounts: [
        AccountSpec(admAcc, al2, [adm2], role: GroupAccountRole.admin),
        AccountSpec(bobAcc, bl1, [bob1]),
      ],
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
        expect(await history.admittedByRevokedAuthors(), {'bob1'});
        expect(await view.offerCutoff(await cutoff(last)), isTrue);
        // Bob was admitted well before: he receives again.
        expect(await history.admittedByRevokedAuthors(), isEmpty);
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
      expect(await history.admittedByRevokedAuthors(), {'bob1'});
    });

    test('a record that is not on the author\'s own chain is not before its '
        'cutoff, whatever its sequence number says', () async {
      // The record claims a number below the cutoff but the chain walked
      // from the cutoff does not reach it (a backdated fill-in).
      await admit(admitsOnChain: false);
      await fx.message(r3, adm1);
      final last = await fx.message(r3, adm1);
      view.offerVerified(al2, accountKey: admAcc.keys.publicKeyBase64);
      expect(await view.offerCutoff(await cutoff(last)), isTrue);
      expect(r3.proof.sequence, lessThan(last.sequence));
      expect(await history.admittedByRevokedAuthors(), {'bob1'});
    });

    test('the earlier of the owner\'s checkpoint and the sibling\'s cutoff '
        'counts', () async {
      await admit(firstMessage: true);
      final last = await fx.message(r3, adm1);
      view.offerVerified(al2, accountKey: admAcc.keys.publicKeyBase64);
      // The owner's pin carries its journal head for the admin: it covers
      // the admitting record too.
      final pin = await ownerPin(
        r3,
        checkpoints: {
          'adm1': GroupHistoryCheckpoint(
            sequence: last.sequence,
            eventId: last.eventId,
          ),
        },
      );
      expect(await history.import(pin), GroupMembershipImport.accepted);
      onChain.add(last.eventId);
      // Alone, that checkpoint would release the device (the owner has not
      // answered, but the record is below the checkpoint).
      expect(await history.admittedByRevokedAuthors(), isEmpty);
      // A sibling says the admin's honest events ended before the admitting
      // record: the earlier cutoff wins.
      expect(await view.offerCutoff(await cutoff(firstEvent)), isTrue);
      expect(await history.admittedByRevokedAuthors(), {'bob1'});
    });

    test('the owner\'s own revocation pin is no answer; a later owner record '
        'that still lists the device is', () async {
      await admit();
      view.offerVerified(al2, accountKey: admAcc.keys.publicKeyBase64);
      expect(await history.admittedByRevokedAuthors(), {'bob1'});
      final eve = await TestDevice.create('eve', 'acc-eve');
      final pin = await ownerPin(r3);
      expect(await history.import(pin), GroupMembershipImport.accepted);
      expect(history.current!.id, pin.id);
      // The pin keeps Bob, but nobody has looked at him yet.
      expect(await history.admittedByRevokedAuthors(), {'bob1'});
      final answer = await fx.record(
        owner: alice,
        author: alice,
        parents: [pin],
        deviceOnly: [carol, eve],
        accounts: [
          AccountSpec(admAcc, al2, [adm2], role: GroupAccountRole.admin),
          AccountSpec(bobAcc, bl1, [bob1]),
        ],
      );
      expect(await history.import(answer), GroupMembershipImport.accepted);
      expect(await history.admittedByRevokedAuthors(), isEmpty);
    });
  });

  group('M4: an account that left does not undo what its devices did', () {
    test('a sibling\'s deletion still counts after the account is removed, '
        'and a device-only newcomer with the same account id gets no such '
        'right', () async {
      final r1 = await root();
      final r2 = await withBob(r1);
      // bob1 writes; bob2 (the same account) deletes it.
      final original = await fx.sign(
        author: bob1,
        membershipId: r2.id,
        kind: GroupEventKind.message,
        payload: {'body': 'hello'},
      );
      final deletion = await fx.sign(
        author: bob2,
        membershipId: r2.id,
        kind: GroupEventKind.deletion,
        payload: {
          'targetEventId': original.eventId,
          'changedAt': fixtureEpoch.toIso8601String(),
        },
      );
      // The account is removed by the owner.
      final r3 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r2],
        deviceOnly: [carol],
      );
      final history = fx.history(owner: alice);
      for (final r in [r1, r2, r3]) {
        await history.import(r);
      }
      expect(r3.group.memberAccounts, isEmpty);
      GroupMessageProjection? project(GroupHistoryEvent mutation) =>
          GroupMessageProjection.reduce(original, [
            mutation,
          ], accountIdsAt: (event) => history.accountIdsAt(event.membershipId));
      // Judged at the record the deletion names, the account was a member.
      expect(history.accountIdsAt(deletion.membershipId), {'acc-bob'});
      expect(project(deletion)!.deleted, isTrue);
      // Judged by the head (no account left), the deletion would be undone.
      expect(
        GroupMessageProjection.reduce(original, [
          deletion,
        ], accountIds: history.accountIdsAt(r3.id))!.deleted,
        isFalse,
      );
      // A later device that merely calls itself 'acc-bob' is not the account.
      final impostor = await TestDevice.create('bob9', 'acc-bob');
      final late = await fx.sign(
        author: impostor,
        membershipId: r3.id,
        kind: GroupEventKind.deletion,
        payload: {
          'targetEventId': original.eventId,
          'changedAt': fixtureEpoch.toIso8601String(),
        },
      );
      expect(history.accountIdsAt(late.membershipId), isEmpty);
      expect(project(late)!.deleted, isFalse);
    });
  });
}
