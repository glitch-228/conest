import 'dart:math';

/// Where an outgoing XMPP message got to.
enum XmppMessageState { sending, sent, delivered, read, failed }

/// How a message was protected. Append only (stored by name).
enum XmppSecurity {
  /// Sent in the clear (as far as the XMPP stream goes).
  plain,

  /// OMEMO 2, end to end, but with devices that were never verified.
  omemo2,

  /// Legacy OMEMO (the Conversations/Dino/Gajim format). Shown as such, not
  /// as "encrypted", until the implementation has been reviewed.
  legacyOmemo,

  /// Encrypted, but it could not be read here.
  unreadable,

  /// Encrypted by a device the user has refused.
  untrusted,

  /// OMEMO 2, from or to devices the user verified.
  omemo2Verified,

  /// Encrypted by a new device of a contact who has verified devices, which
  /// the user has not confirmed yet.
  unconfirmed,
}

/// What the user chose for a chat: encrypt when the contact has OMEMO
/// devices (auto), never, or always (and refuse to send otherwise). Stored
/// by name; append only.
enum XmppChatEncryption { auto, off, on }

/// One message in an XMPP chat (1:1 or group chat).
class XmppChatMessage {
  const XmppChatMessage({
    required this.id,
    required this.from,
    required this.text,
    required this.at,
    required this.outgoing,
    this.stanzaId,
    this.state = XmppMessageState.sent,
    this.editedAt,
    this.retracted = false,
    this.replyTo,
    this.replySnippet,
    this.reactions = const {},
    this.fileUrl,
    this.security = XmppSecurity.plain,
    this.securityNote,
  });

  /// The id the sender gave (origin id), which corrections and receipts
  /// name.
  final String id;

  /// The archive's id (XEP-0359), which group chats' retractions and
  /// reactions name, and history catch-up starts after.
  final String? stanzaId;

  /// The sender: a bare JID in 1:1 chats, the nickname in a group chat.
  final String from;
  final String text;
  final DateTime at;
  final bool outgoing;
  final XmppMessageState state;
  final DateTime? editedAt;
  final bool retracted;

  /// The message this one answers (XEP-0461), by id.
  final String? replyTo;
  final String? replySnippet;

  /// Emoji to the senders who reacted with it (XEP-0444).
  final Map<String, Set<String>> reactions;

  /// A file shared by link (HTTP upload, XEP-0363 / XEP-0066).
  final String? fileUrl;

  /// How the message was protected.
  final XmppSecurity security;

  /// Why an encrypted message could not be read, if so.
  final String? securityNote;

  XmppChatMessage copyWith({
    String? stanzaId,
    String? text,
    XmppMessageState? state,
    DateTime? editedAt,
    bool? retracted,
    Map<String, Set<String>>? reactions,
    XmppSecurity? security,
    String? securityNote,
  }) => XmppChatMessage(
    id: id,
    from: from,
    text: text ?? this.text,
    at: at,
    outgoing: outgoing,
    stanzaId: stanzaId ?? this.stanzaId,
    state: state ?? this.state,
    editedAt: editedAt ?? this.editedAt,
    retracted: retracted ?? this.retracted,
    replyTo: replyTo,
    replySnippet: replySnippet,
    reactions: reactions ?? this.reactions,
    fileUrl: fileUrl,
    security: security ?? this.security,
    securityNote: securityNote ?? this.securityNote,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'sid': ?stanzaId,
    'from': from,
    'text': text,
    'at': at.toUtc().toIso8601String(),
    if (outgoing) 'out': true,
    if (state != XmppMessageState.sent) 'state': state.name,
    'edited': ?editedAt?.toUtc().toIso8601String(),
    if (retracted) 'retracted': true,
    'reply': ?replyTo,
    'replySnippet': ?replySnippet,
    if (reactions.isNotEmpty)
      'reactions': {
        for (final MapEntry(:key, :value) in reactions.entries)
          key: value.toList(),
      },
    'file': ?fileUrl,
    if (security != XmppSecurity.plain) 'sec': security.name,
    'secNote': ?securityNote,
  };

  static XmppChatMessage? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final from = json['from'];
    final text = json['text'];
    final at = DateTime.tryParse('${json['at']}');
    if (id is! String || from is! String || text is! String || at == null) {
      return null;
    }
    final reactions = json['reactions'];
    return XmppChatMessage(
      id: id,
      stanzaId: json['sid'] as String?,
      from: from,
      text: text,
      at: at,
      outgoing: json['out'] == true,
      state:
          XmppMessageState.values.asNameMap()[json['state']] ??
          XmppMessageState.sent,
      editedAt: DateTime.tryParse('${json['edited']}'),
      retracted: json['retracted'] == true,
      replyTo: json['reply'] as String?,
      replySnippet: json['replySnippet'] as String?,
      reactions: {
        if (reactions is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in reactions.entries.take(32))
            if (value is List) key: {...value.whereType<String>().take(256)},
      },
      fileUrl: json['file'] as String?,
      security:
          XmppSecurity.values.asNameMap()[json['sec']] ?? XmppSecurity.plain,
      securityNote: json['secNote'] as String?,
    );
  }
}

/// One XMPP chat: a person (bare JID) or a group chat (room JID).
class XmppChat {
  const XmppChat({
    required this.jid,
    this.room = false,
    this.request = false,
    this.title,
    this.nick,
    this.messages = const [],
    this.unread = 0,
    this.lastStanzaId,
    this.encryption = XmppChatEncryption.auto,
  });

  final String jid;

  /// A group chat (MUC, XEP-0045).
  final bool room;

  /// Someone not in the contact list wrote first: kept apart until
  /// accepted, as Delta Chat does.
  final bool request;

  /// The room's subject or the name given to the person.
  final String? title;

  /// This account's nickname in the room.
  final String? nick;
  final List<XmppChatMessage> messages;
  final int unread;

  /// The newest archived message seen, where history catch-up resumes.
  final String? lastStanzaId;

  /// Whether messages here are encrypted (OMEMO).
  final XmppChatEncryption encryption;

  XmppChat copyWith({
    bool? request,
    String? title,
    String? nick,
    List<XmppChatMessage>? messages,
    int? unread,
    String? lastStanzaId,
    XmppChatEncryption? encryption,
  }) => XmppChat(
    jid: jid,
    room: room,
    request: request ?? this.request,
    title: title ?? this.title,
    nick: nick ?? this.nick,
    messages: messages ?? this.messages,
    unread: unread ?? this.unread,
    lastStanzaId: lastStanzaId ?? this.lastStanzaId,
    encryption: encryption ?? this.encryption,
  );

  Map<String, Object?> toJson() => {
    'jid': jid,
    if (room) 'room': true,
    if (request) 'request': true,
    'title': ?title,
    'nick': ?nick,
    'messages': [for (final message in messages) message.toJson()],
    if (unread > 0) 'unread': unread,
    'last': ?lastStanzaId,
    if (encryption != XmppChatEncryption.auto) 'enc': encryption.name,
  };

  static XmppChat? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final jid = json['jid'];
    if (jid is! String || jid.isEmpty) return null;
    final messages = json['messages'];
    return XmppChat(
      jid: jid,
      room: json['room'] == true,
      request: json['request'] == true,
      title: json['title'] as String?,
      nick: json['nick'] as String?,
      messages: [
        if (messages is List)
          for (final message in messages.take(XmppChats.maxMessagesPerChat))
            ?XmppChatMessage.fromJson(message),
      ],
      unread: (json['unread'] as int?) ?? 0,
      lastStanzaId: json['last'] as String?,
      encryption:
          XmppChatEncryption.values.asNameMap()[json['enc']] ??
          XmppChatEncryption.auto,
    );
  }
}

/// Every XMPP chat of the account, kept in the vault. Bounded: chats,
/// messages per chat and text lengths all have limits.
class XmppChats {
  const XmppChats({
    this.chats = const {},
    this.blocked = const {},
    this.names = const {},
    this.archiveLast,
  });

  /// The newest message of this account's archive seen, where its history
  /// catch-up resumes.
  final String? archiveLast;

  static const int maxChats = 500;
  static const int maxMessagesPerChat = 500;
  static const int maxTextChars = 10000;

  final Map<String, XmppChat> chats;

  /// Blocked addresses (XEP-0191), mirrored from the server.
  final Set<String> blocked;

  /// Names from the contact list (roster).
  final Map<String, String> names;

  XmppChats copyWith({
    Map<String, XmppChat>? chats,
    Set<String>? blocked,
    Map<String, String>? names,
    String? archiveLast,
  }) => XmppChats(
    chats: chats ?? this.chats,
    blocked: blocked ?? this.blocked,
    names: names ?? this.names,
    archiveLast: archiveLast ?? this.archiveLast,
  );

  /// [chat] replaced or added; the oldest chat goes past [maxChats].
  XmppChats withChat(XmppChat chat) {
    final next = {...chats, chat.jid: chat};
    while (next.length > maxChats) {
      final oldest = next.values.reduce(
        (a, b) =>
            (a.messages.lastOrNull?.at ?? DateTime(0)).isBefore(
              b.messages.lastOrNull?.at ?? DateTime(0),
            )
            ? a
            : b,
      );
      next.remove(oldest.jid);
    }
    return copyWith(chats: next);
  }

  XmppChats withoutChat(String jid) => copyWith(chats: {...chats}..remove(jid));

  /// [message] added to [jid]'s chat (made if needed), in time order, with
  /// duplicates (same id from the same sender) ignored.
  XmppChats addMessage(
    String jid,
    XmppChatMessage message, {
    bool room = false,
    bool request = false,
    bool countUnread = true,
  }) {
    final chat = chats[jid] ?? XmppChat(jid: jid, room: room, request: request);
    final duplicate = chat.messages.any(
      (existing) =>
          (existing.id == message.id && existing.from == message.from) ||
          (message.stanzaId != null && existing.stanzaId == message.stanzaId),
    );
    if (duplicate) return this;
    final messages = [...chat.messages, message]
      ..sort((a, b) => a.at.compareTo(b.at));
    final kept = messages.length > maxMessagesPerChat
        ? messages.sublist(messages.length - maxMessagesPerChat)
        : messages;
    return withChat(
      chat.copyWith(
        messages: kept,
        unread: chat.unread + (countUnread && !message.outgoing ? 1 : 0),
        lastStanzaId: message.stanzaId,
      ),
    );
  }

  /// Changes the message [id] in [jid]'s chat, if [test] allows.
  XmppChats updateMessage(
    String jid,
    bool Function(XmppChatMessage message) match,
    XmppChatMessage Function(XmppChatMessage message) change,
  ) {
    final chat = chats[jid];
    if (chat == null) return this;
    var changed = false;
    final messages = [
      for (final message in chat.messages)
        if (!changed && match(message))
          () {
            changed = true;
            return change(message);
          }()
        else
          message,
    ];
    if (!changed) return this;
    return withChat(chat.copyWith(messages: messages));
  }

  XmppChats markRead(String jid) {
    final chat = chats[jid];
    if (chat == null || chat.unread == 0) return this;
    return withChat(chat.copyWith(unread: 0));
  }

  Map<String, Object?> toJson() => {
    'chats': [for (final chat in chats.values) chat.toJson()],
    if (blocked.isNotEmpty) 'blocked': blocked.toList(),
    if (names.isNotEmpty) 'names': names,
    'archiveLast': ?archiveLast,
  };

  static XmppChats fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const XmppChats();
    final chats = json['chats'];
    final blocked = json['blocked'];
    final names = json['names'];
    final parsed = <String, XmppChat>{};
    if (chats is List) {
      for (final chat in chats.take(maxChats)) {
        final value = XmppChat.fromJson(chat);
        if (value != null) parsed[value.jid] = value;
      }
    }
    return XmppChats(
      archiveLast: json['archiveLast'] as String?,
      chats: parsed,
      blocked: {if (blocked is List) ...blocked.whereType<String>().take(1000)},
      names: {
        if (names is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in names.entries.take(5000))
            if (value is String) key: value,
      },
    );
  }
}

/// [text] cut to [XmppChats.maxTextChars] characters.
String boundedXmppText(String text) => text.length <= XmppChats.maxTextChars
    ? text
    : '${String.fromCharCodes(text.runes.take(XmppChats.maxTextChars))}…';

/// A short quote of [text] for a reply.
String xmppSnippet(String text) {
  final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return single.length <= 80
      ? single
      : '${single.substring(0, min(80, single.length))}…';
}
