import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

typedef _StartNative = Uint64 Function();
typedef _StartDart = int Function();
typedef _WaitNative = Uint64 Function(Uint64, Uint64, Uint64);
typedef _WaitDart = int Function(int, int, int);
typedef _StopNative = Void Function(Uint64);
typedef _StopDart = void Function(int);

/// How long one native wait lasts at most (the native side caps it at 60 s
/// as well). A wait that times out is not a change: it only comes back to
/// look again.
const int linkMonitorWaitMs = 60000;

/// The loop that turns the native monitor's generation number into change
/// reports: start it, it waits for a change off the main isolate and calls
/// [onChange] for each one; [stop] wakes a wait that is running (the native
/// side keeps what the wait holds until it returns).
///
/// The functions are the native ones (or a fake in tests): [start] returns a
/// handle (0: could not start), [wait] returns the new generation, the same
/// one after its timeout, or 0 once the monitor is stopped.
class LinkMonitorLoop {
  LinkMonitorLoop({
    required int Function() start,
    required Future<int> Function(int handle, int seen) wait,
    required void Function(int handle) stop,
    required void Function() onChange,
  }) : _start = start,
       _wait = wait,
       _stop = stop,
       _onChange = onChange;

  final int Function() _start;
  final Future<int> Function(int handle, int seen) _wait;
  final void Function(int handle) _stop;
  final void Function() _onChange;

  int _handle = 0;
  bool _running = false;
  bool _stopped = false;
  Future<void>? _loop;

  void start() {
    if (_running || _stopped) return;
    _running = true;
    _handle = _start();
    if (_handle == 0) return;
    _loop = _run(_handle);
  }

  Future<void> _run(int handle) async {
    var seen = 0;
    while (!_stopped) {
      final generation = await _wait(handle, seen);
      if (_stopped || generation == 0) break;
      // The first generation is the state at the start, not a change.
      if (seen != 0 && generation != seen) _onChange();
      seen = generation;
    }
  }

  /// Ends the loop. Safe to call twice.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    final handle = _handle;
    if (handle != 0) _stop(handle);
    await _loop;
  }
}

/// The native `conest_link_monitor_*` functions of `conest_native`
/// (Linux and Windows), waited on from a helper isolate.
class NativeLinkMonitor {
  NativeLinkMonitor._(this._libraryPath, this._startNative);

  final String _libraryPath;
  final int Function() _startNative;

  /// Null where the library has no monitor (Android, an older library).
  static NativeLinkMonitor? tryCreate() {
    if (!(Platform.isLinux || Platform.isWindows)) return null;
    for (final candidate in _candidateLibraryPaths()) {
      try {
        final library = DynamicLibrary.open(candidate);
        final start = library.lookupFunction<_StartNative, _StartDart>(
          'conest_link_monitor_start',
        );
        library.lookupFunction<_WaitNative, _WaitDart>(
          'conest_link_monitor_wait',
        );
        library.lookupFunction<_StopNative, _StopDart>(
          'conest_link_monitor_stop',
        );
        return NativeLinkMonitor._(candidate, start);
      } catch (_) {
        // The next place; without the library the other sources still work.
      }
    }
    return null;
  }

  /// A loop reporting every change of the system's interfaces to [onChange].
  LinkMonitorLoop loop(void Function() onChange) {
    final path = _libraryPath;
    return LinkMonitorLoop(
      start: _startNative,
      wait: (handle, seen) => Isolate.run(() {
        final library = DynamicLibrary.open(path);
        final wait = library.lookupFunction<_WaitNative, _WaitDart>(
          'conest_link_monitor_wait',
        );
        return wait(handle, seen, linkMonitorWaitMs);
      }),
      stop: (handle) {
        final library = DynamicLibrary.open(path);
        library.lookupFunction<_StopNative, _StopDart>(
          'conest_link_monitor_stop',
        )(handle);
      },
      onChange: onChange,
    );
  }

  static Iterable<String> _candidateLibraryPaths() sync* {
    final override = Platform.environment['CONEST_NATIVE_LIBRARY'];
    if (override != null && override.trim().isNotEmpty) {
      yield override.trim();
    }
    final name = Platform.isWindows
        ? 'conest_native.dll'
        : 'libconest_native.so';
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    yield '$executableDirectory${Platform.pathSeparator}$name';
    yield '$executableDirectory${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
    yield name;
  }
}
