import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// The bounded native ABI behind desktop links. Tests inject a fake source.
abstract interface class DesktopBleNative {
  Future<void> open();
  Map<String, dynamic> poll();
  bool sendTo(String link, Uint8List packet);
  int broadcast(Uint8List packet, {String? except});
  Future<void> close();
}

typedef _OpenNative = Uint64 Function();
typedef _OpenDart = int Function();
typedef _JsonNative = Pointer<Utf8> Function(Uint64);
typedef _JsonDart = Pointer<Utf8> Function(int);
typedef _SendNative =
    Bool Function(Uint64, Pointer<Uint8>, UintPtr, Pointer<Uint8>, UintPtr);
typedef _SendDart =
    bool Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _BroadcastNative =
    Uint32 Function(Uint64, Pointer<Uint8>, UintPtr, Pointer<Uint8>, UintPtr);
typedef _BroadcastDart =
    int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _CloseNative = Void Function(Uint64);
typedef _CloseDart = void Function(int);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class _Bindings {
  _Bindings(DynamicLibrary library)
    : open = library.lookupFunction<_OpenNative, _OpenDart>('conest_ble_open'),
      poll = library.lookupFunction<_JsonNative, _JsonDart>(
        'conest_ble_poll_events',
      ),
      limits = library.lookupFunction<_JsonNative, _JsonDart>(
        'conest_ble_link_limits',
      ),
      status = library.lookupFunction<_JsonNative, _JsonDart>(
        'conest_ble_status',
      ),
      send = library.lookupFunction<_SendNative, _SendDart>(
        'conest_ble_send_to',
      ),
      broadcast = library.lookupFunction<_BroadcastNative, _BroadcastDart>(
        'conest_ble_broadcast',
      ),
      close = library.lookupFunction<_CloseNative, _CloseDart>(
        'conest_ble_close',
      ),
      free = library.lookupFunction<_FreeNative, _FreeDart>(
        'conest_string_free',
      );

  final _OpenDart open;
  final _JsonDart poll;
  final _JsonDart limits;
  final _JsonDart status;
  final _SendDart send;
  final _BroadcastDart broadcast;
  final _CloseDart close;
  final _FreeDart free;
}

/// All radio operations run on Rust's dedicated worker. Poll and enqueue
/// only copy bounded memory; closing joins that worker on a helper isolate.
class FfiDesktopBleNative implements DesktopBleNative {
  String? _path;
  _Bindings? _bindings;
  int _handle = 0;

  @override
  Future<void> open() async {
    if (!Platform.isLinux && !Platform.isWindows) {
      throw UnsupportedError('Desktop Bluetooth needs Linux or Windows.');
    }
    if (_handle != 0) throw StateError('Bluetooth mesh is already open.');
    for (final path in _libraryPaths()) {
      try {
        _bindings = _Bindings(DynamicLibrary.open(path));
        _path = path;
        break;
      } catch (_) {
        // Try the next existing native-library location.
      }
    }
    final bindings = _bindings;
    if (bindings == null) {
      throw StateError('This build is missing desktop Bluetooth support.');
    }
    _handle = bindings.open();
    if (_handle == 0) {
      throw StateError('Bluetooth mesh could not start or is already open.');
    }
  }

  @override
  Map<String, dynamic> poll() {
    if (_handle == 0) throw StateError('Bluetooth mesh is closed.');
    final bindings = _bindings!;
    final pointer = bindings.poll(_handle);
    if (pointer == nullptr) throw StateError('Bluetooth mesh stopped.');
    try {
      final json = pointer.toDartString();
      // 32 events of at most 4096 bytes, base64 encoded, plus snapshots.
      if (json.length > 192 * 1024) {
        throw const FormatException('Bluetooth event batch too large.');
      }
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid Bluetooth event batch.');
      }
      return decoded;
    } finally {
      bindings.free(pointer);
    }
  }

  @override
  bool sendTo(String link, Uint8List packet) {
    if (_handle == 0 ||
        link.length != 20 ||
        packet.isEmpty ||
        packet.length > 512) {
      return false;
    }
    final id = utf8.encode(link);
    if (id.length != 20) return false;
    final linkBytes = calloc<Uint8>(id.length);
    final data = calloc<Uint8>(packet.length);
    try {
      linkBytes.asTypedList(id.length).setAll(0, id);
      data.asTypedList(packet.length).setAll(0, packet);
      return _bindings!.send(
        _handle,
        linkBytes,
        id.length,
        data,
        packet.length,
      );
    } finally {
      calloc.free(linkBytes);
      calloc.free(data);
    }
  }

  @override
  int broadcast(Uint8List packet, {String? except}) {
    if (_handle == 0 || packet.isEmpty || packet.length > 512) return 0;
    if (except != null && except.length != 20) return 0;
    final id = except == null ? null : utf8.encode(except);
    if (id != null && id.length != 20) return 0;
    final linkBytes = id == null
        ? nullptr.cast<Uint8>()
        : calloc<Uint8>(id.length);
    final data = calloc<Uint8>(packet.length);
    try {
      if (id != null) linkBytes.asTypedList(id.length).setAll(0, id);
      data.asTypedList(packet.length).setAll(0, packet);
      return _bindings!.broadcast(
        _handle,
        data,
        packet.length,
        linkBytes,
        id?.length ?? 0,
      );
    } finally {
      if (linkBytes != nullptr) calloc.free(linkBytes);
      calloc.free(data);
    }
  }

  @override
  Future<void> close() async {
    final handle = _handle;
    final path = _path;
    _handle = 0;
    if (handle != 0 && path != null) {
      await Isolate.run(() => _closeNative(path, handle));
    }
  }
}

void _closeNative(String path, int handle) {
  _Bindings(DynamicLibrary.open(path)).close(handle);
}

Iterable<String> _libraryPaths() sync* {
  final override = Platform.environment['CONEST_NATIVE_LIBRARY'];
  if (override != null && override.trim().isNotEmpty) yield override.trim();
  final name = Platform.isWindows ? 'conest_native.dll' : 'libconest_native.so';
  final executable = File(Platform.resolvedExecutable).parent.path;
  yield '$executable${Platform.pathSeparator}$name';
  yield '$executable${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
  yield name;
}
