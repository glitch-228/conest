import 'dart:async';
import 'dart:io';

/// Receives the browser's redirect at the end of a Matrix browser sign-in
/// (OAuth 2.0 for native apps, RFC 8252): a one-shot HTTP listener on the
/// loopback interface, on every platform.
class MatrixOAuthLoopback {
  MatrixOAuthLoopback._(this._server) {
    _server.listen(_handle, onError: (Object _) {});
    // A cancel may land before anyone waits on the callback.
    _callback.future.ignore();
  }

  /// Listens on a free loopback port.
  static Future<MatrixOAuthLoopback> bind() async => MatrixOAuthLoopback._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  static const _path = '/callback';

  final HttpServer _server;
  final _callback = Completer<Uri>();

  Uri get redirectUri => Uri.parse('http://127.0.0.1:${_server.port}$_path');

  /// The full redirect URL the browser was sent to, carrying either the
  /// authorization code or an error, and the state to check.
  Future<Uri> get callback => _callback.future;

  void cancel([Object? reason]) {
    if (_callback.isCompleted) return;
    _callback.completeError(
      reason ?? StateError('The browser sign-in was cancelled.'),
    );
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final response = request.response;
    final isCallback =
        request.method == 'GET' &&
        request.uri.path == _path &&
        (query.containsKey('code') || query.containsKey('error'));
    if (!isCallback || _callback.isCompleted) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(
        '<!doctype html><meta charset="utf-8"><title>Conest</title>'
        '<body style="font-family:sans-serif;text-align:center;padding:3em">'
        '<h2>${query.containsKey('error') ? 'Sign-in was not completed' : 'Signed in'}</h2>'
        '<p>You can close this tab and return to Conest.</p></body>',
      );
    await response.close();
    _callback.complete(redirectUri.replace(query: request.uri.query));
  }
}
