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
}
