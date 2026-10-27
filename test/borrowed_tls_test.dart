import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conest/src/relay_v2/borrowed_tls.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/borrowed_relay_stub.dart';

SecurityContext _serverContext() => SecurityContext()
  ..useCertificateChain('test/fixtures/relay_v2/tls/cert.pem')
  ..usePrivateKey('test/fixtures/relay_v2/tls/key.pem');

/// A real site: a TLS server that answers a line with its reverse and
/// remembers whether it ever received data.
class _Site {
  _Site(this.server);
  final SecureServerSocket server;
  int connections = 0;
  final received = <int>[];

  static Future<_Site> start() async {
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      _serverContext(),
    );
    final site = _Site(server);
    server.listen((socket) {
      site.connections++;
      socket.listen((data) {
        site.received.addAll(data);
        socket.add(utf8.encode('site says hi'));
      }, onError: (_) {});
    }, onError: (_) {});
    return site;
  }
}

void main() {
  const seed = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
  ];

  test(
    'Ed25519 identity keys convert to the X25519 keys the relay uses',
    () async {
      final digest = (await Sha512().hash(seed)).bytes.sublist(0, 32);
      digest[0] &= 248;
      digest[31] &= 127;
      digest[31] |= 64;
      final x = await (await X25519().newKeyPairFromSeed(
        digest,
      )).extractPublicKey();
      final ed = await (await Ed25519().newKeyPairFromSeed(
        seed,
      )).extractPublicKey();
      expect(BorrowedTlsChannel.montgomeryFromEd25519(ed.bytes), x.bytes);
    },
  );

  test(
    'the borrowed handshake carries the relay bytes, and the site never sees them',
    () async {
      final site = await _Site.start();
      final relay = await BorrowedRelayStub.start(
        siteHost: '127.0.0.1',
        sitePort: site.server.port,
        seed: seed,
      );
      addTearDown(() async {
        await relay.close();
        await site.server.close();
      });
      final channel = await BorrowedTlsChannel.connect(
        host: '127.0.0.1',
        port: relay.port,
        sni: 'localhost',
        relayIdentity: relay.identityPublic,
        onBadCertificate: (_) => true,
      );
      addTearDown(channel.destroy);
      final collected = <int>[];
      var waiting = Completer<void>();
      channel.input.listen((chunk) {
        collected.addAll(chunk);
        if (!waiting.isCompleted) waiting.complete();
      });
      Future<void> until(int length) async {
        while (collected.length < length) {
          waiting = Completer<void>();
          await waiting.future.timeout(const Duration(seconds: 5));
        }
      }

      channel.add(utf8.encode('hello relay'));
      await until(11);
      expect(utf8.decode(collected), 'yaler olleh');
      expect(utf8.decode(relay.tunnelData.single), 'hello relay');
      // Large writes are split and come back whole.
      collected.clear();
      final big = List<int>.generate(30000, (i) => i % 251);
      channel.add(big);
      await until(big.length);
      expect(collected, _chunkReversed(big));
      // The real site got a handshake and no application data.
      expect(site.received, isEmpty);
    },
  );

  test('someone without the marker talks to the real site', () async {
    final site = await _Site.start();
    final relay = await BorrowedRelayStub.start(
      siteHost: '127.0.0.1',
      sitePort: site.server.port,
      seed: seed,
    );
    addTearDown(() async {
      await relay.close();
      await site.server.close();
    });
    final socket = await SecureSocket.connect(
      '127.0.0.1',
      relay.port,
      onBadCertificate: (_) => true,
    );
    socket.add(utf8.encode('GET / HTTP/1.1\r\n\r\n'));
    final reply = await socket.first.timeout(const Duration(seconds: 5));
    expect(utf8.decode(reply), 'site says hi');
    expect(utf8.decode(site.received), startsWith('GET /'));
    socket.destroy();
  });

  test('a client that has the wrong identity never gets the tunnel', () async {
    final site = await _Site.start();
    final relay = await BorrowedRelayStub.start(
      siteHost: '127.0.0.1',
      sitePort: site.server.port,
      seed: seed,
    );
    addTearDown(() async {
      await relay.close();
      await site.server.close();
    });
    final other = await (await Ed25519().newKeyPairFromSeed(
      List<int>.filled(32, 9),
    )).extractPublicKey();
    await expectLater(
      BorrowedTlsChannel.connect(
        host: '127.0.0.1',
        port: relay.port,
        sni: 'localhost',
        relayIdentity: other.bytes,
        timeout: const Duration(seconds: 3),
        onBadCertificate: (_) => true,
      ),
      throwsA(anything),
    );
    expect(relay.tunnelData, isEmpty);
  });

  test(
    'a certificate that does not match stops the handshake before the marker',
    () async {
      final site = await _Site.start();
      final relay = await BorrowedRelayStub.start(
        siteHost: '127.0.0.1',
        sitePort: site.server.port,
        seed: seed,
      );
      addTearDown(() async {
        await relay.close();
        await site.server.close();
      });
      await expectLater(
        BorrowedTlsChannel.connect(
          host: '127.0.0.1',
          port: relay.port,
          sni: 'localhost',
          relayIdentity: relay.identityPublic,
          timeout: const Duration(seconds: 3),
        ),
        throwsA(anything),
      );
      expect(relay.tunnelData, isEmpty);
    },
  );
}

/// The stub reverses each record's data: the writes are cut at 8 KiB.
List<int> _chunkReversed(List<int> data) {
  final out = <int>[];
  for (var offset = 0; offset < data.length; offset += 8192) {
    final end = offset + 8192 < data.length ? offset + 8192 : data.length;
    out.addAll(data.sublist(offset, end).reversed);
  }
  return out;
}
