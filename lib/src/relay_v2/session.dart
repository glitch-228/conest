import 'dart:async';
import '../circumvention/circumvention.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'frames.dart';
import 'noise_nk.dart';

/// A connected byte stream a session runs over (plain TCP to port 7667,
/// or the outer layer: TLS and a WebSocket).
abstract class RelayByteChannel {
  Stream<List<int>> get input;
  void add(List<int> bytes);
  Future<void> flush();
  Future<void> close();
  void destroy();
}

class SocketRelayChannel implements RelayByteChannel {
  SocketRelayChannel(this.socket);

  final Socket socket;

  static Future<SocketRelayChannel> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final socket = await Circumvention.instance
        .connect(host, port, timeout: timeout)
        .timeout(timeout);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // Not every socket takes it; the session works without.
    }
    return SocketRelayChannel(socket);
  }

  @override
  Stream<List<int>> get input => socket;

  @override
  void add(List<int> bytes) => socket.add(bytes);

  @override
  Future<void> flush() => socket.flush();

  @override
  Future<void> close() async {
    try {
      await socket.close();
    } on Object {
      // Closing a broken socket.
    }
    socket.destroy();
  }

  @override
  void destroy() => socket.destroy();
}

/// The session could not be used (not connected, backing off, or full):
/// the caller may use v1 instead.
class RelayV2Unavailable implements Exception {
  const RelayV2Unavailable(this.message);

  final String message;

  @override
  String toString() => 'RelayV2Unavailable: $message';
}

/// Buffers a byte stream and hands it out by exact counts (a session's
/// records, on either side).
class RelayInputReader {
  RelayInputReader(Stream<List<int>> input) {
    _subscription = input.listen(
      _onData,
      onError: (Object error) {
        _error ??= error;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  static const int _pauseAbove = 4 * 1024 * 1024;
  static const int _resumeBelow = 1024 * 1024;

  final RelayByteQueue _queue = RelayByteQueue();
  late final StreamSubscription<List<int>> _subscription;
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;
  bool _paused = false;

  void _onData(List<int> chunk) {
    _queue.add(chunk);
    if (!_paused && _queue.length > _pauseAbove) {
      _paused = true;
      _subscription.pause();
    }
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<Uint8List> readExact(int count) async {
    while (_queue.length < count) {
      final error = _error;
      if (error != null) throw error;
      if (_done) throw const SocketException('Relay session closed.');
      if (_paused) {
        _paused = false;
        _subscription.resume();
      }
      final waiter = Completer<void>();
      _waiter = waiter;
      await waiter.future;
    }
    final out = _queue.take(count);
    if (_paused && _queue.length < _resumeBelow) {
      _paused = false;
      _subscription.resume();
    }
    return out;
  }

  Future<void> cancel() async {
    _done = true;
    _wake();
    await _subscription.cancel();
  }
}

/// One v2 session to a relay: many requests in flight on one encrypted
/// connection, and subscriptions that push envelopes as they arrive.
class RelayV2Session {
  RelayV2Session._(
    this._channel,
    this._reader,
    this._transport,
    this.hello,
    this._keepalive,
  ) : maxStreams = _intFrom(hello['max_streams'], 32).clamp(1, 256);

  /// The largest frame this client takes (a fetch of 128 envelopes fits).
  static const int maxFramePayload = 41 * 1024 * 1024;

  /// What any other frame (an answer nobody asked big, a pong, a stray
  /// stream) may carry.
  static const int smallFramePayload = 1024 * 1024;

  final RelayByteChannel _channel;
  final RelayInputReader _reader;
  final NoiseNkTransport _transport;

  /// What the relay said in its handshake reply.
  final Map<String, dynamic> hello;

  /// Requests and subscriptions the relay lets one session have at once.
  final int maxStreams;

  /// Mailboxes whose owner proved itself on this session.
  final Set<String> provedMailboxes = <String>{};
  final Duration _keepalive;
  late final RelayV2FrameDecoder _decoder = RelayV2FrameDecoder(
    maxFramePayload,
    limitFor: (type, stream) {
      // Checked on the header, before the payload is buffered: an answer
      // may be as big as its request allowed, events as big as a fetch,
      // everything else is small.
      if (type == RelayV2FrameType.response) {
        final limit = _limits[stream];
        return limit == null ? smallFramePayload : limit + 4096;
      }
      if (type == RelayV2FrameType.event &&
          _subscriptions.containsKey(stream)) {
        return null;
      }
      return smallFramePayload;
    },
  );
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, int> _limits = {};
  final Map<int, StreamController<Map<String, dynamic>>> _subscriptions = {};
  final Completer<void> _done = Completer<void>();
  Future<void> _writing = Future<void>.value();
  Timer? _keepaliveTimer;
  DateTime? _pingSentAt;
  int _nextStream = 1;
  bool _closed = false;

  Uint8List get handshakeHash => _transport.handshakeHash;
  bool get isClosed => _closed;
  Future<void> get done => _done.future;

  static int _intFrom(Object? value, int fallback) =>
      value is int ? value : fallback;

  /// Runs the handshake over [channel] against [relayNoiseKey] (checked by
  /// the caller against the relay's pinned identity). Fails when the relay
  /// does not hold that key.
  static Future<RelayV2Session> connect({
    required RelayByteChannel channel,
    required List<int> relayNoiseKey,
    Duration timeout = const Duration(seconds: 8),
    Duration keepalive = const Duration(seconds: 30),
  }) async {
    final reader = RelayInputReader(channel.input);
    try {
      final initiator = await NoiseNkInitiator.start(
        relayStaticPublic: relayNoiseKey,
      );
      final message1 = await initiator.writeMessage1(utf8.encode('{"v":1}'));
      channel.add([
        ...relayV2Magic,
        relayV2Version,
        message1.length >> 8,
        message1.length & 0xff,
        ...message1,
      ]);
      await channel.flush().timeout(timeout);
      final lengthBytes = await reader.readExact(2).timeout(timeout);
      final length = (lengthBytes[0] << 8) | lengthBytes[1];
      if (length < 48 || length > 2048) {
        throw const FormatException('Relay session reply has a bad length.');
      }
      final message2 = await reader.readExact(length).timeout(timeout);
      final (payload, transport) = await initiator.readMessage2(message2);
      var hello = <String, dynamic>{};
      try {
        final decoded = jsonDecode(utf8.decode(payload));
        if (decoded is Map<String, dynamic>) hello = decoded;
      } on FormatException {
        // An unreadable hello leaves the defaults.
      }
      final session = RelayV2Session._(
        channel,
        reader,
        transport,
        hello,
        keepalive,
      );
      session._start();
      return session;
    } catch (_) {
      unawaited(reader.cancel());
      channel.destroy();
      rethrow;
    }
  }

  void _start() {
    unawaited(_readLoop());
    _keepaliveTimer = Timer.periodic(_keepalive, (_) => _keepaliveTick());
  }

  void _keepaliveTick() {
    if (_closed) return;
    final sent = _pingSentAt;
    if (sent != null) {
      // A whole interval without its pong: the connection is gone.
      _fail(TimeoutException('Relay session stopped answering.'));
      return;
    }
    _pingSentAt = DateTime.now();
    unawaited(
      _send(RelayV2FrameType.ping, 0, const [1]).catchError((Object _) {}),
    );
  }

  Future<void> _readLoop() async {
    try {
      while (!_closed) {
        final header = await _reader.readExact(2);
        final length = (header[0] << 8) | header[1];
        if (length < relayV2Tag) {
          throw const FormatException('Relay record too short.');
        }
        final sealed = await _reader.readExact(length);
        final plain = await _transport.receive.decryptWithAd(const [], sealed);
        _decoder.add(plain);
        for (
          var frame = _decoder.next();
          frame != null;
          frame = _decoder.next()
        ) {
          _dispatch(frame);
        }
      }
    } catch (error) {
      _fail(error);
    }
  }

  Map<String, dynamic>? _json(Uint8List payload) {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void _dispatch(RelayV2Frame frame) {
    switch (frame.type) {
      case RelayV2FrameType.response:
        final limit = _limits.remove(frame.stream);
        final body = _json(frame.payload);
        final pending = _pending.remove(frame.stream);
        if (pending != null && !pending.isCompleted) {
          if (limit != null && frame.payload.length > limit) {
            pending.completeError(
              StateError('Relay response exceeded the allowed size.'),
            );
          } else if (body == null) {
            pending.completeError(
              StateError('Relay returned a malformed (non-JSON) response.'),
            );
          } else {
            pending.complete(body);
          }
        }
        final subscription = _subscriptions.remove(frame.stream);
        if (subscription != null) {
          if (body == null || body['ok'] != true) {
            subscription.addError(
              StateError(
                body?['error'] as String? ?? 'Relay ended the subscription.',
              ),
            );
          }
          unawaited(subscription.close());
        }
      case RelayV2FrameType.event:
        final body = _json(frame.payload);
        final subscription = _subscriptions[frame.stream];
        if (subscription != null && body != null) subscription.add(body);
      case RelayV2FrameType.ping:
        unawaited(
          _send(
            RelayV2FrameType.pong,
            frame.stream,
            frame.payload,
          ).catchError((Object _) {}),
        );
      case RelayV2FrameType.pong:
        _pingSentAt = null;
      case RelayV2FrameType.goaway:
        _fail(const SocketException('Relay closed the session.'));
      default:
      // Padding and anything newer: ignored.
    }
  }

  int _allocateStream() {
    for (var tries = 0; tries < 1 << 16; tries++) {
      final id = _nextStream;
      _nextStream = _nextStream >= 0x7ffffffd ? 1 : _nextStream + 2;
      if (!_pending.containsKey(id) && !_subscriptions.containsKey(id)) {
        return id;
      }
    }
    throw const RelayV2Unavailable('No free session stream.');
  }

  Future<void> _send(int type, int stream, List<int> payload) {
    if (_closed) {
      return Future<void>.error(const SocketException('Relay session closed.'));
    }
    final next = _writing.then((_) async {
      if (_closed) throw const SocketException('Relay session closed.');
      final plain = encodeRelayV2Frame(type, stream, payload);
      final out = BytesBuilder(copy: false);
      for (
        var offset = 0;
        offset < plain.length;
        offset += relayV2MaxRecordPlaintext
      ) {
        final end = min(offset + relayV2MaxRecordPlaintext, plain.length);
        final sealed = await _transport.send.encryptWithAd(
          const [],
          Uint8List.sublistView(plain, offset, end),
        );
        out
          ..addByte(sealed.length >> 8)
          ..addByte(sealed.length & 0xff)
          ..add(sealed);
      }
      _channel.add(out.takeBytes());
      await _channel.flush();
    });
    _writing = next.catchError((Object error) {
      _fail(error);
    });
    return next;
  }

  /// Sends a v1-style request ([body] has its `action`) and waits for the
  /// answer, at most [timeout]. The answer is returned as is (`ok` false
  /// included).
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 8),
    int maxResponseBytes = maxFramePayload,
  }) async {
    if (_closed) throw const SocketException('Relay session closed.');
    if (_pending.length + _subscriptions.length >= maxStreams) {
      throw const RelayV2Unavailable('Relay session is full.');
    }
    final id = _allocateStream();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _limits[id] = maxResponseBytes;
    try {
      await _send(
        RelayV2FrameType.request,
        id,
        utf8.encode(jsonEncode(body)),
      ).timeout(timeout);
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      if (_pending.remove(id) != null && !_closed) {
        unawaited(
          _send(
            RelayV2FrameType.cancel,
            id,
            const [],
          ).catchError((Object _) {}),
        );
      }
      rethrow;
    } finally {
      _pending.remove(id);
      _limits.remove(id);
    }
  }

  /// Opens a subscription stream ([body] is the `subscribe` request): its
  /// events, until the relay ends it, the session ends (an error), or the
  /// listener cancels (which tells the relay).
  Stream<Map<String, dynamic>> subscribe(Map<String, dynamic> body) {
    late final StreamController<Map<String, dynamic>> controller;
    var id = 0;
    controller = StreamController<Map<String, dynamic>>(
      onListen: () {
        if (_closed) {
          controller
            ..addError(const SocketException('Relay session closed.'))
            ..close();
          return;
        }
        if (_pending.length + _subscriptions.length >= maxStreams) {
          controller
            ..addError(const RelayV2Unavailable('Relay session is full.'))
            ..close();
          return;
        }
        id = _allocateStream();
        _subscriptions[id] = controller;
        _send(
          RelayV2FrameType.request,
          id,
          utf8.encode(jsonEncode(body)),
        ).catchError((Object error) {
          if (_subscriptions.remove(id) != null) {
            controller
              ..addError(error)
              ..close();
          }
        });
      },
      onCancel: () {
        if (id != 0 && _subscriptions.remove(id) != null && !_closed) {
          unawaited(
            _send(
              RelayV2FrameType.cancel,
              id,
              const [],
            ).catchError((Object _) {}),
          );
        }
      },
    );
    return controller.stream;
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _keepaliveTimer?.cancel();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    _limits.clear();
    for (final subscription in _subscriptions.values) {
      subscription.addError(error);
      unawaited(subscription.close());
    }
    _subscriptions.clear();
    unawaited(_reader.cancel());
    _channel.destroy();
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> close() async {
    _fail(const SocketException('Relay session closed.'));
  }
}

/// One session per relay, shared by every request to it; after a failed
/// connect, the relay is left alone a while (1 s, doubling to a minute)
/// and callers use v1 meanwhile.
class RelayV2Pool {
  RelayV2Pool({this.maxSessions = 16});

  static final RelayV2Pool shared = RelayV2Pool();

  final int maxSessions;
  final Map<String, Future<RelayV2Session>> _sessions = {};
  final Map<String, ({DateTime until, int failures})> _backoff = {};

  bool inBackoff(String key) {
    final backoff = _backoff[key];
    return backoff != null && DateTime.now().isBefore(backoff.until);
  }

  /// The open session for [key], or a new one from [connect].
  Future<RelayV2Session> session(
    String key,
    Future<RelayV2Session> Function() connect,
  ) async {
    final existing = _sessions[key];
    if (existing != null) {
      try {
        final session = await existing;
        if (!session.isClosed) return session;
      } on Object {
        // Failed or closed: connect again (or back off) below.
      }
      if (identical(_sessions[key], existing)) _sessions.remove(key);
    }
    if (inBackoff(key)) {
      throw const RelayV2Unavailable('Relay session is backing off.');
    }
    if (_sessions.length >= maxSessions) {
      final oldest = _sessions.keys.first;
      final evicted = _sessions.remove(oldest);
      unawaited(
        evicted?.then((session) => session.close(), onError: (Object _) {}),
      );
    }
    final connecting = connect();
    _sessions[key] = connecting;
    try {
      final session = await connecting;
      _backoff.remove(key);
      unawaited(
        session.done.then((_) {
          if (identical(_sessions[key], connecting)) _sessions.remove(key);
        }),
      );
      return session;
    } catch (_) {
      if (identical(_sessions[key], connecting)) _sessions.remove(key);
      final failures = (_backoff[key]?.failures ?? 0) + 1;
      final wait = Duration(seconds: min(60, 1 << min(failures - 1, 6)));
      if (_backoff.length >= 256 && !_backoff.containsKey(key)) {
        _backoff.remove(_backoff.keys.first);
      }
      _backoff[key] = (until: DateTime.now().add(wait), failures: failures);
      rethrow;
    }
  }

  /// Closes every session (tests, and when the app goes offline).
  Future<void> closeAll() async {
    final sessions = _sessions.values.toList();
    _sessions.clear();
    _backoff.clear();
    for (final session in sessions) {
      try {
        await (await session).close();
      } on Object {
        // Already gone.
      }
    }
  }
}
