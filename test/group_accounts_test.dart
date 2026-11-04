import 'package:conest/src/account/account_model.dart';
import 'package:conest/src/group_account_member.dart';
import 'package:conest/src/group_accounts.dart';
import 'package:conest/src/group_history_event.dart';
import 'package:conest/src/group_message_projection.dart';
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
        accounts: [
          AccountSpec(bobAcc, l1, [bob1]),
        ],
      );
      final l2 = await bobAcc.list(2, [bob1, bob2]);
      final r3 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, l2, [bob1, bob2]),
        ],
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
        accounts: [
          AccountSpec(bobAcc, l1, [bob1]),
        ],
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
        accounts: [
          AccountSpec(bobAcc, l1, [bob1]),
        ],
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
        accounts: [
          AccountSpec(bobAcc, l1, [bob1, bob2]),
        ],
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
        accounts: [
          AccountSpec(bobAcc, l2, [bob1]),
        ],
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
        accounts: [
          AccountSpec(bobAcc, l1, [bob1, bob2]),
        ],
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
      final r1 = await fx.record(
        owner: alice1,
        author: alice1,
        deviceOnly: [carol],
      );
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
          AccountSpec(aliceAcc, l1, [
            alice1,
            alice2,
          ], role: GroupAccountRole.owner),
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

  Future<void> importAll(
    GroupMembershipHistory history,
    List<GroupMembershipRecord> records,
  ) async {
    var pending = [...records];
    while (pending.isNotEmpty) {
      final next = <GroupMembershipRecord>[];
      for (final record in pending) {
        final result = await history.import(record);
        if (result == GroupMembershipImport.missingParents ||
            result == GroupMembershipImport.missingDeviceLists) {
          next.add(record);
        }
      }
      if (next.length == pending.length) break;
      pending = next;
    }
  }

  Future<GroupMembershipRecord> pinBob(
    GroupMembershipRecord parent,
    AccountDeviceList list,
    List<TestDevice> projected, {
    TestDevice? author,
    List<String> approved = const [],
    List<String> excluded = const [],
    bool confirm = false,
    List<String> admins = const [],
  }) => fx.record(
    owner: alice,
    author: author ?? alice,
    parents: [parent],
    deviceOnly: [carol],
    admins: admins,
    confirmNewDevices: confirm,
    accounts: [
      AccountSpec(
        bobAcc,
        list,
        projected,
        approved: approved,
        excluded: excluded,
      ),
    ],
  );

  group('forks, forgeries and rollbacks', () {
    test('two lists that revoke each other make the account non-effective '
        'and its key can never come back', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await pinBob(r1, l1, [bob1, bob2]);
      final honest = await bobAcc.list(2, [bob1], revoked: ['bob2']);
      final thief = await bobAcc.list(2, [bob2, bob3], revoked: ['bob1']);
      final ra = await pinBob(r2, honest, [bob1]);
      final rb = await pinBob(r2, thief, [bob2]);
      final history = fx.history(owner: alice);
      await importAll(history, [r1, r2, ra, rb]);
      expect(history.hasConflict, isTrue);
      // Resolving the fork: projecting any device is refused.
      final bad = await pinBob(ra, honest, [bob1]);
      final merged = await fx.record(
        owner: alice,
        author: alice,
        parents: [ra, rb],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, honest, [bob1]),
        ],
      );
      expect(() => history.import(merged), throwsFormatException);
      final resolved = await fx.record(
        owner: alice,
        author: alice,
        parents: [ra, rb],
        deviceOnly: [carol],
        accounts: [AccountSpec(bobAcc, honest, const [])],
      );
      expect(await history.import(resolved), GroupMembershipImport.accepted);
      expect(bad.parents, [ra.id]);
      // The account is removed, and the compromised key cannot rejoin.
      final removed = await fx.record(
        owner: alice,
        author: alice,
        parents: [resolved],
        deviceOnly: [carol],
      );
      expect(await history.import(removed), GroupMembershipImport.accepted);
      final rejoin = await pinBob(removed, honest, const []);
      expect(() => history.import(rejoin), throwsFormatException);
      // The view agrees for message events.
      final view = DeviceListView(groupId: fx.groupId);
      for (final list in [l1, honest, thief]) {
        view.offerVerified(list, accountKey: bobAcc.keys.publicKeyBase64);
      }
      expect(view.compromised('acc-bob'), isTrue);
      expect(
        view.effectiveCerts(
          resolved.group.memberAccounts.single,
          confirmNewDevices: false,
        ),
        isEmpty,
      );
    });

    test('the view is the same whatever order lists arrive in', () async {
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final l2 = await bobAcc.list(2, [bob1], revoked: ['bob2']);
      final l3 = await bobAcc.list(3, [bob1, bob3], revoked: ['bob2']);
      String show(DeviceListView v) =>
          '${v.current('acc-bob')?.version} ${v.revoked('acc-bob').toList()..sort()} ${v.compromised('acc-bob')}';
      final shown = <String>{};
      for (final order in [
        [l1, l2, l3],
        [l3, l2, l1],
        [l2, l1, l3],
        [l3, l1, l2],
      ]) {
        final view = DeviceListView(groupId: fx.groupId);
        for (final l in order) {
          view.offerVerified(l, accountKey: bobAcc.keys.publicKeyBase64);
        }
        shown.add(show(view));
      }
      expect(shown, hasLength(1));
      expect(shown.single, startsWith('3 [bob2] false'));
    });

    test('forged lists are refused whole: wrong key, other account, '
        'rollback by an admin', () async {
      final r1 = await fx.record(
        owner: alice,
        author: alice,
        deviceOnly: [carol],
        admins: ['carol'],
      );
      final stranger = await TestAccount.create('acc-bob');
      final l2 = await bobAcc.list(2, [bob1]);
      final wrongKey = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        admins: ['carol'],
        accounts: [
          AccountSpec(bobAcc, l2, [
            bob1,
          ], keyOverride: stranger.keys.publicKeyBase64),
        ],
      );
      final history = fx.history(owner: alice);
      await history.import(r1);
      expect(() => history.import(wrongKey), throwsFormatException);
      final otherAccount = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        admins: ['carol'],
        accounts: [
          AccountSpec(bobAcc, await danAcc.list(2, [dan1]), []),
        ],
      );
      expect(() => history.import(otherAccount), throwsFormatException);
      final r2 = await pinBob(r1, l2, [bob1], admins: ['carol']);
      expect(await history.import(r2), GroupMembershipImport.accepted);
      // An admin pins the older list again: refused. The owner may.
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final rollback = await pinBob(
        r2,
        l1,
        [bob1],
        author: carol,
        admins: ['carol'],
      );
      expect(() => history.import(rollback), throwsFormatException);
    });

    test(
      'a certificate cannot take a device id another identity pinned',
      () async {
        final r1 = await root(members: [carol, eve]);
        final fakeEve = await TestDevice.create('eve', 'acc-bob');
        final l1 = await bobAcc.list(1, [bob1, fakeEve]);
        // eve left the group, but its id stays pinned in the ancestry.
        final r2 = await fx.record(
          owner: alice,
          author: alice,
          parents: [r1],
          deviceOnly: [carol],
          accounts: [
            AccountSpec(bobAcc, l1, [bob1]),
          ],
        );
        final history = fx.history(owner: alice);
        await history.import(r1);
        expect(
          () => history.import(r2),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('pinned identity'),
            ),
          ),
        );
      },
    );

    test('an admin adds an account only as a member', () async {
      final r1 = await fx.record(
        owner: alice,
        author: alice,
        deviceOnly: [carol],
        admins: ['carol'],
      );
      final l1 = await bobAcc.list(1, [bob1]);
      Future<GroupMembershipRecord> add(GroupAccountRole role) => fx.record(
        owner: alice,
        author: carol,
        parents: [r1],
        deviceOnly: [carol],
        admins: ['carol'],
        accounts: [AccountSpec(bobAcc, l1, const [], role: role)],
      );
      final history = fx.history(owner: alice);
      await history.import(r1);
      expect(
        () async => history.import(await add(GroupAccountRole.admin)),
        throwsFormatException,
      );
      expect(
        await history.import(await add(GroupAccountRole.member)),
        GroupMembershipImport.accepted,
      );
    });

    test(
      'accounts mode needs an owner and admins that know accounts',
      () async {
        final r1 = await fx.record(
          owner: alice,
          author: alice,
          deviceOnly: [carol],
          profileOverrides: {'alice': alice.profile(capable: false)},
        );
        final l1 = await bobAcc.list(1, [bob1]);
        final r2 = await fx.record(
          owner: alice,
          author: alice,
          parents: [r1],
          deviceOnly: [carol],
          profileOverrides: {'alice': alice.profile(capable: false)},
          accounts: [
            AccountSpec(bobAcc, l1, [bob1]),
          ],
        );
        final history = fx.history(owner: alice);
        await history.import(r1);
        expect(() => history.import(r2), throwsFormatException);
      },
    );
  });

  group('folding a device-only member into an account', () {
    Future<GroupMembershipRecord> fold(
      GroupMembershipRecord parent,
      TestAccount account,
      TestDevice device,
      List<TestDevice> projected, {
      AccountUpgrade? upgrade,
      TestAccount? signer,
    }) async => fx.record(
      owner: alice,
      author: alice,
      parents: [parent],
      deviceOnly: [carol],
      accounts: [
        AccountSpec(
          account,
          await account.list(1, projected),
          projected,
          upgrade: upgrade ?? await (signer ?? account).upgrade(device),
          admission: parent.admissions[device.id],
        ),
      ],
    );

    test('needs the member own proof for this account key', () async {
      final r1 = await root(members: [carol, dan1]);
      final history = fx.history(owner: alice);
      await history.import(r1);
      final good = await fold(r1, danAcc, dan1, [dan1, dan2]);
      expect(await history.import(good), GroupMembershipImport.accepted);
      expect(good.group.memberAccounts.single.upgrade, isNotNull);
      // A proof by another account key does not fold the member.
      final other = await TestAccount.create('acc-dan');
      final h2 = fx.history(owner: alice);
      await h2.import(r1);
      final forged = await fold(r1, danAcc, dan1, [
        dan1,
      ], upgrade: await other.upgrade(dan1));
      expect(() => h2.import(forged), throwsFormatException);
      // Neither does one without it.
      final bare = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(danAcc, await danAcc.list(1, [dan1]), [
            dan1,
          ], admission: r1.admissions['dan1']),
        ],
      );
      expect(() => h2.import(bare), throwsFormatException);
    });
  });

  group('confirming new devices', () {
    test('a new device waits for approval; switching it on approves all '
        'current devices', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1]);
      final r2 = await pinBob(r1, l1, [bob1]);
      final history = fx.history(owner: alice);
      await importAll(history, [r1, r2]);
      // Not approving the current device in the same record is refused.
      final noApproval = await pinBob(r2, l1, [bob1], confirm: true);
      expect(() => history.import(noApproval), throwsFormatException);
      final on = await pinBob(
        r2,
        l1,
        [bob1],
        confirm: true,
        approved: ['bob1'],
      );
      expect(await history.import(on), GroupMembershipImport.accepted);
      // A new device bob2 in a newer list is not projected until approved.
      final l2 = await bobAcc.list(2, [bob1, bob2]);
      final unapproved = await pinBob(
        on,
        l2,
        [bob1, bob2],
        confirm: true,
        approved: ['bob1'],
      );
      expect(() => history.import(unapproved), throwsFormatException);
      final approved = await pinBob(
        on,
        l2,
        [bob1, bob2],
        confirm: true,
        approved: ['bob1', 'bob2'],
      );
      expect(await history.import(approved), GroupMembershipImport.accepted);
      // For message events the sibling stays pending until approved.
      final view = DeviceListView(groupId: fx.groupId)
        ..offerVerified(l2, accountKey: bobAcc.keys.publicKeyBase64);
      final pendingHistory = fx.history(owner: alice, view: view);
      await importAll(pendingHistory, [r1, r2, on]);
      final entry = on.group.memberAccounts.single;
      expect(
        view
            .effectiveCerts(entry, confirmNewDevices: true)
            .map((c) => c.deviceId),
        ['bob1'],
      );
      expect(view.pendingCerts(entry).map((c) => c.deviceId), ['bob2']);
    });
  });

  group('message events of sibling devices', () {
    test('a second device posts and receives; strangers and pending devices '
        'do not; a new account sees history only from its admission', () async {
      final r1 = await fx.record(
        owner: alice,
        author: alice,
        deviceOnly: [carol],
        visibility: GroupHistoryVisibility.sinceAdmission,
      );
      final before = await fx.message(r1, carol);
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r1],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, l1, [bob1]),
        ],
        checkpoints: {
          'carol': GroupHistoryCheckpoint(
            sequence: before.sequence,
            eventId: before.eventId,
          ),
        },
      );
      final view = DeviceListView(groupId: fx.groupId)
        ..offerVerified(l1, accountKey: bobAcc.keys.publicKeyBase64);
      final history = fx.history(owner: alice, view: view);
      await importAll(history, [r1, r2]);
      final fromSibling = await fx.message(r2, bob2);
      final after = await fx.message(r2, carol);
      expect(
        await history.canReceive(fromSibling, recipientDeviceId: 'carol'),
        isTrue,
      );
      expect(
        await history.canReceive(after, recipientDeviceId: 'bob2'),
        isTrue,
      );
      // History from before the account was admitted stays closed, for the
      // sibling as for the projected device.
      expect(
        await history.canReceive(before, recipientDeviceId: 'bob2'),
        isFalse,
      );
      expect(
        await history.canReceive(before, recipientDeviceId: 'bob1'),
        isFalse,
      );
      // A device the list does not know is not a member.
      final stranger = await fx.message(r2, bob3);
      expect(
        await history.canReceive(stranger, recipientDeviceId: 'carol'),
        isFalse,
      );
      expect(
        await history.canReceive(after, recipientDeviceId: 'bob3'),
        isFalse,
      );
    });
  });

  group('limits', () {
    test('a byte cap on the list store never refuses a record that is '
        'rebuilt from retained lists', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1]);
      final l2 = await bobAcc.list(2, [bob1, bob2]);
      final r2 = await pinBob(r1, l1, [bob1]);
      final r3 = await pinBob(r2, l2, [bob1, bob2]);
      // Junk fills the store far over its cap.
      for (var i = 3; i < 60; i++) {
        fx.lists.put(await bobAcc.list(i, [bob1, bob2, bob3]));
      }
      final history = fx.history(owner: alice);
      await importAll(history, [r1, r2, r3]);
      final pinned = fx.lists.pinnedDigests;
      expect(pinned, hasLength(2));
      final dropped = fx.lists.evictUnpinned(maxUnpinnedBytes: 0);
      expect(dropped, greaterThan(50));
      for (final digest in pinned) {
        expect(fx.lists.get(digest), isNotNull);
      }
      // A fresh index over the same store (a restart) accepts everything.
      final rebuilt = fx.history(owner: alice);
      await importAll(rebuilt, [r1, r2, r3]);
      expect(rebuilt.current!.id, r3.id);
    });
  });

  group('resolved group', () {
    test('siblings join, revoked projected devices leave, a fork empties '
        'the account, pending devices are listed', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await pinBob(r1, l1, [bob1]);
      final signed = r2.group;
      final view = DeviceListView(groupId: fx.groupId);
      // Nothing known yet: the signed projection stands.
      expect(
        resolveGroup(signed, view).group.activeMemberDeviceIds,
        containsAll(['alice', 'carol', 'bob1']),
      );
      view.offerVerified(l1, accountKey: bobAcc.keys.publicKeyBase64);
      var resolved = resolveGroup(signed, view);
      expect(resolved.group.hasActiveMember('bob2'), isTrue);
      expect(resolved.group.roleFor('bob2'), GroupMemberRole.member);
      expect(signed.hasActiveMember('bob2'), isFalse);
      expect(resolved.group.toJson().containsKey('siblingProfiles'), isFalse);
      // A device id this device knows with other keys is ignored.
      resolved = resolveGroup(
        signed,
        view,
        conflictsWithKnownIdentity: (id, cert) => id == 'bob2',
      );
      expect(resolved.group.hasActiveMember('bob2'), isFalse);
      expect(resolved.unverifiedDeviceIds, ['bob2']);
      // bob1 is revoked: it leaves, though the record still projects it.
      view.offerVerified(
        await bobAcc.list(2, [bob2], revoked: ['bob1']),
        accountKey: bobAcc.keys.publicKeyBase64,
      );
      resolved = resolveGroup(signed, view);
      expect(resolved.group.hasActiveMember('bob1'), isFalse);
      expect(resolved.group.hasActiveMember('bob2'), isTrue);
      // A fork leaves nobody.
      view.offerVerified(
        await bobAcc.list(3, [bob1, bob3], revoked: ['bob2']),
        accountKey: bobAcc.keys.publicKeyBase64,
      );
      resolved = resolveGroup(signed, view);
      expect(resolved.compromisedAccountIds, ['acc-bob']);
      for (final id in ['bob1', 'bob2', 'bob3']) {
        expect(resolved.group.hasActiveMember(id), isFalse);
      }
      expect(resolved.group.hasActiveMember('carol'), isTrue);
    });
  });

  group('delivery to a member account', () {
    test('delivered when any device has it, read when any has read it; the '
        'rest stop being sent to once one read', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await pinBob(r1, l1, [bob1, bob2]);
      final group = r2.group;
      final states = {
        'carol': DeliveryState.delivered,
        'bob1': DeliveryState.delivered,
        'bob2': DeliveryState.pending,
      };
      final folded = foldAccountDeliveryStates(group, states);
      expect(folded.keys, containsAll(['carol', 'account:acc-bob']));
      expect(folded['account:acc-bob'], DeliveryState.delivered);
      expect(accountHasRead(group, 'bob2', states), isFalse);
      final read = {...states, 'bob1': DeliveryState.read};
      expect(
        foldAccountDeliveryStates(group, read)['account:acc-bob'],
        DeliveryState.read,
      );
      // bob2 is not waited for any more once bob1 read it.
      expect(accountHasRead(group, 'bob2', read), isTrue);
      // A group without accounts is untouched.
      final plain = r1.group;
      expect(foldAccountDeliveryStates(plain, states), same(states));
    });
  });

  group('compatibility', () {
    test('a group without accounts serializes as before', () async {
      final r1 = await root();
      final json = r1.group.toJson();
      expect(json.containsKey('memberAccounts'), isFalse);
      expect(json.containsKey('confirmNewDevices'), isFalse);
      expect(json.containsKey('siblingProfiles'), isFalse);
      // The local resolved view never reaches the wire either.
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await pinBob(r1, l1, [bob1]);
      final view = DeviceListView(groupId: fx.groupId)
        ..offerVerified(l1, accountKey: bobAcc.keys.publicKeyBase64);
      final resolved = resolveGroup(r2.group, view).group;
      expect(resolved.hasActiveMember('bob2'), isTrue);
      expect(
        GroupRecord.fromJson(resolved.toJson()).hasActiveMember('bob2'),
        isFalse,
      );
    });
  });

  group('messages of a member account', () {
    test('any device of the account changes and reacts for it; a name '
        'someone else chose never merges devices', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await pinBob(r1, l1, [bob1, bob2]);
      final original = await fx.message(r2, bob1);
      final payloadOriginal = GroupHistoryEvent.decode(original.encode());
      // The projection needs a body.
      final text = await fx.sign(
        author: bob1,
        membershipId: r2.id,
        kind: GroupEventKind.message,
        payload: {'messageId': 'm1', 'body': 'hi'},
      );
      Future<GroupHistoryEvent> mutate(
        TestDevice by,
        GroupEventKind kind,
        Map<String, Object?> extra,
      ) => fx.sign(
        author: by,
        membershipId: r2.id,
        kind: kind,
        payload: {
          'targetEventId': text.eventId,
          'changedAt': fixtureEpoch.toIso8601String(),
          ...extra,
        },
      );
      final edit = await mutate(bob2, GroupEventKind.edit, {'body': 'edited'});
      final react1 = await mutate(bob1, GroupEventKind.reaction, {
        'emoji': '+',
        'active': true,
      });
      final react2 = await mutate(bob2, GroupEventKind.reaction, {
        'emoji': '+',
        'active': true,
      });
      expect(payloadOriginal.eventId, original.eventId);
      // As account: the sibling's edit counts, and two devices react once.
      final asAccount = GroupMessageProjection.reduce(
        text,
        [edit, react1, react2],
        accountIds: {'acc-bob'},
      )!;
      expect(asAccount.body, 'edited');
      expect(asAccount.reactions['+'], hasLength(1));
      // As two separate members (no signed account): neither merges.
      final asDevices = GroupMessageProjection.reduce(text, [
        edit,
        react1,
        react2,
      ])!;
      expect(asDevices.body, 'hi');
      expect(asDevices.reactions['+'], hasLength(2));
    });
  });

  group('view and signed record together', () {
    test('a revoked projected device is held to the owner checkpoint even '
        'when the view knows the revocation and has no cutoff', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1, bob2]);
      final r2 = await pinBob(r1, l1, [bob1, bob2]);
      final e1 = await fx.message(r2, bob2);
      final e2 = await fx.message(r2, bob2);
      final e3 = await fx.message(r2, bob2);
      final l2 = await bobAcc.list(2, [bob1], revoked: ['bob2']);
      final r3 = await fx.record(
        owner: alice,
        author: alice,
        parents: [r2],
        deviceOnly: [carol],
        accounts: [
          AccountSpec(bobAcc, l2, [bob1]),
        ],
        checkpoints: {
          'bob2': GroupHistoryCheckpoint(
            sequence: e2.sequence,
            eventId: e2.eventId,
          ),
        },
      );
      final chain = {e1.eventId, e2.eventId};
      final view = DeviceListView(groupId: fx.groupId)
        ..offerVerified(l1, accountKey: bobAcc.keys.publicKeyBase64)
        ..offerVerified(l2, accountKey: bobAcc.keys.publicKeyBase64);
      final history = fx.history(
        owner: alice,
        view: view,
        chain: (event, cutoff) async => chain.contains(event.eventId),
      );
      await importAll(history, [r1, r2, r3]);
      Future<bool> counts(GroupHistoryEvent e) =>
          history.canReceive(e, recipientDeviceId: 'carol');
      expect(await counts(e1), isTrue);
      expect(await counts(e2), isTrue);
      expect(await counts(e3), isFalse);
      // A device no record ever listed has no checkpoint: it needs a cutoff.
      final l3 = await bobAcc.list(3, [bob1], revoked: ['bob2', 'bob3']);
      view.offerVerified(l3, accountKey: bobAcc.keys.publicKeyBase64);
      final l1b = await bobAcc.list(1, [bob1, bob2, bob3]);
      view.offerVerified(l1b, accountKey: bobAcc.keys.publicKeyBase64);
      final stray = await fx.message(r3, bob3);
      expect(await counts(stray), isFalse);
    });

    test('a device id belongs to the first holder: a later claimant is '
        'ignored and the rightful device stays', () async {
      final r1 = await root();
      final l1 = await bobAcc.list(1, [bob1]);
      final r2 = await pinBob(r1, l1, [bob1]);
      // Dan's list names bob1's device id with the stranger's keys.
      final fakeBob1 = await TestDevice.create('bob1', 'acc-dan');
      final dl = await danAcc.list(1, [fakeBob1, dan2]);
      final group = r2.group.copyWith(
        memberAccounts: [
          ...r2.group.memberAccounts,
          GroupAccountMember(
            accountId: 'acc-dan',
            accountKeyBase64: danAcc.keys.publicKeyBase64,
            role: GroupAccountRole.member,
            listVersion: 1,
            listDigest: fx.lists.put(dl),
          ),
        ],
      );
      final view = DeviceListView(groupId: fx.groupId)
        ..offerVerified(l1, accountKey: bobAcc.keys.publicKeyBase64)
        ..offerVerified(dl, accountKey: danAcc.keys.publicKeyBase64);
      final resolved = resolveGroup(group, view).group;
      expect(resolved.hasActiveMember('bob1'), isTrue);
      expect(resolved.memberProfileFor('bob1')!.accountId, 'acc-bob');
      expect(resolved.hasActiveMember('dan2'), isTrue);
    });

    test(
      'lists seen under another key than the record holds are not used',
      () async {
        final r1 = await root();
        final l1 = await bobAcc.list(1, [bob1, bob2]);
        final r2 = await pinBob(r1, l1, [bob1]);
        final other = await TestAccount.create('acc-bob');
        final view = DeviceListView(groupId: fx.groupId)
          ..offerVerified(
            await other.list(5, [bob1, bob3]),
            accountKey: other.keys.publicKeyBase64,
          );
        final entry = r2.group.memberAccounts.single;
        expect(view.effectiveCerts(entry, confirmNewDevices: false), isEmpty);
        expect(view.knows(entry), isFalse);
        expect(
          view.certFor('acc-bob', 'bob3', accountKey: entry.accountKeyBase64),
          isNull,
        );
        // The signed projection stands.
        expect(
          resolveGroup(r2.group, view).group.hasActiveMember('bob1'),
          isTrue,
        );
      },
    );
  });
}
