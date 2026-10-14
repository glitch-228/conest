import 'dart:convert';
import 'dart:io';

import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
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
}
