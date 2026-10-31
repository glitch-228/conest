import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../models.dart' show PeerEndpoint;

/// What a sender tells the receiver after leaving a file's encrypted blocks
/// on relays as blobs (`attachment_blobs`): the relays (by route key, the
/// receiver uses only relays it has configured itself), and per block the
/// SHA-256 of the encrypted block (its name on the relay) and of its
/// plaintext (what the block check wants). [readSecret] is what the relays
/// want to see before they serve a blob; only the receiver learns it (this
/// announcement is end-to-end encrypted), so a hash alone reads nothing.
class BlobAnnouncement {
  const BlobAnnouncement({
    required this.attachmentId,
    required this.relays,
    required this.blobHashes,
    required this.plainHashes,
    required this.readSecret,
  });

  final String attachmentId;
  final List<String> relays;
  final List<String> blobHashes;
  final List<Uint8List> plainHashes;
  final String readSecret;

  static const int maxRelays = 2;
  static const int maxBlocks = 16384;

  Map<String, dynamic> toJson() => {
    'attachmentId': attachmentId,
    'relays': relays,
    'blobs': blobHashes,
    'plain': [for (final hash in plainHashes) base64Encode(hash)],
    'secret': readSecret,
  };

  /// Parses [json] for a file of [blocks] blocks; null when anything is
  /// out of range (a hostile or broken sender gets nothing taken).
  static BlobAnnouncement? parse(Object? json, {required int blocks}) {
    if (json is! Map) return null;
    final id = json['attachmentId'];
    final relays = json['relays'];
    final blobs = json['blobs'];
    final plain = json['plain'];
    final secret = json['secret'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 160 ||
        relays is! List ||
        relays.isEmpty ||
        relays.length > maxRelays ||
        blobs is! List ||
        plain is! List ||
        !isReadSecret(secret) ||
        blocks <= 0 ||
        blocks > maxBlocks ||
        blobs.length != blocks ||
        plain.length != blocks) {
      return null;
    }
    final relayKeys = <String>[];
    for (final relay in relays) {
      if (relay is! String || relay.isEmpty || relay.length > 300) return null;
      relayKeys.add(relay);
    }
    final blobHashes = <String>[];
    for (final blob in blobs) {
      if (blob is! String || !isBlobHash(blob)) return null;
      blobHashes.add(blob);
    }
    final plainHashes = <Uint8List>[];
    for (final entry in plain) {
      if (entry is! String || entry.length > 64) return null;
      final Uint8List bytes;
      try {
        bytes = base64Decode(entry);
      } on FormatException {
        return null;
      }
      if (bytes.length != 32) return null;
      plainHashes.add(bytes);
    }
    return BlobAnnouncement(
      attachmentId: id,
      relays: relayKeys,
      blobHashes: blobHashes,
      plainHashes: plainHashes,
      readSecret: secret as String,
    );
  }
}

/// A blob's name: 64 lowercase hex digits.
bool isBlobHash(String text) =>
    text.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(text);

String blobHashOf(Uint8List encryptedBlock) =>
    crypto.sha256.convert(encryptedBlock).toString();

/// A blob read secret: 16 to 128 printable ASCII characters.
bool isReadSecret(Object? text) =>
    text is String &&
    text.length >= 16 &&
    text.length <= 128 &&
    RegExp(r'^[\x21-\x7e]+$').hasMatch(text);

/// A fresh random read secret (256 bits, URL-safe).
String newReadSecret([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = Uint8List.fromList([
    for (var i = 0; i < 32; i++) source.nextInt(256),
  ]);
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Where a sender left blobs for one file, so it can take them back when
/// the file is done another way or the receiver declines. [uploads] are
/// (relay route key, blob hash) pairs, as many as were tried.
class LeftBlobs {
  LeftBlobs({required this.peerDeviceId, required this.relays});

  final String peerDeviceId;

  /// Relay route key -> (endpoint, pinned identity key).
  final Map<String, ({PeerEndpoint endpoint, String key})> relays;
  final Map<String, Set<String>> uploads = {};

  void note(String routeKey, String hash) =>
      (uploads[routeKey] ??= <String>{}).add(hash);
}
