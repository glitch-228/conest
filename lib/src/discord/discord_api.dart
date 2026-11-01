import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../limits/network_limiter.dart';

/// A Discord REST call that failed.
class DiscordException implements Exception, ServerSlowDown {
  const DiscordException(
    this.path,
    this.code,
    this.message, {
    this.retryAfter,
    this.global = false,
  });

  final String path;

  /// The HTTP status (0 for no answer).
  final int code;
  final String message;

  /// Seconds Discord asked to wait (429).
  final double? retryAfter;

  /// The 429 is the account-wide limit, not one route's bucket.
  final bool global;

  bool get unauthorized => code == 401;
  bool get forbidden => code == 403;
  bool get rateLimited => code == 429;

  @override
  Duration? get slowDownFor => rateLimited && global
      ? Duration(milliseconds: ((retryAfter ?? 0) * 1000).ceil())
      : null;

  @override
  String toString() => 'Discord $path failed ($code): $message';
}

/// Discord's REST API as one account sees it. Tests substitute a fake.
abstract interface class DiscordApi {
  /// Calls [method] on [path] (like `/channels/1/messages`), with optional
  /// [query] and JSON [body], and returns the decoded JSON answer.
  Future<Object?> call(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  });

  void close();
}

/// A bot token is three base64url parts joined by dots.
bool isValidDiscordBotToken(String token) => RegExp(
  r'^[A-Za-z0-9_-]{18,40}\.[A-Za-z0-9_-]{4,10}\.[A-Za-z0-9_-]{20,80}$',
).hasMatch(token);

/// A snowflake id: up to 20 digits.
bool isDiscordId(String value) => RegExp(r'^\d{15,20}$').hasMatch(value);

/// Which kind of credential the Authorization header carries.
enum DiscordAuth { bot, user }

/// The real REST API over HTTPS. The credential only goes in the
/// Authorization header and never into errors.
class HttpDiscordApi implements DiscordApi {
  HttpDiscordApi(this.token, this.auth, {Uri? apiRoot, HttpClient? client})
    : apiRoot = apiRoot ?? Uri.parse('https://discord.com/api/v10'),
      _client = client ?? (HttpClient()..userAgent = 'Conest');

  final String token;
  final DiscordAuth auth;
  final Uri apiRoot;
  final HttpClient _client;

  static const _maxAnswerBytes = 4 * 1024 * 1024;

  @override
  Future<Object?> call(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final url = apiRoot.replace(
      path: '${apiRoot.path.replaceAll(RegExp(r'/+$'), '')}$path',
      queryParameters: query,
    );
    try {
      return await _send(method, path, url, body).timeout(timeout);
    } on TimeoutException {
      throw DiscordException(path, 0, 'timed out');
    } on SocketException catch (error) {
      throw DiscordException(path, 0, error.message);
    } on HandshakeException {
      throw DiscordException(path, 0, 'TLS handshake failed');
    }
  }

  Future<Object?> _send(
    String method,
    String path,
    Uri url,
    Object? body,
  ) async {
    final request = await _client.openUrl(method, url);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      auth == DiscordAuth.bot ? 'Bot $token' : token,
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > _maxAnswerBytes) {
        throw DiscordException(path, response.statusCode, 'too large');
      }
    }
    Object? decoded;
    if (bytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw DiscordException(path, response.statusCode, 'not JSON');
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    final retry = decoded is Map ? decoded['retry_after'] : null;
    throw DiscordException(
      path,
      response.statusCode,
      (decoded is Map && decoded['message'] is String
              ? decoded['message'] as String
              : 'failed')
          .replaceAll(token, '***'),
      // A hostile value (Infinity, negative, huge) is dropped or capped.
      retryAfter: retry is num && retry.isFinite && retry >= 0
          ? (retry > 86400 ? 86400.0 : retry.toDouble())
          : null,
      global: decoded is Map && decoded['global'] == true,
    );
  }

  @override
  void close() => _client.close(force: true);
}

/// How Conest reaches Discord; tests substitute in-memory servers.
class DiscordNetwork {
  const DiscordNetwork({
    this.api = _http,
    this.pollInterval = const Duration(seconds: 4),
  });

  final DiscordApi Function(String token, DiscordAuth auth) api;

  /// How often the carrier asks the channel for news.
  final Duration pollInterval;

  static DiscordApi _http(String token, DiscordAuth auth) =>
      HttpDiscordApi(token, auth);
}
