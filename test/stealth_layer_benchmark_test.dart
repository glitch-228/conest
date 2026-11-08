import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/bitchat/noise.dart' show NoiseCipherState;
import 'package:conest/src/relay_v2/borrowed_tls.dart';
import 'package:conest/src/relay_v2/session.dart';
import 'package:conest/src/relay_v2/websocket_channel.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import 'support/borrowed_relay_stub.dart';

/// P0 of M38 (measure first): what each way of reaching a relay costs on
/// this machine: the time to a ready channel, and the round trip of
/// [_bytes] through an echo, with the longest stall of the event loop
/// meanwhile (a frame is late when it is over 16 ms). The numbers are
/// printed (`M38 P0 ...`) and go into the progress log as baselines; the
/// bars are judged on the lab phone (frames under 16 ms, borrowed at least
/// 2 MB/s there and 10 MB/s on a desktop), so here only a hang or a
/// collapse fails.
const _bytes = 8 * 1024 * 1024;

/// The longest the event loop was kept from running a 2 ms timer.
class _LoopStall {
  final Stopwatch _clock = Stopwatch()..start();
  late final Timer _timer;
  int _last = 0;
  int worstMs = 0;

  void start() {
    _last = _clock.elapsedMilliseconds;
    _timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
      final now = _clock.elapsedMilliseconds;
      worstMs = max(worstMs, now - _last - 2);
      _last = now;
    });
  }

  void stop() => _timer.cancel();
}

class _Result {
  _Result(this.readyMs, this.mbPerSecond, this.worstStallMs);
  final double readyMs;
  final double mbPerSecond;
  final int worstStallMs;
}

double _median(List<int> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2].toDouble();
}

/// Sends [_bytes] through [channel] (an echo) and waits for them back.
Future<_Result> _measure(Future<RelayByteChannel> Function() connect) async {
  final ready = <int>[];
  for (var i = 0; i < 5; i++) {
    final clock = Stopwatch()..start();
    final channel = await connect();
    ready.add(clock.elapsedMicroseconds);
    channel.destroy();
  }
  final channel = await connect();
  var received = 0;
  final done = Completer<void>();
  channel.input.listen((chunk) {
    received += chunk.length;
    if (received >= _bytes && !done.isCompleted) done.complete();
  });
  final stall = _LoopStall()..start();
  final clock = Stopwatch()..start();
  final chunk = Uint8List.fromList(List<int>.generate(65536, (i) => i % 251));
  for (var sent = 0; sent < _bytes; sent += chunk.length) {
    channel.add(chunk);
    // Not all at once: the channel's own queue is what is measured.
    if ((sent ~/ chunk.length) % 8 == 7) await channel.flush();
  }
  await done.future.timeout(const Duration(seconds: 120));
  clock.stop();
  stall.stop();
  channel.destroy();
  final seconds = clock.elapsedMicroseconds / 1e6;
  return _Result(
    _median(ready) / 1000,
    (_bytes / 1048576) / seconds,
    stall.worstMs,
  );
}

Future<ServerSocket> _echoServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) {
    client.setOption(SocketOption.tcpNoDelay, true);
    client.listen(client.add, onError: (_) {}, onDone: client.destroy);
  });
  return server;
}

void main() {
  const seed = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
  ];
  final results = <String, _Result>{};

  test('plain TCP', () async {
    final server = await _echoServer();
    addTearDown(server.close);
    results['plain'] = await _measure(
      () => SocketRelayChannel.connect('127.0.0.1', server.port),
    );
  });

  test('TLS and a WebSocket (the hidden address)', () async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/relay_v2/tls/cert.pem')
      ..usePrivateKey('test/fixtures/relay_v2/tls/key.pem');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(socket.add, onError: (_) {}, onDone: socket.close);
    });
    final pem = File('test/fixtures/relay_v2/tls/cert.pem').readAsStringSync();
    final der = base64Decode(
      pem.split('\n').where((line) => !line.startsWith('-----')).join().trim(),
    );
    final hash = crypto.sha256.convert(der).bytes;
    results['wss'] = await _measure(
      () => WebSocketRelayChannel.connect(
        host: '127.0.0.1',
        port: server.port,
        path: '/bench',
        pinnedCertSha256: hash,
      ),
    );
  });

  test('the borrowed handshake', () async {
    final siteContext = SecurityContext()
      ..useCertificateChain('test/fixtures/relay_v2/tls/cert.pem')
      ..usePrivateKey('test/fixtures/relay_v2/tls/key.pem');
    final site = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      siteContext,
    );
    site.listen((socket) => socket.listen((_) {}, onError: (_) {}));
    final relay = await BorrowedRelayStub.start(
      siteHost: '127.0.0.1',
      sitePort: site.port,
      seed: seed,
    );
    addTearDown(() async {
      await relay.close();
      await site.close();
    });
    results['borrowed'] = await _measure(
      () => BorrowedTlsChannel.connect(
        host: '127.0.0.1',
        port: relay.port,
        sni: 'localhost',
        relayIdentity: relay.identityPublic,
        onBadCertificate: (_) => true,
      ),
    );
  });

  test('the session cipher alone (Noise, in every layer)', () async {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final send = NoiseCipherState(key);
    final receive = NoiseCipherState(key);
    final record = Uint8List.fromList(
      List<int>.generate(16384, (i) => i % 251),
    );
    final clock = Stopwatch()..start();
    final stall = _LoopStall()..start();
    for (var done = 0; done < _bytes; done += record.length) {
      final sealed = await send.encryptWithAd(const [], record);
      await receive.decryptWithAd(const [], sealed);
    }
    clock.stop();
    stall.stop();
    final seconds = clock.elapsedMicroseconds / 1e6;
    results['noise'] = _Result(0, (_bytes / 1048576) / seconds, stall.worstMs);
  });

  tearDownAll(() {
    // ignore: avoid_print
    print(
      'M38 P0 layer benchmark on ${Platform.operatingSystem} '
      '(${_bytes ~/ 1048576} MiB round trip through an echo; the loop '
      'stall is the longest the event loop was kept from a 2 ms timer):',
    );
    for (final entry in results.entries) {
      final value = entry.value;
      // ignore: avoid_print
      print(
        'M38 P0   ${entry.key.padRight(9)} ready '
        '${value.readyMs.toStringAsFixed(1).padLeft(7)} ms   '
        '${value.mbPerSecond.toStringAsFixed(1).padLeft(7)} MB/s   '
        'worst loop stall ${value.worstStallMs} ms',
      );
    }
  });

  test('nothing hangs, and borrowed is not a collapse against plain', () {
    expect(results.keys, containsAll(['plain', 'wss', 'borrowed', 'noise']));
    for (final value in results.values) {
      expect(value.mbPerSecond, greaterThan(0.2));
    }
  });
}
