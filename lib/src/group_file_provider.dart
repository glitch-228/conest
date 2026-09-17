import 'dart:typed_data';

import 'group_file_store.dart';

/// Serves a single signed file identity. The service owning this provider binds
/// [authorize] to its group/event ID and the authenticated requesting peer.
class GroupFileProvider {
  GroupFileProvider({
    required this.store,
    required this.authorize,
    required this.persistSharing,
    required bool sharing,
  }) : _sharing = sharing;

  final GroupFileStore store;
  final Future<bool> Function(String peer) authorize;
  final Future<void> Function(bool sharing) persistSharing;
  bool _sharing;
  int _generation = 0;
  int _reading = 0;
  Future<Set<int>>? _checking;
  Future<void> _settings = Future.value();

  bool get sharing => _sharing;

  /// Disables immediately, including requests already awaiting disk reads.
  /// Enabling waits for persistence so a failed save cannot silently enable it.
  Future<void> setSharing(bool value) {
    final generation = ++_generation;
    if (!value) _sharing = false;
    final result = _settings.then((_) async {
      await persistSharing(value);
      if (generation == _generation) _sharing = value;
    });
    _settings = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Set<int>> availability(String peer) async {
    final generation = _generation;
    if (!_sharing || !await authorize(peer)) return {};
    final checking = _checking ??= store.recover();
    Set<int> pieces;
    try {
      pieces = await checking;
    } finally {
      if (identical(_checking, checking)) _checking = null;
    }
    if (!_sharing || generation != _generation || !await authorize(peer)) {
      return {};
    }
    return Set.unmodifiable(pieces);
  }

  Future<Uint8List?> readPiece(String peer, int index) async {
    store.manifest.lengthOf(index);
    if (_reading >= 4) throw StateError('Group file provider is busy.');
    final generation = _generation;
    _reading++;
    try {
      if (!_sharing || !await authorize(peer)) return null;
      final bytes = await store.readPiece(index);
      if (!_sharing || generation != _generation || !await authorize(peer)) {
        return null;
      }
      return bytes;
    } finally {
      _reading--;
    }
  }
}
