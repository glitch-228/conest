import 'dart:math';
import 'dart:typed_data';

import 'identity.dart';

/// Reticulum packet types.
abstract final class RnsPacketType {
  static const int data = 0;
  static const int announce = 1;
  static const int linkRequest = 2;
  static const int proof = 3;
}

/// Reticulum destination types.
abstract final class RnsDestinationType {
  static const int single = 0;
  static const int group = 1;
  static const int plain = 2;
  static const int link = 3;
}

/// Reticulum packet contexts Conest uses.
abstract final class RnsContext {
  static const int none = 0x00;
  static const int pathResponse = 0x0b;
}

/// Largest packet on a Reticulum interface.
const int rnsMtu = 500;

/// Largest plaintext one encrypted packet to a SINGLE destination carries.
const int rnsEncryptedMdu = 383;

/// One Reticulum packet (HEADER_1, or HEADER_2 with a transport id).
class RnsPacket {
  const RnsPacket({
    required this.packetType,
    required this.destinationType,
    required this.destinationHash,
    required this.data,
    this.context = RnsContext.none,
    this.contextFlag = false,
    this.hops = 0,
    this.transportId,
  });

  final int packetType;
  final int destinationType;
  final Uint8List destinationHash;
  final Uint8List data;
  final int context;
  final bool contextFlag;
  final int hops;

  /// The next hop's identity hash, for packets sent through a transport
  /// node (HEADER_2).
  final Uint8List? transportId;

  int get _flags =>
      ((transportId == null ? 0 : 1) << 6) |
      ((contextFlag ? 1 : 0) << 5) |
      ((transportId == null ? 0 : 1) << 4) |
      (destinationType << 2) |
      packetType;

  Uint8List pack() {
    final raw = Uint8List.fromList([
      _flags,
      hops,
      ...?transportId,
      ...destinationHash,
      context,
      ...data,
    ]);
    if (raw.length > rnsMtu) {
      throw ArgumentError('Reticulum packet exceeds the MTU.');
    }
    return raw;
  }

  /// Parses a packet; null when it is malformed.
  static RnsPacket? unpack(Uint8List raw) {
    if (raw.length < 2 + rnsTruncatedHashBytes + 1 + 1 || raw.length > rnsMtu) {
      return null;
    }
    final flags = raw[0];
    final headerType = (flags >> 6) & 1;
    final hops = raw[1];
    if (hops >= 128) return null;
    var offset = 2;
    Uint8List? transportId;
    if (headerType == 1) {
      if (raw.length < 2 + 2 * rnsTruncatedHashBytes + 2) return null;
      transportId = Uint8List.fromList(
        raw.sublist(offset, offset + rnsTruncatedHashBytes),
      );
      offset += rnsTruncatedHashBytes;
    }
    final destination = Uint8List.fromList(
      raw.sublist(offset, offset + rnsTruncatedHashBytes),
    );
    offset += rnsTruncatedHashBytes;
    final context = raw[offset++];
    return RnsPacket(
      packetType: flags & 3,
      destinationType: (flags >> 2) & 3,
      destinationHash: destination,
      data: Uint8List.fromList(raw.sublist(offset)),
      context: context,
      contextFlag: (flags >> 5) & 1 == 1,
      hops: hops,
      transportId: transportId,
    );
  }

  /// The packet hash Reticulum deduplicates and proves by: everything but
  /// the hop count and transport id.
  Uint8List get hash =>
      rnsFullHash([_flags & 0x0f, ...destinationHash, context, ...data]);
}

/// A validated announce.
class RnsAnnounce {
  const RnsAnnounce({
    required this.destinationHash,
    required this.identity,
    required this.nameHash,
    required this.appData,
    required this.hops,
    required this.emittedAt,
    this.transportId,
  });

  final Uint8List destinationHash;
  final RnsIdentity identity;
  final Uint8List nameHash;
  final Uint8List appData;
  final int hops;
  final Uint8List? transportId;

  /// When the announce was made, in seconds: the last five bytes of its
  /// random hash.
  final int emittedAt;

  /// Builds the announce packet for [identity]'s destination [nameHash].
  static Future<RnsPacket> build(
    RnsIdentity identity,
    Uint8List nameHash, {
    List<int> appData = const [],
    required int timeSeconds,
    List<int>? random,
    bool pathResponse = false,
  }) async {
    final destination = rnsDestinationHash(nameHash, identity.hash);
    final randomHash = [
      ...(random ?? List<int>.generate(5, (_) => Random.secure().nextInt(256))),
      for (var shift = 32; shift >= 0; shift -= 8)
        (timeSeconds >> shift) & 0xff,
    ];
    final signed = [
      ...destination,
      ...identity.publicKey,
      ...nameHash,
      ...randomHash,
      ...appData,
    ];
    final signature = await identity.sign(signed);
    return RnsPacket(
      packetType: RnsPacketType.announce,
      destinationType: RnsDestinationType.single,
      destinationHash: destination,
      context: pathResponse ? RnsContext.pathResponse : RnsContext.none,
      data: Uint8List.fromList([
        ...identity.publicKey,
        ...nameHash,
        ...randomHash,
        ...signature,
        ...appData,
      ]),
    );
  }

  /// Checks an announce's signature and that its destination hash belongs
  /// to the announced key; null when either fails.
  static Future<RnsAnnounce?> validate(RnsPacket packet) async {
    if (packet.packetType != RnsPacketType.announce) return null;
    final data = packet.data;
    final ratchetBytes = packet.contextFlag ? 32 : 0;
    const fixed = 64 + rnsNameHashBytes + 10;
    if (data.length < fixed + ratchetBytes + 64) return null;
    final publicKey = data.sublist(0, 64);
    final nameHash = data.sublist(64, 64 + rnsNameHashBytes);
    final randomHash = data.sublist(64 + rnsNameHashBytes, fixed);
    final ratchet = data.sublist(fixed, fixed + ratchetBytes);
    final signature = data.sublist(
      fixed + ratchetBytes,
      fixed + ratchetBytes + 64,
    );
    final appData = data.sublist(fixed + ratchetBytes + 64);
    final identity = RnsIdentity.fromPublicKey(publicKey)!;
    final expected = rnsDestinationHash(nameHash, identity.hash);
    if (!_equal(expected, packet.destinationHash)) return null;
    final valid = await identity.verify([
      ...packet.destinationHash,
      ...publicKey,
      ...nameHash,
      ...randomHash,
      ...ratchet,
      ...appData,
    ], signature);
    if (!valid) return null;
    return RnsAnnounce(
      destinationHash: packet.destinationHash,
      identity: identity,
      nameHash: nameHash,
      appData: appData,
      hops: packet.hops,
      transportId: packet.transportId,
      emittedAt: randomHash
          .sublist(5)
          .fold<int>(0, (value, byte) => (value << 8) | byte),
    );
  }
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
