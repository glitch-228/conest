// The native Matrix client against a real homeserver. Runs only when both
// CONEST_MATRIX_HOMESERVER (open registration) and a conest_native build
// with the Matrix client are available; the debug workflow provides both.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conest/src/matrix_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final homeserverUrl = Platform.environment['CONEST_MATRIX_HOMESERVER'];
  final native = NativeMatrixClient.tryCreate();
  if (homeserverUrl == null || homeserverUrl.isEmpty || native == null) {
    test(
      'native Matrix client',
      () {},
      skip: 'Needs CONEST_MATRIX_HOMESERVER and a native Matrix client build.',
    );
    return;
  }
  final homeserver = Uri.parse(homeserverUrl);
  final suffix = Random.secure().nextInt(1 << 30).toRadixString(36);

  Future<Map<String, dynamic>> http(
    String method,
    String path, {
    Object? body,
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        homeserver.replace(path: path),
      );
      request.headers.contentType = ContentType.json;
      if (token != null) {
        request.headers.set('authorization', 'Bearer $token');
      }
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 200, reason: '$method $path: $text');
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<String> register(String name) async {
    final response = await http(
      'POST',
      '/_matrix/client/v3/register',
      body: {
        'username': '$name$suffix',
        'password': 'pw-$name',
        'auth': {'type': 'm.login.dummy'},
      },
    );
    return response['access_token'] as String;
  }

  Future<void> waitFor(Future<bool> Function() ready, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    fail(reason);
  }

  test(
    'sign in, sync, DM both ways, restore and log out',
    () async {
      await register('alice');
      final bobToken = await register('bob');
      final store = await Directory.systemTemp.createTemp('conest-matrix-');
      addTearDown(() => store.delete(recursive: true));
      final storeParameters = {
        'storePath': store.path,
        'passphrase': 'test-store-passphrase',
      };

      final session = await native.request('login_password', {
        ...storeParameters,
        'homeserver': homeserverUrl,
        'user': 'alice$suffix',
        'password': 'pw-alice',
        'deviceId': 'CONEST_TEST',
      });
      expect(session['userId'], startsWith('@alice$suffix:'));
      expect(session['deviceId'], 'CONEST_TEST');
      expect(session['accessToken'], isNotEmpty);

      final syncs = <Map<String, dynamic>>[];
      final subscription = native.events.listen(syncs.add);
      addTearDown(subscription.cancel);
      await native.request('start_sync');

      final bobId =
          '@bob$suffix:${session['userId'].toString().split(':').last}';
      final dm = await native.request('create_dm', {'userId': bobId});
      final roomId = dm['roomId'] as String;
      await http(
        'POST',
        '/_matrix/client/v3/join/${Uri.encodeComponent(roomId)}',
        body: const {},
        token: bobToken,
      );
      await http(
        'PUT',
        '/_matrix/client/v3/rooms/${Uri.encodeComponent(roomId)}/send/'
            'm.room.message/t$suffix',
        body: {'msgtype': 'm.text', 'body': 'hello alice'},
        token: bobToken,
      );

      await waitFor(() async {
        final page = await native.request('messages', {
          'roomId': roomId,
          'limit': 20,
        });
        return (page['events'] as List).any(
          (event) => (event as Map)['content']?['body'] == 'hello alice',
        );
      }, 'Bob\'s message never arrived');
      expect(syncs.where((event) => event['type'] == 'sync'), isNotEmpty);

      final sent = await native.request('send_text', {
        'roomId': roomId,
        'body': 'hi bob',
      });
      expect(sent['eventId'], startsWith('\$'));

      final rooms = (await native.request('rooms'))['rooms'] as List;
      final room = rooms.cast<Map<String, dynamic>>().singleWhere(
        (room) => room['roomId'] == roomId,
      );
      expect(room['direct'], isTrue);
      expect(room['invited'], isFalse);

      await native.request('restore', {...storeParameters, 'session': session});
      final restoredRooms = (await native.request('rooms'))['rooms'] as List;
      expect(
        restoredRooms.cast<Map<String, dynamic>>().map(
          (room) => room['roomId'],
        ),
        contains(roomId),
      );

      await native.request('logout');
      await expectLater(
        native.request('rooms'),
        throwsA(isA<MatrixClientException>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
