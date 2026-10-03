import 'dart:convert';
import 'dart:io';

import 'package:conest/src/matrix_oauth.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(int, String)> _get(Uri url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    return (response.statusCode, await utf8.decoder.bind(response).join());
  } finally {
    client.close();
  }
}

void main() {
  test('the browser redirect completes the callback once', () async {
    final loopback = await MatrixOAuthLoopback.bind();
    addTearDown(loopback.close);
    loopback.expectStateOf(Uri.parse('https://account.x/authorize?state=s1'));
    expect(loopback.redirectUri.host, '127.0.0.1');
    expect(loopback.redirectUri.path, '/callback');

    final stray = await _get(
      loopback.redirectUri.replace(path: '/favicon.ico'),
    );
    expect(stray.$1, 404);
    final empty = await _get(loopback.redirectUri);
    expect(empty.$1, 404);
    // A forged redirect without the sign-in's state is ignored.
    final forged = await _get(
      loopback.redirectUri.replace(
        queryParameters: {'error': 'access_denied', 'state': 'other'},
      ),
    );
    expect(forged.$1, 404);

    final redirect = loopback.redirectUri.replace(
      queryParameters: {'code': 'abc', 'state': 's1'},
    );
    final page = await _get(redirect);
    expect(page.$1, 200);
    expect(page.$2, contains('Signed in'));
    final callback = await loopback.callback;
    expect(callback.queryParameters, {'code': 'abc', 'state': 's1'});
    expect(
      callback.replace(query: '').toString(),
      startsWith('http://127.0.0.1:'),
    );

    // Only the first redirect counts.
    final again = await _get(redirect);
    expect(again.$1, 404);
  });

  test('an error redirect is handed on for the SDK to report', () async {
    final loopback = await MatrixOAuthLoopback.bind();
    addTearDown(loopback.close);
    loopback.expectStateOf(Uri.parse('https://account.x/authorize?state=s'));
    final page = await _get(
      loopback.redirectUri.replace(
        queryParameters: {'error': 'access_denied', 'state': 's'},
      ),
    );
    expect(page.$2, contains('not completed'));
    expect((await loopback.callback).queryParameters['error'], 'access_denied');
  });

  test('cancelling fails the wait', () async {
    final loopback = await MatrixOAuthLoopback.bind();
    addTearDown(loopback.close);
    loopback.cancel();
    await expectLater(loopback.callback, throwsStateError);
  });
}
