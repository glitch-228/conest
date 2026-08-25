import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'iroh_transport.dart';

typedef _StartNative =
    Uint64 Function(Pointer<Uint8>, UintPtr, Bool, Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Uint8>, int, bool, Pointer<Utf8>);
typedef _StatusNative = Pointer<Utf8> Function(Uint64);
typedef _StatusDart = Pointer<Utf8> Function(int);
typedef _SendNative =
    Pointer<Utf8> Function(
      Uint64,
      Pointer<Utf8>,
      Pointer<Uint8>,
      UintPtr,
      Bool,
    );
typedef _SendDart =
    Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Uint8>, int, bool);
typedef _NextNative = Pointer<Utf8> Function(Uint64);
typedef _NextDart = Pointer<Utf8> Function(int);
typedef _CloseNative = Void Function(Uint64);
typedef _CloseDart = void Function(int);
typedef _ErrorNative = Pointer<Utf8> Function();
typedef _ErrorDart = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class _NativeIrohBindings {
  _NativeIrohBindings(DynamicLibrary library)
    : start = library.lookupFunction<_StartNative, _StartDart>(
        'conest_iroh_start_v2',
      ),
      status = library.lookupFunction<_StatusNative, _StatusDart>(
        'conest_iroh_status',
      ),
      send = library.lookupFunction<_SendNative, _SendDart>(
        'conest_iroh_send_v2',
      ),
      next = library.lookupFunction<_NextNative, _NextDart>('conest_iroh_next'),
      close = library.lookupFunction<_CloseNative, _CloseDart>(
        'conest_iroh_close',
      ),
      lastError = library.lookupFunction<_ErrorNative, _ErrorDart>(
        'conest_last_error',
      ),
      freeString = library.lookupFunction<_FreeNative, _FreeDart>(
        'conest_string_free',
      );

  final _StartDart start;
  final _StatusDart status;
  final _SendDart send;
  final _NextDart next;
  final _CloseDart close;
  final _ErrorDart lastError;
  final _FreeDart freeString;

  String takeString(Pointer<Utf8> pointer) {
    if (pointer == nullptr) throw StateError(takeLastError());
    try {
      return pointer.toDartString();
    } finally {
      freeString(pointer);
    }
  }

  String takeLastError() {
    final pointer = lastError();
    if (pointer == nullptr) return 'Unknown Conest native error.';
    try {
      final value = pointer.toDartString();
      return value.isEmpty ? 'Unknown Conest native error.' : value;
    } finally {
      freeString(pointer);
    }
  }
}

/// Loads the platform `conest_native` library and presents the narrow bridge
/// expected by [IrohTransportAdapter]. Network calls run off the Flutter UI
/// isolate; inbound delivery is a bounded non-blocking native queue.
class FfiNativeIrohBridge implements NativeIrohBridge {
  FfiNativeIrohBridge._(this._libraryPath);

  final String _libraryPath;
  final StreamController<IrohBridgeInbound> _inbound =
      StreamController<IrohBridgeInbound>.broadcast();
  int? _handle;
  Timer? _poller;
  bool _polling = false;

  static FfiNativeIrohBridge? tryCreate() {
    for (final candidate in _candidateLibraryPaths()) {
      try {
        final library = DynamicLibrary.open(candidate);
        _NativeIrohBindings(library);
        return FfiNativeIrohBridge._(candidate);
      } catch (_) {
        // Try the next bundle/loader location. Missing native transport must
        // leave the existing Conest relay fallback operational.
      }
    }
    return null;
  }

  @override
  Stream<IrohBridgeInbound> get inbound => _inbound.stream;

  @override
  Future<IrohBridgeStatus> start({
    required Uint8List secretKeySeed,
    required bool relayEnabled,
    required List<String> relayUrls,
  }) async {
    if (_handle != null) throw StateError('Iroh bridge is already running.');
    final started = await Isolate.run(
      () => _startNative(_libraryPath, secretKeySeed, relayEnabled, relayUrls),
    );
    _handle = started.handle;
    _poller = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => unawaited(_pollInbound()),
    );
    return _statusFromJson(started.status);
  }

  @override
  Future<IrohBridgeReceipt> sendEnvelope({
    required String remoteEndpointId,
    required Uint8List bytes,
    required bool allowRelay,
  }) async {
    final handle = _handle;
    if (handle == null) throw StateError('Iroh bridge is not running.');
    final value = await Isolate.run(
      () => _sendNative(
        _libraryPath,
        handle,
        remoteEndpointId,
        bytes,
        allowRelay,
      ),
    );
    return IrohBridgeReceipt(
      endpointId: value['endpoint_id'] as String,
      relayed: value['path'] == 'Relayed',
      accepted: value['accepted'] as bool? ?? false,
    );
  }

  Future<void> _pollInbound() async {
    final handle = _handle;
    if (handle == null || _polling) return;
    _polling = true;
    try {
      for (var count = 0; count < 32; count++) {
        final value = _tryNextNative(_libraryPath, handle);
        if (value == null) break;
        _inbound.add(
          IrohBridgeInbound(
            senderEndpointId: value['senderEndpointId'] as String,
            bytes: Uint8List.fromList(
              base64Decode(value['bytesBase64'] as String),
            ),
            relayed: value['relayed'] as bool? ?? false,
          ),
        );
      }
    } catch (error, stackTrace) {
      _inbound.addError(error, stackTrace);
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> close() async {
    _poller?.cancel();
    _poller = null;
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      await Isolate.run(() => _closeNative(_libraryPath, handle));
    }
  }

  static Iterable<String> _candidateLibraryPaths() sync* {
    final name = Platform.isWindows
        ? 'conest_native.dll'
        : Platform.isMacOS
        ? 'libconest_native.dylib'
        : 'libconest_native.so';
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final executableDirectory = File(Platform.resolvedExecutable).parent.path;
      yield '$executableDirectory${Platform.pathSeparator}$name';
      yield '$executableDirectory${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
    }
    yield name;
  }
}

({int handle, Map<String, dynamic> status}) _startNative(
  String libraryPath,
  Uint8List seed,
  bool relayEnabled,
  List<String> relayUrls,
) {
  final bindings = _NativeIrohBindings(DynamicLibrary.open(libraryPath));
  final pointer = calloc<Uint8>(seed.length);
  final relaysPointer = jsonEncode(relayUrls).toNativeUtf8();
  try {
    pointer.asTypedList(seed.length).setAll(0, seed);
    final handle = bindings.start(
      pointer,
      seed.length,
      relayEnabled,
      relaysPointer,
    );
    if (handle == 0) throw StateError(bindings.takeLastError());
    final status = _decodeObject(bindings.takeString(bindings.status(handle)));
    return (handle: handle, status: status);
  } finally {
    calloc.free(pointer);
    calloc.free(relaysPointer);
  }
}

Map<String, dynamic> _sendNative(
  String libraryPath,
  int handle,
  String endpoint,
  Uint8List bytes,
  bool allowRelay,
) {
  final bindings = _NativeIrohBindings(DynamicLibrary.open(libraryPath));
  final endpointPointer = endpoint.toNativeUtf8();
  final bytesPointer = calloc<Uint8>(bytes.length);
  try {
    bytesPointer.asTypedList(bytes.length).setAll(0, bytes);
    return _decodeObject(
      bindings.takeString(
        bindings.send(
          handle,
          endpointPointer,
          bytesPointer,
          bytes.length,
          allowRelay,
        ),
      ),
    );
  } finally {
    calloc.free(endpointPointer);
    calloc.free(bytesPointer);
  }
}

Map<String, dynamic>? _tryNextNative(String libraryPath, int handle) {
  final bindings = _NativeIrohBindings(DynamicLibrary.open(libraryPath));
  final pointer = bindings.next(handle);
  if (pointer == nullptr) return null;
  return _decodeObject(bindings.takeString(pointer));
}

void _closeNative(String libraryPath, int handle) {
  _NativeIrohBindings(DynamicLibrary.open(libraryPath)).close(handle);
}

Map<String, dynamic> _decodeObject(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Native Iroh response is not an object.');
  }
  return decoded;
}

IrohBridgeStatus _statusFromJson(Map<String, dynamic> value) =>
    IrohBridgeStatus(
      endpointId: value['endpoint_id'] as String,
      directAddresses: (value['direct_addresses'] as List<dynamic>)
          .cast<String>(),
      relayUrl: value['relay_url'] as String?,
      relayEnabled: value['relay_enabled'] as bool? ?? false,
    );
