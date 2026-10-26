import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/circumvention/circumvention.dart';
import 'package:conest/src/circumvention/doh_resolver.dart';
import 'package:conest/src/circumvention/fragmenting_proxy.dart';
import 'package:conest/src/circumvention/lan_beacon_codec.dart';
import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

SecurityContext _serverContext() => SecurityContext()
  ..useCertificateChain('test/fixtures/relay_v2/tls/cert.pem')
  ..usePrivateKey('test/fixtures/relay_v2/tls/key.pem');

SecurityContext _clientContext() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/relay_v2/tls/ca.pem');

/// A TLS echo server for relay.test.
Future<SecureServerSocket> _echoServer() async {
  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    _serverContext(),
  );
  server.listen(
    (socket) => socket.listen(
      socket.add,
      onDone: socket.close,
      onError: (_) => socket.destroy(),
    ),
    onError: (_) {},
  );
  return server;
}

/// A filter like a censor's: it reads a connection's first segment and
/// drops the connection when it holds [blocked] (a server name).
Future<ServerSocket> _fakeDpi(int upstreamPort, String blocked) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final needle = utf8.encode(blocked);
  server.listen((client) async {
    final input = StreamIterator<Uint8List>(client);
    if (!await input.moveNext()) {
      client.destroy();
      return;
    }
    final first = input.current;
    if (_contains(first, needle)) {
      client.destroy();
      return;
    }
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      upstreamPort,
    );
    upstream.add(first);
    unawaited(client.addStream(upstream).catchError((Object _) {}));
    while (await input.moveNext()) {
      upstream.add(input.current);
    }
    await upstream.close();
  });
  return server;
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var match = true;
    for (var index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

Future<String> _echoOver(SecureSocket socket) async {
  socket.add(utf8.encode('ping'));
  await socket.flush();
  final answer = await socket.first.timeout(const Duration(seconds: 5));
  await socket.close();
  return utf8.decode(answer);
}

/// A DNS answer to [query] with [addresses].
List<int> _answer(List<int> query, List<InternetAddress> addresses) {
  final out = BytesBuilder()
    ..add([
      query[0],
      query[1],
      0x81,
      0x80,
      0,
      1,
      0,
      addresses.length,
      0,
      0,
      0,
      0,
    ])
    ..add(query.sublist(12));
  for (final address in addresses) {
    final raw = address.rawAddress;
    out.add([
      0xc0,
      12,
      0,
      raw.length == 4 ? 1 : 28,
      0,
      1,
      0,
      0,
      1,
      0,
      0,
      raw.length,
      ...raw,
    ]);
  }
  return out.takeBytes();
}

int _queryType(List<int> query) =>
    (query[query.length - 4] << 8) | query[query.length - 3];

void main() {
  group('ClientHello fragmentation', () {
    test('a filter reading the first segment blocks the plain connection '
        'and lets the fragmented one through', () async {
      final echo = await _echoServer();
      addTearDown(echo.close);
      final dpi = await _fakeDpi(echo.port, 'relay.test');
      addTearDown(dpi.close);

      final plain = await Socket.connect(
        InternetAddress.loopbackIPv4,
        dpi.port,
      );
      await expectLater(
        SecureSocket.secure(
          plain,
          host: 'relay.test',
          context: _clientContext(),
        ).timeout(const Duration(seconds: 5)),
        throwsA(anything),
        reason: 'the filter sees the name and drops it',
      );

      final proxy = FragmentingProxy(
        resolve: (_) async => [InternetAddress.loopbackIPv4],
        segmentGap: const Duration(milliseconds: 50),
      );
      addTearDown(proxy.stop);
      final through = await proxy.secureConnect(
        'relay.test',
        dpi.port,
        context: _clientContext(),
      );
      expect(await _echoOver(through), 'ping');

      // Sabotage check built in: without the split, the same filter wins.
      proxy.fragment = false;
      await expectLater(
        proxy.secureConnect('relay.test', dpi.port, context: _clientContext()),
        throwsA(anything),
      );
    });

    test('the proxy takes CONNECT only with its token', () async {
      final echo = await _echoServer();
      addTearDown(echo.close);
      final proxy = FragmentingProxy(
        resolve: (_) async => [InternetAddress.loopbackIPv4],
      );
      await proxy.start();
      addTearDown(proxy.stop);
      Future<String> connect(String? authorization) async {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          proxy.port!,
        );
        socket.write(
          'CONNECT relay.test:${echo.port} HTTP/1.1\r\n'
          '${authorization == null ? '' : 'Proxy-Authorization: $authorization\r\n'}'
          '\r\n',
        );
        await socket.flush();
        final answer = utf8.decode(
          await socket.first.timeout(const Duration(seconds: 5)),
        );
        socket.destroy();
        return answer;
      }

      expect(await connect(null), startsWith('HTTP/1.1 407'));
      expect(await connect('Basic d3Jvbmc='), startsWith('HTTP/1.1 407'));
      expect(await connect(proxy.authorization), startsWith('HTTP/1.1 200'));
      // HttpClient goes through it as a proxy (credentials in the proxy
      // setting, sent with the CONNECT).
      final site = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        _serverContext(),
      );
      addTearDown(() => site.close(force: true));
      site.listen((request) async {
        request.response.write('through');
        await request.response.close();
      });
      final client = HttpClient(context: _clientContext())
        ..findProxy = ((_) => proxy.proxyDirective);
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('https://relay.test:${site.port}/'),
      );
      final response = await request.close();
      expect(await response.transform(utf8.decoder).join(), 'through');
    });

    test('the server name is found in a real ClientHello and the split '
        'keeps it out of each piece', () async {
      final capture = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(capture.close);
      final hello = Completer<Uint8List>();
      capture.listen((socket) async {
        hello.complete(await socket.first);
        socket.destroy();
      });
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        capture.port,
      );
      unawaited(
        SecureSocket.secure(
          socket,
          host: 'hidden.example.org',
        ).then((_) {}, onError: (Object _) {}),
      );
      final record = await hello.future;
      final sni = findClientHelloSni(record)!;
      expect(
        latin1.decode(record.sublist(sni.offset, sni.offset + sni.length)),
        'hidden.example.org',
      );
      final pieces = splitClientHello(record);
      expect(pieces.length, greaterThanOrEqualTo(2));
      for (final piece in pieces) {
        expect(_contains(piece, utf8.encode('hidden.example.org')), isFalse);
      }
      // Two well-formed records that hold the same handshake bytes.
      final rejoined = <int>[];
      for (final piece in pieces.take(2)) {
        expect(piece[0], 0x16);
        expect((piece[3] << 8) | piece[4], piece.length - 5);
        rejoined.addAll(piece.sublist(5));
      }
      expect(rejoined, record.sublist(5, 5 + ((record[3] << 8) | record[4])));
      expect(splitClientHello(Uint8List.fromList([1, 2, 3])).single, [1, 2, 3]);
    });
  });

  group('DNS over HTTPS', () {
    final good = InternetAddress('93.184.216.34');
    final sinkhole = InternetAddress('10.10.34.35');

    test('a poisoned system answer is not used; DoH\'s is', () async {
      var systemAsked = 0;
      final resolver = DohResolver(
        endpoints: [Uri.parse('https://doh.test/dns-query')],
        transport: (endpoint, query, timeout) async =>
            _answer(query, _queryType(query) == 1 ? [good] : []),
        systemLookup: (_) async {
          systemAsked++;
          return [sinkhole];
        },
      );
      expect(await resolver.resolve('blocked.example'), [good]);
      expect(systemAsked, 0);
    });

    test(
      'when every resolver fails, the system answers (unless poisoned)',
      () async {
        final resolver = DohResolver(
          endpoints: [
            Uri.parse('https://a.test/dns-query'),
            Uri.parse('https://b.test/dns-query'),
          ],
          transport: (_, _, _) async => throw const SocketException('blocked'),
          systemLookup: (host) async =>
              host == 'poisoned.example' ? [sinkhole] : [good],
        );
        expect(await resolver.resolve('fine.example'), [good]);
        await expectLater(
          resolver.resolve('poisoned.example'),
          throwsA(isA<SocketException>()),
        );
      },
    );

    test('a poisoned DoH answer loses to a good one', () async {
      final resolver = DohResolver(
        endpoints: [
          Uri.parse('https://liar.test/dns-query'),
          Uri.parse('https://honest.test/dns-query'),
        ],
        transport: (endpoint, query, _) async {
          if (_queryType(query) != 1) return _answer(query, []);
          if (endpoint.host == 'liar.test') return _answer(query, [sinkhole]);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _answer(query, [good]);
        },
        systemLookup: (_) async => [sinkhole],
      );
      expect(await resolver.resolve('site.example'), [good]);
    });

    test('answers to another query, or malformed ones, are ignored', () {
      final query = encodeDnsQuery('site.example', 1, id: 0x1234);
      final answer = _answer(query, [good]);
      expect(decodeDnsAnswer(answer, id: 0x1234, type: 1), [good]);
      expect(decodeDnsAnswer(answer, id: 0x1235, type: 1), isEmpty);
      expect(
        decodeDnsAnswer(answer.sublist(0, 20), id: 0x1234, type: 1),
        isEmpty,
      );
      expect(
        decodeDnsAnswer(List<int>.filled(5000, 0), id: 0, type: 1),
        isEmpty,
      );
      expect(looksPoisoned(InternetAddress('0.0.0.0')), isTrue);
      expect(looksPoisoned(InternetAddress('127.0.0.1')), isTrue);
      expect(looksPoisoned(good), isFalse);
    });
  });

  group('sealed LAN beacons', () {
    final beacon = {
      'app': 'conest',
      'kind': 'pairing_route',
      'deviceId': 'dev-a',
      'relayPort': 7667,
    };

    test('they carry no tell, vary in size, and open to the message', () async {
      final sizes = <int>{};
      for (var i = 0; i < 20; i++) {
        final sealed = await LanBeaconCodec.seal(beacon);
        sizes.add(sealed.length);
        final text = latin1.decode(sealed);
        expect(text.contains('conest'), isFalse);
        expect(text.contains('deviceId'), isFalse);
        expect(sealed[0], isNot(0x7b));
        expect(await LanBeaconCodec.open(sealed), beacon);
      }
      expect(sizes.length, greaterThan(5));
    });

    test('damaged, foreign and oversized datagrams do not open', () async {
      final sealed = await LanBeaconCodec.seal(beacon);
      final damaged = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
      expect(await LanBeaconCodec.open(damaged), isNull);
      expect(
        await LanBeaconCodec.open(utf8.encode('{"app":"conest"}')),
        isNull,
      );
      expect(await LanBeaconCodec.open(const []), isNull);
      expect(
        await LanBeaconCodec.open(
          Uint8List(LanBeaconCodec.maxDatagramBytes + 1),
        ),
        isNull,
      );
    });

    test('quiet discovery follows the network like the other measures', () {
      final circumvention = Circumvention(
        resolver: DohResolver(endpoints: const []),
      );
      expect(circumvention.quietLanActive, isFalse);
      circumvention.update(blockedHere: true);
      expect(circumvention.quietLanActive, isTrue);
      circumvention.update(
        preferences: const CircumventionPreferences(
          quietLan: CircumventionPolicy.never,
        ),
      );
      expect(circumvention.quietLanActive, isFalse);
      final back = CircumventionPreferences.fromJson(
        jsonDecode(
          jsonEncode(
            const CircumventionPreferences(
              quietLan: CircumventionPolicy.always,
            ).toJson(),
          ),
        ),
      );
      expect(back.quietLan, CircumventionPolicy.always);
    });
  });

  group('when circumvention is on', () {
    test('automatic follows the network; always and off do not', () {
      final circumvention = Circumvention(
        resolver: DohResolver(endpoints: const []),
      );
      expect(circumvention.anyActive, isFalse, reason: 'off where all works');
      circumvention.update(blockedHere: true);
      expect(circumvention.privateDnsActive, isTrue);
      expect(circumvention.splitGreetingActive, isTrue);
      circumvention.update(
        preferences: const CircumventionPreferences(
          privateDns: CircumventionPolicy.never,
          splitGreeting: CircumventionPolicy.automatic,
        ),
      );
      expect(circumvention.privateDnsActive, isFalse);
      expect(circumvention.splitGreetingActive, isTrue);
      circumvention.update(
        blockedHere: false,
        preferences: const CircumventionPreferences(
          splitGreeting: CircumventionPolicy.always,
        ),
      );
      expect(circumvention.privateDnsActive, isFalse);
      expect(circumvention.splitGreetingActive, isTrue);
    });

    test('the choices are kept with the connectivity settings', () {
      const preferences = GlobalConnectivityPreferences(
        circumvention: CircumventionPreferences(
          privateDns: CircumventionPolicy.always,
          splitGreeting: CircumventionPolicy.never,
        ),
      );
      final back = GlobalConnectivityPreferences.fromJson(
        jsonDecode(jsonEncode(preferences.toJson())) as Map<String, dynamic>,
      );
      expect(back.circumvention, preferences.circumvention);
      // Old settings (no field) read as automatic.
      expect(
        GlobalConnectivityPreferences.fromJson(
          const {},
        ).circumvention.isDefault,
        isTrue,
      );
      expect(
        const GlobalConnectivityPreferences().toJson().containsKey(
          'circumvention',
        ),
        isFalse,
      );
    });
  });
}
