import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as paths;

import 'group_history_event.dart';

/// One encrypted append-only journal per group, outside the attachment cache.
/// The caller owns the vault key and must authorize membership before appending
/// or serving an event. This layer checks signatures and author-chain conflicts;
/// it deliberately cannot turn a self-supplied signing key into membership.
///
/// A dedicated worker owns the file lock, crypto and rebuildable offset indexes.
/// Only bounded pages cross the UI isolate. Appends are flushed before success;
/// a torn final frame is discarded on reopening, never a complete corrupt frame.
class GroupHistoryJournal {
  GroupHistoryJournal._(this._fileIdentity);

  // POSIX advisory locks may be process-scoped, so also exclude a second
  // worker in this application isolate before acquiring the OS file lock.
  static final _openFiles = <String>{};
  final String _fileIdentity;

  final _responses = ReceivePort();
  final _errors = ReceivePort();
  final _ready = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  SendPort? _commands;
  Isolate? _isolate;
  int _nextId = 0;
  bool _closed = false;
  bool _disposed = false;

  static Future<GroupHistoryJournal> open({
    required File file,
    required List<int> key,
    required String groupId,
  }) async {
    if (key.length != 32 || groupId.isEmpty || groupId.length > 128) {
      throw ArgumentError('A vault key and group identity are required.');
    }
    await file.parent.create(recursive: true);
    final fileIdentity = await file.exists()
        ? await file.resolveSymbolicLinks()
        : paths.join(
            await file.parent.resolveSymbolicLinks(),
            paths.basename(file.path),
          );
    if (!_openFiles.add(fileIdentity)) {
      throw StateError('This group history journal is already open.');
    }
    final journal = GroupHistoryJournal._(fileIdentity);
    journal._responses.listen(journal._receive);
    journal._errors.listen((_) {
      journal._fail(StateError('Group history worker failed.'));
    });
    try {
      journal._isolate = await Isolate.spawn(
        _runJournal,
        <Object?>[
          fileIdentity,
          List<int>.of(key),
          groupId,
          journal._responses.sendPort,
        ],
        onExit: journal._responses.sendPort,
        onError: journal._errors.sendPort,
        errorsAreFatal: true,
        debugName: 'conest-group-journal',
      );
      await journal._ready.future;
      return journal;
    } catch (_) {
      journal._dispose();
      rethrow;
    }
  }

  void _receive(dynamic message) {
    if (message == null) {
      _fail(StateError('Group history worker stopped.'));
      return;
    }
    final response = message as List<Object?>;
    if (response[0] == 'ready') {
      _commands = response[1] as SendPort;
      _ready.complete();
      return;
    }
    if (response[0] == 'openError') {
      _fail(FormatException(response[1] as String));
      return;
    }
    final pending = _pending.remove(response[0] as int);
    if (pending == null) return;
    if (response[1] == true) {
      pending.complete(response[2]);
    } else {
      pending.completeError(StateError(response[2] as String));
    }
  }

  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _dispose();
  }

  Future<Object?> _request(String operation, [Object? arguments]) {
    if (_closed || _commands == null) {
      return Future.error(StateError('Group history journal is closed.'));
    }
    final id = ++_nextId;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands!.send([id, operation, arguments]);
    return result.future;
  }

  /// Returns false for an already durable event; conflicting author sequences
  /// throw instead of silently overwriting history. Membership checks belong to
  /// the sync engine before this call, including on locally authored events.
  Future<bool> append(GroupHistoryEvent event) async =>
      await _request('append', event) as bool;

  Future<List<GroupHistoryEvent>> readPage({
    String? beforeEventId,
    int limit = 50,
  }) async => (await _request('page', [beforeEventId, limit]) as List)
      .cast<GroupHistoryEvent>();

  Future<List<String>> authors({String? after, int limit = 16}) async =>
      (await _request('authors', [after, limit]) as List).cast<String>();

  Future<List<GroupHistoryEvent>> readMembershipPage({
    String? afterEventId,
    int limit = 32,
  }) async => (await _request('memberships', [afterEventId, limit]) as List)
      .cast<GroupHistoryEvent>();

  Future<List<GroupHistoryEvent>> readEvents(List<String> ids) async =>
      (await _request('events', List<String>.of(ids)) as List)
          .cast<GroupHistoryEvent>();

  Future<GroupHistoryEvent?> authorHead(String author) async =>
      await _request('authorHead', [author]) as GroupHistoryEvent?;

  Future<GroupHistoryEvent?> sourceMessage(
    String author,
    String messageId,
  ) async =>
      await _request('sourceMessage', [author, messageId])
          as GroupHistoryEvent?;

  Future<Set<String>> retainedIds(List<String> ids) async =>
      (await _request('retained', List<String>.of(ids)) as List)
          .cast<String>()
          .toSet();

  Future<Map<String, Object?>> syncProgress(String peerDeviceId) async =>
      Map<String, Object?>.from(
        await _request('syncProgress', [peerDeviceId]) as Map,
      );

  Future<void> saveSyncProgress(
    String peerDeviceId,
    Map<String, Object?> progress,
  ) async {
    await _request('saveSyncProgress', [
      peerDeviceId,
      Map<String, Object?>.of(progress),
    ]);
  }

  /// Inclusive, contiguous verified ranges. The next page starts after the
  /// previous page's final end; gaps remain visible even with reordered arrival.
  Future<List<({int start, int end})>> rangesForAuthor(
    String authorDeviceId, {
    int afterSequence = 0,
    int limit = 64,
  }) async =>
      (await _request('ranges', [authorDeviceId, afterSequence, limit]) as List)
          .cast<List>()
          .map((range) => (start: range[0] as int, end: range[1] as int))
          .toList(growable: false);

  Future<List<GroupHistoryEvent>> readAuthorRange(
    String authorDeviceId, {
    required int start,
    required int end,
    int limit = 50,
  }) async =>
      (await _request('range', [authorDeviceId, start, end, limit]) as List)
          .cast<GroupHistoryEvent>();

  Future<void> close() async {
    if (_closed) return;
    // Queue close after prior requests and reject any new work immediately.
    final done = _request('close');
    _closed = true;
    try {
      await done;
    } finally {
      _dispose();
    }
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _responses.close();
    _errors.close();
    _openFiles.remove(_fileIdentity);
  }
}

Future<void> _runJournal(List<Object?> input) async {
  final responses = input[3] as SendPort;
  final commands = ReceivePort();
  final worker = _JournalWorker(
    File(input[0] as String),
    SecretKey(input[1] as List<int>),
    input[2] as String,
  );
  try {
    await worker.open();
    responses.send(['ready', commands.sendPort]);
    await for (final raw in commands) {
      final command = raw as List<Object?>;
      final id = command[0] as int;
      final operation = command[1] as String;
      try {
        final result = await worker.execute(operation, command[2]);
        responses.send([id, true, result]);
      } catch (error) {
        responses.send([id, false, error.toString()]);
      }
      if (operation == 'close') break;
    }
  } catch (error) {
    await worker.close();
    responses.send(['openError', error.toString()]);
  } finally {
    commands.close();
    await worker.close();
  }
}

class _JournalWorker {
  _JournalWorker(this.file, this.key, this.groupId);

  static final _magic = utf8.encode('CONEST-GROUP-JOURNAL-1\n');
  static const _maxFrame = groupEventMaxBytes + 28;
  static const _pageBytes = 1024 * 1024;
  final File file;
  final SecretKey key;
  final String groupId;
  final _cipher = Chacha20.poly1305Aead();
  final _entries = <String, _JournalEntry>{};
  final _authors = <String, Map<int, _JournalEntry>>{};
  final _ordered = <_JournalEntry>[];
  final _authorHeads = <String, _JournalEntry>{};
  final _sourceMessages = <String, _JournalEntry>{};
  RandomAccessFile? _handle;
  int _end = 0;
  bool _poisoned = false;
  Map<String, Object?>? _syncProgress;

  Future<Map<String, Object?>> _loadSyncProgress() async {
    if (_syncProgress != null) return _syncProgress!;
    final progressFile = File('${file.path}.sync');
    try {
      if (await progressFile.exists() && await progressFile.length() <= 65536) {
        final bytes = await progressFile.readAsBytes();
        final clear = await _cipher.decrypt(
          SecretBox(
            bytes.sublist(12, bytes.length - 16),
            nonce: bytes.sublist(0, 12),
            mac: Mac(bytes.sublist(bytes.length - 16)),
          ),
          secretKey: key,
          aad: utf8.encode('conest.group-sync-progress.v1|$groupId'),
        );
        _syncProgress = Map<String, Object?>.from(
          jsonDecode(utf8.decode(clear)) as Map,
        );
      }
    } catch (_) {
      // Progress is an optimization. Corruption can only cause another metadata
      // scan; signed, durable events in the journal remain authoritative.
    }
    return _syncProgress ??= {};
  }

  Future<void> _saveSyncProgress(
    String peer,
    Map<String, Object?> progress,
  ) async {
    if (peer.isEmpty || peer.length > 128) {
      throw ArgumentError('Invalid sync peer.');
    }
    final updated = Map<String, Object?>.of(await _loadSyncProgress());
    if (progress.isEmpty) {
      updated.remove(peer);
    } else {
      updated[peer] = progress;
    }
    final clear = utf8.encode(jsonEncode(updated));
    if (clear.length > 65000) {
      throw StateError('Too many pending group synchronization cursors.');
    }
    final box = await _cipher.encrypt(
      clear,
      secretKey: key,
      aad: utf8.encode('conest.group-sync-progress.v1|$groupId'),
    );
    final destination = File('${file.path}.sync');
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsBytes([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ], flush: true);
    try {
      await temporary.rename(destination.path);
    } on FileSystemException {
      // Windows may refuse replacement. Losing only this optional cursor on a
      // crash between delete/rename safely restarts metadata enumeration.
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
    }
    _syncProgress = updated;
  }

  Future<void> open() async {
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.append);
    _handle = handle;
    await handle.lock(FileLock.exclusive);
    var length = await handle.length();
    if (length == 0) {
      await handle.writeFrom(_magic);
      await handle.flush();
      length = _magic.length;
    }
    await handle.setPosition(0);
    if (base64Encode(await handle.read(_magic.length)) !=
        base64Encode(_magic)) {
      throw const FormatException('Invalid group journal header.');
    }
    _end = _magic.length;
    while (_end < length) {
      if (length - _end < 4) {
        await handle.truncate(_end);
        await handle.flush();
        break;
      }
      await handle.setPosition(_end);
      final sizeBytes = await handle.read(4);
      final size = ByteData.sublistView(sizeBytes).getUint32(0);
      if (size < 28 || size > _maxFrame) {
        throw const FormatException('Invalid group journal frame length.');
      }
      if (length - _end - 4 < size) {
        await handle.truncate(_end);
        await handle.flush();
        break;
      }
      final event = await _decode(await handle.read(size), _end);
      await _checkSignature(event);
      _checkChain(event);
      _index(event, _end, size);
      _end += 4 + size;
    }
  }

  List<int> _aad(int offset) =>
      utf8.encode('conest.group-journal.v1|$groupId|$offset');

  Future<GroupHistoryEvent> _decode(Uint8List frame, int offset) async {
    final cleartext = await _cipher.decrypt(
      SecretBox(
        frame.sublist(12, frame.length - 16),
        nonce: frame.sublist(0, 12),
        mac: Mac(frame.sublist(frame.length - 16)),
      ),
      secretKey: key,
      aad: _aad(offset),
    );
    final event = GroupHistoryEvent.decode(utf8.decode(cleartext));
    if (event.groupId != groupId) {
      throw const FormatException('Group journal contains another group.');
    }
    return event;
  }

  Future<void> _checkSignature(GroupHistoryEvent event) async {
    if (event.groupId != groupId ||
        !await event.verify(
          expectedGroupId: groupId,
          expectedAccountId: event.authorAccountId,
          expectedDeviceId: event.authorDeviceId,
          expectedSigningKeyBase64: event.signingPublicKeyBase64,
        )) {
      throw const FormatException('Invalid group journal event signature.');
    }
  }

  void _checkChain(GroupHistoryEvent event) {
    final source = event.kind == GroupEventKind.message
        ? event.payload['messageId']
        : null;
    if (source is String) {
      final existing =
          _sourceMessages[jsonEncode([event.authorDeviceId, source])];
      if (existing != null && existing.id != event.eventId) {
        throw StateError('Conflicting group source message identity.');
      }
    }
    final author = _authors[event.authorDeviceId];
    if (author == null) return;
    final existing = author[event.sequence];
    final previous = author[event.sequence - 1];
    final next = author[event.sequence + 1];
    if ((existing != null && existing.id != event.eventId) ||
        (previous != null &&
            (previous.id != event.previousEventId ||
                previous.lamport >= event.lamport)) ||
        (next != null &&
            (next.previousId != event.eventId ||
                next.lamport <= event.lamport))) {
      throw StateError(
        'Conflicting group author history: ${event.authorDeviceId}/${event.sequence}.',
      );
    }
  }

  void _index(GroupHistoryEvent event, int offset, int size) {
    if (_entries.containsKey(event.eventId)) return;
    final entry = _JournalEntry(event, offset, size);
    _entries[entry.id] = entry;
    (_authors[event.authorDeviceId] ??= {})[event.sequence] = entry;
    if ((_authorHeads[event.authorDeviceId]?.sequence ?? 0) < event.sequence) {
      _authorHeads[event.authorDeviceId] = entry;
    }
    final source = event.kind == GroupEventKind.message
        ? event.payload['messageId']
        : null;
    if (source is String) {
      _sourceMessages[jsonEncode([event.authorDeviceId, source])] = entry;
    }
    var low = 0;
    var high = _ordered.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_ordered[middle].compareTo(entry) < 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    _ordered.insert(low, entry);
  }

  Future<bool> _append(String encoded) async {
    final event = GroupHistoryEvent.decode(encoded);
    await _checkSignature(event);
    _checkChain(event);
    if (_entries.containsKey(event.eventId)) return false;
    final box = await _cipher.encrypt(
      utf8.encode(encoded),
      secretKey: key,
      aad: _aad(_end),
    );
    final frame = Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    final size = ByteData(4)..setUint32(0, frame.length);
    final handle = _handle!;
    try {
      await handle.setPosition(_end);
      await handle.writeFrom(size.buffer.asUint8List());
      await handle.writeFrom(frame);
      await handle.flush();
    } catch (_) {
      try {
        await handle.truncate(_end);
        await handle.flush();
      } catch (_) {
        _poisoned = true;
      }
      rethrow;
    }
    _index(event, _end, frame.length);
    _end += 4 + frame.length;
    return true;
  }

  Future<List<GroupHistoryEvent>> _read(
    Iterable<_JournalEntry> entries,
    int limit,
  ) async {
    _checkLimit(limit, 128);
    final result = <GroupHistoryEvent>[];
    var bytes = 0;
    for (final entry in entries) {
      if (result.length == limit || bytes + entry.size > _pageBytes) break;
      await _handle!.setPosition(entry.offset + 4);
      final event = await _decode(
        await _handle!.read(entry.size),
        entry.offset,
      );
      result.add(event);
      bytes += entry.size;
    }
    return result;
  }

  Future<Object?> execute(String operation, Object? arguments) async {
    if (operation == 'close') {
      await close();
      return null;
    }
    if (_poisoned) throw StateError('Reopen the journal after an I/O failure.');
    if (operation == 'append') {
      return _append((arguments as GroupHistoryEvent).encode());
    }
    final args = arguments as List;
    switch (operation) {
      case 'authorHead':
      case 'sourceMessage':
        final entry = operation == 'authorHead'
            ? _authorHeads[args[0]]
            : _sourceMessages[jsonEncode(args)];
        return entry == null ? null : (await _read([entry], 1)).single;
      case 'syncProgress':
        return (await _loadSyncProgress())[args[0]] ?? <String, Object?>{};
      case 'saveSyncProgress':
        await _saveSyncProgress(
          args[0] as String,
          (args[1] as Map).cast<String, Object?>(),
        );
        return null;
      case 'retained':
        _checkLimit(args.length, 128);
        return args.cast<String>().where(_entries.containsKey).toList();
      case 'events':
        _checkLimit(args.length, 128);
        return _read(
          args
              .cast<String>()
              .toSet()
              .map((id) => _entries[id])
              .whereType<_JournalEntry>(),
          128,
        );
      case 'memberships':
        final afterId = args[0] as String?;
        final after = _entries[afterId];
        if (afterId != null && after == null) {
          throw ArgumentError('Unknown membership page cursor.');
        }
        return _read(
          _ordered.where(
            (entry) =>
                entry.kind == GroupEventKind.membership &&
                (after == null || entry.compareTo(after) > 0),
          ),
          args[1] as int,
        );
      case 'page':
        final beforeId = args[0] as String?;
        final before = _entries[beforeId];
        if (beforeId != null && before == null) {
          throw ArgumentError('Unknown group history page cursor.');
        }
        return _read(
          _ordered.reversed.where(
            (entry) => before == null || entry.compareTo(before) < 0,
          ),
          args[1] as int,
        );
      case 'authors':
        final after = args[0] as String?;
        final limit = args[1] as int;
        _checkLimit(limit, 128);
        final authors =
            _authors.keys
                .where((author) => after == null || author.compareTo(after) > 0)
                .toList()
              ..sort();
        return authors.take(limit).toList();
      case 'ranges':
        final after = args[1] as int;
        final limit = args[2] as int;
        _checkLimit(limit, 64);
        if (after < 0 || after > groupEventMaxCounter) {
          throw ArgumentError('Invalid range cursor.');
        }
        final sequences =
            (_authors[args[0]]?.keys ?? const <int>[])
                .where((sequence) => sequence > after)
                .toList()
              ..sort();
        final ranges = <List<int>>[];
        for (final sequence in sequences) {
          if (ranges.isNotEmpty && ranges.last[1] == sequence - 1) {
            ranges.last[1] = sequence;
          } else {
            if (ranges.length == limit) break;
            ranges.add([sequence, sequence]);
          }
        }
        return ranges;
      case 'range':
        final start = args[1] as int;
        final end = args[2] as int;
        if (start < 1 || end < start || end > groupEventMaxCounter) {
          throw ArgumentError('Invalid event range.');
        }
        final entries =
            (_authors[args[0]]?.values ?? const <_JournalEntry>[])
                .where(
                  (entry) => entry.sequence >= start && entry.sequence <= end,
                )
                .toList()
              ..sort((a, b) => a.sequence.compareTo(b.sequence));
        return _read(entries, args[3] as int);
      default:
        throw ArgumentError('Unknown group journal operation.');
    }
  }

  void _checkLimit(int limit, int maximum) {
    if (limit < 1 || limit > maximum) {
      throw ArgumentError('Invalid history page size.');
    }
  }

  Future<void> close() async {
    final handle = _handle;
    _handle = null;
    if (handle != null) await handle.close();
  }
}

class _JournalEntry implements Comparable<_JournalEntry> {
  _JournalEntry(GroupHistoryEvent event, this.offset, this.size)
    : id = event.eventId,
      author = event.authorDeviceId,
      sequence = event.sequence,
      previousId = event.previousEventId,
      lamport = event.lamport,
      kind = event.kind;

  final String id;
  final String author;
  final int sequence;
  final String? previousId;
  final int lamport;
  final GroupEventKind kind;
  final int offset;
  final int size;

  @override
  int compareTo(_JournalEntry other) {
    var result = lamport.compareTo(other.lamport);
    if (result != 0) return result;
    result = author.compareTo(other.author);
    if (result != 0) return result;
    result = sequence.compareTo(other.sequence);
    return result != 0 ? result : id.compareTo(other.id);
  }
}
