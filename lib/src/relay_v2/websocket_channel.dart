import 'dart:async';
import '../circumvention/circumvention.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'frames.dart';
import 'session.dart';

/// A relay's hidden address: TLS to [host]:[port] (SNI = [host]), then a
/// WebSocket on the secret [path]; the relay's bytes (a v2 session, or a v1
/// line) travel in binary frames.
class WebSocketRelayChannel implements RelayByteChannel {
  WebSocketRelayChannel._(this._socket);

  final Socket _socket;
  final StreamController<List<int>> _input = StreamController<List<int>>();
  final RelayByteQueue _buffer = RelayByteQueue();
  final Random _random = Random.secure();
  StreamSubscription<List<int>>? _subscription;
  bool _closed = false;

  static const int _maxFrame = 2 * 1024 * 1024;
  static const int _maxHead = 16 * 1024;

  /// Connects and upgrades. The secret path is sent only to a server whose
  /// certificate is a WebPKI one, or is exactly the certificate whose
  /// SHA-256 ([pinnedCertSha256]) the relay's identity signed: whoever
  /// else answers on that address (a poisoned DNS answer, a middlebox)
  /// learns nothing, not even the path.
  static Future<WebSocketRelayChannel> connect({
    required String host,
    required int port,
    required String path,
    List<int>? pinnedCertSha256,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final socket = await Circumvention.instance
        .secureConnect(
          host,
          port,
          timeout: timeout,
          supportedProtocols: const ['http/1.1'],
          onBadCertificate: (certificate) =>
              pinnedCertSha256 != null &&
              _sameBytes(
                crypto.sha256.convert(certificate.der).bytes,
                pinnedCertSha256,
              ),
        )
        .timeout(timeout);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // Not every socket takes it.
    }
    final channel = WebSocketRelayChannel._(socket);
    try {
      await channel._upgrade(host, port, path).timeout(timeout);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
    return channel;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var index = 0; index < a.length; index++) {
      difference |= a[index] ^ b[index];
    }
    return difference == 0;
  }

  Future<void> _upgrade(String host, int port, String path) async {
    final key = base64Encode(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    );
    final hostHeader = port == 443 ? host : '$host:$port';
    _socket.add(
      utf8.encode(
        'GET $path HTTP/1.1\r\n'
        'Host: $hostHeader\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: $key\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        '\r\n',
      ),
    );
    await _socket.flush();
    final head = Completer<String>();
    final pending = BytesBuilder(copy: false);
    _subscription = _socket.listen(
      (chunk) {
        if (!head.isCompleted) {
          pending.add(chunk);
          final bytes = pending.toBytes();
          final end = _headEnd(bytes);
          if (end == null) {
            if (bytes.length > _maxHead) {
              head.completeError(
                const FormatException('Relay upgrade answer too large.'),
              );
            }
            return;
          }
          head.complete(latin1.decode(bytes.sublist(0, end)));
          pending.clear();
          _onData(bytes.sublist(end));
          return;
        }
        _onData(chunk);
      },
      onError: (Object error) {
        if (!head.isCompleted) head.completeError(error);
        _fail(error);
      },
      onDone: () {
        if (!head.isCompleted) {
          head.completeError(
            const SocketException('Relay closed during the upgrade.'),
          );
        }
        _fail(const SocketException('Relay connection closed.'));
      },
      cancelOnError: true,
    );
    final answer = await head.future;
    final lines = answer.split('\r\n');
    if (!lines.first.startsWith('HTTP/1.1 101')) {
      // Not the relay (the decoy, or a wrong path).
      throw const SocketException('Relay address did not upgrade.');
    }
    final expected = base64Encode(
      crypto.sha1
          .convert(utf8.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
          .bytes,
    );
    final accept = lines
        .skip(1)
        .map((line) => line.split(':'))
        .where((parts) => parts.length >= 2)
        .where(
          (parts) => parts.first.trim().toLowerCase() == 'sec-websocket-accept',
        )
        .map((parts) => parts.sublist(1).join(':').trim())
        .firstOrNull;
    if (accept != expected) {
      throw const SocketException('Relay upgrade answer is wrong.');
    }
  }

  static int? _headEnd(Uint8List bytes) {
    for (var index = 0; index + 3 < bytes.length; index++) {
      if (bytes[index] == 13 &&
          bytes[index + 1] == 10 &&
          bytes[index + 2] == 13 &&
          bytes[index + 3] == 10) {
        return index + 4;
      }
    }
    return null;
  }

  void _onData(List<int> chunk) {
    if (_closed) return;
    _buffer.add(chunk);
    while (true) {
      if (_buffer.length < 2) return;
      final first = _buffer.peekByte(0);
      final second = _buffer.peekByte(1);
      if (second & 0x80 != 0) {
        // A server never masks.
        _fail(const FormatException('Relay sent a masked frame.'));
        return;
      }
      var length = second & 0x7f;
      var offset = 2;
      if (length == 126) {
        if (_buffer.length < 4) return;
        length = (_buffer.peekByte(2) << 8) | _buffer.peekByte(3);
        offset = 4;
      } else if (length == 127) {
        if (_buffer.length < 10) return;
        var value = 0;
        for (var index = 2; index < 10; index++) {
          value = (value << 8) | _buffer.peekByte(index);
        }
        length = value;
        offset = 10;
      }
      if (length < 0 || length > _maxFrame) {
        _fail(const FormatException('Relay frame too large.'));
        return;
      }
      if (_buffer.length < offset + length) return;
      _buffer.take(offset);
      final payload = _buffer.take(length);
      switch (first & 0x0f) {
        case 0x0 || 0x1 || 0x2:
          if (payload.isNotEmpty) _input.add(payload);
        case 0x8:
          _fail(const SocketException('Relay closed the connection.'));
          return;
        case 0x9:
          if (payload.length <= 125) _sendFrame(0xa, payload);
        default:
        // Pongs and anything newer.
      }
    }
  }

  void _sendFrame(int opcode, List<int> payload) {
    if (_closed) return;
    final mask = List<int>.generate(4, (_) => _random.nextInt(256));
    final header = BytesBuilder(copy: false)..addByte(0x80 | opcode);
    if (payload.length < 126) {
      header.addByte(0x80 | payload.length);
    } else if (payload.length <= 0xffff) {
      header
        ..addByte(0x80 | 126)
        ..addByte(payload.length >> 8)
        ..addByte(payload.length & 0xff);
    } else {
      header.addByte(0x80 | 127);
      for (var shift = 56; shift >= 0; shift -= 8) {
        header.addByte((payload.length >> shift) & 0xff);
      }
    }
    header.add(mask);
    final masked = Uint8List(payload.length);
    for (var index = 0; index < payload.length; index++) {
      masked[index] = payload[index] ^ mask[index & 3];
    }
    header.add(masked);
    _socket.add(header.takeBytes());
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    if (!_input.isClosed) {
      if (error is! SocketException) _input.addError(error);
      unawaited(_input.close());
    }
    unawaited(_subscription?.cancel());
    _socket.destroy();
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void add(List<int> bytes) {
    for (var offset = 0; offset < bytes.length; offset += 64 * 1024) {
      _sendFrame(
        0x2,
        bytes.sublist(offset, min(offset + 64 * 1024, bytes.length)),
      );
    }
  }

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> close() async {
    if (!_closed) {
      _sendFrame(0x8, const []);
      try {
        await _socket.flush().timeout(const Duration(seconds: 1));
      } on Object {
        // Closing anyway.
      }
    }
    _fail(const SocketException('Relay connection closed.'));
  }

  @override
  void destroy() => _fail(const SocketException('Relay connection closed.'));
}
