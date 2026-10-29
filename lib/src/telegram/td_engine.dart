import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';

/// TDLib answered a request with an `error` object.
class TdError implements Exception {
  const TdError(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'Telegram error $code: $message';
}

/// TDLib's JSON interface (https://core.telegram.org/tdlib): requests and
/// updates are JSON objects with an `@type`. Tests substitute a fake.
abstract interface class TdEngine {
  /// Every update and unsolicited object TDLib sends (not request answers).
  Stream<Map<String, dynamic>> get updates;

  /// Sends [request] and returns TDLib's answer, or throws [TdError].
  Future<Map<String, dynamic>> send(
    Map<String, Object?> request, {
    Duration timeout = const Duration(seconds: 60),
  });

  /// Closes the client; its database stays on disk.
  Future<void> close();
}

/// Locations to try for TDLib's JSON library, honouring CONEST_TDJSON_LIBRARY.
Iterable<String> tdjsonLibraryCandidates() sync* {
  final override = Platform.environment['CONEST_TDJSON_LIBRARY'];
  if (override != null && override.trim().isNotEmpty) yield override.trim();
  final name = Platform.isWindows
      ? 'tdjson.dll'
      : Platform.isMacOS
      ? 'libtdjson.dylib'
      : 'libtdjson.so';
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    final directory = File(Platform.resolvedExecutable).parent.path;
    yield '$directory${Platform.pathSeparator}$name';
    yield '$directory${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
  }
  yield name;
}

typedef _CreateNative = Int Function();
typedef _CreateDart = int Function();
typedef _SendNative = Void Function(Int, Pointer<Utf8>);
typedef _SendDart = void Function(int, Pointer<Utf8>);
typedef _ReceiveNative = Pointer<Utf8> Function(Double);
typedef _ReceiveDart = Pointer<Utf8> Function(double);
typedef _ExecuteNative = Pointer<Utf8> Function(Pointer<Utf8>);

/// Routes the objects TDLib returns to the client they belong to, by
/// `@client_id`. TDLib has one receive queue per process, so exactly one
/// reader serves every client; objects for a client nobody holds any more
/// (a closed one) are dropped.
class TdRouter {
  final Map<int, void Function(Map<String, dynamic> object)> _clients = {};
  final Map<int, void Function()> _lost = {};

  /// [onLost] runs when the reader died under the client (its pending
  /// requests cannot be answered any more).
  void register(
    int clientId,
    void Function(Map<String, dynamic>) handler, {
    void Function()? onLost,
  }) {
    _clients[clientId] = handler;
    if (onLost != null) _lost[clientId] = onLost;
  }

  void unregister(int clientId) {
    _clients.remove(clientId);
    _lost.remove(clientId);
  }

  int get clients => _clients.length;

  /// Tells every client its answers will not come.
  void readerDied() {
    for (final lost in _lost.values.toList()) {
      lost();
    }
  }

  /// Hands one raw JSON object from `td_receive` to its client.
  void dispatch(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['@client_id'];
    if (id is! int) return;
    _clients[id]?.call(decoded);
  }
}

/// A running reader: it ends by itself after [requestStop] (within one
/// receive timeout) or if it crashes; [exited] completes either way.
class TdReaderHandle {
  TdReaderHandle({required this.exited, required this.requestStop});
  final Future<void> exited;
  final void Function() requestStop;
}

/// Keeps exactly one reader alive while any TDLib client exists: a dead
/// reader is started again on the next request, and the reader is stopped
/// (cleanly, never killed inside `td_receive`) when the last client closes,
/// so a Telegram that is off costs no wake-ups.
class TdReaderSupervisor {
  TdReaderSupervisor(this._spawn, {this.onDied});

  final Future<TdReaderHandle> Function() _spawn;

  /// Called when a reader ends without being asked to.
  final void Function()? onDied;

  Future<void>? _starting;
  TdReaderHandle? _handle;
  Future<void>? _stopping;

  bool get running => _handle != null;

  /// Makes sure a reader runs; waits for one that is stopping first.
  Future<void> ensure() async {
    while (_stopping != null) {
      await _stopping;
    }
    return _starting ??= _start();
  }

  Future<void> _start() async {
    try {
      final handle = await _spawn();
      _handle = handle;
      unawaited(
        handle.exited.then((_) {
          if (!identical(_handle, handle)) return;
          final asked = _stopping != null;
          _handle = null;
          _starting = null;
          if (!asked) onDied?.call();
        }),
      );
    } catch (_) {
      _starting = null;
      rethrow;
    }
  }

  /// Stops the reader when no client is left.
  Future<void> stopIfIdle(int clients) {
    final handle = _handle;
    if (clients > 0 || handle == null || _stopping != null) {
      return _stopping ?? Future.value();
    }
    final stopping = _stopping = () async {
      handle.requestStop();
      await handle.exited;
    }();
    return stopping.whenComplete(() {
      _stopping = null;
      if (identical(_handle, handle)) {
        _handle = null;
        _starting = null;
      }
    });
  }
}

/// The process-wide reader of TDLib's queue.
class _SharedTdReader {
  static final TdRouter router = TdRouter();
  static String? _path;

  static final TdReaderSupervisor supervisor = TdReaderSupervisor(
    () => _spawnNative(_path!),
    onDied: router.readerDied,
  );

  static Future<void> ensure(String libraryPath) {
    _path = libraryPath;
    return supervisor.ensure();
  }

  static Future<TdReaderHandle> _spawnNative(String libraryPath) async {
    final port = ReceivePort();
    port.listen((message) {
      if (message is String) router.dispatch(message);
    });
    final exitPort = ReceivePort();
    final stopFlag = calloc<Int32>();
    final exited = Completer<void>();
    exitPort.listen((_) {
      if (!exited.isCompleted) exited.complete();
      exitPort.close();
      port.close();
      calloc.free(stopFlag);
    });
    try {
      await Isolate.spawn(
        _readUpdates,
        (libraryPath, port.sendPort, stopFlag.address),
        debugName: 'conest-tdlib',
        onExit: exitPort.sendPort,
        onError: exitPort.sendPort,
      );
    } catch (_) {
      port.close();
      exitPort.close();
      calloc.free(stopFlag);
      rethrow;
    }
    return TdReaderHandle(
      exited: exited.future,
      requestStop: () => stopFlag.value = 1,
    );
  }
}

/// The real TDLib through `libtdjson`, built in CI and shipped next to the
/// app. A shared background isolate blocks in `td_receive`; nothing here
/// blocks the UI isolate.
class NativeTdEngine implements TdEngine {
  NativeTdEngine._(this._libraryPath, DynamicLibrary library)
    : _send = library.lookupFunction<_SendNative, _SendDart>('td_send'),
      _clientId = library.lookupFunction<_CreateNative, _CreateDart>(
        'td_create_client_id',
      )() {
    _SharedTdReader.router.register(_clientId, _onObject, onLost: _onLost);
    // Keep TDLib's own log (it can hold identifiers) off stderr.
    final execute = library.lookupFunction<_ExecuteNative, _ExecuteNative>(
      'td_execute',
    );
    final request = jsonEncode({
      '@type': 'setLogVerbosityLevel',
      'new_verbosity_level': 0,
    }).toNativeUtf8();
    try {
      execute(request);
    } finally {
      malloc.free(request);
    }
  }

  /// Whether libtdjson can be loaded here, without creating a client.
  static bool isAvailable() {
    for (final candidate in tdjsonLibraryCandidates()) {
      try {
        DynamicLibrary.open(candidate).lookup('td_create_client_id');
        return true;
      } catch (_) {
        // Try the next location.
      }
    }
    return false;
  }

  /// Null when libtdjson is not available (tests, builds without it).
  static NativeTdEngine? tryCreate() {
    for (final candidate in tdjsonLibraryCandidates()) {
      try {
        final library = DynamicLibrary.open(candidate);
        library.lookup('td_create_client_id');
        return NativeTdEngine._(candidate, library);
      } catch (_) {
        // Try the next location.
      }
    }
    return null;
  }

  final String _libraryPath;
  final _SendDart _send;
  final int _clientId;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _updates = StreamController<Map<String, dynamic>>.broadcast();
  final _random = Random.secure();
  bool _closed = false;
  final _closedUpdate = Completer<void>();

  @override
  Stream<Map<String, dynamic>> get updates => _updates.stream;

  /// The reader died: requests in flight will never be answered.
  void _onLost() {
    for (final completer in _pending.values.toList()) {
      if (!completer.isCompleted) {
        completer.completeError(const TdError(0, 'TDLib reader stopped'));
      }
    }
    _pending.clear();
  }

  void _onObject(Map<String, dynamic> object) {
    final extra = object['@extra'];
    if (extra is String && _pending.containsKey(extra)) {
      _pending.remove(extra)!.complete(object);
      return;
    }
    if (object['@type'] == 'updateAuthorizationState' &&
        object['authorization_state'] is Map &&
        (object['authorization_state'] as Map)['@type'] ==
            'authorizationStateClosed' &&
        !_closedUpdate.isCompleted) {
      _closedUpdate.complete();
    }
    if (!_updates.isClosed) _updates.add(object);
  }

  @override
  Future<Map<String, dynamic>> send(
    Map<String, Object?> request, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_closed) throw const TdError(500, 'closed');
    await _SharedTdReader.ensure(_libraryPath);
    final extra = List<int>.generate(
      12,
      (_) => _random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final completer = Completer<Map<String, dynamic>>();
    _pending[extra] = completer;
    final input = jsonEncode({...request, '@extra': extra}).toNativeUtf8();
    try {
      _send(_clientId, input);
    } finally {
      malloc.free(input);
    }
    final Map<String, dynamic> answer;
    try {
      answer = await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(extra);
      throw TdError(0, '${request['@type']} timed out');
    }
    if (answer['@type'] == 'error') {
      throw TdError(
        answer['code'] is int ? answer['code'] as int : 0,
        answer['message'] is String ? answer['message'] as String : 'failed',
      );
    }
    return answer;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await send({'@type': 'close'}, timeout: const Duration(seconds: 10));
      // The client is gone for good only once TDLib says so; its database
      // is then safe to open again.
      await _closedUpdate.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      // Closing is best effort.
    }
    _closed = true;
    _SharedTdReader.router.unregister(_clientId);
    unawaited(
      _SharedTdReader.supervisor.stopIfIdle(_SharedTdReader.router.clients),
    );
    for (final completer in _pending.values) {
      completer.completeError(const TdError(0, 'closed'));
    }
    _pending.clear();
    unawaited(_updates.close());
  }
}

/// Background isolate: blocks in `td_receive` and forwards each object. It
/// is the only caller of `td_receive` in the process, and leaves when the
/// shared stop flag is set (checked once per receive timeout).
void _readUpdates((String, SendPort, int) arguments) {
  final (libraryPath, port, flagAddress) = arguments;
  final stop = Pointer<Int32>.fromAddress(flagAddress);
  try {
    final library = DynamicLibrary.open(libraryPath);
    final receive = library.lookupFunction<_ReceiveNative, _ReceiveDart>(
      'td_receive',
    );
    while (stop.value == 0) {
      final pointer = receive(1.0);
      // TDLib owns this string until the next td_receive call; it is copied
      // before that call.
      if (pointer == nullptr) continue;
      port.send(pointer.toDartString());
    }
  } catch (_) {
    // The supervisor sees the exit and starts a new reader when needed.
  }
}
