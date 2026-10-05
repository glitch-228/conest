import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'matrix_native.dart' show conestNativeLibraryCandidates;

typedef _CallNative = Bool Function(Pointer<Utf8>);
typedef _CallDart = bool Function(Pointer<Utf8>);
typedef _NextNative = Pointer<Utf8> Function(Uint32);
typedef _NextDart = Pointer<Utf8> Function(int);
typedef _StringNative = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class NativeQueueException implements Exception {
  const NativeQueueException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A native module that takes JSON commands through `conest_<name>_call`
/// and answers through an event queue drained by `conest_<name>_next_event`
/// on a background isolate (the shape of `matrix.rs` and `tor.rs`).
class NativeCommandQueue {
  NativeCommandQueue._(this._name, this._libraryPath, DynamicLibrary library)
    : _call = library.lookupFunction<_CallNative, _CallDart>(
        'conest_${_name}_call',
      ),
      _lastError = library.lookupFunction<_StringNative, _StringNative>(
        'conest_last_error',
      ),
      _free = library.lookupFunction<_FreeNative, _FreeDart>(
        'conest_string_free',
      );

  /// Null when no library with the module's symbols is available.
  static NativeCommandQueue? tryOpen(String name) {
    for (final candidate in conestNativeLibraryCandidates()) {
      try {
        final library = DynamicLibrary.open(candidate);
        library.lookup('conest_${name}_next_event');
        return NativeCommandQueue._(name, candidate, library);
      } catch (_) {
        // Try the next location.
      }
    }
    return null;
  }

  final String _name;
  final String _libraryPath;
  final _CallDart _call;
  final _StringNative _lastError;
  final _FreeDart _free;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _random = Random.secure();
  ReceivePort? _port;
  Isolate? _reader;

  /// Events that are not command results.
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
      'conest_${_name}_next_event',
      port.sendPort,
    ), debugName: 'conest-$_name-events');
  }

  /// Runs one command and returns its `value`, or throws with its error.
  Future<Object?> request(
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
        throw NativeQueueException(_takeLastError());
      }
    } finally {
      malloc.free(input);
    }
    final Map<String, dynamic> result;
    try {
      result = await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(requestId);
      throw NativeQueueException('$_name $op timed out.');
    }
    if (result['ok'] != true) {
      throw NativeQueueException(
        result['error'] as String? ?? '$_name $op failed.',
      );
    }
    return result['value'];
  }

  String _takeLastError() {
    final pointer = _lastError();
    if (pointer == nullptr) return 'Unknown $_name error.';
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
      completer.completeError(const NativeQueueException('Closed.'));
    }
    _pending.clear();
    unawaited(_events.close());
  }
}

/// Background isolate: blocks in the native queue and forwards each event.
void _readEvents((String, String, SendPort) arguments) {
  final (libraryPath, symbol, port) = arguments;
  final library = DynamicLibrary.open(libraryPath);
  final next = library.lookupFunction<_NextNative, _NextDart>(symbol);
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
