import 'dart:io';
import 'dart:typed_data';

import 'group_file_scheduler.dart';
import 'group_file_store.dart';

enum GroupFileDownloadState {
  checking,
  waiting,
  downloading,
  paused,
  complete,
  failed,
}

/// One bounded download session. The transport callback must return only after
/// releasing its request resources, including on timeout/cancellation. Policy
/// combines current membership, explicit acceptance, route limits and storage.
class GroupFileDownload {
  GroupFileDownload({
    required this.store,
    required this.fetch,
    required this.allowed,
    required this.authorize,
    this.onChanged,
  }) : scheduler = GroupFileScheduler(store.manifest);

  final GroupFileStore store;
  final GroupFileScheduler scheduler;
  final Future<Uint8List> Function(GroupPieceRequest request) fetch;
  final bool Function(String peer, bool lan) allowed;
  final Future<bool> Function(String peer) authorize;
  final void Function()? onChanged;
  GroupFileDownloadState state = GroupFileDownloadState.checking;
  Object? lastError;
  File? completedFile;
  Future<void>? _running;
  bool _recovered = false;
  bool _paused = false;

  int get verifiedBytes => scheduler.verifiedBytes;

  /// Surface a storage/policy failure without discarding verified partial
  /// pieces. The caller can change policy and resume the same session.
  void fail(Object error) {
    lastError = error;
    state = GroupFileDownloadState.failed;
    onChanged?.call();
  }

  void pause() {
    _paused = true;
    state = GroupFileDownloadState.paused;
    onChanged?.call();
  }

  /// Caller invokes again when a provider appears or accepted policy changes.
  /// Simultaneous wakeups share one pump, preserving the four-request cap.
  Future<void> resume() {
    _paused = false;
    final active = _running;
    if (active != null) return active;
    final result = _pump();
    _running = result;
    return result.whenComplete(() => _running = null);
  }

  /// Stop current requests and remove this device's verified cache. The
  /// conversation metadata is deliberately preserved by the caller.
  Future<void> evict() async {
    _paused = true;
    state = GroupFileDownloadState.paused;
    onChanged?.call();
    final running = _running;
    if (running != null) {
      try {
        await running;
      } catch (_) {
        // The session is being reset; a request failure is not destructive.
      }
    }
    await store.evict();
    scheduler.reset();
    completedFile = null;
    lastError = null;
    _recovered = true;
    _paused = false;
    state = GroupFileDownloadState.waiting;
    onChanged?.call();
  }

  Future<void> _pump() async {
    try {
      if (!_recovered) {
        scheduler.restoreVerified(await store.recover());
        _recovered = true;
      }
      while (!_paused && !scheduler.complete) {
        final requests = scheduler.reserve(
          DateTime.now().toUtc(),
          allowed: allowed,
        );
        if (requests.isEmpty) {
          state = GroupFileDownloadState.waiting;
          onChanged?.call();
          return;
        }
        state = GroupFileDownloadState.downloading;
        onChanged?.call();
        // Await the full bounded batch before reserving replacements. A timeout
        // must not accumulate unbounded, still-live transport operations.
        await Future.wait(requests.map(_receive));
      }
      if (!_paused && scheduler.complete) {
        completedFile = await store.assemble();
        state = GroupFileDownloadState.complete;
        lastError = null;
      }
    } catch (error) {
      lastError = error;
      state = GroupFileDownloadState.failed;
    } finally {
      if (_paused) state = GroupFileDownloadState.paused;
      onChanged?.call();
    }
  }

  Future<void> _receive(GroupPieceRequest request) async {
    try {
      if (_paused ||
          !scheduler.stillAllowed(request, allowed) ||
          !await authorize(request.peer)) {
        scheduler.failed(request);
        return;
      }
      final bytes = await fetch(request);
      // Authorization may change while data is in flight. Do not commit or
      // advertise those bytes after learning about a removal.
      if (_paused ||
          !scheduler.stillAllowed(request, allowed) ||
          !await authorize(request.peer)) {
        scheduler.failed(request);
        return;
      }
      await store.writePiece(request.piece, bytes);
      scheduler.markDurable(request);
      onChanged?.call();
    } catch (error) {
      lastError = error;
      scheduler.failed(request);
    }
  }
}
