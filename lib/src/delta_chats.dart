/// Delta Chat chats over the email account: the people (by OpenPGP key),
/// one-to-one and group chats, and pending invites. Kept on this device.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Someone on Delta Chat, known by their key.
class DeltaPeer {
  const DeltaPeer({
    required this.fingerprint,
    required this.addr,
    this.key,
    this.name,
    this.verified = false,
  });

  /// Upper-case hex: who this is.
  final String fingerprint;

  /// Their current address (lower case).
  final String addr;

  /// Their public key, once it arrived.
  final Uint8List? key;
  final String? name;

  /// The key was checked against an invite (Securejoin).
  final bool verified;

  DeltaPeer copyWith({
    String? addr,
    Uint8List? key,
    String? name,
    bool? verified,
  }) => DeltaPeer(
    fingerprint: fingerprint,
    addr: addr ?? this.addr,
    key: key ?? this.key,
    name: name ?? this.name,
    verified: verified ?? this.verified,
  );

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'addr': addr,
    if (key != null) 'key': base64.encode(key!),
    if (name != null) 'name': name,
    if (verified) 'verified': true,
  };

  static DeltaPeer? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final fingerprint = json['fingerprint'];
    final addr = json['addr'];
    if (fingerprint is! String || addr is! String) return null;
    Uint8List? key;
    if (json['key'] case final String encoded) {
      try {
        key = base64.decode(encoded);
      } on FormatException {
        key = null;
      }
    }
    return DeltaPeer(
      fingerprint: fingerprint,
      addr: addr,
      key: key,
      name: json['name'] as String?,
      verified: json['verified'] == true,
    );
  }
}

enum DeltaMessageState { sent, read, failed }

class DeltaChatMessage {
  const DeltaChatMessage({
    required this.id,
    required this.author,
    required this.text,
    required this.at,
    this.outgoing = false,
    this.state = DeltaMessageState.sent,
    this.wantsReceipt = false,
    this.info = false,
  });

  /// The Message-ID.
  final String id;

  /// The author's fingerprint (this account's own for outgoing).
  final String author;
  final String text;
  final DateTime at;
  final bool outgoing;
  final DeltaMessageState state;

  /// The sender asked for a read receipt (not yet sent).
  final bool wantsReceipt;

  /// A note about the chat (someone joined, verified…), not a message.
  final bool info;

  DeltaChatMessage copyWith({DeltaMessageState? state, bool? wantsReceipt}) =>
      DeltaChatMessage(
        id: id,
        author: author,
        text: text,
        at: at,
        outgoing: outgoing,
        state: state ?? this.state,
        wantsReceipt: wantsReceipt ?? this.wantsReceipt,
        info: info,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'author': author,
    'text': text,
    'at': at.toUtc().toIso8601String(),
    if (outgoing) 'outgoing': true,
    if (state != DeltaMessageState.sent) 'state': state.name,
    if (wantsReceipt) 'wantsReceipt': true,
    if (info) 'info': true,
  };

  static DeltaChatMessage? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final author = json['author'];
    final text = json['text'];
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (id is! String || author is! String || text is! String || at == null) {
      return null;
    }
    return DeltaChatMessage(
      id: id,
      author: author,
      text: text,
      at: at.toUtc(),
      outgoing: json['outgoing'] == true,
      state:
          DeltaMessageState.values.asNameMap()[json['state']] ??
          DeltaMessageState.sent,
      wantsReceipt: json['wantsReceipt'] == true,
      info: json['info'] == true,
    );
  }
}

class DeltaChat {
  const DeltaChat({
    required this.key,
    required this.members,
    this.groupId,
    this.name,
    this.messages = const [],
    this.unread = 0,
    this.kept = false,
    this.left = false,
    this.membersAt,
  });

  /// A peer's fingerprint for a one-to-one chat, `g:<id>` for a group.
  final String key;

  /// Everyone else in the chat, by fingerprint.
  final List<String> members;

  /// Delta Chat's Chat-Group-ID, for groups.
  final String? groupId;
  final String? name;

  /// Oldest first.
  final List<DeltaChatMessage> messages;
  final int unread;

  /// The user started, joined or wrote in it; until then a request.
  final bool kept;

  /// This account left the group (or was removed).
  final bool left;

  /// When the member list was last set: older messages do not change it.
  final DateTime? membersAt;

  bool get isGroup => groupId != null;

  static String groupKey(String groupId) => 'g:$groupId';

  DeltaChat copyWith({
    List<String>? members,
    String? name,
    List<DeltaChatMessage>? messages,
    int? unread,
    bool? kept,
    bool? left,
    DateTime? membersAt,
  }) => DeltaChat(
    key: key,
    members: members ?? this.members,
    groupId: groupId,
    name: name ?? this.name,
    messages: messages ?? this.messages,
    unread: unread ?? this.unread,
    kept: kept ?? this.kept,
    left: left ?? this.left,
    membersAt: membersAt ?? this.membersAt,
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    'members': members,
    if (groupId != null) 'groupId': groupId,
    if (name != null) 'name': name,
    'messages': [for (final message in messages) message.toJson()],
    if (unread > 0) 'unread': unread,
    if (kept) 'kept': true,
    if (left) 'left': true,
    if (membersAt != null) 'membersAt': membersAt!.toUtc().toIso8601String(),
  };

  static DeltaChat? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final key = json['key'];
    if (key is! String) return null;
    return DeltaChat(
      key: key,
      members: [
        for (final member in json['members'] as List? ?? const [])
          if (member is String) member,
      ],
      groupId: json['groupId'] as String?,
      name: json['name'] as String?,
      messages: [
        for (final message in json['messages'] as List? ?? const [])
          ?DeltaChatMessage.fromJson(message),
      ],
      unread: json['unread'] as int? ?? 0,
      kept: json['kept'] == true,
      left: json['left'] == true,
      membersAt: DateTime.tryParse(json['membersAt'] as String? ?? '')?.toUtc(),
    );
  }
}

/// An invite this device scanned and is still answering (Bob's side of
/// Securejoin).
class DeltaJoin {
  const DeltaJoin({
    required this.fingerprint,
    required this.addr,
    required this.auth,
    required this.at,
    this.groupId,
    this.groupName,
  });

  final String fingerprint;
  final String addr;
  final String auth;
  final DateTime at;
  final String? groupId;
  final String? groupName;

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'addr': addr,
    'auth': auth,
    'at': at.toUtc().toIso8601String(),
    if (groupId != null) 'groupId': groupId,
    if (groupName != null) 'groupName': groupName,
  };

  static DeltaJoin? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final fingerprint = json['fingerprint'];
    final addr = json['addr'];
    final auth = json['auth'];
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (fingerprint is! String ||
        addr is! String ||
        auth is! String ||
        at == null) {
      return null;
    }
    return DeltaJoin(
      fingerprint: fingerprint,
      addr: addr,
      auth: auth,
      at: at.toUtc(),
      groupId: json['groupId'] as String?,
      groupName: json['groupName'] as String?,
    );
  }
}

/// Everything about Delta Chat chats. Replaced, never changed in place.
class DeltaChats {
  const DeltaChats({
    this.peers = const {},
    this.chats = const {},
    this.joins = const [],
    this.deleted = const {},
  });

  static const int maxMessagesPerChat = 500;
  static const int maxRequests = 50;
  static const int maxMessagesPerRequest = 50;
  static const int maxPeers = 2000;
  static const int maxJoins = 20;
  static const int maxDeleted = 500;

  /// By fingerprint.
  final Map<String, DeltaPeer> peers;
  final Map<String, DeltaChat> chats;
  final List<DeltaJoin> joins;

  /// Deleted chats, by key, with when: older messages do not bring them
  /// back.
  final Map<String, DateTime> deleted;

  int get totalUnread => chats.values
      .where((chat) => chat.kept)
      .fold(0, (sum, chat) => sum + chat.unread);

  DeltaChats copyWith({
    Map<String, DeltaPeer>? peers,
    Map<String, DeltaChat>? chats,
    List<DeltaJoin>? joins,
    Map<String, DateTime>? deleted,
  }) => DeltaChats(
    peers: peers ?? this.peers,
    chats: chats ?? this.chats,
    joins: joins ?? this.joins,
    deleted: deleted ?? this.deleted,
  );

  /// [peer] remembered (merged with what was known).
  DeltaChats withPeer(DeltaPeer peer) {
    final known = peers[peer.fingerprint];
    final merged = known == null
        ? peer
        : known.copyWith(
            addr: peer.addr,
            key: peer.key,
            name: peer.name,
            verified: known.verified || peer.verified,
          );
    final next = {...peers, peer.fingerprint: merged};
    if (next.length > maxPeers) {
      // People in no chat go first; verified ones never.
      final inChats = {for (final chat in chats.values) ...chat.members};
      for (final MapEntry(key: fingerprint, value: known)
          in next.entries.toList()) {
        if (next.length <= maxPeers) break;
        if (!inChats.contains(fingerprint) &&
            !known.verified &&
            fingerprint != peer.fingerprint) {
          next.remove(fingerprint);
        }
      }
    }
    return copyWith(peers: next);
  }

  /// [chat] in place of the chat with its key.
  DeltaChats withChat(DeltaChat chat) =>
      copyWith(chats: {...chats, chat.key: chat});

  /// [message] added to the chat [key] (made from [create] when new),
  /// unless it is there already or older than the chat's deletion.
  DeltaChats add(
    String key,
    DeltaChatMessage message, {
    required DeltaChat Function() create,
  }) {
    final chat = chats[key] ?? create();
    final deletedAt = deleted[key];
    if ((deletedAt != null && !message.at.isAfter(deletedAt)) ||
        chat.messages.any((existing) => existing.id == message.id)) {
      return this;
    }
    final kept = chat.kept || message.outgoing;
    final limit = kept ? maxMessagesPerChat : maxMessagesPerRequest;
    final messages = [...chat.messages, message]
      ..sort((a, b) => a.at.compareTo(b.at));
    final trimmed = messages.length > limit
        ? messages.sublist(messages.length - limit)
        : messages;
    final updated = chat.copyWith(
      messages: trimmed,
      unread: message.outgoing || message.info || !trimmed.contains(message)
          ? chat.unread
          : min(chat.unread + 1, trimmed.length),
      kept: kept,
    );
    final next = {...chats, key: updated};
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
    return copyWith(chats: next);
  }

  /// Our message [id] was read by someone in chat [key].
  DeltaChats markReadBy(String key, String id) {
    final chat = chats[key];
    if (chat == null) return this;
    var changed = false;
    final messages = [
      for (final message in chat.messages)
        if (message.outgoing &&
            message.id == id &&
            message.state != DeltaMessageState.read)
          (() {
            changed = true;
            return message.copyWith(state: DeltaMessageState.read);
          })()
        else
          message,
    ];
    return changed ? withChat(chat.copyWith(messages: messages)) : this;
  }

  /// Our message [id] in chat [key] could not be sent.
  DeltaChats markFailed(String key, String id) {
    final chat = chats[key];
    if (chat == null) return this;
    return withChat(
      chat.copyWith(
        messages: [
          for (final message in chat.messages)
            message.outgoing && message.id == id
                ? message.copyWith(state: DeltaMessageState.failed)
                : message,
        ],
      ),
    );
  }

  /// Chat [key] read: unread cleared, and receipts no longer owed.
  DeltaChats markRead(String key) {
    final chat = chats[key];
    if (chat == null) return this;
    return withChat(
      chat.copyWith(
        unread: 0,
        messages: [
          for (final message in chat.messages)
            message.wantsReceipt
                ? message.copyWith(wantsReceipt: false)
                : message,
        ],
      ),
    );
  }

  DeltaChats withoutChat(String key, DateTime now) {
    final next = {...deleted, key: now};
    if (next.length > maxDeleted) {
      final oldest = next.entries.reduce(
        (a, b) => a.value.isBefore(b.value) ? a : b,
      );
      next.remove(oldest.key);
    }
    return copyWith(chats: {...chats}..remove(key), deleted: next);
  }

  /// [join] remembered; the oldest go past [maxJoins].
  DeltaChats withJoin(DeltaJoin join) {
    final next = [
      for (final existing in joins)
        if (existing.fingerprint != join.fingerprint ||
            existing.groupId != join.groupId)
          existing,
      join,
    ];
    return copyWith(
      joins: next.length > maxJoins
          ? next.sublist(next.length - maxJoins)
          : next,
    );
  }

  DeltaChats withoutJoin(DeltaJoin join) => copyWith(
    joins: [
      for (final existing in joins)
        if (!identical(existing, join) &&
            (existing.fingerprint != join.fingerprint ||
                existing.groupId != join.groupId))
          existing,
    ],
  );

  Map<String, dynamic> toJson() => {
    if (peers.isNotEmpty)
      'peers': [for (final peer in peers.values) peer.toJson()],
    if (chats.isNotEmpty)
      'chats': [for (final chat in chats.values) chat.toJson()],
    if (joins.isNotEmpty) 'joins': [for (final join in joins) join.toJson()],
    if (deleted.isNotEmpty)
      'deleted': {
        for (final MapEntry(:key, :value) in deleted.entries)
          key: value.toUtc().toIso8601String(),
      },
  };

  static DeltaChats fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const DeltaChats();
    final deleted = json['deleted'];
    return DeltaChats(
      peers: {
        for (final peer in [
          for (final json in json['peers'] as List? ?? const [])
            ?DeltaPeer.fromJson(json),
        ])
          peer.fingerprint: peer,
      },
      chats: {
        for (final chat in [
          for (final json in json['chats'] as List? ?? const [])
            ?DeltaChat.fromJson(json),
        ])
          chat.key: chat,
      },
      joins: [
        for (final join in json['joins'] as List? ?? const [])
          ?DeltaJoin.fromJson(join),
      ],
      deleted: {
        if (deleted is Map<String, dynamic>)
          for (final MapEntry(:key, :value) in deleted.entries)
            if (DateTime.tryParse(value is String ? value : '') case final at?)
              key: at.toUtc(),
      },
    );
  }
}
