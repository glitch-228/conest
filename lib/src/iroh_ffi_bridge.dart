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
      Pointer<Utf8>,
      Pointer<Uint8>,
      UintPtr,
      Bool,
    );
typedef _SendDart =
    Pointer<Utf8> Function(
      int,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Uint8>,
      int,
      bool,
    );
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
        'conest_iroh_send_v3',
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

  // Matches the direct attachment range window: enough parallel QUIC streams
  // to cover latency without keeping eight Dart isolate heaps alive on mobile.
  static const int _sendWorkerCount = 4;

  final String _libraryPath;
  final StreamController<IrohBridgeInbound> _inbound =
      StreamController<IrohBridgeInbound>.broadcast();
  int? _handle;
  Timer? _poller;
  bool _polling = false;
  final List<Isolate> _sendWorkerIsolates = <Isolate>[];
  final List<SendPort> _sendWorkerPorts = <SendPort>[];
  int _nextSendWorker = 0;

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
    final libraryPath = _libraryPath;
    final started = await Isolate.run(
      () => _startNative(libraryPath, secretKeySeed, relayEnabled, relayUrls),
    );
    _handle = started.handle;
    try {
      for (var index = 0; index < _sendWorkerCount; index++) {
        final worker = await _spawnIrohSendWorker(libraryPath, index);
        _sendWorkerIsolates.add(worker.isolate);
        _sendWorkerPorts.add(worker.port);
      }
    } catch (_) {
      await _stopSendWorkers();
      _handle = null;
      await Isolate.run(() => _closeNative(libraryPath, started.handle));
      rethrow;
    }
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
    List<String> directAddresses = const <String>[],
  }) async {
    final handle = _handle;
    if (handle == null) throw StateError('Iroh bridge is not running.');
    if (_sendWorkerPorts.isEmpty) {
      throw StateError('Iroh send workers are not running.');
    }
    final worker =
        _sendWorkerPorts[_nextSendWorker++ % _sendWorkerPorts.length];
    final addressHints = List<String>.of(directAddresses, growable: false);
    final reply = ReceivePort();
    try {
      worker.send(<Object?>[
        reply.sendPort,
        handle,
        remoteEndpointId,
        addressHints,
        TransferableTypedData.fromList(<Uint8List>[bytes]),
        allowRelay,
      ]);
      final response = await reply.first;
      if (response is! List<Object?> || response.isEmpty) {
        throw const FormatException('Iroh send worker returned bad data.');
      }
      if (response.first != true) {
        throw StateError(
          response.length > 1 ? response[1].toString() : 'Iroh send failed.',
        );
      }
      final value = (response[1] as Map<Object?, Object?>)
          .cast<String, dynamic>();
      return IrohBridgeReceipt(
        endpointId: value['endpoint_id'] as String,
        relayed: value['path'] == 'Relayed',
        accepted: value['accepted'] as bool? ?? false,
      );
    } finally {
      reply.close();
    }
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
    await _stopSendWorkers();
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      final libraryPath = _libraryPath;
      await Isolate.run(() => _closeNative(libraryPath, handle));
    }
  }

  Future<void> _stopSendWorkers() async {
    final workerPorts = List<SendPort>.of(_sendWorkerPorts);
    final workerIsolates = List<Isolate>.of(_sendWorkerIsolates);
    _sendWorkerPorts.clear();
    _sendWorkerIsolates.clear();
    _nextSendWorker = 0;
    await Future.wait(
      workerPorts.map((workerPort) async {
        final reply = ReceivePort();
        try {
          workerPort.send(<Object?>[reply.sendPort]);
          await reply.first.timeout(const Duration(seconds: 5));
        } catch (_) {
          // The endpoint close below remains authoritative. A worker that is
          // already gone has no native resources of its own to recover.
        } finally {
          reply.close();
        }
      }),
    );
    for (final workerIsolate in workerIsolates) {
      workerIsolate.kill(priority: Isolate.immediate);
    }
  }

  static Iterable<String> _candidateLibraryPaths() sync* {
    final override = Platform.environment['CONEST_NATIVE_LIBRARY'];
    if (override != null && override.trim().isNotEmpty) {
      yield override.trim();
    }
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

Future<({Isolate isolate, SendPort port})> _spawnIrohSendWorker(
  String libraryPath,
  int workerIndex,
) async {
  final ready = ReceivePort();
  final isolate = await Isolate.spawn<List<Object?>>(
    _irohSendWorkerMain,
    <Object?>[libraryPath, ready.sendPort],
    debugName: 'conest-iroh-send-$workerIndex',
  );
  try {
    final response = await ready.first;
    if (response is SendPort) return (isolate: isolate, port: response);
    isolate.kill(priority: Isolate.immediate);
    throw StateError('Unable to start Iroh send worker: $response');
  } finally {
    ready.close();
  }
}

void _irohSendWorkerMain(List<Object?> startup) {
  final libraryPath = startup[0] as String;
  final ready = startup[1] as SendPort;
  late final _NativeIrohBindings bindings;
  try {
    bindings = _NativeIrohBindings(DynamicLibrary.open(libraryPath));
  } catch (error) {
    ready.send(error.toString());
    return;
  }
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  requests.listen((dynamic message) {
    if (message is! List<Object?> || message.isEmpty) return;
    final reply = message[0] as SendPort;
    if (message.length == 1) {
      reply.send(true);
      requests.close();
      return;
    }
    try {
      final bytes = (message[4] as TransferableTypedData)
          .materialize()
          .asUint8List();
      final value = _sendNativeWithBindings(
        bindings,
        message[1] as int,
        message[2] as String,
        (message[3] as List<Object?>).cast<String>(),
        bytes,
        message[5] as bool,
      );
      reply.send(<Object?>[true, value]);
    } catch (error, stackTrace) {
      reply.send(<Object?>[false, '$error\n$stackTrace']);
    }
  });
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

Map<String, dynamic> _sendNativeWithBindings(
  _NativeIrohBindings bindings,
  int handle,
  String endpoint,
  List<String> directAddresses,
  Uint8List bytes,
  bool allowRelay,
) {
  final endpointPointer = endpoint.toNativeUtf8();
  final directAddressesPointer = jsonEncode(directAddresses).toNativeUtf8();
  final bytesPointer = calloc<Uint8>(bytes.length);
  try {
    bytesPointer.asTypedList(bytes.length).setAll(0, bytes);
    return _decodeObject(
      bindings.takeString(
        bindings.send(
          handle,
          endpointPointer,
          directAddressesPointer,
          bytesPointer,
          bytes.length,
          allowRelay,
        ),
      ),
    );
  } finally {
    calloc.free(endpointPointer);
    calloc.free(directAddressesPointer);
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
