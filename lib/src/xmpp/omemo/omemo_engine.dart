import 'dart:convert';
import 'dart:typed_data';

import 'omemo_crypto.dart';
import 'omemo_keys.dart';
import 'omemo_proto.dart';
import 'omemo_ratchet.dart';
import 'omemo_random.dart';
import 'omemo_session.dart';
import 'omemo_suite.dart';

/// How much a device of someone else is trusted. Append only.
enum OmemoTrust {
  /// Accepted when first seen, never compared by the user (what
  /// Conversations calls "trusted, not verified").
  blind,

  /// The user compared the fingerprint.
  verified,

  /// The user refuses it: nothing is sent to it.
  distrusted,
}

class OmemoDeviceRecord {
  OmemoDeviceRecord({
    required this.identity,
    required this.trust,
    required this.firstSeen,
  });

  /// Curve25519 identity key.
  final Uint8List identity;
  OmemoTrust trust;
  final int firstSeen;

  String get fingerprint => omemoFingerprint(identity);

  Map<String, Object?> toJson() => {
    'ik': base64.encode(identity),
    'trust': trust.name,
    'at': firstSeen,
  };
}

/// A device uses a different identity key than the one remembered.
class OmemoIdentityChanged implements Exception {
  const OmemoIdentityChanged(this.jid, this.deviceId);
  final String jid;
  final int deviceId;
  @override
  String toString() => 'The keys of $jid device $deviceId changed.';
}

/// A key for a device needs a bundle that is not at hand.
class OmemoNeedsBundle implements Exception {
  const OmemoNeedsBundle(this.jid, this.deviceId);
  final String jid;
  final int deviceId;
  @override
  String toString() => 'No bundle for $jid device $deviceId.';
}

class OmemoPayload {
  const OmemoPayload({
    required this.ciphertext,
    required this.keyMaterial,
    this.iv,
  });

  /// The encrypted body (empty for a key transport message).
  final Uint8List ciphertext;

  /// What each recipient device gets: the payload key and its tag.
  final Uint8List keyMaterial;

  /// Legacy OMEMO's 12-byte GCM nonce.
  final Uint8List? iv;
}

class OmemoEncryptedKey {
  const OmemoEncryptedKey({
    required this.jid,
    required this.deviceId,
    required this.blob,
    required this.keyExchange,
  });

  final String jid;
  final int deviceId;
  final Uint8List blob;
  final bool keyExchange;
}

/// This device's OMEMO state: identity, keys of both versions, sessions and
/// the trust record of everyone else's devices. Pure cryptography; the XMPP
/// side fetches bundles and carries the results.
class OmemoEngine {
  OmemoEngine._({
    required this.deviceId,
    required this.identity,
    required this.keys,
    required this.sessions,
    required this.devices,
    required this.random,
    required this.now,
  });

  final int deviceId;
  final OmemoIdentity identity;
  final Map<OmemoVersion, OmemoSuiteKeys> keys;
  final OmemoRandom random;
  final int Function() now;

  /// Sessions by "version|jid|device", newest or last used first.
  final Map<String, List<OmemoSession>> sessions;

  /// Devices of others by bare JID, then device id.
  final Map<String, Map<int, OmemoDeviceRecord>> devices;

  static const int maxSessionsPerDevice = 3;
  static const int maxDeviceKeys = 1500;
  static const int maxDevicesPerJid = 100;
  static const int maxJids = 1000;

  /// Signed pre keys older than this are rotated.
  static const Duration rotateAfter = Duration(days: 7);

  static Future<OmemoEngine> create({
    OmemoRandom? random,
    int Function()? now,
  }) async {
    final rng = random ?? SecureOmemoRandom();
    final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
    final identity = await OmemoIdentity.fromSeed(rng.bytes(32));
    var deviceId = 0;
    while (deviceId == 0) {
      deviceId = rng.bytes(4).buffer.asByteData().getUint32(0) & 0x7fffffff;
    }
    final engine = OmemoEngine._(
      deviceId: deviceId,
      identity: identity,
      keys: {},
      sessions: {},
      devices: {},
      random: rng,
      now: clock,
    );
    for (final version in OmemoVersion.values) {
      final suiteKeys = await OmemoSuiteKeys.create(
        version,
        identity,
        rng,
        clock(),
      );
      suiteKeys.topUp(rng);
      engine.keys[version] = suiteKeys;
    }
    return engine;
  }

  /// Restores saved state, or null when it is unreadable.
  static Future<OmemoEngine?> restore(
    Map<String, Object?> json, {
    OmemoRandom? random,
    int Function()? now,
  }) async {
    try {
      final identity = await OmemoIdentity.fromSeed(
        base64.decode(json['seed'] as String),
      );
      final keys = <OmemoVersion, OmemoSuiteKeys>{};
      for (final version in OmemoVersion.values) {
        final stored = (json['keys'] as Map)[version.name];
        if (stored == null) return null;
        keys[version] = await OmemoSuiteKeys.fromJson(stored);
      }
      final sessions = <String, List<OmemoSession>>{};
      for (final entry in (json['sessions'] as Map).entries) {
        final list = <OmemoSession>[];
        for (final item in entry.value as List) {
          if (list.length >= maxSessionsPerDevice) break;
          list.add(OmemoSession.fromJson(item));
        }
        if (list.isNotEmpty) sessions[entry.key as String] = list;
      }
      final devices = <String, Map<int, OmemoDeviceRecord>>{};
      for (final entry in (json['devices'] as Map).entries) {
        final records = <int, OmemoDeviceRecord>{};
        for (final record in (entry.value as Map).entries) {
          if (records.length >= maxDevicesPerJid) break;
          final map = record.value as Map;
          records[int.parse(record.key as String)] = OmemoDeviceRecord(
            identity: Uint8List.fromList(base64.decode(map['ik'] as String)),
            trust: OmemoTrust.values.byName(map['trust'] as String),
            firstSeen: map['at'] as int,
          );
        }
        if (devices.length < maxJids) devices[entry.key as String] = records;
      }
      return OmemoEngine._(
        deviceId: json['deviceId'] as int,
        identity: identity,
        keys: keys,
        sessions: sessions,
        devices: devices,
        random: random ?? SecureOmemoRandom(),
        now: now ?? () => DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'seed': base64.encode(identity.seed),
    'keys': {
      for (final entry in keys.entries) entry.key.name: entry.value.toJson(),
    },
    'sessions': {
      for (final entry in sessions.entries)
        entry.key: [for (final s in entry.value) s.toJson()],
    },
    'devices': {
      for (final entry in devices.entries)
        entry.key: {
          for (final record in entry.value.entries)
            '${record.key}': record.value.toJson(),
        },
    },
  };

  String get fingerprint => identity.fingerprint;

  static String _sessionKey(OmemoVersion version, String jid, int deviceId) =>
      '${version.name}|$jid|$deviceId';

  // ---- Own bundles -------------------------------------------------------

  Future<OmemoBundle> ownBundle(OmemoVersion version) =>
      keys[version]!.bundle(version, identity);

  /// Rotates old signed pre keys and refills pre keys. True when a bundle
  /// has to be published again.
  Future<bool> maintainKeys() async {
    var changed = false;
    for (final version in OmemoVersion.values) {
      final suiteKeys = keys[version]!;
      final age = now() - suiteKeys.signedPreKey.createdAt;
      if (age > rotateAfter.inMilliseconds) {
        await suiteKeys.rotate(version, identity, random, now());
        changed = true;
      }
      if (suiteKeys.topUp(random)) changed = true;
    }
    return changed;
  }

  // ---- Devices and trust -------------------------------------------------

  OmemoDeviceRecord? deviceRecord(String jid, int deviceId) =>
      devices[jid]?[deviceId];

  Iterable<MapEntry<int, OmemoDeviceRecord>> devicesOf(String jid) =>
      devices[jid]?.entries ?? const [];

  /// Remembers [identityKey] for the device, or checks it against what is
  /// remembered. Throws [OmemoIdentityChanged] when it differs.
  OmemoDeviceRecord _remember(String jid, int deviceId, Uint8List identityKey) {
    final known = devices[jid]?[deviceId];
    if (known != null) {
      if (!OmemoCrypto.constantTimeEquals(known.identity, identityKey)) {
        throw OmemoIdentityChanged(jid, deviceId);
      }
      return known;
    }
    final perJid = devices.putIfAbsent(jid, () => <int, OmemoDeviceRecord>{});
    if (perJid.length >= maxDevicesPerJid) {
      throw const OmemoProtoException('too many devices for one contact');
    }
    if (devices.length > maxJids) {
      throw const OmemoProtoException('too many contacts');
    }
    final record = OmemoDeviceRecord(
      identity: Uint8List.fromList(identityKey),
      trust: OmemoTrust.blind,
      firstSeen: now(),
    );
    perJid[deviceId] = record;
    return record;
  }

  /// Tells whether the device's key is known and unchanged, without
  /// recording anything.
  bool identityMatches(String jid, int deviceId, Uint8List identityKey) {
    final known = devices[jid]?[deviceId];
    return known == null ||
        OmemoCrypto.constantTimeEquals(known.identity, identityKey);
  }

  void setTrust(String jid, int deviceId, OmemoTrust trust) {
    devices[jid]?[deviceId]?.trust = trust;
  }

  /// Forgets a device's remembered key and sessions (after a reinstall that
  /// reused the id, or to start over).
  void forgetDevice(String jid, int deviceId) {
    devices[jid]?.remove(deviceId);
    if (devices[jid]?.isEmpty ?? false) devices.remove(jid);
    for (final version in OmemoVersion.values) {
      sessions.remove(_sessionKey(version, jid, deviceId));
    }
  }

  void forgetJid(String jid) {
    devices.remove(jid);
    sessions.removeWhere((key, _) => key.split('|')[1] == jid);
  }

  bool hasSession(OmemoVersion version, String jid, int deviceId) =>
      sessions[_sessionKey(version, jid, deviceId)]?.isNotEmpty ?? false;

  // ---- Payload -----------------------------------------------------------

  Future<OmemoPayload> encryptPayload(
    OmemoVersion version,
    List<int> plaintext,
  ) async {
    final suite = version.suite;
    final key = random.bytes(suite.payloadKeyLength);
    if (version == OmemoVersion.legacy) {
      final iv = random.bytes(12);
      final (cipher, tag) = await OmemoCrypto.aesGcmEncrypt(key, iv, plaintext);
      return OmemoPayload(
        ciphertext: cipher,
        keyMaterial: Uint8List.fromList([...key, ...tag]),
        iv: iv,
      );
    }
    final (encryptionKey, authenticationKey, iv) = await _payloadKeys(key);
    final cipher = await OmemoCrypto.aesCbcEncrypt(
      encryptionKey,
      iv,
      plaintext,
    );
    final tag = (await OmemoCrypto.hmacSha256(
      authenticationKey,
      cipher,
    )).sublist(0, suite.payloadTagLength);
    return OmemoPayload(
      ciphertext: cipher,
      keyMaterial: Uint8List.fromList([...key, ...tag]),
    );
  }

  /// A key transport message: no payload, only a fresh key.
  OmemoPayload emptyPayload(OmemoVersion version) {
    final suite = version.suite;
    final key = random.bytes(suite.payloadKeyLength);
    return OmemoPayload(
      ciphertext: Uint8List(0),
      keyMaterial: Uint8List.fromList([
        ...key,
        if (version == OmemoVersion.legacy) ...Uint8List(16),
      ]),
      iv: version == OmemoVersion.legacy ? random.bytes(12) : null,
    );
  }

  Future<Uint8List> decryptPayload(
    OmemoVersion version,
    Uint8List ciphertext,
    Uint8List keyMaterial, {
    Uint8List? iv,
  }) async {
    final suite = version.suite;
    final keyLength = suite.payloadKeyLength;
    if (keyMaterial.length < keyLength + suite.payloadTagLength) {
      throw const OmemoDecryptException('key material too short');
    }
    final key = keyMaterial.sublist(0, keyLength);
    final tag = keyMaterial.sublist(
      keyLength,
      keyLength + suite.payloadTagLength,
    );
    try {
      if (version == OmemoVersion.legacy) {
        if (iv == null || iv.length != 12) {
          throw const OmemoDecryptException('bad nonce');
        }
        return await OmemoCrypto.aesGcmDecrypt(key, iv, ciphertext, tag);
      }
      final (decryptionKey, authenticationKey, nonce) = await _payloadKeys(key);
      final expected = (await OmemoCrypto.hmacSha256(
        authenticationKey,
        ciphertext,
      )).sublist(0, suite.payloadTagLength);
      if (!OmemoCrypto.constantTimeEquals(expected, tag)) {
        throw const OmemoDecryptException('payload authentication failed');
      }
      return await OmemoCrypto.aesCbcDecrypt(decryptionKey, nonce, ciphertext);
    } on OmemoDecryptException {
      rethrow;
    } catch (_) {
      throw const OmemoDecryptException('payload decryption failed');
    }
  }

  Future<(Uint8List, Uint8List, Uint8List)> _payloadKeys(Uint8List key) async {
    final out = await OmemoCrypto.hkdf(
      key,
      salt: Uint8List(32),
      info: ascii.encode('OMEMO Payload'),
      length: 80,
    );
    return (
      Uint8List.sublistView(out, 0, 32),
      Uint8List.sublistView(out, 32, 64),
      Uint8List.sublistView(out, 64),
    );
  }

  // ---- Sessions ----------------------------------------------------------

  void _putSession(OmemoSession session) {
    final key = _sessionKey(session.version, session.jid, session.deviceId);
    final list = sessions.putIfAbsent(key, () => <OmemoSession>[]);
    list.removeWhere((existing) => identical(existing, session));
    list.insert(0, session);
    while (list.length > maxSessionsPerDevice) {
      list.removeLast();
    }
    var total = 0;
    for (final entry in sessions.values) {
      total += entry.length;
    }
    // Bounded: drop the oldest sessions of other devices when full.
    if (total > maxDeviceKeys) {
      for (final other in sessions.keys.toList()) {
        if (other == key) continue;
        sessions[other]!.removeLast();
        if (sessions[other]!.isEmpty) sessions.remove(other);
        total--;
        if (total <= maxDeviceKeys) break;
      }
    }
  }

  /// Encrypts [keyMaterial] for one device, starting a session from
  /// [bundle] when there is none. Throws [OmemoNeedsBundle] when a session
  /// is needed and [bundle] is null; [OmemoIdentityChanged] when the
  /// bundle's key differs from the remembered one; [OmemoKeyAgreementException]
  /// when the bundle is unusable.
  Future<OmemoEncryptedKey> encryptKey({
    required OmemoVersion version,
    required String jid,
    required int deviceId,
    required Uint8List keyMaterial,
    OmemoBundle? bundle,
  }) async {
    final key = _sessionKey(version, jid, deviceId);
    var session = sessions[key]?.firstOrNull;
    if (session == null) {
      if (bundle == null) throw OmemoNeedsBundle(jid, deviceId);
      final record = _remember(jid, deviceId, bundle.identityMontgomery);
      if (record.trust == OmemoTrust.distrusted) {
        throw const OmemoKeyAgreementException('the device is distrusted');
      }
      final suite = version.suite;
      final agreement = await omemoAgreeActive(suite, identity, bundle, random);
      final ratchet = await OmemoRatchet.initiate(
        suite,
        agreement.sharedSecret,
        bundle.signedPreKey,
        random,
      );
      session = OmemoSession(
        version: version,
        jid: jid,
        deviceId: deviceId,
        initiation: OmemoInitiation.active,
        ratchet: ratchet,
        associatedData: agreement.associatedData,
        peerIdentity: bundle.identityMontgomery,
        kexEphemeral: agreement.ephemeralKey,
        kexPreKeyId: agreement.preKeyId,
        kexSignedPreKeyId: bundle.signedPreKeyId,
        kexIdentity: version == OmemoVersion.legacy
            ? identity.montgomery
            : identity.edwards,
      );
    } else if (devices[jid]?[deviceId]?.trust == OmemoTrust.distrusted) {
      throw const OmemoKeyAgreementException('the device is distrusted');
    }
    final (blob, isKex) = await session.encrypt(keyMaterial);
    _putSession(session);
    return OmemoEncryptedKey(
      jid: jid,
      deviceId: deviceId,
      blob: blob,
      keyExchange: isKex,
    );
  }

  /// Decrypts the key material a device sent to this one. [sender] is the
  /// bare JID the message came from. Creates a session from a key exchange.
  /// Throws [OmemoDecryptException], [OmemoIdentityChanged],
  /// [OmemoKeyAgreementException] or [OmemoProtoException].
  Future<Uint8List> decryptKey({
    required OmemoVersion version,
    required String sender,
    required int senderDevice,
    required Uint8List blob,
    required bool keyExchange,
  }) async {
    final suite = version.suite;
    final key = _sessionKey(version, sender, senderDevice);
    if (!keyExchange) {
      final list = sessions[key];
      if (list == null || list.isEmpty) {
        throw const OmemoDecryptException('no session');
      }
      for (final session in List.of(list)) {
        try {
          final plain = await session.decrypt(blob, random);
          _putSession(session);
          return plain;
        } on OmemoDecryptException {
          continue;
        }
      }
      throw const OmemoDecryptException('no session accepted the message');
    }

    final OmemoKeyExchange kex;
    try {
      kex = suite.parseKeyExchange(blob);
    } on OmemoProtoException catch (error) {
      throw OmemoDecryptException(error.message);
    }
    // A repeat of a key exchange already turned into a session.
    for (final session in List.of(sessions[key] ?? const <OmemoSession>[])) {
      if (session.matchesKeyExchange(kex)) {
        final plain = await session.decrypt(kex.message, random);
        _putSession(session);
        return plain;
      }
    }
    final Uint8List initiatorMontgomery;
    if (version == OmemoVersion.legacy) {
      initiatorMontgomery = kex.identityKey;
    } else {
      final converted = omemoMontgomery(kex.identityKey);
      if (converted == null) {
        throw const OmemoKeyAgreementException('the identity key is invalid');
      }
      initiatorMontgomery = converted;
    }
    if (!identityMatches(sender, senderDevice, initiatorMontgomery)) {
      throw OmemoIdentityChanged(sender, senderDevice);
    }
    final suiteKeys = keys[version]!;
    final agreement = await omemoAgreePassive(suite, identity, suiteKeys, kex);
    final OmemoRatchetMessage first;
    try {
      first = parseOmemoRatchetMessage(suite, kex.message);
    } on OmemoDecryptException {
      rethrow;
    }
    final ratchet = await OmemoRatchet.respond(
      suite,
      agreement.sharedSecret,
      agreement.signedPreKey.priv,
      first.ratchetPub,
      random,
    );
    final session = OmemoSession(
      version: version,
      jid: sender,
      deviceId: senderDevice,
      initiation: OmemoInitiation.passive,
      ratchet: ratchet,
      associatedData: agreement.associatedData,
      peerIdentity: agreement.initiatorMontgomery,
      kexEphemeral: kex.ephemeralKey,
      kexPreKeyId: kex.preKeyId,
      kexSignedPreKeyId: kex.signedPreKeyId,
      kexIdentity: kex.identityKey,
    );
    final plain = await session.decrypt(kex.message, random);
    // Only now is the sender's key remembered and the pre key spent.
    _remember(sender, senderDevice, initiatorMontgomery);
    suiteKeys.preKeys.remove(kex.preKeyId);
    _putSession(session);
    return plain;
  }
}
