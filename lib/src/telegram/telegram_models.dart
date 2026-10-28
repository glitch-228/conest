/// What a Telegram client shows, parsed from TDLib's JSON. Everything from
/// TDLib is treated as untrusted data: sizes and counts are bounded and
/// unknown shapes degrade to a placeholder.
library;

const int maxTelegramChats = 3000;
const int maxTelegramMessagesPerChat = 400;
const int maxTelegramTextChars = 20000;
const int maxTelegramNameChars = 200;
const int maxTelegramReactions = 32;

/// TDLib sends int64 as strings and smaller integers as numbers.
int? tdInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};

String tdText(Object? value, int limit) {
  if (value is! String) return '';
  return value.length <= limit ? value : value.substring(0, limit);
}

enum TgChatKind { private, group, channel, secret, saved, other }

enum TgContentKind {
  text,
  photo,
  video,
  document,
  voice,
  audio,
  sticker,
  other,

  /// The sender deleted the message; its content is dropped, not kept.
  deleted,
}

/// A file TDLib downloads on request.
class TgFile {
  const TgFile({
    required this.id,
    this.name = '',
    this.size = 0,
    this.path,
    this.downloading = false,
    this.downloadedBytes = 0,
  });

  final int id;
  final String name;
  final int size;

  /// Where TDLib put it once downloaded.
  final String? path;
  final bool downloading;
  final int downloadedBytes;

  bool get downloaded => path != null;

  TgFile withProgress(Map<String, dynamic> file) {
    final local = file['local'];
    final completed = local is Map && local['is_downloading_completed'] == true;
    final localPath = local is Map ? tdText(local['path'], 4096) : '';
    return TgFile(
      id: id,
      name: name,
      size: tdInt(file['size']) ?? size,
      path: completed && localPath.isNotEmpty ? localPath : null,
      downloading: local is Map && local['is_downloading_active'] == true,
      downloadedBytes: local is Map
          ? (tdInt(local['downloaded_size']) ?? 0)
          : 0,
    );
  }

  static TgFile? parse(Object? json, {String name = ''}) {
    if (json is! Map) return null;
    final id = tdInt(json['id']);
    if (id == null) return null;
    return TgFile(
      id: id,
      name: tdText(name, 255),
    ).withProgress(Map<String, dynamic>.from(json));
  }
}

class TgContent {
  const TgContent(this.kind, {this.text = '', this.file, this.typeName = ''});

  final TgContentKind kind;

  /// The text, or a file's caption.
  final String text;
  final TgFile? file;

  /// TDLib's content type when it is not one Conest shows.
  final String typeName;

  static const deleted = TgContent(TgContentKind.deleted);

  TgContent withFile(TgFile? next) =>
      TgContent(kind, text: text, file: next, typeName: typeName);

  static TgContent parse(Object? json) {
    if (json is! Map) return const TgContent(TgContentKind.other);
    final type = json['@type'];
    String formatted(Object? value) =>
        value is Map ? tdText(value['text'], maxTelegramTextChars) : '';
    switch (type) {
      case 'messageText':
        return TgContent(TgContentKind.text, text: formatted(json['text']));
      case 'messagePhoto':
        final photo = json['photo'];
        TgFile? best;
        if (photo is Map && photo['sizes'] is List) {
          for (final size in (photo['sizes'] as List).take(16)) {
            if (size is Map) {
              final file = TgFile.parse(size['photo'], name: 'photo.jpg');
              if (file != null && (best == null || file.size >= best.size)) {
                best = file;
              }
            }
          }
        }
        return TgContent(
          TgContentKind.photo,
          text: formatted(json['caption']),
          file: best,
        );
      case 'messageVideo':
        final video = json['video'];
        return TgContent(
          TgContentKind.video,
          text: formatted(json['caption']),
          file: video is Map
              ? TgFile.parse(
                  video['video'],
                  name: tdText(video['file_name'], 255),
                )
              : null,
        );
      case 'messageDocument':
        final document = json['document'];
        return TgContent(
          TgContentKind.document,
          text: formatted(json['caption']),
          file: document is Map
              ? TgFile.parse(
                  document['document'],
                  name: tdText(document['file_name'], 255),
                )
              : null,
        );
      case 'messageVoiceNote':
        final voice = json['voice_note'];
        return TgContent(
          TgContentKind.voice,
          text: formatted(json['caption']),
          file: voice is Map
              ? TgFile.parse(voice['voice'], name: 'voice.ogg')
              : null,
        );
      case 'messageAudio':
        final audio = json['audio'];
        return TgContent(
          TgContentKind.audio,
          text: formatted(json['caption']),
          file: audio is Map
              ? TgFile.parse(
                  audio['audio'],
                  name: tdText(audio['file_name'], 255),
                )
              : null,
        );
      case 'messageSticker':
        final sticker = json['sticker'];
        return TgContent(
          TgContentKind.sticker,
          text: sticker is Map ? tdText(sticker['emoji'], 16) : '',
        );
    }
    return TgContent(
      TgContentKind.other,
      typeName: type is String ? tdText(type, 64) : '',
    );
  }
}

/// Where a sent message got to.
enum TgSendState { sent, sending, failed }

class TgMessage {
  const TgMessage({
    required this.id,
    required this.chatId,
    required this.date,
    required this.outgoing,
    required this.content,
    this.senderId = 0,
    this.senderName = '',
    this.replyToId,
    this.editedAt,
    this.reactions = const {},
    this.myReactions = const {},
    this.sendState = TgSendState.sent,
    this.scheduled = false,
  });

  final int id;
  final int chatId;
  final DateTime date;
  final bool outgoing;
  final TgContent content;
  final int senderId;
  final String senderName;
  final int? replyToId;
  final DateTime? editedAt;

  /// Emoji to how many people reacted with it, and which ones the user did.
  final Map<String, int> reactions;
  final Set<String> myReactions;
  final TgSendState sendState;
  final bool scheduled;

  TgMessage copyWith({
    int? id,
    TgContent? content,
    DateTime? editedAt,
    Map<String, int>? reactions,
    Set<String>? myReactions,
    TgSendState? sendState,
    String? senderName,
  }) => TgMessage(
    id: id ?? this.id,
    chatId: chatId,
    date: date,
    outgoing: outgoing,
    content: content ?? this.content,
    senderId: senderId,
    senderName: senderName ?? this.senderName,
    replyToId: replyToId,
    editedAt: editedAt ?? this.editedAt,
    reactions: reactions ?? this.reactions,
    myReactions: myReactions ?? this.myReactions,
    sendState: sendState ?? this.sendState,
    scheduled: scheduled,
  );

  static (Map<String, int>, Set<String>) parseReactions(Object? info) {
    final counts = <String, int>{};
    final mine = <String>{};
    if (info is Map) {
      final holder = info['reactions'];
      final list = holder is Map ? holder['reactions'] : holder;
      if (list is List) {
        for (final entry in list.take(maxTelegramReactions)) {
          if (entry is! Map) continue;
          final type = entry['type'];
          if (type is! Map || type['@type'] != 'reactionTypeEmoji') continue;
          final emoji = tdText(type['emoji'], 16);
          final count = tdInt(entry['total_count']) ?? 0;
          if (emoji.isEmpty || count <= 0) continue;
          counts[emoji] = count;
          if (entry['is_chosen'] == true) mine.add(emoji);
        }
      }
    }
    return (counts, mine);
  }

  static TgMessage? parse(Object? json) {
    if (json is! Map) return null;
    final id = tdInt(json['id']);
    final chatId = tdInt(json['chat_id']);
    final date = tdInt(json['date']);
    if (id == null || chatId == null || date == null) return null;
    final sender = json['sender_id'];
    final senderId = sender is Map
        ? (tdInt(sender['user_id']) ?? tdInt(sender['chat_id']) ?? 0)
        : 0;
    final reply = json['reply_to'];
    final replyId = reply is Map && reply['@type'] == 'messageReplyToMessage'
        ? tdInt(reply['message_id'])
        : null;
    final edit = tdInt(json['edit_date']);
    final (counts, mine) = parseReactions(json['interaction_info']);
    final state = json['sending_state'];
    final scheduling = json['scheduling_state'];
    return TgMessage(
      id: id,
      chatId: chatId,
      date: DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true),
      outgoing: json['is_outgoing'] == true,
      content: TgContent.parse(json['content']),
      senderId: senderId,
      replyToId: replyId == null || replyId == 0 ? null : replyId,
      editedAt: edit == null || edit == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(edit * 1000, isUtc: true),
      reactions: counts,
      myReactions: mine,
      sendState: state is Map
          ? (state['@type'] == 'messageSendingStateFailed'
                ? TgSendState.failed
                : TgSendState.sending)
          : TgSendState.sent,
      scheduled: scheduling is Map,
    );
  }
}

class TgChat {
  TgChat({
    required this.id,
    required this.title,
    required this.kind,
    this.userId = 0,
    this.unread = 0,
    this.canPost = true,
    this.lastMessage,
    this.orders = const {},
    this.pinned = false,
    this.muted = false,
  });

  final int id;
  String title;
  final TgChatKind kind;

  /// The other person in a private chat.
  final int userId;
  int unread;
  bool canPost;
  TgMessage? lastMessage;
  bool muted;
  bool pinned;

  /// Sort key per chat list: `main`, `archive` or `folder:<id>`; a chat is
  /// in a list when it has a (non-zero) order there.
  Map<String, int> orders;

  static TgChat? parse(Object? json, {required int selfUserId}) {
    if (json is! Map) return null;
    final id = tdInt(json['id']);
    if (id == null) return null;
    final type = json['type'];
    var kind = TgChatKind.other;
    var userId = 0;
    if (type is Map) {
      switch (type['@type']) {
        case 'chatTypePrivate':
          userId = tdInt(type['user_id']) ?? 0;
          kind = userId == selfUserId && selfUserId != 0
              ? TgChatKind.saved
              : TgChatKind.private;
        case 'chatTypeBasicGroup':
          kind = TgChatKind.group;
        case 'chatTypeSupergroup':
          kind = type['is_channel'] == true
              ? TgChatKind.channel
              : TgChatKind.group;
        case 'chatTypeSecret':
          kind = TgChatKind.secret;
      }
    }
    final permissions = json['permissions'];
    final chat = TgChat(
      id: id,
      title: tdText(json['title'], maxTelegramNameChars),
      kind: kind,
      userId: userId,
      unread: tdInt(json['unread_count']) ?? 0,
      canPost: kind == TgChatKind.channel
          ? false
          : (permissions is Map
                ? permissions['can_send_basic_messages'] != false
                : true),
      lastMessage: TgMessage.parse(json['last_message']),
      muted: _muted(json['notification_settings']),
    );
    final positions = json['positions'];
    if (positions is List) {
      for (final position in positions.take(64)) {
        chat.applyPosition(position);
      }
    }
    return chat;
  }

  static bool _muted(Object? settings) =>
      settings is Map && (tdInt(settings['mute_for']) ?? 0) > 0;

  /// The list key of a TDLib `ChatList` object, or null for one not shown.
  static String? listKey(Object? list) {
    if (list is! Map) return null;
    return switch (list['@type']) {
      'chatListMain' => 'main',
      'chatListArchive' => 'archive',
      'chatListFolder' => 'folder:${tdInt(list['chat_folder_id']) ?? 0}',
      _ => null,
    };
  }

  void applyPosition(Object? position) {
    if (position is! Map) return;
    final key = listKey(position['list']);
    if (key == null) return;
    final order = tdInt(position['order']) ?? 0;
    orders = Map.of(orders);
    if (order == 0) {
      orders.remove(key);
    } else {
      orders[key] = order;
      if (key == 'main') pinned = position['is_pinned'] == true;
    }
  }
}

/// A chat folder (a filter): chats in it have an order in `folder:<id>`.
class TgFolder {
  const TgFolder(this.id, this.title);
  final int id;
  final String title;

  String get key => 'folder:$id';

  static TgFolder? parse(Object? json) {
    if (json is! Map) return null;
    final id = tdInt(json['id']);
    if (id == null) return null;
    final name = json['title'];
    final title = name is Map
        ? tdText(name['text'] is Map ? name['text']['text'] : name['text'], 64)
        : tdText(name, 64);
    return TgFolder(id, title.isEmpty ? 'Folder' : title);
  }
}

/// A message advertisers paid for in a channel. Telegram's terms require
/// showing these in channels, marked as sponsored.
class TgSponsored {
  const TgSponsored({
    required this.id,
    required this.title,
    required this.text,
    this.url = '',
    this.buttonText = '',
  });

  final int id;
  final String title;
  final String text;
  final String url;
  final String buttonText;

  static TgSponsored? parse(Object? json) {
    if (json is! Map) return null;
    final id = tdInt(json['message_id']) ?? tdInt(json['id']) ?? 0;
    final content = TgContent.parse(json['content']);
    final sponsor = json['sponsor'];
    var url = '';
    if (sponsor is Map && sponsor['url'] is String) {
      url = tdText(sponsor['url'], 2048);
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
      url = '';
    }
    return TgSponsored(
      id: id,
      title: tdText(json['title'], 128),
      text: content.text,
      url: url,
      buttonText: tdText(json['button_text'], 64),
    );
  }
}
