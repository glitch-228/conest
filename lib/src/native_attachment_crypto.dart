import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _EncryptNative =
    Bool Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
    );
typedef _EncryptDart =
    bool Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
    );
typedef _DecryptNative =
    Bool Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
      Pointer<Uint8>,
      UintPtr,
    );
typedef _DecryptDart =
    bool Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
    );
typedef _ErrorNative = Pointer<Utf8> Function();
typedef _ErrorDart = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _HashFileNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _HashFileDart = Pointer<Utf8> Function(Pointer<Utf8>);

class _NativeAttachmentCryptoBindings {
  _NativeAttachmentCryptoBindings(DynamicLibrary library)
    : hashFile = _lookupHashFile(library),
      encrypt = library.lookupFunction<_EncryptNative, _EncryptDart>(
        'conest_attachment_encrypt_block',
      ),
      decrypt = library.lookupFunction<_DecryptNative, _DecryptDart>(
        'conest_attachment_decrypt_block',
      ),
      lastError = library.lookupFunction<_ErrorNative, _ErrorDart>(
        'conest_last_error',
      ),
      freeString = library.lookupFunction<_FreeNative, _FreeDart>(
        'conest_string_free',
      );

  final _EncryptDart encrypt;
  final _HashFileDart? hashFile;
  static _HashFileDart? _lookupHashFile(DynamicLibrary library) {
    try {
      return library.lookupFunction<_HashFileNative, _HashFileDart>(
        'conest_attachment_hash_file',
      );
    } catch (_) {
      return null;
    }
  }

  final _DecryptDart decrypt;
  final _ErrorDart lastError;
  final _FreeDart freeString;

  String takeLastError() {
    final pointer = lastError();
    if (pointer == nullptr) return 'Unknown native attachment error.';
    try {
      final value = pointer.toDartString();
      return value.isEmpty ? 'Unknown native attachment error.' : value;
    } finally {
      freeString(pointer);
    }
  }
}

class NativeEncryptedAttachmentBlock {
  const NativeEncryptedAttachmentBlock({
    required this.ciphertext,
    required this.plaintextSha256,
  });

  final Uint8List ciphertext;
  final Uint8List plaintextSha256;
}

/// Zero-JSON binary bridge to the Rust XChaCha20-Poly1305/SHA-256 block
/// implementation. A missing native library is normal in pure-Dart tests;
/// production builds bundle it for Android, Linux, and Windows and the
/// controller retains a protocol-compatible Dart fallback.
class NativeAttachmentCrypto {
  NativeAttachmentCrypto._(this._bindings);

  static const int _keyLength = 32;
  static const int _nonceLength = 24;
  static const int _hashLength = 32;
  static const int _tagLength = 16;
  static const int _maximumBlockLength = 4 * 1024 * 1024;

  final _NativeAttachmentCryptoBindings _bindings;

  ({int sizeBytes, String sha256Base64})? hashFile(String path) {
    final hash = _bindings.hashFile;
    if (hash == null) return null;
    final input = path.toNativeUtf8();
    try {
      final output = hash(input);
      if (output == nullptr) throw StateError(_bindings.takeLastError());
      try {
        final value = jsonDecode(output.toDartString()) as Map<String, dynamic>;
        return (
          sizeBytes: value['sizeBytes'] as int,
          sha256Base64: value['sha256Base64'] as String,
        );
      } finally {
        _bindings.freeString(output);
      }
    } finally {
      malloc.free(input);
    }
  }

  static NativeAttachmentCrypto? tryCreate() {
    for (final candidate in _candidateLibraryPaths()) {
      try {
        return NativeAttachmentCrypto._(
          _NativeAttachmentCryptoBindings(DynamicLibrary.open(candidate)),
        );
      } catch (_) {
        // Native acceleration is optional for source/tests and mandatory only
        // in packaged builds, where the same library also provides Iroh.
      }
    }
    return null;
  }

  NativeEncryptedAttachmentBlock encrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
    required Uint8List plaintext,
  }) {
    _validateCommon(key: key, nonce: nonce, aad: aad);
    if (plaintext.isEmpty || plaintext.length > _maximumBlockLength) {
      throw const FormatException('Native attachment block size is invalid.');
    }
    final keyPointer = calloc<Uint8>(_keyLength);
    final noncePointer = calloc<Uint8>(_nonceLength);
    final aadPointer = calloc<Uint8>(aad.length);
    final plaintextPointer = calloc<Uint8>(plaintext.length);
    final ciphertextPointer = calloc<Uint8>(plaintext.length + _tagLength);
    final hashPointer = calloc<Uint8>(_hashLength);
    try {
      keyPointer.asTypedList(_keyLength).setAll(0, key);
      noncePointer.asTypedList(_nonceLength).setAll(0, nonce);
      aadPointer.asTypedList(aad.length).setAll(0, aad);
      plaintextPointer.asTypedList(plaintext.length).setAll(0, plaintext);
      final succeeded = _bindings.encrypt(
        keyPointer,
        noncePointer,
        aadPointer,
        aad.length,
        plaintextPointer,
        plaintext.length,
        ciphertextPointer,
        plaintext.length + _tagLength,
        hashPointer,
      );
      if (!succeeded) throw StateError(_bindings.takeLastError());
      return NativeEncryptedAttachmentBlock(
        ciphertext: Uint8List.fromList(
          ciphertextPointer.asTypedList(plaintext.length + _tagLength),
        ),
        plaintextSha256: Uint8List.fromList(
          hashPointer.asTypedList(_hashLength),
        ),
      );
    } finally {
      keyPointer.asTypedList(_keyLength).fillRange(0, _keyLength, 0);
      plaintextPointer
          .asTypedList(plaintext.length)
          .fillRange(0, plaintext.length, 0);
      calloc.free(keyPointer);
      calloc.free(noncePointer);
      calloc.free(aadPointer);
      calloc.free(plaintextPointer);
      calloc.free(ciphertextPointer);
      calloc.free(hashPointer);
    }
  }

  Uint8List decrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
    required Uint8List ciphertext,
    required Uint8List expectedPlaintextSha256,
  }) {
    _validateCommon(key: key, nonce: nonce, aad: aad);
    if (expectedPlaintextSha256.length != _hashLength ||
        ciphertext.length <= _tagLength ||
        ciphertext.length > _maximumBlockLength + _tagLength) {
      throw const FormatException('Native attachment ciphertext is invalid.');
    }
    final plaintextLength = ciphertext.length - _tagLength;
    final keyPointer = calloc<Uint8>(_keyLength);
    final noncePointer = calloc<Uint8>(_nonceLength);
    final aadPointer = calloc<Uint8>(aad.length);
    final ciphertextPointer = calloc<Uint8>(ciphertext.length);
    final hashPointer = calloc<Uint8>(_hashLength);
    final plaintextPointer = calloc<Uint8>(plaintextLength);
    try {
      keyPointer.asTypedList(_keyLength).setAll(0, key);
      noncePointer.asTypedList(_nonceLength).setAll(0, nonce);
      aadPointer.asTypedList(aad.length).setAll(0, aad);
      ciphertextPointer.asTypedList(ciphertext.length).setAll(0, ciphertext);
      hashPointer.asTypedList(_hashLength).setAll(0, expectedPlaintextSha256);
      final succeeded = _bindings.decrypt(
        keyPointer,
        noncePointer,
        aadPointer,
        aad.length,
        ciphertextPointer,
        ciphertext.length,
        hashPointer,
        plaintextPointer,
        plaintextLength,
      );
      if (!succeeded) throw StateError(_bindings.takeLastError());
      return Uint8List.fromList(plaintextPointer.asTypedList(plaintextLength));
    } finally {
      keyPointer.asTypedList(_keyLength).fillRange(0, _keyLength, 0);
      plaintextPointer
          .asTypedList(plaintextLength)
          .fillRange(0, plaintextLength, 0);
      calloc.free(keyPointer);
      calloc.free(noncePointer);
      calloc.free(aadPointer);
      calloc.free(ciphertextPointer);
      calloc.free(hashPointer);
      calloc.free(plaintextPointer);
    }
  }

  static void _validateCommon({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) {
    if (key.length != _keyLength ||
        nonce.length != _nonceLength ||
        aad.isEmpty) {
      throw const FormatException('Native attachment crypto input is invalid.');
    }
  }

  static Iterable<String> _candidateLibraryPaths() sync* {
    final override = Platform.environment['CONEST_NATIVE_LIBRARY'];
    if (override != null && override.trim().isNotEmpty) {
      yield override.trim();
    }
    final name = Platform.isWindows
        ? 'conest_native.dll'
        : Platform.isMacOS
        ? 'libconest_native.dylib'
        : 'libconest_native.so';
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final executableDirectory = File(Platform.resolvedExecutable).parent.path;
      yield '$executableDirectory${Platform.pathSeparator}$name';
      yield '$executableDirectory${Platform.pathSeparator}lib${Platform.pathSeparator}$name';
    }
    yield name;
  }
}
