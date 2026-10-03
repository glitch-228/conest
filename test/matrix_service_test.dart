import 'dart:async';
import 'dart:io';

import 'package:conest/src/matrix_service.dart';
import 'package:conest/src/matrix_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi implements MatrixNativeApi {
  final requests = <(String, Map<String, Object?>)>[];
  final responses = <String, List<Map<String, dynamic>>>{};
  final failures = <String, List<Object>>{};
  final gates = <String, Completer<void>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  void respond(String op, Map<String, dynamic> value) =>
      responses.putIfAbsent(op, () => []).add(value);

  void emit(Map<String, dynamic> event) => _events.add(event);

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(minutes: 2),
  ]) async {
    requests.add((op, parameters));
    await gates[op]?.future;
    final failure = failures[op];
    if (failure != null && failure.isNotEmpty) throw failure.removeAt(0);
    final queued = responses[op];
    if (queued != null && queued.isNotEmpty) {
      return queued.length == 1 ? queued.first : queued.removeAt(0);
    }
    return const {};
  }

  Iterable<String> get ops => requests.map((request) => request.$1);
  Map<String, Object?> last(String op) =>
      requests.lastWhere((request) => request.$1 == op).$2;
}

Map<String, dynamic> _message(String id, String body, int ts) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': '@b:x',
  'origin_server_ts': ts,
  'content': {'msgtype': 'm.text', 'body': body},
};

void main() {
  late _FakeApi api;
  late MatrixClientService service;
  final sessions = <Map<String, dynamic>?>[];
  final toDevice = <Map<String, dynamic>>[];

  setUp(() {
    api = _FakeApi();
    sessions.clear();
    toDevice.clear();
    service = MatrixClientService(
      api: api,
      store: () async => (path: '/store', passphrase: 'secret'),
      onSession: (session) async => sessions.add(session),
      onToDevice: toDevice.add,
    );
    addTearDown(service.dispose);
  });

  test('sign-in starts sync, persists the session and lists rooms', () async {
    api
      ..respond('login_password', {
        'userId': '@a:x',
        'deviceId': 'CONEST_A',
        'accessToken': 't',
        'homeserver': 'https://x',
      })
      ..respond('rooms', {
        'rooms': [
          {'roomId': '!inv:x', 'name': 'Invite', 'invited': true, 'unread': 9},
          {'roomId': '!dm:x', 'name': 'Bob', 'direct': true, 'unread': 2},
          {'roomId': '!quiet:x', 'name': '', 'unread': 0},
        ],
      });
    await service.signInWithPassword(
      homeserver: 'https://x',
      user: 'a',
      password: 'p',
      deviceId: 'CONEST_A',
    );
    expect(api.ops, ['login_password', 'start_sync', 'rooms']);
    expect(api.last('login_password'), containsPair('storePath', '/store'));
    expect(api.last('login_password'), containsPair('passphrase', 'secret'));
    expect(sessions.single?['userId'], '@a:x');
    expect(service.signedIn, isTrue);
    expect(service.rooms.map((room) => room.roomId), [
      '!dm:x',
      '!quiet:x',
      '!inv:x',
    ]);
    // An empty name falls back to the room id.
    expect(service.room('!quiet:x')!.name, '!quiet:x');
  });

  test('sync timelines append; a gap restarts the room', () async {
    api.emit({
      'type': 'timeline',
      'roomId': '!r:x',
      'events': [_message('\$1', 'one', 1)],
    });
    await Future<void>.delayed(Duration.zero);
    expect(service.timeline('!r:x').items.single.body, 'one');
    api.emit({
      'type': 'timeline',
      'roomId': '!r:x',
      'events': [_message('\$9', 'nine', 9)],
      'limited': true,
      'prevBatch': 'p8',
    });
    await Future<void>.delayed(Duration.zero);
    expect(service.timeline('!r:x').items.map((item) => item.body), ['nine']);
    api.respond('messages', {
      'events': [_message('\$8', 'eight', 8)],
      'end': 'p7',
    });
    await service.loadOlder('!r:x');
    expect(api.last('messages')['from'], 'p8');
    expect(service.timeline('!r:x').items.map((item) => item.body), [
      'eight',
      'nine',
    ]);
  });

  test('history paging stops at the start of the room', () async {
    api
      ..respond('messages', {
        'events': [_message('\$2', 'two', 2)],
        'end': 'p1',
      })
      ..respond('messages', {
        'events': [_message('\$1', 'one', 1)],
      });
    expect(await service.loadOlder('!r:x'), isTrue);
    expect(api.last('messages').containsKey('from'), isFalse);
    expect(await service.loadOlder('!r:x'), isFalse);
    expect(api.last('messages')['from'], 'p1');
    expect(service.hasOlder('!r:x'), isFalse);
    expect(await service.loadOlder('!r:x'), isFalse);
    expect(api.ops.where((op) => op == 'messages'), hasLength(2));
    expect(service.timeline('!r:x').items.map((item) => item.kind), [
      MatrixItemKind.text,
      MatrixItemKind.text,
    ]);
  });

  test('replies, edits and reactions use the Matrix relation shapes', () async {
    api.respond('send_raw', {'eventId': '\$sent'});
    await service.sendText('!r:x', 'hi', replyTo: '\$q');
    expect(api.last('send_raw'), {
      'roomId': '!r:x',
      'type': 'm.room.message',
      'content': {
        'msgtype': 'm.text',
        'body': 'hi',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': '\$q'},
        },
      },
    });
    await service.edit('!r:x', '\$q', 'fixed');
    final edit = api.last('send_raw')['content'] as Map;
    expect(edit['m.new_content'], {'msgtype': 'm.text', 'body': 'fixed'});
    expect(edit['m.relates_to'], {'rel_type': 'm.replace', 'event_id': '\$q'});
    await service.react('!r:x', '\$q', '👍');
    expect(api.last('send_raw')['type'], 'm.reaction');
    expect((api.last('send_raw')['content'] as Map)['m.relates_to'], {
      'rel_type': 'm.annotation',
      'event_id': '\$q',
      'key': '👍',
    });
  });

  test('a revoked token signs the client out', () async {
    api.respond('login_password', {
      'userId': '@a:x',
      'deviceId': 'D',
      'accessToken': 't',
      'homeserver': 'https://x',
    });
    await service.signInWithPassword(
      homeserver: 'https://x',
      user: 'a',
      password: 'p',
    );
    api.emit({
      'type': 'sync_error',
      'error': 'M_UNKNOWN_TOKEN: Invalid access token passed.',
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(service.state, MatrixClientState.signedOut);
    expect(sessions.last, isNull);
    expect(api.last('forget'), {'storePath': '/store'});
  });

  Future<void> signIn() async {
    api.respond('login_password', {
      'userId': '@a:x',
      'deviceId': 'D',
      'accessToken': 't',
      'homeserver': 'https://x',
      'store': 's1',
    });
    await service.signInWithPassword(
      homeserver: 'https://x',
      user: 'a',
      password: 'p',
    );
  }

  test('an unreachable server keeps the session until forced', () async {
    await signIn();
    api.failures['logout'] = [Exception('connection refused')];
    await expectLater(service.signOut(), throwsException);
    expect(service.signedIn, isTrue);
    expect(sessions.last, isNotNull);
    expect(api.ops, isNot(contains('forget')));

    await service.signOut(force: true);
    expect(api.last('forget'), {'storePath': '/store'});
    expect(service.state, MatrixClientState.signedOut);
    expect(sessions.last, isNull);
  });

  test('an already revoked token signs out locally', () async {
    await signIn();
    api.failures['logout'] = [Exception('M_UNKNOWN_TOKEN: gone')];
    await service.signOut();
    expect(api.ops, contains('forget'));
    expect(service.state, MatrixClientState.signedOut);
  });

  test('a native side that never resumed is resumed to revoke', () async {
    await signIn();
    api.failures['logout'] = [Exception('not signed in to Matrix')];
    await service.signOut();
    expect(api.last('restore')['session'], containsPair('userId', '@a:x'));
    expect(api.ops.where((op) => op == 'logout'), hasLength(2));
    expect(service.state, MatrixClientState.signedOut);
  });

  test('media is cached inside the login store', () async {
    expect(await service.mediaCacheDirectory(), isNull);
    final root = await Directory.systemTemp.createTemp('conest-media-');
    addTearDown(() => root.delete(recursive: true));
    final local = MatrixClientService(
      api: api,
      store: () async => (path: root.path, passphrase: 'secret'),
      onSession: (_) async {},
    );
    addTearDown(local.dispose);
    api.respond('login_password', {
      'userId': '@a:x',
      'deviceId': 'D',
      'accessToken': 't',
      'homeserver': 'https://x',
      'store': 's1',
    });
    await local.signInWithPassword(
      homeserver: 'https://x',
      user: 'a',
      password: 'p',
    );
    final cache = await local.mediaCacheDirectory();
    expect(cache!.path, '${root.path}/s1/media-cache');
    expect(await cache.exists(), isTrue);
  });

  test('tapping your own reaction takes it back', () async {
    await signIn();
    api.emit({
      'type': 'timeline',
      'roomId': '!r:x',
      'events': [
        _message('\$m', 'hi', 1),
        {
          'event_id': '\$like',
          'type': 'm.reaction',
          'sender': '@a:x',
          'origin_server_ts': 2,
          'content': {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': '\$m',
              'key': '👍',
            },
          },
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    await service.toggleReaction('!r:x', '\$m', '👍');
    expect(api.last('redact'), containsPair('eventId', '\$like'));
    api.respond('send_raw', {'eventId': '\$love'});
    await service.toggleReaction('!r:x', '\$m', '❤️');
    expect(api.last('send_raw')['type'], 'm.reaction');
  });

  test('a history page that races a sync gap is dropped', () async {
    api.respond('messages', {
      'events': [_message('\$1', 'old', 1)],
      'end': 'stale',
    });
    final gate = api.gates['messages'] = Completer<void>();
    final paging = service.loadOlder('!r:x');
    api.emit({
      'type': 'timeline',
      'roomId': '!r:x',
      'events': [_message('\$9', 'new', 9)],
      'limited': true,
      'prevBatch': 'p8',
    });
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await paging;
    expect(service.timeline('!r:x').items.map((item) => item.body), ['new']);
    api.gates.remove('messages');
    await service.loadOlder('!r:x');
    expect(api.last('messages')['from'], 'p8');
  });

  test('browser sign-in waits for the redirect, then finishes', () async {
    api
      ..respond('oauth_start', {'url': 'https://account.x/authorize?state=s'})
      ..respond('oauth_finish', {
        'userId': '@a:x',
        'deviceId': 'D',
        'accessToken': 't',
        'refreshToken': 'r',
        'oauthClientId': 'client-1',
        'homeserver': 'https://x',
      });
    Uri? opened;
    await service.signInWithBrowser(
      homeserver: 'https://x',
      deviceId: 'D',
      openUrl: (url) async {
        opened = url;
        // The browser follows the account server's redirect.
        final redirect = Uri.parse(
          api.last('oauth_start')['redirectUri'] as String,
        ).replace(queryParameters: {'code': 'c', 'state': 's'});
        final http = HttpClient();
        await (await http.getUrl(redirect)).close();
        http.close();
      },
    );
    expect(opened.toString(), 'https://account.x/authorize?state=s');
    expect(api.last('oauth_start'), containsPair('deviceId', 'D'));
    expect(
      Uri.parse(
        api.last('oauth_finish')['callbackUrl'] as String,
      ).queryParameters,
      {'code': 'c', 'state': 's'},
    );
    expect(sessions.single?['oauthClientId'], 'client-1');
    expect(service.signedIn, isTrue);

    // Refreshed tokens are stored; a refused refresh signs out.
    api.emit({
      'type': 'session',
      'session': {...service.session!, 'accessToken': 't2'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(sessions.last?['accessToken'], 't2');
    expect(service.session!['accessToken'], 't2');
    api.emit({'type': 'session_revoked'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(service.state, MatrixClientState.signedOut);
    expect(sessions.last, isNull);
  });

  test('a cancelled browser sign-in aborts the native flow', () async {
    api.respond('oauth_start', {'url': 'https://account.x/authorize'});
    final signIn = service.signInWithBrowser(
      homeserver: 'https://x',
      openUrl: (_) async => service.cancelBrowserSignIn(),
    );
    await expectLater(signIn, throwsStateError);
    expect(api.ops, contains('oauth_abort'));
    expect(api.ops, isNot(contains('oauth_finish')));
    expect(service.state, MatrixClientState.signedOut);
    expect(service.browserSignInPending, isFalse);
  });

  test('carrier to-device events are handed on; sign-out clears', () async {
    api.emit({
      'type': 'to_device',
      'event': {
        'type': 'dev.conest.carrier.v1',
        'sender': '@b:x',
        'content': {'v': 1},
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(toDevice.single['sender'], '@b:x');

    await service.signOut();
    expect(api.ops.last, 'logout');
    expect(sessions.last, isNull);
    expect(service.state, MatrixClientState.signedOut);
  });
}
