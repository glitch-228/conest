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

  group('Telegram client', () {
    final keys = TelegramApiKeys.parse(
      '424242',
      'abcdef0123456789abcdef0123456789',
    );

    Future<Directory> tempDirectory() async {
      final dir = await Directory.systemTemp.createTemp('conest-tg-');
      addTearDown(() => dir.delete(recursive: true));
      return dir;
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue);
    }

    test('is hidden without keys or without TDLib', () async {
      final noKeys = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'A',
        tdEngineFactory: () => FakeTdEngine(),
      );
      addTearDown(noKeys.dispose);
      expect(noKeys.telegram.supported, isFalse);
      await expectLater(noKeys.telegram.enable(), throwsStateError);
      final noEngine = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'B',
        telegramApiKeys: keys,
      );
      addTearDown(noEngine.dispose);
      expect(noEngine.telegram.supported, isFalse);
      expect(noEngine.telegram.enabled, isFalse);
    });

    test('signs in, survives a restart, follows Online, logs out', () async {
      final dir = await tempDirectory();
      final vault = _MemoryVaultStore();
      final engines = <FakeTdEngine>[];
      Future<MessengerController> launch({bool loggedIn = false}) async {
        final controller = await _createController(
          relayClient: _FakeRelayClient(),
          vaultStore: vault,
          displayName: 'Alice',
          telegramApiKeys: keys,
          telegramDirectory: () async => dir,
          tdEngineFactory: () {
            final engine = FakeTdEngine(loggedIn: loggedIn)..addChat(10, 'Bob');
            engines.add(engine);
            return engine;
          },
        );
        return controller;
      }

      final alice = await launch();
      await alice.telegram.enable();
      final client = alice.telegram.client!;
      await until(() => client.auth == TgAuth.waitPhone);
      final key = engines.last.setParameters!['database_encryption_key'];
      expect((key as String).length, greaterThan(40));
      expect(
        engines.last.setParameters!['database_directory'],
        startsWith(dir.path),
      );
      await client.submitPhone('+15550001');
      await client.submitCode('12345');
      await until(() => client.auth == TgAuth.ready);
      await until(() => client.chats.containsKey(10));
      alice.dispose();

      // The next launch starts it again with the same database key.
      final again = await launch(loggedIn: true);
      addTearDown(again.dispose);
      expect(again.telegram.enabled, isTrue);
      await until(() => again.telegram.client?.auth == TgAuth.ready);
      expect(engines.last.setParameters!['database_encryption_key'], key);

      // Online off stops it; on starts it.
      await again.updateGlobalConnectivity(
        again.identity!.connectivity.copyWith(onlineEnabled: false),
      );
      await until(() => again.telegram.client == null);
      expect(again.telegram.enabled, isTrue);
      await again.updateGlobalConnectivity(
        again.identity!.connectivity.copyWith(onlineEnabled: true),
      );
      await until(() => again.telegram.client?.auth == TgAuth.ready);

      // Removing it logs out, deletes TDLib's files and forgets the key.
      final files = Directory('${dir.path}/telegram/db')
        ..createSync(recursive: true);
      File('${files.path}/td.binlog').writeAsStringSync('x');
      final engine = engines.last;
      await again.telegram.disable();
      expect(engine.requests.map((r) => r['@type']), contains('logOut'));
      expect(Directory('${dir.path}/telegram').existsSync(), isFalse);
      expect(again.telegram.enabled, isFalse);
      expect(again.telegram.client, isNull);
    });

    test('turning it on again keeps the database key', () async {
      final dir = await tempDirectory();
      final engines = <FakeTdEngine>[];
      final alice = await _createController(
        relayClient: _FakeRelayClient(),
        displayName: 'Alice',
        telegramApiKeys: keys,
        telegramDirectory: () async => dir,
        tdEngineFactory: () {
          final engine = FakeTdEngine();
          engines.add(engine);
          return engine;
        },
      );
      addTearDown(alice.dispose);
      await alice.telegram.enable();
      await until(
        () => engines.isNotEmpty && engines.last.setParameters != null,
      );
      final key = engines.last.setParameters!['database_encryption_key'];
      await alice.telegram.stop();
      await alice.telegram.enable();
      await until(() => engines.last.setParameters != null);
      expect(engines.last.setParameters!['database_encryption_key'], key);
    });

    test('mods are saved in the vault', () async {
      final vault = _MemoryVaultStore();
      Future<MessengerController> launch() => _createController(
        relayClient: _FakeRelayClient(),
        vaultStore: vault,
        displayName: 'Alice',
        telegramApiKeys: keys,
        tdEngineFactory: () => FakeTdEngine(),
      );
      final alice = await launch();
      alice.telegram.mods.hiddenWords = ['spam'];
      alice.telegram.mods.install('{"id":"p","name":"P"}');
      await alice.telegram.saveMods();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      alice.dispose();
      final again = await launch();
      addTearDown(again.dispose);
      expect(again.telegram.mods.hiddenWords, ['spam']);
      expect(again.telegram.mods.plugins.single.id, 'p');
    });
  });
}
