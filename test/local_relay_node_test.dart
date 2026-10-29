import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

RelayEnvelope _envelope(String id, int payloadBytes) => RelayEnvelope(
  protocolVersion: 1,
  kind: 'direct_message',
  messageId: id,
  conversationId: 'c1',
  senderAccountId: 'a',
  senderDeviceId: 'd1',
  recipientDeviceId: 'd2',
  createdAt: DateTime.now().toUtc(),
  payloadBase64: base64Encode(Uint8List(payloadBytes)),
);

Future<void> _storeOverTcp(int port, RelayEnvelope envelope) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.writeln(
    jsonEncode({
      'action': 'store',
      'recipient_device_id': 'd2',
      'envelope': envelope.toJson(),
    }),
  );
  await socket.flush();
  await socket.first.timeout(const Duration(seconds: 5));
  await socket.close();
}

/// One UDP request and its answer, or null when none comes.
Future<Map<String, dynamic>?> _udpAsk(
  int port,
  Map<String, Object?> request,
) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final answer = Completer<Map<String, dynamic>?>();
    socket.listen((event) {
      final datagram = event == RawSocketEvent.read ? socket.receive() : null;
      if (datagram != null && !answer.isCompleted) {
        answer.complete(
          jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>,
        );
      }
    });
    socket.send(
      utf8.encode(jsonEncode(request)),
      InternetAddress.loopbackIPv4,
      port,
    );
    return await answer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => null,
    );
  } finally {
    socket.close();
  }
}

void main() {
  test('a stored envelope reports the address that stored it', () async {
    final node = LocalRelayNode();
    final port = await _freePort();
    await node.start(port);
    addTearDown(node.stop);
    final peers = <String?>[];
    node.onEnvelopeStored = (_, _) => peers.add(node.storingPeer);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final envelope = RelayEnvelope(
      protocolVersion: 1,
      kind: 'direct_message',
      messageId: 'm1',
      conversationId: 'c1',
      senderAccountId: 'a',
      senderDeviceId: 'd1',
      recipientDeviceId: 'd2',
      createdAt: DateTime.now().toUtc(),
      payloadBase64: base64Encode(utf8.encode('x')),
    );
    socket.writeln(
      jsonEncode({
        'action': 'store',
        'recipient_device_id': 'd2',
        'envelope': envelope.toJson(),
      }),
    );
    await socket.flush();
    await socket.first.timeout(const Duration(seconds: 5));
    await socket.close();
    expect(peers, ['127.0.0.1']);
    expect(node.storingPeer, isNull, reason: 'only while reporting');
  });

  test('local network addresses are told apart from the internet', () {
    for (final address in [
      '127.0.0.1',
      '10.1.2.3',
      '172.20.0.5',
      '192.168.43.1',
      '169.254.1.1',
      'fe80::1',
      'fd12::1',
      '::1',
    ]) {
      expect(isLocalNetworkAddress(address), isTrue, reason: address);
    }
    for (final address in [
      '8.8.8.8',
      '172.32.0.1',
      '100.64.0.1',
      '2001:db8::1',
      'nonsense',
    ]) {
      expect(isLocalNetworkAddress(address), isFalse, reason: address);
    }
  });

  test('overlapping starts bind the port once', () async {
    final node = LocalRelayNode();
    addTearDown(node.stop);
    final port = await _freePort();
    // A poll and Check Paths starting the node together used to bind twice
    // and fail with "shared flag" on the second bind.
    await Future.wait([node.start(port), node.start(port), node.start(port)]);
    expect(node.isRunning, isTrue);
    expect(node.port, port);
    await Future.wait([node.stop(), node.start(port)]);
    expect(node.isRunning, isTrue);
  });

  test('a port held elsewhere fails cleanly and can be retried', () async {
    final node = LocalRelayNode();
    addTearDown(node.stop);
    final port = await _freePort();
    final blocker = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: false,
    );
    // TCP binds, UDP does not: nothing may stay half bound.
    await expectLater(node.start(port), throwsA(isA<SocketException>()));
    expect(node.isRunning, isFalse);
    blocker.close();
    await node.start(port);
    expect(node.isRunning, isTrue);
  });

  test('a UDP fetch answers with what fits in one datagram, and the rest '
      'stays queued', () async {
    final node = LocalRelayNode();
    final port = await _freePort();
    await node.start(port);
    addTearDown(node.stop);
    // Four of 20 kB: together far more than one datagram carries.
    for (var i = 0; i < 4; i++) {
      await _storeOverTcp(port, _envelope('m$i', 20 * 1024));
    }
    final got = <String>[];
    for (var round = 0; round < 6 && got.length < 4; round++) {
      final answer = await _udpAsk(port, {
        'action': 'fetch',
        'recipient_device_id': 'd2',
        'limit': 16,
      });
      expect(answer, isNotNull, reason: 'round $round got no answer');
      for (final message in answer!['messages'] as List) {
        got.add((message as Map)['messageId'] as String);
      }
    }
    expect(got..sort(), ['m0', 'm1', 'm2', 'm3']);
  });

  test('UDP keeps answering after the system closes its socket', () async {
    final node = LocalRelayNode();
    final port = await _freePort();
    await node.start(port);
    addTearDown(node.stop);
    expect(await _udpAsk(port, {'action': 'health'}), isNotNull);
    // A failed send makes Dart close the socket (as an oversized answer or
    // Android's blocked network did).
    node.udpSocketForTesting!.close();
    Map<String, dynamic>? answer;
    for (var i = 0; i < 20 && answer == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      answer = await _udpAsk(port, {'action': 'health'});
    }
    expect(answer, isNotNull);
    expect(node.isRunning, isTrue);
  });
}
