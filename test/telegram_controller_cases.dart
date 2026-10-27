part of 'messenger_controller_test.dart';

/// The Telegram bot carrier (M30) inside the controller.
void _telegramControllerTests() {
  group('Telegram bot carrier', () {
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
      FakeTelegramBots hub,
      _FakeRelayClient relay,
      String name,
    ) async {
      final controller = await _createController(
        relayClient: relay,
        displayName: name,
        telegramNetwork: hub.network,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    Future<void> connected(MessengerController controller) async {
      for (
        var i = 0;
        i < 200 &&
            controller.telegramChannel?.state != TelegramCarrierState.connected;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(controller.telegramChannel?.state, TelegramCarrierState.connected);
    }

    test('two contacts talk through their Telegram bots', () async {
      final hub = FakeTelegramBots();
      final aliceBot = hub.addBot('alice_conest_bot');
      final bobBot = hub.addBot('bob_conest_bot');
      final relay = _FakeRelayClient();
      final alice = await person(hub, relay, 'Alice');
      final bob = await person(hub, relay, 'Bob');
      await _pairControllers(alice, bob);
      expect(
        await alice.enableTelegramCarrier(aliceBot.token),
        'alice_conest_bot',
      );
      await bob.enableTelegramCarrier(bobBot.token);
      await connected(alice);
      await connected(bob);
      for (
        var round = 0;
        round < 20 &&
            bob.contacts.single.carrierAddress(TransportKind.telegram) == null;
        round++
      ) {
        await settle([alice, bob]);
      }
      expect(
        bob.contacts.single.carrierAddress(TransportKind.telegram),
        'alice_conest_bot',
      );

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by telegram');
      final bobId = bob.identity!.deviceId;
      for (
        var round = 0;
        round < 80 &&
            !alice.messagesFor(bobId).any((m) => m.body == 'by telegram');
        round++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by telegram');
      expect(received.route, MessageRoute.telegramCarrier);
      // What went over Telegram is sealed: the text is not in it.
      expect(bobBot.sent.map((e) => e.$2).join(), isNot(contains('telegram')));

      relay.shouldFailStore = null;
      await alice.disableTelegramCarrier();
      expect(alice.telegramBotConfig, isNull);
      for (
        var round = 0;
        round < 10 &&
            bob.contacts.single.carrierAddress(TransportKind.telegram) != null;
        round++
      ) {
        await settle([alice, bob]);
      }
      expect(
        bob.contacts.single.carrierAddress(TransportKind.telegram),
        isNull,
      );
    });

    test('a mutual add works over Telegram alone', () async {
      final hub = FakeTelegramBots();
      final aliceBot = hub.addBot('alice_conest_bot');
      final bobBot = hub.addBot('bob_conest_bot');
      final relay = _FakeRelayClient();
      final alice = await person(hub, relay, 'Alice');
      final bob = await person(hub, relay, 'Bob');
      await alice.enableTelegramCarrier(aliceBot.token);
      await bob.enableTelegramCarrier(bobBot.token);
      await connected(alice);
      await connected(bob);
      relay.shouldFailStore = (_, _, _, _, _) => true;
      final aliceInvite = await alice.buildInvite();
      final bobInvite = await bob.buildInvite();
      expect(
        aliceInvite.carrierHints[TransportKind.telegram],
        'alice_conest_bot',
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

    test('with Online off Telegram is not contacted', () async {
      final hub = FakeTelegramBots();
      final aliceBot = hub.addBot('alice_conest_bot');
      final alice = await person(hub, _FakeRelayClient(), 'Alice');
      await alice.enableTelegramCarrier(aliceBot.token);
      await connected(alice);
      await alice.updateGlobalConnectivity(
        alice.identity!.connectivity.copyWith(onlineEnabled: false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = hub.calls.length;
      await expectLater(
        alice.enableTelegramCarrier(aliceBot.token),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.calls.length, before);
    });

    test('a wrong or revoked bot token is refused at setup', () async {
      final hub = FakeTelegramBots();
      final aliceBot = hub.addBot('alice_conest_bot');
      final alice = await person(hub, _FakeRelayClient(), 'Alice');
      await expectLater(
        alice.enableTelegramCarrier('not a token'),
        throwsArgumentError,
      );
      aliceBot.revoked = true;
      await expectLater(
        alice.enableTelegramCarrier(aliceBot.token),
        throwsStateError,
      );
      expect(alice.telegramBotConfig, isNull);
    });
  });
}
