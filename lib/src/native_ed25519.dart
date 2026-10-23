import 'dart:ffi';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';

import 'matrix_native.dart' show conestNativeLibraryCandidates;

typedef _SignNative =
    Bool Function(Pointer<Uint8>, Pointer<Uint8>, UintPtr, Pointer<Uint8>);
typedef _SignDart =
    bool Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>);
typedef _VerifyNative =
    Bool Function(Pointer<Uint8>, Pointer<Uint8>, UintPtr, Pointer<Uint8>);
typedef _VerifyDart =
    bool Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>);

/// Ed25519 in `conest_native` (signing.rs). Group calls sign and check every
/// audio frame: in Dart that took about 3 ms each on a desktop, and many
/// times that on a phone, which kept the main isolate busy for the whole
/// call. Null where the library lacks it (tests, older builds): callers
/// fall back to Dart.
class NativeEd25519 {
  NativeEd25519._(this._sign, this._verify);

  static NativeEd25519? _instance;
  static bool _tried = false;

  static NativeEd25519? get instance {
    if (!_tried) {
      _tried = true;
      _instance = _open();
    }
    return _instance;
  }

  static NativeEd25519? _open() {
    for (final candidate in conestNativeLibraryCandidates()) {
      try {
        final library = DynamicLibrary.open(candidate);
        return NativeEd25519._(
          library.lookupFunction<_SignNative, _SignDart>('conest_ed25519_sign'),
          library.lookupFunction<_VerifyNative, _VerifyDart>(
            'conest_ed25519_verify',
          ),
        );
      } catch (_) {
        // Try the next location.
      }
    }
    return null;
  }

  /// Larger messages go to Dart (signing.rs refuses them).
  static const int maximumMessageBytes = 1 << 20;

  final _SignDart _sign;
  final _VerifyDart _verify;

  /// The 64-byte signature of [message] by the key with this 32-byte
  /// [seed]; null for input the native side refuses.
  Uint8List? sign(List<int> seed, List<int> message) {
    if (seed.length != 32 || message.length > maximumMessageBytes) {
      return null;
    }
    final seedPointer = calloc<Uint8>(32);
    final messagePointer = calloc<Uint8>(message.isEmpty ? 1 : message.length);
    final signaturePointer = calloc<Uint8>(64);
    try {
      seedPointer.asTypedList(32).setAll(0, seed);
      messagePointer.asTypedList(message.length).setAll(0, message);
      if (!_sign(
        seedPointer,
        messagePointer,
        message.length,
        signaturePointer,
      )) {
        return null;
      }
      return Uint8List.fromList(signaturePointer.asTypedList(64));
    } finally {
      calloc.free(seedPointer);
      calloc.free(messagePointer);
      calloc.free(signaturePointer);
    }
  }

  /// Whether [signature] is [publicKey]'s over [message] (strict rules).
  bool verify(List<int> publicKey, List<int> message, List<int> signature) {
    if (publicKey.length != 32 ||
        signature.length != 64 ||
        message.length > maximumMessageBytes) {
      return false;
    }
    final keyPointer = calloc<Uint8>(32);
    final messagePointer = calloc<Uint8>(message.isEmpty ? 1 : message.length);
    final signaturePointer = calloc<Uint8>(64);
    try {
      keyPointer.asTypedList(32).setAll(0, publicKey);
      messagePointer.asTypedList(message.length).setAll(0, message);
      signaturePointer.asTypedList(64).setAll(0, signature);
      return _verify(
        keyPointer,
        messagePointer,
        message.length,
        signaturePointer,
      );
    } finally {
      calloc.free(keyPointer);
      calloc.free(messagePointer);
      calloc.free(signaturePointer);
    }
  }
}

/// Whether [signature] is [publicKey]'s Ed25519 signature over [message]:
/// natively where `conest_native` has it (relay answers, group history and
/// account lists are checked all the time, even with nothing going on; in
/// Dart each check took milliseconds of the main isolate), in Dart
/// otherwise. False for malformed input.
Future<bool> verifyEd25519Signature({
  required List<int> publicKey,
  required List<int> message,
  required List<int> signature,
}) async {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final native = NativeEd25519.instance;
  if (native != null && message.length <= NativeEd25519.maximumMessageBytes) {
    return native.verify(publicKey, message, signature);
  }
  try {
    return await Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}
