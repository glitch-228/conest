/// What went wrong, kept across restarts on debug and nightly builds, so it
/// can be copied out when something misbehaves on a device (Q6).
///
/// Entries live in memory, bounded by count and size, and are written now
/// and then to an encrypted side file next to the vault (a key derived from
/// the vault key). A file that cannot be read starts an empty history.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// One line of the history.
class ErrorHistoryEntry {
  const ErrorHistoryEntry({
    required this.at,
    required this.kind,
    required this.text,
    this.subject,
  });

  /// The device it is about, when one (matched exactly, never by name).
  final String? subject;

  bool get isLog => kind == 'log';

  final DateTime at;

  /// 'error' for failures, 'log' for the debug log, or a narrower kind
  /// ('send', 'receive', 'carrier', …).
  final String kind;
  final String text;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'kind': kind,
    'text': text,
    if (subject != null) 'subject': subject,
  };

  static ErrorHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    final kind = json['kind'];
    final text = json['text'];
    if (at == null || kind is! String || text is! String) return null;
    final subject = json['subject'];
    return ErrorHistoryEntry(
      at: at.toUtc(),
      kind: kind,
      text: text,
      subject: subject is String ? subject : null,
    );
  }

  String format() => '${at.toUtc().toIso8601String()}  [$kind]  $text';
}

class ErrorHistory {
  ErrorHistory({
    this.file,
    this.key,
    this.capacity = 1000,
    this.logCapacity = 1000,
    this.maxBytes = 512 * 1024,
    this.flushDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Where it is kept; null keeps it in memory only.
  final File? file;

  /// 32-byte key for the file (required with [file]).
  final List<int>? key;

  /// Errors kept (and debug-log lines, separately: a chatty log never
  /// pushes errors out).
  final int capacity;
  final int logCapacity;
  final int maxBytes;
  final Duration flushDelay;
  final DateTime Function() _now;

  final List<ErrorHistoryEntry> _entries = [];
  int _bytes = 0;
  Timer? _flushTimer;
  bool _dirty = false;
  Future<void> _writeTail = Future<void>.value();

  /// Longest text kept for one entry.
  static const int maxEntryChars = 4000;

  List<ErrorHistoryEntry> get entries => List.unmodifiable(_entries);

  void add(String kind, String text, {String? subject}) {
    final trimmed = text.length > maxEntryChars
        ? '${text.substring(0, maxEntryChars)}…'
        : text;
    final entry = ErrorHistoryEntry(
      at: _now().toUtc(),
      kind: kind,
      text: trimmed,
      subject: subject,
    );
    _entries.add(entry);
    _bytes += _sizeOf(entry);
    _trim();
    _scheduleFlush();
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
    _scheduleFlush();
  }

  /// Every entry (or those containing [filter]), oldest first, as text.
  String exportText({String filter = ''}) {
    final needle = filter.trim().toLowerCase();
    return [
      for (final entry in _entries)
        if (needle.isEmpty ||
            entry.text.toLowerCase().contains(needle) ||
            entry.kind.toLowerCase().contains(needle))
          entry.format(),
    ].join('\n');
  }

  static int _sizeOf(ErrorHistoryEntry entry) =>
      entry.text.length + entry.kind.length + 40;

  void _trim() {
    void dropOldest(bool log) {
      final index = _entries.indexWhere((entry) => entry.isLog == log);
      if (index >= 0) _bytes -= _sizeOf(_entries.removeAt(index));
    }

    var logs = _entries.where((entry) => entry.isLog).length;
    var errors = _entries.length - logs;
    while (logs > logCapacity) {
      dropOldest(true);
      logs--;
    }
    while (errors > capacity) {
      dropOldest(false);
      errors--;
    }
    // Over the size: log lines go first.
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      if (logs > 0) {
        dropOldest(true);
        logs--;
      } else {
        dropOldest(false);
      }
    }
  }

  void _scheduleFlush() {
    if (file == null) return;
    _dirty = true;
    _flushTimer ??= Timer(flushDelay, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// Reads what an earlier run kept (before anything is added).
  Future<void> load() async {
    final target = file;
    final secret = key;
    if (target == null || secret == null || !await target.exists()) return;
    try {
      final bytes = await target.readAsBytes();
      final algorithm = Chacha20.poly1305Aead();
      if (bytes.length < algorithm.nonceLength + 16) return;
      final nonce = bytes.sublist(0, algorithm.nonceLength);
      final mac = bytes.sublist(bytes.length - 16);
      final cipher = bytes.sublist(algorithm.nonceLength, bytes.length - 16);
      final clear = await algorithm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(secret),
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! List) return;
      final loaded = [
        for (final item in decoded) ?ErrorHistoryEntry.fromJson(item),
      ];
      _entries.insertAll(0, loaded);
      _bytes = _entries.fold(0, (sum, entry) => sum + _sizeOf(entry));
      _trim();
    } catch (_) {
      // Unreadable (another key, damaged): start afresh.
    }
  }

  /// Writes the history now (when something changed).
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    return _writeTail = _writeTail.then((_) => _write());
  }

  Future<void> _write() async {
    final target = file;
    final secret = key;
    if (target == null || secret == null || !_dirty) return;
    _dirty = false;
    try {
      final algorithm = Chacha20.poly1305Aead();
      final box = await algorithm.encrypt(
        utf8.encode(jsonEncode([for (final e in _entries) e.toJson()])),
        secretKey: SecretKey(secret),
      );
      final temporary = File('${target.path}.tmp');
      await temporary.parent.create(recursive: true);
      await temporary.writeAsBytes([
        ...box.nonce,
        ...box.cipherText,
        ...box.mac.bytes,
      ], flush: true);
      await temporary.rename(target.path);
    } catch (_) {
      // Kept in memory; the next change tries again.
      _dirty = true;
    }
  }

  /// Forgets everything without writing again (the file goes with the
  /// vault).
  void discard() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _entries.clear();
    _bytes = 0;
    _dirty = false;
  }

  Future<void> close() async {
    await flush();
  }
}
