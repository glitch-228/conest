import 'group_file_manifest.dart';

/// Scheduling only: callers supply authenticated, currently authorized peers
/// and recheck transport/storage policy before dispatching each reservation.
class GroupFileScheduler {
  GroupFileScheduler(
    this.manifest, {
    this.minHedgeDelay = const Duration(seconds: 3),
    this.maxHedgeShare = 0.2,
    this.maxHedgesInFlight = 2,
  });
  final GroupFileManifest manifest;

  /// A piece that is late may also be asked of a second provider, but not
  /// sooner than this, and only within a share of the bytes already fetched.
  final Duration minHedgeDelay;
  final double maxHedgeShare;
  final int maxHedgesInFlight;
  final _providers = <String, _Provider>{};
  final _requests = <int, GroupPieceRequest>{};
  final _hedges = <int, GroupPieceRequest>{};
  int _deliveredBytes = 0;
  int _hedgedBytes = 0;

  /// Speeds assumed until a provider has delivered a piece: a provider on
  /// the local network is expected to be faster than one over the internet.
  static const double _lanPriorBytesPerSecond = 8 * 1024 * 1024;
  static const double _netPriorBytesPerSecond = 1024 * 1024;
  final _verified = <int>{};
  final _blockedRequests = <String, DateTime>{};
  int _generation = 0;

  static const Duration _failedPieceCooldown = Duration(seconds: 30);

  int get verifiedBytes =>
      _verified.fold(0, (sum, piece) => sum + manifest.lengthOf(piece));
  bool isVerified(int piece) => _verified.contains(piece);
  bool get complete => _verified.length == manifest.pieceHashes.length;
  Set<int> get verifiedPieces => Set.unmodifiable(_verified);

  /// Drop runtime availability after a deliberate local cache eviction. The
  /// signed manifest remains owned by the session and can be downloaded again.
  void reset() {
    _providers.clear();
    _requests.clear();
    _hedges.clear();
    _verified.clear();
    _blockedRequests.clear();
    _deliveredBytes = 0;
    _hedgedBytes = 0;
    _generation++;
  }

  bool stillAllowed(
    GroupPieceRequest request,
    bool Function(String peer, bool lan) allowed,
  ) {
    final provider = _providers[request.peer];
    return _isCurrent(request) &&
        provider != null &&
        allowed(request.peer, provider.lan);
  }

  void updateProvider(String peer, Iterable<int> pieces, {required bool lan}) {
    final available = pieces.toSet();
    for (final piece in available) {
      manifest.lengthOf(piece);
    }
    final before = _providers[peer];
    _providers[peer] = _Provider(available, lan)
      ..bytesPerSecond = before?.bytesPerSecond
      ..samples = before?.samples ?? 0;
    // A fresh authenticated availability response means the peer is back;
    // do not keep a transient piece failure quarantined across rediscovery.
    _blockedRequests.removeWhere((key, _) => key.startsWith('$peer|'));
    _dropRequests(
      (request) => request.peer == peer && !available.contains(request.piece),
    );
  }

  void removeProvider(String peer) {
    _providers.remove(peer);
    _dropRequests((request) => request.peer == peer);
    _blockedRequests.removeWhere((key, _) => key.startsWith('$peer|'));
  }

  /// Reserve at most four pieces / 16 MiB, using at most three providers.
  /// Offline or disallowed providers do not make a piece appear available.
  List<GroupPieceRequest> reserve(
    DateTime now, {
    required bool Function(String peer, bool lan) allowed,
    Duration timeout = const Duration(seconds: 15),
  }) {
    _blockedRequests.removeWhere((_, until) => !now.isBefore(until));
    final stalled = [
      ..._requests.values,
      ..._hedges.values,
    ].where((r) => !now.isBefore(r.deadline)).toList();
    for (final request in stalled) {
      _end(request);
      _block(request.peer, request.piece, now);
    }
    _dropRequests((r) => !allowed(r.peer, _providers[r.peer]?.lan ?? false));
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
                  !_isBlocked(peer, piece, now) &&
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
      peers.sort(_byScore);
      final request = GroupPieceRequest(
        piece,
        peers.first,
        ++_generation,
        now.add(timeout),
        issuedAt: now,
      );
      _requests[piece] = request;
      result.add(request);
    }
    return result;
  }

  /// Call only AFTER hash verification and durable write by the storage worker.
  /// Tokens prevent late replies from completing a replacement reservation.
  /// The first of a piece's requests (it and its hedge) to finish wins; the
  /// speed of its provider is learned from how long it took.
  bool markDurable(GroupPieceRequest request, {DateTime? now}) {
    if (!_isCurrent(request)) return false;
    final primary = _requests.remove(request.piece);
    final hedge = _hedges.remove(request.piece);
    for (final other in [primary, hedge]) {
      if (other != null) {
        _blockedRequests.remove(_key(other.peer, other.piece));
      }
    }
    final length = manifest.lengthOf(request.piece);
    final issued = request.issuedAt;
    final provider = _providers[request.peer];
    if (provider != null && issued != null) {
      final seconds =
          (now ?? DateTime.now().toUtc()).difference(issued).inMicroseconds /
          1e6;
      if (seconds > 0) provider.learn(length / seconds);
    }
    if (_verified.add(request.piece)) {
      _deliveredBytes += length;
      return true;
    }
    return false;
  }

  void failed(GroupPieceRequest request) {
    if (!_isCurrent(request)) return;
    _end(request);
    _block(request.peer, request.piece, DateTime.now().toUtc());
  }

  /// A second request for a piece that [primary] is late with, to another
  /// provider that has it; null when [primary] is not outstanding, the piece
  /// was already hedged, the hedging budget is spent, or nobody else can.
  GroupPieceRequest? hedge(
    GroupPieceRequest primary,
    DateTime now, {
    required bool Function(String peer, bool lan) allowed,
    Duration timeout = const Duration(seconds: 15),
  }) {
    final piece = primary.piece;
    if (_requests[piece] != primary || _hedges.containsKey(piece)) return null;
    final length = manifest.lengthOf(piece);
    // The first hedge of a download is free (nothing is fetched yet to
    // take a share of); later ones stay within [maxHedgeShare].
    if (_hedges.length >= maxHedgesInFlight ||
        (_hedgedBytes > 0 &&
            _hedgedBytes + length >
                (_deliveredBytes + length) * maxHedgeShare)) {
      return null;
    }
    final active = _requests.values.map((r) => r.peer).toSet();
    final peers = _providers.keys
        .where(
          (peer) =>
              peer != primary.peer &&
              _providers[peer]!.pieces.contains(piece) &&
              !_isBlocked(peer, piece, now) &&
              allowed(peer, _providers[peer]!.lan) &&
              (active.length < 3 || active.contains(peer)),
        )
        .toList();
    if (peers.isEmpty) return null;
    peers.sort(_byScore);
    final request = GroupPieceRequest(
      piece,
      peers.first,
      ++_generation,
      now.add(timeout),
      issuedAt: now,
    );
    _hedges[piece] = request;
    _hedgedBytes += length;
    return request;
  }

  /// How long [request] may take before it is worth asking a second
  /// provider: twice what its provider's speed predicts, at least
  /// [minHedgeDelay].
  Duration hedgeDelayFor(GroupPieceRequest request) {
    final provider = _providers[request.peer];
    final speed = provider?.speed ?? _netPriorBytesPerSecond;
    final expected = Duration(
      microseconds: (manifest.lengthOf(request.piece) / speed * 2e6).round(),
    );
    return expected > minHedgeDelay ? expected : minHedgeDelay;
  }

  /// Whether [request] is still wanted: not finished, failed or replaced.
  bool isCurrent(GroupPieceRequest request) => _isCurrent(request);

  /// Measured speed of [peer] in bytes a second, or its assumed one.
  double speedOf(String peer) =>
      _providers[peer]?.speed ?? _netPriorBytesPerSecond;

  bool _isCurrent(GroupPieceRequest request) =>
      _requests[request.piece] == request || _hedges[request.piece] == request;

  /// [request] is over (failed or stalled). A failed primary hands its
  /// piece to its hedge, if there is one.
  void _end(GroupPieceRequest request) {
    if (_hedges[request.piece] == request) {
      _hedges.remove(request.piece);
    } else if (_requests[request.piece] == request) {
      final hedge = _hedges.remove(request.piece);
      if (hedge != null) {
        _requests[request.piece] = hedge;
      } else {
        _requests.remove(request.piece);
      }
    }
  }

  void _dropRequests(bool Function(GroupPieceRequest request) test) {
    for (final request in [
      ..._hedges.values,
      ..._requests.values,
    ].where(test).toList()) {
      _end(request);
    }
  }

  /// Providers best first: faster, shared with the pieces already on them.
  int _byScore(String a, String b) {
    double score(String peer) =>
        _providers[peer]!.speed /
        (_requests.values.where((r) => r.peer == peer).length +
            _hedges.values.where((r) => r.peer == peer).length +
            1);
    final byScore = score(b).compareTo(score(a));
    return byScore != 0 ? byScore : a.compareTo(b);
  }

  /// Recovery must verify retained bytes against the manifest before calling.
  void restoreVerified(Iterable<int> pieces) {
    final checked = pieces.toSet();
    for (final piece in checked) {
      manifest.lengthOf(piece);
    }
    _verified.addAll(checked);
    for (final request in [..._requests.values, ..._hedges.values]) {
      if (!checked.contains(request.piece)) continue;
      _blockedRequests.remove(_key(request.peer, request.piece));
    }
    _requests.removeWhere((piece, _) => checked.contains(piece));
    _hedges.removeWhere((piece, _) => checked.contains(piece));
  }

  String _key(String peer, int piece) => '$peer|$piece';

  bool _isBlocked(String peer, int piece, DateTime now) {
    final until = _blockedRequests[_key(peer, piece)];
    return until != null && now.isBefore(until);
  }

  void _block(String peer, int piece, DateTime now) {
    _blockedRequests[_key(peer, piece)] = now.add(_failedPieceCooldown);
  }
}

class GroupPieceRequest {
  const GroupPieceRequest(
    this.piece,
    this.peer,
    this.generation,
    this.deadline, {
    this.issuedAt,
  });
  final int piece;
  final String peer;
  final int generation;
  final DateTime deadline;
  final DateTime? issuedAt;
}

class _Provider {
  _Provider(this.pieces, this.lan);
  final Set<int> pieces;
  final bool lan;
  double? bytesPerSecond;
  int samples = 0;

  double get speed =>
      bytesPerSecond ??
      (lan
          ? GroupFileScheduler._lanPriorBytesPerSecond
          : GroupFileScheduler._netPriorBytesPerSecond);

  void learn(double sample) {
    final before = bytesPerSecond;
    bytesPerSecond = before == null ? sample : before * 0.7 + sample * 0.3;
    samples++;
  }
}
