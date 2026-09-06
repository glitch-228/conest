import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/native_attachment_crypto.dart';

void main() {
  test(
    'Rust whole-file hash handles UTF-8 paths and missing files',
    () async {
      final native = NativeAttachmentCrypto.tryCreate()!;
      final root = await Directory.systemTemp.createTemp('conest-native-hash-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/тест.bin');
      final bytes = Uint8List.fromList(
        List<int>.generate(2 * 1024 * 1024 + 7, (i) => i % 251),
      );
      await file.writeAsBytes(bytes);
      final result = native.hashFile(file.path);
      expect(
        result,
        isNotNull,
        reason: 'The native library must export whole-file hashing.',
      );
      expect(result!.sizeBytes, bytes.length);
      expect(
        result.sha256Base64,
        base64Encode((await Sha256().hash(bytes)).bytes),
      );
      await file.writeAsBytes([]);
      expect(
        native.hashFile(file.path)!.sha256Base64,
        base64Encode((await Sha256().hash([])).bytes),
      );
      expect(() => native.hashFile('${root.path}/missing'), throwsStateError);
    },
    skip: NativeAttachmentCrypto.tryCreate() == null
        ? 'Build conest_native to test FFI interop.'
        : false,
  );

  test(
    'Rust attachment blocks remain byte-compatible with the Dart fallback',
    () async {
      final native = NativeAttachmentCrypto.tryCreate()!;
      final key = Uint8List.fromList(
        List<int>.generate(32, (index) => index * 7 & 0xff),
      );
      final nonce = Uint8List.fromList(
        List<int>.generate(24, (index) => index * 11 & 0xff),
      );
      final aad = Uint8List.fromList(
        List<int>.generate(137, (index) => index * 13 & 0xff),
      );
      final plaintext = Uint8List.fromList(
        List<int>.generate(4 * 1024 * 1024, (index) => index * 17 & 0xff),
      );
      final dartCipher = Xchacha20.poly1305Aead();

      final nativeEncrypted = native.encrypt(
        key: key,
        nonce: nonce,
        aad: aad,
        plaintext: plaintext,
      );
      final tagStart = nativeEncrypted.ciphertext.length - 16;
      final dartDecrypted = await dartCipher.decrypt(
        SecretBox(
          nativeEncrypted.ciphertext.sublist(0, tagStart),
          nonce: nonce,
          mac: Mac(nativeEncrypted.ciphertext.sublist(tagStart)),
        ),
        secretKey: SecretKey(key),
        aad: aad,
      );
      expect(dartDecrypted, orderedEquals(plaintext));
      expect(
        nativeEncrypted.plaintextSha256,
        orderedEquals((await Sha256().hash(plaintext)).bytes),
      );

      final dartEncrypted = await dartCipher.encrypt(
        plaintext,
        secretKey: SecretKey(key),
        nonce: nonce,
        aad: aad,
      );
      final packed = Uint8List.fromList(<int>[
        ...dartEncrypted.cipherText,
        ...dartEncrypted.mac.bytes,
      ]);
      final nativeDecrypted = native.decrypt(
        key: key,
        nonce: nonce,
        aad: aad,
        ciphertext: packed,
        expectedPlaintextSha256: nativeEncrypted.plaintextSha256,
      );
      expect(nativeDecrypted, orderedEquals(plaintext));

      packed[42] ^= 0x80;
      expect(
        () => native.decrypt(
          key: key,
          nonce: nonce,
          aad: aad,
          ciphertext: packed,
          expectedPlaintextSha256: nativeEncrypted.plaintextSha256,
        ),
        throwsStateError,
      );
    },
    skip: NativeAttachmentCrypto.tryCreate() == null
        ? 'Build conest_native or set CONEST_NATIVE_LIBRARY to test FFI interop.'
        : false,
  );
}
