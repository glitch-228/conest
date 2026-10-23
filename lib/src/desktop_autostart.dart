import 'dart:io';

/// Runs a program, as [Process.run] does (replaced in tests).
typedef RunProcess =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Starting Conest when the user logs in (Linux, Windows), hidden in the
/// tray. Off unless chosen. The entry is written again at each start, so a
/// portable build that moved still starts; an instance with the setting off
/// takes away only an entry that starts itself, never another Conest's.
class DesktopAutostart {
  DesktopAutostart({
    String? executable,
    Directory? linuxAutostartDirectory,
    RunProcess? run,
    bool? windows,
  }) : _executable = executable ?? Platform.resolvedExecutable,
       _linuxDirectory = linuxAutostartDirectory,
       _run = run ?? Process.run,
       _windows = windows ?? Platform.isWindows;

  /// Given to Conest started at login: no window until asked for.
  static const hiddenFlag = '--hidden';

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'Conest';

  final String _executable;
  final Directory? _linuxDirectory;
  final RunProcess _run;
  final bool _windows;

  /// Whether this platform can start Conest at login.
  static bool get supported => Platform.isLinux || Platform.isWindows;

  /// Makes starting at login match [enabled].
  Future<void> apply(bool enabled) async {
    if (_windows) {
      await _applyWindows(enabled);
    } else {
      await _applyLinux(enabled);
    }
  }

  // Linux: an XDG autostart entry.

  File get _desktopFile {
    final directory =
        _linuxDirectory ??
        Directory(
          '${Platform.environment['XDG_CONFIG_HOME'] ?? '${Platform.environment['HOME']}/.config'}/autostart',
        );
    return File('${directory.path}/conest.desktop');
  }

  /// [_executable] as one argument of a desktop entry's Exec key.
  static String desktopExecArgument(String path) {
    final escaped = path.replaceAllMapped(
      RegExp(r'["`$\\]'),
      (match) => '\\${match[0]}',
    );
    return '"${escaped.replaceAll('%', '%%')}"';
  }

  String get _exec => '${desktopExecArgument(_executable)} $hiddenFlag';

  Future<void> _applyLinux(bool enabled) async {
    final file = _desktopFile;
    if (!enabled) {
      if (!await file.exists()) return;
      final text = await file.readAsString();
      if (text.contains('Exec=$_exec\n')) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    final icon = File('${File(_executable).parent.path}/data/conest.png');
    await file.writeAsString(
      '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=Conest\n'
      'Exec=$_exec\n'
      '${await icon.exists() ? 'Icon=${icon.path}\n' : ''}'
      'Terminal=false\n'
      'X-GNOME-Autostart-enabled=true\n',
    );
  }

  // Windows: a value under the user's Run key.

  String get _command => '"$_executable" $hiddenFlag';

  Future<void> _applyWindows(bool enabled) async {
    if (enabled) {
      await _run('reg', [
        'add',
        _runKey,
        '/v',
        _valueName,
        '/t',
        'REG_SZ',
        '/d',
        _command,
        '/f',
      ]);
      return;
    }
    final query = await _run('reg', ['query', _runKey, '/v', _valueName]);
    if (query.exitCode != 0) return;
    // Another Conest's entry (another folder) is not this one's to take.
    final current = '${query.stdout}'.toLowerCase();
    if (!current.contains('"${_executable.toLowerCase()}"')) return;
    await _run('reg', ['delete', _runKey, '/v', _valueName, '/f']);
  }
}
