import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/src/group_file_transport.dart';

void main() {
  test(
    'availability window includes requests still draining after timeout',
    () async {
      final drain = Completer<void>();
      final allDraining = Completer<void>();
      var cancellations = 0;
      final client = GroupFileTransport(
        groupId: 'group',
        eventId: 'event',
        authorized: (_) => true,
        timeout: const Duration(milliseconds: 20),
        sendEncrypted: (_, _, _) async {},
        cancelAndDrain: (_, _) async {
          if (++cancellations == 4) allDraining.complete();
          await drain.future;
        },
      );
      final checks = List.generate(
        4,
        (_) => expectLater(
          client.queryAvailability('peer'),
          throwsA(isA<TimeoutException>()),
        ),
      );
      await allDraining.future;
      await expectLater(client.queryAvailability('peer'), throwsStateError);
      drain.complete();
      await Future.wait(checks);
      await client.close();
    },
  );

  test(
    'availability and binary pieces cross a bound authenticated channel',
    () async {
      late GroupFileTransport client;
      late GroupFileTransport server;
      final cancelled = <String>[];
      client = GroupFileTransport(
        groupId: 'group',
        eventId: 'event',
        authorized: (peer) => peer == 'server',
        sendEncrypted: (peer, id, frame) async {
          await server.receive('client', frame);
        },
        cancelAndDrain: (peer, id) async {
          cancelled.add(id);
        },
      );
      server = GroupFileTransport(
        groupId: 'group',
        eventId: 'event',
        authorized: (peer) => peer == 'client',
        sendEncrypted: (peer, id, frame) async {
          await client.receive('server', frame);
        },
        cancelAndDrain: (peer, id) async {},
        availablePieces: (peer) async => {0, 2},
        readPiece: (peer, piece) async =>
            piece == 0 ? Uint8List.fromList([0, 255, 7]) : null,
      );
      expect(await client.queryAvailability('server'), {0, 2});
      expect(await client.requestPiece('server', 0, 3), [0, 255, 7]);
      await expectLater(client.requestPiece('server', 1, 3), throwsStateError);
      expect(cancelled, hasLength(3));
      await client.close();
      await server.close();
    },
  );

  test(
    'wrong event and wrong authenticated peer cannot satisfy a request',
    () async {
      late GroupFileTransport client;
      client = GroupFileTransport(
        groupId: 'group',
        eventId: 'event',
        authorized: (_) => true,
        timeout: const Duration(milliseconds: 20),
        sendEncrypted: (peer, id, frame) async {
          Uint8List reply(String event) {
            final json = utf8.encode(
              jsonEncode({
                'version': 1,
                'groupId': 'group',
                'eventId': event,
                'requestId': id,
                'type': 'piece',
                'piece': 0,
              }),
            );
            final output = Uint8List(4 + json.length + 1);
            ByteData.sublistView(output).setUint32(0, json.length);
            output.setRange(4, 4 + json.length, json);
            return output;
          }

          expect(await client.receive('server', reply('other')), isFalse);
          expect(await client.receive('impostor', reply('event')), isFalse);
        },
        cancelAndDrain: (_, _) async {},
      );
      await expectLater(
        client.requestPiece('server', 0, 1),
        throwsA(isA<Exception>()),
      );
      await client.close();
    },
  );
}
