import 'dart:io';
import 'dart:typed_data';

import 'group_file_download.dart';
import 'group_file_manifest.dart';
import 'group_file_provider.dart';
import 'group_file_store.dart';
import 'group_file_transport.dart';
import 'models.dart';
import 'group_history_event.dart';

/// Owns one store and download per signed attachment identity. The enclosing
/// history replica must authenticate the author and membership in
/// [authorizeEvent]; the transport must authenticate every supplied peer ID.
/// Keep one service per account/root. Different events deliberately have
/// separate caches, even when their content hashes match.
class GroupFileService {
  GroupFileService({
    required this.root,
    required this.authorizeEvent,
    required this.authorizePeer,
    required this.receiveAllowed,
    required this.loadPreferences,
    required this.savePreferences,
    required this.sendEncrypted,
    required this.cancelAndDrain,
    this.onChanged,
  });

  final Directory root;
  final Future<bool> Function(GroupHistoryEvent event) authorizeEvent;
  final Future<bool> Function(GroupHistoryEvent event, String peer)
  authorizePeer;

  /// Current route, reachability, receive settings and storage policy.
  final bool Function(GroupHistoryEvent event, String peer, bool lan)
  receiveAllowed;
  final Future<GroupFilePreference> Function(GroupHistoryEvent event)
  loadPreferences;
  final Future<void> Function(
    GroupHistoryEvent event,
    GroupFilePreference preferences,
  )
  savePreferences;
  final Future<void> Function(
    GroupHistoryEvent event,
    String peer,
    String operationId,
    Uint8List frame,
  )
  sendEncrypted;
  final Future<void> Function(
    GroupHistoryEvent event,
    String peer,
    String requestId,
  )
  cancelAndDrain;
  final void Function(String eventId)? onChanged;
  final _sessions = <String, Future<GroupFileSession>>{};
  bool _closed = false;

  Future<GroupFileSession> register(GroupHistoryEvent event) {
    if (_closed) {
      return Future.error(StateError('Group file service is closed.'));
    }
    final existing = _sessions[event.eventId];
    if (existing != null) return existing;
    final result = _register(event);
    _sessions[event.eventId] = result;
    // A failed authorization or storage read can be retried later.
    result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        if (identical(_sessions[event.eventId], result)) {
          _sessions.remove(event.eventId);
        }
      },
    );
    return result;
  }

  Future<GroupFileSession> _register(GroupHistoryEvent event) async {
    final manifest = GroupFileManifest.fromEvent(event);
    if (!await authorizeEvent(event)) {
      throw StateError('Group attachment is not authorized.');
    }
    final preferences = await loadPreferences(event);
    if (_closed) throw StateError('Group file service is closed.');
    if (preferences.groupId != event.groupId ||
        preferences.eventId != event.eventId) {
      throw StateError('Group file preference identity mismatch.');
    }
    return GroupFileSession._(this, event, manifest, preferences);
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(
      _sessions.values.map((pending) async {
        GroupFileSession session;
        try {
          session = await pending;
        } catch (_) {
          return;
        }
        await session.close();
      }),
    );
  }
}

class GroupFileSession {
  GroupFileSession._(
    this._service,
    this.event,
    this.manifest,
    this._preferences,
  ) {
    store = GroupFileStore(
      root: Directory('${_service.root.path}/${event.eventId}'),
      manifest: manifest,
    );
    provider = GroupFileProvider(
      store: store,
      authorize: _authorize,
      sharing: _preferences.sharing,
      persistSharing: (sharing) => _save(sharing: sharing),
    );
    transport = GroupFileTransport(
      groupId: event.groupId,
      eventId: event.eventId,
      sendEncrypted: (peer, id, frame) =>
          _service.sendEncrypted(event, peer, id, frame),
      cancelAndDrain: (peer, id) => _service.cancelAndDrain(event, peer, id),
      authorized: _authorize,
      availablePieces: provider.availability,
      readPiece: provider.readPiece,
    );
    download = GroupFileDownload(
      store: store,
      fetch: (request) => transport.requestPiece(
        request.peer,
        request.piece,
        manifest.lengthOf(request.piece),
      ),
      allowed: (peer, lan) =>
          !_closed &&
          !_pauseRequested &&
          !_preferences.paused &&
          (_preferences.accepted || manifest.automaticallyDownload(lan: lan)) &&
          _service.receiveAllowed(event, peer, lan),
      authorize: _authorize,
      onChanged: _changed,
    );
    if (_preferences.paused) download.pause();
  }

  final GroupFileService _service;
  final GroupHistoryEvent event;
  final GroupFileManifest manifest;
  late final GroupFileStore store;
  late final GroupFileTransport transport;
  late final GroupFileProvider provider;
  late final GroupFileDownload download;
  GroupFilePreference _preferences;
  GroupFilePreference get preferences => _preferences;
  Future<void> _settings = Future.value();
  Future<void>? _waking;
  bool _wakeRequested = false;
  bool _pauseRequested = false;
  bool _closed = false;
  int _pauseGeneration = 0;

  Future<bool> _authorize(String peer) async =>
      !_closed &&
      await _service.authorizeEvent(event) &&
      await _service.authorizePeer(event, peer) &&
      !_closed;

  void _changed() => _service.onChanged?.call(event.eventId);

  Future<void> _save({
    bool? accepted,
    bool? paused,
    bool? sharing,
    bool? reserveOverride,
  }) {
    final result = _settings.then((_) async {
      final next = _preferences.copyWith(
        accepted: accepted ?? _preferences.accepted,
        paused: paused ?? _preferences.paused,
        sharing: sharing ?? _preferences.sharing,
        reserveOverride: reserveOverride,
      );
      await _service.savePreferences(event, next);
      _preferences = next;
      _changed();
    });
    _settings = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> setAccepted(bool accepted, {bool? reserveOverride}) async {
    await _save(accepted: accepted, reserveOverride: reserveOverride);
    await wake();
  }

  Future<void> setPaused(bool paused) async {
    final generation = ++_pauseGeneration;
    if (paused) {
      _pauseRequested = true;
      download.pause();
    }
    await _save(paused: paused);
    if (generation != _pauseGeneration) return;
    _pauseRequested = paused;
    if (!paused) await wake();
  }

  Future<void> setSharing(bool sharing) async {
    await provider.setSharing(sharing);
    _changed();
  }

  /// Remove local pieces without removing the signed group attachment event.
  Future<void> evict() async {
    await download.evict();
    _changed();
  }

  /// Supply authenticated discovery advertisements only. Authorization is
  /// rechecked here and again before each fetch and durable write.
  Future<void> updateProvider(
    String peer,
    Iterable<int> pieces, {
    required bool lan,
  }) async {
    final owned = pieces.toList(growable: false);
    if (!await _authorize(peer)) {
      removeProvider(peer);
      return;
    }
    download.scheduler.updateProvider(peer, owned, lan: lan);
    await wake();
  }

  Future<void> discoverProvider(String peer, {required bool lan}) async {
    if (!await _authorize(peer)) return;
    final pieces = await transport.queryAvailability(peer);
    await updateProvider(peer, pieces, lan: lan);
  }

  /// Import an app-owned staged copy; each piece and the complete file are
  /// verified against the signed manifest before reporting completion.
  Future<File> seedExisting(String path) async {
    if (_closed || !await _service.authorizeEvent(event)) {
      throw StateError('Group attachment is not authorized.');
    }
    final input = await File(path).open();
    try {
      if (await input.length() != manifest.sizeBytes) {
        throw const FormatException('Group file size mismatch.');
      }
      for (var piece = 0; piece < manifest.pieceHashes.length; piece++) {
        final bytes = await input.read(manifest.lengthOf(piece));
        if (_closed || !await _service.authorizeEvent(event)) {
          throw StateError('Group attachment is not authorized.');
        }
        await store.writePiece(piece, bytes);
      }
    } finally {
      await input.close();
    }
    final completed = await store.assemble();
    download.scheduler.restoreVerified(await store.recover());
    _changed();
    return completed;
  }

  void removeProvider(String peer) => download.scheduler.removeProvider(peer);

  /// Invoke after discovery, route, membership or storage policy changes.
  /// Remember wakeups arriving during an active batch to avoid lost resumes.
  Future<void> wake() {
    if (_closed || _pauseRequested || _preferences.paused) {
      return Future.value();
    }
    _wakeRequested = true;
    return _waking ??= _pump().whenComplete(() => _waking = null);
  }

  Future<void> _pump() async {
    while (_wakeRequested &&
        !_closed &&
        !_pauseRequested &&
        !_preferences.paused) {
      _wakeRequested = false;
      await download.resume();
    }
  }

  Future<void> close() async {
    _closed = true;
    download.pause();
    await transport.close();
    await _waking;
    await _settings;
  }
}
