import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'group_history_event.dart';
import 'group_history_sync.dart';

/// Correlates catch-up RPCs inside authenticated encrypted group envelopes.
/// No transport acceptance is interpreted as a recipient response or receipt.
class GroupHistoryWire {
  GroupHistoryWire({
    required this.groupId,
    required this.send,
    required this.localExchange,
    this.timeout = const Duration(seconds: 30),
  });

  final String groupId;
  final Future<void> Function(String peerDeviceId, Map<String, Object?> message)
  send;
  final Future<GroupHistoryExchange> Function() localExchange;
  final Duration timeout;
  final _random = Random.secure();
  final _pending = <String, _PendingHistoryRequest>{};
  int _serving = 0;
  bool _closed = false;

  GroupHistoryExchange remote(String peerDeviceId) =>
      _RemoteGroupHistory(this, peerDeviceId);

  Future<Map<String, Object?>> _request(
    String peer,
    String operation,
    Map<String, Object?> payload,
  ) {
    if (_closed) {
      return Future.error(StateError('Group history connection closed.'));
    }
    if (_pending.length >= 32 ||
        _pending.values.where((request) => request.peer == peer).length >= 4) {
      return Future.error(
        StateError('Too many pending group history requests.'),
      );
    }
    final id = base64Url.encode(
      List<int>.generate(18, (_) => _random.nextInt(256)),
    );
    final request = _PendingHistoryRequest(peer, operation);
    _pending[id] = request;
    final result = request.result.future
        .timeout(timeout)
        .whenComplete(() => _pending.remove(id));
    unawaited(
      Future.sync(
        () => send(peer, {
          'version': 1,
          'groupId': groupId,
          'type': 'request',
          'requestId': id,
          'operation': operation,
          'payload': payload,
        }),
      ).catchError((Object error, StackTrace stack) {
        if (!request.result.isCompleted) {
          request.result.completeError(error, stack);
        }
      }),
    );
    return result;
  }

  /// authenticatedPeer must come from the envelope's verified group identity.
  Future<bool> handle(
    String authenticatedPeer,
    Map<String, Object?> message,
  ) async {
    if (_closed || message['version'] != 1 || message['groupId'] != groupId) {
      return false;
    }
    final id = message['requestId'];
    final operation = message['operation'];
    if (id is! String || id.isEmpty || id.length > 64 || operation is! String) {
      return false;
    }
    if (message['type'] == 'response') {
      final pending = _pending[id];
      if (pending == null ||
          pending.peer != authenticatedPeer ||
          pending.operation != operation ||
          pending.result.isCompleted) {
        return false;
      }
      final payload = message['payload'];
      if (message['error'] is String) {
        pending.result.completeError(
          StateError('Group history peer: ${message['error']}'),
        );
      } else if (payload is Map<String, Object?>) {
        pending.result.complete(payload);
      } else {
        pending.result.completeError(
          const FormatException('Invalid group history response.'),
        );
      }
      return true;
    }
    if (message['type'] != 'request') return false;
    final response = <String, Object?>{
      'version': 1,
      'groupId': groupId,
      'type': 'response',
      'requestId': id,
      'operation': operation,
    };
    if (_serving >= 4) {
      response['error'] = 'busy';
      await send(authenticatedPeer, response);
      return true;
    }
    _serving++;
    try {
      final arguments = message['payload'];
      if (arguments is! Map<String, Object?>) {
        throw const FormatException('Invalid request.');
      }
      final exchange = await localExchange();
      switch (operation) {
        case 'memberships':
          final cursor = arguments['afterEventId'];
          if (cursor != null && (cursor is! String || !_eventId(cursor))) {
            throw const FormatException('Invalid cursor.');
          }
          final events = await exchange.membershipPage(
            authenticatedPeer,
            afterEventId: cursor as String?,
          );
          response['payload'] = {
            'events': events.map((event) => event.toJson()).toList(),
          };
        case 'inventory':
          final page = await exchange.inventory(
            authenticatedPeer,
            cursor: _decodeCursor(arguments['cursor']),
          );
          response['payload'] = {
            'entries': page.entries
                .map(
                  (entry) => {
                    'eventId': entry.eventId,
                    'authorDeviceId': entry.authorDeviceId,
                    'sequence': entry.sequence,
                  },
                )
                .toList(),
            'next': _encodeCursor(page.next),
          };
        case 'events':
          final ids = arguments['ids'];
          if (ids is! List ||
              ids.isEmpty ||
              ids.length > groupSyncPageSize ||
              !ids.every((id) => id is String && _eventId(id))) {
            throw const FormatException('Invalid event request.');
          }
          final events = await exchange.events(
            authenticatedPeer,
            ids.cast<String>(),
          );
          response['payload'] = {
            'events': events.map((event) => event.toJson()).toList(),
          };
        default:
          response['error'] = 'unsupported operation';
      }
      if (utf8.encode(jsonEncode(response)).length > 1536 * 1024) {
        response.remove('payload');
        response['error'] = 'response too large';
      }
    } on FormatException {
      response['error'] = 'invalid request';
    } on StateError {
      response['error'] = 'history unavailable; retry after membership refresh';
    } catch (_) {
      response['error'] = 'history unavailable';
    } finally {
      _serving--;
    }
    if (!_closed) await send(authenticatedPeer, response);
    return true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _pending.values) {
      if (!request.result.isCompleted) {
        request.result.completeError(
          StateError('Group history connection closed.'),
        );
      }
    }
    _pending.clear();
  }
}

class _PendingHistoryRequest {
  _PendingHistoryRequest(this.peer, this.operation);
  final String peer;
  final String operation;
  final result = Completer<Map<String, Object?>>();
}

class _RemoteGroupHistory implements GroupHistoryExchange {
  _RemoteGroupHistory(this.wire, this.peer);
  final GroupHistoryWire wire;
  final String peer;

  @override
  Future<List<GroupHistoryEvent>> membershipPage(
    String requesterDeviceId, {
    String? afterEventId,
  }) async => _decodeEvents(
    await wire._request(peer, 'memberships', {'afterEventId': afterEventId}),
  );

  @override
  Future<GroupSyncInventory> inventory(
    String requesterDeviceId, {
    GroupSyncCursor? cursor,
  }) async {
    final payload = await wire._request(peer, 'inventory', {
      'cursor': _encodeCursor(cursor),
    });
    final entries = payload['entries'];
    if (entries is! List || entries.length > groupSyncPageSize) {
      throw const FormatException('Invalid inventory.');
    }
    return GroupSyncInventory(
      entries: entries.map((entry) {
        if (entry is! Map ||
            entry['eventId'] is! String ||
            !_eventId(entry['eventId'] as String) ||
            entry['authorDeviceId'] is! String ||
            entry['sequence'] is! int) {
          throw const FormatException('Invalid inventory entry.');
        }
        return GroupSyncInventoryEntry(
          eventId: entry['eventId'] as String,
          authorDeviceId: entry['authorDeviceId'] as String,
          sequence: entry['sequence'] as int,
        );
      }).toList(),
      next: _decodeCursor(payload['next']),
    );
  }

  @override
  Future<List<GroupHistoryEvent>> events(
    String requesterDeviceId,
    List<String> ids,
  ) async => _decodeEvents(await wire._request(peer, 'events', {'ids': ids}));
}

List<GroupHistoryEvent> _decodeEvents(Map<String, Object?> payload) {
  final events = payload['events'];
  if (events is! List || events.length > groupSyncPageSize) {
    throw const FormatException('Invalid history page.');
  }
  return events
      .map((event) => GroupHistoryEvent.decode(jsonEncode(event)))
      .toList();
}

Map<String, Object?>? _encodeCursor(GroupSyncCursor? cursor) => cursor == null
    ? null
    : {
        'authorDeviceId': cursor.authorDeviceId,
        'afterSequence': cursor.afterSequence,
      };

GroupSyncCursor? _decodeCursor(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map ||
      raw['authorDeviceId'] is! String ||
      raw['afterSequence'] is! int) {
    throw const FormatException('Invalid inventory cursor.');
  }
  final author = raw['authorDeviceId'] as String;
  final sequence = raw['afterSequence'] as int;
  if (author.isEmpty ||
      author.length > 128 ||
      sequence < 0 ||
      sequence > groupEventMaxCounter) {
    throw const FormatException('Invalid inventory cursor.');
  }
  return GroupSyncCursor(authorDeviceId: author, afterSequence: sequence);
}

bool _eventId(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
