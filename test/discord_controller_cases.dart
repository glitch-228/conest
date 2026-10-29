part of 'messenger_controller_test.dart';

/// The Discord bot carrier (M31) inside the controller.
void _discordControllerTests() {
  group('Discord bot carrier', () {
    Future<void> settle(List<MessengerController> controllers) async {
      for (var round = 0; round < 6; round++) {
        for (final controller in controllers) {
          await controller.retryUnacknowledgedMessagesNow();
          await controller.pollNow();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<MessengerController> person(
      FakeDiscord hub,
      _FakeRelayClient relay,
      String name,
    ) async {
      final controller = await _createController(
        relayClient: relay,
        displayName: name,
        discordNetwork: hub.network,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    Future<void> connected(MessengerController controller) async {
      for (
        var i = 0;
        i < 200 &&
            controller.discordChannel?.state != DiscordCarrierState.connected;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(controller.discordChannel?.state, DiscordCarrierState.connected);
    }

    test('two contacts talk through their Discord bots', () async {
      final hub = FakeDiscord();
      final aliceBot = hub.addBot('alice-bot');
      final bobBot = hub.addBot('bob-bot');
      final room = hub.addChannel(members: [aliceBot, bobBot]);
      final relay = _FakeRelayClient();
      final alice = await person(hub, relay, 'Alice');
      final bob = await person(hub, relay, 'Bob');
      await _pairControllers(alice, bob);
      expect(
        await alice.enableDiscordCarrier(aliceBot.token, room),
        '${aliceBot.id}|$room',
      );
      await bob.enableDiscordCarrier(bobBot.token, room);
      await connected(alice);
      await connected(bob);
      for (
        var round = 0;
        round < 20 &&
            bob.contacts.single.carrierAddress(TransportKind.discord) == null;
        round++
      ) {
        await settle([alice, bob]);
      }
      expect(
        bob.contacts.single.carrierAddress(TransportKind.discord),
        '${aliceBot.id}|$room',
      );

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by discord');
      final bobId = bob.identity!.deviceId;
      for (
        var round = 0;
        round < 80 &&
            !alice.messagesFor(bobId).any((m) => m.body == 'by discord');
        round++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by discord');
      expect(received.route, MessageRoute.discordCarrier);
      // What went over Discord is sealed: the text is not in it.
      expect(
        bobBot.sent.map((e) => e.content).join(),
        isNot(contains('discord')),
      );

      relay.shouldFailStore = null;
      await alice.disableDiscordCarrier();
      expect(alice.discordBotConfig, isNull);
      for (
        var round = 0;
        round < 10 &&
            bob.contacts.single.carrierAddress(TransportKind.discord) != null;
        round++
      ) {
        await settle([alice, bob]);
      }
      expect(bob.contacts.single.carrierAddress(TransportKind.discord), isNull);
    });

    test('a mutual add works over Discord alone', () async {
      final hub = FakeDiscord();
      final aliceBot = hub.addBot('alice-bot');
      final bobBot = hub.addBot('bob-bot');
      final room = hub.addChannel(members: [aliceBot, bobBot]);
      final relay = _FakeRelayClient();
      final alice = await person(hub, relay, 'Alice');
      final bob = await person(hub, relay, 'Bob');
      await alice.enableDiscordCarrier(aliceBot.token, room);
      await bob.enableDiscordCarrier(bobBot.token, room);
      await connected(alice);
      await connected(bob);
      relay.shouldFailStore = (_, _, _, _, _) => true;
      final aliceInvite = await alice.buildInvite();
      final bobInvite = await bob.buildInvite();
      expect(
        aliceInvite.carrierHints[TransportKind.discord],
        '${aliceBot.id}|$room',
      );
      await alice.addContactFromInvite(
        alias: 'Bob',
        payload: bobInvite.encodePayload(),
        codephrase: '',
      );
      await bob.addContactFromInvite(
        alias: 'Alice',
        payload: aliceInvite.encodePayload(),
        codephrase: '',
      );
      for (
        var round = 0;
        round < 15 &&
            (alice.contacts.single.pairingState !=
                    ContactPairingState.accepted ||
                bob.contacts.single.pairingState !=
                    ContactPairingState.accepted);
        round++
      ) {
        await settle([alice, bob]);
        await alice.retryContactPairingNow(bob.identity!.deviceId);
        await bob.retryContactPairingNow(alice.identity!.deviceId);
      }
      expect(alice.contacts.single.pairingState, ContactPairingState.accepted);
      expect(bob.contacts.single.pairingState, ContactPairingState.accepted);
      expect(aliceBot.sent, isNotEmpty);
    });

    test('with Online off Discord is not contacted', () async {
      final hub = FakeDiscord();
      final aliceBot = hub.addBot('alice-bot');
      final room = hub.addChannel(members: [aliceBot]);
      final alice = await person(hub, _FakeRelayClient(), 'Alice');
      await alice.enableDiscordCarrier(aliceBot.token, room);
      await connected(alice);
      await alice.updateGlobalConnectivity(
        alice.identity!.connectivity.copyWith(onlineEnabled: false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = hub.calls.length;
      await expectLater(
        alice.enableDiscordCarrier(aliceBot.token, room),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.calls.length, before);
    });

    test('a wrong or revoked bot token is refused at setup', () async {
      final hub = FakeDiscord();
      final aliceBot = hub.addBot('alice-bot');
      final room = hub.addChannel(members: [aliceBot]);
      final alice = await person(hub, _FakeRelayClient(), 'Alice');
      await expectLater(
        alice.enableDiscordCarrier('not a token', room),
        throwsArgumentError,
      );
      aliceBot.revoked = true;
      await expectLater(
        alice.enableDiscordCarrier(aliceBot.token, room),
        throwsStateError,
      );
      expect(alice.discordBotConfig, isNull);
    });
  });

  group('Discord client', () {
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue);
    }

    (FakeDiscord, FakeDiscordAccount) seeded() {
      final hub = FakeDiscord();
      final me = hub.addUser('me');
      final friend = hub.addUser('friend');
      final dm = hub.addChannel(members: [me, friend]);
      me.dms.add({
        'id': dm,
        'type': 1,
        'recipients': [
          {'id': friend.id, 'username': 'friend'},
        ],
      });
      hub.post(dm, friend, 'hi from friend');
      return (hub, me);
    }

    Future<MessengerController> launch(
      FakeDiscord hub, {
      _MemoryVaultStore? vault,
    }) async {
      final controller = await _createController(
        relayClient: _FakeRelayClient(),
        vaultStore: vault,
        displayName: 'Alice',
        discordNetwork: hub.network,
      );
      return controller;
    }

    test(
      'stays off until accepted, then follows the mode and Online',
      () async {
        final (hub, me) = seeded();
        final user = hub.addUser('x');
        final vault = _MemoryVaultStore();
        final alice = await launch(hub, vault: vault);
        await expectLater(
          alice.discord.enable(user.token, acceptedRisk: false),
          throwsStateError,
        );
        expect(hub.calls, isEmpty);
        await alice.discord.enable(me.token, acceptedRisk: true);
        expect(alice.discord.client!.signedIn, isTrue);
        // The carrier did not start and nothing was posted by the client.
        expect(alice.discordChannel, isNull);
        alice.dispose();

        final again = await launch(hub, vault: vault);
        addTearDown(again.dispose);
        await until(() => again.discord.client?.signedIn ?? false);
        await again.updateGlobalConnectivity(
          again.identity!.connectivity.copyWith(onlineEnabled: false),
        );
        await until(() => again.discord.client == null);
        await again.updateGlobalConnectivity(
          again.identity!.connectivity.copyWith(onlineEnabled: true),
        );
        await until(() => again.discord.client?.signedIn ?? false);
        // Discord-only mode keeps it running with Conest dormant.
        await again.setAppMode(AppMode.discordOnly);
        expect(again.conestActive, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(again.discord.client?.signedIn, isTrue);
        await again.setAppMode(AppMode.xmppOnly);
        await until(() => again.discord.client == null);
        await again.setAppMode(AppMode.conest);
        await until(() => again.discord.client?.signedIn ?? false);
      },
    );

    testWidgets('the panel warns first and the chat list opens a DM', (
      tester,
    ) async {
      final (hub, me) = seeded();
      late MessengerController alice;
      await tester.runAsync(() async => alice = await launch(hub));
      addTearDown(alice.dispose);
      Widget host(Widget child) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );
      await tester.pumpWidget(host(DiscordClientPanel(controller: alice)));
      await tester.enterText(
        find.byKey(const ValueKey('discord-token-field')),
        me.token,
      );
      await tester.tap(find.byKey(const ValueKey('discord-enable')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('against Discord'), findsWidgets);
      expect(hub.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('discord-accept-risk')));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('discord-signed-in')), findsOneWidget);

      final client = alice.discord.client!;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DiscordChatList(controller: alice, client: client),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('friend'));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('hi from friend'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('discord-composer')),
        'hello back',
      );
      await tester.tap(find.byKey(const ValueKey('discord-send')));
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('hello back'), findsOneWidget);
      expect(me.sent.single.content, 'hello back');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
