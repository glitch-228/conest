import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/relay_client.dart';
import 'package:conest/src/relay_defaults.dart';
import 'package:conest/src/relay_link.dart';
import 'package:conest/src/relay_v2/frames.dart';
import 'package:conest/src/relay_v2/noise_nk.dart';
import 'package:conest/src/relay_v2/session.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _fixture() =>
    jsonDecode(File('test/fixtures/relay_v2/session.json').readAsStringSync())
        as Map<String, dynamic>;

Uint8List _hex(String text) => Uint8List.fromList([
  for (var index = 0; index < text.length; index += 2)
    int.parse(text.substring(index, index + 2), radix: 16),
]);

String _toHex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

RelayEnvelope _envelope(String id, {String recipient = 'dev-b'}) =>
    RelayEnvelope(
      protocolVersion: 1,
      kind: 'direct_message',
      messageId: id,
      conversationId: 'c1',
      senderAccountId: 'acc-a',
      senderDeviceId: 'dev-a',
      recipientDeviceId: recipient,
      createdAt: DateTime.utc(2026, 10, 24),
      payloadBase64: base64Encode(utf8.encode('hello $id')),
    );

/// A relay with an identity (v2 sessions), started on a free port.
Future<(LocalRelayNode, int, String)> _startRelay({List<int>? seed}) async {
  final node = LocalRelayNode(
    identitySeed: seed ?? List<int>.generate(32, (index) => index + 1),
  );
  final port = await _freePort();
  await node.start(port);
  addTearDown(node.stop);
  final health = await const RelayClient().inspectHealth(
    host: '127.0.0.1',
    port: port,
  );
  return (node, port, health.identityPublicKeyBase64!);
}

void main() {
  setUp(RelayClient.resetSessionsForTesting);
  tearDown(RelayClient.resetSessionsForTesting);

  group('shared fixtures', () {
    test('the client handshake and records match the fixture', () async {
      final fixture = _fixture();
      expect(fixture['protocol'], relayV2NoiseProtocol);
      expect(_toHex(relayV2Prologue), fixture['prologue']);
      final initiator = await NoiseNkInitiator.start(
        relayStaticPublic: _hex(fixture['relay_static_public'] as String),
        ephemeralSeed: _hex(fixture['client_ephemeral_private'] as String),
      );
      final message1 = await initiator.writeMessage1(
        _hex(fixture['msg1_payload'] as String),
      );
      expect(_toHex(message1), fixture['msg1']);
      final (payload, transport) = await initiator.readMessage2(
        _hex(fixture['msg2'] as String),
      );
      expect(_toHex(payload), fixture['msg2_payload']);
      expect(_toHex(transport.handshakeHash), fixture['handshake_hash']);
      for (final record in (fixture['transport'] as List).cast<Map>()) {
        if (record['from'] != 'client') continue;
        final sealed = await transport.send.encryptWithAd(
          const [],
          _hex(record['plaintext'] as String),
        );
        final expected = _hex(record['record'] as String);
        expect(_toHex(sealed), _toHex(expected.sublist(2)));
      }
      for (final record in (fixture['transport'] as List).cast<Map>()) {
        if (record['from'] != 'relay') continue;
        final opened = await transport.receive.decryptWithAd(
          const [],
          _hex(record['record'] as String).sublist(2),
        );
        expect(_toHex(opened), record['plaintext']);
      }
    });

    test('the relay side of the handshake matches the fixture', () async {
      final fixture = _fixture();
      final relayStatic = await X25519().newKeyPairFromSeed(
        _hex(fixture['relay_static_private'] as String),
      );
      expect(
        _toHex((await relayStatic.extractPublicKey()).bytes),
        fixture['relay_static_public'],
      );
      final responder = await NoiseNkResponder.start(
        staticKeyPair: relayStatic,
        ephemeralSeed: _hex(fixture['relay_ephemeral_private'] as String),
      );
      final payload = await responder.readMessage1(
        _hex(fixture['msg1'] as String),
      );
      expect(_toHex(payload), fixture['msg1_payload']);
      final (message2, transport) = await responder.writeMessage2(
        _hex(fixture['msg2_payload'] as String),
      );
      expect(_toHex(message2), fixture['msg2']);
      expect(_toHex(transport.handshakeHash), fixture['handshake_hash']);
    });

    test('a reply made without the relay key is refused', () async {
      final fixture = _fixture();
      final initiator = await NoiseNkInitiator.start(
        relayStaticPublic: _hex(fixture['relay_static_public'] as String),
        ephemeralSeed: _hex(fixture['client_ephemeral_private'] as String),
      );
      await initiator.writeMessage1(_hex(fixture['msg1_payload'] as String));
      final tampered = _hex(fixture['msg2'] as String);
      tampered[40] ^= 1;
      await expectLater(
        initiator.readMessage2(tampered),
        throwsA(isA<FormatException>()),
      );
    });

    test('frames encode as the fixture says and are bounded', () {
      final fixture = _fixture();
      for (final sample in (fixture['frames'] as List).cast<Map>()) {
        final encoded = encodeRelayV2Frame(
          sample['type'] as int,
          sample['stream'] as int,
          utf8.encode(sample['payload'] as String),
        );
        expect(_toHex(encoded), sample['hex']);
        final decoder = RelayV2FrameDecoder(1024);
        RelayV2Frame? found;
        for (final byte in encoded) {
          decoder.add([byte]);
          found ??= decoder.next();
        }
        expect(found?.type, sample['type']);
        expect(found?.stream, sample['stream']);
        expect(utf8.decode(found!.payload), sample['payload']);
      }
      final decoder = RelayV2FrameDecoder(16);
      decoder.add(encodeRelayV2Frame(1, 1, List<int>.filled(17, 0)));
      expect(decoder.next, throwsFormatException);
    });

    test('an in-app relay derives and signs its session key as the fixture '
        'says', () async {
      final fixture = _fixture();
      final (_, port, identity) = await _startRelay(
        seed: _hex(fixture['identity_seed'] as String),
      );
      expect(_toHex(base64Decode(identity)), fixture['identity_public']);
      // Learned from the signed health answer, under the identity that
      // signed it (used only where that identity is pinned).
      expect(
        RelayClient.sessionInfoFor('127.0.0.1', port)?.identityPublicKeyBase64,
        identity,
      );
      final learned = RelayClient.sessionInfoFor('127.0.0.1', port)!;
      expect(learned.sessions, isTrue);
      expect(_toHex(learned.noiseKey!), fixture['relay_static_public']);
    });
  });

  group('sessions against the in-app relay', () {
    test('a session stores, fetches, and subscribes', () async {
      final (node, port, identity) = await _startRelay();
      await const RelayClient().inspectHealth(
        host: '127.0.0.1',
        port: port,
        expectedIdentityPublicKeyBase64: identity,
      );
      final noiseKey = RelayClient.sessionInfoFor('127.0.0.1', port)!.noiseKey!;
      final before = node.sessionsServed;
      final session = await RelayV2Session.connect(
        channel: await SocketRelayChannel.connect('127.0.0.1', port),
        relayNoiseKey: noiseKey,
      );
      addTearDown(session.close);
      expect(session.hello['v'], 1);
      final events = <Map<String, dynamic>>[];
      final subscription = session
          .subscribe({
            'action': 'subscribe',
            'mailboxes': ['dev-sub'],
          })
          .listen(events.add);
      addTearDown(subscription.cancel);
      final stored = await session.request({
        'action': 'store',
        'recipient_device_id': 'dev-sub',
        'envelope': _envelope('s1', recipient: 'dev-sub').toJson(),
      });
      expect(stored['stored'], isTrue);
      for (var tries = 0; tries < 50 && events.length < 2; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(events.first['subscribed'], ['dev-sub']);
      expect(events[1]['messages'][0]['messageId'], 's1');
      expect(node.sessionsServed, before + 1);
      // Requests in flight together on the one session.
      final answers = await Future.wait([
        for (var index = 0; index < 5; index++)
          session.request({
            'action': 'store',
            'recipient_device_id': 'dev-many',
            'envelope': _envelope('m$index', recipient: 'dev-many').toJson(),
          }),
      ]);
      expect(answers.every((answer) => answer['stored'] == true), isTrue);
      final fetched = await session.request({
        'action': 'fetch',
        'recipient_device_id': 'dev-many',
      });
      expect((fetched['messages'] as List).length, 5);
      final refused = await session.request({'action': 'nope'});
      expect(refused['ok'], isFalse);
    });

    test('a session against the wrong key fails', () async {
      final (_, port, _) = await _startRelay();
      final wrong = await X25519().newKeyPairFromSeed(List<int>.filled(32, 9));
      await expectLater(
        RelayV2Session.connect(
          channel: await SocketRelayChannel.connect('127.0.0.1', port),
          relayNoiseKey: (await wrong.extractPublicKey()).bytes,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(anything),
      );
    });

    test('a pinned relay that offers sessions is used over one, and a '
        'subscription pushes what arrives', () async {
      final (node, port, identity) = await _startRelay();
      const client = RelayClient();
      // The first request learns (in the background) that it has sessions.
      await client.storeEnvelope(
        host: '127.0.0.1',
        port: port,
        recipientDeviceId: 'dev-b',
        envelope: _envelope('v1-first'),
        expectedIdentityPublicKeyBase64: identity,
      );
      for (var tries = 0; tries < 50; tries++) {
        if (RelayClient.sessionInfoFor('127.0.0.1', port) != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        client.supportsSubscribe(
          host: '127.0.0.1',
          port: port,
          expectedIdentityPublicKeyBase64: identity,
        ),
        isTrue,
      );
      expect(
        client.supportsSubscribe(host: '127.0.0.1', port: port),
        isFalse,
        reason: 'only with a pinned identity',
      );
      final batches = <RelayFetchBatch>[];
      final subscription = client
          .subscribeEnvelopes(
            host: '127.0.0.1',
            port: port,
            recipientDeviceId: 'dev-b',
            expectedIdentityPublicKeyBase64: identity,
          )
          .listen(batches.add);
      addTearDown(subscription.cancel);
      for (var tries = 0; tries < 50 && batches.length < 2; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // In place (an empty batch), then what was queued already.
      expect(batches.first.envelopes, isEmpty);
      expect(batches[1].envelopes.single.messageId, 'v1-first');
      await client.storeEnvelope(
        host: '127.0.0.1',
        port: port,
        recipientDeviceId: 'dev-b',
        envelope: _envelope('v2-second'),
        expectedIdentityPublicKeyBase64: identity,
      );
      for (var tries = 0; tries < 50 && batches.length < 3; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(batches[2].envelopes.single.messageId, 'v2-second');
      // The store went over the session (one session for everything).
      expect(node.sessionsServed, 1);
    });

    test('an owned mailbox is not asked for in cleartext when its session '
        'fails', () async {
      final (node, port, identity) = await _startRelay();
      const client = RelayClient();
      await client.inspectHealth(
        host: '127.0.0.1',
        port: port,
        expectedIdentityPublicKeyBase64: identity,
      );
      RelayClient.registerMailboxSecret('dev-owned', List<int>.filled(32, 9));
      await RelayClient.v2Pool.closeAll();
      // Sessions cannot open now, though v1 would still answer. The fetch
      // fails; it does not turn into a cleartext v1 request carrying the
      // mailbox id and its proof.
      node.refuseSessions = true;
      final before = node.v1RequestsSeen;
      await expectLater(
        client.fetchEnvelopes(
          host: '127.0.0.1',
          port: port,
          recipientDeviceId: 'dev-owned',
          timeout: const Duration(seconds: 2),
          expectedIdentityPublicKeyBase64: identity,
        ),
        throwsA(anything),
      );
      expect(node.v1RequestsSeen, before);
    });

    test('a broken session is replaced on the next request', () async {
      final (node, port, identity) = await _startRelay();
      const client = RelayClient();
      await client.inspectHealth(
        host: '127.0.0.1',
        port: port,
        expectedIdentityPublicKeyBase64: identity,
      );
      await client.storeEnvelope(
        host: '127.0.0.1',
        port: port,
        recipientDeviceId: 'dev-b',
        envelope: _envelope('r1'),
        expectedIdentityPublicKeyBase64: identity,
      );
      expect(node.sessionsServed, 1);
      await RelayClient.v2Pool.closeAll();
      await client.storeEnvelope(
        host: '127.0.0.1',
        port: port,
        recipientDeviceId: 'dev-b',
        envelope: _envelope('r2'),
        expectedIdentityPublicKeyBase64: identity,
      );
      expect(node.sessionsServed, 2);
      final fetched = await client.fetchEnvelopes(
        host: '127.0.0.1',
        port: port,
        recipientDeviceId: 'dev-b',
        expectedIdentityPublicKeyBase64: identity,
      );
      expect(fetched.map((envelope) => envelope.messageId), ['r1', 'r2']);
    });

    test('a relay without sessions keeps v1', () async {
      final node = LocalRelayNode();
      final port = await _freePort();
      await node.start(port);
      addTearDown(node.stop);
      const client = RelayClient();
      // Unpinned, unsigned: v1 as before.
      expect(
        await client.storeEnvelope(
          host: '127.0.0.1',
          port: port,
          recipientDeviceId: 'dev-b',
          envelope: _envelope('old-1'),
        ),
        isTrue,
      );
      final fetched = await client.fetchEnvelopes(
        host: '127.0.0.1',
        port: port,
        recipientDeviceId: 'dev-b',
      );
      expect(fetched.single.messageId, 'old-1');
      expect(node.sessionsServed, 0);
      expect(
        client.supportsSubscribe(
          host: '127.0.0.1',
          port: port,
          expectedIdentityPublicKeyBase64: 'AAAA',
        ),
        isFalse,
      );
    });

    test(
      'a session key the pinned identity did not sign is not used',
      () async {
        // A relay whose health offers sessions under a key signed by someone
        // else: the client stays on v1.
        final identity = await Ed25519().newKeyPairFromSeed(
          List<int>.filled(32, 3),
        );
        final stranger = await Ed25519().newKeyPairFromSeed(
          List<int>.filled(32, 4),
        );
        final identityKey = base64Encode(
          (await identity.extractPublicKey()).bytes,
        );
        final noiseKey = List<int>.filled(32, 7);
        final badBinding = await Ed25519().sign([
          ...relayV2BindingLabel,
          ...noiseKey,
        ], keyPair: stranger);
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        var sessionAttempts = 0;
        server.listen((socket) {
          final lines = <int>[];
          socket.listen((chunk) async {
            lines.addAll(chunk);
            if (lines.length >= 4 &&
                utf8.decode(lines.take(4).toList(), allowMalformed: true) ==
                    'CNS2') {
              sessionAttempts++;
              socket.destroy();
              return;
            }
            if (!lines.contains(10)) return;
            final request =
                jsonDecode(utf8.decode(lines.sublist(0, lines.indexOf(10))))
                    as Map<String, dynamic>;
            final body = jsonEncode({
              'ok': true,
              'stored': request['action'] == 'store',
              'messages': const [],
              'error': null,
              'stats': {
                'relay_id': 'fake',
                'identity_public_key': identityKey,
                'v2': {
                  'sessions': 1,
                  'noise': relayV2NoiseProtocol,
                  'noise_key': base64Encode(noiseKey),
                  'noise_key_sig': base64Encode(badBinding.bytes),
                },
              },
            });
            final nonce = base64Decode(request['nonce'] as String);
            final signature = await Ed25519().sign([
              ...utf8.encode(request['action'] as String),
              ...nonce,
              ...utf8.encode(body),
            ], keyPair: identity);
            socket.writeln(
              jsonEncode({
                'sig_v': 2,
                'body': body,
                'nonce_echo': request['nonce'],
                'signature': base64Encode(signature.bytes),
              }),
            );
            await socket.flush();
            await socket.close();
          });
        });
        const client = RelayClient();
        await client.inspectHealth(
          host: '127.0.0.1',
          port: server.port,
          expectedIdentityPublicKeyBase64: identityKey,
        );
        final info = RelayClient.sessionInfoFor('127.0.0.1', server.port)!;
        expect(info.sessions, isFalse);
        expect(
          await client.storeEnvelope(
            host: '127.0.0.1',
            port: server.port,
            recipientDeviceId: 'dev-b',
            envelope: _envelope('bad-binding'),
            expectedIdentityPublicKeyBase64: identityKey,
          ),
          isTrue,
        );
        expect(sessionAttempts, 0);
      },
    );
  });

  group('hidden (wss) relay addresses', () {
    test('a wss address parses with its secret path, which stays out of '
        'labels and invites', () {
      final route = PeerEndpoint.normalized(
        kind: PeerRouteKind.relay,
        host: 'wss://relay.test/s3cret-path_1',
        port: 7667,
      );
      expect(route.protocol, PeerRouteProtocol.wss);
      expect(route.port, 443);
      expect(route.path, '/s3cret-path_1');
      expect(route.label, isNot(contains('s3cret')));
      expect(route.routeKey, isNot(contains('s3cret')));
      final back = PeerEndpoint.fromJson(route.toJson());
      expect(back.path, '/s3cret-path_1');
      expect(
        () => PeerEndpoint.normalized(
          kind: PeerRouteKind.relay,
          host: 'wss://relay.test',
          port: 443,
        ),
        throwsArgumentError,
        reason: 'no path, no hidden address',
      );
    });

    test('the client reaches a relay through TLS and a WebSocket, and '
        'trusts a self-signed certificate only for a pinned relay', () async {
      final (node, relayPort, identity) = await _startRelay();
      // A front like the relay's: TLS, the secret path upgrades, its bytes
      // go to the relay.
      final front = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain('test/fixtures/relay_v2/tls/cert.pem')
          ..usePrivateKey('test/fixtures/relay_v2/tls/key.pem'),
      );
      addTearDown(() => front.close(force: true));
      final seenPaths = <String>[];
      front.listen((request) async {
        seenPaths.add(request.uri.path);
        if (request.uri.path != '/s3cret-path_1' ||
            !WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        final upstream = await Socket.connect('127.0.0.1', relayPort);
        upstream.listen(
          socket.add,
          onDone: () => socket.close(),
          onError: (_) => socket.close(),
        );
        socket.listen(
          (data) => upstream.add(
            data is String ? utf8.encode(data) : data as List<int>,
          ),
          onDone: upstream.destroy,
          onError: (_) => upstream.destroy(),
        );
      });
      RelayClient.registerWssPath('127.0.0.1', front.port, '/s3cret-path_1');
      const client = RelayClient();
      // Unpinned: the certificate must be a WebPKI one, and is not.
      await expectLater(
        client.inspectHealth(
          host: '127.0.0.1',
          port: front.port,
          protocol: PeerRouteProtocol.wss,
        ),
        throwsA(anything),
      );
      // Pinned, but the certificate's hash was never signed by the
      // identity: the secret path is not even sent.
      seenPaths.clear();
      await expectLater(
        client.inspectHealth(
          host: '127.0.0.1',
          port: front.port,
          protocol: PeerRouteProtocol.wss,
          expectedIdentityPublicKeyBase64: identity,
        ),
        throwsA(anything),
      );
      expect(
        seenPaths,
        isEmpty,
        reason: 'the path went to an unverified server',
      );
      // A different certificate's hash does not do either.
      RelayClient.debugRegisterTlsCert(identity, List<int>.filled(32, 7));
      await expectLater(
        client.inspectHealth(
          host: '127.0.0.1',
          port: front.port,
          protocol: PeerRouteProtocol.wss,
          expectedIdentityPublicKeyBase64: identity,
        ),
        throwsA(anything),
      );
      expect(seenPaths, isEmpty);
      // The signed hash of this very certificate: accepted.
      final pem = File(
        'test/fixtures/relay_v2/tls/cert.pem',
      ).readAsStringSync();
      final der = base64Decode(
        pem
            .split('-----BEGIN CERTIFICATE-----')[1]
            .split('-----END CERTIFICATE-----')[0]
            .replaceAll(RegExp(r'\s'), ''),
      );
      RelayClient.debugRegisterTlsCert(identity, sha256.convert(der).bytes);
      final health = await client.inspectHealth(
        host: '127.0.0.1',
        port: front.port,
        protocol: PeerRouteProtocol.wss,
        expectedIdentityPublicKeyBase64: identity,
      );
      expect(health.signatureVerified, isTrue);
      expect(
        RelayClient.sessionInfoFor('127.0.0.1', front.port)?.sessions,
        isTrue,
      );
      final before = node.sessionsServed;
      expect(
        await client.storeEnvelope(
          host: '127.0.0.1',
          port: front.port,
          protocol: PeerRouteProtocol.wss,
          recipientDeviceId: 'dev-hidden',
          envelope: _envelope('hidden-1', recipient: 'dev-hidden'),
          expectedIdentityPublicKeyBase64: identity,
        ),
        isTrue,
      );
      expect(node.sessionsServed, before + 1, reason: 'a session inside');
      final fetched = await client.fetchEnvelopes(
        host: '127.0.0.1',
        port: front.port,
        protocol: PeerRouteProtocol.wss,
        recipientDeviceId: 'dev-hidden',
        expectedIdentityPublicKeyBase64: identity,
      );
      expect(fetched.single.messageId, 'hidden-1');
      expect(
        client.supportsSubscribe(
          host: '127.0.0.1',
          port: front.port,
          protocol: PeerRouteProtocol.wss,
          expectedIdentityPublicKeyBase64: identity,
        ),
        isTrue,
      );
    });
  });

  group('hidden addresses in links and lists', () {
    test('a relay link may carry the hidden address', () {
      const key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      final link = RelayLink.tryParse(
        'conest-relay://relay.example.org:7667?id=r1&key=${Uri.encodeQueryComponent(key)}'
        '&wss=${Uri.encodeQueryComponent('wss://relay.example.org/s3cret-path_1')}',
      )!;
      expect(link.hiddenAddress, 'wss://relay.example.org/s3cret-path_1');
      expect(
        RelayLink.tryParse(link.toString())?.hiddenAddress,
        link.hiddenAddress,
      );
      expect(
        RelayLink.tryParse(
          'conest-relay://relay.example.org?id=r1&key=${Uri.encodeQueryComponent(key)}'
          '&wss=${Uri.encodeQueryComponent('wss://relay.example.org/')}',
        ),
        isNull,
        reason: 'a hidden address without its secret path is refused',
      );
    });

    test('a relay list carries wss entries only with their path', () {
      final list = parseUnsignedRelayList(
        jsonEncode({
          'version': 1,
          'issuedAt': '2026-10-26T00:00:00Z',
          'endpoints': [
            {
              'kind': 'relay',
              'host': 'relay.example.org',
              'port': 443,
              'protocol': 'wss',
              'path': '/s3cret-path_1',
            },
            {
              'kind': 'relay',
              'host': 'relay.example.org',
              'port': 443,
              'protocol': 'wss',
              'path': '/bad path',
            },
          ],
        }),
      )!;
      expect(list.endpoints.first.path, '/s3cret-path_1');
      expect(list.endpoints.last.path, isNull);
    });
  });

  group('borrowed-handshake addresses', () {
    test('an endpoint carries the site name, and refuses a bad one', () {
      final endpoint = PeerEndpoint.normalized(
        kind: PeerRouteKind.relay,
        host: 'borrowed://relay.example.org/www.example.com',
        port: 443,
      );
      expect(endpoint.protocol, PeerRouteProtocol.borrowed);
      expect(endpoint.path, 'www.example.com');
      expect(endpoint.label, isNot(contains('www.example.com')));
      final back = PeerEndpoint.fromJson(endpoint.toJson());
      expect(back.path, 'www.example.com');
      expect(back.protocol, PeerRouteProtocol.borrowed);
      for (final bad in ['', 'nodots', 'a b.com', '-x.com', 'x..com']) {
        expect(
          () => PeerEndpoint.normalized(
            kind: PeerRouteKind.relay,
            host: 'relay.example.org',
            port: 443,
            protocol: PeerRouteProtocol.borrowed,
            path: bad,
          ),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  test('a v1 mailbox proof also covers the lease and limit parameters', () {
    expect(
      RelayClient.v1ProofExtra('fetch', {'limit': 4, 'wait_ms': 100}),
      '|4|100|',
    );
    expect(RelayClient.v1ProofExtra('fetch', {}), '|||');
    expect(
      RelayClient.v1ProofExtra('fetch_leased', {'limit': 2, 'lease_ms': 30000}),
      '|2||30000',
    );
    expect(
      RelayClient.v1ProofExtra('ack_lease', {'lease_id': 'abc'}),
      'abc|||',
    );
    expect(RelayClient.v1ProofExtra('store', {'limit': 1}), '');
  });
}
