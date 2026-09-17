import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// Correlates encrypted group control requests with separately transported
/// binary pieces. Peer/group authentication belongs to the enclosing transport.
/// Each instance belongs to one signed attachment event in one group.
class GroupFileWire {
  GroupFileWire({
    required this.eventId,
    required this.send,
    required this.cancel,
    this.timeout = const Duration(seconds: 30),
  });

  final String eventId;
  final Future<void> Function(String peer, Map<String, Object?> control) send;

  /// Must stop/release the underlying request before completing.
  final Future<void> Function(String peer, String requestId) cancel;
  final Duration timeout;
  final _pending = <String, _PieceRequest>{};
  final _random = Random.secure();
  bool _closed = false;

  Future<Uint8List> requestPiece(
    String peer,
    int index,
    int expectedLength,
  ) async {
    if (_closed) throw StateError('Group file connection is closed.');
    if (_pending.length >= 4) {
      throw StateError('Group file request window is full.');
    }
    if (index < 0 ||
        index >= 512 ||
        expectedLength < 1 ||
        expectedLength > 4 * 1024 * 1024) {
      throw ArgumentError('Invalid group file piece geometry.');
    }
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final request = _PieceRequest(peer, index, expectedLength);
    _pending[id] = request;
    final result = request.result.future.timeout(timeout);
    // Install an error handler before transport work can yield. A timeout
    // includes connection establishment, not only the wait after sending.
    unawaited(
      Future.sync(
        () => send(peer, {
          'version': 1,
          'type': 'piece_request',
          'eventId': eventId,
          'requestId': id,
          'piece': index,
        }),
      ).catchError((Object error, StackTrace stack) {
        if (!request.result.isCompleted) {
          request.result.completeError(error, stack);
        }
      }),
    );
    try {
      return await result;
    } finally {
      request.accepting = false;
      try {
        await cancel(peer, id);
      } finally {
        _pending.remove(id);
      }
    }
  }

  /// Call after decrypting a binary frame and authenticating its source. A
  /// matching reply only satisfies transport correlation; storage still checks
  /// the original author's signed piece hash before acknowledging it.
  bool receive({
    required String peer,
    required String attachmentEventId,
    required String requestId,
    required int piece,
    required Uint8List bytes,
  }) {
    final request = _pending[requestId];
    if (_closed ||
        attachmentEventId != eventId ||
        request == null ||
        !request.accepting ||
        request.peer != peer ||
        request.index != piece ||
        request.length != bytes.length ||
        request.result.isCompleted) {
      return false;
    }
    request.result.complete(Uint8List.fromList(bytes));
    return true;
  }

  void unavailable({required String peer, required String requestId}) {
    final request = _pending[requestId];
    if (request != null &&
        request.peer == peer &&
        !request.result.isCompleted) {
      request.result.completeError(
        StateError('Waiting for someone with this file.'),
      );
    }
  }

  void close() {
    _closed = true;
    for (final request in _pending.values) {
      if (!request.result.isCompleted) {
        request.result.completeError(
          StateError('Group file connection closed.'),
        );
      }
    }
  }
}

class _PieceRequest {
  _PieceRequest(this.peer, this.index, this.length);
  final String peer;
  final int index;
  final int length;
  final result = Completer<Uint8List>();
  bool accepting = true;
}
