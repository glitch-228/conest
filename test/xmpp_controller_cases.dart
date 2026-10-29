part of 'messenger_controller_test.dart';

/// The XMPP carrier (M51) inside the controller.
void _xmppControllerTests() {
  group('XMPP carrier', () {
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
      FakeXmppServer server,
      _FakeRelayClient relay,
      String name,
    ) async {
      final controller = await _createController(
        relayClient: relay,
        displayName: name,
        xmppNetwork: XmppNetwork(
          connector: server.connect,
          webSocketConnector: server.connectWebSocket,
          webSocketLookup: null,
        ),
      );
      addTearDown(controller.dispose);
      return controller;
    }

    Future<void> connected(MessengerController controller) async {
      for (
        var i = 0;
        i < 200 && controller.xmppChannel?.state != XmppCarrierState.connected;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(controller.xmppChannel?.state, XmppCarrierState.connected);
    }

    test('two contacts talk through their XMPP accounts', () async {
      final server = FakeXmppServer();
      server
        ..addAccount('alice', 'pa')
        ..addAccount('bob', 'pb');
      final relay = _FakeRelayClient();
      final alice = await person(server, relay, 'Alice');
      final bob = await person(server, relay, 'Bob');
      await _pairControllers(alice, bob);
      expect(
        await alice.enableXmppCarrier(jid: 'Alice@xmpp.test', password: 'pa'),
        'alice@xmpp.test',
      );
      await bob.enableXmppCarrier(jid: 'bob@xmpp.test', password: 'pb');
      await connected(alice);
      await connected(bob);
      for (
        var round = 0;
        round < 20 &&
            bob.contacts.single.carrierAddress(TransportKind.xmpp) == null;
        round++
      ) {
        await settle([alice, bob]);
      }
      final aliceAddress = alice.xmppChannel!.localAddress!;
      expect(aliceAddress, startsWith('alice@xmpp.test|conest-'));
      expect(
        bob.contacts.single.carrierAddress(TransportKind.xmpp),
        aliceAddress,
      );
      // The resource is the one saved with the account.
      expect(
        server.boundResources,
        contains('alice@xmpp.test/${alice.xmppCarrierConfig!.resource}'),
      );

      relay.shouldFailStore = (_, _, _, _, _) => true;
      await bob.sendMessage(contact: bob.contacts.single, body: 'by xmpp');
      final bobId = bob.identity!.deviceId;
      for (
        var round = 0;
        round < 50 && !alice.messagesFor(bobId).any((m) => m.body == 'by xmpp');
        round++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final received = alice
          .messagesFor(bobId)
          .singleWhere((m) => m.body == 'by xmpp');
      expect(received.route, MessageRoute.xmppCarrier);

      relay.shouldFailStore = null;
      await alice.disableXmppCarrier();
      expect(alice.xmppCarrierConfig, isNull);
      for (
        var round = 0;
        round < 10 &&
            bob.contacts.single.carrierAddress(TransportKind.xmpp) != null;
        round++
      ) {
        await settle([alice, bob]);
      }
      expect(bob.contacts.single.carrierAddress(TransportKind.xmpp), isNull);
    });

    test('only one XMPP set-up runs at a time', () async {
      final server = FakeXmppServer()..captchaAnswer = 'abc';
      final relay = _FakeRelayClient();
      final alice = await person(server, relay, 'Alice');
      final asked = Completer<void>();
      final answer = Completer<String?>();
      final first = alice.enableXmppCarrier(
        servers: ['xmpp.test'],
        captchaSolver: (_) {
          asked.complete();
          return answer.future;
        },
      );
      await asked.future;
      await expectLater(
        alice.enableXmppCarrier(servers: ['xmpp.test']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('already being set up'),
          ),
        ),
      );
      answer.complete('abc');
      await first;
      expect(alice.xmppCarrierConfig, isNotNull);
      await alice.disableXmppCarrier();
    });

    test('a mutual add works over XMPP alone', () async {
      final server = FakeXmppServer();
      final relay = _FakeRelayClient();
      final alice = await person(server, relay, 'Alice');
      final bob = await person(server, relay, 'Bob');
      // Accounts Conest creates itself.
      await alice.enableXmppCarrier(servers: ['xmpp.test']);
      await bob.enableXmppCarrier(servers: ['xmpp.test']);
      expect(alice.xmppCarrierConfig!.created, isTrue);
      await connected(alice);
      await connected(bob);
      relay.shouldFailStore = (_, _, _, _, _) => true;
      final aliceInvite = await alice.buildInvite();
      final bobInvite = await bob.buildInvite();
      // The invite carries the XMPP address as a signed hint.
      expect(
        aliceInvite.carrierHints[TransportKind.xmpp],
        alice.xmppChannel!.localAddress,
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
      // Only XMPP carried it.
      expect(
        server.received.where(
          (stanza) => stanza.child('conest', XmppNs.conestCarrier) != null,
        ),
        isNotEmpty,
      );
    });

    test('with Online off no XMPP server is contacted', () async {
      final server = FakeXmppServer()..addAccount('alice', 'pa');
      final relay = _FakeRelayClient();
      final alice = await person(server, relay, 'Alice');
      await alice.enableXmppCarrier(jid: 'alice@xmpp.test', password: 'pa');
      await connected(alice);
      await alice.updateGlobalConnectivity(
        alice.identity!.connectivity.copyWith(onlineEnabled: false),
      );
      for (var i = 0; i < 50 && server.online.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(server.online, isEmpty);
      final before = server.connections.length;
      await expectLater(
        alice.enableXmppCarrier(servers: ['xmpp.test']),
        throwsStateError,
      );
      final checks = await alice.checkInternetTransports(
        xmppCandidates: ['xmpp.test'],
        nostrCandidates: const [],
        chatmailCandidates: const [],
        timeout: const Duration(milliseconds: 200),
      );
      expect(
        checks.singleWhere((check) => check.kind == TransportKind.xmpp).state,
        InternetTransportState.needsSetup,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.connections.length, before);
    });

    test('a wrong password is refused at setup', () async {
      final server = FakeXmppServer()..addAccount('alice', 'pa');
      final alice = await person(server, _FakeRelayClient(), 'Alice');
      await expectLater(
        alice.enableXmppCarrier(jid: 'alice@xmpp.test', password: 'nope'),
        throwsStateError,
      );
      expect(alice.xmppCarrierConfig, isNull);
    });
    testWidgets('Settings shows the XMPP account and its state', (
      tester,
    ) async {
      final server = FakeXmppServer()..addAccount('alice', 'pa');
      late MessengerController alice;
      await tester.runAsync(() async {
        alice = await person(server, _FakeRelayClient(), 'Alice');
        await alice.enableXmppCarrier(jid: 'alice@xmpp.test', password: 'pa');
        await connected(alice);
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: XmppCarrierPanel(controller: alice),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('alice@xmpp.test'), findsOneWidget);
      expect(find.textContaining('Your own account'), findsOneWidget);
      // Changing the account offers the user's own account, filled in.
      await tester.tap(find.byKey(const ValueKey('xmpp-change-account')));
      await tester.pump();
      expect(find.byKey(const ValueKey('xmpp-jid-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('xmpp-server-field')), findsNothing);
      await tester.runAsync(alice.disableXmppCarrier);
    });
    test('XMPP chats run beside Conest and alone in XMPP-only mode', () async {
      final server = FakeXmppServer()
        ..addAccount('alice', 'pa')
        ..addAccount('bob', 'pb');
      final alice = await person(server, _FakeRelayClient(), 'Alice');
      await alice.enableXmppChats(jid: 'alice@xmpp.test', password: 'pa');
      expect(alice.xmppClientConfig!.jid, 'alice@xmpp.test');
      for (
        var i = 0;
        i < 200 && !(alice.xmppChatClient?.connected ?? false);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(alice.xmppChatClient!.connected, isTrue);
      // Bob writes from another client.
      server.inject(
        XmppElement(
          'message',
          attributes: {
            'from': 'bob@xmpp.test/x',
            'to': 'alice@xmpp.test/${alice.xmppClientConfig!.resource}',
            'type': 'chat',
            'id': 'b1',
          },
          children: [XmppElement('body', text: 'hi Alice')],
        ),
      );
      for (
        var i = 0;
        i < 100 && alice.xmppChats.chats['bob@xmpp.test'] == null;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(alice.xmppChats.chats['bob@xmpp.test']!.request, isTrue);
      expect(
        networkChatSources(
          alice,
          ConestPalette(brightness: Brightness.dark),
        ).singleWhere((source) => source.id == 'xmpp').chats().single.title,
        'bob@xmpp.test',
      );

      // XMPP only: Conest sleeps, the chats go on.
      await alice.setAppMode(AppMode.xmppOnly);
      expect(alice.conestActive, isFalse);
      expect(alice.xmppChatClient, isNotNull);
      await alice.setAppMode(AppMode.conest);
      expect(alice.conestActive, isTrue);

      // Online off: the chats disconnect.
      await alice.updateGlobalConnectivity(
        alice.identity!.connectivity.copyWith(onlineEnabled: false),
      );
      expect(alice.xmppChatClient, isNull);
      for (var i = 0; i < 50 && server.online.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(server.online, isEmpty);
      // The chats are kept.
      expect(alice.xmppChats.chats, contains('bob@xmpp.test'));
    });

    testWidgets('an XMPP chat sends, and a request waits for accepting', (
      tester,
    ) async {
      final server = FakeXmppServer()
        ..addAccount('alice', 'pa')
        ..addAccount('bob', 'pb');
      late MessengerController alice;
      await tester.runAsync(() async {
        alice = await person(server, _FakeRelayClient(), 'Alice');
        await alice.enableXmppChats(jid: 'alice@xmpp.test', password: 'pa');
        for (
          var i = 0;
          i < 200 && !(alice.xmppChatClient?.connected ?? false);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        server.inject(
          XmppElement(
            'message',
            attributes: {
              'from': 'bob@xmpp.test/x',
              'to': 'alice@xmpp.test/${alice.xmppClientConfig!.resource}',
              'type': 'chat',
              'id': 'b1',
            },
            children: [XmppElement('body', text: 'hi Alice')],
          ),
        );
        for (
          var i = 0;
          i < 100 && alice.xmppChats.chats['bob@xmpp.test'] == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: XmppChatScreen(controller: alice, jid: 'bob@xmpp.test'),
        ),
      );
      await tester.pump();
      expect(find.text('hi Alice'), findsOneWidget);
      expect(find.byKey(const ValueKey('xmpp-request-banner')), findsOneWidget);
      // No composer before accepting.
      expect(find.byKey(const ValueKey('xmpp-composer')), findsNothing);
      expect(find.textContaining('encrypted if the contact'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('xmpp-request-accept')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('xmpp-composer')),
        'hey',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('xmpp-send')));
        for (
          var i = 0;
          i < 100 && !server.received.any((e) => e.childText('body') == 'hey');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      expect(server.received.any((e) => e.childText('body') == 'hey'), isTrue);
      expect(
        find.descendant(of: find.byType(ListView), matching: find.text('hey')),
        findsOneWidget,
      );
      await tester.runAsync(alice.disableXmppChats);
    });
  });
}
