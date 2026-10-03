import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The small HTTP seam the Matrix client needs, so a browser build can supply
/// its own implementation.
abstract interface class MatrixHttp {
  Future<MatrixHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  });

  void close();
}

class MatrixHttpResponse {
  const MatrixHttpResponse({
    required this.status,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int status;
  final Uint8List body;

  /// Header names in lower case.
  final Map<String, String> headers;
}

class IoMatrixHttp implements MatrixHttp {
  IoMatrixHttp() : _client = HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
  }

  final HttpClient _client;

  @override
  Future<MatrixHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
    required Duration timeout,
  }) async {
    final request = await _client.openUrl(method, uri).timeout(timeout);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close().timeout(timeout);
    final bytes = BytesBuilder(copy: false);
    await response.timeout(timeout).forEach(bytes.add);
    final collected = <String, String>{};
    response.headers.forEach((name, values) {
      collected[name.toLowerCase()] = values.join(',');
    });
    return MatrixHttpResponse(
      status: response.statusCode,
      body: bytes.takeBytes(),
      headers: collected,
    );
  }

  @override
  void close() => _client.close(force: true);
}

class MatrixException implements Exception {
  const MatrixException(
    this.message, {
    this.status,
    this.errcode,
    this.retryAfter,
  });

  final String message;
  final int? status;
  final String? errcode;
  final Duration? retryAfter;

  bool get isRateLimited => status == 429 || errcode == 'M_LIMIT_EXCEEDED';
  bool get isUnknownToken => errcode == 'M_UNKNOWN_TOKEN';

  @override
  String toString() =>
      'MatrixException(${status ?? '-'} ${errcode ?? ''}): $message';
}

/// A signed-in Matrix device. Conest asks for its own device so its traffic
/// never reaches the user's other Matrix clients.
class MatrixSession {
  const MatrixSession({
    required this.homeserver,
    required this.userId,
    required this.deviceId,
    required this.accessToken,
  });

  final Uri homeserver;
  final String userId;
  final String deviceId;
  final String accessToken;

  Map<String, Object?> toJson() => {
    'homeserver': homeserver.toString(),
    'userId': userId,
    'deviceId': deviceId,
    'accessToken': accessToken,
  };

  static MatrixSession? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final homeserver = Uri.tryParse(json['homeserver'] as String? ?? '');
    final userId = json['userId'];
    final deviceId = json['deviceId'];
    final accessToken = json['accessToken'];
    if (homeserver == null ||
        !homeserver.hasScheme ||
        userId is! String ||
        !isMatrixUserId(userId) ||
        deviceId is! String ||
        deviceId.isEmpty ||
        accessToken is! String ||
        accessToken.isEmpty) {
      return null;
    }
    return MatrixSession(
      homeserver: homeserver,
      userId: userId,
      deviceId: deviceId,
      accessToken: accessToken,
    );
  }
}

/// `@localpart:server` with a non-empty server part.
bool isMatrixUserId(String value) =>
    value.length <= 255 && RegExp(r'^@[^:\s]+:[^\s]+$').hasMatch(value);

/// Passwords and access tokens only travel over HTTPS; plain HTTP is
/// accepted for a homeserver on this machine (tests and local servers).
void requireSecureHomeserver(Uri homeserver) {
  const loopback = {'localhost', '127.0.0.1', '::1', '[::1]'};
  if (homeserver.scheme == 'https' ||
      (homeserver.scheme == 'http' && loopback.contains(homeserver.host))) {
    return;
  }
  throw MatrixException(
    'Homeserver $homeserver must use HTTPS to protect your password.',
  );
}

String? matrixServerName(String userId) =>
    isMatrixUserId(userId) ? userId.substring(userId.indexOf(':') + 1) : null;

class MatrixToDeviceEvent {
  const MatrixToDeviceEvent({
    required this.type,
    required this.sender,
    required this.content,
  });

  final String type;
  final String sender;
  final Map<String, dynamic> content;
}

class MatrixSyncResult {
  const MatrixSyncResult({required this.nextBatch, required this.toDevice});

  final String nextBatch;
  final List<MatrixToDeviceEvent> toDevice;
}

/// Minimal Client-Server API (spec v1.19) for the Conest carrier: login,
/// send-to-device and a `/sync` that carries only to-device messages.
class MatrixClient {
  MatrixClient(this.session, {MatrixHttp? http})
    : _http = http ?? IoMatrixHttp();

  final MatrixSession session;
  final MatrixHttp _http;

  /// Rooms, presence and account data are excluded; to-device messages are
  /// always delivered by `/sync` and cannot be filtered out.
  static const String toDeviceOnlyFilter =
      '{"room":{"rooms":[]},"presence":{"types":[]},'
      '"account_data":{"types":[]}}';

  static final Random _random = Random.secure();

  /// Accepts a homeserver URL, a server name, or empty with a full user id,
  /// follows `.well-known` discovery, and checks the server answers.
  static Future<Uri> resolveHomeserver(
    String input, {
    String? userId,
    MatrixHttp? http,
  }) async {
    final client = http ?? IoMatrixHttp();
    try {
      var text = input.trim();
      if (text.isEmpty && userId != null) text = matrixServerName(userId) ?? '';
      if (text.isEmpty) {
        throw const MatrixException('Enter a homeserver or a full user id.');
      }
      var base = Uri.tryParse(text.contains('://') ? text : 'https://$text');
      if (base == null || base.host.isEmpty) {
        throw MatrixException('Not a homeserver address: $text');
      }
      base = base.replace(path: '', query: null, fragment: null);
      try {
        final wellKnown = await client.send(
          'GET',
          base.replace(path: '/.well-known/matrix/client'),
          timeout: const Duration(seconds: 10),
        );
        if (wellKnown.status == 200) {
          final decoded = jsonDecode(utf8.decode(wellKnown.body));
          Object? advertised;
          if (decoded is Map<String, dynamic>) {
            final homeserver = decoded['m.homeserver'];
            if (homeserver is Map) advertised = homeserver['base_url'];
          }
          final parsed = advertised is String ? Uri.tryParse(advertised) : null;
          if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
            base = parsed.replace(
              path: parsed.path.endsWith('/')
                  ? parsed.path.substring(0, parsed.path.length - 1)
                  : parsed.path,
            );
          }
        }
      } on Object {
        // No discovery document: use the address as given.
      }
      requireSecureHomeserver(base!);
      final versions = await client.send(
        'GET',
        base.replace(path: '${base.path}/_matrix/client/versions'),
        timeout: const Duration(seconds: 10),
      );
      final decoded = versions.status == 200
          ? jsonDecode(utf8.decode(versions.body))
          : null;
      if (decoded is! Map<String, dynamic> || decoded['versions'] is! List) {
        throw MatrixException('$base is not a Matrix homeserver.');
      }
      return base;
    } finally {
      if (http == null) client.close();
    }
  }

  /// Password login (`m.login.password`). Homeservers on the Matrix
  /// Authentication Service keep this through their compatibility layer.
  static Future<MatrixSession> login({
    required Uri homeserver,
    required String user,
    required String password,
    String deviceDisplayName = 'Conest',
    String? deviceId,
    MatrixHttp? http,
  }) async {
    requireSecureHomeserver(homeserver);
    final client = http ?? IoMatrixHttp();
    try {
      final response = await _call(
        client,
        'POST',
        homeserver.replace(path: '${homeserver.path}/_matrix/client/v3/login'),
        body: {
          'type': 'm.login.password',
          'identifier': {'type': 'm.id.user', 'user': user},
          'password': password,
          'initial_device_display_name': deviceDisplayName,
          'device_id': ?deviceId,
        },
      );
      final userId = response['user_id'];
      final token = response['access_token'];
      final device = response['device_id'];
      if (userId is! String ||
          !isMatrixUserId(userId) ||
          token is! String ||
          device is! String) {
        throw const MatrixException('The homeserver sent an invalid login.');
      }
      return MatrixSession(
        homeserver: homeserver,
        userId: userId,
        deviceId: device,
        accessToken: token,
      );
    } finally {
      if (http == null) client.close();
    }
  }

  Future<String> whoami() async {
    final response = await _authorized(
      'GET',
      '/_matrix/client/v3/account/whoami',
    );
    final userId = response['user_id'];
    if (userId is! String) {
      throw const MatrixException('Invalid whoami response.');
    }
    return userId;
  }

  /// Sends one event type to specific devices. [messages] maps user id to
  /// device id to event content. A fresh transaction id is used unless one
  /// is given; repeating an id makes the homeserver treat it as a retry.
  Future<void> sendToDevice(
    String type,
    Map<String, Map<String, Map<String, Object?>>> messages, {
    String? transactionId,
  }) => _authorized(
    'PUT',
    '/_matrix/client/v3/sendToDevice/${Uri.encodeComponent(type)}/'
        '${Uri.encodeComponent(transactionId ?? newTransactionId())}',
    body: {'messages': messages},
  );

  /// Long-polls for to-device messages. Passing the returned [nextBatch] as
  /// [since] on the next call acknowledges this batch to the homeserver.
  Future<MatrixSyncResult> sync({
    String? since,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await _authorized(
      'GET',
      '/_matrix/client/v3/sync',
      query: {
        'filter': toDeviceOnlyFilter,
        'timeout': '${timeout.inMilliseconds}',
        'set_presence': 'offline',
        'since': ?since,
      },
      timeout: timeout + const Duration(seconds: 20),
    );
    final nextBatch = response['next_batch'];
    if (nextBatch is! String) {
      throw const MatrixException('Invalid sync response.');
    }
    final events = (response['to_device'] as Map?)?['events'];
    return MatrixSyncResult(
      nextBatch: nextBatch,
      toDevice: [
        if (events is List)
          for (final event in events)
            if (event is Map<String, dynamic> &&
                event['type'] is String &&
                event['sender'] is String &&
                event['content'] is Map<String, dynamic>)
              MatrixToDeviceEvent(
                type: event['type'] as String,
                sender: event['sender'] as String,
                content: event['content'] as Map<String, dynamic>,
              ),
      ],
    );
  }

  Future<void> logout() =>
      _authorized('POST', '/_matrix/client/v3/logout', body: const {});

  void close() => _http.close();

  static String newTransactionId() => List<int>.generate(
    16,
    (_) => _random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  Future<Map<String, dynamic>> _authorized(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) => _call(
    _http,
    method,
    session.homeserver.replace(
      path: '${session.homeserver.path}$path',
      queryParameters: query,
    ),
    body: body,
    accessToken: session.accessToken,
    timeout: timeout,
  );

  static Future<Map<String, dynamic>> _call(
    MatrixHttp http,
    String method,
    Uri uri, {
    Object? body,
    String? accessToken,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await http.send(
      method,
      uri,
      headers: {
        if (body != null) 'content-type': 'application/json',
        'authorization': ?(accessToken == null ? null : 'Bearer $accessToken'),
      },
      body: body == null ? null : utf8.encode(jsonEncode(body)),
      timeout: timeout,
    );
    Object? decoded;
    try {
      decoded = response.body.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(utf8.decode(response.body));
    } on FormatException {
      decoded = null;
    }
    if (response.status >= 200 && response.status < 300) {
      if (decoded is Map<String, dynamic>) return decoded;
      throw MatrixException(
        'Unexpected homeserver response.',
        status: response.status,
      );
    }
    final error = (decoded is Map<String, dynamic>) ? decoded : const {};
    Duration? retryAfter;
    final header = int.tryParse(response.headers['retry-after'] ?? '');
    if (header != null) {
      retryAfter = Duration(seconds: header);
    } else if (error['retry_after_ms'] is int) {
      retryAfter = Duration(milliseconds: error['retry_after_ms'] as int);
    }
    throw MatrixException(
      error['error'] as String? ?? 'Homeserver error ${response.status}.',
      status: response.status,
      errcode: error['errcode'] as String?,
      retryAfter: retryAfter,
    );
  }
}
