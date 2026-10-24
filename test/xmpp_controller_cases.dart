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
  });
}
