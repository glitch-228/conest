import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/stealth/client_hello.dart';
import 'package:flutter_test/flutter_test.dart';

/// A ClientHello with known contents (GREASE in the ciphers, the first
/// extension, the groups and the versions), and the JA3 and JA4 an
/// independent implementation (a few lines of Python from the same
/// definitions) gives it.
const _synthetic =
    '16030100b2010000ae030300000000000000000000000000000000000000000000000000'
    '000000000000000000080a0a13011302c02b0100007d2a2a000000000010000e00000b65'
    '78616d706c652e636f6d000a000800060a0a001d0017000b00020100000d000800060403'
    '080404010010000e000c02683208687474702f312e31002b0007060a0a03040303003300'
    '260024001d00200000000000000000000000000000000000000000000000000000000000'
    '00000000';

List<int> _hex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];

/// The first TLS record a client sends after it connects to a server that
/// only listens: what the app's TLS library puts on the wire.
Future<List<int>> _captureHello(
  Future<void> Function(int port) startClient,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final seen = Completer<List<int>>();
  server.listen((client) {
    final bytes = BytesBuilder();
    client.listen((chunk) {
      bytes.add(chunk);
      final soFar = bytes.toBytes();
      if (soFar.length >= 5) {
        final need = 5 + ((soFar[3] << 8) | soFar[4]);
        if (soFar.length >= need && !seen.isCompleted) {
          seen.complete(soFar.sublist(0, need));
          client.destroy();
        }
      }
    }, onError: (_) {});
  });
  try {
    unawaited(startClient(server.port).catchError((Object _) {}));
    return await seen.future.timeout(const Duration(seconds: 10));
  } finally {
    await server.close();
  }
}

Future<void> _secure(int port, {String? host, List<String>? protocols}) async {
  final plain = await Socket.connect(InternetAddress.loopbackIPv4, port);
  await SecureSocket.secure(
    plain,
    host: host ?? 'relay.example.org',
    supportedProtocols: protocols,
    onBadCertificate: (_) => true,
  );
}

void main() {
  group('the parser and the fingerprints', () {
    test('a known hello gives the known JA3 and JA4', () {
      final hello = parseClientHello(_hex(_synthetic));
      expect(hello.serverName, 'example.com');
      expect(hello.alpn, ['h2', 'http/1.1']);
      expect(hello.cipherSuites, [0x0a0a, 0x1301, 0x1302, 0xc02b]);
      expect(hello.supportedVersions, [0x0a0a, 0x0304, 0x0303]);
      expect(hello.keyShareGroups, [0x001d]);
      expect(
        hello.ja3String,
        '771,4865-4866-49195,0-10-11-13-16-43-51,29-23,0',
      );
      expect(hello.ja3, 'ce04116d61aa4c0fc142193e54a2a31e');
      expect(hello.ja4, 't13d0307h2_5559582ccdc4_5e6a61e7dae5');
    });

    test('GREASE does not change a fingerprint', () {
      final bytes = _hex(_synthetic);
      final plain = parseClientHello(bytes);
      // The first cipher (GREASE 0x0a0a) as another GREASE value.
      final other = [...bytes];
      final at = bytes.length;
      expect(at, greaterThan(100));
      for (var i = 0; i < other.length - 1; i++) {
        if (other[i] == 0x0a && other[i + 1] == 0x0a && i == 0x50) {
          other[i] = 0x5a;
          other[i + 1] = 0x5a;
        }
      }
      expect(parseClientHello(other).ja3, plain.ja3);
      expect(parseClientHello(other).ja4, plain.ja4);
    });

    test('anything that is not a whole ClientHello is refused', () {
      final bytes = _hex(_synthetic);
      expect(
        () => parseClientHello(bytes.sublist(0, 60)),
        throwsA(isA<ClientHelloFormatException>()),
      );
      expect(
        () => parseClientHello([0x17, 3, 3, 0, 1, 0]),
        throwsA(isA<ClientHelloFormatException>()),
      );
      final serverHello = [...bytes]..[5] = 2;
      expect(
        () => parseClientHello(serverHello),
        throwsA(isA<ClientHelloFormatException>()),
      );
    });
  });

  group('what the app\'s own TLS library sends', () {
    late final Map<String, dynamic> pins;
    setUpAll(() {
      pins =
          jsonDecode(
                File(
                  'test/fixtures/stealth/dart_client_hello.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
    });

    Future<Map<String, ClientHelloInfo>> captured() async => {
      // The relay's hidden address: SNI, ALPN http/1.1 only.
      'relay-wss': parseClientHello(
        await _captureHello(
          (port) => _secure(port, protocols: const ['http/1.1']),
        ),
      ),
      // The borrowed handshake's real TLS: the site's name, h2 and http/1.1.
      'borrowed-tap': parseClientHello(
        await _captureHello(
          (port) => _secure(
            port,
            host: 'www.bing.com',
            protocols: const ['h2', 'http/1.1'],
          ),
        ),
      ),
      // DoH to an address, through HttpClient.
      'doh-by-ip': parseClientHello(
        await _captureHello((port) async {
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 2);
          client.badCertificateCallback = (_, _, _) => true;
          try {
            final request = await client.postUrl(
              Uri.parse('https://127.0.0.1:$port/dns-query'),
            );
            await request.close().timeout(const Duration(seconds: 2));
          } finally {
            client.close(force: true);
          }
        }),
      ),
    };

    test('is captured, and does not change without a person looking '
        '(M38 P0)', () async {
      final now = await captured();
      for (final entry in now.entries) {
        // ignore: avoid_print
        print(
          'M38 P0 ClientHello ${Platform.operatingSystem} '
          '${entry.key}: ${entry.value.summary}',
        );
      }
      // What a censor can see without breaking TLS: the server name and
      // what the client offers.
      expect(now['relay-wss']!.serverName, 'relay.example.org');
      expect(now['relay-wss']!.alpn, ['http/1.1']);
      expect(now['borrowed-tap']!.serverName, 'www.bing.com');
      expect(now['borrowed-tap']!.alpn, ['h2', 'http/1.1']);
      // Dialling an address, Dart puts the address in the SNI, which RFC
      // 6066 forbids: a tell of its own, measured here, not yet fixed.
      expect(now['doh-by-ip']!.serverName, '127.0.0.1');
      for (final hello in now.values) {
        // TLS 1.3 is offered, and the hello carries no GREASE (a browser's
        // would): the app's library is not a browser's.
        expect(hello.supportedVersions, contains(0x0304));
      }
      final platform = Platform.operatingSystem;
      final forPlatform = [
        for (final pin in pins['pins'] as List<dynamic>)
          if ((pin as Map<String, dynamic>)['platform'] == platform) pin,
      ];
      if (forPlatform.isEmpty) {
        markTestSkipped(
          'No pin for $platform yet: capture it on a $platform build and add '
          'it to test/fixtures/stealth/dart_client_hello.json.',
        );
        return;
      }
      final pinned = (forPlatform.last['hellos'] as Map<String, dynamic>);
      final changes = <String>[];
      for (final entry in now.entries) {
        final was = pinned[entry.key] as Map<String, dynamic>?;
        if (was == null ||
            was['ja3'] != entry.value.ja3 ||
            was['ja4'] != entry.value.ja4) {
          changes.add(
            '${entry.key}: was ${was?['ja3']} ${was?['ja4']}, '
            'now ${entry.value.ja3} ${entry.value.ja4}',
          );
        }
      }
      expect(
        changes,
        isEmpty,
        reason:
            'Dart ${Platform.version.split(' ').first} sends another TLS '
            'ClientHello than the pinned one. A network that blocks by '
            'fingerprint sees the change: a person decides (is it still '
            'common? does a relay route need work?) and adds a pin to '
            'test/fixtures/stealth/dart_client_hello.json.',
      );
    });
  });
}
