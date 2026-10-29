import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A Bot API call that Telegram answered with `ok: false` (or an HTTP error).
class TelegramBotException implements Exception {
  const TelegramBotException(
    this.method,
    this.code,
    this.description, {
    this.retryAfter,
  });

  final String method;

  /// The Bot API error code (an HTTP status): 401 bad token, 409 another
  /// poller, 429 rate limit.
  final int code;
  final String description;

  /// Seconds Telegram asked to wait (429).
  final int? retryAfter;

  bool get unauthorized => code == 401 || code == 404;
  bool get conflict => code == 409;
  bool get rateLimited => code == 429;

  @override
  String toString() => 'Telegram $method failed ($code): $description';
}

/// One bot's Bot API (https://core.telegram.org/bots/api). Tests substitute
/// an in-memory one.
abstract interface class TelegramBotApi {
  /// Calls [method] with JSON [parameters] and returns `result`.
  Future<Object?> call(
    String method, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(seconds: 30),
  ]);

  void close();
}

/// The shape of a bot token: `<bot id>:<35 characters>`.
bool isValidTelegramBotToken(String token) =>
    RegExp(r'^\d{5,15}:[A-Za-z0-9_-]{30,64}$').hasMatch(token);

/// A bot's username as Telegram allows it: 5 to 32 letters, digits and
/// underscores, ending in "bot". Lower case here, so addresses compare.
bool isValidTelegramBotUsername(String name) =>
    RegExp(r'^[a-z][a-z0-9_]{3,30}bot$').hasMatch(name);

/// The real Bot API over HTTPS. The token only ever goes into the URL path
/// of [apiRoot], and error text never repeats it.
class HttpTelegramBotApi implements TelegramBotApi {
  HttpTelegramBotApi(this.token, {Uri? apiRoot, HttpClient? client})
    : apiRoot = apiRoot ?? Uri.parse('https://api.telegram.org'),
      _client = client ?? (HttpClient()..userAgent = null);

  final String token;
  final Uri apiRoot;
  final HttpClient _client;

  /// Largest answer read: a batch of updates is far smaller.
  static const _maxAnswerBytes = 4 * 1024 * 1024;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    final url = apiRoot.replace(
      path: '${apiRoot.path.replaceAll(RegExp(r'/+$'), '')}/bot$token/$method',
    );
    try {
      return await _post(method, url, parameters).timeout(timeout);
    } on TimeoutException {
      throw TelegramBotException(method, 0, 'timed out');
    } on SocketException catch (error) {
      throw TelegramBotException(method, 0, error.message);
    } on HandshakeException {
      throw TelegramBotException(method, 0, 'TLS handshake failed');
    } on TelegramBotException {
      rethrow;
    } catch (error) {
      // Other I/O errors (HttpException, FormatException, ...) can quote the
      // URL, which holds the token.
      throw TelegramBotException(
        method,
        0,
        error.toString().replaceAll(token, '***'),
      );
    }
  }

  Future<Object?> _post(
    String method,
    Uri url,
    Map<String, Object?> parameters,
  ) async {
    final request = await _client.postUrl(url);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(parameters)));
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > _maxAnswerBytes) {
        throw TelegramBotException(method, response.statusCode, 'too large');
      }
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw TelegramBotException(
        method,
        response.statusCode,
        'not a Bot API answer',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw TelegramBotException(method, response.statusCode, 'bad answer');
    }
    if (decoded['ok'] == true) return decoded['result'];
    final parameters2 = decoded['parameters'];
    final retry = parameters2 is Map ? parameters2['retry_after'] : null;
    throw TelegramBotException(
      method,
      decoded['error_code'] is int
          ? decoded['error_code'] as int
          : response.statusCode,
      decoded['description'] is String
          ? (decoded['description'] as String).replaceAll(token, '***')
          : 'failed',
      retryAfter: retry is int ? retry : null,
    );
  }

  @override
  void close() => _client.close(force: true);
}

/// How Conest reaches the Bot API; tests substitute in-memory bots.
class TelegramNetwork {
  const TelegramNetwork({this.botApi = _httpBotApi});

  final TelegramBotApi Function(String token) botApi;

  static TelegramBotApi _httpBotApi(String token) => HttpTelegramBotApi(token);
}
