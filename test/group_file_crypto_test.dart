import 'dart:typed_data';

import 'package:conest/src/group_file_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = List<int>.filled(32, 7);
  GroupFileBinaryHeader header({String? epoch}) => GroupFileBinaryHeader(
    groupId: 'group-1',
    eventId: 'e' * 64,
    requestId: 'a' * 32,
    sender: 'dev-a',
    recipient: 'dev-b',
    epoch: epoch,
  );

  test('epoch frames round-trip and name their epoch', () async {
    final frame = await encryptGroupFileBinary(
      pairwiseKey: key,
      header: header(epoch: 'f' * 32),
      cleartext: Uint8List.fromList([1, 2, 3]),
    );
    final peeked = peekGroupFileBinary(frame);
    expect(peeked.epoch, 'f' * 32);
    expect(peeked.toJson()['version'], 2);
    expect(
      await decryptGroupFileBinary(
        pairwiseKey: key,
        expected: header(epoch: 'f' * 32),
        frame: frame,
      ),
      [1, 2, 3],
    );
  });

  test('version 1 frames are unchanged', () async {
    final frame = await encryptGroupFileBinary(
      pairwiseKey: key,
      header: header(),
      cleartext: Uint8List.fromList([9]),
    );
    final peeked = peekGroupFileBinary(frame);
    expect(peeked.epoch, isNull);
    expect(peeked.toJson(), isNot(contains('epoch')));
    expect(peeked.toJson()['version'], 1);
  });

  test('an epoch frame cannot be read as another epoch or as v1', () async {
    final frame = await encryptGroupFileBinary(
      pairwiseKey: key,
      header: header(epoch: 'f' * 32),
      cleartext: Uint8List.fromList([1]),
    );
    await expectLater(
      () => decryptGroupFileBinary(
        pairwiseKey: key,
        expected: header(epoch: '0' * 32),
        frame: frame,
      ),
      throwsFormatException,
    );
    await expectLater(
      () => decryptGroupFileBinary(
        pairwiseKey: key,
        expected: header(),
        frame: frame,
      ),
      throwsFormatException,
    );
  });

  test('malformed epochs and versions are rejected', () {
    final base = header(epoch: 'f' * 32).toJson();
    for (final json in <Map<String, dynamic>>[
      {...base, 'epoch': 'F' * 32},
      {...base, 'epoch': 'f' * 31},
      {...base, 'version': 1},
      {...header().toJson(), 'version': 2},
    ]) {
      expect(() => GroupFileBinaryHeader.decode(json), throwsFormatException);
    }
  });
}
