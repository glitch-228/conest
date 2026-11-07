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
      Duration? deputyDelay,
      bool confirmFirst = false,
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
      if (deputyDelay != null) {
        bob.setDeputyDelayForTesting(deputyDelay);
        phone.setDeputyDelayForTesting(deputyDelay);
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
      if (confirmFirst) {
        await alice.setConfirmNewDevices(group.groupId, true);
        await settle(
          [alice, bob, carol],
          until: () => of(carol).confirmNewDevices && of(bob).confirmNewDevices,
          rounds: 100,
        );
      }
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
      if (confirmFirst) {
        await settle(
          [alice, bob, carol, phone],
          until: () => alice
              .groupAccountStatus(group.groupId)!
              .pendingDeviceIds
              .contains(phoneId),
          rounds: 150,
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
      'envelopes that become due while a replay runs are read in a second '
      'pass',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        final carol = t.carol.identity!;
        RelayEnvelope parked(String id) => RelayEnvelope(
          kind: 'group_message',
          messageId: id,
          conversationId: t.groupId,
          senderAccountId: carol.accountId,
          senderDeviceId: carol.deviceId,
          recipientDeviceId: t.alice.identity!.deviceId,
          createdAt: DateTime.now().toUtc(),
        );
        t.alice.parkSiblingEnvelopeForTesting(parked('first'));
        t.alice.replaySiblingParkedForTesting(t.groupId);
        // Parked while the first replay is running: its call returns early.
        t.alice.parkSiblingEnvelopeForTesting(parked('second'));
        t.alice.replaySiblingParkedForTesting(t.groupId);
        await t.alice.settleSiblingReplaysForTesting();
        expect(t.alice.parkedSiblingEnvelopesForTesting, isEmpty);
      },
    );

    test(
      'an announced profile is the sender\'s own, and one account cannot '
      'crowd the others out of the slots',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(ownerWrites: false);
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        Future<void> announce(
          MessengerController from,
          Map<String, Object?> profile,
        ) => t.alice.handleGroupDevicesForTesting(
          t.groupId,
          from.identity!.deviceId,
          {
            'version': 1,
            'groupId': t.groupId,
            'type': 'devices',
            'announce': profile,
          },
        );
        final carol = t.carol.identity!;
        final carolProfile = of(t.alice).memberProfileFor(carol.deviceId)!;
        final base = t.alice.groupAccountStateSizeForTesting;
        // Another account's id in a profile is not the sender's to announce.
        await announce(t.carol, {
          ...carolProfile.toJson(),
          'accountId': 'acc-victim',
        });
        expect(t.alice.groupAccountStateSizeForTesting, base);
        // Sixteen slots taken under Carol's account leave none for her own.
        for (var i = 0; i < 16; i++) {
          t.alice.noteSiblingAnnounceForTesting(
            t.groupId,
            GroupMemberProfile.fromJson({
              ...carolProfile.toJson(),
              'deviceId': 'dev-fake-$i',
            }),
            DateTime.now().toUtc(),
          );
        }
        final full = t.alice.groupAccountStateSizeForTesting;
        await announce(t.carol, carolProfile.toJson());
        expect(t.alice.groupAccountStateSizeForTesting, full);
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
      'a deletion by a device of an account stays after the account leaves, '
      'for a member who reads the history later',
      timeout: const Timeout(Duration(minutes: 4)),
      () async {
        final t = await joinedPhone();
        final all = [t.alice, t.bob, t.carol, t.phone];
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        ChatMessage? find(MessengerController c, String body) => c
            .messagesForGroup(t.groupId)
            .where((m) => m.body == body && !m.deleted)
            .firstOrNull;
        await t.bob.sendGroupMessage(groupId: t.groupId, body: 'doomed');
        await t.bob.sendGroupMessage(groupId: t.groupId, body: 'kept');
        await settle(
          all,
          until: () =>
              find(t.phone, 'doomed') != null && find(t.carol, 'kept') != null,
        );
        final onPhone = find(t.phone, 'doomed')!;
        for (var attempt = 0; attempt < 20; attempt++) {
          try {
            await t.phone.changeGroupMessage(
              groupId: t.groupId,
              messageId: onPhone.id,
              delete: true,
            );
            break;
          } on StateError {
            await settle(all, rounds: 3);
          }
        }
        await settle(
          all,
          until: () => find(t.carol, 'doomed') == null,
          rounds: 250,
        );
        expect(find(t.carol, 'doomed'), isNull);
        // The account leaves the group.
        final bobId = t.bob.identity!.deviceId;
        await t.bob.leaveGroup(t.groupId);
        await settle(
          all,
          until: () => !of(t.carol).hasActiveMember(bobId),
          rounds: 250,
        );
        expect(of(t.carol).memberAccounts, isEmpty);
        // Dave joins afterwards and reads the retained history.
        final dave = await _createController(
          relayClient: t.relay,
          displayName: 'Dave',
          transportRegistryFactory: t.network.registry,
        );
        addTearDown(dave.dispose);
        await _pairControllers(t.alice, dave);
        await t.alice.addGroupMembers(
          groupId: t.groupId,
          members: [
            t.alice.contacts.firstWhere(
              (c) => c.deviceId == dave.identity!.deviceId,
            ),
          ],
        );
        await settle(
          [t.alice, t.carol, dave],
          until: () => find(dave, 'kept') != null,
          rounds: 300,
        );
        expect(find(dave, 'kept'), isNotNull);
        expect(find(dave, 'doomed'), isNull);
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
        // The invitee has no history yet: it believes the group once the
        // signed records back to the root, pulled from the sender, check out.
        await settle(
          [t.alice, t.bob, t.carol, t.phone, dave],
          until: () => dave.groups.any((g) => g.groupId == t.groupId),
          rounds: 200,
        );
        final joined = dave.groups.firstWhere((g) => g.groupId == t.groupId);
        expect(joined.memberAccounts, isNotEmpty);
        expect(joined.hasActiveMember(dave.identity!.deviceId), isTrue);
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

    test(
      'a sibling pins the revocation of its own account when the owner is '
      'away',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(
          deputyDelay: const Duration(milliseconds: 50),
        );
        final all = [t.alice, t.bob, t.carol, t.phone];
        final phoneId = t.phone.identity!.deviceId;
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        expect(of(t.alice).memberDeviceIds, contains(phoneId));
        // The owner's app writes nothing from here; the laptop steps in.
        t.alice.setOwnerWriterDelayForTesting(const Duration(days: 1));
        await t.bob.revokeAccountDevice(phoneId);
        await settle(
          all,
          until: () =>
              !of(t.alice).memberDeviceIds.contains(phoneId) &&
              !of(t.carol).memberDeviceIds.contains(phoneId),
          rounds: 200,
        );
        expect(of(t.alice).memberDeviceIds, isNot(contains(phoneId)));
        expect(of(t.carol).hasActiveMember(phoneId), isFalse);
        expect(of(t.alice).membershipVersion, greaterThan(3));
      },
    );

    test(
      'a sibling and the owner write at once: the owner merges the fork and '
      'the group keeps working',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(deputyDelay: const Duration(days: 1));
        final all = [t.alice, t.bob, t.carol, t.phone];
        final phoneId = t.phone.identity!.deviceId;
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        t.alice.setOwnerWriterDelayForTesting(const Duration(days: 1));
        await t.bob.revokeAccountDevice(phoneId);
        // Both know the revocation; neither has written a record for it.
        await settle(
          all,
          until: () =>
              !of(t.alice).hasActiveMember(phoneId) &&
              !of(t.bob).hasActiveMember(phoneId),
          rounds: 200,
        );
        expect(of(t.alice).memberDeviceIds, contains(phoneId));
        final base = of(t.alice).membershipVersion;
        expect(of(t.bob).membershipVersion, base);
        // Neither reaches the other while both sign.
        final alicePoint = t.alice.identity!.irohEndpointId!;
        final bobPoint = t.bob.identity!.irohEndpointId!;
        t.network.blockedPairs
          ..add((alicePoint, bobPoint))
          ..add((bobPoint, alicePoint));
        t.alice.setOwnerWriterDelayForTesting(const Duration(milliseconds: 50));
        await t.alice.runOwnerWriterForTesting(t.groupId);
        await t.bob.runDeputyForTesting(t.groupId);
        expect(of(t.alice).membershipVersion, base + 1);
        expect(of(t.bob).membershipVersion, base + 1);
        // They meet again: two records on one parent. The owner resolves it.
        t.network.blockedPairs.clear();
        await settle(
          all,
          until: () =>
              of(t.alice).membershipVersion == base + 2 &&
              of(t.bob).membershipVersion == base + 2 &&
              of(t.carol).membershipVersion == base + 2,
          rounds: 300,
        );
        for (final c in [t.alice, t.bob, t.carol]) {
          expect(of(c).membershipVersion, base + 2);
          expect(of(c).memberDeviceIds, isNot(contains(phoneId)));
        }
        // Group traffic flows again.
        await t.carol.sendGroupMessage(groupId: t.groupId, body: 'after fork');
        bool got(MessengerController c) =>
            c.messagesForGroup(t.groupId).any((m) => m.body == 'after fork');
        await settle(all, until: () => got(t.alice) && got(t.bob), rounds: 100);
        expect(got(t.alice), isTrue);
        expect(got(t.bob), isTrue);
      },
    );

    test(
      'a leave that arrives while the group is forked is recorded after the '
      'merge, and merges are rate limited',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(deputyDelay: const Duration(days: 1));
        final all = [t.alice, t.bob, t.carol, t.phone];
        final phoneId = t.phone.identity!.deviceId;
        final carolId = t.carol.identity!.deviceId;
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        t.alice.setOwnerWriterDelayForTesting(const Duration(days: 1));
        await t.bob.revokeAccountDevice(phoneId);
        await settle(
          all,
          until: () =>
              !of(t.alice).hasActiveMember(phoneId) &&
              !of(t.bob).hasActiveMember(phoneId),
          rounds: 200,
        );
        final base = of(t.alice).membershipVersion;
        final alicePoint = t.alice.identity!.irohEndpointId!;
        final bobPoint = t.bob.identity!.irohEndpointId!;
        t.network.blockedPairs
          ..add((alicePoint, bobPoint))
          ..add((bobPoint, alicePoint));
        t.alice.setOwnerWriterDelayForTesting(const Duration(milliseconds: 50));
        await t.alice.runOwnerWriterForTesting(t.groupId);
        await t.bob.runDeputyForTesting(t.groupId);
        // The owner's app is slow to act: a day until its writer runs.
        t.alice.setOwnerWriterDelayForTesting(const Duration(days: 1));
        t.network.blockedPairs.clear();
        for (var i = 0; i < 100; i++) {
          if (await t.alice.hasMembershipConflictForTesting(t.groupId)) break;
          await settle(all, rounds: 2);
        }
        expect(
          await t.alice.hasMembershipConflictForTesting(t.groupId),
          isTrue,
        );
        // Carol leaves in the middle of the fork.
        await t.carol.leaveGroup(t.groupId);
        await settle(
          all,
          until: () => !of(t.alice).hasActiveMember(carolId),
          rounds: 200,
        );
        expect(of(t.alice).hasActiveMember(carolId), isFalse);
        expect(
          await t.alice.hasMembershipConflictForTesting(t.groupId),
          isFalse,
        );
        // Merge, then the leave: two records on the two heads.
        expect(of(t.alice).membershipVersion, base + 3);
        // A second merge within the window waits; the first one did not.
        expect(t.alice.mergeDueForTesting('another-group'), isTrue);
        expect(t.alice.mergeDueForTesting('another-group'), isFalse);
      },
    );

    test(
      'a stolen admin phone admits a thief device and is revoked: the owner\'s '
      'record for the revocation takes the thief device out too',
      timeout: const Timeout(Duration(minutes: 4)),
      () async {
        final t = await joinedPhone();
        final all = [t.alice, t.bob, t.carol, t.phone];
        final phoneId = t.phone.identity!.deviceId;
        final bobId = t.bob.identity!.deviceId;
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        final dave = await _createController(
          relayClient: t.relay,
          displayName: 'Thief device',
          transportRegistryFactory: t.network.registry,
        );
        addTearDown(dave.dispose);
        final daveId = dave.identity!.deviceId;
        // Bob's account is an admin account: his phone can add members.
        await t.alice.setGroupMemberRole(
          groupId: t.groupId,
          memberDeviceId: bobId,
          role: GroupMemberRole.admin,
        );
        await settle(
          all,
          until: () => of(t.phone).roleFor(phoneId) == GroupMemberRole.admin,
          rounds: 200,
        );
        expect(of(t.phone).roleFor(phoneId), GroupMemberRole.admin);
        await _pairControllers(t.phone, dave);
        // The thief adds a device. The laptop does not hear of it.
        await t.phone.addGroupMembers(
          groupId: t.groupId,
          members: [t.phone.contacts.firstWhere((c) => c.deviceId == daveId)],
        );
        await settle(
          [t.alice, t.carol, t.phone, dave],
          until: () => of(t.alice).hasActiveMember(daveId),
          rounds: 200,
        );
        expect(of(t.alice).hasActiveMember(daveId), isTrue);
        // The laptop revokes the phone; the owner pins it.
        await t.bob.revokeAccountDevice(phoneId);
        await settle(
          all,
          until: () =>
              !of(t.alice).memberDeviceIds.contains(phoneId) &&
              !of(t.alice).hasActiveMember(daveId),
          rounds: 250,
        );
        expect(of(t.alice).memberDeviceIds, isNot(contains(phoneId)));
        expect(of(t.alice).hasActiveMember(daveId), isFalse);
        expect(of(t.carol).hasActiveMember(daveId), isFalse);
        expect(of(t.alice).hasActiveMember(bobId), isTrue);
      },
    );

    test(
      'a candidate at the head\'s version that is not the head is refused, '
      'the head itself is accepted',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(ownerWrites: false);
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        final head = of(t.alice);
        // The same members and entries: nothing to sign, nothing changes.
        await t.alice.commitGroupChangeForTesting(head.signedView);
        expect(of(t.alice).membershipVersion, head.membershipVersion);
        // Another record at that version is not the head, and is not stored.
        await expectLater(
          t.alice.commitGroupChangeForTesting(
            head.signedView.copyWith(title: 'Not what was signed'),
          ),
          throwsA(isA<StateError>()),
        );
        expect(of(t.alice).title, head.title);
      },
    );

    test(
      'a device-only member\'s leave in a group with accounts is signed by the '
      'owner at the next version, whatever number the leaver claims',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(ownerWrites: false);
        final all = [t.alice, t.bob, t.carol, t.phone];
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        final carolId = t.carol.identity!.deviceId;
        final base = of(t.alice).membershipVersion;
        // Carol leaves, claiming a version far ahead of the signed head.
        await t.carol.sendGroupLeaveForTesting(
          of(t.carol).copyWith(
            removedDeviceIds: [...of(t.carol).removedDeviceIds, carolId],
            membershipVersion: base + 90,
          ),
        );
        await settle(
          all,
          until: () =>
              !of(t.alice).hasActiveMember(carolId) &&
              !of(t.bob).hasActiveMember(carolId),
          rounds: 100,
        );
        expect(of(t.alice).hasActiveMember(carolId), isFalse);
        // One record, one version up: the number the leaver gave is not used.
        expect(of(t.alice).membershipVersion, base + 1);
        // The group still moves: the owner's next record is accepted.
        await t.alice.setGroupMemberRole(
          groupId: t.groupId,
          memberDeviceId: t.bob.identity!.deviceId,
          role: GroupMemberRole.moderator,
        );
        expect(of(t.alice).membershipVersion, base + 2);
        await settle(
          all,
          until: () => of(t.bob).membershipVersion == base + 2,
          rounds: 100,
        );
        expect(of(t.bob).membershipVersion, base + 2);
        expect(of(t.bob).hasActiveMember(carolId), isFalse);
      },
    );

    test(
      'two leaves in a row are both signed, the second from the new head',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(ownerWrites: false);
        final all = [t.alice, t.bob, t.carol, t.phone];
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        final carolId = t.carol.identity!.deviceId;
        final bobId = t.bob.identity!.deviceId;
        final base = of(t.alice).membershipVersion;
        await Future.wait([
          t.carol.leaveGroup(t.groupId),
          t.phone.leaveGroup(t.groupId),
        ]);
        await settle(
          all,
          until: () =>
              !of(t.alice).hasActiveMember(carolId) &&
              !of(t.alice).hasActiveMember(bobId),
          rounds: 150,
        );
        expect(of(t.alice).hasActiveMember(carolId), isFalse);
        expect(of(t.alice).hasActiveMember(bobId), isFalse);
        expect(of(t.alice).memberAccounts, isEmpty);
        expect(of(t.alice).membershipVersion, base + 2);
      },
    );

    /// A device certificate naming [deviceId] with keys that are not its own
    /// (an impostor's), issued by [keys].
    Future<DeviceCert> impostorCert(
      AccountKeys keys,
      String accountId,
      String deviceId,
    ) async {
      final impostor = await TestDevice.create(deviceId, accountId);
      return DeviceCert.issue(
        account: keys,
        accountId: accountId,
        deviceId: deviceId,
        encryptionKeyBase64: impostor.encryptionPublicKey,
        signingKeyBase64: impostor.signingPublicKey,
        irohEndpointId: impostor.iroh,
        name: 'impostor',
        linkedAt: fixtureEpoch,
        proofSignatureBase64: await signEd25519(
          DeviceCert.proofBytes(
            accountId: accountId,
            accountKeyBase64: keys.publicKeyBase64,
            deviceId: deviceId,
            encryptionKeyBase64: impostor.encryptionPublicKey,
            signingKeyBase64: impostor.signingPublicKey,
            irohEndpointId: impostor.iroh,
          ),
          publicKeyBase64: impostor.signingPublicKey,
          privateKeyBase64: impostor.signingPrivateKey,
        ),
      );
    }

    test(
      'a hostile account listing another member\'s device id does not block '
      'that member\'s record',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        final all = [t.alice, t.bob, t.carol, t.phone];
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        final phoneId = t.phone.identity!.deviceId;
        // Carol becomes an account too (a second account in the group).
        await t.carol.createAccount(deviceName: 'Carol phone');
        await settle(
          all,
          until: () => of(t.alice).memberAccounts.length == 2,
          rounds: 150,
        );
        expect(of(t.alice).memberAccounts, hasLength(2));
        // Carol's account (its key) lists Bob's laptop under keys that are
        // not the laptop's, in a list newer than any pinned one.
        final carol = t.carol.identity!;
        final keys = AccountKeys(
          publicKeyBase64: carol.accountKeyPublicBase64!,
          privateKeyBase64: carol.accountKeyPrivateBase64!,
        );
        final ownCert = t.carol.accountDevices!.devices.first;
        final hostile = await AccountDeviceList.issue(
          account: keys,
          accountId: carol.accountId,
          version: 50,
          devices: [
            ownCert,
            await impostorCert(keys, carol.accountId, t.bob.identity!.deviceId),
          ],
          issuedAt: DateTime.now().toUtc(),
        );
        await t.alice.handleGroupDevicesForTesting(t.groupId, carol.deviceId, {
          'version': 1,
          'groupId': t.groupId,
          'type': 'devices',
          'lists': [hostile.toJson()],
        });
        // Bob revokes his phone: the owner's record for Bob's account must
        // still be written, whatever Carol's account claims.
        await t.bob.revokeAccountDevice(phoneId);
        await settle(
          all,
          until: () => !of(t.alice).memberDeviceIds.contains(phoneId),
          rounds: 150,
        );
        expect(of(t.alice).memberDeviceIds, isNot(contains(phoneId)));
        expect(of(t.alice).hasActiveMember(t.bob.identity!.deviceId), isTrue);
      },
    );

    test(
      'a pending upgrade the owner will not fold is dropped without stopping '
      'the writer',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(ownerWrites: false);
        final carol = t.carol.identity!;
        final keys = await AccountKeys.generate();
        final upgrade = await AccountUpgrade.create(
          accountId: carol.accountId,
          deviceId: carol.deviceId,
          deviceSigningPublicKeyBase64: carol.signingPublicKeyBase64!,
          deviceSigningPrivateKeyBase64: carol.signingPrivateKeyBase64!,
          account: keys,
          issuedAt: fixtureEpoch,
        );
        final own = await DeviceCert.issue(
          account: keys,
          accountId: carol.accountId,
          deviceId: carol.deviceId,
          encryptionKeyBase64: carol.publicKeyBase64,
          signingKeyBase64: carol.signingPublicKeyBase64!,
          irohEndpointId: carol.irohEndpointId,
          name: 'carol',
          linkedAt: fixtureEpoch,
          proofSignatureBase64: await signEd25519(
            DeviceCert.proofBytes(
              accountId: carol.accountId,
              accountKeyBase64: keys.publicKeyBase64,
              deviceId: carol.deviceId,
              encryptionKeyBase64: carol.publicKeyBase64,
              signingKeyBase64: carol.signingPublicKeyBase64!,
              irohEndpointId: carol.irohEndpointId,
            ),
            publicKeyBase64: carol.signingPublicKeyBase64!,
            privateKeyBase64: carol.signingPrivateKeyBase64!,
          ),
        );
        // The list also names the owner's device id with someone else's keys.
        final list = await AccountDeviceList.issue(
          account: keys,
          accountId: carol.accountId,
          version: 1,
          devices: [
            own,
            await impostorCert(
              keys,
              carol.accountId,
              t.alice.identity!.deviceId,
            ),
          ],
          issuedAt: fixtureEpoch,
        );
        t.alice.notePendingUpgradeForTesting(
          t.groupId,
          upgrade,
          list,
          DateTime.now().toUtc(),
        );
        expect(t.alice.pendingUpgradeCountForTesting(t.groupId), 1);
        await t.alice.runOwnerWriterForTesting(t.groupId);
        expect(t.alice.pendingUpgradeCountForTesting(t.groupId), 0);
      },
    );

    test(
      'on slow routes one device of an account gets a message and passes it '
      'on to the other',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone();
        final all = [t.alice, t.bob, t.carol, t.phone];
        t.carol.setGatewayGraceForTesting(
          const Duration(days: 1),
          allSlow: true,
        );
        for (final c in all) {
          c.setPassOnStepForTesting(Duration.zero);
        }
        await t.carol.sendGroupMessage(groupId: t.groupId, body: 'via gateway');
        bool got(MessengerController c) =>
            c.messagesForGroup(t.groupId).any((m) => m.body == 'via gateway');
        await settle(all, until: () => got(t.bob) && got(t.phone), rounds: 300);
        expect(got(t.bob), isTrue);
        expect(got(t.phone), isTrue);
      },
    );

    test(
      'in a group that confirms new devices a new device waits, and an admin '
      'decides',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(confirmFirst: true);
        final all = [t.alice, t.bob, t.carol, t.phone];
        final phoneId = t.phone.identity!.deviceId;
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        expect(of(t.alice).hasActiveMember(phoneId), isFalse);
        expect(of(t.carol).hasActiveMember(phoneId), isFalse);
        expect(
          t.alice.groupAccountStatus(t.groupId)!.pendingDeviceIds,
          contains(phoneId),
        );
        await t.alice.decideAccountDevice(
          groupId: t.groupId,
          deviceId: phoneId,
          approve: true,
        );
        await settle(
          all,
          until: () =>
              of(t.carol).hasActiveMember(phoneId) &&
              of(t.phone).memberDeviceIds.contains(phoneId),
          rounds: 200,
        );
        expect(of(t.carol).hasActiveMember(phoneId), isTrue);
        expect(of(t.alice).memberDeviceIds, contains(phoneId));
        expect(
          of(t.alice).memberAccounts.single.approvedDeviceIds,
          contains(phoneId),
        );
      },
    );

    test(
      'a refused new device stays out',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(confirmFirst: true);
        final phoneId = t.phone.identity!.deviceId;
        await t.alice.decideAccountDevice(
          groupId: t.groupId,
          deviceId: phoneId,
          approve: false,
        );
        final group = t.alice.groups.firstWhere((g) => g.groupId == t.groupId);
        expect(
          group.memberAccounts.single.excludedDeviceIds,
          contains(phoneId),
        );
        expect(group.hasActiveMember(phoneId), isFalse);
        expect(
          t.alice.groupAccountStatus(t.groupId)!.pendingDeviceIds,
          isNot(contains(phoneId)),
        );
      },
    );

    test(
      'a list that names another member\'s device id is never pinned, and the '
      'owner can still sign the next record',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final t = await joinedPhone(ownerWrites: false);
        GroupRecord of(MessengerController c) =>
            c.groups.firstWhere((g) => g.groupId == t.groupId);
        final bob = t.bob.identity!;
        final accountKeys = AccountKeys(
          publicKeyBase64: bob.accountKeyPublicBase64!,
          privateKeyBase64: bob.accountKeyPrivateBase64!,
        );
        final carolId = t.carol.identity!.deviceId;
        final impostor = await TestDevice.create(carolId, bob.accountId);
        final laptop = t.bob.accountDevices!.devices.first;
        final cert = await DeviceCert.issue(
          account: accountKeys,
          accountId: bob.accountId,
          deviceId: carolId,
          encryptionKeyBase64: impostor.encryptionPublicKey,
          signingKeyBase64: impostor.signingPublicKey,
          irohEndpointId: impostor.iroh,
          name: 'impostor',
          linkedAt: fixtureEpoch,
          proofSignatureBase64: await signEd25519(
            DeviceCert.proofBytes(
              accountId: bob.accountId,
              accountKeyBase64: accountKeys.publicKeyBase64,
              deviceId: carolId,
              encryptionKeyBase64: impostor.encryptionPublicKey,
              signingKeyBase64: impostor.signingPublicKey,
              irohEndpointId: impostor.iroh,
            ),
            publicKeyBase64: impostor.signingPublicKey,
            privateKeyBase64: impostor.signingPrivateKey,
          ),
        );
        final hostile = await AccountDeviceList.issue(
          account: accountKeys,
          accountId: bob.accountId,
          version: 9,
          devices: [laptop, cert],
          issuedAt: DateTime.now().toUtc(),
        );
        final before = of(t.alice).membershipVersion;
        await t.alice.handleGroupDevicesForTesting(t.groupId, bob.deviceId, {
          'version': 1,
          'groupId': t.groupId,
          'type': 'devices',
          'lists': [hostile.toJson()],
        });
        await t.alice.runOwnerWriterForTesting(t.groupId);
        // Nothing was signed with the colliding list, and carol is still
        // carol.
        expect(of(t.alice).membershipVersion, before);
        expect(
          of(t.alice).memberProfileFor(carolId)!.accountId,
          t.carol.identity!.accountId,
        );
        expect(of(t.alice).hasActiveMember(carolId), isTrue);
        // The owner can still sign: the next record goes through.
        await t.alice.setGroupMemberRole(
          groupId: t.groupId,
          memberDeviceId: bob.deviceId,
          role: GroupMemberRole.moderator,
        );
        expect(of(t.alice).membershipVersion, before + 1);
      },
    );
  });
}
