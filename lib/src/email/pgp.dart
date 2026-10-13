/// OpenPGP public-key messages (RFC 4880 with RFC 6637 ECDH), as Autocrypt
/// and Delta Chat use them: v4 keys with an Ed25519 (EdDSA legacy) primary
/// key and a Cv25519 encryption subkey, the keys Delta Chat, Thunderbird and
/// gpg make by default. Messages are SEIPD v1 with MDC, signed inside.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' hide Hash;

import 'aes.dart';
import 'aes_key_wrap.dart';
import 'openpgp.dart';
import 'pgp_aead.dart';

const int _ecdh = 18;
const int _eddsaLegacy = 22;
const int _sha256Id = 8;
const int _aes128 = 7;
const int _aes256 = 9;

const List<int> _ed25519Oid = [
  0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01, //
];
const List<int> _cv25519Oid = [
  0x2b, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01, //
];

/// Largest OpenPGP key read.
const int maxKeyBytes = 64 * 1024;

/// User ids read from one key, subkeys checked, and signatures checked on
/// each; at most [_maxChecksPerKey] checks in all. An honest key costs
/// about two.
const int _maxComponents = 8;
const int _maxUserIdBytes = 256;
const int _maxSubkeysChecked = 2;
const int _maxSignaturesEach = 4;
const int _maxChecksPerKey = 12;

/// Signature checks left for reading keys; one budget can be shared by all
/// the keys in one mail.
class PgpCheckBudget {
  PgpCheckBudget(this.remaining);

  int remaining;

  bool take() => remaining-- > 0;
}

/// Most a decrypted message may expand to (compressed data included).
const int maxPgpPlaintextBytes = 8 * 1024 * 1024;

/// A Cv25519 encryption subkey of a [PgpPublicKey].
class PgpEncryptionSubkey {
  PgpEncryptionSubkey._(
    this.body,
    this.fingerprint,
    this.publicKey, {
    this.wrapCipher = _aes128,
  });

  /// The public subkey packet's body.
  final Uint8List body;
  final Uint8List fingerprint;

  /// The X25519 public key (native byte order).
  final Uint8List publicKey;

  /// The cipher its owner asked for to wrap session keys (AES-128 or
  /// AES-256; the KDF hash is always SHA-256).
  final int wrapCipher;

  Uint8List get keyId => Uint8List.sublistView(fingerprint, 12);
}

/// Someone's OpenPGP key, with its self-signatures checked.
class PgpPublicKey {
  PgpPublicKey._({
    required this.bytes,
    required this.body,
    required this.fingerprint,
    required this.signingKey,
    required this.userIds,
    required this.encryptionSubkey,
    required this.symmetricPreferences,
  });

  /// The key as it is passed on (Autocrypt keydata, gossip): the primary
  /// key, its user ids and the encryption subkey, each with the signature
  /// that binds it.
  final Uint8List bytes;

  /// The primary key packet's body.
  final Uint8List body;
  final Uint8List fingerprint;

  /// The Ed25519 public key that signs.
  final Uint8List signingKey;
  final List<String> userIds;
  final PgpEncryptionSubkey encryptionSubkey;

  /// Ciphers the owner asked for, most preferred first.
  final List<int> symmetricPreferences;

  Uint8List get keyId => Uint8List.sublistView(fingerprint, 12);

  /// The fingerprint in upper-case hex, as Autocrypt and Securejoin write it.
  String get fingerprintHex => _hex(fingerprint).toUpperCase();

  /// Reads a transferable public key (binary), keeping only what its own
  /// signatures vouch for. Throws [FormatException] for keys Conest cannot
  /// use: other algorithms, revoked or expired keys, no encryption subkey.
  static Future<PgpPublicKey> parse(
    Uint8List data, {
    DateTime? now,
    PgpCheckBudget? budget,
  }) async {
    final at = now ?? DateTime.now();
    // Keys come from strangers (Autocrypt headers, gossip), and every
    // signature costs a check: large keys, and more than a few user ids,
    // subkeys and signatures each, are not read.
    if (data.length > maxKeyBytes) {
      throw const FormatException('OpenPGP key too large.');
    }
    final packets = OpenPgpSymmetric.readPackets(data);
    if (packets.isEmpty || packets.first.$1 != 6) {
      throw const FormatException('Not an OpenPGP public key.');
    }
    final body = packets.first.$2;
    final primary = _KeyMaterial.read(body);
    if (primary.algorithm != _eddsaLegacy) {
      throw const FormatException('Only Ed25519 OpenPGP keys are supported.');
    }
    final signingKey = primary.eddsaKey();
    final fingerprint = _fingerprint(body);
    final keyMaterial = _hashedKey(body);

    final userIds = <String>[];
    final kept = BytesBuilder(copy: false)
      ..add(OpenPgpSymmetric.packet(6, body));
    var preferences = const <int>[];
    var preferenceTime = -1;
    var keyExpires = 0;
    (Uint8List, (Uint8List, int), _Signature, int)? subkey;

    var index = 1;
    // Direct-key signatures and revocations straight after the key.
    final checks = budget ?? PgpCheckBudget(_maxChecksPerKey);
    Future<bool> check(_Signature signature, List<List<int>> parts) {
      if (!checks.take()) {
        throw const FormatException('Too many OpenPGP signatures to check.');
      }
      return signature.verify(signingKey, parts, fingerprint, at);
    }

    var revocationChecks = 0;
    while (index < packets.length && packets[index].$1 == 2) {
      final signature = _Signature.tryRead(packets[index].$2);
      if (signature != null &&
          signature.type == 0x20 &&
          signature.mayBeFrom(fingerprint) &&
          ++revocationChecks <= 2 &&
          await check(signature, [keyMaterial])) {
        throw const FormatException('This OpenPGP key was revoked.');
      }
      index++;
    }
    // Signatures that may be the key's own, newest first, a few at most.
    List<_Signature> own(List<_Signature> signatures, Set<int> types) =>
        (signatures
                .where(
                  (signature) =>
                      types.contains(signature.type) &&
                      signature.mayBeFrom(fingerprint),
                )
                .toList()
              ..sort((a, b) => b.created.compareTo(a.created)))
            .take(_maxSignaturesEach)
            .toList();

    final subkeys = <(Uint8List, (Uint8List, int), int, List<_Signature>)>[];
    var userIdCount = 0;
    while (index < packets.length) {
      final (tag, packetBody) = packets[index++];
      final signatures = <_Signature>[];
      while (index < packets.length && packets[index].$1 == 2) {
        final signature = _Signature.tryRead(packets[index++].$2);
        if (signature != null) signatures.add(signature);
      }
      if (tag == 13) {
        // Long user ids (and many) are not read: keys are stored.
        if (packetBody.length > _maxUserIdBytes ||
            ++userIdCount > _maxComponents) {
          continue;
        }
        final userId = [0xb4, ..._be32(packetBody.length), ...packetBody];
        _Signature? best;
        // The newest good one is enough.
        for (final signature in own(signatures, const {
          0x10,
          0x11,
          0x12,
          0x13,
        })) {
          if (await check(signature, [keyMaterial, userId])) {
            best = signature;
            break;
          }
        }
        if (best == null) continue;
        userIds.add(utf8.decode(packetBody, allowMalformed: true));
        // The kept key carries one user id: it is what gets stored.
        if (userIds.length == 1) {
          kept
            ..add(OpenPgpSymmetric.packet(13, packetBody))
            ..add(OpenPgpSymmetric.packet(2, best.raw));
        }
        if (best.created > preferenceTime) {
          preferenceTime = best.created;
          preferences = best.hashed[11]?.firstOrNull ?? const [];
          final expiry = best.hashed[9]?.firstOrNull;
          keyExpires = expiry == null || expiry.length != 4
              ? 0
              : _readBe32(expiry, 0);
        }
      } else if (tag == 14) {
        // Collected for now (reading one costs nothing); the newest are
        // checked below.
        final material = _KeyMaterial.tryRead(packetBody);
        if (material == null || material.algorithm != _ecdh) continue;
        final cv25519 = material.cv25519Key();
        if (cv25519 == null) continue;
        subkeys.add((
          packetBody,
          cv25519,
          material.created,
          own(signatures, const {0x18, 0x28}),
        ));
      }
      // Other packets (attributes, trust, unknown) are left out.
    }
    subkeys.sort((a, b) => b.$3.compareTo(a.$3));
    for (final (packetBody, cv25519, created, signatures) in subkeys.take(
      _maxSubkeysChecked,
    )) {
      final subkeyMaterial = _hashedKey(packetBody);
      _Signature? binding;
      for (final signature in signatures) {
        if (!await check(signature, [keyMaterial, subkeyMaterial])) continue;
        // Newest first: a revocation newer than any binding ends it.
        if (signature.type == 0x18) binding = signature;
        break;
      }
      if (binding == null) continue;
      final flags = binding.hashed[27]?.firstOrNull;
      if (flags != null && flags.isNotEmpty && flags[0] & 0x0c == 0) {
        continue;
      }
      final expiry = binding.hashed[9]?.firstOrNull;
      if (expiry != null &&
          expiry.length == 4 &&
          _readBe32(expiry, 0) != 0 &&
          created + _readBe32(expiry, 0) <= at.millisecondsSinceEpoch ~/ 1000) {
        continue;
      }
      subkey = (packetBody, cv25519, binding, created);
      break;
    }
    if (userIds.isEmpty) {
      throw const FormatException('The OpenPGP key has no signed user id.');
    }
    if (keyExpires != 0 &&
        primary.created + keyExpires <= at.millisecondsSinceEpoch ~/ 1000) {
      throw const FormatException('This OpenPGP key has expired.');
    }
    if (subkey == null) {
      throw const FormatException('The OpenPGP key has no encryption key.');
    }
    kept
      ..add(OpenPgpSymmetric.packet(14, subkey.$1))
      ..add(OpenPgpSymmetric.packet(2, subkey.$3.raw));
    return PgpPublicKey._(
      bytes: kept.takeBytes(),
      body: body,
      fingerprint: fingerprint,
      signingKey: signingKey,
      userIds: List.unmodifiable(userIds),
      encryptionSubkey: PgpEncryptionSubkey._(
        subkey.$1,
        _fingerprint(subkey.$1),
        subkey.$2.$1,
        wrapCipher: subkey.$2.$2,
      ),
      symmetricPreferences: List.unmodifiable(preferences),
    );
  }
}

/// This device's OpenPGP key: an Ed25519 primary key and a Cv25519
/// encryption subkey.
class PgpSecretKey {
  PgpSecretKey._(this.publicKey, this._signingSeed, this._encryptionSecret);

  final PgpPublicKey publicKey;
  final Uint8List _signingSeed;
  final Uint8List _encryptionSecret;

  /// A new key for [userId] (for example `<me@example.org>`).
  static Future<PgpSecretKey> generate(
    String userId, {
    DateTime? created,
    Random? random,
  }) async {
    final source = random ?? Random.secure();
    Uint8List randomBytes(int length) =>
        Uint8List.fromList(List.generate(length, (_) => source.nextInt(256)));
    return _build(
      userId,
      (created ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
      randomBytes(32),
      randomBytes(32),
    );
  }

  static Future<PgpSecretKey> _build(
    String userId,
    int created,
    Uint8List signingSeed,
    Uint8List encryptionSecret,
  ) async {
    final signing = await Ed25519().newKeyPairFromSeed(signingSeed);
    final signingPublic = Uint8List.fromList(
      (await signing.extractPublicKey()).bytes,
    );
    final encryption = await X25519().newKeyPairFromSeed(encryptionSecret);
    final encryptionPublic = Uint8List.fromList(
      (await encryption.extractPublicKey()).bytes,
    );

    final primaryBody = Uint8List.fromList([
      4,
      ..._be32(created),
      _eddsaLegacy,
      _ed25519Oid.length,
      ..._ed25519Oid,
      ..._mpi([0x40, ...signingPublic]),
    ]);
    final subkeyBody = Uint8List.fromList([
      4,
      ..._be32(created),
      _ecdh,
      _cv25519Oid.length,
      ..._cv25519Oid,
      ..._mpi([0x40, ...encryptionPublic]),
      3,
      1,
      _sha256Id,
      _aes128,
    ]);
    final fingerprint = _fingerprint(primaryBody);
    final userIdBytes = utf8.encode(userId);
    final certification = await _sign(
      signing,
      0x13,
      [
        _hashedKey(primaryBody),
        [0xb4, ..._be32(userIdBytes.length), ...userIdBytes],
      ],
      fingerprint,
      created,
      [
        _subpacket(27, [0x03]), // certify, sign
        _subpacket(11, [_aes256, 8, _aes128]),
        _subpacket(21, [_sha256Id, 10, 9]),
        _subpacket(22, [2, 1, 0]),
        _subpacket(30, [0x01]), // MDC
      ],
    );
    final binding = await _sign(
      signing,
      0x18,
      [_hashedKey(primaryBody), _hashedKey(subkeyBody)],
      fingerprint,
      created,
      [
        _subpacket(27, [0x0c]),
      ], // encrypt communications and storage
    );
    final bytes = Uint8List.fromList([
      ...OpenPgpSymmetric.packet(6, primaryBody),
      ...OpenPgpSymmetric.packet(13, userIdBytes),
      ...OpenPgpSymmetric.packet(2, certification),
      ...OpenPgpSymmetric.packet(14, subkeyBody),
      ...OpenPgpSymmetric.packet(2, binding),
    ]);
    return PgpSecretKey._(
      PgpPublicKey._(
        bytes: bytes,
        body: primaryBody,
        fingerprint: fingerprint,
        signingKey: signingPublic,
        userIds: [userId],
        encryptionSubkey: PgpEncryptionSubkey._(
          subkeyBody,
          _fingerprint(subkeyBody),
          encryptionPublic,
        ),
        symmetricPreferences: const [_aes256, 8, _aes128],
      ),
      signingSeed,
      encryptionSecret,
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': publicKey.userIds.first,
    'created': _readBe32(publicKey.body, 1),
    'signing': base64Encode(_signingSeed),
    'encryption': base64Encode(_encryptionSecret),
  };

  static Future<PgpSecretKey> fromJson(Map<String, dynamic> json) async {
    final userId = json['userId'];
    final created = json['created'];
    final signing = base64Decode(json['signing'] as String);
    final encryption = base64Decode(json['encryption'] as String);
    if (userId is! String ||
        created is! int ||
        signing.length != 32 ||
        encryption.length != 32) {
      throw const FormatException('Malformed OpenPGP secret key.');
    }
    return _build(userId, created, signing, encryption);
  }
}

/// A decrypted message.
class PgpDecrypted {
  PgpDecrypted._(this.data, this._signatures, this._now);

  final Uint8List data;
  final List<_Signature> _signatures;
  final DateTime _now;

  /// The key whose good signature the message carries (one of the keys
  /// given to [Pgp.decrypt]), or null.
  PgpPublicKey? signer;

  /// It carried a signature, good or not, from a known key or not.
  bool get signed => _signatures.isNotEmpty;

  /// Fingerprints the good signature found by [verify] names as intended
  /// recipients (empty when it names none).
  List<Uint8List> intendedRecipients = const [];

  /// The first of [keys] that made a good signature on it, or null.
  Future<PgpPublicKey?> verify(List<PgpPublicKey> keys) async {
    for (final signature in _signatures) {
      if (signature.type != 0x00 && signature.type != 0x01) continue;
      final hashed = signature.type == 0x01 ? _canonicalText(data) : data;
      for (final key in keys) {
        if (!signature.mayBeFrom(key.fingerprint)) continue;
        if (await signature.verify(
          key.signingKey,
          [hashed],
          key.fingerprint,
          _now,
        )) {
          intendedRecipients = [
            for (final value in signature.hashed[35] ?? const <Uint8List>[])
              if (value.length == 21 && value[0] == 4)
                Uint8List.sublistView(value, 1),
          ];
          return key;
        }
      }
    }
    return null;
  }
}

/// Encrypting to, and decrypting from, OpenPGP keys.
abstract final class Pgp {
  /// Encrypts [data] to [recipients] (and to [signer] itself, so the sent
  /// copy stays readable), signed by [signer].
  static Future<Uint8List> encrypt(
    Uint8List data,
    List<PgpPublicKey> recipients, {
    required PgpSecretKey signer,
    Random? random,
    DateTime? now,
  }) async {
    final source = random ?? Random.secure();
    Uint8List randomBytes(int length) =>
        Uint8List.fromList(List.generate(length, (_) => source.nextInt(256)));
    final created = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final everyone = [
      signer.publicKey,
      for (final key in recipients)
        if (!_same(key.fingerprint, signer.publicKey.fingerprint)) key,
    ];
    final algorithm =
        everyone.every((key) => key.symmetricPreferences.contains(_aes256))
        ? _aes256
        : _aes128;
    final sessionKey = randomBytes(algorithm == _aes256 ? 32 : 16);

    final keys = BytesBuilder(copy: false);
    for (final key in everyone) {
      keys.add(
        OpenPgpSymmetric.packet(
          1,
          await _wrapSessionKey(key, algorithm, sessionKey, randomBytes(32)),
        ),
      );
    }

    final inner = await _literal(
      data,
      created,
      signer: signer,
      recipients: recipients,
    );

    final prefix = randomBytes(16);
    final clear = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(prefix.sublist(14))
      ..add(inner)
      ..add([0xd3, 0x14]);
    final mdcInput = clear.takeBytes();
    final plaintext = Uint8List.fromList([
      ...mdcInput,
      ...sha1.convert(mdcInput).bytes,
    ]);
    final encrypted = OpenPgpSymmetric.cfb(
      AesBlockCipher(sessionKey),
      plaintext,
      encrypt: true,
    );
    keys.add(OpenPgpSymmetric.packet(18, [1, ...encrypted]));
    return keys.takeBytes();
  }

  /// [data] as a literal packet, signed by [signer] (one-pass) if given.
  static Future<Uint8List> _literal(
    Uint8List data,
    int created, {
    PgpSecretKey? signer,
    List<PgpPublicKey> recipients = const [],
  }) async {
    final literal = OpenPgpSymmetric.packet(11, [
      0x62, // 'b': binary
      0,
      ..._be32(created),
      ...data,
    ]);
    if (signer == null) return Uint8List.fromList(literal);
    final signing = await Ed25519().newKeyPairFromSeed(signer._signingSeed);
    final signerKey = signer.publicKey;
    final signature = await _sign(
      signing,
      0x00,
      [data],
      signerKey.fingerprint,
      created,
      [
        for (final key in recipients) _subpacket(35, [4, ...key.fingerprint]),
      ],
    );
    return (BytesBuilder(copy: false)
          ..add(
            OpenPgpSymmetric.packet(4, [
              3,
              0x00,
              _sha256Id,
              _eddsaLegacy,
              ...signerKey.keyId,
              1,
            ]),
          )
          ..add(literal)
          ..add(OpenPgpSymmetric.packet(2, signature)))
        .takeBytes();
  }

  /// [data] encrypted with [password] as an OpenPGP v6 message (v6 SKESK,
  /// v2 SEIPD with AES-OCB), signed by [signer] if given.
  static Future<Uint8List> encryptWithPassword(
    Uint8List data,
    List<int> password, {
    PgpSecretKey? signer,
    Random? random,
    DateTime? now,
  }) async {
    final created = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    return OpenPgpAead.encrypt(
      await _literal(data, created, signer: signer),
      password,
      random: random,
    );
  }

  /// Decrypts a password-encrypted v6 message with one of [passwords],
  /// checking its signature against [senders]: the message and the
  /// password that opened it, or null when none does.
  static Future<(PgpDecrypted, List<int>)?> decryptWithPasswords(
    Uint8List message,
    List<List<int>> passwords, {
    List<PgpPublicKey> senders = const [],
    DateTime? now,
  }) async {
    final opened = OpenPgpAead.decrypt(message, passwords);
    if (opened == null) return null;
    final (inner, password) = opened;
    return (
      await _readSigned(inner, senders, now ?? DateTime.now(), depth: 0),
      password,
    );
  }

  /// Decrypts [message] with [key], checking its signature against
  /// [senders]. Throws [FormatException] if it is not for [key], or was
  /// changed.
  static Future<PgpDecrypted> decrypt(
    Uint8List message,
    PgpSecretKey key, {
    List<PgpPublicKey> senders = const [],
    DateTime? now,
  }) async {
    final packets = OpenPgpSymmetric.readPackets(message);
    final subkey = key.publicKey.encryptionSubkey;
    (int, Uint8List)? session;
    Uint8List? data;
    final named = <Uint8List>[];
    final anonymous = <Uint8List>[];
    for (final (tag, body) in packets) {
      if (tag == 1) {
        // Each try costs a key agreement: packets naming this key first,
        // and only a few that name no key (a big group has many packets,
        // a hostile mail could have thousands).
        if (body.length >= 9 && _same(body.sublist(1, 9), subkey.keyId)) {
          if (named.length < 4) named.add(body);
        } else if (body.length >= 9 &&
            body.sublist(1, 9).every((b) => b == 0)) {
          if (anonymous.length < 4) anonymous.add(body);
        }
      } else if (tag == 18) {
        data = body;
      } else if (tag == 20) {
        throw const FormatException('OpenPGP AEAD messages are not supported.');
      } else if (tag != 3 && tag != 10) {
        throw const FormatException('Unexpected OpenPGP packet.');
      }
    }
    for (final body in [...named, ...anonymous]) {
      session ??= await _unwrapSessionKey(body, key, subkey);
    }
    if (session == null) {
      throw const FormatException('This OpenPGP message is not for this key.');
    }
    if (data == null) {
      throw const FormatException('The OpenPGP message holds no data.');
    }
    final inner = _decryptSeipd(data, session.$2);
    return _readSigned(inner, senders, now ?? DateTime.now(), depth: 0);
  }

  static Future<List<int>> _wrapSessionKey(
    PgpPublicKey key,
    int algorithm,
    Uint8List sessionKey,
    Uint8List ephemeralSeed,
  ) async {
    final subkey = key.encryptionSubkey;
    final ephemeral = await X25519().newKeyPairFromSeed(ephemeralSeed);
    final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
    final shared = await X25519().sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        subkey.publicKey,
        type: KeyPairType.x25519,
      ),
    );
    final kek = _kdf(await shared.extractBytes(), subkey);
    var checksum = 0;
    for (final byte in sessionKey) {
      checksum = (checksum + byte) & 0xffff;
    }
    final plain = [algorithm, ...sessionKey, checksum >> 8, checksum & 0xff];
    final padding = 8 - plain.length % 8;
    final wrapped = AesKeyWrap.wrap(
      kek,
      Uint8List.fromList([...plain, for (var i = 0; i < padding; i++) padding]),
    );
    return [
      3,
      ...subkey.keyId,
      _ecdh,
      ..._mpi([0x40, ...ephemeralPublic]),
      wrapped.length,
      ...wrapped,
    ];
  }

  static Future<(int, Uint8List)?> _unwrapSessionKey(
    Uint8List body,
    PgpSecretKey key,
    PgpEncryptionSubkey subkey,
  ) async {
    if (body.length < 10 || body[0] != 3 || body[9] != _ecdh) return null;
    final keyId = Uint8List.sublistView(body, 1, 9);
    if (!keyId.every((byte) => byte == 0) && !_same(keyId, subkey.keyId)) {
      return null;
    }
    try {
      final reader = _Reader(body, 10);
      final ephemeral = reader.mpi();
      if (ephemeral.length != 33 || ephemeral[0] != 0x40) return null;
      final wrappedLength = reader.byte();
      final wrapped = reader.take(wrappedLength);
      final pair = await X25519().newKeyPairFromSeed(key._encryptionSecret);
      final shared = await X25519().sharedSecretKey(
        keyPair: pair,
        remotePublicKey: SimplePublicKey(
          ephemeral.sublist(1),
          type: KeyPairType.x25519,
        ),
      );
      final kek = _kdf(await shared.extractBytes(), subkey);
      final plain = AesKeyWrap.unwrap(kek, wrapped);
      final padding = plain.last;
      if (padding == 0 || padding > 8 || padding >= plain.length) return null;
      for (var index = plain.length - padding; index < plain.length; index++) {
        if (plain[index] != padding) return null;
      }
      final unpadded = plain.sublist(0, plain.length - padding);
      final algorithm = unpadded[0];
      final keyLength = switch (algorithm) {
        _aes128 => 16,
        8 => 24,
        _aes256 => 32,
        _ => 0,
      };
      if (keyLength == 0 || unpadded.length != 1 + keyLength + 2) return null;
      final sessionKey = unpadded.sublist(1, 1 + keyLength);
      var checksum = 0;
      for (final byte in sessionKey) {
        checksum = (checksum + byte) & 0xffff;
      }
      if (checksum !=
          (unpadded[1 + keyLength] << 8 | unpadded[2 + keyLength])) {
        return null;
      }
      return (algorithm, sessionKey);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static Uint8List _decryptSeipd(Uint8List data, Uint8List sessionKey) {
    if (data.isEmpty || data[0] != 1 || data.length < 1 + 18 + 22) {
      throw const FormatException('Unsupported OpenPGP data packet.');
    }
    final plain = OpenPgpSymmetric.cfb(
      AesBlockCipher(sessionKey),
      Uint8List.sublistView(data, 1),
      encrypt: false,
    );
    final body = Uint8List.sublistView(plain, 0, plain.length - 20);
    final mdc = Uint8List.sublistView(plain, plain.length - 20);
    final expected = sha1.convert(body).bytes;
    var difference = 0;
    for (var index = 0; index < 20; index++) {
      difference |= expected[index] ^ mdc[index];
    }
    // The quick check is part of the MDC, so a wrong key fails here too.
    if (difference != 0 ||
        body[body.length - 2] != 0xd3 ||
        body[body.length - 1] != 0x14) {
      throw const FormatException('OpenPGP integrity check failed.');
    }
    return Uint8List.sublistView(body, 18, body.length - 2);
  }

  static Future<PgpDecrypted> _readSigned(
    Uint8List data,
    List<PgpPublicKey> senders,
    DateTime now, {
    required int depth,
  }) async {
    final packets = OpenPgpSymmetric.readPackets(data);
    if (packets.length == 1 && packets.single.$1 == 8) {
      if (depth > 0) {
        throw const FormatException('Nested OpenPGP compression.');
      }
      return _readSigned(
        _decompress(packets.single.$2),
        senders,
        now,
        depth: depth + 1,
      );
    }
    Uint8List? content;
    final signatures = <_Signature>[];
    for (final (tag, body) in packets) {
      switch (tag) {
        case 4: // one-pass signature: the signature follows
          break;
        case 21: // padding (RFC 9580)
          break;
        case 11:
          if (content != null) {
            throw const FormatException('Several OpenPGP literal packets.');
          }
          if (body.length < 6 || 2 + body[1] + 4 > body.length) {
            throw const FormatException('OpenPGP literal data is truncated.');
          }
          content = Uint8List.sublistView(body, 2 + body[1] + 4);
        case 2:
          // A few, naming their signer: each check hashes the whole
          // message.
          final signature = _Signature.tryRead(body);
          if (signature != null &&
              signatures.length < 4 &&
              signature.namesIssuer) {
            signatures.add(signature);
          }
        default:
          throw const FormatException('Unexpected packet in OpenPGP message.');
      }
    }
    if (content == null) {
      throw const FormatException('OpenPGP message holds no literal data.');
    }
    final decrypted = PgpDecrypted._(content, signatures, now);
    decrypted.signer = await decrypted.verify(senders);
    return decrypted;
  }

  static Uint8List _decompress(Uint8List body) {
    if (body.isEmpty) throw const FormatException('Empty compressed packet.');
    final input = Uint8List.sublistView(body, 1);
    switch (body[0]) {
      case 0:
        return input;
      case 1:
      case 2:
        final sink = _LimitedSink(maxPgpPlaintextBytes);
        final decoder = ZLibDecoder(
          raw: body[0] == 1,
        ).startChunkedConversion(sink);
        try {
          for (var offset = 0; offset < input.length; offset += 4096) {
            decoder.add(
              Uint8List.sublistView(
                input,
                offset,
                min(offset + 4096, input.length),
              ),
            );
          }
          decoder.close();
        } on FormatException {
          rethrow;
        } catch (_) {
          throw const FormatException('Malformed OpenPGP compressed data.');
        }
        return sink.takeBytes();
      default:
        throw const FormatException('Unsupported OpenPGP compression.');
    }
  }
}

class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this.limit);

  final int limit;
  final _builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (_builder.length + data.length > limit) {
      throw const FormatException('OpenPGP message too large.');
    }
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

/// A v4 signature packet.
class _Signature {
  _Signature._(
    this.raw,
    this.type,
    this.hashAlgorithm,
    this.hashedArea,
    this.hashed,
    this.unhashed,
    this.left16,
    this.r,
    this.s,
  );

  final Uint8List raw;
  final int type;
  final int hashAlgorithm;

  /// Version through hashed subpackets: the signed trailer's start.
  final Uint8List hashedArea;
  final Map<int, List<Uint8List>> hashed;
  final Map<int, List<Uint8List>> unhashed;
  final Uint8List left16;
  final Uint8List r;
  final Uint8List s;

  int get created {
    final time = hashed[2]?.firstOrNull;
    return time == null || time.length != 4 ? 0 : _readBe32(time, 0);
  }

  /// Subpackets this reader knows; others marked critical void the
  /// signature (RFC 4880 5.2.3.1).
  static const _understood = {2, 3, 9, 11, 16, 21, 22, 23, 25, 27, 30, 33, 35};

  static _Signature? tryRead(Uint8List body) {
    try {
      final reader = _Reader(body, 0);
      if (reader.byte() != 4) return null;
      final type = reader.byte();
      if (reader.byte() != _eddsaLegacy) return null;
      final hashAlgorithm = reader.byte();
      final hashedLength = reader.be16();
      final hashedBytes = reader.take(hashedLength);
      final hashedArea = Uint8List.sublistView(body, 0, 6 + hashedLength);
      final hashed = _subpackets(hashedBytes, strict: true);
      if (hashed == null) return null;
      final unhashed = _subpackets(reader.take(reader.be16()), strict: false);
      final left16 = reader.take(2);
      final r = reader.mpi();
      final s = reader.mpi();
      if (r.length > 32 || s.length > 32) return null;
      return _Signature._(
        body,
        type,
        hashAlgorithm,
        hashedArea,
        hashed,
        unhashed ?? const {},
        left16,
        _leftPad(r, 32),
        _leftPad(s, 32),
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  static Map<int, List<Uint8List>>? _subpackets(
    Uint8List area, {
    required bool strict,
  }) {
    final result = <int, List<Uint8List>>{};
    final reader = _Reader(area, 0);
    while (!reader.done) {
      final first = reader.byte();
      int length;
      if (first < 192) {
        length = first;
      } else if (first < 255) {
        length = ((first - 192) << 8) + reader.byte() + 192;
      } else {
        length = reader.be32();
      }
      if (length < 1) throw const FormatException('Empty subpacket.');
      final type = reader.byte();
      final data = reader.take(length - 1);
      final kind = type & 0x7f;
      if (strict && type & 0x80 != 0 && !_understood.contains(kind)) {
        return null;
      }
      result.putIfAbsent(kind, () => []).add(data);
    }
    return result;
  }

  /// It says who made it (issuer fingerprint or key id).
  bool get namesIssuer =>
      [
        ...?hashed[33],
        ...?unhashed[33],
      ].any((issuer) => issuer.length == 21 && issuer[0] == 4) ||
      [...?hashed[16], ...?unhashed[16]].any((issuer) => issuer.length == 8);

  /// The issuer subpackets do not rule out [fingerprint].
  bool mayBeFrom(Uint8List fingerprint) {
    for (final issuer in [...?hashed[33], ...?unhashed[33]]) {
      if (issuer.length != 21 ||
          issuer[0] != 4 ||
          !_same(Uint8List.sublistView(issuer, 1), fingerprint)) {
        return false;
      }
    }
    for (final issuer in [...?hashed[16], ...?unhashed[16]]) {
      if (issuer.length != 8 ||
          !_same(issuer, Uint8List.sublistView(fingerprint, 12))) {
        return false;
      }
    }
    return true;
  }

  /// Checks this signature by [publicKey] over [parts].
  Future<bool> verify(
    Uint8List publicKey,
    List<List<int>> parts,
    Uint8List fingerprint,
    DateTime now,
  ) async {
    if (!mayBeFrom(fingerprint)) return false;
    final hash = _hash(hashAlgorithm);
    if (hash == null) return false;
    // A signature says when it was made, and not far in the future.
    final made = hashed[2]?.firstOrNull;
    if (made == null ||
        made.length != 4 ||
        created > now.millisecondsSinceEpoch ~/ 1000 + 24 * 3600) {
      return false;
    }
    final expiry = hashed[3]?.firstOrNull;
    if (expiry != null &&
        expiry.length == 4 &&
        _readBe32(expiry, 0) != 0 &&
        created + _readBe32(expiry, 0) <= now.millisecondsSinceEpoch ~/ 1000) {
      return false;
    }
    final digest = _digest(hash, [
      ...parts,
      hashedArea,
      [0x04, 0xff, ..._be32(hashedArea.length)],
    ]);
    if (digest[0] != left16[0] || digest[1] != left16[1]) return false;
    return Ed25519().verify(
      digest,
      signature: Signature([
        ...r,
        ...s,
      ], publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  }
}

/// Key fields of a v4 public key packet.
class _KeyMaterial {
  _KeyMaterial(this.created, this.algorithm, this.reader);

  final int created;
  final int algorithm;
  final _Reader reader;

  static _KeyMaterial read(Uint8List body) {
    final reader = _Reader(body, 0);
    if (reader.byte() != 4) {
      throw const FormatException('Only v4 OpenPGP keys are supported.');
    }
    return _KeyMaterial(reader.be32(), reader.byte(), reader);
  }

  static _KeyMaterial? tryRead(Uint8List body) {
    try {
      return read(body);
    } on FormatException {
      return null;
    }
  }

  Uint8List eddsaKey() {
    final oid = reader.take(reader.byte());
    if (!_same(oid, _ed25519Oid)) {
      throw const FormatException('Only Ed25519 OpenPGP keys are supported.');
    }
    final point = reader.mpi();
    if (point.length != 33 || point[0] != 0x40) {
      throw const FormatException('Malformed Ed25519 OpenPGP key.');
    }
    return Uint8List.fromList(point.sublist(1));
  }

  /// The X25519 key and its key-wrap cipher.
  (Uint8List, int)? cv25519Key() {
    try {
      final oid = reader.take(reader.byte());
      if (!_same(oid, _cv25519Oid)) return null;
      final point = reader.mpi();
      if (point.length != 33 || point[0] != 0x40) return null;
      final kdf = reader.take(reader.byte());
      // KDF with SHA-256 and AES-128 or AES-256 key wrapping only.
      if (kdf.length != 3 ||
          kdf[0] != 1 ||
          kdf[1] != _sha256Id ||
          (kdf[2] != _aes128 && kdf[2] != _aes256)) {
        return null;
      }
      return (Uint8List.fromList(point.sublist(1)), kdf[2]);
    } on FormatException {
      return null;
    }
  }
}

class _Reader {
  _Reader(this.data, this.offset);

  final Uint8List data;
  int offset;

  bool get done => offset >= data.length;

  int byte() {
    if (offset >= data.length) throw const FormatException('Truncated.');
    return data[offset++];
  }

  int be16() => byte() << 8 | byte();

  int be32() => be16() << 16 | be16();

  Uint8List take(int length) {
    if (length < 0 || offset + length > data.length) {
      throw const FormatException('Truncated.');
    }
    final result = Uint8List.sublistView(data, offset, offset + length);
    offset += length;
    return result;
  }

  Uint8List mpi() => take((be16() + 7) >> 3);
}

/// The ECDH key-encryption key (RFC 6637 section 7) for a Cv25519
/// [subkey]: SHA-256, and a 16- or 32-byte key for its wrap cipher.
Uint8List _kdf(List<int> shared, PgpEncryptionSubkey subkey) {
  final param = [
    _cv25519Oid.length,
    ..._cv25519Oid,
    _ecdh,
    3,
    1,
    _sha256Id,
    subkey.wrapCipher,
    ...ascii.encode('Anonymous Sender    '),
    ...subkey.fingerprint,
  ];
  final digest = sha256.convert([0, 0, 0, 1, ...shared, ...param]).bytes;
  return Uint8List.fromList(
    digest.sublist(0, subkey.wrapCipher == _aes256 ? 32 : 16),
  );
}

Future<Uint8List> _sign(
  SimpleKeyPair signing,
  int type,
  List<List<int>> parts,
  Uint8List fingerprint,
  int created,
  List<List<int>> extraHashed,
) async {
  final hashedSubpackets = [
    ..._subpacket(2, _be32(created)),
    ..._subpacket(33, [4, ...fingerprint]),
    for (final subpacket in extraHashed) ...subpacket,
  ];
  final hashedArea = [
    4,
    type,
    _eddsaLegacy,
    _sha256Id,
    hashedSubpackets.length >> 8,
    hashedSubpackets.length & 0xff,
    ...hashedSubpackets,
  ];
  final digest = _digest(sha256, [
    ...parts,
    hashedArea,
    [0x04, 0xff, ..._be32(hashedArea.length)],
  ]);
  final signature = (await Ed25519().sign(digest, keyPair: signing)).bytes;
  final unhashed = _subpacket(16, Uint8List.sublistView(fingerprint, 12));
  return Uint8List.fromList([
    ...hashedArea,
    unhashed.length >> 8,
    unhashed.length & 0xff,
    ...unhashed,
    digest[0],
    digest[1],
    ..._mpi(signature.sublist(0, 32)),
    ..._mpi(signature.sublist(32)),
  ]);
}

Hash? _hash(int algorithm) => switch (algorithm) {
  8 => sha256,
  9 => sha384,
  10 => sha512,
  11 => sha224,
  _ => null, // MD5 and SHA-1 signatures are refused
};

Uint8List _digest(Hash hash, List<List<int>> parts) {
  final sink = _DigestSink();
  final input = hash.startChunkedConversion(sink);
  for (final part in parts) {
    input.add(part);
  }
  input.close();
  return Uint8List.fromList(sink.value!.bytes);
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Text signatures (type 0x01) hash lines ending in CR LF.
List<int> _canonicalText(Uint8List data) {
  final out = BytesBuilder(copy: false);
  for (var index = 0; index < data.length; index++) {
    final byte = data[index];
    if (byte == 0x0a && (index == 0 || data[index - 1] != 0x0d)) {
      out.addByte(0x0d);
    }
    out.addByte(byte);
  }
  return out.takeBytes();
}

List<int> _hashedKey(Uint8List body) => [
  0x99,
  body.length >> 8,
  body.length & 0xff,
  ...body,
];

Uint8List _fingerprint(Uint8List body) =>
    Uint8List.fromList(sha1.convert(_hashedKey(body)).bytes);

List<int> _subpacket(int type, List<int> data) {
  final length = data.length + 1;
  if (length >= 192) throw ArgumentError('Subpacket too long.');
  return [length, type, ...data];
}

/// An MPI of [value] (big-endian, leading zeros dropped).
List<int> _mpi(List<int> value) {
  var start = 0;
  while (start < value.length && value[start] == 0) {
    start++;
  }
  final trimmed = value.sublist(start);
  final bits = trimmed.isEmpty
      ? 0
      : (trimmed.length - 1) * 8 + trimmed.first.bitLength;
  return [bits >> 8, bits & 0xff, ...trimmed];
}

Uint8List _leftPad(Uint8List value, int length) =>
    Uint8List(length)..setRange(length - value.length, length, value);

List<int> _be32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

int _readBe32(List<int> data, int offset) =>
    data[offset] << 24 |
    data[offset + 1] << 16 |
    data[offset + 2] << 8 |
    data[offset + 3];

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
