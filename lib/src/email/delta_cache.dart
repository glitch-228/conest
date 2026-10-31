import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// A bounded index of Delta files in the shared content-addressed cache.
/// Startup reads metadata only. File times preserve recency across restarts.
class DeltaAttachmentCache {
  DeltaAttachmentCache(
    this.directory, {
    this.maxBytes = 256 * 1024 * 1024,
    this.maxFiles = 4096,
    required this.onEvicted,
  });
  final Directory directory;
  final int maxBytes;
  final int maxFiles;
  final void Function(String name) onEvicted;
  final _entries = <String, ({int size, DateTime modified})>{};
  var _bytes = 0;
  int get sizeBytes => _bytes;

  Future<void> load(Iterable<String> names) async {
    final rows = <(String, FileStat)>[];
    final selected = names.toSet();
    if (!await directory.exists()) return;
    await for (final file in directory.list(followLinks: false)) {
      if (file is! File) continue;
      final name = file.uri.pathSegments.last;
      if (!name.startsWith('delta-') && !selected.contains(name)) continue;
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file) rows.add((name, stat));
    }
    rows.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final row in rows) {
      _entries[row.$1] = (size: row.$2.size, modified: row.$2.modified);
      _bytes += row.$2.size;
    }
  }

  Future<void> touch(String name, DateTime now) async {
    final entry = _entries.remove(name);
    if (entry == null) return;
    _entries[name] = (size: entry.size, modified: now);
    try {
      await File('${directory.path}/$name').setLastModified(now);
    } on FileSystemException {
      /* evicted elsewhere */
    }
  }

  /// Reserve space before writing; pinned/shared content stays protected.
  Future<void> reserve(String name, int size, Set<String> protected) async {
    if (size < 0 || size > maxBytes)
      throw const FileSystemException('Delta cache limit exceeded');
    final previous = _entries[name];
    var projected = _bytes - (previous?.size ?? 0) + size;
    var count = _entries.length + (previous == null ? 1 : 0);
    for (final key in _entries.keys.toList()) {
      if (projected <= maxBytes && count <= maxFiles) break;
      if (key == name || protected.contains(key)) continue;
      final row = _entries[key]!;
      final file = File('${directory.path}/$key');
      if (await file.exists()) await file.delete();
      _entries.remove(key);
      _bytes -= row.size;
      projected -= row.size;
      count--;
      onEvicted(key);
    }
    if (projected > maxBytes || count > maxFiles)
      throw const FileSystemException('Delta cache is full');
  }

  Future<void> record(String name, int size, DateTime now) async {
    final previous = _entries.remove(name);
    _bytes += size - (previous?.size ?? 0);
    _entries[name] = (size: size, modified: now);
    await touch(name, now);
  }
}

Future<String> deltaFileHash(Uint8List bytes) =>
    Isolate.run(() => base64Encode(crypto.sha256.convert(bytes).bytes));
