import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'event.dart';

/// A text WebSocket to a relay; tests substitute an in-memory one.
abstract interface class NostrSocket {
  Stream<String> get messages;
  void send(String message);
  Future<void> close();
}

typedef NostrSocketConnector = Future<NostrSocket> Function(Uri url);

/// Opens a real WebSocket.
Future<NostrSocket> connectNostrSocket(Uri url) async => _IoNostrSocket(
  await WebSocket.connect(url.toString()).timeout(const Duration(seconds: 15)),
);

class _IoNostrSocket implements NostrSocket {
  _IoNostrSocket(this._socket) {
    _socket.pingInterval = const Duration(seconds: 30);
  }

  final WebSocket _socket;

  @override
  Stream<String> get messages =>
      _socket.where((message) => message is String).cast<String>();

  @override
  void send(String message) => _socket.add(message);

  @override
  Future<void> close() => _socket.close();
}

enum NostrRelayState { disconnected, connecting, connected }

/// A relay refused an event; [rateLimited] when it asked to slow down.
class NostrRelayException implements Exception {
  const NostrRelayException(this.relay, this.message);

  final String relay;
  final String message;

  bool get rateLimited => message.startsWith('rate-limited');

  @override
  String toString() => '$relay: $message';
}

/// One relay connection: reconnects with backoff, answers NIP-42
/// authentication, keeps an optional subscription and publishes events.
class NostrRelay {
  NostrRelay({
    required this.url,
    required Uint8List Function() authKey,
    NostrSocketConnector? connector,
    this.filter,
    this.onEvent,
    this.onStateChanged,
    Duration publishTimeout = const Duration(seconds: 15),
  }) : _authKey = authKey,
       _connector = connector ?? connectNostrSocket,
       _publishTimeout = publishTimeout;

  final Uri url;
  final Uint8List Function() _authKey;
  final NostrSocketConnector _connector;
  final Duration _publishTimeout;

  /// The subscription filter, read on every (re)connect so its `since`
  /// moves forward; null for a publish-only connection.
  final Map<String, Object?> Function()? filter;
  final void Function(NostrEvent event)? onEvent;
  final void Function()? onStateChanged;

  /// Largest message accepted from a relay.
  static const int maxMessageChars = 512 * 1024;

  final String _subscriptionId = _randomId();
  final Map<String, Completer<(bool, String)>> _pendingOk = {};
  final List<Completer<void>> _connectionWaiters = [];
  NostrSocket? _socket;
  StreamSubscription<String>? _subscription;
  NostrRelayState _state = NostrRelayState.disconnected;
  bool _running = false;
  bool _authenticated = false;
  String? _lastError;
  Duration _backoff = const Duration(seconds: 2);
  Timer? _retryTimer;
  DateTime _lastUsed = DateTime.now();

  NostrRelayState get state => _state;
  String? get lastError => _lastError;
  bool get authenticated => _authenticated;
  DateTime get lastUsed => _lastUsed;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _running = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _closeSocket();
    for (final waiter in _connectionWaiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('Relay connection stopped.'));
      }
    }
    _connectionWaiters.clear();
    _setState(NostrRelayState.disconnected);
  }

  /// Sends [event] and waits for the relay to accept it. A relay that
  /// requires authentication gets it first and the event once more. The
  /// connection must have been started; a stopped one refuses.
  Future<void> publish(NostrEvent event) async {
    if (!_running) throw StateError('Relay connection is stopped.');
    _lastUsed = DateTime.now();
    final deadline = DateTime.now().add(_publishTimeout);
    var (accepted, message) = await _send(event, deadline);
    if (!accepted && message.startsWith('auth-required')) {
      await _waitForAuth(deadline);
      (accepted, message) = await _send(event, deadline);
    }
    if (!accepted) throw NostrRelayException(url.host, message);
  }

  Future<(bool, String)> _send(NostrEvent event, DateTime deadline) async {
    await _waitConnected(deadline);
    final completer = _pendingOk[event.id] = Completer<(bool, String)>();
    _socket!.send(jsonEncode(['EVENT', event.toJson()]));
    try {
      return await completer.future.timeout(_remaining(deadline));
    } finally {
      _pendingOk.remove(event.id);
    }
  }

  Future<void> _waitConnected(DateTime deadline) async {
    if (_state == NostrRelayState.connected) return;
    final waiter = Completer<void>();
    _connectionWaiters.add(waiter);
    try {
      await waiter.future.timeout(_remaining(deadline));
    } finally {
      _connectionWaiters.remove(waiter);
    }
  }

  Future<void> _waitForAuth(DateTime deadline) async {
    while (!_authenticated) {
      if (DateTime.now().isAfter(deadline)) {
        throw NostrRelayException(url.host, 'auth-required: timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Duration _remaining(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Future<void> _connect() async {
    if (!_running || _state != NostrRelayState.disconnected) return;
    _setState(NostrRelayState.connecting);
    try {
      final socket = await _connector(url);
      if (!_running) {
        await socket.close();
        return;
      }
      _socket = socket;
      _authenticated = false;
      _subscription = socket.messages.listen(
        _handle,
        onDone: _lost,
        onError: (Object error) {
          _lastError = '$error';
          _lost();
        },
        cancelOnError: true,
      );
      _lastError = null;
      _backoff = const Duration(seconds: 2);
      _setState(NostrRelayState.connected);
      _subscribe();
      for (final waiter in List.of(_connectionWaiters)) {
        if (!waiter.isCompleted) waiter.complete();
      }
    } catch (error) {
      _lastError = '$error';
      _setState(NostrRelayState.disconnected);
      _scheduleRetry();
    }
  }

  void _subscribe() {
    final current = filter?.call();
    if (current == null) return;
    _socket?.send(jsonEncode(['REQ', _subscriptionId, current]));
  }

  void _lost() {
    unawaited(_closeSocket());
    for (final pending in _pendingOk.values) {
      if (!pending.isCompleted) {
        pending.complete((false, 'error: disconnected'));
      }
    }
    _setState(NostrRelayState.disconnected);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_running) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_backoff, () => unawaited(_connect()));
    final doubled = _backoff * 2;
    _backoff = doubled > const Duration(minutes: 2)
        ? const Duration(minutes: 2)
        : doubled;
  }

  Future<void> _closeSocket() async {
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;
    await subscription?.cancel();
    await socket?.close().catchError((Object _) {});
  }

  void _handle(String raw) {
    if (raw.length > maxMessageChars) return;
    final Object? message;
    try {
      message = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (message is! List || message.isEmpty) return;
    switch (message) {
      case ['EVENT', final String id, final Object? json]
          when id == _subscriptionId:
        final event = NostrEvent.fromJson(json);
        if (event != null) onEvent?.call(event);
      case ['OK', final String id, final bool accepted, ...]:
        final text = message.length > 3 && message[3] is String
            ? message[3] as String
            : '';
        if (id == _authEventId) {
          _authenticated = accepted;
          _authEventId = null;
          if (accepted && _closedForAuth) {
            _closedForAuth = false;
            _subscribe();
          }
          onStateChanged?.call();
        }
        final pending = _pendingOk[id];
        if (pending != null && !pending.isCompleted) {
          pending.complete((accepted, text));
        }
      case ['CLOSED', final String id, ...] when id == _subscriptionId:
        final text = message.length > 2 && message[2] is String
            ? message[2] as String
            : '';
        if (text.startsWith('auth-required')) {
          _closedForAuth = true;
        } else {
          _lastError = text;
          onStateChanged?.call();
        }
      case ['AUTH', final String challenge]:
        _authenticate(challenge);
      case ['NOTICE', final String text]:
        _lastError = text;
        onStateChanged?.call();
      default:
        break;
    }
  }

  String? _authEventId;
  bool _closedForAuth = false;

  void _authenticate(String challenge) {
    if (challenge.length > 512) return;
    final event = NostrEvent.sign(
      secretKey: _authKey(),
      kind: NostrKind.clientAuth,
      tags: [
        ['relay', url.toString()],
        ['challenge', challenge],
      ],
      content: '',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    _authEventId = event.id;
    _socket?.send(jsonEncode(['AUTH', event.toJson()]));
  }

  void _setState(NostrRelayState state) {
    if (_state == state) return;
    _state = state;
    onStateChanged?.call();
  }

  static String _randomId() {
    final random = Random.secure();
    return List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
