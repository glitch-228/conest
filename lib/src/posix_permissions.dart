import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// rw------- (0600): only the owner reads and writes.
const int ownerReadWrite = 0x180;

typedef _ChmodLinuxNative = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodMacNative = Int32 Function(Pointer<Utf8>, Uint16);
typedef _ChmodDart = int Function(Pointer<Utf8>, int);

_ChmodDart? _chmod;
bool _looked = false;

_ChmodDart? _lookup() {
  if (_looked) return _chmod;
  _looked = true;
  try {
    final libc = DynamicLibrary.process();
    _chmod = Platform.isMacOS
        ? libc.lookupFunction<_ChmodMacNative, _ChmodDart>('chmod')
        : libc.lookupFunction<_ChmodLinuxNative, _ChmodDart>('chmod');
  } catch (_) {
    _chmod = null;
  }
  return _chmod;
}

/// Whether chmod(2) is called directly here (no process per change).
bool get chmodCallAvailable => _lookup() != null;

/// Sets [path]'s permission bits to [mode] (Linux, macOS) with chmod(2)
/// itself: a vault save used to start the `chmod` program up to four
/// times, a process each, even with nothing else going on. Falls back to
/// that program where the call is unavailable or refused, so failures
/// still come with its message.
Future<ProcessResult> setPosixMode(String path, int mode) async {
  final chmod = _lookup();
  if (chmod != null) {
    final native = path.toNativeUtf8(allocator: calloc);
    try {
      if (chmod(native, mode) == 0) return ProcessResult(0, 0, '', '');
    } finally {
      calloc.free(native);
    }
  }
  return Process.run('chmod', [mode.toRadixString(8), path]);
}
