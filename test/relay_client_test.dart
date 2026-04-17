import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/relay_client.dart';

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
}
