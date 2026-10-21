/// Previews this device fetched, kept so a link is fetched once: at most
/// [LinkPreviews.maxEntries] for [LinkPreviews.maxAge], their pictures
/// within [LinkPreviews.maxImageBytes], least recently used first out. A
/// link that could not be previewed is not asked again for
/// [LinkPreviews.retryAfter]. Kept in an encrypted side file next to the
/// vault (which links came in is private).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'embed_fixers.dart';
import 'link_preview.dart';

class LinkPreviews {
  LinkPreviews({
    required LinkPreviewFetcher fetcher,
    this.file,
    this.key,
    DateTime Function()? now,
    this.onServiceFailed,
  }) : _fetcher = fetcher,
       _now = now ?? DateTime.now;

  static const maxEntries = 200;
  static const maxAge = Duration(days: 7);
  static const maxImageBytes = 4 * 1024 * 1024;
  static const retryAfter = Duration(hours: 1);

  /// Fetches at a time, however many messages ask.
  static const maxConcurrent = 3;

  final LinkPreviewFetcher _fetcher;
  final File? file;
  final List<int>? key;
  final DateTime Function() _now;

  /// An embed-fixing service ("twitter:1") gave nothing for a link.
  final void Function(String service)? onServiceFailed;

  // Insertion order is use order: the first is the least recently used.
  final _entries = <String, LinkPreview>{};
  final _failed = <String, DateTime>{};
  final _loading = <String, Future<LinkPreview?>>{};
  final _reported = <String, DateTime>{};
  var _running = 0;

  /// Bumped by [clear]: a fetch that started before keeps nothing.
  var _epoch = 0;
  final _waiting = <Completer<void>>[];
  Timer? _flushTimer;
  Future<void> _writeTail = Future<void>.value();

  /// The kept preview of [url], if fresh.
  LinkPreview? cached(Uri url) {
    final key = url.toString();
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (_now().difference(entry.fetchedAt) > maxAge) {
      _scheduleFlush();
      return null;
    }
    _entries[key] = entry; // most recently used
    return entry;
  }

  /// Whether [url] failed lately (not asked again yet).
  bool failedLately(Uri url) {
    final at = _failed[url.toString()];
    if (at == null) return false;
    final age = _now().difference(at);
    return !age.isNegative && age < retryAfter;
  }

  /// The preview of [url]: kept, or fetched (once, however many ask). For
  /// a link to an embed-fixing service ([fixers]), its other services and
  /// then the original are tried when it gives nothing.
  Future<LinkPreview?> preview(
    Uri url, {
    EmbedFixers? fixers,
    Set<String> failedServices = const {},
    int maxImage = LinkPreviewFetcher.maxImageBytes,
  }) {
    final hit = cached(url);
    if (hit != null) return Future.value(hit);
    if (failedLately(url)) return Future.value(null);
    final key = url.toString();
    return _loading[key] ??= () async {
      final epoch = _epoch;
      await _slot();
      try {
        final candidates = [
          url,
          ...?fixers?.alternatesFor(url, failed: failedServices),
        ];
        // Services that were down (not merely without this post): reported
        // only when another one did work, so a link to a post that does not
        // exist cannot switch them off.
        final down = <String>[];
        for (final candidate in candidates) {
          LinkPreview? preview;
          var serviceDown = false;
          try {
            preview = await _fetcher.fetch(
              candidate,
              maxImage: maxImage,
              now: _now,
            );
          } on LinkPreviewException catch (error) {
            serviceDown = error.down;
          } catch (_) {
            // Anything else (a page the parser chokes on) is a failure too.
          }
          if (preview != null) {
            if (epoch == _epoch) _remember(key, preview);
            // Only another service working shows these were down: the
            // original site answering says nothing about them.
            if (fixers?.serviceOf(candidate) != null) down.forEach(_report);
            return preview;
          }
          if (serviceDown) {
            if (fixers?.serviceOf(candidate) case final service?) {
              down.add(service);
            }
          }
        }
        _failed[key] = _now().toUtc();
        if (_failed.length > maxEntries) _failed.remove(_failed.keys.first);
        return null;
      } finally {
        _release();
        _loading.remove(key);
      }
    }();
  }

  /// At most once an hour per service.
  void _report(String service) {
    final now = _now();
    final last = _reported[service];
    if (last != null && now.difference(last) < retryAfter) return;
    _reported[service] = now;
    onServiceFailed?.call(service);
  }

  Future<void> _slot() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future; // the slot is handed over by [_release]
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  /// Forgets every kept preview and failure (previews were turned off),
  /// the file too.
  Future<void> clear() async {
    _epoch++;
    _entries.clear();
    _failed.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    await _writeTail;
    for (final path in [?file?.path, if (file != null) '${file!.path}.tmp']) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  void _remember(String key, LinkPreview preview) {
    _entries.remove(key);
    _entries[key] = preview;
    _failed.remove(key);
    _trim();
    _scheduleFlush();
  }

  void _trim() {
    final now = _now();
    _entries.removeWhere(
      (_, entry) => now.difference(entry.fetchedAt) > maxAge,
    );
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    var bytes = _entries.values.fold<int>(
      0,
      (sum, entry) => sum + (entry.image?.length ?? 0),
    );
    while (bytes > maxImageBytes && _entries.isNotEmpty) {
      final oldest = _entries.remove(_entries.keys.first);
      bytes -= oldest?.image?.length ?? 0;
    }
  }

  /// Reads what an earlier run kept.
  Future<void> load() async {
    final target = file;
    final secret = key;
    if (target == null || secret == null || !await target.exists()) return;
    try {
      final bytes = await target.readAsBytes();
      final algorithm = Chacha20.poly1305Aead();
      if (bytes.length < algorithm.nonceLength + 16) return;
      final clear = await algorithm.decrypt(
        SecretBox(
          bytes.sublist(algorithm.nonceLength, bytes.length - 16),
          nonce: bytes.sublist(0, algorithm.nonceLength),
          mac: Mac(bytes.sublist(bytes.length - 16)),
        ),
        secretKey: SecretKey(secret),
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! List) return;
      for (final item in decoded) {
        final entry = LinkPreview.fromJson(item);
        if (entry != null && item is Map && item['key'] is String) {
          _entries[item['key'] as String] = entry;
        }
      }
      _trim();
    } catch (_) {
      // Unreadable (another key, damaged): start afresh.
    }
  }

  void _scheduleFlush() {
    if (file == null) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 5), () => unawaited(flush()));
  }

  /// Writes the kept previews now.
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    return _writeTail = _writeTail.then((_) => _write());
  }

  Future<void> _write() async {
    final target = file;
    final secret = key;
    if (target == null || secret == null) return;
    try {
      final algorithm = Chacha20.poly1305Aead();
      final box = await algorithm.encrypt(
        utf8.encode(
          jsonEncode([
            for (final MapEntry(:key, :value) in _entries.entries)
              {...value.toJson(), 'key': key},
          ]),
        ),
        secretKey: SecretKey(secret),
      );
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsBytes([
        ...box.nonce,
        ...box.cipherText,
        ...box.mac.bytes,
      ], flush: true);
      await temporary.rename(target.path);
    } catch (_) {
      // Kept in memory for this run.
    }
  }

  void dispose() {
    _flushTimer?.cancel();
  }
}
