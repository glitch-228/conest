import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// What a sender tells the receiver after leaving a file's encrypted blocks
/// on relays as blobs (`attachment_blobs`): the relays (by route key, the
/// receiver uses only relays it has configured itself), and per block the
/// SHA-256 of the encrypted block (its name on the relay) and of its
/// plaintext (what the block check wants).
class BlobAnnouncement {
  const BlobAnnouncement({
    required this.attachmentId,
    required this.relays,
    required this.blobHashes,
    required this.plainHashes,
  });

  final String attachmentId;
  final List<String> relays;
  final List<String> blobHashes;
  final List<Uint8List> plainHashes;

  static const int maxRelays = 2;
  static const int maxBlocks = 16384;

  Map<String, dynamic> toJson() => {
    'attachmentId': attachmentId,
    'relays': relays,
    'blobs': blobHashes,
    'plain': [for (final hash in plainHashes) base64Encode(hash)],
  };

  /// Parses [json] for a file of [blocks] blocks; null when anything is
  /// out of range (a hostile or broken sender gets nothing taken).
  static BlobAnnouncement? parse(Object? json, {required int blocks}) {
    if (json is! Map) return null;
    final id = json['attachmentId'];
    final relays = json['relays'];
    final blobs = json['blobs'];
    final plain = json['plain'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 160 ||
        relays is! List ||
        relays.isEmpty ||
        relays.length > maxRelays ||
        blobs is! List ||
        plain is! List ||
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
    );
  }
}

/// A blob's name: 64 lowercase hex digits.
bool isBlobHash(String text) =>
    text.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(text);

String blobHashOf(Uint8List encryptedBlock) =>
    crypto.sha256.convert(encryptedBlock).toString();
