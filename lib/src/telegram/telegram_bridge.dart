import 'dart:async';

import 'telegram_models.dart';

/// Which Telegram chats this device relays to the account's other devices
/// (M30 bridge): Saved Messages and chats the user chose. Only message
/// text goes, never the login session, the database key or any file.
class TelegramBridgeSettings {
  TelegramBridgeSettings({this.savedMessages = false, Set<int>? chats})
    : chats = chats ?? <int>{};

  static const int maxChats = 50;

  bool savedMessages;
  final Set<int> chats;

  bool get any => savedMessages || chats.isNotEmpty;

  bool relays(TgChat chat) =>
      chat.kind == TgChatKind.saved ? savedMessages : chats.contains(chat.id);

  /// Adds or removes [chatId]; false when the limit is reached.
  bool setChat(int chatId, bool on) {
    if (!on) {
      chats.remove(chatId);
      return true;
    }
    if (chats.length >= maxChats && !chats.contains(chatId)) return false;
    chats.add(chatId);
    return true;
  }

  Map<String, Object?> toJson() => {
    'saved': savedMessages,
    'chats': chats.toList(),
  };

  static TelegramBridgeSettings fromJson(Object? json) {
    final settings = TelegramBridgeSettings();
    if (json is! Map) return settings;
    settings.savedMessages = json['saved'] == true;
    final chats = json['chats'];
    if (chats is List) {
      for (final id in chats.take(maxChats)) {
        if (id is int) settings.chats.add(id);
      }
    }
    return settings;
  }
}

const int maxBridgeTextChars = 4000;

/// The event relayed to other devices for a live message in a relayed chat,
/// or null when it is not to be relayed.
Map<String, Object?>? bridgeEventFor({
  required TgMessage message,
  required TgChat chat,
  required String chatTitle,
  required String from,
  required TelegramBridgeSettings settings,
}) {
  if (!settings.relays(chat)) return null;
  final content = message.content;
  if (content.kind == TgContentKind.deleted) return null;
  var text = content.text;
  if (text.isEmpty) {
    // Files and other content are not relayed: a note says so.
    text = switch (content.kind) {
      TgContentKind.text => '',
      _ => '[${content.kind.name}]',
    };
  }
  if (text.isEmpty) return null;
  if (text.length > maxBridgeTextChars) {
    text = text.substring(0, maxBridgeTextChars);
  }
  return {
    'type': 'tgx',
    'chat': '${chat.id}',
    'id': '${message.id}',
    'title': chatTitle.length > maxTelegramNameChars
        ? chatTitle.substring(0, maxTelegramNameChars)
        : chatTitle,
    'saved': chat.kind == TgChatKind.saved,
    'from': from.length > 100 ? from.substring(0, 100) : from,
    'out': message.outgoing,
    'text': text,
    'at': message.date.toUtc().toIso8601String(),
  };
}

/// A relayed message on a device that has no Telegram access of its own.
class BridgedMessage {
  const BridgedMessage({
    required this.id,
    required this.from,
    required this.text,
    required this.at,
    required this.outgoing,
  });

  final String id;
  final String from;
  final String text;
  final DateTime at;
  final bool outgoing;
}

class BridgedChat {
  BridgedChat({
    required this.id,
    required this.title,
    this.saved = false,
    List<BridgedMessage>? messages,
    this.unread = 0,
  }) : messages = messages ?? [];

  final String id;
  String title;
  bool saved;
  final List<BridgedMessage> messages;
  int unread;
}

/// Messages relayed from the account's other devices, kept bounded and
/// read-only: this device cannot answer through Telegram (it has no
/// session), and nothing it holds can be used to sign in.
class TelegramBridgeInbox {
  TelegramBridgeInbox({Map<String, BridgedChat>? chats}) : chats = chats ?? {};

  static const int maxChats = 100;
  static const int maxMessagesPerChat = 200;

  final Map<String, BridgedChat> chats;

  /// Takes a `tgx` [event]; true if it changed anything.
  bool accept(Map<String, dynamic> event) {
    final chatId = event['chat'];
    final id = event['id'];
    final text = event['text'];
    final at = DateTime.tryParse(event['at'] is String ? event['at'] : '');
    if (chatId is! String ||
        !RegExp(r'^-?\d{1,20}$').hasMatch(chatId) ||
        id is! String ||
        !RegExp(r'^\d{1,20}$').hasMatch(id) ||
        text is! String ||
        text.isEmpty ||
        text.length > maxBridgeTextChars ||
        at == null) {
      return false;
    }
    var chat = chats[chatId];
    if (chat == null) {
      if (chats.length >= maxChats) return false;
      chat = chats[chatId] = BridgedChat(id: chatId, title: '');
    }
    if (chat.messages.any((m) => m.id == id)) return false;
    final title = event['title'];
    if (title is String && title.isNotEmpty) {
      chat.title = tdText(title, maxTelegramNameChars);
    }
    chat.saved = event['saved'] == true;
    final outgoing = event['out'] == true;
    final now = DateTime.now().toUtc();
    chat.messages.add(
      BridgedMessage(
        id: id,
        from: tdText(event['from'], 100),
        text: text,
        // No time from another device's clock lies ahead of this one's.
        at: at.isAfter(now) ? now : at.toUtc(),
        outgoing: outgoing,
      ),
    );
    chat.messages.sort((a, b) => a.at.compareTo(b.at));
    while (chat.messages.length > maxMessagesPerChat) {
      chat.messages.removeAt(0);
    }
    if (!outgoing) chat.unread++;
    return true;
  }

  Map<String, Object?> toJson() => {
    'chats': [
      for (final chat in chats.values)
        {
          'id': chat.id,
          'title': chat.title,
          'saved': chat.saved,
          'unread': chat.unread,
          'messages': [
            for (final m in chat.messages)
              {
                'id': m.id,
                'from': m.from,
                'text': m.text,
                'at': m.at.toIso8601String(),
                'out': m.outgoing,
              },
          ],
        },
    ],
  };

  static TelegramBridgeInbox fromJson(Object? json) {
    final inbox = TelegramBridgeInbox();
    if (json is! Map || json['chats'] is! List) return inbox;
    for (final raw in (json['chats'] as List).take(maxChats)) {
      if (raw is! Map || raw['id'] is! String || raw['messages'] is! List) {
        continue;
      }
      final chat = BridgedChat(
        id: raw['id'] as String,
        title: tdText(raw['title'], maxTelegramNameChars),
        saved: raw['saved'] == true,
        unread: raw['unread'] is int ? raw['unread'] as int : 0,
      );
      for (final m in (raw['messages'] as List).take(maxMessagesPerChat)) {
        if (m is! Map ||
            m['id'] is! String ||
            m['text'] is! String ||
            DateTime.tryParse('${m['at']}') == null) {
          continue;
        }
        chat.messages.add(
          BridgedMessage(
            id: m['id'] as String,
            from: tdText(m['from'], 100),
            text: tdText(m['text'], maxBridgeTextChars),
            at: DateTime.parse('${m['at']}').toUtc(),
            outgoing: m['out'] == true,
          ),
        );
      }
      inbox.chats[chat.id] = chat;
    }
    return inbox;
  }
}

/// Gathers relayed messages and sends them to the other devices in batches:
/// one sync envelope for a burst, not one per message. A batch is sent
/// after [delay], or at once when it reaches [maxItems] or [maxChars].
class TelegramBridgeBatcher {
  TelegramBridgeBatcher({
    required this.send,
    this.delay = const Duration(seconds: 4),
    this.maxItems = 20,
    this.maxChars = 32 * 1024,
    this.maxPending = 200,
    Timer Function(Duration, void Function())? timer,
  }) : _timer = timer ?? Timer.new;

  /// Takes one `tgx` event with an `items` list.
  final void Function(Map<String, Object?> batch) send;
  final Duration delay;
  final int maxItems;
  final int maxChars;

  /// Most messages waiting at once; the oldest are dropped past it.
  final int maxPending;

  /// Most items taken from one received batch.
  static const int maxReceivedItems = 50;
  final Timer Function(Duration, void Function()) _timer;

  final List<Map<String, Object?>> _items = [];
  int _chars = 0;
  Timer? _scheduled;

  int get pending => _items.length;

  void add(Map<String, Object?> event) {
    final size = (event['text'] as String? ?? '').length + 300;
    _items.add(event);
    _chars += size;
    while (_items.length > maxPending) {
      final dropped = _items.removeAt(0);
      _chars -= (dropped['text'] as String? ?? '').length + 300;
    }
    if (_items.length >= maxItems || _chars >= maxChars) {
      flush();
    } else {
      _scheduled ??= _timer(delay, flush);
    }
  }

  void flush() {
    _scheduled?.cancel();
    _scheduled = null;
    while (_items.isNotEmpty) {
      final batch = <Map<String, Object?>>[];
      var chars = 0;
      while (_items.isNotEmpty &&
          batch.length < maxItems &&
          (batch.isEmpty ||
              chars + _items.first.toString().length < maxChars)) {
        final item = _items.removeAt(0);
        chars += item.toString().length;
        batch.add(item);
      }
      send({'type': 'tgx', 'items': batch});
    }
    _chars = 0;
  }

  void dispose() {
    _scheduled?.cancel();
    _scheduled = null;
    _items.clear();
    _chars = 0;
  }
}
