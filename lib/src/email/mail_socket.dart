import 'dart:async';
import '../circumvention/circumvention.dart';
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
  // The whole connection, TLS handshake included: connect's own timeout
  // covers only reaching the port, and a network that lets the connection
  // open but stalls the handshake left the phone's account setup hanging.
  if (!tls) {
    return _IoMailSocket(
      await Circumvention.instance.connect(host, port, timeout: timeout),
    );
  }
  final connecting = Circumvention.instance.secureConnect(
    host,
    port,
    timeout: timeout,
    supportedProtocols: alpn == null ? null : [alpn],
  );
  try {
    return _IoMailSocket(
      await connecting.timeout(timeout + const Duration(seconds: 10)),
    );
  } on TimeoutException {
    // A handshake that finishes after all is closed, not left open.
    unawaited(connecting.then((late) => late.destroy(), onError: (_) {}));
    rethrow;
  }
}

/// Chatmail servers also take IMAP and SMTP on port 443, told apart by
/// ALPN, for networks that block the mail ports (seen on the device lab:
/// a phone and a PC that could not reach port 465 at all).
MailConnector chatmailFallback({
  MailConnector direct = connectMailSocket,
  Future<MailSocket> Function(String host, String alpn) viaHttpsPort =
      connectViaHttpsPort,
  Duration greetingWait = const Duration(seconds: 15),
  void Function(String line)? log,
  Set<String>? viaHttps,
}) {
  // Servers reached only on 443: tried there first next time, not after the
  // blocked port's whole timeout. The app shares one set (see
  // [chatmailReachedViaHttps]); tests keep their own.
  final reached = viaHttps ?? <String>{};
  return (String host, int port, {required bool tls}) async {
    final alpn = switch (port) {
      993 => 'imap',
      465 => 'smtp',
      _ => null,
    };
    if (!tls || alpn == null) return direct(host, port, tls: tls);
    final watch = Stopwatch()..start();
    String took() =>
        '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
    if (reached.contains(host)) {
      try {
        return await viaHttpsPort(host, alpn);
      } catch (error) {
        log?.call('$host:443 ($alpn) failed after ${took()}: $error');
        reached.remove(host);
        watch.reset();
      }
    }
    try {
      // The server speaks first (IMAP and SMTP): a port that connects but
      // stays silent is blocked too, and its silence is not waited out.
      return await _speaking(await direct(host, port, tls: tls), greetingWait);
    } catch (error) {
      log?.call(
        '$host:$port failed after ${took()}: $error; trying port 443 ($alpn)',
      );
      watch.reset();
      try {
        final socket = await viaHttpsPort(host, alpn);
        log?.call('$host reached over port 443 ($alpn) in ${took()}');
        reached.add(host);
        return socket;
      } catch (httpsError) {
        log?.call('$host:443 ($alpn) failed after ${took()}: $httpsError');
        // The mail port's error says more than 443's.
        Error.throwWithStackTrace(error, StackTrace.current);
      }
    }
  };
}

/// [socket] once its first bytes came within [wait] (handed on to the
/// reader unchanged); closed, and a timeout, otherwise.
Future<MailSocket> _speaking(MailSocket socket, Duration wait) async {
  final first = Completer<Uint8List>();
  final rest = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> subscription;
  subscription = socket.input.listen(
    (chunk) {
      if (!first.isCompleted) {
        first.complete(chunk);
      } else {
        rest.add(chunk);
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!first.isCompleted) {
        first.completeError(error, stack);
      } else {
        rest.addError(error, stack);
      }
    },
    onDone: () {
      if (!first.isCompleted) {
        first.completeError(const SocketException('closed before speaking'));
      }
      rest.close();
    },
  );
  try {
    final chunk = await first.future.timeout(wait);
    return _Replayed(socket, chunk, rest.stream, subscription);
  } catch (_) {
    await subscription.cancel();
    await socket.close();
    rethrow;
  }
}

class _Replayed implements MailSocket {
  _Replayed(this._socket, Uint8List first, Stream<Uint8List> rest, this._sub)
    : input = _prepend(first, rest);

  final MailSocket _socket;
  final StreamSubscription<Uint8List> _sub;

  @override
  final Stream<Uint8List> input;

  static Stream<Uint8List> _prepend(
    Uint8List first,
    Stream<Uint8List> rest,
  ) async* {
    yield first;
    yield* rest;
  }

  @override
  void write(List<int> bytes) => _socket.write(bytes);

  @override
  Future<void> close() async {
    await _sub.cancel().timeout(_closeWait, onTimeout: () {});
    await _socket.close();
  }
}

/// How long a close waits for the connection to end politely before it is
/// cut (a frozen link never lets a close finish).
const _closeWait = Duration(seconds: 2);

/// IMAP or SMTP ([alpn]) on [host]'s port 443, as chatmail servers offer.
Future<MailSocket> connectViaHttpsPort(String host, String alpn) =>
    connectMailSocket(host, 443, tls: true, alpn: alpn);

/// Chatmail servers that answered first on port 443 here (the mail ports
/// were blocked, stalled or just slower): sign-up, reading and sending go
/// there first. One that then fails on 443 is dropped from the set and the
/// mail port is tried again.
final Set<String> chatmailReachedViaHttps = <String>{};

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
      await _socket.close().timeout(_closeWait);
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
    this.lineTimeout = const Duration(seconds: 60),
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

  /// How long [readLine] waits for a line, unless told otherwise.
  final Duration lineTimeout;

  /// The next line without its CRLF, decoded as Latin-1.
  Future<String> readLine({Duration? timeout}) async {
    final wait = timeout ?? lineTimeout;
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
      await _waitForData(wait);
    }
  }

  /// The next [count] bytes.
  Future<Uint8List> readBytes(int count, {Duration? timeout}) async {
    // Like a line: how long to wait for more of it, not for all of it.
    final wait = timeout ?? lineTimeout;
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
      await _waitForData(wait);
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
