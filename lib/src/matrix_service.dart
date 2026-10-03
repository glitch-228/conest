import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'matrix_oauth.dart';
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

/// The server asks for the account password to continue.
class MatrixPasswordRequired implements Exception {
  const MatrixPasswordRequired();

  @override
  String toString() => 'The Matrix server asks for your account password.';
}

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
  MatrixOAuthLoopback? _browserSignIn;
  final _verification = StreamController<Map<String, dynamic>>.broadcast();

  /// Interactive verification: `verification_request` (another session asks
  /// to verify this one) and `verification` with a `state` of `ready`,
  /// `emojis` (with the seven emojis to compare), `done` or `cancelled`.
  Stream<Map<String, dynamic>> get verificationEvents => _verification.stream;
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

  /// Signs in through the account server's own page in the browser: the
  /// only way into accounts that use single sign-on or the Matrix
  /// Authentication Service. [openUrl] shows the page; the browser comes
  /// back to a loopback listener.
  Future<void> signInWithBrowser({
    required String homeserver,
    required Future<void> Function(Uri url) openUrl,
    String? deviceId,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    _browserSignIn?.cancel();
    _setState(MatrixClientState.signingIn);
    final loopback = await MatrixOAuthLoopback.bind();
    _browserSignIn = loopback;
    try {
      final store = await _store();
      final started = await _api.request('oauth_start', {
        'storePath': store.path,
        'passphrase': store.passphrase,
        'homeserver': homeserver,
        'redirectUri': loopback.redirectUri.toString(),
        'deviceId': ?deviceId,
      });
      final url = Uri.parse(started['url'] as String);
      loopback.expectStateOf(url);
      await openUrl(url);
      final callback = await loopback.callback.timeout(
        timeout,
        onTimeout: () =>
            throw TimeoutException('The browser sign-in timed out.'),
      );
      final session = await _api.request('oauth_finish', {
        'callbackUrl': callback.toString(),
      });
      await _started(session);
    } catch (error) {
      unawaited(
        _api
            .request('oauth_abort')
            .catchError((Object _) => <String, dynamic>{}),
      );
      _fail(error);
      rethrow;
    } finally {
      if (identical(_browserSignIn, loopback)) _browserSignIn = null;
      unawaited(loopback.close());
    }
  }

  /// Stops waiting for the browser.
  void cancelBrowserSignIn() => _browserSignIn?.cancel();

  bool get browserSignInPending => _browserSignIn != null;

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

  /// Revokes this device on the server, then drops it locally. When the
  /// server cannot be reached the session is kept (it is still valid there)
  /// and the error is thrown; [force] drops it locally regardless.
  Future<void> signOut({bool force = false}) async {
    final store = await _store();
    final root = {'storePath': store.path};
    if (force) {
      await _api.request('forget', root).catchError((Object _) => _none);
    } else {
      try {
        await _api.request('logout', root);
      } catch (error) {
        final text = '$error';
        if (text.contains('M_UNKNOWN_TOKEN')) {
          // Already revoked: nothing left to do on the server.
          await _api.request('forget', root).catchError((Object _) => _none);
        } else if (text.contains('not signed in to Matrix') &&
            _session != null) {
          // The native side never resumed (for example the restore at
          // startup failed); resume it to revoke the token.
          await _api.request('restore', {
            ...root,
            'passphrase': store.passphrase,
            'session': _session,
          });
          await _api.request('logout', root);
        } else {
          _lastError = text;
          _notify();
          rethrow;
        }
      }
    }
    _clearLocal();
    await _onSession(null);
    _setState(MatrixClientState.signedOut);
  }

  static const Map<String, dynamic> _none = {};

  void _clearLocal() {
    _session = null;
    _rooms.clear();
    _timelines.clear();
    _olderFrom.clear();
    _exhausted.clear();
  }

  /// Where decrypted media is cached: inside this login's store, so it goes
  /// with the store at sign-out and never sits in a shared temp directory.
  Future<Directory?> mediaCacheDirectory() async {
    final session = _session;
    if (session == null) return null;
    final store = await _store();
    final name = session['store'] as String? ?? '';
    final directory = Directory(
      name.isEmpty
          ? '${store.path}/media-cache'
          : '${store.path}/$name/media-cache',
    );
    await directory.create(recursive: true);
    return directory;
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
    final before = timeline(roomId);
    final page = await _api.request('messages', {
      'roomId': roomId,
      'limit': limit,
      'from': ?_olderFrom[roomId],
    });
    final events = (page['events'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    // A gap in sync restarted the room meanwhile: this page belongs to the
    // old timeline, and its token would skip history.
    if (!identical(before, _timelines[roomId])) return true;
    before.prependPage(events);
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

  /// Adds [key] to [eventId], or takes this user's reaction back when it is
  /// already there.
  Future<void> toggleReaction(String roomId, String eventId, String key) async {
    final own = userId == null
        ? null
        : timeline(roomId).reactionEventId(eventId, key, userId!);
    if (own != null) {
      await redact(roomId, own);
    } else {
      await react(roomId, eventId, key);
    }
  }

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

  /// Secret storage and key backup state, e.g. `Enabled`, `Disabled`,
  /// `Incomplete`, plus whether cross-signing is fully set up.
  Future<({String recovery, bool crossSigning})> recoveryState() async {
    final state = await _api.request('recovery_state');
    return (
      recovery: state['recovery'] as String? ?? 'Unknown',
      crossSigning: state['crossSigning'] == true,
    );
  }

  /// Sets up cross-signing, secret storage and key backup; returns the
  /// recovery key the user must keep.
  /// Throws a [MatrixPasswordRequired] when the server wants the account
  /// password before accepting the first cross-signing keys.
  Future<String> enableRecovery({String? password}) async {
    try {
      final result = await _api.request('enable_recovery', {
        'password': ?password,
      });
      return result['recoveryKey'] as String;
    } catch (error) {
      if ('$error'.contains('M_CONEST_NEEDS_PASSWORD')) {
        throw const MatrixPasswordRequired();
      }
      rethrow;
    }
  }

  /// Unlocks secret storage with a recovery key, restoring encrypted
  /// history keys on this device.
  Future<void> recover(String recoveryKey) async {
    await _api.request('recover', {'recoveryKey': recoveryKey.trim()});
    resetTimelines();
  }

  /// Drops loaded timelines so they reload: messages that could not be
  /// decrypted before recovery or verification can be now.
  void resetTimelines() {
    _timelines.clear();
    _olderFrom.clear();
    _exhausted.clear();
    _notify();
  }

  /// Asks another signed-in session of this account to verify this one;
  /// returns the flow id to follow on [verificationEvents].
  Future<String> verifyOwnSession() async {
    final result = await _api.request('verify_own_session');
    return result['flowId'] as String;
  }

  Future<void> acceptVerification(String userId, String flowId) =>
      _api.request('verification_accept', {'userId': userId, 'flowId': flowId});

  Future<void> startEmojiVerification(String userId, String flowId) => _api
      .request('verification_start_sas', {'userId': userId, 'flowId': flowId});

  Future<void> confirmVerification(
    String userId,
    String flowId, {
    required bool match,
  }) => _api.request(match ? 'verification_confirm' : 'verification_mismatch', {
    'userId': userId,
    'flowId': flowId,
  });

  Future<void> cancelVerification(String userId, String flowId) =>
      _api.request('verification_cancel', {'userId': userId, 'flowId': flowId});

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
        final error = event['error'] as String? ?? '';
        _lastError = error;
        if (signedIn && error.contains('M_UNKNOWN_TOKEN')) {
          // Signed out elsewhere: stop syncing and drop the session.
          unawaited(_sessionRevoked());
          return;
        }
        _notify();
      case 'session':
        // The SDK refreshed the access token; keep the stored copy current.
        final session = event['session'];
        if (signedIn && session is Map<String, dynamic>) {
          _session = session;
          unawaited(_onSession(session).catchError((Object _) {}));
        }
      case 'session_revoked':
        if (signedIn) unawaited(_sessionRevoked());
      case 'verification_request' || 'verification':
        _verification.add(event);
        if (event['state'] == 'done') resetTimelines();
      case 'to_device':
        final payload = event['event'];
        if (payload is Map<String, dynamic>) _onToDevice?.call(payload);
    }
  }

  Future<void> _sessionRevoked() async {
    try {
      final store = await _store();
      await _api.request('forget', {'storePath': store.path});
    } catch (_) {}
    _clearLocal();
    await _onSession(null);
    _lastError = 'The Matrix sign-in expired. Sign in again.';
    _setState(MatrixClientState.signedOut);
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
    _browserSignIn?.cancel();
    unawaited(_events.cancel());
    unawaited(_verification.close());
    super.dispose();
  }
}
