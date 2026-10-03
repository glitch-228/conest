import 'dart:io';

import 'package:conest/src/local_relay_node.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

void main() {
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
