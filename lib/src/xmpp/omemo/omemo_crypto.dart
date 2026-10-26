import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The cryptographic building blocks of both OMEMO versions, on the
/// `cryptography` package.
abstract final class OmemoCrypto {
  static final _x25519 = X25519();
  static final _ed25519 = Ed25519();
  static final _hmac = Hmac.sha256();
  static final _cbc = AesCbc.with256bits(
    macAlgorithm: MacAlgorithm.empty,
    paddingAlgorithm: PaddingAlgorithm.pkcs7,
  );
  static final _gcm = AesGcm.with128bits(nonceLength: 12);

  /// The X25519 public key of the raw private scalar [priv].
  static Future<Uint8List> x25519Public(List<int> priv) async {
    final pair = await _x25519.newKeyPairFromSeed(priv);
    return Uint8List.fromList((await pair.extractPublicKey()).bytes);
  }

  /// X25519; an all-zero result (a low-order public key) is an error.
  static Future<Uint8List> x25519(List<int> priv, List<int> pub) async {
    if (priv.length != 32 || pub.length != 32) {
      throw ArgumentError('X25519 needs 32-byte keys.');
    }
    final pair = await _x25519.newKeyPairFromSeed(priv);
    final secret = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
    );
    final bytes = Uint8List.fromList(await secret.extractBytes());
    var any = 0;
    for (final byte in bytes) {
      any |= byte;
    }
    if (any == 0) {
      throw StateError('Key agreement gave an all-zero secret.');
    }
    return bytes;
  }

  static Future<Uint8List> hkdf(
    List<int> ikm, {
    required List<int> salt,
    required List<int> info,
    required int length,
  }) async {
    final key = await Hkdf(
      hmac: _hmac,
      outputLength: length,
    ).deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);
    return Uint8List.fromList(await key.extractBytes());
  }

  static Future<Uint8List> hmacSha256(List<int> key, List<int> data) async {
    final mac = await _hmac.calculateMac(data, secretKey: SecretKey(key));
    return Uint8List.fromList(mac.bytes);
  }

  static Future<Uint8List> aesCbcEncrypt(
    List<int> key,
    List<int> iv,
    List<int> plain,
  ) async {
    final box = await _cbc.encrypt(plain, secretKey: SecretKey(key), nonce: iv);
    return Uint8List.fromList(box.cipherText);
  }

  static Future<Uint8List> aesCbcDecrypt(
    List<int> key,
    List<int> iv,
    List<int> cipher,
  ) async {
    final plain = await _cbc.decrypt(
      SecretBox(cipher, nonce: iv, mac: Mac.empty),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(plain);
  }

  /// AES-128-GCM; returns the ciphertext and the 16-byte tag apart (legacy
  /// OMEMO sends the tag with the key).
  static Future<(Uint8List, Uint8List)> aesGcmEncrypt(
    List<int> key,
    List<int> iv,
    List<int> plain,
  ) async {
    final box = await _gcm.encrypt(plain, secretKey: SecretKey(key), nonce: iv);
    return (
      Uint8List.fromList(box.cipherText),
      Uint8List.fromList(box.mac.bytes),
    );
  }

  static Future<Uint8List> aesGcmDecrypt(
    List<int> key,
    List<int> iv,
    List<int> cipher,
    List<int> tag,
  ) async {
    final plain = await _gcm.decrypt(
      SecretBox(cipher, nonce: iv, mac: Mac(tag)),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(plain);
  }

  /// An Ed25519 key pair from a 32-byte seed: (public key, signer).
  static Future<Uint8List> ed25519Public(List<int> seed) async {
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    return Uint8List.fromList((await pair.extractPublicKey()).bytes);
  }

  static Future<Uint8List> ed25519Sign(
    List<int> seed,
    List<int> message,
  ) async {
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    final signature = await _ed25519.sign(message, keyPair: pair);
    return Uint8List.fromList(signature.bytes);
  }

  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var index = 0; index < a.length; index++) {
      diff |= a[index] ^ b[index];
    }
    return diff == 0;
  }
}
