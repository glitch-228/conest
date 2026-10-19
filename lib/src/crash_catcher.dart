/// Keeps a record of every crash, so none goes unnoticed: uncaught errors
/// from Dart and Flutter, native crashes the native library writes down,
/// and runs that ended without closing properly. The next start shows what
/// the last run left behind. Nothing leaves the device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// One thing that went wrong.
class CrashRecord {
  const CrashRecord({required this.at, required this.kind, required this.text});

  final DateTime at;

  /// Where it came from: `flutter`, `uncaught`, `zone`, `isolate`,
  /// `native`, `android` or `exit` (the run ended without closing).
  final String kind;
  final String text;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'kind': kind,
    'text': text,
  };

  static CrashRecord? tryParse(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    final kind = json['kind'];
    final text = json['text'];
    if (at == null || kind is! String || text is! String) return null;
    return CrashRecord(at: at, kind: kind, text: text);
  }

  String format() => '${at.toLocal().toIso8601String()} [$kind] $text';
}

/// What earlier runs left behind, until the user dismisses it.
class CrashReport {
  const CrashReport(this.records);

  final List<CrashRecord> records;

  bool get isEmpty => records.isEmpty;

  /// Ended badly (a crash, or closed without finishing) rather than only
  /// reporting errors it lived through.
  bool get crashed => records.any(
    (record) =>
        record.kind == 'exit' ||
        record.kind == 'native' ||
        record.kind == 'android',
  );

  String format() => records.map((record) => record.format()).join('\n\n');
}

class CrashCatcher {
  CrashCatcher({
    this.maxBytes = 256 * 1024,
    this.maxTextChars = 8000,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The app's one catcher, installed first thing in `main`.
  static final CrashCatcher instance = CrashCatcher();

  static const logName = 'crash-log.jsonl';
  static const previousName = 'previous.jsonl';
  static const markerName = 'running.marker';

  /// Written by the native library (panics, fatal signals, Windows
  /// exceptions): plain text, one report per block.
  static const nativeName = 'native-crash.txt';

  final int maxBytes;
  final int maxTextChars;
  final DateTime Function() _now;

  Directory? _directory;
  final List<CrashRecord> _early = [];
  final List<CrashRecord> _thisRun = [];
  void Function(String kind, String text)? _sink;
  CrashReport _previous = const CrashReport([]);
  bool _installed = false;

  /// What earlier runs left behind.
  CrashReport get previousRun => _previous;

  Directory? get directory => _directory;

  /// Catches uncaught errors from Flutter, the platform dispatcher and this
  /// isolate; zone errors come through [zoneError].
  void install() {
    if (_installed) return;
    _installed = true;
    final presentError = FlutterError.onError;
    FlutterError.onError = (details) {
      record(
        'flutter',
        details.exceptionAsString(),
        details.stack,
        context: details.context?.toString(),
      );
      presentError?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record('uncaught', '$error', stack);
      return true;
    };
    final port = RawReceivePort((Object? pair) {
      if (pair is List && pair.length == 2) {
        record(
          'isolate',
          '${pair[0]}',
          pair[1] == null ? null : StackTrace.fromString('${pair[1]}'),
        );
      }
    });
    Isolate.current.addErrorListener(port.sendPort);
  }

  /// For `runZonedGuarded`.
  void zoneError(Object error, StackTrace stack) =>
      record('zone', '$error', stack);

  /// Writes it down at once (a crash may be next), and passes it on to the
  /// error history once that is open.
  void record(String kind, String error, StackTrace? stack, {String? context}) {
    var text = [
      if (context != null && context.isNotEmpty) context,
      error,
      if (stack != null) '$stack',
    ].join('\n');
    if (text.length > maxTextChars) {
      text = '${text.substring(0, maxTextChars)}…';
    }
    final entry = CrashRecord(at: _now().toUtc(), kind: kind, text: text);
    if (_thisRun.length >= 32) _thisRun.removeAt(0);
    _thisRun.add(entry);
    try {
      _sink?.call(kind, text);
    } catch (_) {
      // The history may be closing; the file below still has it.
    }
    final directory = _directory;
    if (directory == null) {
      if (_early.length < 64) _early.add(entry);
      return;
    }
    _append(File(p.join(directory.path, logName)), entry);
  }

  /// Where records go from now on (in the app's data folder); earlier runs'
  /// records and a run that never closed become [previousRun].
  ///
  /// [markRunning]: whether this run counts as running from the start. On
  /// Android the system ends apps in the background as a matter of course,
  /// so the marker is kept only while the app is in front.
  /// [build] names the running build: a marker left by another build
  /// means an update replaced the app, not that it crashed.
  Future<void> attach(
    Directory directory, {
    required bool markRunning,
    String? build,
  }) async {
    _build = build;
    try {
      await directory.create(recursive: true);
      final log = File(p.join(directory.path, logName));
      final previous = File(p.join(directory.path, previousName));
      final carried = <CrashRecord>[
        ..._readRecords(previous),
        ..._readRecords(log),
      ];
      final native = File(p.join(directory.path, nativeName));
      if (native.existsSync()) {
        final text = _readCapped(native).trim();
        if (text.isNotEmpty) {
          carried.add(
            CrashRecord(
              at: native.lastModifiedSync().toUtc(),
              kind: 'native',
              text: text,
            ),
          );
        }
        native.deleteSync();
      }
      final marker = File(p.join(directory.path, markerName));
      final ended = marker.existsSync() ? _readMarker(marker) : null;
      // Not a crash: the app handed itself to an installer or updater, or
      // a newer build now runs (an update replaced the one that was).
      final replaced =
          ended != null &&
          (ended.updating ||
              (build != null && ended.build != null && ended.build != build));
      if (ended != null && !replaced) {
        carried.add(
          CrashRecord(
            at: ended.at,
            kind: 'exit',
            text:
                'Conest closed without finishing: a crash, or the device '
                'shut it down.',
          ),
        );
      }
      if (log.existsSync()) log.deleteSync();
      _writeRecords(previous, carried);
      _previous = CrashReport(_readRecords(previous));
      _directory = directory;
      if (markRunning) this.markRunning();
      for (final entry in _early) {
        _append(log, entry);
      }
      _early.clear();
    } catch (error) {
      // No folder to write to: records stay in memory for this run.
      debugPrint('Crash records unavailable: $error');
    }
  }

  /// Records found outside this catcher (Android's exit records).
  void addPrevious(Iterable<CrashRecord> records) {
    final list = records.toList();
    if (list.isEmpty) return;
    final directory = _directory;
    final merged = [..._previous.records, ...list];
    if (directory != null) {
      final file = File(p.join(directory.path, previousName));
      _writeRecords(file, merged);
      _previous = CrashReport(_readRecords(file));
    } else {
      _previous = CrashReport(merged);
    }
  }

  /// The user has seen what earlier runs left behind.
  void dismissPrevious() {
    _previous = const CrashReport([]);
    final directory = _directory;
    if (directory == null) return;
    final file = File(p.join(directory.path, previousName));
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// The running build, written into the marker.
  String? _build;

  /// This run is in progress: if it ends without [markStopped], the next
  /// start says so.
  void markRunning() => _writeMarker(updating: false);

  /// The app is handing itself to an installer or updater, which ends it:
  /// the next start says nothing.
  void markUpdating() => _writeMarker(updating: true);

  void _writeMarker({required bool updating}) {
    final directory = _directory;
    if (directory == null) return;
    try {
      File(p.join(directory.path, markerName)).writeAsStringSync(
        jsonEncode({
          'at': _now().toUtc().toIso8601String(),
          'build': ?_build,
          if (updating) 'updating': true,
        }),
        flush: true,
      );
    } catch (_) {}
  }

  /// A marker as written by [_writeMarker], or by older builds (only the
  /// time).
  static ({DateTime at, String? build, bool updating}) _readMarker(
    File marker,
  ) {
    final text = marker.readAsStringSync().trim();
    final fallback = marker.lastModifiedSync().toUtc();
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) {
        return (
          at: DateTime.tryParse('${json['at']}')?.toUtc() ?? fallback,
          build: json['build'] is String ? json['build'] as String : null,
          updating: json['updating'] == true,
        );
      }
    } catch (_) {}
    return (
      at: DateTime.tryParse(text)?.toUtc() ?? fallback,
      build: null,
      updating: false,
    );
  }

  /// This run closed properly, or went to the background where the system
  /// may end it.
  void markStopped() {
    final directory = _directory;
    if (directory == null) return;
    try {
      final marker = File(p.join(directory.path, markerName));
      if (marker.existsSync()) marker.deleteSync();
    } catch (_) {}
  }

  /// The error history, once open: this run's records so far go there, as
  /// do earlier runs', and every later one.
  void connect(void Function(String kind, String text) sink) {
    _sink = sink;
    for (final entry in [..._previous.records, ..._thisRun]) {
      try {
        sink(entry.kind, entry.text);
      } catch (_) {}
    }
  }

  void disconnect() => _sink = null;

  void _append(File file, CrashRecord entry) {
    try {
      if (file.existsSync() && file.lengthSync() > maxBytes) {
        final kept = _readRecords(file);
        _writeRecords(file, kept.sublist(kept.length ~/ 2));
      }
      file.writeAsStringSync(
        '${jsonEncode(entry.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Nowhere to write: nothing more can be done for it.
    }
  }

  List<CrashRecord> _readRecords(File file) {
    if (!file.existsSync()) return [];
    try {
      return [
        for (final line in const LineSplitter().convert(_readCapped(file)))
          if (line.trim().isNotEmpty) ?_tryDecode(line),
      ];
    } catch (_) {
      return [];
    }
  }

  CrashRecord? _tryDecode(String line) {
    try {
      return CrashRecord.tryParse(jsonDecode(line));
    } catch (_) {
      return null;
    }
  }

  /// Keeps the newest records within [maxBytes].
  void _writeRecords(File file, List<CrashRecord> records) {
    final lines = [for (final entry in records) jsonEncode(entry.toJson())];
    var total = 0;
    var start = lines.length;
    while (start > 0 && total + lines[start - 1].length + 1 <= maxBytes) {
      start--;
      total += lines[start].length + 1;
    }
    try {
      if (start == lines.length) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      file.writeAsStringSync(
        '${lines.sublist(start).join('\n')}\n',
        flush: true,
      );
    } catch (_) {}
  }

  /// The end of the file, at most [maxBytes] of it.
  String _readCapped(File file) {
    final length = file.lengthSync();
    if (length <= maxBytes) return file.readAsStringSync();
    final handle = file.openSync();
    try {
      handle.setPositionSync(length - maxBytes);
      return utf8.decode(handle.readSync(maxBytes), allowMalformed: true);
    } finally {
      handle.closeSync();
    }
  }
}
