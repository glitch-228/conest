import 'dart:convert';
import 'dart:typed_data';

import 'omemo_ratchet.dart';
import 'omemo_random.dart';
import 'omemo_suite.dart';

enum OmemoInitiation { active, passive }

/// One Double Ratchet session with one device of someone else.
class OmemoSession {
  OmemoSession({
    required this.version,
    required this.jid,
    required this.deviceId,
    required this.initiation,
    required this.ratchet,
    required this.associatedData,
    required this.peerIdentity,
    required this.kexEphemeral,
    required this.kexPreKeyId,
    required this.kexSignedPreKeyId,
    required this.kexIdentity,
    this.confirmed = false,
  });

  final OmemoVersion version;
  final String jid;
  final int deviceId;
  final OmemoInitiation initiation;
  final OmemoRatchet ratchet;

  /// Initiator identity then responder identity.
  final Uint8List associatedData;

  /// The peer's identity key (Curve25519).
  final Uint8List peerIdentity;

  /// The key exchange this session came from. For an active session it
  /// goes with every message until the peer answers; for a passive one it
  /// recognizes a repeated key exchange.
  final Uint8List kexEphemeral;
  final int kexPreKeyId;
  final int kexSignedPreKeyId;

  /// The initiator's identity key as sent in the key exchange (legacy:
  /// Curve25519, OMEMO 2: Ed25519).
  final Uint8List kexIdentity;
  bool confirmed;

  OmemoSuite get suite => version.suite;

  Uint8List _adFor({required bool sending}) {
    if (!suite.directional) return associatedData;
    // Legacy OMEMO authenticates "sender identity, receiver identity".
    final initiatorSends = (initiation == OmemoInitiation.active) == sending;
    if (initiatorSends) return associatedData;
    final length = suite.identityLength;
    return Uint8List.fromList([
      ...associatedData.sublist(length),
      ...associatedData.sublist(0, length),
    ]);
  }

  bool get needsKeyExchange =>
      initiation == OmemoInitiation.active && !confirmed;

  /// Whether [kex] describes the same key exchange as this session's.
  bool matchesKeyExchange(OmemoKeyExchange kex) =>
      initiation == OmemoInitiation.passive &&
      kex.preKeyId == kexPreKeyId &&
      kex.signedPreKeyId == kexSignedPreKeyId &&
      _same(kex.ephemeralKey, kexEphemeral) &&
      _same(kex.identityKey, kexIdentity);

  /// Encrypts [keyMaterial] for the peer; the result is what goes into the
  /// `<key>` element, and whether the element is a key exchange.
  Future<(Uint8List, bool)> encrypt(Uint8List keyMaterial) async {
    final sealed = await ratchet.encrypt(keyMaterial, _adFor(sending: true));
    if (!needsKeyExchange) return (sealed, false);
    final kex = suite.encodeKeyExchange(
      OmemoKeyExchange(
        preKeyId: kexPreKeyId,
        signedPreKeyId: kexSignedPreKeyId,
        identityKey: kexIdentity,
        ephemeralKey: kexEphemeral,
        message: sealed,
      ),
    );
    return (kex, true);
  }

  /// Decrypts a sealed ratchet message (the key exchange already taken off).
  Future<Uint8List> decrypt(Uint8List sealed, OmemoRandom random) async {
    final plain = await ratchet.decrypt(sealed, _adFor(sending: false), random);
    confirmed = true;
    return plain;
  }

  Map<String, Object?> toJson() => {
    'v': version.name,
    'jid': jid,
    'dev': deviceId,
    'init': initiation.name,
    'ratchet': ratchet.toJson(),
    'ad': base64.encode(associatedData),
    'peer': base64.encode(peerIdentity),
    'kexEk': base64.encode(kexEphemeral),
    'kexPk': kexPreKeyId,
    'kexSpk': kexSignedPreKeyId,
    'kexIk': base64.encode(kexIdentity),
    'confirmed': confirmed,
  };

  static OmemoSession fromJson(Object? json) {
    final map = json as Map;
    final version = OmemoVersion.byName(map['v'] as String?);
    if (version == null) throw const FormatException('unknown version');
    Uint8List bytes(String name) =>
        Uint8List.fromList(base64.decode(map[name] as String));
    return OmemoSession(
      version: version,
      jid: map['jid'] as String,
      deviceId: map['dev'] as int,
      initiation: OmemoInitiation.values.byName(map['init'] as String),
      ratchet: OmemoRatchet.fromJson(version.suite, map['ratchet']),
      associatedData: bytes('ad'),
      peerIdentity: bytes('peer'),
      kexEphemeral: bytes('kexEk'),
      kexPreKeyId: map['kexPk'] as int,
      kexSignedPreKeyId: map['kexSpk'] as int,
      kexIdentity: bytes('kexIk'),
      confirmed: map['confirmed'] as bool? ?? false,
    );
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
