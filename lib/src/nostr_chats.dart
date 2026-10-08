/// Nostr private chats (NIP-17): one chat per set of people, kept on this
/// device only.
library;

import 'dart:math';

class NostrChatMessage {
  const NostrChatMessage({
    required this.id,
    required this.author,
    required this.text,
    required this.at,
    required this.outgoing,
  });

  /// The rumor id, the same for every copy.
  final String id;

  /// The author's public key (hex).
  final String author;
  final String text;
  final DateTime at;
  final bool outgoing;

  Map<String, dynamic> toJson() => {
    'id': id,
    'author': author,
    'text': text,
    'at': at.toUtc().toIso8601String(),
    if (outgoing) 'outgoing': true,
  };

  static NostrChatMessage? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final author = json['author'];
    final text = json['text'];
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (id is! String || author is! String || text is! String || at == null) {
      return null;
    }
    return NostrChatMessage(
      id: id,
      author: author,
      text: text,
      at: at.toUtc(),
      outgoing: json['outgoing'] == true,
    );
  }
}

class NostrChat {
  const NostrChat({
    required this.people,
    this.subject,
    this.messages = const [],
    this.unread = 0,
    this.kept = false,
  });

  /// Everyone in the chat except this account (public keys, hex, sorted).
  final List<String> people;

  /// The title someone gave the chat, if any.
  final String? subject;

  /// Oldest first.
  final List<NostrChatMessage> messages;
  final int unread;

  /// The user started, opened or wrote in it: never pushed out by others.
  /// Until then it is a request from strangers, with smaller limits.
  final bool kept;

  /// The chat's key: its people, sorted.
  String get key => people.join(',');
  bool get isGroup => people.length > 1;

  NostrChat copyWith({
    String? subject,
    List<NostrChatMessage>? messages,
    int? unread,
    bool? kept,
  }) => NostrChat(
    people: people,
    subject: subject ?? this.subject,
    messages: messages ?? this.messages,
    unread: unread ?? this.unread,
    kept: kept ?? this.kept,
  );

  Map<String, dynamic> toJson() => {
    'people': people,
    if (subject != null) 'subject': subject,
    'messages': [for (final message in messages) message.toJson()],
    if (unread > 0) 'unread': unread,
    if (kept) 'kept': true,
  };

  static NostrChat? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final people = json['people'];
    if (people is! List || people.isEmpty) return null;
    return NostrChat(
      people: [
        for (final person in people)
          if (person is String) person,
      ]..sort(),
      subject: json['subject'] as String?,
      messages: [
        for (final message in json['messages'] as List? ?? const [])
          ?NostrChatMessage.fromJson(message),
      ],
      unread: json['unread'] as int? ?? 0,
      kept: json['kept'] == true,
    );
  }
}

/// All Nostr private chats, and names given to people. Replaced, never
/// changed in place.
class NostrChats {
  const NostrChats({
    this.chats = const {},
    this.names = const {},
    this.deleted = const {},
    this.hints = const {},
  });

  static const int maxMessagesPerChat = 500;

  /// Chats the user has not opened (strangers writing): fewer, shorter,
  /// and the oldest go first; the user's own chats never do.
  static const int maxRequests = 50;
  static const int maxMessagesPerRequest = 50;
  static const int maxPeople = 20;
  static const int maxDeleted = 500;

  final Map<String, NostrChat> chats;

  /// Names the user gave to public keys.
  final Map<String, String> names;

  /// Chats deleted, by key, with when: their older messages, read again
  /// from the relays, do not bring them back.
  final Map<String, DateTime> deleted;

  /// Relays people's profiles named (at most three each), for people
  /// without a list of their own.
  final Map<String, List<String>> hints;

  /// Unread in the user's own chats; strangers' requests do not count.
  int get totalUnread => chats.values
      .where((chat) => chat.kept)
      .fold(0, (sum, chat) => sum + chat.unread);

  /// The chat with [people] (not including this account), made if new.
  NostrChat chatWith(List<String> people) {
    final sorted = [...people]..sort();
    return chats[sorted.join(',')] ?? NostrChat(people: sorted);
  }

  /// [message] added to the chat with [people], unless it is there
  /// already, or older than the chat's deletion.
  NostrChats add(
    List<String> people,
    NostrChatMessage message, {
    String? subject,
  }) {
    final chat = chatWith(people);
    final deletedAt = deleted[chat.key];
    if (chat.people.length > maxPeople ||
        (deletedAt != null && !message.at.isAfter(deletedAt)) ||
        chat.messages.any((existing) => existing.id == message.id)) {
      return this;
    }
    // Writing in it makes it the user's chat.
    final kept = chat.kept || message.outgoing;
    final limit = kept ? maxMessagesPerChat : maxMessagesPerRequest;
    final messages = [...chat.messages, message]
      ..sort((a, b) => a.at.compareTo(b.at));
    final trimmed = messages.length > limit
        ? messages.sublist(messages.length - limit)
        : messages;
    final updated = chat.copyWith(
      subject: chat.isGroup ? subject : null,
      messages: trimmed,
      unread: message.outgoing || !trimmed.contains(message)
          ? chat.unread
          : min(chat.unread + 1, trimmed.length),
      kept: kept,
    );
    final next = {...chats, updated.key: updated};
    final requests = next.values.where((chat) => !chat.kept).toList();
    if (requests.length > maxRequests) {
      requests.sort(
        (a, b) => (a.messages.lastOrNull?.at ?? DateTime(0)).compareTo(
          b.messages.lastOrNull?.at ?? DateTime(0),
        ),
      );
      for (final old in requests.take(requests.length - maxRequests)) {
        next.remove(old.key);
      }
    }
    return NostrChats(
      chats: next,
      names: names,
      deleted: deleted,
      hints: hints,
    );
  }

  /// A chat with [people] the user starts: kept, and empty if new. What
  /// was deleted before stays deleted. [relays] are where to reach people
  /// with no list of their own.
  NostrChats start(
    List<String> people, {
    Map<String, List<Uri>> relays = const {},
  }) {
    final chat = chatWith(people);
    return NostrChats(
      chats: {...chats, chat.key: chat.copyWith(kept: true)},
      names: names,
      deleted: deleted,
      hints: {
        ...hints,
        for (final MapEntry(:key, :value) in relays.entries)
          if (value.isNotEmpty)
            key: [for (final relay in value.take(3)) relay.toString()],
      },
    );
  }

  /// Chat [key] read. Reading alone does not keep a stranger's chat:
  /// replying does.
  NostrChats markRead(String key) {
    final chat = chats[key];
    if (chat == null || chat.unread == 0) return this;
    return NostrChats(
      chats: {...chats, key: chat.copyWith(unread: 0)},
      names: names,
      deleted: deleted,
      hints: hints,
    );
  }

  /// Deletes chat [key]; what was written before [now] stays out.
  NostrChats withoutChat(String key, DateTime now) {
    final next = {...deleted, key: now};
    if (next.length > maxDeleted) {
      final oldest = next.entries.reduce(
        (a, b) => a.value.isBefore(b.value) ? a : b,
      );
      next.remove(oldest.key);
    }
    return NostrChats(
      chats: {...chats}..remove(key),
      names: names,
      deleted: next,
      hints: hints,
    );
  }

  NostrChats named(String publicKey, String name) => NostrChats(
    chats: chats,
    deleted: deleted,
    hints: hints,
    names: name.trim().isEmpty
        ? ({...names}..remove(publicKey))
        : {...names, publicKey: name.trim()},
  );

  Map<String, dynamic> toJson() => {
    if (chats.isNotEmpty)
      'chats': [for (final chat in chats.values) chat.toJson()],
    if (names.isNotEmpty) 'names': names,
    if (hints.isNotEmpty) 'hints': hints,
    if (deleted.isNotEmpty)
      'deleted': {
        for (final MapEntry(:key, :value) in deleted.entries)
          key: value.toUtc().toIso8601String(),
      },
  };

  static NostrChats fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const NostrChats();
    final names = json['names'];
    final deleted = json['deleted'];
    final hints = json['hints'];
    return NostrChats(
      hints: {
        if (hints is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in hints.entries)
            if (value is List)
              key: [
                for (final relay in value.take(3))
                  if (relay is String) relay,
              ],
      },
      deleted: {
        if (deleted is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in deleted.entries)
            if (DateTime.tryParse(value is String ? value : '') case final at?)
              key: at.toUtc(),
      },
      chats: {
        for (final chat in json['chats'] as List? ?? const [])
          if (NostrChat.fromJson(chat) case final parsed?) parsed.key: parsed,
      },
      names: {
        if (names is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in names.entries)
            if (value is String) key: value,
      },
    );
  }
}
