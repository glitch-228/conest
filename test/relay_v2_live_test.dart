// Relay v2 against the real relay (`CONEST_RELAY_TEST_BINARY`, built by
// debug.yml): sessions, subscriptions, mailbox owners and the v1 forms the
// app still uses (UDP and HTTP), all from the Dart client.
import 'dart:convert';
import 'dart:io';

import 'package:conest/src/models.dart';
import 'package:conest/src/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _binary = Platform.environment['CONEST_RELAY_TEST_BINARY'];

class _Relay {
  _Relay(this.port, this.process, this.directory);

  final int port;
  final Process process;
  final Directory directory;
}

Future<_Relay> _startRelay({List<String> extra = const []}) async {
  final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = reservation.port;
  await reservation.close();
  final directory = await Directory.systemTemp.createTemp('conest_relay_v2_');
  final process = await Process.start(_binary!, [
    '127.0.0.1:$port',
    '--identity-seed-path',
    '${directory.path}/identity.seed',
    '--database-path',
    '${directory.path}/relay.sqlite3',
    '--max-requests-per-minute',
    '10000',
    ...extra,
  ]);
  process.stdout.listen((_) {});
  process.stderr.transform(utf8.decoder).listen(stderr.write);
  addTearDown(() async {
    process.kill();
    await process.exitCode;
    await directory.delete(recursive: true);
  });
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 100),
      );
      socket.destroy();
      return _Relay(port, process, directory);
    } on Object {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  fail('relay did not start');
}

RelayEnvelope _envelope(String id, String recipient) => RelayEnvelope(
  protocolVersion: 1,
  kind: 'direct_message',
  messageId: id,
  conversationId: 'c1',
  senderAccountId: 'acc-a',
  senderDeviceId: 'dev-a',
  recipientDeviceId: recipient,
  createdAt: DateTime.now().toUtc(),
  payloadBase64: base64Encode(utf8.encode('hello $id')),
);

/// The relay's identity, pinned as the app pins it (and what it says
/// about sessions learned).
Future<String> _pin(int port) async {
  const client = RelayClient();
  final unpinned = await client.inspectHealth(host: '127.0.0.1', port: port);
  final identity = unpinned.identityPublicKeyBase64!;
  await client.inspectHealth(
    host: '127.0.0.1',
    port: port,
    expectedIdentityPublicKeyBase64: identity,
  );
  return identity;
}

void main() {
  if (_binary == null) {
    test('relay v2 live tests', () {}, skip: 'needs CONEST_RELAY_TEST_BINARY');
    return;
  }
  setUp(RelayClient.resetSessionsForTesting);
  tearDown(RelayClient.resetSessionsForTesting);

  test('the client talks to the relay over a session and is pushed what '
      'arrives', () async {
    final relay = await _startRelay();
    final identity = await _pin(relay.port);
    final info = RelayClient.sessionInfoFor('127.0.0.1', relay.port)!;
    expect(info.sessions, isTrue);
    expect(info.mailboxAuth, isTrue);
    const client = RelayClient();
    final batches = <RelayFetchBatch>[];
    final subscription = client
        .subscribeEnvelopes(
          host: '127.0.0.1',
          port: relay.port,
          recipientDeviceId: 'dev-live',
          expectedIdentityPublicKeyBase64: identity,
        )
        .listen(batches.add);
    addTearDown(subscription.cancel);
    expect(
      await client.storeEnvelope(
        host: '127.0.0.1',
        port: relay.port,
        recipientDeviceId: 'dev-live',
        envelope: _envelope('live-1', 'dev-live'),
        expectedIdentityPublicKeyBase64: identity,
      ),
      isTrue,
    );
    for (var tries = 0; tries < 100; tries++) {
      if (batches.any((batch) => batch.envelopes.isNotEmpty)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final pushed = batches.firstWhere((batch) => batch.envelopes.isNotEmpty);
    expect(pushed.envelopes.single.messageId, 'live-1');
    await client.acknowledgeLease(
      host: '127.0.0.1',
      port: relay.port,
      recipientDeviceId: 'dev-live',
      leaseId: pushed.leaseId!,
      expectedIdentityPublicKeyBase64: identity,
    );
    final health = await client.inspectHealth(
      host: '127.0.0.1',
      port: relay.port,
      expectedIdentityPublicKeyBase64: identity,
    );
    expect(health.ok, isTrue);
  });

  test('UDP is sealed once the relay says it opens sealed datagrams', () async {
    final relay = await _startRelay();
    final identity = await _pin(relay.port);
    expect(
      RelayClient.sessionInfoFor('127.0.0.1', relay.port)?.udpSealed,
      isTrue,
    );
    const client = RelayClient();
    await client.storeEnvelope(
      host: '127.0.0.1',
      port: relay.port,
      protocol: PeerRouteProtocol.udp,
      recipientDeviceId: 'dev-sealed',
      envelope: _envelope('sealed-1', 'dev-sealed'),
      expectedIdentityPublicKeyBase64: identity,
    );
    final batch = await client.fetchLeasedEnvelopes(
      host: '127.0.0.1',
      port: relay.port,
      protocol: PeerRouteProtocol.udp,
      recipientDeviceId: 'dev-sealed',
      expectedIdentityPublicKeyBase64: identity,
    );
    expect(batch.envelopes.single.messageId, 'sealed-1');
    // The old cleartext form still works (an unpinned client).
    await client.storeEnvelope(
      host: '127.0.0.1',
      port: relay.port,
      protocol: PeerRouteProtocol.udp,
      recipientDeviceId: 'dev-plain',
      envelope: _envelope('plain-1', 'dev-plain'),
    );
    final plain = await client.fetchLeasedEnvelopes(
      host: '127.0.0.1',
      port: relay.port,
      protocol: PeerRouteProtocol.udp,
      recipientDeviceId: 'dev-plain',
    );
    expect(plain.envelopes.single.messageId, 'plain-1');
  });

  test('the borrowed handshake carries sessions against a real site', () async {
    // A real site: a TLS server (the test certificate) that says nothing.
    SecurityContext.defaultContext.setTrustedCertificates(
      'test/fixtures/relay_v2/tls/ca.pem',
    );
    final site = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain('test/fixtures/relay_v2/tls/cert.pem')
        ..usePrivateKey('test/fixtures/relay_v2/tls/key.pem'),
    );
    site.listen((socket) => socket.listen((_) {}, onError: (_) {}));
    addTearDown(site.close);
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final borrowedPort = reservation.port;
    await reservation.close();
    final relay = await _startRelay(
      extra: [
        '--borrow-bind',
        '127.0.0.1:$borrowedPort',
        '--borrow-site',
        '127.0.0.1:${site.port}',
        '--borrow-sni',
        'relay.test',
        '--public-host',
        '127.0.0.1',
        '--registration',
        'open',
      ],
    );
    final identity = await _pin(relay.port);
    // The relay tells its borrowed address inside a session only: ask again
    // now that sessions are known.
    // ...and only to a registered user (or one that proved a mailbox owned
    // before it came): this one registers.
    final token = await const RelayClient().register(
      host: '127.0.0.1',
      port: relay.port,
      expectedIdentityPublicKeyBase64: identity,
      accountSecret: List<int>.filled(32, 11),
    );
    RelayClient.setRelayTokens({identity: token});
    for (var attempt = 0; attempt < 10; attempt++) {
      if (RelayClient.sessionInfoFor('127.0.0.1', relay.port)?.borrowed !=
          null) {
        break;
      }
      await const RelayClient().inspectHealth(
        host: '127.0.0.1',
        port: relay.port,
        expectedIdentityPublicKeyBase64: identity,
      );
    }
    // The relay told its borrowed address inside a session.
    final told = RelayClient.sessionInfoFor('127.0.0.1', relay.port)?.borrowed;
    expect(told?.port, borrowedPort);
    expect(told?.sni, 'relay.test');
    // Reaching it needs the site's certificate to be valid for "relay.test"
    // (the test certificate has relay.test) and the pinned identity.
    RelayClient.registerBorrowedSite('127.0.0.1', borrowedPort, 'relay.test');
    const client = RelayClient();
    final health = await client.inspectHealth(
      host: '127.0.0.1',
      port: borrowedPort,
      protocol: PeerRouteProtocol.borrowed,
      expectedIdentityPublicKeyBase64: identity,
    );
    expect(health.identityPublicKeyBase64, identity);
    await client.storeEnvelope(
      host: '127.0.0.1',
      port: borrowedPort,
      protocol: PeerRouteProtocol.borrowed,
      recipientDeviceId: 'dev-borrowed',
      envelope: _envelope('borrowed-1', 'dev-borrowed'),
      expectedIdentityPublicKeyBase64: identity,
    );
    // Once a session is learned the same route runs sessions.
    for (var attempt = 0; attempt < 20; attempt++) {
      if (RelayClient.sessionInfoFor('127.0.0.1', borrowedPort)?.sessions ==
          true) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await client.inspectHealth(
        host: '127.0.0.1',
        port: borrowedPort,
        protocol: PeerRouteProtocol.borrowed,
        expectedIdentityPublicKeyBase64: identity,
      );
    }
    final batch = await client.fetchLeasedEnvelopes(
      host: '127.0.0.1',
      port: borrowedPort,
      protocol: PeerRouteProtocol.borrowed,
      recipientDeviceId: 'dev-borrowed',
      expectedIdentityPublicKeyBase64: identity,
    );
    expect(batch.envelopes.single.messageId, 'borrowed-1');
  });

  test('an owned mailbox takes only its owner\'s fetches, over a session, '
      'UDP and HTTP alike', () async {
    final relay = await _startRelay();
    final identity = await _pin(relay.port);
    const client = RelayClient();
    // This app owns dev-owned: its first session fetch claims it.
    RelayClient.registerMailboxSecret('dev-owned', List<int>.filled(32, 42));
    await client.storeEnvelope(
      host: '127.0.0.1',
      port: relay.port,
      recipientDeviceId: 'dev-owned',
      envelope: _envelope('owned-1', 'dev-owned'),
      expectedIdentityPublicKeyBase64: identity,
    );
    final first = await client.fetchLeasedEnvelopes(
      host: '127.0.0.1',
      port: relay.port,
      recipientDeviceId: 'dev-owned',
      expectedIdentityPublicKeyBase64: identity,
    );
    expect(first.envelopes.single.messageId, 'owned-1');
    await client.acknowledgeLease(
      host: '127.0.0.1',
      port: relay.port,
      recipientDeviceId: 'dev-owned',
      leaseId: first.leaseId!,
      expectedIdentityPublicKeyBase64: identity,
    );
    // Over UDP and HTTP (v1), the owner's proof goes with each request.
    for (final protocol in [PeerRouteProtocol.udp, PeerRouteProtocol.http]) {
      await client.storeEnvelope(
        host: '127.0.0.1',
        port: relay.port,
        protocol: protocol,
        recipientDeviceId: 'dev-owned',
        envelope: _envelope('owned-${protocol.name}', 'dev-owned'),
        expectedIdentityPublicKeyBase64: identity,
      );
      final batch = await client.fetchLeasedEnvelopes(
        host: '127.0.0.1',
        port: relay.port,
        protocol: protocol,
        recipientDeviceId: 'dev-owned',
        expectedIdentityPublicKeyBase64: identity,
      );
      expect(
        batch.envelopes.single.messageId,
        'owned-${protocol.name}',
        reason: protocol.name,
      );
      await client.acknowledgeLease(
        host: '127.0.0.1',
        port: relay.port,
        protocol: protocol,
        recipientDeviceId: 'dev-owned',
        leaseId: batch.leaseId!,
        expectedIdentityPublicKeyBase64: identity,
      );
    }
    // Someone else who knows the device id gets nothing: not over a
    // session, not over v1.
    await RelayClient.resetSessionsForTesting();
    await _pin(relay.port);
    await client.storeEnvelope(
      host: '127.0.0.1',
      port: relay.port,
      recipientDeviceId: 'dev-owned',
      envelope: _envelope('owned-private', 'dev-owned'),
      expectedIdentityPublicKeyBase64: identity,
    );
    for (final protocol in [PeerRouteProtocol.tcp, PeerRouteProtocol.http]) {
      await expectLater(
        client.fetchEnvelopes(
          host: '127.0.0.1',
          port: relay.port,
          protocol: protocol,
          recipientDeviceId: 'dev-owned',
          expectedIdentityPublicKeyBase64: identity,
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains('owner'),
            'refused for want of the owner',
          ),
        ),
        reason: protocol.name,
      );
    }
    // A mailbox nobody claimed is open as before.
    await client.storeEnvelope(
      host: '127.0.0.1',
      port: relay.port,
      recipientDeviceId: 'dev-open',
      envelope: _envelope('open-1', 'dev-open'),
    );
    final open = await client.fetchEnvelopes(
      host: '127.0.0.1',
      port: relay.port,
      recipientDeviceId: 'dev-open',
    );
    expect(open.single.messageId, 'open-1');
  });

  test('a registered-only relay takes stores from accounts registered with '
      'an invite', () async {
    final relay = await _startRelay(
      extra: ['--tier1', 'registered', '--registration', 'invite'],
    );
    final created = await Process.run(_binary!, [
      'admin',
      '--database-path',
      '${relay.directory.path}/relay.sqlite3',
      'invite',
      'create',
      '--uses',
      '1',
    ]);
    expect(created.exitCode, 0, reason: '${created.stderr}');
    final invite = (created.stdout as String).trim();
    final identity = await _pin(relay.port);
    final info = RelayClient.sessionInfoFor('127.0.0.1', relay.port)!;
    expect(info.tier1, 'registered');
    expect(info.registration, 'invite');
    const client = RelayClient();
    Future<bool> store(String id) => client.storeEnvelope(
      host: '127.0.0.1',
      port: relay.port,
      recipientDeviceId: 'dev-reg',
      envelope: _envelope(id, 'dev-reg'),
      expectedIdentityPublicKeyBase64: identity,
    );
    await expectLater(store('before'), throwsA(isA<StateError>()));
    await expectLater(
      client.register(
        host: '127.0.0.1',
        port: relay.port,
        expectedIdentityPublicKeyBase64: identity,
        accountSecret: List<int>.filled(32, 1),
      ),
      throwsA(isA<StateError>()),
      reason: 'an invite is needed',
    );
    final token = await client.register(
      host: '127.0.0.1',
      port: relay.port,
      expectedIdentityPublicKeyBase64: identity,
      accountSecret: List<int>.filled(32, 1),
      invite: invite,
    );
    expect(
      RelayClient.tokenExpiry(token)!.isAfter(DateTime.now().toUtc()),
      isTrue,
    );
    expect(await store('after'), isTrue);
    // Used up: another account cannot register with it.
    await expectLater(
      client.register(
        host: '127.0.0.1',
        port: relay.port,
        expectedIdentityPublicKeyBase64: identity,
        accountSecret: List<int>.filled(32, 2),
        invite: invite,
      ),
      throwsA(isA<StateError>()),
    );
    // The same account refreshes without one.
    final refreshed = await client.register(
      host: '127.0.0.1',
      port: relay.port,
      expectedIdentityPublicKeyBase64: identity,
      accountSecret: List<int>.filled(32, 1),
    );
    expect(refreshed, isNotEmpty);
  });

  test(
    'the relay\'s hidden address carries sessions inside TLS on a high '
    'port with a self-signed certificate, and probes see a web server',
    () async {
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final tlsPort = reservation.port;
      await reservation.close();
      final relay = await _startRelay(
        extra: [
          '--tls-bind',
          '127.0.0.1:$tlsPort',
          '--tls-cert',
          'test/fixtures/relay_v2/tls/cert.pem',
          '--tls-key',
          'test/fixtures/relay_v2/tls/key.pem',
          '--ws-path',
          's3cret-live-path',
        ],
      );
      final identity = await _pin(relay.port);
      RelayClient.registerWssPath('127.0.0.1', tlsPort, '/s3cret-live-path');
      const client = RelayClient();
      final health = await client.inspectHealth(
        host: '127.0.0.1',
        port: tlsPort,
        protocol: PeerRouteProtocol.wss,
        expectedIdentityPublicKeyBase64: identity,
      );
      expect(health.signatureVerified, isTrue);
      final batches = <RelayFetchBatch>[];
      final subscription = client
          .subscribeEnvelopes(
            host: '127.0.0.1',
            port: tlsPort,
            protocol: PeerRouteProtocol.wss,
            recipientDeviceId: 'dev-tls',
            expectedIdentityPublicKeyBase64: identity,
          )
          .listen(batches.add);
      addTearDown(subscription.cancel);
      expect(
        await client.storeEnvelope(
          host: '127.0.0.1',
          port: tlsPort,
          protocol: PeerRouteProtocol.wss,
          recipientDeviceId: 'dev-tls',
          envelope: _envelope('tls-1', 'dev-tls'),
          expectedIdentityPublicKeyBase64: identity,
        ),
        isTrue,
      );
      for (var tries = 0; tries < 100; tries++) {
        if (batches.any((batch) => batch.envelopes.isNotEmpty)) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        batches
            .firstWhere((batch) => batch.envelopes.isNotEmpty)
            .envelopes
            .single
            .messageId,
        'tls-1',
      );
      // A browser (or a probe) sees a web server, on the secret path too.
      final http = HttpClient()..badCertificateCallback = (_, _, _) => true;
      addTearDown(http.close);
      Future<(int, String)> get(String path) async {
        final request = await http.getUrl(
          Uri.parse('https://127.0.0.1:$tlsPort$path'),
        );
        final response = await request.close();
        return (
          response.statusCode,
          await response.transform(utf8.decoder).join(),
        );
      }

      final (frontStatus, front) = await get('/');
      expect(frontStatus, 200);
      expect(front, contains('Welcome to nginx!'));
      final (secretStatus, secret) = await get('/s3cret-live-path');
      final (unknownStatus, unknown) = await get('/nope');
      expect(secretStatus, 404);
      expect(unknownStatus, 404);
      expect(secret, unknown);
    },
  );
}
