/// Chats with bitchat users nearby: the mesh chat everyone in range shares,
/// and private chats with single bitchat users. Kept on this device only.
library;

/// How an outgoing message has fared.
enum BitchatMessageState { sent, delivered, read }

class BitchatChatMessage {
  const BitchatChatMessage({
    required this.id,
    required this.peerId,
    required this.nickname,
    required this.text,
    required this.at,
    required this.outgoing,
    this.state = BitchatMessageState.sent,
    this.via,
  });

  /// bitchat's id: the message id of a private message, the derived id of
  /// a mesh chat message.
  final String id;

  /// The other side of a private chat; the author in the mesh chat.
  final String peerId;
  final String nickname;
  final String text;
  final DateTime at;
  final bool outgoing;
  final BitchatMessageState state;

  /// The peer id of our own bitchat identity that sent or received it: a
  /// later identity must not answer for an earlier one (that would link
  /// them).
  final String? via;

  BitchatChatMessage withState(BitchatMessageState next) =>
      next.index <= state.index
      ? this
      : BitchatChatMessage(
          id: id,
          peerId: peerId,
          nickname: nickname,
          text: text,
          at: at,
          outgoing: outgoing,
          state: next,
          via: via,
        );

  Map<String, dynamic> toJson() => {
    'id': id,
    'peerId': peerId,
    'nickname': nickname,
    'text': text,
    'at': at.toUtc().toIso8601String(),
    if (outgoing) 'outgoing': true,
    if (state != BitchatMessageState.sent) 'state': state.name,
    if (via != null) 'via': via,
  };

  static BitchatChatMessage? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final peerId = json['peerId'];
    final text = json['text'];
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (id is! String || peerId is! String || text is! String || at == null) {
      return null;
    }
    return BitchatChatMessage(
      id: id,
      peerId: peerId,
      nickname: json['nickname'] as String? ?? '',
      text: text,
      at: at.toUtc(),
      outgoing: json['outgoing'] == true,
      state:
          BitchatMessageState.values.asNameMap()[json['state']] ??
          BitchatMessageState.sent,
      via: json['via'] as String?,
    );
  }
}

/// All bitchat chats. Replaced, never changed in place.
class BitchatChats {
  const BitchatChats({
    this.mesh = const [],
    this.direct = const {},
    this.unread = const {},
  });

  /// The key of the mesh chat in [unread].
  static const String meshKey = '#mesh';

  static const int maxMessagesPerChat = 500;
  static const int maxChats = 200;

  /// The mesh chat is strangers talking: fewer messages, and none older
  /// than [meshKeptFor].
  static const int maxMeshMessages = 200;
  static const Duration meshKeptFor = Duration(days: 7);

  /// The mesh chat, oldest first.
  final List<BitchatChatMessage> mesh;

  /// Private chats by the bitchat user's peer id, oldest first.
  final Map<String, List<BitchatChatMessage>> direct;

  /// Unread messages by chat ([meshKey] or a peer id).
  final Map<String, int> unread;

  int get totalUnread => unread.values.fold(0, (sum, count) => sum + count);

  /// The latest name a peer used in any chat.
  String? nicknameOf(String peerId) {
    final messages = [
      ...?direct[peerId],
      ...mesh.where((message) => message.peerId == peerId),
    ].where((message) => !message.outgoing).toList();
    if (messages.isEmpty) return null;
    messages.sort((a, b) => a.at.compareTo(b.at));
    return messages.last.nickname;
  }

  /// [message] added to the mesh chat, unless it is there already.
  BitchatChats addMesh(BitchatChatMessage message) {
    if (mesh.any((existing) => existing.id == message.id)) return this;
    final cutoff = message.at.subtract(meshKeptFor);
    return BitchatChats(
      mesh: _trimmed([
        for (final existing in mesh)
          if (existing.at.isAfter(cutoff)) existing,
        message,
      ], maxMeshMessages),
      direct: direct,
      unread: message.outgoing ? unread : _bumped(meshKey),
    );
  }

  /// [message] added to its private chat, unless it is there already.
  BitchatChats addDirect(BitchatChatMessage message) {
    final chat = direct[message.peerId] ?? const [];
    if (chat.any((existing) => existing.id == message.id)) return this;
    final chats = {
      ...direct,
      message.peerId: _trimmed([...chat, message], maxMessagesPerChat),
    };
    // The chats with the oldest last message go first when there are many.
    if (chats.length > maxChats) {
      final byAge = chats.entries.toList()
        ..sort((a, b) => a.value.last.at.compareTo(b.value.last.at));
      for (final entry in byAge.take(chats.length - maxChats)) {
        chats.remove(entry.key);
      }
    }
    return BitchatChats(
      mesh: mesh,
      direct: chats,
      unread: {
        for (final entry
            in (message.outgoing ? unread : _bumped(message.peerId)).entries)
          if (entry.key == meshKey || chats.containsKey(entry.key))
            entry.key: entry.value,
      },
    );
  }

  /// Our message [messageId] to [peerId] reached [state].
  BitchatChats markOutgoing(
    String peerId,
    String messageId,
    BitchatMessageState state,
  ) {
    final chat = direct[peerId];
    if (chat == null) return this;
    var changed = false;
    final next = [
      for (final message in chat)
        if (message.outgoing && message.id == messageId)
          () {
            final updated = message.withState(state);
            changed |= !identical(updated, message);
            return updated;
          }()
        else
          message,
    ];
    if (!changed) return this;
    return BitchatChats(
      mesh: mesh,
      direct: {...direct, peerId: next},
      unread: unread,
    );
  }

  /// Chat [key] ([meshKey] or a peer id) read.
  BitchatChats markRead(String key) {
    if (!unread.containsKey(key)) return this;
    return BitchatChats(
      mesh: mesh,
      direct: direct,
      unread: {...unread}..remove(key),
    );
  }

  /// Removes the private chat with [peerId].
  BitchatChats withoutChat(String peerId) => BitchatChats(
    mesh: mesh,
    direct: {...direct}..remove(peerId),
    unread: {...unread}..remove(peerId),
  );

  Map<String, int> _bumped(String key) => {
    ...unread,
    key: (unread[key] ?? 0) + 1,
  };

  static List<BitchatChatMessage> _trimmed(
    List<BitchatChatMessage> chat,
    int max,
  ) {
    chat.sort((a, b) => a.at.compareTo(b.at));
    return chat.length <= max ? chat : chat.sublist(chat.length - max);
  }

  Map<String, dynamic> toJson() => {
    if (mesh.isNotEmpty) 'mesh': [for (final message in mesh) message.toJson()],
    if (direct.isNotEmpty)
      'direct': {
        for (final MapEntry(:key, :value) in direct.entries)
          key: [for (final message in value) message.toJson()],
      },
    if (unread.isNotEmpty) 'unread': unread,
  };

  static BitchatChats fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const BitchatChats();
    List<BitchatChatMessage> messages(Object? list) => [
      if (list is List)
        for (final item in list) ?BitchatChatMessage.fromJson(item),
    ];
    final direct = json['direct'];
    final unread = json['unread'];
    return BitchatChats(
      mesh: messages(json['mesh']),
      direct: {
        if (direct is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in direct.entries)
            if (messages(value) case final chat when chat.isNotEmpty) key: chat,
      },
      unread: {
        if (unread is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in unread.entries)
            if (value is int && value > 0) key: value,
      },
    );
  }
}
