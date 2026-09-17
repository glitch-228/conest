import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'group_file_wire.dart';

/// A bounded protocol over an authenticated, encrypted binary channel.
///
/// [sendEncrypted] must encrypt the complete frame for [peer], and [receive]
/// must only be called after authenticating that peer and decrypting its frame.
/// [cancelAndDrain] must release and join underlying sends before returning;
/// TransportAdapter.cancel alone does not currently guarantee this on Iroh.
class GroupFileTransport {
  GroupFileTransport({
    required this.groupId,
    required this.eventId,
    required this.sendEncrypted,
    required this.cancelAndDrain,
    required this.authorized,
    this.availablePieces,
    this.readPiece,
    this.timeout = const Duration(seconds: 30),
  }) {
    _wire = GroupFileWire(
      eventId: eventId,
      timeout: timeout,
      send: (peer, control) => _send(peer, control),
      cancel: cancelAndDrain,
    );
  }

  final String groupId;
  final String eventId;
  final Future<void> Function(String peer, String operationId, Uint8List frame)
  sendEncrypted;
  final Future<void> Function(String peer, String operationId) cancelAndDrain;
  final FutureOr<bool> Function(String peer) authorized;
  final Future<Set<int>> Function(String peer)? availablePieces;
  final Future<Uint8List?> Function(String peer, int piece)? readPiece;
  final Duration timeout;
  late final GroupFileWire _wire;
  final _queries = <String, _AvailabilityRequest>{};
  final _serving = <String>{};
  final _tasks = <Future<void>>{};
  final _sends = <String, String>{};
  final _random = Random.secure();
  bool _closed = false;

  Future<Uint8List> requestPiece(
    String peer,
    int index,
    int expectedLength,
  ) async {
    await _check(peer);
    return _wire.requestPiece(peer, index, expectedLength);
  }

  Future<Set<int>> queryAvailability(String peer) async {
    await _check(peer);
    if (_queries.length >= 4) throw StateError('Availability window is full.');
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final query = _AvailabilityRequest(peer);
    _queries[id] = query;
    final result = query.result.future.timeout(timeout);
    // Handle the result before any asynchronous channel work can fail.
    unawaited(
      _send(peer, {
        'type': 'availability_request',
        'requestId': id,
      }).catchError((Object error, StackTrace stack) {
        if (!query.result.isCompleted) query.result.completeError(error, stack);
      }),
    );
    try {
      return await result;
    } finally {
      query.accepting = false;
      try {
        await cancelAndDrain(peer, id);
      } finally {
        _queries.remove(id);
      }
    }
  }

  Future<void> _check(String peer) async {
    if (!await authorized(peer) || _closed) {
      throw StateError('Group file peer is unavailable or unauthorized.');
    }
  }

  Future<void> _send(
    String peer,
    Map<String, Object?> header, [
    Uint8List? bytes,
  ]) async {
    await _check(peer);
    final id = header['requestId']! as String;
    final metadata = utf8.encode(
      jsonEncode({
        ...header,
        'version': 1,
        'groupId': groupId,
        'eventId': eventId,
      }),
    );
    if (metadata.length > 8192 || (bytes?.length ?? 0) > 4 * 1024 * 1024) {
      throw const FormatException('Group file frame is too large.');
    }
    final frame = Uint8List(4 + metadata.length + (bytes?.length ?? 0));
    ByteData.sublistView(frame).setUint32(0, metadata.length);
    frame.setRange(4, 4 + metadata.length, metadata);
    if (bytes != null) frame.setRange(4 + metadata.length, frame.length, bytes);
    final key = '$peer:$id';
    _sends[key] = peer;
    try {
      await sendEncrypted(peer, id, frame);
    } finally {
      _sends.remove(key);
    }
  }

  /// Returns false for malformed, unrelated, unauthorized, or stale frames.
  Future<bool> receive(String peer, Uint8List frame) async {
    if (!await authorized(peer) ||
        _closed ||
        frame.length < 4 ||
        frame.length > 4 * 1024 * 1024 + 8196) {
      return false;
    }
    try {
      final size = ByteData.sublistView(frame).getUint32(0);
      if (size > 8192 || size + 4 > frame.length) return false;
      final header = jsonDecode(utf8.decode(frame.sublist(4, size + 4)));
      if (header is! Map<String, dynamic> ||
          header['version'] != 1 ||
          header['groupId'] != groupId ||
          header['eventId'] != eventId) {
        return false;
      }
      final id = header['requestId'];
      if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
        return false;
      }
      final bytes = Uint8List.sublistView(frame, size + 4);
      switch (header['type']) {
        case 'piece':
          final piece = header['piece'];
          return piece is int &&
              _wire.receive(
                peer: peer,
                attachmentEventId: eventId,
                requestId: id,
                piece: piece,
                bytes: bytes,
              );
        case 'unavailable':
          if (bytes.isNotEmpty) return false;
          _wire.unavailable(peer: peer, requestId: id);
          return true;
        case 'availability':
          final query = _queries[id];
          final pieces = header['pieces'];
          if (bytes.isNotEmpty ||
              query == null ||
              !query.accepting ||
              query.peer != peer ||
              query.result.isCompleted ||
              pieces is! List ||
              pieces.length > 512 ||
              pieces.any((p) => p is! int || p < 0 || p >= 512)) {
            return false;
          }
          query.result.complete(Set<int>.unmodifiable(pieces.cast<int>()));
          return true;
        case 'availability_request':
        case 'piece_request':
          if (bytes.isNotEmpty || _serving.length >= 4) return false;
          final piece = header['piece'];
          if (header['type'] == 'piece_request' &&
              (piece is! int || piece < 0 || piece >= 512)) {
            return false;
          }
          final key = '$peer:$id';
          if (!_serving.add(key)) return false;
          final task = _serve(
            peer,
            id,
            header['type'] as String,
            piece is int ? piece : null,
          );
          _tasks.add(task);
          try {
            await task;
          } finally {
            _tasks.remove(task);
            _serving.remove(key);
          }
          return true;
        default:
          return false;
      }
    } on FormatException {
      return false;
    }
  }

  Future<void> _serve(String peer, String id, String type, int? piece) async {
    if (type == 'availability_request') {
      final pieces = await availablePieces?.call(peer) ?? <int>{};
      if (pieces.length > 512 || pieces.any((p) => p < 0 || p >= 512)) {
        throw StateError('Invalid local piece availability.');
      }
      if (!await authorized(peer) || _closed) return;
      await _send(peer, {
        'type': 'availability',
        'requestId': id,
        'pieces': pieces.toList()..sort(),
      });
    } else {
      final bytes = await readPiece?.call(peer, piece!);
      if (!await authorized(peer) || _closed) return;
      await _send(peer, {
        'type': bytes == null ? 'unavailable' : 'piece',
        'requestId': id,
        'piece': piece,
      }, bytes);
    }
  }

  Future<void> close() async {
    _closed = true;
    _wire.close();
    for (final query in _queries.values) {
      if (!query.result.isCompleted) {
        query.result.completeError(StateError('Group file connection closed.'));
      }
    }
    await Future.wait(
      _sends.entries.toList().map(
        (entry) => cancelAndDrain(
          entry.value,
          entry.key.substring(entry.value.length + 1),
        ),
      ),
    );
    await Future.wait(_tasks.toList());
  }
}

class _AvailabilityRequest {
  _AvailabilityRequest(this.peer);
  final String peer;
  final result = Completer<Set<int>>();
  bool accepting = true;
}
