import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/native_ed25519.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// Runs against a built conest_native (CONEST_NATIVE_LIBRARY=…/libconest_
// native.so); without one there is nothing native to compare.
void main() {
  final native = NativeEd25519.instance;
  final skip = native == null ? 'No conest_native with Ed25519 here' : null;

  test(
    'native Ed25519 signs as Dart does and checks Dart signatures',
    () async {
      final ed = Ed25519();
      for (var round = 0; round < 8; round++) {
        final pair = await ed.newKeyPair();
        final seed = await pair.extractPrivateKeyBytes();
        final publicKey = (await pair.extractPublicKey()).bytes;
        final message = utf8.encode('conest group call frame $round');
        final ours = native!.sign(seed, message)!;
        final dart = await ed.sign(message, keyPair: pair);
        // Ed25519 is deterministic: the same bytes either way.
        expect(ours, dart.bytes);
        expect(native.verify(publicKey, message, dart.bytes), isTrue);
        expect(
          await ed.verify(
            message,
            signature: Signature(
              ours,
              publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
            ),
          ),
          isTrue,
        );
        final forged = Uint8List.fromList(ours)..[3] ^= 1;
        expect(native.verify(publicKey, message, forged), isFalse);
        expect(
          native.verify(publicKey, utf8.encode('another frame'), ours),
          isFalse,
        );
      }
      expect(native!.sign(List.filled(31, 0), [1]), isNull);
      expect(
        native.verify(List.filled(32, 0), [1], List.filled(63, 0)),
        isFalse,
      );
    },
    skip: skip,
  );
}
