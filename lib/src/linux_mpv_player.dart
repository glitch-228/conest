import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class LinuxMpvSnapshot {
  const LinuxMpvSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.speed = 1,
    this.playing = false,
    this.loaded = false,
    this.completed = false,
    this.error,
  });

  final Duration position;
  final Duration duration;
  final double speed;
  final bool playing;
  final bool loaded;
  final bool completed;
  final String? error;
}

/// A Linux-only mpv client that keeps libmpv out of the Conest process. The
/// private Unix socket carries only local player controls and observations.
class LinuxMpvPlayer {
  LinuxMpvPlayer._(this._process, this._socket, this._socketDirectory) {
    _stdoutSubscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_rememberOutput);
    _stderrSubscription = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_rememberOutput);
    _socketSubscription = _socket
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: _fail,
          onDone: () => _fail(StateError('The mpv control socket closed.')),
        );
    unawaited(_process.exitCode.then(_handleExit));
  }

  static const Duration _startupTimeout = Duration(seconds: 3);
  static const Duration _commandTimeout = Duration(seconds: 2);
  static const int _maxSocketPathLength = 100;

  final Process _process;
  final Socket _socket;
  final Directory _socketDirectory;
  final StreamController<LinuxMpvSnapshot> _changes =
      StreamController<LinuxMpvSnapshot>.broadcast();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  StreamSubscription<String>? _socketSubscription;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  LinuxMpvSnapshot _snapshot = const LinuxMpvSnapshot();
  int _requestId = 0;
  String _recentOutput = '';
  bool _closed = false;
  bool _intentionalExit = false;
  bool _exited = false;

  LinuxMpvSnapshot get snapshot => _snapshot;
  Stream<LinuxMpvSnapshot> get changes => _changes.stream;
  bool get isPlaying => _snapshot.playing;

  static Future<LinuxMpvPlayer> start() async {
    final executable = _resolveExecutable();
    final base = Directory.systemTemp;
    final shortName =
        'conest-mpv-${pid}-${DateTime.now().microsecondsSinceEpoch}';
    final socketDirectory = Directory(p.join(base.path, shortName));
    await socketDirectory.create(recursive: true, mode: 0x1c0);
    final socketPath = p.join(socketDirectory.path, 'ipc.sock');
    if (socketPath.length >= _maxSocketPathLength) {
      await socketDirectory.delete(recursive: true);
      throw StateError('The private audio-control socket path is too long.');
    }
    final env = Map<String, String>.from(Platform.environment);
    final runtimeLib = _bundledRuntimeLibraryDirectory(executable);
    if (runtimeLib != null) {
      final current = env['LD_LIBRARY_PATH'];
      env['LD_LIBRARY_PATH'] = current == null || current.isEmpty
          ? runtimeLib
          : '$runtimeLib${Platform.isWindows ? ';' : ':'}$current';
    }
    final process =
        await Process.start(
          executable,
          [
            '--no-config',
            '--no-terminal',
            '--idle=yes',
            '--force-window=no',
            '--vo=null',
            '--input-ipc-server=$socketPath',
          ],
          environment: env,
          runInShell: false,
        ).timeout(
          _startupTimeout,
          onTimeout: () {
            throw TimeoutException(
              'mpv did not start in time.',
              _startupTimeout,
            );
          },
        );
    final deadline = DateTime.now().add(_startupTimeout);
    Socket? socket;
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        socket = await Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        ).timeout(const Duration(milliseconds: 150));
        break;
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (socket == null) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await socketDirectory.delete(recursive: true);
      throw StateError(
        'Could not open the private mpv audio controller: ${lastError ?? 'startup timed out'}.',
      );
    }
    final player = LinuxMpvPlayer._(process, socket, socketDirectory);
    try {
      await Future.wait([
        player._command(['observe_property', 1, 'time-pos']),
        player._command(['observe_property', 2, 'duration']),
        player._command(['observe_property', 3, 'pause']),
        player._command(['observe_property', 4, 'speed']),
      ]).timeout(_startupTimeout);
      return player;
    } catch (error) {
      await player.dispose();
      throw StateError('Could not initialize the mpv audio controller: $error');
    }
  }

  static String _resolveExecutable() {
    final override = Platform.environment['CONEST_MPV_PATH'];
    if (override != null && override.trim().isNotEmpty) return override.trim();
    final applicationDirectory = File(Platform.resolvedExecutable).parent;
    for (final candidate in [
      p.join(applicationDirectory.path, 'bin', 'mpv'),
      p.join(applicationDirectory.path, 'mpv'),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return 'mpv';
  }

  static String? _bundledRuntimeLibraryDirectory(String executable) {
    if (p.isAbsolute(executable)) {
      final directory = File(executable).parent.parent;
      final candidate = Directory(p.join(directory.path, 'lib', 'mpv-runtime'));
      if (candidate.existsSync()) return candidate.path;
    }
    final appDir = File(Platform.resolvedExecutable).parent;
    final candidate = Directory(p.join(appDir.path, 'lib', 'mpv-runtime'));
    return candidate.existsSync() ? candidate.path : null;
  }

  Future<void> playFile(String path) async {
    _throwIfUnavailable();
    await _command(['loadfile', path, 'replace']);
    await _command(['set_property', 'pause', false]);
    _set(
      _snapshot.copyWith(
        position: Duration.zero,
        duration: Duration.zero,
        playing: true,
        loaded: true,
        completed: false,
        clearError: true,
      ),
    );
  }

  Future<void> toggle() async {
    _throwIfUnavailable();
    await _command(['set_property', 'pause', _snapshot.playing]);
  }

  Future<void> seek(Duration position) async {
    _throwIfUnavailable();
    await _command([
      'seek',
      position.inMicroseconds / Duration.microsecondsPerSecond,
      'absolute+exact',
    ]);
  }

  Future<void> setSpeed(double speed) async {
    _throwIfUnavailable();
    await _command(['set_property', 'speed', speed]);
  }

  Future<void> stop() async {
    if (_closed || !_processIsRunning) return;
    await _command(['stop']);
    _set(
      _snapshot.copyWith(
        position: Duration.zero,
        playing: false,
        loaded: false,
        completed: false,
      ),
    );
  }

  Future<Map<String, dynamic>> _command(List<Object?> command) async {
    _throwIfUnavailable();
    final id = ++_requestId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _socket.write('${jsonEncode({'command': command, 'request_id': id})}\n');
      await _socket.flush();
      final response = await completer.future.timeout(_commandTimeout);
      if (response['error'] != 'success') {
        throw StateError('mpv rejected the audio command.');
      }
      return response;
    } on TimeoutException {
      throw TimeoutException('mpv audio command timed out.', _commandTimeout);
    } finally {
      _pending.remove(id);
    }
  }

  bool get _processIsRunning => !_closed && !_intentionalExit && !_exited;

  void _throwIfUnavailable() {
    if (!_processIsRunning) {
      throw StateError(
        _snapshot.error ?? 'The mpv audio helper is unavailable.',
      );
    }
  }

  void _handleLine(String line) {
    final Map<String, dynamic> value;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return;
      value = decoded;
    } catch (_) {
      return;
    }
    final requestId = value['request_id'];
    if (requestId is int) _pending[requestId]?.complete(value);
    final event = value['event'];
    if (event == 'property-change') {
      final name = value['name'];
      final data = value['data'];
      if (name == 'time-pos' && data is num) {
        _set(
          _snapshot.copyWith(
            position: Duration(microseconds: (data * 1000000).round()),
          ),
        );
      } else if (name == 'duration' && data is num) {
        _set(
          _snapshot.copyWith(
            duration: Duration(microseconds: (data * 1000000).round()),
          ),
        );
      } else if (name == 'pause' && data is bool) {
        _set(_snapshot.copyWith(playing: !data));
      } else if (name == 'speed' && data is num) {
        _set(_snapshot.copyWith(speed: data.toDouble()));
      }
    } else if (event == 'end-file') {
      final reason = value['reason'];
      final completed = reason == 'eof';
      _set(
        _snapshot.copyWith(
          position: completed ? _snapshot.duration : Duration.zero,
          playing: false,
          loaded: false,
          completed: completed,
          error: reason == 'error'
              ? 'mpv could not decode this voice message.'
              : null,
          clearError: reason != 'error',
        ),
      );
    }
  }

  void _rememberOutput(String line) {
    if (line.isEmpty) return;
    _recentOutput = line.length > 500
        ? line.substring(line.length - 500)
        : line;
  }

  void _fail(Object error, [StackTrace? stack]) {
    final message = 'Linux voice playback failed: $error';
    _set(_snapshot.copyWith(error: message, playing: false));
    for (final request in _pending.values) {
      if (!request.isCompleted) request.completeError(error, stack);
    }
  }

  void _handleExit(int code) {
    _exited = true;
    if (_closed || _intentionalExit) return;
    final detail = _recentOutput.isEmpty ? '' : ' $_recentOutput';
    _set(
      _snapshot.copyWith(
        error: 'Linux voice player stopped unexpectedly (exit $code).$detail',
        playing: false,
        loaded: false,
      ),
    );
    for (final request in _pending.values) {
      if (!request.isCompleted) {
        request.completeError(StateError('mpv stopped unexpectedly.'));
      }
    }
  }

  void _set(LinuxMpvSnapshot value) {
    _snapshot = value;
    if (!_changes.isClosed) _changes.add(value);
  }

  Future<void> dispose() async {
    if (_closed) return;
    if (!_exited) {
      try {
        await _command(['quit']).timeout(_commandTimeout);
      } catch (_) {}
    }
    _intentionalExit = true;
    _closed = true;
    _socket.destroy();
    if (!_exited) _process.kill(ProcessSignal.sigterm);
    if (!_exited) {
      try {
        await _process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        _process.kill(ProcessSignal.sigkill);
        try {
          await _process.exitCode.timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }
    await _socketSubscription?.cancel();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await _socketDirectory.delete(recursive: true);
    await _changes.close();
  }
}

extension on LinuxMpvSnapshot {
  LinuxMpvSnapshot copyWith({
    Duration? position,
    Duration? duration,
    double? speed,
    bool? playing,
    bool? loaded,
    bool? completed,
    String? error,
    bool clearError = false,
  }) => LinuxMpvSnapshot(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    speed: speed ?? this.speed,
    playing: playing ?? this.playing,
    loaded: loaded ?? this.loaded,
    completed: completed ?? this.completed,
    error: clearError ? null : (error ?? this.error),
  );
}
