import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CrashInitNative = Bool Function(Pointer<Utf8> path);
typedef _CrashInit = bool Function(Pointer<Utf8> path);

/// Asks the native library to write its crashes (Rust panics; Windows
/// exceptions nothing handled) to [path]. False when the library, or this
/// call in it, is missing (source runs, tests, older builds).
bool startNativeCrashReports(String path) {
  for (final candidate in _candidateLibraryPaths()) {
    final _CrashInit init;
    try {
      init = DynamicLibrary.open(
        candidate,
      ).lookupFunction<_CrashInitNative, _CrashInit>('conest_crash_init');
    } catch (_) {
      continue;
    }
    final native = path.toNativeUtf8();
    try {
      return init(native);
    } finally {
      malloc.free(native);
    }
  }
  return false;
}

Iterable<String> _candidateLibraryPaths() sync* {
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
