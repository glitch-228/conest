import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/group_history_wire.dart';

void main() {
  test(
    'only the expected peer, group and operation can satisfy a request',
    () async {
      final sent = Completer<Map<String, Object?>>();
      final wire = GroupHistoryWire(
        groupId: 'group',
        send: (peer, message) async {
          sent.complete(message);
        },
        localExchange: () => throw UnimplementedError(),
      );
      addTearDown(wire.close);
      final pending = wire.remote('bob').inventory('alice');
      final request = await sent.future;
      final response = {
        ...request,
        'type': 'response',
        'payload': {'entries': [], 'next': null},
      };
      expect(await wire.handle('carol', response), isFalse);
      expect(
        await wire.handle('bob', {...response, 'groupId': 'other'}),
        isFalse,
      );
      expect(
        await wire.handle('bob', {...response, 'operation': 'events'}),
        isFalse,
      );
      expect(await wire.handle('bob', response), isTrue);
      expect((await pending).entries, isEmpty);
      expect(await wire.handle('bob', response), isFalse);
    },
  );

  test(
    'transport acceptance alone times out and a late response is ignored',
    () async {
      final sent = Completer<Map<String, Object?>>();
      final wire = GroupHistoryWire(
        groupId: 'group',
        timeout: const Duration(milliseconds: 30),
        send: (peer, message) async {
          sent.complete(message);
        },
        localExchange: () => throw UnimplementedError(),
      );
      addTearDown(wire.close);
      final pending = wire.remote('bob').inventory('alice');
      final checked = expectLater(pending, throwsA(isA<TimeoutException>()));
      final request = await sent.future;
      await checked;
      expect(
        await wire.handle('bob', {
          ...request,
          'type': 'response',
          'payload': {'entries': [], 'next': null},
        }),
        isFalse,
      );
    },
  );

  test(
    'closing releases pending requests without waiting for network timeout',
    () async {
      final wire = GroupHistoryWire(
        groupId: 'group',
        send: (peer, message) async {},
        localExchange: () => throw UnimplementedError(),
      );
      final pending = wire.remote('bob').inventory('alice');
      final checked = expectLater(pending, throwsStateError);
      wire.close();
      await checked;
      await expectLater(
        wire.remote('bob').inventory('alice'),
        throwsStateError,
      );
    },
  );
}
