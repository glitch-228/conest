import 'dart:async';

import 'package:flutter/foundation.dart';

import 'matrix_timeline.dart';

/// What [MatrixClientService] needs from the native client; tests supply a
/// fake.
abstract interface class MatrixNativeApi {
  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, Object?> parameters,
    Duration timeout,
  ]);

  Stream<Map<String, dynamic>> get events;
}

class MatrixRoom {
  MatrixRoom({
    required this.roomId,
    required this.name,
    required this.direct,
    required this.encrypted,
    required this.invited,
    required this.unread,
    required this.highlight,
  });

  factory MatrixRoom.fromJson(Map<String, dynamic> json) => MatrixRoom(
    roomId: json['roomId'] as String,
    name: (json['name'] as String?)?.trim().isNotEmpty == true
        ? json['name'] as String
        : json['roomId'] as String,
    direct: json['direct'] == true,
    encrypted: json['encrypted'] == true,
    invited: json['invited'] == true,
    unread: (json['unread'] as num?)?.toInt() ?? 0,
    highlight: (json['highlight'] as num?)?.toInt() ?? 0,
  );

  final String roomId;
  final String name;
  final bool direct;
  final bool encrypted;
  final bool invited;
  final int unread;
  final int highlight;
}

enum MatrixClientState { signedOut, signingIn, ready, error }

/// The full Matrix client for the app: session, rooms, timelines and
/// sending. The native client owns the only `/sync` for the Matrix device.
class MatrixClientService extends ChangeNotifier {
  MatrixClientService({
    required MatrixNativeApi api,
    required Future<({String path, String passphrase})> Function() store,
    required Future<void> Function(Map<String, dynamic>? session) onSession,
    void Function(Map<String, dynamic> event)? onToDevice,
  }) : _api = api,
       _store = store,
       _onSession = onSession,
       _onToDevice = onToDevice {
    _events = api.events.listen(_handleEvent);
  }

  final MatrixNativeApi _api;
  final Future<({String path, String passphrase})> Function() _store;
  final Future<void> Function(Map<String, dynamic>? session) _onSession;
  final void Function(Map<String, dynamic> event)? _onToDevice;
  late final StreamSubscription<Map<String, dynamic>> _events;

  MatrixClientState _state = MatrixClientState.signedOut;
  Map<String, dynamic>? _session;
  String? _lastError;
  final Map<String, MatrixRoom> _rooms = {};
  final Map<String, MatrixTimeline> _timelines = {};
  final Map<String, String?> _olderFrom = {};
  final Set<String> _exhausted = {};
  Timer? _roomRefresh;
  bool _disposed = false;

  MatrixClientState get state => _state;
  String? get userId => _session?['userId'] as String?;
  String? get deviceId => _session?['deviceId'] as String?;
  Map<String, dynamic>? get session =>
      _session == null ? null : Map.unmodifiable(_session!);
  String? get lastError => _lastError;
  bool get signedIn => _state == MatrixClientState.ready;

  /// Joined rooms first by unread count, then invites.
  List<MatrixRoom> get rooms {
    final list = _rooms.values.toList()
      ..sort((left, right) {
        if (left.invited != right.invited) return left.invited ? 1 : -1;
        return right.unread.compareTo(left.unread);
      });
    return list;
  }

  MatrixRoom? room(String roomId) => _rooms[roomId];

  MatrixTimeline timeline(String roomId) =>
      _timelines.putIfAbsent(roomId, MatrixTimeline.new);

  bool hasOlder(String roomId) => !_exhausted.contains(roomId);

  Future<void> signInWithPassword({
    required String homeserver,
    required String user,
    required String password,
    String? deviceId,
  }) async {
    _setState(MatrixClientState.signingIn);
    try {
      final store = await _store();
      final session = await _api.request('login_password', {
        'storePath': store.path,
        'passphrase': store.passphrase,
        'homeserver': homeserver,
        'user': user,
        'password': password,
        'deviceId': ?deviceId,
      });
      await _started(session);
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  /// Resumes a stored session (startup, or migrating the carrier's device).
  Future<void> restore(Map<String, dynamic> session) async {
    _setState(MatrixClientState.signingIn);
    try {
      final store = await _store();
      final restored = await _api.request('restore', {
        'storePath': store.path,
        'passphrase': store.passphrase,
        'session': session,
      });
      await _started(restored);
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  Future<void> _started(Map<String, dynamic> session) async {
    _session = session;
    await _onSession(session);
    await _api.request('start_sync');
    _lastError = null;
    _setState(MatrixClientState.ready);
    await refreshRooms();
  }

  Future<void> signOut() async {
    try {
      await _api.request('logout');
    } catch (error) {
      // The local session is dropped either way.
      _lastError = '$error';
    }
    _session = null;
    _rooms.clear();
    _timelines.clear();
    _olderFrom.clear();
    _exhausted.clear();
    await _onSession(null);
    _setState(MatrixClientState.signedOut);
  }

  Future<void> refreshRooms() async {
    final result = await _api.request('rooms');
    _rooms
      ..clear()
      ..addEntries(
        (result['rooms'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MatrixRoom.fromJson)
            .map((room) => MapEntry(room.roomId, room)),
      );
    _notify();
  }

  /// Loads the next page of older events; returns false at the start of
  /// the room's history.
  Future<bool> loadOlder(String roomId, {int limit = 30}) async {
    if (_exhausted.contains(roomId)) return false;
    final page = await _api.request('messages', {
      'roomId': roomId,
      'limit': limit,
      'from': ?_olderFrom[roomId],
    });
    final events = (page['events'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    timeline(roomId).prependPage(events);
    final end = page['end'] as String?;
    _olderFrom[roomId] = end;
    if (end == null || events.isEmpty) _exhausted.add(roomId);
    _notify();
    return end != null && events.isNotEmpty;
  }

  Future<String> sendText(String roomId, String body, {String? replyTo}) =>
      _sendMessage(roomId, {
        'msgtype': 'm.text',
        'body': body,
        if (replyTo != null)
          'm.relates_to': {
            'm.in_reply_to': {'event_id': replyTo},
          },
      });

  Future<String> edit(String roomId, String eventId, String body) =>
      _sendMessage(roomId, {
        'msgtype': 'm.text',
        'body': '* $body',
        'm.new_content': {'msgtype': 'm.text', 'body': body},
        'm.relates_to': {'rel_type': 'm.replace', 'event_id': eventId},
      });

  Future<String> react(String roomId, String eventId, String key) async {
    final sent = await _api.request('send_raw', {
      'roomId': roomId,
      'type': 'm.reaction',
      'content': {
        'm.relates_to': {
          'rel_type': 'm.annotation',
          'event_id': eventId,
          'key': key,
        },
      },
    });
    return sent['eventId'] as String;
  }

  Future<void> redact(String roomId, String eventId, {String? reason}) =>
      _api.request('redact', {
        'roomId': roomId,
        'eventId': eventId,
        'reason': ?reason,
      });

  Future<String> sendFile(
    String roomId, {
    required String path,
    required String name,
    String? mimeType,
  }) async {
    final sent = await _api.request('send_file', {
      'roomId': roomId,
      'path': path,
      'name': name,
      'mimeType': ?mimeType,
    }, const Duration(minutes: 10));
    return sent['eventId'] as String;
  }

  /// Downloads (and decrypts) media to [path]; with a size, a thumbnail.
  Future<void> download(
    Map<String, dynamic> media,
    String path, {
    int? width,
    int? height,
  }) => _api.request('download', {
    'source': media,
    'path': path,
    'width': ?width,
    'height': ?height,
  }, const Duration(minutes: 10));

  Future<void> markRead(String roomId, String eventId) =>
      _api.request('read_receipt', {'roomId': roomId, 'eventId': eventId});

  Future<void> join(String roomId) async {
    await _api.request('join', {'roomId': roomId});
    await refreshRooms();
  }

  Future<void> leave(String roomId) async {
    await _api.request('leave', {'roomId': roomId});
    await refreshRooms();
  }

  Future<String> createDirectMessage(String userId) async {
    final created = await _api.request('create_dm', {'userId': userId});
    await refreshRooms();
    return created['roomId'] as String;
  }

  Future<String?> displayName(String roomId, String userId) async {
    final member = await _api.request('member', {
      'roomId': roomId,
      'userId': userId,
    });
    return member['displayName'] as String?;
  }

  /// Plain to-device message (used by the Conest carrier).
  Future<void> sendToDevice({
    required String type,
    required String userId,
    required String deviceId,
    required Map<String, Object?> content,
    String? transactionId,
  }) => _api.request('send_to_device', {
    'type': type,
    'userId': userId,
    'deviceId': deviceId,
    'content': content,
    'transactionId': ?transactionId,
  });

  Future<String> _sendMessage(
    String roomId,
    Map<String, Object?> content,
  ) async {
    final sent = await _api.request('send_raw', {
      'roomId': roomId,
      'type': 'm.room.message',
      'content': content,
    });
    return sent['eventId'] as String;
  }

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'sync':
        _lastError = null;
        _roomRefresh?.cancel();
        _roomRefresh = Timer(const Duration(milliseconds: 300), () {
          if (_disposed || !signedIn) return;
          unawaited(refreshRooms().catchError((Object _) {}));
        });
      case 'timeline':
        final roomId = event['roomId'];
        if (roomId is! String) return;
        final events = (event['events'] as List? ?? const [])
            .whereType<Map<String, dynamic>>();
        if (event['limited'] == true) {
          // A gap: start over from the newest events; older history
          // reloads on demand.
          _timelines[roomId] = MatrixTimeline();
          _olderFrom[roomId] = event['prevBatch'] as String?;
          _exhausted.remove(roomId);
        }
        timeline(roomId).appendAll(events);
        _notify();
      case 'sync_error':
        _lastError = event['error'] as String?;
        _notify();
      case 'to_device':
        final payload = event['event'];
        if (payload is Map<String, dynamic>) _onToDevice?.call(payload);
    }
  }

  void _fail(Object error) {
    _lastError = '$error';
    _setState(
      _session == null ? MatrixClientState.signedOut : MatrixClientState.error,
    );
  }

  void _setState(MatrixClientState state) {
    _state = state;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _roomRefresh?.cancel();
    unawaited(_events.cancel());
    super.dispose();
  }
}
