import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import 'omemo_crypto.dart';
import 'omemo_random.dart';
import 'omemo_suite.dart';
import 'xeddsa.dart';

/// This device's identity: one 32-byte seed gives an Ed25519 key (OMEMO 2)
/// and the Curve25519 key of the same point (legacy OMEMO and fingerprints),
/// as the reference libraries derive them.
class OmemoIdentity {
  OmemoIdentity._(this.seed, this.scalar, this.montgomery, this.edwards);

  final Uint8List seed;

  /// The clamped X25519 private scalar.
  final Uint8List scalar;
  final Uint8List montgomery;
  final Uint8List edwards;

  static Future<OmemoIdentity> fromSeed(List<int> seed) async {
    if (seed.length != 32) throw ArgumentError('The seed has 32 bytes.');
    final scalar = ed25519SeedToX25519Private(seed);
    return OmemoIdentity._(
      Uint8List.fromList(seed),
      scalar,
      await OmemoCrypto.x25519Public(scalar),
      await OmemoCrypto.ed25519Public(seed),
    );
  }

  /// The fingerprint people compare: the Curve25519 key in hex, groups of 8.
  String get fingerprint => omemoFingerprint(montgomery);
}

String omemoFingerprint(List<int> montgomery) {
  final hex = montgomery
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return [
    for (var index = 0; index < hex.length; index += 8)
      hex.substring(index, index + 8),
  ].join(' ');
}

/// Another device's published keys.
class OmemoBundle {
  OmemoBundle({
    required this.version,
    required this.identityMontgomery,
    required this.identityEdwards,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    required this.preKeys,
  });

  final OmemoVersion version;

  /// The identity key as Curve25519 (always set).
  final Uint8List identityMontgomery;

  /// The identity key as Ed25519: published in OMEMO 2, derived (with the
  /// sign bit the signature carries) in legacy OMEMO.
  final Uint8List identityEdwards;
  final int signedPreKeyId;
  final Uint8List signedPreKey;
  final Uint8List signedPreKeySignature;
  final Map<int, Uint8List> preKeys;

  /// Most pre keys read from one bundle.
  static const int maxPreKeys = 200;

  /// Checks the signed pre key's signature by the identity key.
  Future<bool> verify() async {
    final suite = version.suite;
    if (signedPreKey.length != 32 ||
        signedPreKeySignature.length != 64 ||
        identityMontgomery.length != 32) {
      return false;
    }
    if (version == OmemoVersion.legacy) {
      return xeddsaVerify(
        identityMontgomery,
        suite.encodePublic(signedPreKey),
        signedPreKeySignature,
      );
    }
    final converted = omemoMontgomery(identityEdwards);
    if (converted == null ||
        !OmemoCrypto.constantTimeEquals(converted, identityMontgomery)) {
      return false;
    }
    return ed25519Verify(identityEdwards, signedPreKey, signedPreKeySignature);
  }

  /// A bundle in legacy form: the Edwards key is rebuilt from the signature's
  /// sign bit.
  static OmemoBundle legacy({
    required Uint8List identityMontgomery,
    required int signedPreKeyId,
    required Uint8List signedPreKey,
    required Uint8List signedPreKeySignature,
    required Map<int, Uint8List> preKeys,
  }) {
    final negative =
        signedPreKeySignature.length == 64 &&
        signedPreKeySignature[63] & 0x80 != 0;
    final edwards =
        montgomeryToEdwards(identityMontgomery, negative: negative) ??
        Uint8List(32);
    return OmemoBundle(
      version: OmemoVersion.legacy,
      identityMontgomery: identityMontgomery,
      identityEdwards: edwards,
      signedPreKeyId: signedPreKeyId,
      signedPreKey: signedPreKey,
      signedPreKeySignature: signedPreKeySignature,
      preKeys: preKeys,
    );
  }

  static OmemoBundle? omemo2({
    required Uint8List identityEdwards,
    required int signedPreKeyId,
    required Uint8List signedPreKey,
    required Uint8List signedPreKeySignature,
    required Map<int, Uint8List> preKeys,
  }) {
    final montgomery = omemoMontgomery(identityEdwards);
    if (montgomery == null) return null;
    return OmemoBundle(
      version: OmemoVersion.v2,
      identityMontgomery: montgomery,
      identityEdwards: identityEdwards,
      signedPreKeyId: signedPreKeyId,
      signedPreKey: signedPreKey,
      signedPreKeySignature: signedPreKeySignature,
      preKeys: preKeys,
    );
  }
}

class OmemoSignedPreKey {
  OmemoSignedPreKey({
    required this.id,
    required this.priv,
    required this.pub,
    required this.signature,
    required this.createdAt,
  });

  final int id;
  final Uint8List priv;
  final Uint8List pub;
  final Uint8List signature;
  final int createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'priv': base64.encode(priv),
    'sig': base64.encode(signature),
    'at': createdAt,
  };

  static Future<OmemoSignedPreKey> fromJson(Object? json) async {
    final map = json as Map;
    final priv = Uint8List.fromList(base64.decode(map['priv'] as String));
    return OmemoSignedPreKey(
      id: map['id'] as int,
      priv: priv,
      pub: await OmemoCrypto.x25519Public(priv),
      signature: Uint8List.fromList(base64.decode(map['sig'] as String)),
      createdAt: map['at'] as int,
    );
  }
}

/// The pre keys and signed pre key of one OMEMO version on this device.
class OmemoSuiteKeys {
  OmemoSuiteKeys({
    required this.signedPreKey,
    this.oldSignedPreKey,
    Map<int, Uint8List>? preKeys,
    this.nextPreKeyId = 1,
    this.nextSignedPreKeyId = 1,
  }) : preKeys = preKeys ?? <int, Uint8List>{};

  OmemoSignedPreKey signedPreKey;
  OmemoSignedPreKey? oldSignedPreKey;

  /// Private keys by id.
  final Map<int, Uint8List> preKeys;
  int nextPreKeyId;
  int nextSignedPreKeyId;

  /// Pre keys kept published, and the lowest count before topping up.
  static const int targetPreKeys = 100;
  static const int lowPreKeys = 25;

  /// Most pre keys ever kept, whatever happens.
  static const int maxPreKeys = 200;

  static Future<OmemoSignedPreKey> makeSignedPreKey(
    OmemoVersion version,
    OmemoIdentity identity,
    int id,
    OmemoRandom random,
    int now,
  ) async {
    final priv = random.bytes(32);
    final pub = await OmemoCrypto.x25519Public(priv);
    final Uint8List signature;
    if (version == OmemoVersion.legacy) {
      signature = xeddsaSign(
        identity.scalar,
        version.suite.encodePublic(pub),
        random.bytes(64),
      );
    } else {
      signature = await OmemoCrypto.ed25519Sign(identity.seed, pub);
    }
    return OmemoSignedPreKey(
      id: id,
      priv: priv,
      pub: pub,
      signature: signature,
      createdAt: now,
    );
  }

  static Future<OmemoSuiteKeys> create(
    OmemoVersion version,
    OmemoIdentity identity,
    OmemoRandom random,
    int now,
  ) async => OmemoSuiteKeys(
    signedPreKey: await makeSignedPreKey(version, identity, 1, random, now),
    nextSignedPreKeyId: 2,
  );

  /// Tops the pre keys up to [targetPreKeys]; true when any were made.
  bool topUp(OmemoRandom random) {
    if (preKeys.length >= lowPreKeys) return false;
    while (preKeys.length < targetPreKeys) {
      preKeys[nextPreKeyId++] = random.bytes(32);
    }
    return true;
  }

  /// A new signed pre key; the previous one stays usable for one more round.
  Future<void> rotate(
    OmemoVersion version,
    OmemoIdentity identity,
    OmemoRandom random,
    int now,
  ) async {
    oldSignedPreKey = signedPreKey;
    signedPreKey = await makeSignedPreKey(
      version,
      identity,
      nextSignedPreKeyId++,
      random,
      now,
    );
  }

  Future<OmemoBundle> bundle(
    OmemoVersion version,
    OmemoIdentity identity,
  ) async {
    final publics = <int, Uint8List>{};
    for (final entry in preKeys.entries) {
      publics[entry.key] = await OmemoCrypto.x25519Public(entry.value);
    }
    return OmemoBundle(
      version: version,
      identityMontgomery: identity.montgomery,
      identityEdwards: identity.edwards,
      signedPreKeyId: signedPreKey.id,
      signedPreKey: signedPreKey.pub,
      signedPreKeySignature: signedPreKey.signature,
      preKeys: publics,
    );
  }

  Map<String, Object?> toJson() => {
    'spk': signedPreKey.toJson(),
    'old': oldSignedPreKey?.toJson(),
    'pks': {
      for (final entry in preKeys.entries)
        '${entry.key}': base64.encode(entry.value),
    },
    'nextPk': nextPreKeyId,
    'nextSpk': nextSignedPreKeyId,
  };

  static Future<OmemoSuiteKeys> fromJson(Object? json) async {
    final map = json as Map;
    final preKeys = <int, Uint8List>{};
    final stored = map['pks'];
    if (stored is Map) {
      for (final entry in stored.entries) {
        if (preKeys.length >= maxPreKeys) break;
        final key = base64.decode(entry.value as String);
        if (key.length != 32) continue;
        preKeys[int.parse(entry.key as String)] = Uint8List.fromList(key);
      }
    }
    return OmemoSuiteKeys(
      signedPreKey: await OmemoSignedPreKey.fromJson(map['spk']),
      oldSignedPreKey: map['old'] == null
          ? null
          : await OmemoSignedPreKey.fromJson(map['old']),
      preKeys: preKeys,
      nextPreKeyId: map['nextPk'] as int,
      nextSignedPreKeyId: map['nextSpk'] as int,
    );
  }
}

/// What the initiator of a session computed.
class OmemoActiveAgreement {
  OmemoActiveAgreement({
    required this.sharedSecret,
    required this.associatedData,
    required this.ephemeralKey,
    required this.preKeyId,
  });

  final Uint8List sharedSecret;

  /// Initiator identity then responder identity, as the suite encodes them.
  final Uint8List associatedData;
  final Uint8List ephemeralKey;
  final int preKeyId;
}

class OmemoKeyAgreementException implements Exception {
  const OmemoKeyAgreementException(this.message);
  final String message;
  @override
  String toString() => 'OMEMO key agreement failed: $message';
}

Uint8List _concat(Iterable<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final part in parts) {
    out.add(part);
  }
  return out.toBytes();
}

Future<Uint8List> _secret(OmemoSuite suite, List<List<int>> dh) {
  return OmemoCrypto.hkdf(
    _concat([List<int>.filled(32, 0xff), ...dh]),
    salt: Uint8List(32),
    info: suite.x3dhInfo,
    length: 32,
  );
}

/// X3DH from the initiator's side (Signal's, with the Signal/OMEMO KDF).
Future<OmemoActiveAgreement> omemoAgreeActive(
  OmemoSuite suite,
  OmemoIdentity own,
  OmemoBundle bundle,
  OmemoRandom random,
) async {
  if (bundle.preKeys.isEmpty) {
    throw const OmemoKeyAgreementException('the bundle has no pre key');
  }
  if (!await bundle.verify()) {
    throw const OmemoKeyAgreementException(
      'the signed pre key signature does not verify',
    );
  }
  final ids = bundle.preKeys.keys.toList()..sort();
  final preKeyId = ids.length == 1
      ? ids.first
      : ids[random.bytes(2).buffer.asByteData().getUint16(0) % ids.length];
  final preKey = bundle.preKeys[preKeyId]!;
  final ephemeralPriv = random.bytes(32);
  try {
    final dh1 = await OmemoCrypto.x25519(own.scalar, bundle.signedPreKey);
    final dh2 = await OmemoCrypto.x25519(
      ephemeralPriv,
      bundle.identityMontgomery,
    );
    final dh3 = await OmemoCrypto.x25519(ephemeralPriv, bundle.signedPreKey);
    final dh4 = await OmemoCrypto.x25519(ephemeralPriv, preKey);
    return OmemoActiveAgreement(
      sharedSecret: await _secret(suite, [dh1, dh2, dh3, dh4]),
      associatedData: _concat([
        suite.associatedIdentity(own.montgomery, own.edwards),
        suite.associatedIdentity(
          bundle.identityMontgomery,
          bundle.identityEdwards,
        ),
      ]),
      ephemeralKey: await OmemoCrypto.x25519Public(ephemeralPriv),
      preKeyId: preKeyId,
    );
  } on StateError catch (error) {
    throw OmemoKeyAgreementException(error.message);
  }
}

class OmemoPassiveAgreement {
  OmemoPassiveAgreement({
    required this.sharedSecret,
    required this.associatedData,
    required this.signedPreKey,
    required this.preKeyId,
    required this.initiatorMontgomery,
  });

  final Uint8List sharedSecret;
  final Uint8List associatedData;
  final OmemoSignedPreKey signedPreKey;
  final int preKeyId;
  final Uint8List initiatorMontgomery;
}

/// X3DH from the responder's side. Throws [OmemoKeyAgreementException]
/// when the signed pre key or pre key is gone.
Future<OmemoPassiveAgreement> omemoAgreePassive(
  OmemoSuite suite,
  OmemoIdentity own,
  OmemoSuiteKeys keys,
  OmemoKeyExchange kex,
) async {
  OmemoSignedPreKey? spk;
  if (keys.signedPreKey.id == kex.signedPreKeyId) {
    spk = keys.signedPreKey;
  } else if (keys.oldSignedPreKey?.id == kex.signedPreKeyId) {
    spk = keys.oldSignedPreKey;
  }
  if (spk == null) {
    throw const OmemoKeyAgreementException('the signed pre key is gone');
  }
  final preKey = keys.preKeys[kex.preKeyId];
  if (preKey == null) {
    throw const OmemoKeyAgreementException('the pre key is gone');
  }
  final Uint8List? initiatorEdwards;
  final Uint8List initiatorMontgomery;
  if (suite.version == OmemoVersion.legacy) {
    initiatorMontgomery = kex.identityKey;
    initiatorEdwards = null;
  } else {
    final converted = omemoMontgomery(kex.identityKey);
    if (converted == null) {
      throw const OmemoKeyAgreementException('the identity key is invalid');
    }
    initiatorMontgomery = converted;
    initiatorEdwards = kex.identityKey;
  }
  try {
    final dh1 = await OmemoCrypto.x25519(spk.priv, initiatorMontgomery);
    final dh2 = await OmemoCrypto.x25519(own.scalar, kex.ephemeralKey);
    final dh3 = await OmemoCrypto.x25519(spk.priv, kex.ephemeralKey);
    final dh4 = await OmemoCrypto.x25519(preKey, kex.ephemeralKey);
    return OmemoPassiveAgreement(
      sharedSecret: await _secret(suite, [dh1, dh2, dh3, dh4]),
      associatedData: _concat([
        suite.associatedIdentity(initiatorMontgomery, initiatorEdwards),
        suite.associatedIdentity(own.montgomery, own.edwards),
      ]),
      signedPreKey: spk,
      preKeyId: kex.preKeyId,
      initiatorMontgomery: initiatorMontgomery,
    );
  } on StateError catch (error) {
    throw OmemoKeyAgreementException(error.message);
  }
}

/// A short stable id of a byte string, for logs and duplicate checks.
String omemoDigest(List<int> bytes) =>
    hash.sha256.convert(bytes).toString().substring(0, 16);
