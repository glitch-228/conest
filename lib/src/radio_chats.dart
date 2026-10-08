/// Chats with users of a radio's own apps (the Meshtastic and MeshCore
/// apps): direct messages with nodes, and the radio's channels. Kept on
/// this device only.
library;

import 'dart:math';

enum RadioMessageState { sent, delivered, failed }

class RadioChatMessage {
  const RadioChatMessage({
    required this.id,
    required this.from,
    required this.name,
    required this.text,
    required this.at,
    required this.outgoing,
    this.state = RadioMessageState.sent,
    this.authentic = false,
  });

  /// The radio's packet id (or a made-up one): copies are told apart.
  final String id;

  /// The node (or contact) that wrote it.
  final String from;
  final String name;
  final String text;
  final DateTime at;
  final bool outgoing;
  final RadioMessageState state;

  /// The radio could tell it really came from [from] (a direct message
  /// encrypted with the two radios' keys); channel messages, and older
  /// direct ones, carry whatever sender and name the writer chose.
  final bool authentic;

  RadioChatMessage withState(RadioMessageState next) => RadioChatMessage(
    id: id,
    from: from,
    name: name,
    text: text,
    at: at,
    outgoing: outgoing,
    state: next,
    authentic: authentic,
  );

  RadioChatMessage withText(String next) => RadioChatMessage(
    id: id,
    from: from,
    name: name,
    text: next,
    at: at,
    outgoing: outgoing,
    state: state,
    authentic: authentic,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': from,
    'name': name,
    'text': text,
    'at': at.toUtc().toIso8601String(),
    if (outgoing) 'outgoing': true,
    if (state != RadioMessageState.sent) 'state': state.name,
    if (authentic) 'authentic': true,
  };

  static RadioChatMessage? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final from = json['from'];
    final text = json['text'];
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (id is! String || from is! String || text is! String || at == null) {
      return null;
    }
    return RadioChatMessage(
      id: id,
      from: from,
      name: json['name'] as String? ?? from,
      text: text,
      at: at.toUtc(),
      outgoing: json['outgoing'] == true,
      state:
          RadioMessageState.values.asNameMap()[json['state']] ??
          RadioMessageState.sent,
      authentic: json['authentic'] == true,
    );
  }
}

/// All chats with a radio's app users. Replaced, never changed in place.
class RadioChats {
  const RadioChats({
    this.chats = const {},
    this.unread = const {},
    this.kept = const {},
  });

  /// Chats strangers started (nobody here wrote in them): over this many,
  /// the oldest go first. The user's own chats ([kept]) never do.
  static const int maxChats = 100;
  static const int maxMessagesPerChat = 300;

  /// Longest text kept from a message (radios carry about 200 bytes).
  static const int maxTextChars = 400;

  /// Key of a direct chat with [node].
  static String direct(String node) => 'dm:$node';

  /// Key of the radio's channel [index].
  static String channel(int index) => 'ch:$index';

  static bool isChannel(String key) => key.startsWith('ch:');

  /// By key ([direct] or [channel]), oldest first.
  final Map<String, List<RadioChatMessage>> chats;
  final Map<String, int> unread;

  /// Chats the user started or wrote in.
  final Set<String> kept;

  int get totalUnread => unread.values.fold(0, (sum, count) => sum + count);

  /// [message] added to chat [key], unless it is there already.
  RadioChats add(String key, RadioChatMessage message) {
    final chat = chats[key] ?? const <RadioChatMessage>[];
    if (chat.any((existing) => existing.id == message.id)) return this;
    final stored = message.text.length > maxTextChars
        ? message.withText(
            '${String.fromCharCodes(message.text.runes.take(maxTextChars))}…',
          )
        : message;
    final messages = [...chat, stored]..sort((a, b) => a.at.compareTo(b.at));
    final next = {
      ...chats,
      key: messages.length > maxMessagesPerChat
          ? messages.sublist(messages.length - maxMessagesPerChat)
          : messages,
    };
    final keptNext = message.outgoing ? {...kept, key} : kept;
    _evict(next, keptNext);
    return RadioChats(
      chats: next,
      kept: keptNext,
      unread: {
        for (final MapEntry(:key, :value) in unread.entries)
          if (next.containsKey(key)) key: value,
        if (!message.outgoing && next.containsKey(key))
          key: min((unread[key] ?? 0) + 1, next[key]!.length),
      },
    );
  }

  /// Drops strangers' chats over [maxChats], oldest last message first
  /// (empty ones count as oldest).
  static void _evict(
    Map<String, List<RadioChatMessage>> chats,
    Set<String> kept,
  ) {
    final strangers = chats.entries
        .where((entry) => !kept.contains(entry.key))
        .toList();
    if (strangers.length <= maxChats) return;
    DateTime last(List<RadioChatMessage> messages) =>
        messages.lastOrNull?.at ?? DateTime.utc(0);
    strangers.sort((a, b) => last(a.value).compareTo(last(b.value)));
    for (final old in strangers.take(strangers.length - maxChats)) {
      chats.remove(old.key);
    }
  }

  /// Our message [id] in chat [key] reached the other radio, or [failed].
  RadioChats markDelivered(String key, String id, {bool failed = false}) {
    final chat = chats[key];
    if (chat == null) return this;
    return RadioChats(
      chats: {
        ...chats,
        key: [
          for (final message in chat)
            message.outgoing && message.id == id
                ? message.withState(
                    failed
                        ? RadioMessageState.failed
                        : RadioMessageState.delivered,
                  )
                : message,
        ],
      },
      unread: unread,
      kept: kept,
    );
  }

  RadioChats markRead(String key) => unread.containsKey(key)
      ? RadioChats(chats: chats, unread: {...unread}..remove(key), kept: kept)
      : this;

  /// An empty chat [key] the user starts, to write in: kept.
  RadioChats start(String key) => RadioChats(
    chats: chats.containsKey(key) ? chats : {...chats, key: const []},
    unread: unread,
    kept: {...kept, key},
  );

  RadioChats withoutChat(String key) => RadioChats(
    chats: {...chats}..remove(key),
    unread: {...unread}..remove(key),
    kept: {...kept}..remove(key),
  );

  Map<String, dynamic> toJson() => {
    if (chats.isNotEmpty)
      'chats': {
        for (final MapEntry(:key, :value) in chats.entries)
          key: [for (final message in value) message.toJson()],
      },
    if (unread.isNotEmpty) 'unread': unread,
    if (kept.isNotEmpty) 'kept': kept.toList(),
  };

  static RadioChats fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const RadioChats();
    final chats = json['chats'];
    final unread = json['unread'];
    final kept = json['kept'];
    return RadioChats(
      chats: {
        if (chats is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in chats.entries)
            if (value is List)
              key: [
                for (final message in value)
                  ?RadioChatMessage.fromJson(message),
              ],
      },
      unread: {
        if (unread is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in unread.entries)
            if (value is int && value > 0) key: value,
      },
      kept: {
        if (kept is List)
          for (final key in kept)
            if (key is String) key,
      },
    );
  }
}
