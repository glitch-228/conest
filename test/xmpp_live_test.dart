// Runs against a real XMPP server when CONEST_XMPP_HOST is set (the debug
// workflow starts Prosody with in-band registration, plain c2s on 5222 and
// a WebSocket on 5280, all on localhost), so the client meets a server
// implementation other than the test fake: registration, sign-in, stream
// management, offline storage of body-less messages and the WebSocket.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/xmpp/xmpp_carrier.dart';
import 'package:conest/src/xmpp/xmpp_session.dart';
import 'package:conest/src/xmpp/xmpp_socket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = Platform.environment['CONEST_XMPP_HOST'];
  final domain = Platform.environment['CONEST_XMPP_DOMAIN'] ?? 'localhost';
  final skip = host == null ? 'CONEST_XMPP_HOST is not set' : null;
  final plain = XmppEndpoint(
    host: host ?? 'localhost',
    port: 5222,
    mode: XmppEndpointMode.plainLoopback,
  );
  final webSocket = XmppEndpoint(
    host: host ?? 'localhost',
    port: 5280,
    mode: XmppEndpointMode.webSocket,
    webSocketUrl: 'ws://${host ?? 'localhost'}:5280/xmpp-websocket',
  );

  Future<XmppCarrierConfig> register(XmppEndpoint endpoint) async {
    final config = XmppCarrierConfig.newAccount(
      domain,
      resource: newXmppResource(),
      endpoints: [endpoint],
      random: Random.secure(),
    );
    await registerXmppAccount(
      endpoint: endpoint,
      domain: domain,
      username: config.jid.split('@').first,
      password: config.password,
    );
    return config;
  }

  Future<void> until(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('Timed out: $what');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test(
    'frames cross a real XMPP server, also to a device that was away',
    () async {
      final aliceConfig = await register(plain);
      final bobConfig = await register(webSocket);
      final received = <(String, Uint8List)>[];
      final alice = XmppCarrierChannel(config: aliceConfig, onFrame: (_, _) {});
      XmppCarrierChannel bobChannel() => XmppCarrierChannel(
        config: bobConfig,
        onFrame: (sender, frame) => received.add((sender, frame)),
        log: print,
      );
      var bob = bobChannel();
      addTearDown(alice.stop);
      alice.start();
      bob.start();
      await until(
        () =>
            alice.state == XmppCarrierState.connected &&
            bob.state == XmppCarrierState.connected,
        'both connected (${alice.lastError}, ${bob.lastError})',
      );
      expect(alice.session!.endpoint!.mode, XmppEndpointMode.plainLoopback);
      expect(bob.session!.endpoint!.mode, XmppEndpointMode.webSocket);
      final frame = Uint8List.fromList(
        List<int>.generate(24 * 1024, (index) => index * 13 % 256),
      );
      await alice.sendFrame(bob.localAddress!, frame);
      await until(() => received.isNotEmpty, 'the first frame');
      expect(received.single.$1, aliceConfig.jid);
      expect(received.single.$2, frame);

      // Bob goes away; the server keeps the body-less frame for him.
      await bob.stop();
      received.clear();
      await alice.sendFrame(bob.localAddress!, Uint8List.fromList([1, 2, 3]));
      bob = bobChannel();
      addTearDown(bob.stop);
      bob.start();
      await until(() => received.isNotEmpty, 'the stored frame');
      expect(received.single.$2, [1, 2, 3]);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a wrong password is refused and not retried',
    () async {
      final config = await register(plain);
      final session = XmppSession(
        jid: config.jid,
        password: '${config.password}x',
        resource: config.resource,
        endpoints: [plain],
      );
      addTearDown(session.stop);
      session.start();
      await until(() => session.authFailed, 'the refusal');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
