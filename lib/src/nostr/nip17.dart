import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'event.dart';
import 'nip44.dart';
import 'secp256k1.dart';

/// NIP-17 kinds and NIP-59 layers.
abstract final class Nip17Kind {
  /// The message itself (unsigned, a "rumor").
  static const int chatMessage = 14;

  /// A file message (shown as a note: Conest does not fetch it).
  static const int fileMessage = 15;

  /// The rumor encrypted to one recipient and signed by the author.
  static const int seal = 13;

  /// A user's relays for receiving direct messages.
  static const int dmRelays = 10050;
}

/// A NIP-17 private message, as read from a gift wrap.
class NostrDirectMessage {
  const NostrDirectMessage({
    required this.id,
    required this.author,
    required this.recipients,
    required this.content,
    required this.createdAt,
    this.subject,
    this.replyTo,
  });

  /// The rumor's id: the same for every recipient's copy.
  final String id;

  /// The author's public key (hex), checked against the seal's signature.
  final String author;

  /// Public keys in the rumor's `p` tags: everyone the author wrote to.
  final List<String> recipients;
  final String content;
  final int createdAt;

  /// The conversation's title, when the author set one.
  final String? subject;

  /// The id of the message this one answers, if any.
  final String? replyTo;

  /// Everyone in the conversation: the author and the recipients.
  Set<String> get participants => {author, ...recipients};
}

/// Writing and reading NIP-17 private messages: an unsigned kind-14 rumor,
/// sealed (kind 13, NIP-44 to each recipient, signed by the author), then
/// gift wrapped (kind 1059, NIP-44 again, signed by a throwaway key) so
/// relays see neither the author nor the time it was written.
abstract final class Nip17 {
  /// Seals and wraps are dated up to this long before now.
  static const Duration timestampJitter = Duration(days: 2);

  /// One gift wrap for each recipient and one for the author (to read
  /// their own messages on other devices), with the recipient's key in
  /// its `p` tag: (recipient, wrap).
  static List<(String, NostrEvent)> wrap({
    required Uint8List secretKey,
    required List<String> recipients,
    required String content,
    required DateTime now,
    String? subject,
    String? replyTo,
    Random? random,
  }) {
    final source = random ?? Random.secure();
    final author = hexEncode(Secp256k1.publicKey(secretKey));
    final createdAt = now.millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      for (final recipient in recipients) ['p', recipient],
      if (subject != null) ['subject', subject],
      if (replyTo != null) ['e', replyTo],
    ];
    final rumorId = NostrEvent.eventId(
      pubkey: author,
      createdAt: createdAt,
      kind: Nip17Kind.chatMessage,
      tags: tags,
      content: content,
    );
    final rumor = jsonEncode({
      'id': rumorId,
      'pubkey': author,
      'created_at': createdAt,
      'kind': Nip17Kind.chatMessage,
      'tags': tags,
      'content': content,
    });
    int jittered() => createdAt - source.nextInt(timestampJitter.inSeconds + 1);
    return [
      for (final recipient in {...recipients, author})
        () {
          final recipientKey = hexDecode(recipient)!;
          final seal = NostrEvent.sign(
            secretKey: secretKey,
            kind: Nip17Kind.seal,
            tags: const [],
            content: Nip44.encrypt(
              Uint8List.fromList(utf8.encode(rumor)),
              Nip44.conversationKey(secretKey, recipientKey),
            ),
            createdAt: jittered(),
          );
          final ephemeral = Secp256k1.generateSecretKey();
          final wrap = NostrEvent.sign(
            secretKey: ephemeral,
            kind: NostrKind.giftWrap,
            tags: [
              ['p', recipient],
            ],
            content: Nip44.encrypt(
              Uint8List.fromList(utf8.encode(jsonEncode(seal.toJson()))),
              Nip44.conversationKey(ephemeral, recipientKey),
            ),
            createdAt: jittered(),
          );
          return (recipient, wrap);
        }(),
    ];
  }

  /// The message in [wrap], addressed to [secretKey]'s owner; null when it
  /// is not a NIP-17 message for them, or does not check out (the seal's
  /// signature, and the rumor's author being the seal's signer).
  static NostrDirectMessage? unwrap(NostrEvent wrap, Uint8List secretKey) {
    if (wrap.kind != NostrKind.giftWrap) return null;
    try {
      final sealJson = jsonDecode(
        utf8.decode(
          Nip44.decrypt(
            wrap.content,
            Nip44.conversationKey(secretKey, hexDecode(wrap.pubkey)!),
          ),
        ),
      );
      final seal = NostrEvent.fromJson(sealJson);
      if (seal == null || seal.kind != Nip17Kind.seal || !seal.isValid) {
        return null;
      }
      final rumor = jsonDecode(
        utf8.decode(
          Nip44.decrypt(
            seal.content,
            Nip44.conversationKey(secretKey, hexDecode(seal.pubkey)!),
          ),
        ),
      );
      if (rumor is! Map<String, dynamic>) return null;
      final pubkey = rumor['pubkey'];
      final createdAt = rumor['created_at'];
      final kind = rumor['kind'];
      final tags = rumor['tags'];
      final content = rumor['content'];
      // Only the seal's signer can be the author: otherwise anyone could
      // put words in someone else's mouth.
      if (pubkey != seal.pubkey ||
          createdAt is! int ||
          createdAt < 0 ||
          createdAt > 100000000000 ||
          (kind != Nip17Kind.chatMessage && kind != Nip17Kind.fileMessage) ||
          tags is! List ||
          content is! String) {
        return null;
      }
      final parsedTags = <List<String>>[
        for (final tag in tags)
          if (tag is List && tag.every((value) => value is String))
            tag.cast<String>(),
      ];
      String? first(String name) => parsedTags
          .where((tag) => tag.length >= 2 && tag[0] == name)
          .map((tag) => tag[1])
          .firstOrNull;
      final id = NostrEvent.eventId(
        pubkey: seal.pubkey,
        createdAt: createdAt,
        kind: kind as int,
        tags: parsedTags,
        content: content,
      );
      return NostrDirectMessage(
        id: id,
        author: seal.pubkey,
        recipients: [
          for (final tag in parsedTags)
            if (tag.length >= 2 &&
                tag[0] == 'p' &&
                RegExp(r'^[0-9a-f]{64}$').hasMatch(tag[1]))
              tag[1],
        ],
        // A file is only named: its link and key stay out of the chat.
        content: kind == Nip17Kind.fileMessage
            ? '[A file (${first('file-type') ?? 'unknown type'}): open it in '
                  'the app that sent it]'
            : content,
        createdAt: createdAt,
        subject: first('subject'),
        replyTo: first('e'),
      );
    } catch (_) {
      return null;
    }
  }

  /// A kind-10050 list of the relays where [secretKey]'s owner reads
  /// direct messages.
  static NostrEvent dmRelayList(
    Uint8List secretKey,
    List<Uri> relays,
    DateTime now,
  ) => NostrEvent.sign(
    secretKey: secretKey,
    kind: Nip17Kind.dmRelays,
    tags: [
      for (final relay in relays) ['relay', relay.toString()],
    ],
    content: '',
    createdAt: now.millisecondsSinceEpoch ~/ 1000,
  );

  /// The relays in a kind-10050 list (wss only), when it is valid.
  static List<Uri> relaysFrom(NostrEvent list) {
    if (list.kind != Nip17Kind.dmRelays || !list.isValid) return const [];
    return [
      for (final tag in list.tags)
        if (tag.length >= 2 && tag[0] == 'relay')
          if (Uri.tryParse(tag[1]) case final uri?
              when uri.scheme == 'wss' && uri.host.isNotEmpty)
            uri,
    ].take(8).toList();
  }
}
