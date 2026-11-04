part of 'messenger_controller_test.dart';

/// Groups by account (M29) inside the controller.
void _groupAccountsControllerTests() {
  group('groups by account', () {
    Future<void> settle(
      List<MessengerController> controllers, {
      bool Function()? until,
      int rounds = 40,
    }) async {
      for (var round = 0; round < rounds; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        if (until?.call() ?? false) return;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }

    test('a member that becomes an account is folded into the group by the '
        "owner's app, and the others follow", () async {
      final relay = _FakeRelayClient();
      final alice = await _createController(
        relayClient: relay,
        displayName: 'Alice',
      );
      final bob = await _createController(
        relayClient: relay,
        displayName: 'Bob',
      );
      final carol = await _createController(
        relayClient: relay,
        displayName: 'Carol',
      );
      for (final c in [alice, bob, carol]) {
        addTearDown(c.dispose);
      }
      alice.setOwnerWriterDelayForTesting(const Duration(milliseconds: 50));
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await _pairControllers(bob, carol);
      final group = await alice.createGroup(
        title: 'Account group',
        members: alice.contacts,
      );
      await settle(
        [alice, bob, carol],
        until: () =>
            bob.groups.any((g) => g.groupId == group.groupId) &&
            carol.groups.any((g) => g.groupId == group.groupId),
      );
      expect(bob.groups.any((g) => g.groupId == group.groupId), isTrue);
      GroupRecord of(MessengerController c) =>
          c.groups.firstWhere((g) => g.groupId == group.groupId);

      await bob.createAccount(deviceName: 'Bob phone');
      await settle(
        [alice, bob, carol],
        until: () =>
            of(alice).memberAccounts.isNotEmpty &&
            of(bob).memberAccounts.isNotEmpty &&
            of(carol).memberAccounts.isNotEmpty,
      );
      for (final c in [alice, bob, carol]) {
        final entry = of(c).memberAccounts.single;
        expect(entry.accountId, bob.identity!.accountId);
        expect(entry.role, GroupAccountRole.member);
        expect(of(c).hasActiveMember(bob.identity!.deviceId), isTrue);
      }
      // Still the same group and the same members.
      expect(of(carol).activeMemberDeviceIds, hasLength(3));
    });

    /// Alice owns a group with Bob and Carol; Bob made an account and linked
    /// a phone to it. Returns after the phone is a member everywhere.
    Future<
      ({
        MessengerController alice,
        MessengerController bob,
        MessengerController carol,
        MessengerController phone,
        String groupId,
        _FakeRelayClient relay,
        _InProcessIrohNetwork network,
      })
    >
    joinedPhone({
      DateTime Function()? aliceClock,
      bool settled = true,
      bool ownerWrites = true,
    }) async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> make(
        String name, {
        DateTime Function()? clock,
      }) => _createController(
        relayClient: relay,
        displayName: name,
        transportRegistryFactory: network.registry,
        nowProvider: clock,
      );
      final alice = await make('Alice', clock: aliceClock);
      final bob = await make('Bob');
      final carol = await make('Carol');
      final phone = await make('Bob phone');
      for (final c in [alice, bob, carol, phone]) {
        addTearDown(c.dispose);
      }
      alice.setOwnerWriterDelayForTesting(const Duration(milliseconds: 50));
      await _pairControllers(alice, bob);
      await _pairControllers(alice, carol);
      await _pairControllers(bob, carol);
      final group = await alice.createGroup(
        title: 'Account group',
        members: alice.contacts,
      );
      GroupRecord of(MessengerController c) =>
          c.groups.firstWhere((g) => g.groupId == group.groupId);
      bool has(MessengerController c) =>
          c.groups.any((g) => g.groupId == group.groupId);
      await settle([alice, bob, carol], until: () => has(bob) && has(carol));
      await bob.createAccount(deviceName: 'Bob laptop');
      await settle(
        [alice, bob, carol],
        until: () =>
            of(alice).memberAccounts.isNotEmpty &&
            of(carol).memberAccounts.isNotEmpty,
      );
      // From here the owner's app writes nothing more (a sibling stays one).
      if (!ownerWrites) {
        alice.setOwnerWriterDelayForTesting(const Duration(days: 1));
      }
      final qr = await phone.startLinkAsNewDevice();
      await bob.startLinkFromQrCode(qr);
      await _waitForIroh(
        () =>
            phone.linkState == LinkState.compareCode &&
            bob.linkState == LinkState.compareCode,
      );
      await phone.confirmLinkCode();
      await bob.confirmLinkCode();
      await _waitForIroh(() => phone.linkState == LinkState.linked);
      final phoneId = phone.identity!.deviceId;
      if (!settled) {
        return (
          alice: alice,
          bob: bob,
          carol: carol,
          phone: phone,
          groupId: group.groupId,
          relay: relay,
          network: network,
        );
      }
      await settle(
        [alice, bob, carol, phone],
        until: () =>
            (ownerWrites
                ? of(alice).memberDeviceIds.contains(phoneId) &&
                      of(phone).memberDeviceIds.contains(phoneId)
                : of(alice).hasActiveMember(phoneId)) &&
            of(carol).hasActiveMember(phoneId),
      );
      return (
        alice: alice,
        bob: bob,
        carol: carol,
        phone: phone,
        groupId: group.groupId,
        relay: relay,
        network: network,
      );
    }

    test(
      'a second device of an account member joins by itself and posts '
      'in the group',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        final all = [t.alice, t.bob, t.carol, t.phone];
        final phoneId = t.phone.identity!.deviceId;
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        expect(of(t.alice).hasActiveMember(phoneId), isTrue);
        expect(of(t.carol).hasActiveMember(phoneId), isTrue);
        // The owner pinned the new list: the signed record projects the phone.
        expect(of(t.alice).memberDeviceIds, contains(phoneId));
        expect(of(t.alice).memberAccounts.single.listVersion, 2);
        await t.phone.sendGroupMessage(groupId: t.groupId, body: 'from phone');
        bool got(MessengerController c) =>
            c.messagesForGroup(t.groupId).any((m) => m.body == 'from phone');
        await settle(all, until: () => got(t.carol) && got(t.alice));
        expect(got(t.carol), isTrue);
        expect(got(t.alice), isTrue);
      },
    );

    test(
      'a revoked device leaves the group at once and its later messages '
      'are refused',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        final all = [t.alice, t.bob, t.carol, t.phone];
        final phoneId = t.phone.identity!.deviceId;
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        await t.bob.revokeAccountDevice(phoneId);
        await settle(
          all,
          until: () =>
              !of(t.alice).hasActiveMember(phoneId) &&
              !of(t.carol).hasActiveMember(phoneId) &&
              !of(t.alice).memberDeviceIds.contains(phoneId),
        );
        expect(of(t.alice).hasActiveMember(phoneId), isFalse);
        expect(of(t.carol).hasActiveMember(phoneId), isFalse);
        // The owner's app pinned the revocation and dropped the device.
        expect(of(t.alice).memberDeviceIds, isNot(contains(phoneId)));
        try {
          await t.phone.sendGroupMessage(groupId: t.groupId, body: 'after');
        } catch (_) {}
        await settle(all, rounds: 8);
        for (final c in [t.alice, t.carol]) {
          expect(
            c.messagesForGroup(t.groupId).any((m) => m.body == 'after'),
            isFalse,
          );
        }
      },
    );

    test(
      'when one device of a member account leaves, the whole account '
      'leaves, through a record by the owner',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        final all = [t.alice, t.bob, t.carol, t.phone];
        final bobId = t.bob.identity!.deviceId;
        final phoneId = t.phone.identity!.deviceId;
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        await t.phone.leaveGroup(t.groupId);
        await settle(
          all,
          until: () =>
              of(t.alice).memberAccounts.isEmpty &&
              !of(t.carol).hasActiveMember(bobId),
        );
        expect(of(t.alice).memberAccounts, isEmpty);
        for (final c in [t.alice, t.carol]) {
          expect(of(c).hasActiveMember(bobId), isFalse);
          expect(of(c).hasActiveMember(phoneId), isFalse);
        }
      },
    );

    test(
      'a message from a device whose list has not arrived is kept and '
      'shown when it does',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(settled: false);
        final all = [t.alice, t.bob, t.carol, t.phone];
        // Written at once, before the others have heard of the phone.
        await t.phone.sendGroupMessage(groupId: t.groupId, body: 'early');
        bool got(MessengerController c) =>
            c.messagesForGroup(t.groupId).any((m) => m.body == 'early');
        await settle(
          all,
          until: () => got(t.carol) && got(t.alice),
          rounds: 80,
        );
        expect(got(t.carol), isTrue);
        expect(got(t.alice), isTrue);
      },
    );

    test(
      'parked envelopes are bounded, expire, and only come from devices '
      'in groups with accounts',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        var offset = Duration.zero;
        final t = await joinedPhone(
          aliceClock: () => DateTime.now().add(offset),
        );
        RelayEnvelope from(String sender, String id, {int pad = 0}) =>
            RelayEnvelope(
              kind: 'group_message',
              messageId: id,
              conversationId: t.groupId,
              senderAccountId: 'acc-x',
              senderDeviceId: sender,
              recipientDeviceId: t.alice.identity!.deviceId,
              createdAt: DateTime.now().toUtc(),
              ciphertextBase64: 'A' * pad,
            );
        expect(
          t.alice.isUnknownSiblingForTesting(from('dev-unknown', 'm0')),
          isTrue,
        );
        expect(
          t.alice.isUnknownSiblingForTesting(
            from(t.carol.identity!.deviceId, 'm0'),
          ),
          isFalse,
        );
        // Too large: not kept.
        expect(
          t.alice.parkSiblingEnvelopeForTesting(
            from('dev-unknown', 'big', pad: 70 * 1024),
          ),
          isFalse,
        );
        for (var i = 0; i < 60; i++) {
          t.alice.parkSiblingEnvelopeForTesting(from('dev-unknown', 'm$i'));
        }
        expect(
          t.alice.parkedSiblingEnvelopesForTesting.length,
          lessThanOrEqualTo(32),
        );
        // The oldest went first.
        expect(
          t.alice.parkedSiblingEnvelopesForTesting.last.envelopeJson,
          contains('"m59"'),
        );
        // A day later they are gone with the next one kept.
        offset = const Duration(hours: 25);
        t.alice.parkSiblingEnvelopeForTesting(from('dev-unknown', 'late'));
        expect(t.alice.parkedSiblingEnvelopesForTesting, hasLength(1));
      },
    );

    test(
      'parked envelopes are read again once their sender is a member',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        final carolId = t.carol.identity!.deviceId;
        RelayEnvelope parked(String id, String account, String sender) =>
            RelayEnvelope(
              kind: 'group_message',
              messageId: id,
              conversationId: t.groupId,
              senderAccountId: account,
              senderDeviceId: sender,
              recipientDeviceId: t.alice.identity!.deviceId,
              createdAt: DateTime.now().toUtc(),
            );
        t.alice.parkSiblingEnvelopeForTesting(
          parked('parked-1', t.carol.identity!.accountId, carolId),
        );
        t.alice.parkSiblingEnvelopeForTesting(
          parked('parked-2', 'acc-x', 'dev-still-unknown'),
        );
        expect(t.alice.parkedSiblingEnvelopesForTesting, hasLength(2));
        t.alice.replaySiblingParkedForTesting(t.groupId);
        await t.alice.settleSiblingReplaysForTesting();
        // The member's is read again; the unknown device's stays for its list.
        final left = t.alice.parkedSiblingEnvelopesForTesting;
        expect(left, hasLength(1));
        expect(left.single.senderDeviceId, 'dev-still-unknown');
      },
    );

    test(
      'announced profiles and pending upgrades expire',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        var offset = Duration.zero;
        final t = await joinedPhone(
          aliceClock: () => DateTime.now().add(offset),
        );
        final base = t.alice.groupAccountStateSizeForTesting;
        final profile = GroupMemberProfile(
          accountId: 'acc-z',
          deviceId: 'dev-z',
          displayName: 'z',
          bio: '',
          relayCapable: false,
          publicKeyBase64: '',
          routeHints: const [],
        );
        t.alice.noteSiblingAnnounceForTesting(
          t.groupId,
          profile,
          DateTime.now().toUtc(),
        );
        final account = await TestAccount.create('acc-q');
        final device = await TestDevice.create('dev-q', 'acc-q');
        t.alice.notePendingUpgradeForTesting(
          t.groupId,
          await account.upgrade(device),
          await account.list(1, [device]),
          DateTime.now().toUtc(),
        );
        expect(t.alice.pendingUpgradeCountForTesting(t.groupId), 1);
        offset = const Duration(days: 8);
        t.alice.expireGroupAccountStateForTesting();
        expect(t.alice.pendingUpgradeCountForTesting(t.groupId), 0);
        expect(
          t.alice.groupAccountStateSizeForTesting,
          lessThanOrEqualTo(base),
        );
      },
    );

    test(
      'resetting the identity clears the account state',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        t.alice.parkSiblingEnvelopeForTesting(
          RelayEnvelope(
            kind: 'group_message',
            messageId: 'p',
            conversationId: t.groupId,
            senderAccountId: 'a',
            senderDeviceId: 'dev-unknown',
            recipientDeviceId: t.alice.identity!.deviceId,
            createdAt: DateTime.now().toUtc(),
          ),
        );
        expect(t.alice.groupAccountStateSizeForTesting, greaterThan(0));
        await t.alice.resetIdentity();
        expect(t.alice.groupAccountStateSizeForTesting, 0);
        expect(t.alice.parkedSiblingEnvelopesForTesting, isEmpty);
        expect(t.alice.groups, isEmpty);
      },
    );

    test(
      'any device of an account edits, deletes and reacts for the account',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        final all = [t.alice, t.bob, t.carol, t.phone];
        ChatMessage? find(MessengerController c, String body) => c
            .messagesForGroup(t.groupId)
            .where((m) => m.body == body)
            .firstOrNull;
        await t.bob.sendGroupMessage(groupId: t.groupId, body: 'hello');
        await settle(
          all,
          until: () =>
              find(t.phone, 'hello') != null && find(t.carol, 'hello') != null,
        );
        final onPhone = find(t.phone, 'hello')!;
        // The phone edits what the laptop wrote (once its signed copy is
        // here).
        for (var attempt = 0; attempt < 20; attempt++) {
          try {
            await t.phone.changeGroupMessage(
              groupId: t.groupId,
              messageId: onPhone.id,
              body: 'edited on the phone',
            );
            break;
          } on StateError {
            await settle(all, rounds: 3);
          }
        }
        await settle(
          all,
          until: () => find(t.carol, 'edited on the phone') != null,
        );
        expect(find(t.carol, 'edited on the phone'), isNotNull);
        expect(find(t.bob, 'edited on the phone'), isNotNull);
        // Reactions count once per account: the phone sets it, the laptop's
        // toggle takes it back.
        final id = find(t.carol, 'edited on the phone')!.id;
        await t.phone.toggleGroupReaction(
          groupId: t.groupId,
          messageId: id,
          emoji: '+',
        );
        await settle(
          all,
          until: () =>
              find(t.carol, 'edited on the phone')!.reactions['+']?.length == 1,
          rounds: 250,
        );
        expect(
          find(t.carol, 'edited on the phone')!.reactions['+'],
          hasLength(1),
        );
        await t.bob.toggleGroupReaction(
          groupId: t.groupId,
          messageId: id,
          emoji: '+',
        );
        await settle(
          all,
          until: () =>
              (find(t.carol, 'edited on the phone')!.reactions['+'] ?? {})
                  .isEmpty,
        );
        expect(
          find(t.carol, 'edited on the phone')!.reactions['+'] ?? {},
          isEmpty,
        );
        // And deletes.
        await t.phone.changeGroupMessage(
          groupId: t.groupId,
          messageId: onPhone.id,
          delete: true,
        );
        await settle(
          all,
          until: () => find(t.carol, 'edited on the phone') == null,
          rounds: 250,
        );
        expect(find(t.carol, 'edited on the phone'), isNull);
      },
    );

    test(
      'admin edits of a group with an account member stay signed: adding, '
      'role changes and removal, and a refused record is never stored',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(ownerWrites: false);
        final dave = await _createController(
          relayClient: t.relay,
          displayName: 'Dave',
          transportRegistryFactory: t.network.registry,
        );
        addTearDown(dave.dispose);
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        final bobId = t.bob.identity!.deviceId;
        final phoneId = t.phone.identity!.deviceId;
        // A refused record (it adds a member with no identity) is not stored.
        final head = of(t.alice);
        final bad = head.signedView.copyWith(
          memberDeviceIds: [...head.memberDeviceIds, 'dev-nobody'],
          membershipVersion: head.membershipVersion + 1,
        );
        await expectLater(
          t.alice.commitGroupChangeForTesting(bad),
          throwsA(anything),
        );
        expect(of(t.alice).membershipVersion, head.membershipVersion);
        // A device-only member joins while the account's sibling is in the group.
        await _pairControllers(t.alice, dave);
        await t.alice.addGroupMembers(
          groupId: t.groupId,
          members: [
            t.alice.contacts.firstWhere(
              (c) => c.deviceId == dave.identity!.deviceId,
            ),
          ],
        );
        expect(of(t.alice).hasActiveMember(dave.identity!.deviceId), isTrue);
        // The owner can still sign: the account (with its sibling) gets a
        // role, then loses it, then is removed.
        await t.alice.setGroupMemberRole(
          groupId: t.groupId,
          memberDeviceId: bobId,
          role: GroupMemberRole.moderator,
        );
        expect(
          of(t.alice).memberAccounts.single.role,
          GroupAccountRole.moderator,
        );
        expect(of(t.alice).roleFor(bobId), GroupMemberRole.moderator);
        // The sibling is not in the signed projection yet: member powers.
        expect(of(t.alice).roleFor(phoneId), GroupMemberRole.member);
        await t.alice.setGroupMemberRole(
          groupId: t.groupId,
          memberDeviceId: bobId,
          role: GroupMemberRole.member,
        );
        expect(of(t.alice).memberAccounts.single.role, GroupAccountRole.member);
        await t.alice.removeGroupMember(
          groupId: t.groupId,
          memberDeviceId: phoneId,
        );
        expect(of(t.alice).memberAccounts, isEmpty);
        expect(of(t.alice).hasActiveMember(bobId), isFalse);
        expect(of(t.alice).hasActiveMember(phoneId), isFalse);
      },
    );
  });
}
