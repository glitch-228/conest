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
}
