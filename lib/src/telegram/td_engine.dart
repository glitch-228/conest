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

/// The real TDLib through `libtdjson`, built in CI and shipped next to the
/// app. A background isolate blocks in `td_receive`; nothing here blocks the
/// UI isolate.
class NativeTdEngine implements TdEngine {
  NativeTdEngine._(this._libraryPath, DynamicLibrary library)
    : _send = library.lookupFunction<_SendNative, _SendDart>('td_send'),
      _clientId = library.lookupFunction<_CreateNative, _CreateDart>(
        'td_create_client_id',
      )() {
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
  ReceivePort? _port;
  Isolate? _reader;

  @override
  Stream<Map<String, dynamic>> get updates => _updates.stream;

  Future<void> _ensureReader() async {
    if (_reader != null) return;
    final port = ReceivePort();
    _port = port;
    port.listen((message) {
      if (message is! String) return;
      final Object? decoded;
      try {
        decoded = jsonDecode(message);
      } on FormatException {
        return;
      }
      if (decoded is! Map<String, dynamic>) return;
      final extra = decoded['@extra'];
      if (extra is String && _pending.containsKey(extra)) {
        _pending.remove(extra)!.complete(decoded);
      } else {
        _updates.add(decoded);
      }
    });
    _reader = await Isolate.spawn(_readUpdates, (
      _libraryPath,
      _clientId,
      port.sendPort,
    ), debugName: 'conest-tdlib');
  }

  @override
  Future<Map<String, dynamic>> send(
    Map<String, Object?> request, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    await _ensureReader();
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
    try {
      await send({'@type': 'close'}, timeout: const Duration(seconds: 10));
    } catch (_) {
      // Closing is best effort.
    }
    _reader?.kill(priority: Isolate.immediate);
    _reader = null;
    _port?.close();
    _port = null;
    for (final completer in _pending.values) {
      completer.completeError(const TdError(0, 'closed'));
    }
    _pending.clear();
    unawaited(_updates.close());
  }
}

/// Background isolate: blocks in `td_receive` and forwards each object.
void _readUpdates((String, int, SendPort) arguments) {
  final (libraryPath, _, port) = arguments;
  final library = DynamicLibrary.open(libraryPath);
  final receive = library.lookupFunction<_ReceiveNative, _ReceiveDart>(
    'td_receive',
  );
  while (true) {
    final pointer = receive(1.0);
    // TDLib owns this string until the next td_receive call.
    if (pointer == nullptr) continue;
    port.send(pointer.toDartString());
  }
}
