import 'group_file_manifest.dart';

/// Scheduling only: callers supply authenticated, currently authorized peers
/// and recheck transport/storage policy before dispatching each reservation.
class GroupFileScheduler {
  GroupFileScheduler(this.manifest);
  final GroupFileManifest manifest;
  final _providers = <String, _Provider>{};
  final _requests = <int, GroupPieceRequest>{};
  final _verified = <int>{};
  int _generation = 0;

  int get verifiedBytes =>
      _verified.fold(0, (sum, piece) => sum + manifest.lengthOf(piece));
  bool get complete => _verified.length == manifest.pieceHashes.length;
  Set<int> get verifiedPieces => Set.unmodifiable(_verified);

  void updateProvider(String peer, Iterable<int> pieces, {required bool lan}) {
    final available = pieces.toSet();
    for (final piece in available) {
      manifest.lengthOf(piece);
    }
    _providers[peer] = _Provider(available, lan);
    _requests.removeWhere(
      (piece, request) => request.peer == peer && !available.contains(piece),
    );
  }

  void removeProvider(String peer) {
    _providers.remove(peer);
    _requests.removeWhere((_, request) => request.peer == peer);
  }

  /// Reserve at most four pieces / 16 MiB, using at most three providers.
  /// Offline or disallowed providers do not make a piece appear available.
  List<GroupPieceRequest> reserve(
    DateTime now, {
    required bool Function(String peer, bool lan) allowed,
    Duration timeout = const Duration(seconds: 15),
  }) {
    final stalled = _requests.values
        .where((r) => !now.isBefore(r.deadline))
        .toList();
    for (final request in stalled) {
      removeProvider(request.peer);
    }
    _requests.removeWhere(
      (_, r) => !allowed(r.peer, _providers[r.peer]?.lan ?? false),
    );
    final result = <GroupPieceRequest>[];
    while (_requests.length < 4) {
      final active = _requests.values.map((r) => r.peer).toSet();
      final candidates = <int, List<String>>{};
      for (var piece = 0; piece < manifest.pieceHashes.length; piece++) {
        if (_verified.contains(piece) || _requests.containsKey(piece)) continue;
        final peers = _providers.keys
            .where(
              (peer) =>
                  _providers[peer]!.pieces.contains(piece) &&
                  allowed(peer, _providers[peer]!.lan) &&
                  (active.length < 3 || active.contains(peer)),
            )
            .toList();
        if (peers.isNotEmpty) candidates[piece] = peers;
      }
      if (candidates.isEmpty) break;
      final pieces = candidates.keys.toList()
        ..sort((a, b) {
          final scarcity = candidates[a]!.length.compareTo(
            candidates[b]!.length,
          );
          return scarcity != 0 ? scarcity : a.compareTo(b);
        });
      final piece = pieces.first;
      final peers = candidates[piece]!;
      int load(String peer) =>
          _requests.values.where((r) => r.peer == peer).length;
      peers.sort((a, b) {
        final locality = (_providers[a]!.lan ? 0 : 1).compareTo(
          _providers[b]!.lan ? 0 : 1,
        );
        if (locality != 0) return locality;
        final balance = load(a).compareTo(load(b));
        return balance != 0 ? balance : a.compareTo(b);
      });
      final request = GroupPieceRequest(
        piece,
        peers.first,
        ++_generation,
        now.add(timeout),
      );
      _requests[piece] = request;
      result.add(request);
    }
    return result;
  }

  /// Call only AFTER hash verification and durable write by the storage worker.
  /// Tokens prevent late replies from completing a replacement reservation.
  bool markDurable(GroupPieceRequest request) {
    if (_requests[request.piece] != request) return false;
    _requests.remove(request.piece);
    return _verified.add(request.piece);
  }

  void failed(GroupPieceRequest request) {
    if (_requests[request.piece] == request) removeProvider(request.peer);
  }

  /// Recovery must verify retained bytes against the manifest before calling.
  void restoreVerified(Iterable<int> pieces) {
    final checked = pieces.toSet();
    for (final piece in checked) {
      manifest.lengthOf(piece);
    }
    _verified.addAll(checked);
    _requests.removeWhere((piece, _) => checked.contains(piece));
  }
}

class GroupPieceRequest {
  const GroupPieceRequest(
    this.piece,
    this.peer,
    this.generation,
    this.deadline,
  );
  final int piece;
  final String peer;
  final int generation;
  final DateTime deadline;
}

class _Provider {
  const _Provider(this.pieces, this.lan);
  final Set<int> pieces;
  final bool lan;
}
