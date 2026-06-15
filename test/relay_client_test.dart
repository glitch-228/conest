import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/relay_client.dart';

/// Minimal line-protocol relay that answers every request with a v2
/// detached-signature wrapper. [mutateBodyAfterSigning] simulates an
/// on-path attacker tampering with the body after the relay signed it.
Future<ServerSocket> _startDetachedSigningRelay({
  required SimpleKeyPair keyPair,
  required String identityPublicKeyBase64,
  String Function(String rawBody)? mutateBodyAfterSigning,
}) async {
  final algorithm = Ed25519();
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    utf8.decoder.bind(socket).transform(const LineSplitter()).listen((
      line,
    ) async {
      final request = jsonDecode(line) as Map<String, dynamic>;
      expect(request['sig_mode'], 'detached');
      final action = request['action'] as String;
      final nonce = base64Decode(request['nonce'] as String);
      // `1.5e3` is valid JSON that serde emits but Dart's jsonEncode
      // re-encodes as `1500.0` — the legacy inline scheme silently
      // degrades exactly this response to "unsigned".
      final rawBody =
          '{"ok":true,"stored":false,"messages":[],"error":null,'
          '"stats":{"relay_id":"detached-test","queue_count":0,'
          '"queued_envelope_count":0,"ttl_seconds":1.5e3,'
          '"max_queue_per_mailbox":512,"max_fetch_limit":128,'
          '"identity_public_key":"$identityPublicKeyBase64"}}';
      final signature = await algorithm.sign([
        ...utf8.encode(action),
        ...nonce,
        ...utf8.encode(rawBody),
      ], keyPair: keyPair);
      final wireBody = mutateBodyAfterSigning?.call(rawBody) ?? rawBody;
      socket.writeln(
        jsonEncode({
          'sig_v': 2,
          'body': wireBody,
          'nonce_echo': request['nonce'],
          'signature': base64Encode(signature.bytes),
        }),
      );
      await socket.flush();
      await socket.close();
    });
  });
  return server;
}

void main() {
  test(
    'relay client can store and fetch through UDP local relay protocol',
    () async {
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();

      final node = LocalRelayNode();
      addTearDown(node.stop);
      await node.start(port);

      const client = RelayClient();
      final envelope = RelayEnvelope(
        kind: 'debug_udp_loopback',
        messageId: 'msg-udp',
        conversationId: 'conv-udp',
        senderAccountId: 'acc-a',
        senderDeviceId: 'dev-a',
        recipientDeviceId: 'dev-b',
        createdAt: DateTime.utc(2026, 4, 16),
        payloadBase64: 'aGVsbG8=',
      );

      final stored = await client.storeEnvelope(
        host: '127.0.0.1',
        port: port,
        protocol: PeerRouteProtocol.udp,
        recipientDeviceId: 'dev-b',
        envelope: envelope,
        timeout: const Duration(seconds: 2),
      );
      final fetched = await client.fetchEnvelopes(
        host: '127.0.0.1',
        port: port,
        protocol: PeerRouteProtocol.udp,
        recipientDeviceId: 'dev-b',
        timeout: const Duration(seconds: 2),
      );

      expect(stored, isTrue);
      expect(fetched.single.messageId, 'msg-udp');
    },
  );

  test(
    'relay client can store and fetch through HTTP local relay protocol',
    () async {
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();

      final node = LocalRelayNode();
      addTearDown(node.stop);
      await node.start(port);

      const client = RelayClient();
      final envelope = RelayEnvelope(
        kind: 'debug_http_loopback',
        messageId: 'msg-http',
        conversationId: 'conv-http',
        senderAccountId: 'acc-a',
        senderDeviceId: 'dev-a',
        recipientDeviceId: 'dev-b',
        createdAt: DateTime.utc(2026, 4, 17),
        payloadBase64: 'aGVsbG8=',
      );

      final health = await client.inspectHealth(
        host: '127.0.0.1',
        port: port,
        protocol: PeerRouteProtocol.http,
        timeout: const Duration(seconds: 2),
      );
      final stored = await client.storeEnvelope(
        host: '127.0.0.1',
        port: port,
        protocol: PeerRouteProtocol.http,
        recipientDeviceId: 'dev-b',
        envelope: envelope,
        timeout: const Duration(seconds: 2),
      );
      final fetched = await client.fetchEnvelopes(
        host: '127.0.0.1',
        port: port,
        protocol: PeerRouteProtocol.http,
        recipientDeviceId: 'dev-b',
        timeout: const Duration(seconds: 2),
      );

      expect(health.ok, isTrue);
      expect(stored, isTrue);
      expect(fetched.single.messageId, 'msg-http');
    },
  );

  test('local relay notifies when an envelope is stored', () async {
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();

    final node = LocalRelayNode();
    addTearDown(node.stop);
    await node.start(port);

    final storedEnvelope = Completer<RelayEnvelope>();
    node.onEnvelopeStored = (recipientDeviceId, envelope) {
      if (recipientDeviceId == 'dev-b') {
        storedEnvelope.complete(envelope);
      }
    };

    const client = RelayClient();
    final envelope = RelayEnvelope(
      kind: 'direct_message',
      messageId: 'msg-push',
      conversationId: 'conv-push',
      senderAccountId: 'acc-a',
      senderDeviceId: 'dev-a',
      recipientDeviceId: 'dev-b',
      createdAt: DateTime.utc(2026, 4, 17),
      payloadBase64: 'aGVsbG8=',
    );

    await client.storeEnvelope(
      host: '127.0.0.1',
      port: port,
      recipientDeviceId: 'dev-b',
      envelope: envelope,
      timeout: const Duration(seconds: 2),
    );

    final pushed = await storedEnvelope.future.timeout(
      const Duration(seconds: 2),
    );
    expect(pushed.messageId, 'msg-push');
  });

  test('local relay validates mailbox ids and clamps fetch limits', () async {
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();

    final node = LocalRelayNode(maxQueuePerMailbox: 2, maxFetchLimit: 1);
    addTearDown(node.stop);
    await node.start(port);

    const client = RelayClient();
    RelayEnvelope envelope(String id) => RelayEnvelope(
      kind: 'direct_message',
      messageId: id,
      conversationId: 'conv-cap',
      senderAccountId: 'acc-a',
      senderDeviceId: 'dev-a',
      recipientDeviceId: 'dev-b',
      createdAt: DateTime.utc(2026, 4, 18),
      payloadBase64: 'aGVsbG8=',
    );

    await client.storeEnvelope(
      host: '127.0.0.1',
      port: port,
      recipientDeviceId: 'dev-b',
      envelope: envelope('msg-0'),
      timeout: const Duration(seconds: 2),
    );
    await client.storeEnvelope(
      host: '127.0.0.1',
      port: port,
      recipientDeviceId: 'dev-b',
      envelope: envelope('msg-1'),
      timeout: const Duration(seconds: 2),
    );
    await client.storeEnvelope(
      host: '127.0.0.1',
      port: port,
      recipientDeviceId: 'dev-b',
      envelope: envelope('msg-2'),
      timeout: const Duration(seconds: 2),
    );

    final first = await client.fetchEnvelopes(
      host: '127.0.0.1',
      port: port,
      recipientDeviceId: 'dev-b',
      limit: 99,
      timeout: const Duration(seconds: 2),
    );
    final second = await client.fetchEnvelopes(
      host: '127.0.0.1',
      port: port,
      recipientDeviceId: 'dev-b',
      limit: 99,
      timeout: const Duration(seconds: 2),
    );

    expect(first.single.messageId, 'msg-1');
    expect(second.single.messageId, 'msg-2');
    await expectLater(
      client.storeEnvelope(
        host: '127.0.0.1',
        port: port,
        recipientDeviceId: '../bad',
        envelope: envelope('msg-bad'),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'local relay rejects oversize envelopes and rate limits peers',
    () async {
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();

      final node = LocalRelayNode(
        maxEnvelopeBytes: 128,
        maxLineBytes: 256,
        maxRequestsPerMinute: 1,
      );
      addTearDown(node.stop);
      await node.start(port);

      const client = RelayClient();
      final envelope = RelayEnvelope(
        kind: 'direct_message',
        messageId: 'msg-large',
        conversationId: 'conv-large',
        senderAccountId: 'acc-a',
        senderDeviceId: 'dev-a',
        recipientDeviceId: 'dev-b',
        createdAt: DateTime.utc(2026, 4, 18),
        payloadBase64: 'x' * 240,
      );

      await expectLater(
        client.storeEnvelope(
          host: '127.0.0.1',
          port: port,
          recipientDeviceId: 'dev-b',
          envelope: envelope,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<StateError>()),
      );

      final limited = LocalRelayNode(maxRequestsPerMinute: 1);
      final reservedLimited = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final limitedPort = reservedLimited.port;
      await reservedLimited.close();
      addTearDown(limited.stop);
      await limited.start(limitedPort);

      expect(
        await client.health(
          host: '127.0.0.1',
          port: limitedPort,
          timeout: const Duration(seconds: 2),
        ),
        isTrue,
      );
      await expectLater(
        client.health(
          host: '127.0.0.1',
          port: limitedPort,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('detached-signature responses verify over raw body bytes even when the '
      'body contains float formatting Dart cannot round-trip', () async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKeyBase64 = base64Encode(
      (await keyPair.extractPublicKey()).bytes,
    );
    final server = await _startDetachedSigningRelay(
      keyPair: keyPair,
      identityPublicKeyBase64: publicKeyBase64,
    );
    addTearDown(server.close);

    const client = RelayClient();
    final info = await client.inspectHealth(
      host: '127.0.0.1',
      port: server.port,
      timeout: const Duration(seconds: 2),
    );

    expect(info.ok, isTrue);
    expect(info.relayInstanceId, 'detached-test');
    expect(info.identityPublicKeyBase64, publicKeyBase64);
    expect(
      info.signatureVerified,
      isTrue,
      reason:
          'the detached path must verify over the exact body bytes; the '
          'legacy re-encode path degrades this response to unsigned',
    );
  });

  test(
    'tampered detached body fails verification against a pinned key',
    () async {
      final keyPair = await Ed25519().newKeyPair();
      final publicKeyBase64 = base64Encode(
        (await keyPair.extractPublicKey()).bytes,
      );
      final server = await _startDetachedSigningRelay(
        keyPair: keyPair,
        identityPublicKeyBase64: publicKeyBase64,
        mutateBodyAfterSigning: (rawBody) =>
            rawBody.replaceFirst('"queue_count":0', '"queue_count":7'),
      );
      addTearDown(server.close);

      const client = RelayClient();
      await expectLater(
        client.inspectHealth(
          host: '127.0.0.1',
          port: server.port,
          timeout: const Duration(seconds: 2),
          expectedIdentityPublicKeyBase64: publicKeyBase64,
        ),
        throwsA(isA<RelayIdentityMismatchException>()),
      );
    },
  );
}
