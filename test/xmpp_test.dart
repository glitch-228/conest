import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/carrier.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/transport_models.dart';
import 'package:conest/src/xmpp/xmpp_carrier.dart';
import 'package:conest/src/xmpp/xmpp_sasl.dart';
import 'package:conest/src/xmpp/xmpp_session.dart';
import 'package:conest/src/xmpp/xmpp_socket.dart';
import 'package:conest/src/xmpp/xmpp_xml.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_xmpp_server.dart';

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

XmppCarrierChannel _channel(
  FakeXmppServer server,
  String local, {
  required void Function(String, Uint8List) onFrame,
  bool created = true,
  String resource = 'conest-abc',
}) {
  server.addAccount(local, 'pw-$local');
  return XmppCarrierChannel(
    config: XmppCarrierConfig(
      jid: '$local@${server.domain}',
      password: 'pw-$local',
      resource: resource,
      created: created,
    ),
    onFrame: onFrame,
    connector: server.connect,
    webSocketConnector: server.connectWebSocket,
  );
}

void main() {
  group('XML stream', () {
    test('elements split anywhere arrive whole, with namespaces', () {
      final parser = XmppStreamParser();
      const text =
          "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
          "xmlns:stream='http://etherx.jabber.org/streams' id='x'>"
          '<stream:features><starttls xmlns="urn:ietf:params:xml:ns:xmpp-tls">'
          '<required/></starttls></stream:features>'
          '<message from="a@b/c" type="chat"><body>café &amp; &lt;tea&gt;'
          '</body><x:conest xmlns:x="urn:conest:carrier:1">QUJD</x:conest>'
          '</message>';
      final bytes = utf8.encode(text);
      final events = <XmppStreamEvent>[];
      // One byte at a time, splitting the UTF-8 sequence too.
      for (final byte in bytes) {
        events.addAll(parser.addBytes([byte]));
      }
      expect(events.first, isA<XmppStreamOpened>());
      final features = (events[1] as XmppStreamElement).element;
      expect(features.name, 'features');
      expect(features.xmlns, XmppNs.stream);
      expect(
        features.child('starttls', XmppNs.tls)?.child('required'),
        isNotNull,
      );
      final message = (events[2] as XmppStreamElement).element;
      expect(message.xmlns, XmppNs.client);
      expect(message.childText('body'), 'café & <tea>');
      expect(message.child('conest', XmppNs.conestCarrier)?.text, 'QUJD');
    });

    test('oversized stanzas, deep nesting and DOCTYPEs end the stream', () {
      final header = utf8.encode(
        "<stream:stream xmlns='jabber:client' "
        "xmlns:stream='http://etherx.jabber.org/streams'>",
      );
      final small = XmppStreamParser(maxElementChars: 1000)..addBytes(header);
      expect(
        () => small.addBytes(utf8.encode('<message>${'a' * 2000}</message>')),
        throwsA(isA<XmppProtocolException>()),
      );
      final shallow = XmppStreamParser(maxDepth: 4)..addBytes(header);
      expect(
        () => shallow.addBytes(utf8.encode('<a><b><c><d><e/></d></c></b></a>')),
        throwsA(isA<XmppProtocolException>()),
      );
      expect(
        () => XmppStreamParser().addBytes(
          utf8.encode('<!DOCTYPE x [<!ENTITY a "aaaa">]><x/>'),
        ),
        throwsA(isA<XmppProtocolException>()),
      );
      // Whitespace keepalives between stanzas do not count towards a limit.
      final keepalive = XmppStreamParser(maxElementChars: 100)
        ..addBytes(header);
      for (var i = 0; i < 50; i++) {
        keepalive.addBytes(utf8.encode('   '));
      }
      expect(keepalive.addBytes(utf8.encode('<r/>')), hasLength(1));
    });

    test('text and attributes are escaped', () {
      final element = XmppElement(
        'message',
        attributes: {'to': 'a"b@c'},
        text: '<&>\u0001',
      );
      expect(
        element.toXml(parentNamespace: XmppNs.client),
        '<message to="a&quot;b@c">&lt;&amp;&gt;</message>',
      );
      expect(parseXmppElement(element.toXml()).text, '<&>');
    });

    test('JIDs are checked', () {
      expect(isValidBareJid('alice@example.org'), isTrue);
      expect(isValidBareJid('alice@'), isFalse);
      expect(isValidBareJid('a b@example.org'), isFalse);
      expect(isValidBareJid('a@b@example.org'), isFalse);
      expect(bareJid('Alice@Example.org/res'), 'alice@example.org');
      expect(bareJid('<bad>'), isNull);
      expect(
        XmppCarrierAddress.tryParse('alice@example.org|conest-1')?.fullJid,
        'alice@example.org/conest-1',
      );
      expect(XmppCarrierAddress.tryParse('alice@example.org'), isNull);
      expect(XmppCarrierAddress.tryParse('alice@example.org|a/b'), isNull);
      expect(XmppCarrierAddress.tryParse('Alice@example.org|c'), isNull);
    });
  });

  group('SASL', () {
    test('SCRAM-SHA-1 matches RFC 5802', () {
      final client = ScramClient(
        mechanism: 'SCRAM-SHA-1',
        username: 'user',
        password: 'pencil',
        clientNonce: 'fyko+d2lbbFgONRv9qkxdawL',
      );
      expect(
        utf8.decode(client.first()),
        'n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL',
      );
      final answer = client.respond(
        utf8.encode(
          'r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,'
          's=QSXCR+Q6sek8bf92,i=4096',
        ),
      );
      expect(
        utf8.decode(answer),
        'c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,'
        'p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=',
      );
      client.verify(utf8.encode('v=rmF9pqV8S7suAoZWja4dJRkFsKQ='));
      expect(
        () => client.verify(utf8.encode('v=AAAAAAAAAAAAAAAAAAAAAAAAAAA=')),
        throwsA(isA<XmppSaslException>()),
      );
    });

    test('SCRAM-SHA-256 matches RFC 7677', () {
      final client = ScramClient(
        mechanism: 'SCRAM-SHA-256',
        username: 'user',
        password: 'pencil',
        clientNonce: 'rOprNGfwEbeRWgbNEkqO',
      );
      client.first();
      final answer = client.respond(
        utf8.encode(
          r'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,'
          's=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096',
        ),
      );
      expect(
        utf8.decode(answer),
        r'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,'
        'p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=',
      );
      client.verify(
        utf8.encode('v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4='),
      );
    });

    test('hostile challenges are refused', () {
      ScramClient fresh() => ScramClient(
        mechanism: 'SCRAM-SHA-256',
        username: 'u',
        password: 'p',
        clientNonce: 'abc',
      )..first();
      // A nonce that does not extend ours, too few or too many rounds.
      for (final challenge in [
        'r=zzz123,s=QSXCR+Q6sek8bf92,i=4096',
        'r=abc123,s=QSXCR+Q6sek8bf92,i=1',
        'r=abc123,s=QSXCR+Q6sek8bf92,i=999999999',
        'r=abc,s=QSXCR+Q6sek8bf92,i=4096',
      ]) {
        expect(
          () => fresh().respond(utf8.encode(challenge)),
          throwsA(isA<XmppSaslException>()),
          reason: challenge,
        );
      }
      // PLAIN only over TLS.
      expect(chooseSaslMechanism(['PLAIN'], secure: false), isNull);
      expect(chooseSaslMechanism(['PLAIN'], secure: true), 'PLAIN');
      expect(
        chooseSaslMechanism(['PLAIN', 'SCRAM-SHA-1'], secure: true),
        'SCRAM-SHA-1',
      );
    });
  });

  group('session', () {
    test('signs in with STARTTLS, SCRAM and a bound resource', () async {
      final server = FakeXmppServer();
      server.addAccount('alice', 'secret');
      final session = XmppSession(
        jid: 'alice@xmpp.test',
        password: 'secret',
        resource: 'conest-1',
        endpoints: xmppEndpointCandidates('xmpp.test'),
        connector: server.connect,
      );
      addTearDown(session.stop);
      session.start();
      await _until(() => session.state == XmppSessionState.connected);
      expect(session.boundJid, 'alice@xmpp.test/conest-1');
      expect(server.boundResources, {'alice@xmpp.test/conest-1'});
      final auth = server.received.firstWhere((e) => e.name == 'auth');
      expect(auth.attr('mechanism'), 'SCRAM-SHA-256');
      // STARTTLS came before the sign-in.
      expect(
        server.received.indexWhere((e) => e.name == 'starttls'),
        lessThan(server.received.indexOf(auth)),
      );
    });

    test('never signs in without TLS', () async {
      final server = FakeXmppServer(offerStartTls: false);
      server.addAccount('alice', 'secret');
      final session = XmppSession(
        jid: 'alice@xmpp.test',
        password: 'secret',
        resource: 'conest-1',
        endpoints: [
          const XmppEndpoint(
            host: 'xmpp.test',
            port: 5222,
            mode: XmppEndpointMode.startTls,
          ),
        ],
        connector: server.connect,
      );
      addTearDown(session.stop);
      session.start();
      await _until(() => session.state == XmppSessionState.failed);
      expect(session.lastError, contains('TLS'));
      expect(server.received.where((e) => e.name == 'auth'), isEmpty);
    });

    test(
      'a plain loopback lab server is used as it is, STARTTLS offered or not',
      () async {
        final server = FakeXmppServer(offerPlainSignInToo: true);
        server.addAccount('alice', 'secret');
        final session = XmppSession(
          jid: 'alice@xmpp.test',
          password: 'secret',
          resource: 'conest-1',
          endpoints: [
            const XmppEndpoint(
              host: 'localhost',
              port: 5222,
              mode: XmppEndpointMode.plainLoopback,
            ),
          ],
          connector: server.connect,
        );
        addTearDown(session.stop);
        session.start();
        await _until(() => session.state == XmppSessionState.connected);
        expect(server.received.where((e) => e.name == 'starttls'), isEmpty);
      },
    );

    test('a wrong password stops trying', () async {
      final server = FakeXmppServer();
      server.addAccount('alice', 'secret');
      final session = XmppSession(
        jid: 'alice@xmpp.test',
        password: 'wrong',
        resource: 'conest-1',
        endpoints: xmppEndpointCandidates('xmpp.test'),
        connector: server.connect,
        retryDelay: const Duration(milliseconds: 20),
      );
      addTearDown(session.stop);
      session.start();
      await _until(() => session.authFailed);
      final attempts = server.connections.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.connections.length, attempts);
    });

    test('works over a WebSocket', () async {
      final server = FakeXmppServer();
      server.addAccount('alice', 'secret');
      final session = XmppSession(
        jid: 'alice@xmpp.test',
        password: 'secret',
        resource: 'conest-1',
        endpoints: [
          const XmppEndpoint(
            host: 'xmpp.test',
            port: 443,
            mode: XmppEndpointMode.webSocket,
            webSocketUrl: 'wss://xmpp.test/xmpp-websocket',
          ),
        ],
        connector: server.connect,
        webSocketConnector: server.connectWebSocket,
      );
      addTearDown(session.stop);
      session.start();
      await _until(() => session.state == XmppSessionState.connected);
      expect(server.connections, [XmppEndpointMode.webSocket]);
    });

    test(
      'answers from someone else than the asked address are ignored',
      () async {
        final server = FakeXmppServer();
        server.addAccount('alice', 'secret');
        server.addAccount('mallory', 'm');
        final alice = XmppSession(
          jid: 'alice@xmpp.test',
          password: 'secret',
          resource: 'r',
          endpoints: xmppEndpointCandidates('xmpp.test'),
          connector: server.connect,
        );
        addTearDown(alice.stop);
        alice.start();
        await _until(() => alice.state == XmppSessionState.connected);
        final asked = alice.request(
          XmppElement(
            'iq',
            attributes: {'type': 'get', 'to': 'bob@other.test', 'id': 'q1'},
            children: [XmppElement('query', xmlns: XmppNs.discoInfo)],
          ),
          timeout: const Duration(milliseconds: 500),
        );
        server.inject(
          XmppElement(
            'iq',
            attributes: {
              'type': 'result',
              'id': 'q1',
              'from': 'mallory@xmpp.test/x',
              'to': 'alice@xmpp.test/r',
            },
          ),
        );
        await expectLater(asked, throwsA(isA<TimeoutException>()));
      },
    );
  });

  group('carrier', () {
    test('frames cross between two accounts, body-less and private', () async {
      final server = FakeXmppServer();
      final received = <(String, Uint8List)>[];
      final alice = _channel(server, 'alice', onFrame: (_, _) {});
      final bob = _channel(
        server,
        'bob',
        onFrame: (sender, frame) => received.add((sender, frame)),
      );
      addTearDown(alice.stop);
      addTearDown(bob.stop);
      alice.start();
      bob.start();
      await _until(
        () =>
            alice.state == XmppCarrierState.connected &&
            bob.state == XmppCarrierState.connected,
      );
      final frame = Uint8List.fromList(List.generate(20000, (i) => i % 251));
      await alice.sendFrame(bob.localAddress!, frame);
      await _until(() => received.isNotEmpty);
      expect(received.single.$1, 'alice@xmpp.test');
      expect(received.single.$2, frame);
      final sent = server.received.lastWhere(
        (e) =>
            e.name == 'message' &&
            e.child('conest', XmppNs.conestCarrier) != null,
      );
      // Mainstream apps ignore it and never get a copy.
      expect(sent.child('body'), isNull);
      expect(sent.child('private', XmppNs.carbons), isNotNull);
      expect(sent.child('no-copy', XmppNs.hints), isNotNull);
      expect(sent.child('store', XmppNs.hints), isNotNull);
      expect(sent.attr('to'), 'bob@xmpp.test/conest-abc');
    });

    test('frames wait on the server for a device that is away', () async {
      final server = FakeXmppServer();
      final received = <Uint8List>[];
      final alice = _channel(server, 'alice', onFrame: (_, _) {});
      final bob = _channel(
        server,
        'bob',
        onFrame: (_, frame) => received.add(frame),
      );
      addTearDown(alice.stop);
      addTearDown(bob.stop);
      alice.start();
      await _until(() => alice.state == XmppCarrierState.connected);
      await alice.sendFrame(bob.localAddress!, Uint8List.fromList([1, 2, 3]));
      expect(server.offline['bob@xmpp.test'], hasLength(1));
      bob.start();
      await _until(() => received.isNotEmpty);
      expect(received.single, [1, 2, 3]);
    });

    test(
      'a dropped connection resumes and loses nothing',
      () async {
        final server = FakeXmppServer();
        final received = <Uint8List>[];
        final alice = _channel(server, 'alice', onFrame: (_, _) {});
        final bob = _channel(
          server,
          'bob',
          onFrame: (_, frame) => received.add(frame),
        );
        addTearDown(alice.stop);
        addTearDown(bob.stop);
        alice.start();
        bob.start();
        await _until(
          () =>
              alice.state == XmppCarrierState.connected &&
              bob.state == XmppCarrierState.connected,
        );
        // The server delivers to Bob but the connection drops before Bob's
        // acknowledgement, and Alice's frame is not acknowledged either.
        server.answerAcks = false;
        final sending = alice.sendFrame(
          bob.localAddress!,
          Uint8List.fromList([9]),
        );
        await _until(() => received.isNotEmpty);
        server.dropAll();
        server.answerAcks = true;
        await sending.timeout(const Duration(seconds: 20));
        await _until(
          () =>
              alice.state == XmppCarrierState.connected &&
              bob.state == XmppCarrierState.connected,
          timeout: const Duration(seconds: 20),
        );
        // Resumed, not signed in again.
        expect(server.received.where((e) => e.name == 'resume'), isNotEmpty);
        expect(received.first, [9]);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('only contacts get presence answers', () async {
      final server = FakeXmppServer();
      final bob = _channel(server, 'bob', onFrame: (_, _) {});
      addTearDown(bob.stop);
      bob.updatePeers({'alice@xmpp.test|conest-1'});
      bob.start();
      await _until(() => bob.state == XmppCarrierState.connected);
      // Bob asks Alice (a contact) for a subscription.
      await _until(
        () => server.received.any(
          (e) =>
              e.name == 'presence' &&
              e.attr('type') == 'subscribe' &&
              e.attr('to') == 'alice@xmpp.test',
        ),
      );
      for (final from in ['alice@xmpp.test', 'stranger@xmpp.test']) {
        server.inject(
          XmppElement(
            'presence',
            attributes: {
              'type': 'subscribe',
              'from': from,
              'to': 'bob@xmpp.test',
            },
          ),
        );
      }
      await _until(
        () => server.received.any(
          (e) =>
              e.attr('type') == 'subscribed' &&
              e.attr('to') == 'alice@xmpp.test',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        server.received.where(
          (e) =>
              e.attr('type') == 'subscribed' &&
              e.attr('to') == 'stranger@xmpp.test',
        ),
        isEmpty,
      );
    });

    test('the user\'s own account keeps its chats away from Conest', () async {
      final server = FakeXmppServer();
      final own = _channel(server, 'carol', onFrame: (_, _) {}, created: false);
      addTearDown(own.stop);
      own.start();
      await _until(() => own.state == XmppCarrierState.connected);
      final presence = server.received.lastWhere(
        (e) => e.name == 'presence' && e.attr('to') == null,
      );
      expect(presence.childText('priority'), '-1');
    });

    test('envelopes split into frames and are reassembled', () async {
      final server = FakeXmppServer();
      final sealer = _PlainSealer();
      final aliceAdapter = createXmppCarrierAdapter(sealer: sealer);
      final bobAdapter = createXmppCarrierAdapter(sealer: sealer);
      final alice = _channel(
        server,
        'alice',
        onFrame: aliceAdapter.receiveFrame,
      );
      final bob = _channel(server, 'bob', onFrame: bobAdapter.receiveFrame);
      aliceAdapter.attach(alice);
      bobAdapter.attach(bob);
      await aliceAdapter.start();
      await bobAdapter.start();
      addTearDown(aliceAdapter.stop);
      addTearDown(bobAdapter.stop);
      await _until(
        () =>
            alice.state == XmppCarrierState.connected &&
            bob.state == XmppCarrierState.connected,
      );
      final inbound = bobAdapter.inboundEnvelopes.first;
      final bytes = Uint8List.fromList(
        List.generate(100 * 1024, (i) => (i * 7) % 256),
      );
      final peer = TransportPeer(
        deviceId: 'bob-device',
        transportAddresses: {TransportKind.xmpp: bob.localAddress!},
      );
      final routes = await aliceAdapter.discoverRoutes(peer);
      await aliceAdapter.sendEnvelope(
        peer: peer,
        route: routes.single,
        envelope: TransportEnvelope(
          id: 'e1',
          recipientDeviceId: 'bob-device',
          bytes: bytes,
          createdAt: DateTime.now(),
        ),
      );
      final envelope = await inbound.timeout(const Duration(seconds: 10));
      expect(envelope.bytes, bytes);
      expect(envelope.transport, TransportKind.xmpp);
      // Five frames of at most 32 KiB of text each.
      final frames = server.received.where(
        (e) => e.child('conest', XmppNs.conestCarrier) != null,
      );
      expect(frames.length, 5);
      expect(
        frames.every(
          (e) =>
              e.child('conest', XmppNs.conestCarrier)!.text.length <=
              32 * 1024 + 64,
        ),
        isTrue,
      );
    });
  });

  group('accounts', () {
    test('probing picks a server that answers and registers', () async {
      final server = FakeXmppServer(domain: 'open.test');
      server.unreachableHosts.add('blocked.test');
      final closed = FakeXmppServer(allowRegistration: false);
      Future<XmppByteSocket> connector(
        String host,
        int port, {
        required bool tls,
        String? alpn,
      }) => host == 'closed.test'
          ? closed.connect(host, port, tls: tls, alpn: alpn)
          : server.connect(host, port, tls: tls, alpn: alpn);
      final probed = await reachableXmppServers(
        ['blocked.test', 'closed.test', 'open.test'],
        connector: connector,
        webSocketLookup: null,
        needRegistration: true,
        headStart: const Duration(milliseconds: 10),
      );
      expect(probed.map((p) => p.domain), ['open.test']);
      final config = await createXmppCarrierAccount(
        probed,
        resource: 'conest-x',
        connector: connector,
      );
      expect(config.created, isTrue);
      expect(config.jid, endsWith('@open.test'));
      final local = config.jid.split('@').first;
      expect(server.passwords[local], config.password);
      expect(config.password.length, 32);
      // The account works.
      await checkXmppLogin(config, connector: connector);
    });

    test('a taken name is retried with another', () async {
      final server = FakeXmppServer();
      final random = _RepeatingRandom();
      // The first name the random source makes is taken.
      final first = XmppCarrierConfig.newAccount(
        'open.test',
        resource: 'r',
        random: _RepeatingRandom(),
      );
      server.addAccount(first.jid.split('@').first, 'other');
      final config = await createXmppCarrierAccount(
        [
          XmppServerProbe(
            'open.test',
            xmppEndpointCandidates('open.test').first,
            register: true,
          ),
        ],
        resource: 'r',
        connector: server.connect,
        random: random,
      );
      expect(config.jid, isNot(first.jid));
    });

    test('config survives a round trip and rejects junk', () {
      final config = XmppCarrierConfig(
        jid: 'a@b.test',
        password: 'p',
        resource: 'conest-1',
        endpoints: const [
          XmppEndpoint(
            host: 'b.test',
            port: 5223,
            mode: XmppEndpointMode.directTls,
          ),
        ],
        created: true,
      );
      final copy = XmppCarrierConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())),
      )!;
      expect(copy.jid, 'a@b.test');
      expect(copy.endpoints.single.port, 5223);
      expect(copy.created, isTrue);
      expect(copy.connectEndpoints.first.port, 5223);
      expect(XmppCarrierConfig.fromJson({'jid': 'x'}), isNull);
      // No TLS only ever for this machine.
      expect(
        XmppEndpoint.fromJson({
          'host': 'evil.test',
          'port': 5222,
          'mode': 'plainLoopback',
        }),
        isNull,
      );
      expect(
        parseHostMetaWebSocket(
          '{"links":[{"rel":"urn:xmpp:alt-connections:websocket",'
          '"href":"wss://b.test/ws"}]}',
        ),
        'wss://b.test/ws',
      );
      expect(
        parseHostMetaWebSocket(
          '{"links":[{"rel":"urn:xmpp:alt-connections:websocket",'
          '"href":"ws://b.test/ws"}]}',
        ),
        isNull,
      );
    });
  });
}

/// Seals nothing: the envelope as is, from anyone.
class _PlainSealer implements CarrierSealer {
  @override
  bool acceptsSender(TransportKind kind, String sender) => true;

  @override
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    TransportKind kind,
    String sender,
    Uint8List sealed,
  ) async => (peerDeviceId: sender, envelope: sealed);

  @override
  Future<Uint8List> seal(
    TransportKind kind,
    String peerDeviceId,
    Uint8List envelope,
  ) async => envelope;
}

/// Random that starts over each time it is created, but moves on within
/// one instance only after a full name.
class _RepeatingRandom implements Random {
  int _calls = 0;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => (_calls++ ~/ 44) % max;
}
