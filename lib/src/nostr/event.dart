import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'secp256k1.dart';

/// A signed Nostr event (NIP-01).
class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// Builds and signs an event with [secretKey].
  factory NostrEvent.sign({
    required Uint8List secretKey,
    required int kind,
    required List<List<String>> tags,
    required String content,
    required int createdAt,
  }) {
    final pubkey = hexEncode(Secp256k1.publicKey(secretKey));
    final id = eventId(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: hexEncode(Secp256k1.sign(hexDecode(id)!, secretKey)),
    );
  }

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  /// The sha256 of the event's canonical serialization, as hex.
  static String eventId({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) => sha256
      .convert(
        utf8.encode(jsonEncode([0, pubkey, createdAt, kind, tags, content])),
      )
      .toString();

  /// The first value of tag [name], if any.
  String? tag(String name) => tags
      .where((tag) => tag.length >= 2 && tag[0] == name)
      .map((tag) => tag[1])
      .firstOrNull;

  /// Whether the id matches the content and the signature is valid.
  bool get isValid {
    final pub = hexDecode(pubkey);
    final idBytes = hexDecode(id);
    final signature = hexDecode(sig);
    if (pub == null ||
        pub.length != 32 ||
        idBytes == null ||
        idBytes.length != 32 ||
        signature == null ||
        signature.length != 64) {
      return false;
    }
    if (eventId(
          pubkey: pubkey,
          createdAt: createdAt,
          kind: kind,
          tags: tags,
          content: content,
        ) !=
        id) {
      return false;
    }
    return Secp256k1.verify(idBytes, pub, signature);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  /// Parses an event; null when a field is missing or of the wrong type.
  static NostrEvent? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final pubkey = json['pubkey'];
    final createdAt = json['created_at'];
    final kind = json['kind'];
    final tags = json['tags'];
    final content = json['content'];
    final sig = json['sig'];
    if (id is! String ||
        pubkey is! String ||
        createdAt is! int ||
        kind is! int ||
        tags is! List ||
        content is! String ||
        sig is! String) {
      return null;
    }
    final parsedTags = <List<String>>[];
    for (final tag in tags) {
      if (tag is! List || tag.any((value) => value is! String)) return null;
      parsedTags.add(tag.cast<String>().toList(growable: false));
    }
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: parsedTags,
      content: content,
      sig: sig,
    );
  }
}

/// Nostr event kinds Conest uses.
abstract final class NostrKind {
  /// A gift wrap (NIP-59): relays that follow NIP-17 serve it only to the
  /// key it is addressed to.
  static const int giftWrap = 1059;

  /// Client authentication to a relay (NIP-42).
  static const int clientAuth = 22242;
}
