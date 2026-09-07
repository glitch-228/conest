import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/attachment_block_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'block workers keep the event loop responsive and reject tampering',
    () async {
      final worker = AttachmentBlockWorker();
      addTearDown(worker.close);
      final key = Uint8List(32);
      final nonce = Uint8List(24);
      final aad = Uint8List.fromList([1, 2, 3]);
      final bytes = Uint8List.fromList(
        List<int>.generate(4 * 1024 * 1024, (i) => i % 251),
      );
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      final encrypted = await Future.wait(
        List.generate(
          4,
          (_) => worker.encrypt(
            key: key,
            nonce: nonce,
            aad: aad,
            plaintext: bytes,
          ),
        ),
      );
      timer.cancel();
      expect(ticks, greaterThan(2));
      final block = encrypted.first;
      expect(
        await worker.decrypt(
          key: key,
          nonce: nonce,
          aad: aad,
          ciphertext: block.ciphertext,
          expectedHash: block.hash,
        ),
        bytes,
      );
      final corrupt = Uint8List.fromList(block.ciphertext)..[42] ^= 1;
      await expectLater(
        worker.decrypt(
          key: key,
          nonce: nonce,
          aad: aad,
          ciphertext: corrupt,
          expectedHash: block.hash,
        ),
        throwsStateError,
      );
      final wrongHash = Uint8List.fromList(block.hash)..[0] ^= 1;
      await expectLater(
        worker.decrypt(
          key: key,
          nonce: nonce,
          aad: aad,
          ciphertext: block.ciphertext,
          expectedHash: wrongHash,
        ),
        throwsStateError,
      );
      expect(
        await worker.decrypt(
          key: key,
          nonce: nonce,
          aad: aad,
          ciphertext: block.ciphertext,
          expectedHash: block.hash,
        ),
        bytes,
      );
      worker.close();
      await expectLater(
        worker.encrypt(key: key, nonce: nonce, aad: aad, plaintext: bytes),
        throwsStateError,
      );
    },
  );
}
