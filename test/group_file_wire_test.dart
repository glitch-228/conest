import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/group_file_wire.dart';

void main() {
  test('binary replies bind peer, file, index and exact length', () async {
    final sent = Completer<Map<String, Object?>>();
    final canceled = <String>[];
    final wire = GroupFileWire(
      eventId: 'file',
      send: (_, message) async => sent.complete(message),
      cancel: (_, id) async => canceled.add(id),
    );
    final pending = wire.requestPiece('peer', 2, 3);
    final id = (await sent.future)['requestId'] as String;
    bool receive(String peer, String file, int piece, int length) =>
        wire.receive(
          peer: peer,
          attachmentEventId: file,
          requestId: id,
          piece: piece,
          bytes: Uint8List(length),
        );
    expect(receive('other', 'file', 2, 3), isFalse);
    expect(receive('peer', 'other', 2, 3), isFalse);
    expect(receive('peer', 'file', 1, 3), isFalse);
    expect(receive('peer', 'file', 2, 4), isFalse);
    expect(receive('peer', 'file', 2, 3), isTrue);
    expect((await pending).length, 3);
    expect(canceled, [id]);
    expect(receive('peer', 'file', 2, 3), isFalse);
    wire.close();
  });

  test(
    'timeout waits for resource cancellation and ignores late replies',
    () async {
      final sent = Completer<Map<String, Object?>>();
      final cancelStarted = Completer<void>();
      final cancelDone = Completer<void>();
      final wire = GroupFileWire(
        eventId: 'file',
        timeout: const Duration(milliseconds: 20),
        send: (_, message) async => sent.complete(message),
        cancel: (_, _) async {
          cancelStarted.complete();
          await cancelDone.future;
        },
      );
      var finished = false;
      final pending = wire.requestPiece('peer', 0, 1);
      final checked = expectLater(
        pending.whenComplete(() => finished = true),
        throwsA(isA<TimeoutException>()),
      );
      final id = (await sent.future)['requestId'] as String;
      await cancelStarted.future;
      expect(finished, isFalse);
      expect(
        wire.receive(
          peer: 'peer',
          attachmentEventId: 'file',
          requestId: id,
          piece: 0,
          bytes: Uint8List(1),
        ),
        isFalse,
      );
      cancelDone.complete();
      await checked;
      wire.close();
    },
  );
}
