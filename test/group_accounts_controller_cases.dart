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
      })
    >
    joinedPhone() async {
      final network = _InProcessIrohNetwork();
      final relay = _FakeRelayClient();
      Future<MessengerController> make(String name) => _createController(
        relayClient: relay,
        displayName: name,
        transportRegistryFactory: network.registry,
      );
      final alice = await make('Alice');
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
      await settle(
        [alice, bob, carol, phone],
        until: () =>
            of(alice).memberDeviceIds.contains(phoneId) &&
            of(carol).hasActiveMember(phoneId) &&
            of(phone).memberDeviceIds.contains(phoneId),
      );
      // ignore: avoid_print
      print('TIMING joined alice=${of(alice).memberDeviceIds.contains(phoneId)} carol=${of(carol).hasActiveMember(phoneId)} phone=${of(phone).memberDeviceIds.contains(phoneId)} phoneActive=${of(phone).hasActiveMember(phoneId)} phoneV=${of(phone).membershipVersion} aliceV=${of(alice).membershipVersion}');
      for (final c in [phone, alice]) {
        // ignore: avoid_print
        print('LOG ${c.identity!.displayName} ${c.identity!.deviceId} laptop=${bob.identity!.deviceId} phone=${phone.identity!.deviceId}: ${c.recentDebugLog.where((l) => !l.contains('nnounce')).toList()}');
      }
      return (
        alice: alice,
        bob: bob,
        carol: carol,
        phone: phone,
        groupId: group.groupId,
      );
    }

    test('a second device of an account member joins by itself and posts '
        'in the group', timeout: const Timeout(Duration(minutes: 3)), () async {
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
      bool got(MessengerController c) => c
          .messagesForGroup(t.groupId)
          .any((m) => m.body == 'from phone');
      await settle(all, until: () => got(t.carol) && got(t.alice));
      expect(got(t.carol), isTrue);
      expect(got(t.alice), isTrue);
    });

    test('a revoked device leaves the group at once and its later messages '
        'are refused', timeout: const Timeout(Duration(minutes: 3)), () async {
      final t = await joinedPhone();
      final all = [t.alice, t.bob, t.carol, t.phone];
      final phoneId = t.phone.identity!.deviceId;
      GroupRecord of(MessengerController c) =>
          c.groups.firstWhere((g) => g.groupId == t.groupId);
      final watch = Stopwatch()..start();
      await t.bob.revokeAccountDevice(phoneId);
      // ignore: avoid_print
      print('TIMING revoke call ${watch.elapsedMilliseconds}');
      await settle(
        all,
        until: () =>
            !of(t.alice).hasActiveMember(phoneId) &&
            !of(t.carol).hasActiveMember(phoneId) &&
            !of(t.alice).memberDeviceIds.contains(phoneId),
      );
      // ignore: avoid_print
      print('TIMING settled ${watch.elapsedMilliseconds} aliceActive=${of(t.alice).hasActiveMember(phoneId)} proj=${of(t.alice).memberDeviceIds.contains(phoneId)}');
      expect(of(t.alice).hasActiveMember(phoneId), isFalse);
      expect(of(t.carol).hasActiveMember(phoneId), isFalse);
      // The owner's app pinned the revocation and dropped the device.
      expect(of(t.alice).memberDeviceIds, isNot(contains(phoneId)));
      try {
        await t.phone.sendGroupMessage(groupId: t.groupId, body: 'after');
      } catch (_) {}
      await settle(all, rounds: 15);
      for (final c in [t.alice, t.carol]) {
        expect(
          c.messagesForGroup(t.groupId).any((m) => m.body == 'after'),
          isFalse,
        );
      }
    });
  });
}
