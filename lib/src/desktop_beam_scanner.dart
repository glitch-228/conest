import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _CameraStartNative = Uint64 Function(Uint32);
typedef _CameraStartDart = int Function(int);
typedef _CameraNextNative = Pointer<Utf8> Function(Uint64);
typedef _CameraNextDart = Pointer<Utf8> Function(int);
typedef _CameraStopNative = Void Function(Uint64);
typedef _CameraStopDart = void Function(int);
typedef _ErrorNative = Pointer<Utf8> Function();
typedef _ErrorDart = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class _DesktopBeamBindings {
  _DesktopBeamBindings(DynamicLibrary library)
    : start = library.lookupFunction<_CameraStartNative, _CameraStartDart>(
        'conest_beam_camera_start',
      ),
      next = library.lookupFunction<_CameraNextNative, _CameraNextDart>(
        'conest_beam_camera_next',
      ),
      stop = library.lookupFunction<_CameraStopNative, _CameraStopDart>(
        'conest_beam_camera_stop',
      ),
      lastError = library.lookupFunction<_ErrorNative, _ErrorDart>(
        'conest_last_error',
      ),
      freeString = library.lookupFunction<_FreeNative, _FreeDart>(
        'conest_string_free',
      );

  final _CameraStartDart start;
  final _CameraNextDart next;
  final _CameraStopDart stop;
  final _ErrorDart lastError;
  final _FreeDart freeString;

  String takeString(Pointer<Utf8> pointer) {
    try {
      return pointer.toDartString();
    } finally {
      freeString(pointer);
    }
  }

  String takeLastError() {
    final pointer = lastError();
    if (pointer == nullptr) return 'Unknown desktop camera error.';
    final value = takeString(pointer);
    return value.isEmpty ? 'Unknown desktop camera error.' : value;
  }
}

/// Polling bridge for the native Linux/Windows Beam QR scanner. The native
/// side owns camera frames and RXing; only decoded `cb1:` strings cross FFI.
class FfiDesktopBeamScanner {
  FfiDesktopBeamScanner._(this._libraryPath);

  final String _libraryPath;
  final StreamController<String> _frames = StreamController<String>.broadcast();
  int? _handle;
  Timer? _poller;
  bool _polling = false;

  Stream<String> get frames => _frames.stream;
  bool get isRunning => _handle != null;

  static FfiDesktopBeamScanner? tryCreate() {
    if (!Platform.isLinux && !Platform.isWindows) return null;
    for (final candidate in _candidateLibraryPaths()) {
      try {
        _DesktopBeamBindings(DynamicLibrary.open(candidate));
        return FfiDesktopBeamScanner._(candidate);
      } catch (_) {
        // The packaged native library is optional during source-only tests.
      }
    }
    return null;
  }

  Future<void> start({int cameraIndex = 0}) async {
    if (_handle != null) return;
    final handle = await Isolate.run(
      () => _startNative(_libraryPath, cameraIndex),
    );
    _handle = handle;
    _poller = Timer.periodic(
      const Duration(milliseconds: 35),
      (_) => unawaited(_poll()),
    );
  }

  Future<void> _poll() async {
    final handle = _handle;
    if (handle == null || _polling) return;
    _polling = true;
    try {
      for (var count = 0; count < 24; count++) {
        final value = _nextNative(_libraryPath, handle);
        if (value == null) break;
        if (value.startsWith('error:')) {
          _frames.addError(StateError(value.substring(6)));
          await close();
          break;
        }
        _frames.add(value);
      }
    } catch (error, stackTrace) {
      _frames.addError(error, stackTrace);
    } finally {
      _polling = false;
    }
  }

  Future<void> close() async {
    _poller?.cancel();
    _poller = null;
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      await Isolate.run(() => _stopNative(_libraryPath, handle));
    }
  }

  Future<void> dispose() async {
    await close();
    await _frames.close();
  }

  static Iterable<String> _candidateLibraryPaths() sync* {
    final name = Platform.isWindows
        ? 'conest_native.dll'
        : 'libconest_native.so';
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    yield '$executableDirectory${Platform.pathSeparator}$name';
    yield '$executableDirectory${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
    yield name;
  }
}

int _startNative(String libraryPath, int cameraIndex) {
  final bindings = _DesktopBeamBindings(DynamicLibrary.open(libraryPath));
  final handle = bindings.start(cameraIndex);
  if (handle == 0) throw StateError(bindings.takeLastError());
  return handle;
}

String? _nextNative(String libraryPath, int handle) {
  final bindings = _DesktopBeamBindings(DynamicLibrary.open(libraryPath));
  final pointer = bindings.next(handle);
  return pointer == nullptr ? null : bindings.takeString(pointer);
}

void _stopNative(String libraryPath, int handle) {
  _DesktopBeamBindings(DynamicLibrary.open(libraryPath)).stop(handle);
}
