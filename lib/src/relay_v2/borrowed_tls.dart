import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../circumvention/circumvention.dart';
import 'session.dart';

/// The client of the borrowed handshake (M38-D); the format is described
/// in `native/conest_relay/src/borrowed.rs`. The app's TLS library does a
/// real handshake with the real site (SNI = [sni]) through a loopback tap
/// that forwards the records to the relay, which forwards them to the site.
/// Right after the client's Finished the tap adds one application-data
/// record only the relay recognises, then cuts the TLS library off and
/// carries the relay's bytes in padded, boxed records.
class BorrowedTlsChannel implements RelayByteChannel {
  BorrowedTlsChannel._();

  static final _x25519 = X25519();
  static final _sha256 = Sha256();
  static final _hmac = Hmac.sha256();
  static final _aead = Chacha20.poly1305Aead();
  static final _random = Random.secure();
  static final List<int> _label = utf8.encode('conest-borrowed-v1');

  static const int _header = 5;
  static const int _maxPayload = 16384 + 256;
  static const int _maxData = 8 * 1024;
  static const int _tag = 16;

  // Pausing the reader pauses the socket: nothing piles up in memory.
  late final StreamController<List<int>> _input = StreamController<List<int>>(
    onPause: () => _remoteSubscription?.pause(),
    onResume: () => _remoteSubscription?.resume(),
  );
  StreamSubscription<List<int>>? _remoteSubscription;
  Socket? _remote;
  bool _closed = false;
  late List<int> _sendKey;
  int _sendCounter = 0;
  Future<void> _sending = Future<void>.value();

  /// The X25519 form of an Ed25519 public key (the relay's identity).
  static Uint8List montgomeryFromEd25519(List<int> edPublic) {
    if (edPublic.length != 32) {
      throw ArgumentError('An Ed25519 public key is 32 bytes.');
    }
    final p = (BigInt.one << 255) - BigInt.from(19);
    var y = BigInt.zero;
    for (var index = 31; index >= 0; index--) {
      y = (y << 8) | BigInt.from(edPublic[index]);
    }
    y &= (BigInt.one << 255) - BigInt.one;
    final denominator = (BigInt.one - y) % p;
    if (denominator == BigInt.zero) {
      throw ArgumentError('Not a usable identity key.');
    }
    var u = ((BigInt.one + y) % p * denominator.modPow(p - BigInt.two, p)) % p;
    final out = Uint8List(32);
    for (var index = 0; index < 32; index++) {
      out[index] = (u & BigInt.from(0xff)).toInt();
      u >>= 8;
    }
    return out;
  }

  static Future<Uint8List> _mac(List<int> key, List<List<int>> parts) async =>
      Uint8List.fromList(
        (await _hmac.calculateMac([
          for (final part in parts) ...part,
        ], secretKey: SecretKey(key))).bytes,
      );

  static List<int> _record(int kind, List<int> payload) => [
    kind,
    3,
    3,
    payload.length >> 8,
    payload.length & 0xff,
    ...payload,
  ];

  static Uint8List _nonce(int counter) {
    final nonce = Uint8List(12);
    ByteData.view(nonce.buffer).setUint64(4, counter);
    return nonce;
  }

  /// The random of a ServerHello in a handshake [record].
  static List<int>? _serverHelloRandom(List<int> record) {
    if (record.length < _header + 38 || record[0] != 0x16) return null;
    if (record[_header] != 2 ||
        record[_header + 4] != 3 ||
        record[_header + 5] != 3) {
      return null;
    }
    final random = record.sublist(_header + 6, _header + 38);
    // A HelloRetryRequest's fixed random is not the session's.
    if (random[0] == 0xCF && random[1] == 0x21 && random[2] == 0xAD) {
      return null;
    }
    return random;
  }

  /// Connects: [host]:[port] is the relay, [sni] the real site it plays,
  /// [relayIdentity] the relay's pinned Ed25519 identity key.
  static Future<BorrowedTlsChannel> connect({
    required String host,
    required int port,
    required String sni,
    required List<int> relayIdentity,
    Duration timeout = const Duration(seconds: 10),
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
  }) async {
    final relayPublic = montgomeryFromEd25519(relayIdentity);
    final channel = BorrowedTlsChannel._();
    final tap = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final ready = Completer<void>();
    SecureSocket? tls;
    Socket? local;
    final plainPort = Completer<int>();
    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
    }

    try {
      final remote = await Circumvention.instance
          .connect(host, port, timeout: timeout)
          .timeout(timeout);
      try {
        remote.setOption(SocketOption.tcpNoDelay, true);
      } on Object {
        // Not every socket takes it.
      }
      channel._remote = remote;
      unawaited(
        tap.first.then((accepted) async {
          // Only our own dial: another process on this machine that raced
          // the loopback port is turned away.
          if (accepted.remotePort != await plainPort.future) {
            accepted.destroy();
            fail(const SocketException('Unexpected loopback connection.'));
            return;
          }
          local = accepted;
          unawaited(
            channel
                ._pump(accepted, remote, relayPublic, ready)
                .catchError(fail),
          );
        }, onError: fail),
      );
      final plain = await Socket.connect(
        InternetAddress.loopbackIPv4,
        tap.port,
        timeout: timeout,
      );
      plainPort.complete(plain.port);
      // The handshake is the TLS library's own; an unusable certificate
      // stops it here, before the marker is ever sent.
      final secure = SecureSocket.secure(
        plain,
        host: sni,
        context: context,
        supportedProtocols: const ['h2', 'http/1.1'],
        onBadCertificate: onBadCertificate,
      );
      unawaited(
        secure.then((socket) {
          tls = socket;
          socket.listen((_) {}, onError: (_) {}, cancelOnError: true);
        }, onError: fail),
      );
      await ready.future.timeout(timeout);
      return channel;
    } catch (_) {
      channel.destroy();
      rethrow;
    } finally {
      await tap.close();
      unawaited(
        Future<void>(() {
          tls?.destroy();
          local?.destroy();
        }),
      );
    }
  }

  /// Forwards records between the TLS library ([local]) and the relay
  /// ([remote]) until the client's Finished, adds the marker, then carries
  /// the tunnel. Completes [ready] when the relay's acknowledgement holds.
  Future<void> _pump(
    Socket local,
    Socket remote,
    List<int> relayPublic,
    Completer<void> ready,
  ) async {
    var serverRandom = <int>[];
    var cut = false;
    var sawChangeCipherSpec = false;
    var clientRecords = 0;
    final fromLocal = BytesBuilder(copy: false);
    final fromRemote = BytesBuilder(copy: false);
    List<int>? key;
    List<int>? receiveKey;
    List<int> expectedAck = const [];
    var receiveCounter = 0;
    var skipped = 0;
    var inTunnel = false;

    List<List<int>> take(BytesBuilder pending) {
      final out = <List<int>>[];
      var bytes = pending.takeBytes();
      while (bytes.length >= _header) {
        final length = (bytes[3] << 8) | bytes[4];
        if (length > _maxPayload) {
          throw const FormatException('Not a TLS record.');
        }
        if (bytes.length < _header + length) break;
        out.add(bytes.sublist(0, _header + length));
        bytes = bytes.sublist(_header + length);
      }
      if (bytes.isNotEmpty) pending.add(bytes);
      return out;
    }

    Future<void> sendMarker() async {
      final pair = await _x25519.newKeyPair();
      final ephemeral = (await pair.extractPublicKey()).bytes;
      final shared = await (await _x25519.sharedSecretKey(
        keyPair: pair,
        remotePublicKey: SimplePublicKey(relayPublic, type: KeyPairType.x25519),
      )).extractBytes();
      final exchange = (await _sha256.hash([
        ..._label,
        ...shared,
        ...ephemeral,
        ...relayPublic,
      ])).bytes;
      final tag = (await _mac(exchange, [
        utf8.encode('client'),
        serverRandom,
      ])).sublist(0, _tag);
      expectedAck = (await _mac(exchange, [
        utf8.encode('ack'),
        serverRandom,
        tag,
      ])).sublist(0, _tag);
      final send = await _mac(exchange, [
        utf8.encode('tunnel'),
        utf8.encode('c2s'),
        serverRandom,
      ]);
      receiveKey = await _mac(exchange, [
        utf8.encode('tunnel'),
        utf8.encode('s2c'),
        serverRandom,
      ]);
      key = send;
      _sendKey = send;
      final padding = List<int>.generate(
        _random.nextInt(48),
        (_) => _random.nextInt(256),
      );
      remote.add(_record(0x17, [...ephemeral, ...tag, ...padding]));
      await remote.flush();
    }

    final done = Completer<void>();
    var localChain = Future<void>.value();
    local.listen(
      (chunk) => localChain = localChain.then((_) async {
        if (cut) return;
        fromLocal.add(chunk);
        try {
          for (final record in take(fromLocal)) {
            if (cut) return;
            remote.add(record);
            clientRecords++;
            final kind = record[0];
            if (kind == 0x14) sawChangeCipherSpec = true;
            // The client's Finished: the first protected record after the
            // hello (TLS 1.3), or the handshake record after its
            // ChangeCipherSpec (TLS 1.2).
            final finished =
                clientRecords > 1 &&
                (kind == 0x17 || (kind == 0x16 && sawChangeCipherSpec));
            if (finished) {
              cut = true;
              if (serverRandom.isEmpty) {
                throw const FormatException('No ServerHello was seen.');
              }
              await sendMarker();
              break;
            }
          }
        } catch (error) {
          if (!ready.isCompleted) ready.completeError(error);
        }
      }),
      onError: (_) {},
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    // Chunks are handled one after the other (opening a box is async): the
    // end of the stream must not overtake the last records.
    var remoteChain = Future<void>.value();
    _remoteSubscription = remote.listen(
      (chunk) => remoteChain = remoteChain.then((_) async {
        try {
          if (!cut) {
            // Before the cut: the real site's records to the TLS library.
            fromRemote.add(chunk);
            for (final record in take(fromRemote)) {
              if (serverRandom.isEmpty) {
                serverRandom = _serverHelloRandom(record) ?? serverRandom;
              }
              local.add(record);
            }
            return;
          }
          fromRemote.add(chunk);
          for (final record in take(fromRemote)) {
            if (record[0] != 0x17) throw const FormatException('Bad record.');
            final payload = record.sublist(_header);
            if (!inTunnel) {
              // Skip what the real site still sent until the relay's
              // acknowledgement.
              if (key != null &&
                  payload.length >= _tag &&
                  _equal(payload.sublist(0, _tag), expectedAck)) {
                inTunnel = true;
                if (!ready.isCompleted) ready.complete();
              } else if (++skipped > 16) {
                throw const FormatException('The relay did not answer.');
              }
              continue;
            }
            final opened = await _open(receiveKey!, receiveCounter++, payload);
            if (opened == null) {
              throw const FormatException('A tunnel record did not open.');
            }
            if (opened.isNotEmpty && !_input.isClosed) _input.add(opened);
          }
        } catch (error) {
          if (!ready.isCompleted) ready.completeError(error);
          _fail(error);
        }
      }),
      onError: (Object error) {
        if (!ready.isCompleted) ready.completeError(error);
        _fail(error);
      },
      onDone: () => remoteChain = remoteChain.then((_) {
        if (!ready.isCompleted) {
          ready.completeError(const SocketException('Relay closed.'));
        }
        _fail(const SocketException('Relay connection closed.'));
      }),
      cancelOnError: true,
    );
    await done.future.timeout(const Duration(days: 1), onTimeout: () {});
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var index = 0; index < a.length; index++) {
      difference |= a[index] ^ b[index];
    }
    return difference == 0;
  }

  static Future<List<int>?> _open(
    List<int> key,
    int counter,
    List<int> payload,
  ) async {
    if (payload.length < _tag + 2) return null;
    try {
      final framed = await _aead.decrypt(
        SecretBox(
          payload.sublist(0, payload.length - _tag),
          nonce: _nonce(counter),
          mac: Mac(payload.sublist(payload.length - _tag)),
        ),
        secretKey: SecretKey(key),
      );
      final length = (framed[0] << 8) | framed[1];
      if (2 + length > framed.length) return null;
      return framed.sublist(2, 2 + length);
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    if (!_input.isClosed) {
      _input.addError(error);
      unawaited(_input.close());
    }
    _remote?.destroy();
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void add(List<int> bytes) {
    if (_closed) return;
    final data = Uint8List.fromList(bytes);
    _sending = _sending.then((_) async {
      if (_closed) return;
      for (var offset = 0; offset < data.length; offset += _maxData) {
        final chunk = data.sublist(offset, min(offset + _maxData, data.length));
        final pad = _random.nextInt(33);
        final framed = Uint8List(2 + chunk.length + pad)
          ..[0] = chunk.length >> 8
          ..[1] = chunk.length & 0xff
          ..setRange(2, 2 + chunk.length, chunk);
        final box = await _aead.encrypt(
          framed,
          secretKey: SecretKey(_sendKey),
          nonce: _nonce(_sendCounter++),
        );
        _remote?.add(_record(0x17, [...box.cipherText, ...box.mac.bytes]));
      }
    });
  }

  @override
  Future<void> flush() async {
    await _sending;
    await _remote?.flush();
  }

  @override
  Future<void> close() async {
    await flush();
    destroy();
  }

  @override
  void destroy() {
    _closed = true;
    _remote?.destroy();
    if (!_input.isClosed) unawaited(_input.close());
  }
}
