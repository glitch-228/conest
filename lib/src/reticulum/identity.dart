import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

/// Reticulum hash sizes.
const int rnsTruncatedHashBytes = 16;
const int rnsNameHashBytes = 10;

/// SHA-256 of [data].
Uint8List rnsFullHash(List<int> data) =>
    Uint8List.fromList(hashes.sha256.convert(data).bytes);

/// The first 16 bytes of the SHA-256 of [data].
Uint8List rnsTruncatedHash(List<int> data) =>
    Uint8List.sublistView(rnsFullHash(data), 0, rnsTruncatedHashBytes);

/// The 10-byte hash of a destination name such as `conest.carrier`.
Uint8List rnsNameHash(String appName, List<String> aspects) =>
    Uint8List.sublistView(
      rnsFullHash(utf8.encode([appName, ...aspects].join('.'))),
      0,
      rnsNameHashBytes,
    );

/// The hash of a SINGLE destination owned by the identity with [identityHash].
Uint8List rnsDestinationHash(Uint8List nameHash, Uint8List identityHash) =>
    rnsTruncatedHash([...nameHash, ...identityHash]);

/// RFC 5869 HKDF-SHA256, as Reticulum derives its token keys.
Uint8List rnsHkdf(int length, List<int> input, List<int>? salt) {
  final usedSalt = salt == null || salt.isEmpty
      ? List<int>.filled(32, 0)
      : salt;
  final prk = hashes.Hmac(hashes.sha256, usedSalt).convert(input).bytes;
  final out = BytesBuilder(copy: false);
  var block = <int>[];
  for (var counter = 1; out.length < length; counter++) {
    block = hashes.Hmac(hashes.sha256, prk).convert([...block, counter]).bytes;
    out.add(block);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

/// A Reticulum identity: an X25519 key for encryption and an Ed25519 key
/// for signatures. The public key is both, 64 bytes; its truncated hash
/// names the identity.
class RnsIdentity {
  RnsIdentity._(this.publicKey, this._encryption, this._signing);

  /// Raw public bytes: X25519 (32) then Ed25519 (32).
  final Uint8List publicKey;
  final SimpleKeyPair? _encryption;
  final SimpleKeyPair? _signing;

  static final _x25519 = X25519();
  static final _ed25519 = Ed25519();

  Uint8List get hash => rnsTruncatedHash(publicKey);
  bool get hasPrivateKey => _encryption != null;

  /// A new random identity.
  static Future<RnsIdentity> generate([Random? random]) {
    final source = random ?? Random.secure();
    return fromPrivateKey(
      Uint8List.fromList(List.generate(64, (_) => source.nextInt(256))),
    );
  }

  /// An identity from its 64-byte private key (X25519 then Ed25519 seed),
  /// the form Reticulum stores.
  static Future<RnsIdentity> fromPrivateKey(Uint8List privateKey) async {
    if (privateKey.length != 64) {
      throw ArgumentError('Reticulum private keys are 64 bytes.');
    }
    final encryption = await _x25519.newKeyPairFromSeed(
      privateKey.sublist(0, 32),
    );
    final signing = await _ed25519.newKeyPairFromSeed(privateKey.sublist(32));
    final encryptionPublic = await encryption.extractPublicKey();
    final signingPublic = await signing.extractPublicKey();
    return RnsIdentity._(
      Uint8List.fromList([...encryptionPublic.bytes, ...signingPublic.bytes]),
      encryption,
      signing,
    );
  }

  /// A peer known only by its public key; null when it is not 64 bytes.
  static RnsIdentity? fromPublicKey(List<int> publicKey) =>
      publicKey.length == 64
      ? RnsIdentity._(Uint8List.fromList(publicKey), null, null)
      : null;

  Future<Uint8List> privateKey() async {
    final encryption = _encryption;
    final signing = _signing;
    if (encryption == null || signing == null) {
      throw StateError('This identity holds no private key.');
    }
    return Uint8List.fromList([
      ...await encryption.extractPrivateKeyBytes(),
      ...await signing.extractPrivateKeyBytes(),
    ]);
  }

  Future<Uint8List> sign(List<int> message) async {
    final signing = _signing;
    if (signing == null) throw StateError('This identity cannot sign.');
    final signature = await _ed25519.sign(message, keyPair: signing);
    return Uint8List.fromList(signature.bytes);
  }

  Future<bool> verify(List<int> message, List<int> signature) async {
    if (signature.length != 64) return false;
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(
            publicKey.sublist(32),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Encrypts [plaintext] to this identity: an ephemeral X25519 key, then
  /// a token (AES-256-CBC with HMAC-SHA256) under keys derived from the
  /// shared secret with this identity's hash as salt.
  Future<Uint8List> encrypt(List<int> plaintext, [Random? random]) async {
    final ephemeral = await _x25519.newKeyPair();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        publicKey.sublist(0, 32),
        type: KeyPairType.x25519,
      ),
    );
    final key = rnsHkdf(64, await shared.extractBytes(), hash);
    final ephemeralPublic = await ephemeral.extractPublicKey();
    return Uint8List.fromList([
      ...ephemeralPublic.bytes,
      ...await RnsToken(key).encrypt(plaintext, random),
    ]);
  }

  /// Decrypts a ciphertext made by [encrypt]; null when it was not for
  /// this identity or was altered.
  Future<Uint8List?> decrypt(List<int> ciphertext) async {
    final encryption = _encryption;
    if (encryption == null) throw StateError('This identity cannot decrypt.');
    if (ciphertext.length <= 32 + 16 + 32) return null;
    try {
      final shared = await _x25519.sharedSecretKey(
        keyPair: encryption,
        remotePublicKey: SimplePublicKey(
          ciphertext.sublist(0, 32),
          type: KeyPairType.x25519,
        ),
      );
      final key = rnsHkdf(64, await shared.extractBytes(), hash);
      return await RnsToken(key).decrypt(ciphertext.sublist(32));
    } catch (_) {
      return null;
    }
  }
}

/// Reticulum's token: Fernet without version and timestamp. IV (16), then
/// AES-256-CBC with PKCS#7 padding, then HMAC-SHA256 over both.
class RnsToken {
  RnsToken(this._key) : assert(_key.length == 64);

  final List<int> _key;
  static final _aes = AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);

  List<int> get _signingKey => _key.sublist(0, 32);
  List<int> get _encryptionKey => _key.sublist(32);

  Future<Uint8List> encrypt(List<int> plaintext, [Random? random]) async {
    final source = random ?? Random.secure();
    final iv = List<int>.generate(16, (_) => source.nextInt(256));
    final box = await _aes.encrypt(
      plaintext,
      secretKey: SecretKey(_encryptionKey),
      nonce: iv,
    );
    final signed = [...iv, ...box.cipherText];
    return Uint8List.fromList([
      ...signed,
      ...hashes.Hmac(hashes.sha256, _signingKey).convert(signed).bytes,
    ]);
  }

  /// Throws when the HMAC or padding is wrong.
  Future<Uint8List> decrypt(List<int> token) async {
    if (token.length < 16 + 16 + 32) {
      throw const FormatException('Reticulum token is too short.');
    }
    final signed = token.sublist(0, token.length - 32);
    final mac = token.sublist(token.length - 32);
    final expected = hashes.Hmac(
      hashes.sha256,
      _signingKey,
    ).convert(signed).bytes;
    var difference = 0;
    for (var index = 0; index < 32; index++) {
      difference |= expected[index] ^ mac[index];
    }
    if (difference != 0) {
      throw const FormatException('Reticulum token HMAC mismatch.');
    }
    final clear = await _aes.decrypt(
      SecretBox(
        signed.sublist(16),
        nonce: signed.sublist(0, 16),
        mac: Mac.empty,
      ),
      secretKey: SecretKey(_encryptionKey),
    );
    return Uint8List.fromList(clear);
  }
}
