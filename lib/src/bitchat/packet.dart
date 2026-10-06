import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// bitchat message types Conest handles.
abstract final class BitchatType {
  static const int announce = 0x01;
  static const int message = 0x02;
  static const int leave = 0x03;
  static const int noiseHandshake = 0x10;
  static const int noiseEncrypted = 0x11;
  static const int fragment = 0x20;
}

abstract final class _Flags {
  static const int hasRecipient = 0x01;
  static const int hasSignature = 0x02;
  static const int isCompressed = 0x04;
  static const int hasRoute = 0x08;
}

/// Hops a fresh bitchat packet may travel.
const int bitchatDefaultTtl = 7;

/// The bitchat packet format (versions 1 and 2): a fixed header, the 8-byte
/// sender id, an optional recipient and source route, the payload and an
/// optional Ed25519 signature; BLE frames may be padded to a block size.
class BitchatPacket {
  const BitchatPacket({
    required this.type,
    required this.senderId,
    required this.timestamp,
    required this.payload,
    this.version = 1,
    this.ttl = bitchatDefaultTtl,
    this.recipientId,
    this.signature,
    this.route,
    this.compressed = false,
  });

  final int version;
  final int type;
  final int ttl;

  /// Milliseconds since the epoch.
  final int timestamp;
  final Uint8List senderId;
  final Uint8List? recipientId;
  final List<Uint8List>? route;

  /// As carried: compressed payloads are not expanded (Conest only relays
  /// them).
  final Uint8List payload;
  final bool compressed;
  final Uint8List? signature;

  static const int _senderBytes = 8;
  static const int _signatureBytes = 64;

  BitchatPacket copyWith({int? ttl, Uint8List? signature}) => BitchatPacket(
    type: type,
    senderId: senderId,
    timestamp: timestamp,
    payload: payload,
    version: version,
    ttl: ttl ?? this.ttl,
    recipientId: recipientId,
    signature: signature ?? this.signature,
    route: route,
    compressed: compressed,
  );

  /// The wire form; [pad] adds bitchat's block padding, which bitchat uses
  /// for Noise packets only (the default).
  Uint8List encode({bool? pad}) {
    if (compressed) {
      throw StateError('Compressed packets are relayed as received.');
    }
    final out = BytesBuilder(copy: false)
      ..addByte(version)
      ..addByte(type)
      ..addByte(ttl)
      ..add(_uint(timestamp, 8));
    var flags = 0;
    if (recipientId != null) flags |= _Flags.hasRecipient;
    if (signature != null) flags |= _Flags.hasSignature;
    final hops = route ?? const <Uint8List>[];
    if (version >= 2 && hops.isNotEmpty) flags |= _Flags.hasRoute;
    out
      ..addByte(flags)
      ..add(_uint(payload.length, version >= 2 ? 4 : 2))
      ..add(_fixed(senderId));
    if (recipientId != null) out.add(_fixed(recipientId!));
    if (version >= 2 && hops.isNotEmpty) {
      out.addByte(hops.length);
      for (final hop in hops) {
        out.add(_fixed(hop));
      }
    }
    out.add(payload);
    if (signature != null) out.add(signature!);
    final raw = out.takeBytes();
    final padded =
        pad ??
        (type == BitchatType.noiseHandshake ||
            type == BitchatType.noiseEncrypted);
    return padded ? bitchatPad(raw) : raw;
  }

  /// What the sender signs: the packet without its signature, with TTL 0
  /// (relays change it), padded as on the wire.
  Uint8List bytesToSign() => BitchatPacket(
    type: type,
    senderId: senderId,
    timestamp: timestamp,
    payload: payload,
    version: version,
    ttl: 0,
    recipientId: recipientId,
    route: route,
  ).encode(pad: true);

  /// Parses a packet, removing padding if needed; null when malformed.
  static BitchatPacket? decode(Uint8List data) =>
      _decode(data) ?? _decode(bitchatUnpad(data));

  static BitchatPacket? _decode(Uint8List raw) {
    if (raw.length < 14 + _senderBytes) return null;
    final view = ByteData.sublistView(raw);
    final version = raw[0];
    if (version != 1 && version != 2) return null;
    final type = raw[1];
    final ttl = raw[2];
    final timestamp = view.getUint64(3);
    final flags = raw[11];
    var offset = 12;
    final int payloadLength;
    if (version >= 2) {
      payloadLength = view.getUint32(offset);
      offset += 4;
    } else {
      payloadLength = view.getUint16(offset);
      offset += 2;
    }
    if (payloadLength > 1024 * 1024) return null;
    Uint8List take(int count) {
      if (offset + count > raw.length) throw const FormatException();
      final part = Uint8List.fromList(raw.sublist(offset, offset + count));
      offset += count;
      return part;
    }

    try {
      final sender = take(_senderBytes);
      final recipient = flags & _Flags.hasRecipient != 0
          ? take(_senderBytes)
          : null;
      List<Uint8List>? route;
      if (version >= 2 && flags & _Flags.hasRoute != 0) {
        final count = take(1)[0];
        route = count == 0 ? null : [for (var i = 0; i < count; i++) take(8)];
      }
      final payload = take(payloadLength);
      final signature = flags & _Flags.hasSignature != 0
          ? take(_signatureBytes)
          : null;
      // Anything left must be padding, which the caller strips first.
      if (offset != raw.length) return null;
      return BitchatPacket(
        version: version,
        type: type,
        ttl: ttl,
        timestamp: timestamp,
        senderId: sender,
        recipientId: recipient,
        route: route,
        payload: payload,
        compressed: flags & _Flags.isCompressed != 0,
        signature: signature,
      );
    } on FormatException {
      return null;
    }
  }

  /// A key for duplicate suppression: the same packet relayed again (with
  /// another TTL or padding) has the same key; a copy with other flags does
  /// not, so it cannot stand in for the original.
  String get dedupKey => sha256.convert([
    version,
    type,
    (recipientId != null ? _Flags.hasRecipient : 0) |
        (signature != null ? _Flags.hasSignature : 0) |
        (compressed ? _Flags.isCompressed : 0) |
        (route?.isNotEmpty ?? false ? _Flags.hasRoute : 0),
    ...senderId,
    ..._uint(timestamp, 8),
    ...?recipientId,
    ...payload,
  ]).toString();

  static Uint8List _fixed(Uint8List id) {
    final out = Uint8List(_senderBytes);
    out.setRange(0, id.length.clamp(0, _senderBytes), id);
    return out;
  }

  static List<int> _uint(int value, int bytes) => [
    for (var shift = (bytes - 1) * 8; shift >= 0; shift -= 8)
      (value >> shift) & 0xff,
  ];
}

/// Pads to bitchat's next block size (256, 512, 1024, 2048) when the
/// padding fits in a byte; every padding byte holds its length.
Uint8List bitchatPad(Uint8List data) {
  const blocks = [256, 512, 1024, 2048];
  final target = blocks.firstWhere(
    (block) => data.length + 16 <= block,
    orElse: () => data.length,
  );
  final needed = target - data.length;
  if (needed <= 0 || needed > 255) return data;
  return Uint8List(target)
    ..setRange(0, data.length, data)
    ..fillRange(data.length, target, needed);
}

Uint8List bitchatUnpad(Uint8List data) {
  if (data.isEmpty) return data;
  final length = data.last;
  if (length == 0 || length > data.length) return data;
  for (var index = data.length - length; index < data.length; index++) {
    if (data[index] != length) return data;
  }
  return Uint8List.sublistView(data, 0, data.length - length);
}

/// A bitchat identity announcement: TLVs for nickname, Noise static key and
/// Ed25519 signing key.
class BitchatAnnouncement {
  const BitchatAnnouncement({
    required this.nickname,
    required this.noisePublicKey,
    required this.signingPublicKey,
  });

  final String nickname;
  final Uint8List noisePublicKey;
  final Uint8List signingPublicKey;

  Uint8List encode() {
    final name = utf8.encode(nickname);
    if (name.length > 255) throw ArgumentError('Nickname is too long.');
    return Uint8List.fromList([
      0x01, name.length, ...name, //
      0x02, noisePublicKey.length, ...noisePublicKey,
      0x03, signingPublicKey.length, ...signingPublicKey,
    ]);
  }

  static BitchatAnnouncement? decode(Uint8List data) {
    String? nickname;
    Uint8List? noise;
    Uint8List? signing;
    var offset = 0;
    while (offset + 2 <= data.length) {
      final type = data[offset];
      final length = data[offset + 1];
      offset += 2;
      if (offset + length > data.length) return null;
      final value = Uint8List.sublistView(data, offset, offset + length);
      offset += length;
      switch (type) {
        case 0x01:
          nickname = utf8.decode(value, allowMalformed: true);
        case 0x02:
          noise = Uint8List.fromList(value);
        case 0x03:
          signing = Uint8List.fromList(value);
      }
    }
    if (nickname == null || noise == null || signing == null) return null;
    return BitchatAnnouncement(
      nickname: nickname,
      noisePublicKey: noise,
      signingPublicKey: signing,
    );
  }
}

/// A peer's id: the first 8 bytes of the SHA-256 of its Noise static key.
Uint8List bitchatPeerId(List<int> noisePublicKey) =>
    Uint8List.fromList(sha256.convert(noisePublicKey).bytes.sublist(0, 8));
