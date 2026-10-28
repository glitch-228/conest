import 'dart:async';

import 'package:flutter/foundation.dart';

import 'discord_api.dart';

const int maxDiscordGuilds = 200;
const int maxDiscordChannels = 1000;
const int maxDiscordMessages = 200;
const int maxDiscordTextChars = 4000;

String _text(Object? value, int limit) {
  if (value is! String) return '';
  return value.length <= limit ? value : value.substring(0, limit);
}

class DcGuild {
  const DcGuild(this.id, this.name);
  final String id;
  final String name;
}

enum DcChannelKind { text, announcement, dm, groupDm }

class DcChannel {
  const DcChannel({
    required this.id,
    required this.name,
    required this.kind,
    this.guildId,
    this.lastMessageId,
  });

  final String id;
  final String name;
  final DcChannelKind kind;
  final String? guildId;
  final String? lastMessageId;
}

class DcMessage {
  const DcMessage({
    required this.id,
    required this.channelId,
    required this.authorId,
    required this.author,
    required this.text,
    required this.at,
    this.edited = false,
    this.replyToId,
    this.attachments = const [],
    this.reactions = const {},
  });

  final String id;
  final String channelId;
  final String authorId;
  final String author;
  final String text;
  final DateTime at;
  final bool edited;
  final String? replyToId;

  /// File names and links; only https links are kept.
  final List<({String name, String url})> attachments;
  final Map<String, int> reactions;

  static DcMessage? parse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final channel = json['channel_id'];
    final author = json['author'];
    if (id is! String ||
        !isDiscordId(id) ||
        channel is! String ||
        !isDiscordId(channel) ||
        author is! Map ||
        author['id'] is! String) {
      return null;
    }
    final stamp = json['timestamp'] is String
        ? DateTime.tryParse(json['timestamp'] as String)
        : null;
    final ref = json['message_reference'];
    final files = <({String name, String url})>[];
    final attachments = json['attachments'];
    if (attachments is List) {
      for (final file in attachments.take(10)) {
        if (file is! Map) continue;
        final url = _text(file['url'], 2048);
        final uri = Uri.tryParse(url);
        if (uri == null || uri.scheme != 'https') continue;
        files.add((name: _text(file['filename'], 255), url: url));
      }
    }
    final reactions = <String, int>{};
    final reacted = json['reactions'];
    if (reacted is List) {
      for (final entry in reacted.take(20)) {
        if (entry is! Map || entry['emoji'] is! Map) continue;
        final name = _text((entry['emoji'] as Map)['name'], 32);
        final count = entry['count'];
        if (name.isNotEmpty && count is int && count > 0) {
          reactions[name] = count;
        }
      }
    }
    return DcMessage(
      id: id,
      channelId: channel,
      authorId: author['id'] as String,
      author: _text(author['global_name'] ?? author['username'], 64),
      text: _text(json['content'], maxDiscordTextChars),
      at: stamp?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      edited: json['edited_timestamp'] != null,
      replyToId: ref is Map && ref['message_id'] is String
          ? ref['message_id'] as String
          : null,
      attachments: files,
      reactions: reactions,
    );
  }
}

/// A Discord client with the user's own account token, the way third-party
/// clients work (and against Discord's terms, which the user has been told).
/// It is slow and quiet on purpose: it asks Discord for things when the
/// user opens a screen or a channel, polls only the channel that is open,
/// and never sends, edits, deletes or reacts unless the user does that. It
/// never joins servers, sends friend requests or does anything by itself.
class DiscordClient extends ChangeNotifier {
  DiscordClient({
    required this.api,
    this.pollInterval = const Duration(seconds: 6),
    Future<void> Function(Duration delay)? wait,
    this.log,
  }) : _wait = wait ?? Future<void>.delayed;

  final DiscordApi api;
  final Duration pollInterval;
  final Future<void> Function(Duration delay) _wait;
  final void Function(String line)? log;

  String selfId = '';
  String selfName = '';
  bool signedIn = false;
  String? error;

  List<DcGuild> guilds = const [];
  final Map<String, List<DcChannel>> _guildChannels = {};
  List<DcChannel> dms = const [];
  final Map<String, List<DcMessage>> _messages = {};
  final Map<String, int> _polling = {};
  bool _closed = false;

  List<DcChannel> channelsOf(String guildId) =>
      _guildChannels[guildId] ?? const [];

  List<DcMessage> messagesOf(String channelId) =>
      _messages[channelId] ?? const [];

  /// Signs in with the token the API was made with, and loads the account's
  /// servers and direct messages.
  Future<void> start() async {
    try {
      final me = await api.call('GET', '/users/@me');
      if (me is! Map || me['id'] is! String || me['bot'] == true) {
        throw StateError('That is not a user account token.');
      }
      selfId = me['id'] as String;
      selfName = _text(me['global_name'] ?? me['username'], 64);
      signedIn = true;
      error = null;
      notifyListeners();
      await refreshLists();
    } on DiscordException catch (e) {
      signedIn = false;
      error = e.unauthorized
          ? 'Discord does not accept that token.'
          : e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> refreshLists() async {
    final found = await api.call('GET', '/users/@me/guilds');
    if (found is List) {
      guilds = [
        for (final guild in found.take(maxDiscordGuilds))
          if (guild is Map &&
              guild['id'] is String &&
              isDiscordId(guild['id'] as String))
            DcGuild(guild['id'] as String, _text(guild['name'], 100)),
      ];
    }
    final direct = await api.call('GET', '/users/@me/channels');
    if (direct is List) {
      dms = [
        for (final channel in direct.take(maxDiscordChannels))
          ?_channel(channel),
      ]..sort((a, b) => _newerId(b.lastMessageId, a.lastMessageId));
    }
    notifyListeners();
  }

  static int _newerId(String? a, String? b) {
    final x = a == null ? BigInt.zero : (BigInt.tryParse(a) ?? BigInt.zero);
    final y = b == null ? BigInt.zero : (BigInt.tryParse(b) ?? BigInt.zero);
    return x.compareTo(y);
  }

  DcChannel? _channel(Object? json, {String? guildId}) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || !isDiscordId(id)) return null;
    final kind = switch (json['type']) {
      0 => DcChannelKind.text,
      5 => DcChannelKind.announcement,
      1 => DcChannelKind.dm,
      3 => DcChannelKind.groupDm,
      _ => null,
    };
    if (kind == null) return null;
    var name = _text(json['name'], 100);
    if (name.isEmpty && json['recipients'] is List) {
      name = [
        for (final r in (json['recipients'] as List).take(10))
          if (r is Map) _text(r['global_name'] ?? r['username'], 64),
      ].where((n) => n.isNotEmpty).join(', ');
    }
    return DcChannel(
      id: id,
      name: name,
      kind: kind,
      guildId: guildId,
      lastMessageId: json['last_message_id'] is String
          ? json['last_message_id'] as String
          : null,
    );
  }

  /// Loads a server's text channels when the user opens it.
  Future<void> loadChannels(String guildId) async {
    final found = await api.call('GET', '/guilds/$guildId/channels');
    if (found is List) {
      _guildChannels[guildId] = [
        for (final channel in found.take(maxDiscordChannels))
          ?_channel(channel, guildId: guildId),
      ];
      notifyListeners();
    }
  }

  /// Loads the newest page of a channel, or an older page.
  Future<void> loadMessages(String channelId, {bool older = false}) async {
    final list = _messages[channelId] ?? const <DcMessage>[];
    final found = await api.call(
      'GET',
      '/channels/$channelId/messages',
      query: {
        'limit': '50',
        if (older && list.isNotEmpty) 'before': list.first.id,
      },
    );
    if (found is! List) return;
    _merge(channelId, found);
  }

  void _merge(String channelId, List found) {
    final byId = {
      for (final m in _messages[channelId] ?? const <DcMessage>[]) m.id: m,
    };
    for (final json in found.take(100)) {
      final message = DcMessage.parse(json);
      if (message != null && message.channelId == channelId) {
        byId[message.id] = message;
      }
    }
    final merged = byId.values.toList()..sort((a, b) => _newerId(a.id, b.id));
    while (merged.length > maxDiscordMessages) {
      merged.removeAt(0);
    }
    _messages[channelId] = merged;
    notifyListeners();
  }

  /// Starts looking for new messages in [channelId] while the user has it
  /// open. Returns a function that stops it.
  void Function() watch(String channelId) {
    _polling[channelId] = (_polling[channelId] ?? 0) + 1;
    if (_polling[channelId] == 1) unawaited(_watchLoop(channelId));
    var stopped = false;
    return () {
      if (stopped) return;
      stopped = true;
      final left = (_polling[channelId] ?? 1) - 1;
      if (left <= 0) {
        _polling.remove(channelId);
      } else {
        _polling[channelId] = left;
      }
    };
  }

  Future<void> _watchLoop(String channelId) async {
    var failures = 0;
    while (!_closed && (_polling[channelId] ?? 0) > 0) {
      try {
        // The newest page again, not only what is after the last message:
        // edits, deletions and reactions by others show up in it.
        final found = await api.call(
          'GET',
          '/channels/$channelId/messages',
          query: {'limit': '50'},
        );
        failures = 0;
        if (found is List) _refreshWindow(channelId, found);
        await _wait(pollInterval);
      } on DiscordException catch (e) {
        failures++;
        // Losing access for good is not one bad answer: give up only after
        // several in a row.
        if ((e.unauthorized || e.forbidden) && failures >= 3) {
          error = e.toString();
          notifyListeners();
          return;
        }
        await _wait(
          e.retryAfter != null
              ? Duration(milliseconds: (e.retryAfter! * 1000).ceil())
              : pollInterval * (1 << (failures > 4 ? 4 : failures)),
        );
      } catch (_) {
        failures++;
        await _wait(pollInterval * (1 << (failures > 4 ? 4 : failures)));
      }
    }
  }

  /// Merges the newest page [found] and drops the messages inside its time
  /// span that Discord no longer lists (deleted by someone).
  void _refreshWindow(String channelId, List found) {
    final ids = <String>{};
    BigInt? oldest;
    for (final json in found.take(100)) {
      final message = DcMessage.parse(json);
      if (message == null || message.channelId != channelId) continue;
      ids.add(message.id);
      final n = BigInt.tryParse(message.id);
      if (n != null && (oldest == null || n < oldest)) oldest = n;
    }
    final list = _messages[channelId];
    if (list != null && oldest != null) {
      // A page shorter than asked reaches back to the first message.
      final wholeChannel = found.length < 50;
      list.removeWhere((m) {
        final n = BigInt.tryParse(m.id);
        return n != null &&
            (wholeChannel || n >= oldest!) &&
            !ids.contains(m.id);
      });
    }
    _merge(channelId, found);
  }

  // Everything below happens only because the user did it.

  Future<void> send(String channelId, String text, {String? replyTo}) async {
    final out = text.trim();
    if (out.isEmpty) return;
    if (out.length > 2000) {
      throw ArgumentError('Discord messages are at most 2000 characters.');
    }
    final sent = await api.call(
      'POST',
      '/channels/$channelId/messages',
      body: {
        'content': out,
        'allowed_mentions': {
          'parse': <String>['users'],
        },
        if (replyTo != null) 'message_reference': {'message_id': replyTo},
      },
    );
    if (sent is Map) _merge(channelId, [sent]);
  }

  Future<void> edit(String channelId, String messageId, String text) async {
    final message = messagesOf(
      channelId,
    ).where((m) => m.id == messageId).firstOrNull;
    if (message == null || message.authorId != selfId) {
      throw StateError('Only your own messages can be edited.');
    }
    final changed = await api.call(
      'PATCH',
      '/channels/$channelId/messages/$messageId',
      body: {'content': text.trim()},
    );
    if (changed is Map) _merge(channelId, [changed]);
  }

  Future<void> delete(String channelId, String messageId) async {
    await api.call('DELETE', '/channels/$channelId/messages/$messageId');
    final list = _messages[channelId];
    list?.removeWhere((m) => m.id == messageId);
    notifyListeners();
  }

  Future<void> react(String channelId, String messageId, String emoji) async {
    final encoded = Uri.encodeComponent(emoji);
    await api.call(
      'PUT',
      '/channels/$channelId/messages/$messageId/reactions/$encoded/@me',
    );
    await loadMessages(channelId);
  }

  void closeClient() {
    _closed = true;
    _polling.clear();
    api.close();
  }

  @override
  void dispose() {
    closeClient();
    super.dispose();
  }
}
