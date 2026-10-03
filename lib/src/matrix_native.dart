import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'matrix_service.dart';

/// Locations to try for `conest_native`, honouring CONEST_NATIVE_LIBRARY.
Iterable<String> conestNativeLibraryCandidates() sync* {
  final override = Platform.environment['CONEST_NATIVE_LIBRARY'];
  if (override != null && override.trim().isNotEmpty) yield override.trim();
  final name = Platform.isWindows
      ? 'conest_native.dll'
      : Platform.isMacOS
      ? 'libconest_native.dylib'
      : 'libconest_native.so';
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    final directory = File(Platform.resolvedExecutable).parent.path;
    yield '$directory${Platform.pathSeparator}$name';
    yield '$directory${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
  }
  yield name;
}

typedef _CallNative = Bool Function(Pointer<Utf8>);
typedef _CallDart = bool Function(Pointer<Utf8>);
typedef _NextNative = Pointer<Utf8> Function(Uint32);
typedef _NextDart = Pointer<Utf8> Function(int);
typedef _StringNative = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class MatrixClientException implements Exception {
  const MatrixClientException(this.message);
  final String message;

  @override
  String toString() => 'MatrixClientException: $message';
}

/// The native Matrix client (`native/conest_native/src/matrix.rs`): commands
/// go out as JSON and answers come back through an event queue that a
/// background isolate drains, so nothing here blocks the UI isolate.
class NativeMatrixClient implements MatrixNativeApi {
  NativeMatrixClient._(this._libraryPath, DynamicLibrary library)
    : _call = library.lookupFunction<_CallNative, _CallDart>(
        'conest_matrix_call',
      ),
      _lastError = library.lookupFunction<_StringNative, _StringNative>(
        'conest_last_error',
      ),
      _free = library.lookupFunction<_FreeNative, _FreeDart>(
        'conest_string_free',
      );

  /// Null when no library with the Matrix symbols is available (tests,
  /// builds without the native client).
  static NativeMatrixClient? tryCreate() {
    for (final candidate in conestNativeLibraryCandidates()) {
      try {
        final library = DynamicLibrary.open(candidate);
        library.lookup('conest_matrix_next_event');
        return NativeMatrixClient._(candidate, library);
      } catch (_) {
        // Try the next location.
      }
    }
    return null;
  }

  final String _libraryPath;
  final _CallDart _call;
  final _StringNative _lastError;
  final _FreeDart _free;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _random = Random.secure();
  ReceivePort? _port;
  Isolate? _reader;

  /// Live events that are not command results: `sync` (with changed room
  /// ids) and `sync_error`.
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

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
      if (decoded['type'] == 'result') {
        _pending.remove(decoded['requestId'])?.complete(decoded);
      } else {
        _events.add(decoded);
      }
    });
    _reader = await Isolate.spawn(_readEvents, (
      _libraryPath,
      port.sendPort,
    ), debugName: 'conest-matrix-events');
  }

  /// Runs one command and returns its `value`, or throws with its error.
  @override
  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(minutes: 2),
  ]) async {
    await _ensureReader();
    final requestId = List<int>.generate(
      12,
      (_) => _random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    final input = jsonEncode({
      ...parameters,
      'op': op,
      'requestId': requestId,
    }).toNativeUtf8();
    try {
      if (!_call(input)) {
        _pending.remove(requestId);
        throw MatrixClientException(_takeLastError());
      }
    } finally {
      malloc.free(input);
    }
    final Map<String, dynamic> result;
    try {
      result = await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(requestId);
      throw MatrixClientException('Matrix $op timed out.');
    }
    if (result['ok'] != true) {
      throw MatrixClientException(
        result['error'] as String? ?? 'Matrix $op failed.',
      );
    }
    return (result['value'] as Map<String, dynamic>?) ?? const {};
  }

  String _takeLastError() {
    final pointer = _lastError();
    if (pointer == nullptr) return 'Unknown Matrix error.';
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer);
    }
  }

  void dispose() {
    _reader?.kill(priority: Isolate.immediate);
    _reader = null;
    _port?.close();
    _port = null;
    for (final completer in _pending.values) {
      completer.completeError(const MatrixClientException('Closed.'));
    }
    _pending.clear();
    unawaited(_events.close());
  }
}

/// Background isolate: blocks in the native queue and forwards each event.
void _readEvents((String, SendPort) arguments) {
  final (libraryPath, port) = arguments;
  final library = DynamicLibrary.open(libraryPath);
  final next = library.lookupFunction<_NextNative, _NextDart>(
    'conest_matrix_next_event',
  );
  final free = library.lookupFunction<_FreeNative, _FreeDart>(
    'conest_string_free',
  );
  while (true) {
    final pointer = next(1000);
    if (pointer == nullptr) continue;
    try {
      port.send(pointer.toDartString());
    } finally {
      free(pointer);
    }
  }
}
