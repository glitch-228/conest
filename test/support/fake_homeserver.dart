import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// In-process homeserver implementing the Client-Server subset the Conest
/// carrier uses: versions, password login, whoami, logout, send-to-device and
/// `/sync` with `next_batch` acknowledgement of to-device messages.
class FakeHomeserver {
  FakeHomeserver._(this._server, this.serverName);

  static Future<FakeHomeserver> start({String serverName = 'fake.test'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final homeserver = FakeHomeserver._(server, serverName);
    server.listen(homeserver._handle);
    return homeserver;
  }

  final HttpServer _server;
  final String serverName;
  final Map<String, String> _passwords = {};
  final Map<String, ({String userId, String deviceId})> _tokens = {};
  final Map<String, List<_Queued>> _queues = {};
  final Map<String, Completer<void>> _waiters = {};
  final Set<String> _transactions = {};
  var _sequence = 0;
  var _tokenCounter = 0;

  /// Rejects the next N `sendToDevice` calls with 429.
  int rateLimitSends = 0;
  Duration retryAfter = const Duration(seconds: 1);

  /// Every accepted send-to-device message, for assertions.
  final List<
    ({String type, String from, String to, Map<String, dynamic> content})
  >
  sent = [];

  Uri get url => Uri.parse('http://${_server.address.host}:${_server.port}');

  String register(String localpart, String password) {
    final userId = '@$localpart:$serverName';
    _passwords[userId] = password;
    return userId;
  }

  /// Invalidates every access token of [userId].
  void revoke(String userId) =>
      _tokens.removeWhere((_, owner) => owner.userId == userId);

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final body = await utf8.decoder.bind(request).join();
      final json = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
      if (path == '/_matrix/client/versions') {
        return _reply(request, 200, {
          'versions': ['v1.11', 'v1.19'],
        });
      }
      if (path == '/_matrix/client/v3/login' && request.method == 'POST') {
        return _login(request, json as Map<String, dynamic>);
      }
      final token = request.headers
          .value('authorization')
          ?.replaceFirst('Bearer ', '');
      final owner = token == null ? null : _tokens[token];
      if (owner == null) {
        return _reply(request, 401, {
          'errcode': 'M_UNKNOWN_TOKEN',
          'error': 'Unknown access token.',
        });
      }
      if (path == '/_matrix/client/v3/account/whoami') {
        return _reply(request, 200, {
          'user_id': owner.userId,
          'device_id': owner.deviceId,
        });
      }
      if (path == '/_matrix/client/v3/logout') {
        _tokens.remove(token);
        return _reply(request, 200, {});
      }
      if (path.startsWith('/_matrix/client/v3/sendToDevice/') &&
          request.method == 'PUT') {
        return _sendToDevice(
          request,
          owner,
          path,
          json as Map<String, dynamic>,
        );
      }
      if (path == '/_matrix/client/v3/sync') {
        return _sync(request, owner);
      }
      return _reply(request, 404, {'errcode': 'M_UNRECOGNIZED'});
    } catch (error) {
      return _reply(request, 500, {'errcode': 'M_UNKNOWN', 'error': '$error'});
    }
  }

  void _login(HttpRequest request, Map<String, dynamic> json) {
    final user = (json['identifier'] as Map?)?['user'] as String?;
    final userId = user == null
        ? null
        : user.startsWith('@')
        ? user
        : '@$user:$serverName';
    if (json['type'] != 'm.login.password' ||
        userId == null ||
        _passwords[userId] != json['password']) {
      return _reply(request, 403, {
        'errcode': 'M_FORBIDDEN',
        'error': 'Invalid username or password',
      });
    }
    final deviceId = json['device_id'] as String? ?? 'DEVICE${++_tokenCounter}';
    final token = 'token-${++_tokenCounter}';
    _tokens[token] = (userId: userId, deviceId: deviceId);
    _reply(request, 200, {
      'user_id': userId,
      'access_token': token,
      'device_id': deviceId,
    });
  }

  void _sendToDevice(
    HttpRequest request,
    ({String userId, String deviceId}) owner,
    String path,
    Map<String, dynamic> json,
  ) {
    if (rateLimitSends > 0) {
      rateLimitSends--;
      request.response.headers.set('retry-after', retryAfter.inSeconds);
      return _reply(request, 429, {
        'errcode': 'M_LIMIT_EXCEEDED',
        'error': 'Too many requests',
      });
    }
    final segments = path.split('/');
    final type = Uri.decodeComponent(segments[segments.length - 2]);
    final transaction = '${owner.userId}|${segments.last}';
    if (_transactions.add(transaction)) {
      final messages = json['messages'] as Map<String, dynamic>;
      messages.forEach((userId, devices) {
        (devices as Map<String, dynamic>).forEach((deviceId, content) {
          final key = '$userId|$deviceId';
          _queues
              .putIfAbsent(key, () => [])
              .add(
                _Queued(++_sequence, {
                  'type': type,
                  'sender': owner.userId,
                  'content': content,
                }),
              );
          sent.add((
            type: type,
            from: owner.userId,
            to: key,
            content: content as Map<String, dynamic>,
          ));
          _waiters.remove(key)?.complete();
        });
      });
    }
    _reply(request, 200, {});
  }

  Future<void> _sync(
    HttpRequest request,
    ({String userId, String deviceId}) owner,
  ) async {
    final key = '${owner.userId}|${owner.deviceId}';
    final since = int.tryParse(
      (request.uri.queryParameters['since'] ?? 's0').substring(1),
    );
    final queue = _queues.putIfAbsent(key, () => []);
    // A sync carrying a token acknowledges everything up to it.
    if (since != null) queue.removeWhere((entry) => entry.sequence <= since);
    if (queue.isEmpty) {
      final timeout =
          int.tryParse(request.uri.queryParameters['timeout'] ?? '0') ?? 0;
      if (timeout > 0) {
        final waiter = _waiters.putIfAbsent(key, Completer<void>.new);
        await waiter.future
            .timeout(Duration(milliseconds: timeout))
            .catchError((Object _) {});
      }
    }
    final batch = queue.take(100).toList(growable: false);
    final next = batch.isEmpty ? (since ?? _sequence) : batch.last.sequence;
    _reply(request, 200, {
      'next_batch': 's$next',
      'to_device': {
        'events': [for (final entry in batch) entry.event],
      },
    });
  }

  void _reply(HttpRequest request, int status, Map<String, Object?> body) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(request.response.close());
  }
}

class _Queued {
  _Queued(this.sequence, this.event);
  final int sequence;
  final Map<String, Object?> event;
}
