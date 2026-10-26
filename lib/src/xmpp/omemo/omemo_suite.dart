import 'dart:convert';
import 'dart:typed_data';

import 'omemo_proto.dart';
import 'xeddsa.dart';

/// The two OMEMO versions, which differ in encodings and labels but share
/// X3DH and the Double Ratchet: legacy OMEMO (`eu.siacs.conversations.axolotl`,
/// the libsignal wire format) and OMEMO 2 (`urn:xmpp:omemo:2`).
///
/// Persisted by name: never rename or reorder.
enum OmemoVersion {
  legacy('eu.siacs.conversations.axolotl'),
  v2('urn:xmpp:omemo:2');

  const OmemoVersion(this.namespace);
  final String namespace;

  OmemoSuite get suite => this == legacy ? legacyOmemoSuite : omemo2Suite;

  static OmemoVersion? byName(String? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static OmemoVersion? byNamespace(String? namespace) {
    for (final value in values) {
      if (value.namespace == namespace) return value;
    }
    return null;
  }
}

/// A parsed Double Ratchet message: its header and the sealed bytes.
class OmemoRatchetMessage {
  const OmemoRatchetMessage({
    required this.ratchetPub,
    required this.counter,
    required this.previousCounter,
    required this.sealed,
  });

  /// The sender's current ratchet public key (raw X25519).
  final Uint8List ratchetPub;
  final int counter;
  final int previousCounter;

  /// The whole authenticated message as it travels (including the MAC).
  final Uint8List sealed;
}

/// A key exchange header sent with the first messages of a session.
class OmemoKeyExchange {
  const OmemoKeyExchange({
    required this.preKeyId,
    required this.signedPreKeyId,
    required this.identityKey,
    required this.ephemeralKey,
    required this.message,
  });

  final int preKeyId;
  final int signedPreKeyId;

  /// Raw Curve25519 key (legacy) or Ed25519 key (OMEMO 2) of the initiator.
  final Uint8List identityKey;

  /// Raw X25519 public key.
  final Uint8List ephemeralKey;

  /// The ratchet message that goes with it.
  final Uint8List message;
}

abstract class OmemoSuite {
  const OmemoSuite();

  OmemoVersion get version;

  /// HKDF info of the X3DH secret.
  List<int> get x3dhInfo;

  /// HKDF info of the root chain.
  List<int> get rootInfo;

  /// HKDF info of the per-message keys.
  List<int> get messageKeyInfo;

  /// Bytes of the truncated MAC on ratchet messages.
  int get macLength;

  /// Bytes of one identity key in the associated data.
  int get identityLength;

  /// The bytes of an identity key in the associated data, from its
  /// Montgomery (Curve25519) form and, for OMEMO 2, its Ed25519 form.
  Uint8List associatedIdentity(Uint8List montgomery, Uint8List? edwards);

  /// Whether the two parties' associated data swap with the direction.
  bool get directional;

  /// Bytes of the symmetric key sent to each device.
  int get payloadKeyLength;

  /// Bytes of the authentication value sent after the key.
  int get payloadTagLength;

  /// Encodes/decodes the public keys inside ratchet messages and bundles.
  Uint8List encodePublic(Uint8List raw);
  Uint8List decodePublic(Uint8List encoded);

  /// The header part of a ratchet message (what the associated data of the
  /// reference libraries holds).
  Uint8List encodeMessage(
    Uint8List ratchetPub,
    int counter,
    int previousCounter,
    Uint8List? ciphertext,
  );

  /// The bytes the MAC covers after the associated data, and the sealed form.
  Uint8List sealMessage(Uint8List messageBytes, Uint8List mac);

  /// Splits a sealed message into (message bytes, mac). Throws
  /// [OmemoProtoException].
  (Uint8List, Uint8List) openSealed(Uint8List sealed);

  /// Parses message bytes: (ratchet pub, counter, previous counter,
  /// ciphertext).
  (Uint8List, int, int, Uint8List) parseMessage(Uint8List messageBytes);

  Uint8List encodeKeyExchange(OmemoKeyExchange kex);
  OmemoKeyExchange parseKeyExchange(Uint8List bytes);
}

class _LegacySuite extends OmemoSuite {
  const _LegacySuite();

  @override
  OmemoVersion get version => OmemoVersion.legacy;
  @override
  List<int> get x3dhInfo => ascii.encode('WhisperText');
  @override
  List<int> get rootInfo => ascii.encode('WhisperRatchet');
  @override
  List<int> get messageKeyInfo => ascii.encode('WhisperMessageKeys');
  @override
  int get macLength => 8;
  @override
  int get identityLength => 33;
  @override
  bool get directional => true;
  @override
  int get payloadKeyLength => 16;
  @override
  int get payloadTagLength => 16;

  @override
  Uint8List associatedIdentity(Uint8List montgomery, Uint8List? edwards) =>
      encodePublic(montgomery);

  @override
  Uint8List encodePublic(Uint8List raw) => Uint8List.fromList([0x05, ...raw]);

  @override
  Uint8List decodePublic(Uint8List encoded) {
    if (encoded.length != 33 || encoded[0] != 0x05) {
      throw const OmemoProtoException('public key not in network format');
    }
    return Uint8List.sublistView(encoded, 1);
  }

  @override
  Uint8List encodeMessage(
    Uint8List ratchetPub,
    int counter,
    int previousCounter,
    Uint8List? ciphertext,
  ) {
    final writer = ProtoWriter()
      ..bytes(1, encodePublic(ratchetPub))
      ..uint(2, counter)
      ..uint(3, previousCounter);
    if (ciphertext != null) writer.bytes(4, ciphertext);
    return Uint8List.fromList([0x33, ...writer.toBytes()]);
  }

  @override
  Uint8List sealMessage(Uint8List messageBytes, Uint8List mac) =>
      Uint8List.fromList([...messageBytes, ...mac]);

  @override
  (Uint8List, Uint8List) openSealed(Uint8List sealed) {
    if (sealed.length <= macLength + 1) {
      throw const OmemoProtoException('message too short');
    }
    final split = sealed.length - macLength;
    return (
      Uint8List.sublistView(sealed, 0, split),
      Uint8List.sublistView(sealed, split),
    );
  }

  @override
  (Uint8List, int, int, Uint8List) parseMessage(Uint8List messageBytes) {
    if (messageBytes.isEmpty || messageBytes[0] != 0x33) {
      throw const OmemoProtoException('version byte missing');
    }
    final reader = ProtoReader.parse(Uint8List.sublistView(messageBytes, 1));
    return (
      decodePublic(reader.requiredBytes(1)),
      reader.requiredUint(2),
      reader.requiredUint(3),
      reader.optionalBytes(4) ?? Uint8List(0),
    );
  }

  @override
  Uint8List encodeKeyExchange(OmemoKeyExchange kex) {
    final writer = ProtoWriter()
      ..uint(1, kex.preKeyId)
      ..bytes(2, encodePublic(kex.ephemeralKey))
      ..bytes(3, encodePublic(kex.identityKey))
      ..bytes(4, kex.message)
      ..uint(6, kex.signedPreKeyId);
    return Uint8List.fromList([0x33, ...writer.toBytes()]);
  }

  @override
  OmemoKeyExchange parseKeyExchange(Uint8List bytes) {
    if (bytes.isEmpty || bytes[0] != 0x33) {
      throw const OmemoProtoException('version byte missing');
    }
    final reader = ProtoReader.parse(Uint8List.sublistView(bytes, 1));
    return OmemoKeyExchange(
      preKeyId: reader.requiredUint(1),
      signedPreKeyId: reader.requiredUint(6),
      identityKey: decodePublic(reader.requiredBytes(3)),
      ephemeralKey: decodePublic(reader.requiredBytes(2)),
      message: reader.requiredBytes(4),
    );
  }
}

class _Omemo2Suite extends OmemoSuite {
  const _Omemo2Suite();

  @override
  OmemoVersion get version => OmemoVersion.v2;
  @override
  List<int> get x3dhInfo => ascii.encode('OMEMO X3DH');
  @override
  List<int> get rootInfo => ascii.encode('OMEMO Root Chain');
  @override
  List<int> get messageKeyInfo => ascii.encode('OMEMO Message Key Material');
  @override
  int get macLength => 16;
  @override
  int get identityLength => 32;
  @override
  bool get directional => false;
  @override
  int get payloadKeyLength => 32;
  @override
  int get payloadTagLength => 16;

  @override
  Uint8List associatedIdentity(Uint8List montgomery, Uint8List? edwards) {
    if (edwards == null) {
      throw ArgumentError('OMEMO 2 needs the Ed25519 identity key.');
    }
    return edwards;
  }

  @override
  Uint8List encodePublic(Uint8List raw) => raw;

  @override
  Uint8List decodePublic(Uint8List encoded) {
    if (encoded.length != 32) {
      throw const OmemoProtoException('public key has the wrong size');
    }
    return encoded;
  }

  @override
  Uint8List encodeMessage(
    Uint8List ratchetPub,
    int counter,
    int previousCounter,
    Uint8List? ciphertext,
  ) {
    final writer = ProtoWriter()
      ..uint(1, counter)
      ..uint(2, previousCounter)
      ..bytes(3, ratchetPub);
    if (ciphertext != null) writer.bytes(4, ciphertext);
    return writer.toBytes();
  }

  @override
  Uint8List sealMessage(Uint8List messageBytes, Uint8List mac) {
    // OMEMOAuthenticatedMessage { mac = 1; message = 2 }
    return (ProtoWriter()
          ..bytes(1, mac)
          ..bytes(2, messageBytes))
        .toBytes();
  }

  @override
  (Uint8List, Uint8List) openSealed(Uint8List sealed) {
    final reader = ProtoReader.parse(sealed);
    return (reader.requiredBytes(2), reader.requiredBytes(1));
  }

  @override
  (Uint8List, int, int, Uint8List) parseMessage(Uint8List messageBytes) {
    final reader = ProtoReader.parse(messageBytes);
    return (
      decodePublic(reader.requiredBytes(3)),
      reader.requiredUint(1),
      reader.requiredUint(2),
      reader.optionalBytes(4) ?? Uint8List(0),
    );
  }

  @override
  Uint8List encodeKeyExchange(OmemoKeyExchange kex) =>
      (ProtoWriter()
            ..uint(1, kex.preKeyId)
            ..uint(2, kex.signedPreKeyId)
            ..bytes(3, kex.identityKey)
            ..bytes(4, kex.ephemeralKey)
            ..bytes(5, kex.message))
          .toBytes();

  @override
  OmemoKeyExchange parseKeyExchange(Uint8List bytes) {
    final reader = ProtoReader.parse(bytes);
    return OmemoKeyExchange(
      preKeyId: reader.requiredUint(1),
      signedPreKeyId: reader.requiredUint(2),
      identityKey: decodePublic(reader.requiredBytes(3)),
      ephemeralKey: decodePublic(reader.requiredBytes(4)),
      message: reader.requiredBytes(5),
    );
  }
}

const OmemoSuite legacyOmemoSuite = _LegacySuite();
const OmemoSuite omemo2Suite = _Omemo2Suite();

/// The Curve25519 form of an Ed25519 identity key, or null when invalid.
Uint8List? omemoMontgomery(Uint8List edwards) => edwardsToMontgomery(edwards);
