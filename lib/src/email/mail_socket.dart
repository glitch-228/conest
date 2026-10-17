import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A byte stream to a mail server; tests substitute an in-memory one.
abstract interface class MailSocket {
  Stream<Uint8List> get input;
  void write(List<int> bytes);
  Future<void> close();
}

/// Opens a connection to [host]:[port], with TLS from the first byte unless
/// [tls] is false (only for servers on this machine, as in tests).
typedef MailConnector =
    Future<MailSocket> Function(String host, int port, {required bool tls});

Future<MailSocket> connectMailSocket(
  String host,
  int port, {
  required bool tls,
  String? alpn,
}) async {
  const timeout = Duration(seconds: 20);
  final Socket socket = tls
      ? await SecureSocket.connect(
          host,
          port,
          timeout: timeout,
          supportedProtocols: alpn == null ? null : [alpn],
        )
      : await Socket.connect(host, port, timeout: timeout);
  return _IoMailSocket(socket);
}

/// Chatmail servers also take IMAP and SMTP on port 443, told apart by
/// ALPN, for networks that block the mail ports (seen on the device lab:
/// a phone and a PC that could not reach port 465 at all).
MailConnector chatmailFallback({
  MailConnector direct = connectMailSocket,
  Future<MailSocket> Function(String host, String alpn) viaHttpsPort =
      _connectViaHttpsPort,
}) {
  // Servers this run reached only on 443: tried there first next time, not
  // after the blocked port's whole timeout.
  final viaHttps = <String>{};
  return (String host, int port, {required bool tls}) async {
    final alpn = switch (port) {
      993 => 'imap',
      465 => 'smtp',
      _ => null,
    };
    if (!tls || alpn == null) return direct(host, port, tls: tls);
    if (viaHttps.contains(host)) {
      try {
        return await viaHttpsPort(host, alpn);
      } catch (_) {
        viaHttps.remove(host);
      }
    }
    try {
      return await direct(host, port, tls: tls);
    } catch (error) {
      try {
        final socket = await viaHttpsPort(host, alpn);
        viaHttps.add(host);
        return socket;
      } catch (_) {
        // The mail port's error says more than 443's.
        Error.throwWithStackTrace(error, StackTrace.current);
      }
    }
  };
}

Future<MailSocket> _connectViaHttpsPort(String host, String alpn) =>
    connectMailSocket(host, 443, tls: true, alpn: alpn);

class _IoMailSocket implements MailSocket {
  _IoMailSocket(this._socket) {
    // A write to a connection the server dropped fails here; the reader
    // sees the drop and the caller reconnects.
    _socket.done.catchError((Object _) {});
  }

  final Socket _socket;

  @override
  Stream<Uint8List> get input => _socket;

  @override
  void write(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
    _socket.destroy();
  }
}

/// Reads CRLF-terminated lines and counted byte blocks from a [MailSocket].
class MailLineReader {
  MailLineReader(
    Stream<Uint8List> input, {
    this.maxBufferedBytes = 64 * 1024 * 1024,
    this.maxBufferedChunks = 4096,
  }) {
    _subscription = input.listen(
      (chunk) {
        if (chunk.isEmpty) return;
        if (_chunks.length >= maxBufferedChunks ||
            chunk.length > maxBufferedBytes - _queuedBytes - _pending.length) {
          _error = const FormatException('Mail server input buffer exceeded.');
          _chunks.clear();
          _queuedBytes = 0;
          _pending = Uint8List(0);
          unawaited(_subscription.cancel());
          _wake();
          return;
        }
        _chunks.add(chunk);
        _queuedBytes += chunk.length;
        _wake();
      },
      onError: (Object error) {
        _error = error;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  /// Longest line accepted; a server sending more is cut off.
  static const int maxLineBytes = 256 * 1024;
  final int maxBufferedBytes;
  final int maxBufferedChunks;

  late final StreamSubscription<Uint8List> _subscription;
  final List<Uint8List> _chunks = [];
  var _queuedBytes = 0;
  Uint8List _pending = Uint8List(0);
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;
  bool _interrupted = false;

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  /// Ends the current wait with a [TimeoutException], keeping buffered data.
  void interrupt() {
    _interrupted = true;
    _wake();
  }

  /// Moves received chunks into [_pending] (one copy per call).
  void _absorb() {
    if (_chunks.isEmpty) return;
    final builder = BytesBuilder(copy: false)..add(_pending);
    for (final chunk in _chunks) {
      builder.add(chunk);
    }
    _chunks.clear();
    _queuedBytes = 0;
    _pending = builder.takeBytes();
  }

  Future<void> _waitForData(Duration timeout) async {
    if (_chunks.isNotEmpty) return;
    if (_error != null) throw _error!;
    if (_done) {
      throw const SocketException('Mail server closed the connection.');
    }
    final waiter = _waiter = Completer<void>();
    await waiter.future.timeout(timeout);
    if (_interrupted) {
      _interrupted = false;
      throw TimeoutException('Interrupted.');
    }
    if (_chunks.isEmpty) {
      if (_error != null) throw _error!;
      if (_done) {
        throw const SocketException('Mail server closed the connection.');
      }
    }
  }

  /// The next line without its CRLF, decoded as Latin-1.
  Future<String> readLine({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    var scanned = 0;
    while (true) {
      _absorb();
      final end = _indexOfCrlf(max(0, scanned - 1));
      if (end >= 0) {
        if (end > maxLineBytes) {
          throw const FormatException('Mail server line is too long.');
        }
        final line = latin1.decode(Uint8List.sublistView(_pending, 0, end));
        _pending = Uint8List.sublistView(_pending, end + 2);
        return line;
      }
      scanned = _pending.length;
      if (_pending.length > maxLineBytes) {
        throw const FormatException('Mail server line is too long.');
      }
      await _waitForData(timeout);
    }
  }

  /// The next [count] bytes.
  Future<Uint8List> readBytes(
    int count, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    // Collect without re-copying what is already gathered.
    final out = BytesBuilder(copy: false);
    var have = 0;
    while (true) {
      _absorb();
      final take = min(count - have, _pending.length);
      if (take > 0) {
        out.add(Uint8List.fromList(Uint8List.sublistView(_pending, 0, take)));
        _pending = Uint8List.sublistView(_pending, take);
        have += take;
      }
      if (have == count) return out.takeBytes();
      await _waitForData(timeout);
    }
  }

  int _indexOfCrlf(int from) {
    for (var index = from; index + 1 < _pending.length; index++) {
      if (_pending[index] == 13 && _pending[index + 1] == 10) return index;
    }
    return -1;
  }

  Future<void> cancel() => _subscription.cancel();
}
