import 'dart:async';

import 'package:conest/src/telegram/telegram_bot_api.dart';

/// A Telegram Bot API in memory: bots with tokens, long polling, bot-to-bot
/// messages (only between bots that switched it on), 401/409/429 errors.
class FakeTelegramBots {
  final Map<String, FakeBot> _byToken = {};
  final Map<String, FakeBot> _byUsername = {};
  int _nextBotId = 1000000001;

  /// Every call made, `token-prefix method`.
  final List<String> calls = [];

  FakeBot addBot(String username, {bool botToBot = true}) {
    final id = _nextBotId++;
    final token = '$id:AAFakeTokenFakeTokenFakeTokenFake${id % 1000}';
    final bot = FakeBot(this, id, username.toLowerCase(), token)
      ..botToBot = botToBot;
    _byToken[token] = bot;
    _byUsername[bot.username] = bot;
    return bot;
  }

  /// The network to give the app.
  TelegramNetwork get network =>
      TelegramNetwork(botApi: (token) => _FakeBotApi(this, token));
}

class FakeBot {
  FakeBot(this.hub, this.id, this.username, this.token);

  final FakeTelegramBots hub;
  final int id;
  final String username;
  final String token;
  bool botToBot = true;
  bool revoked = false;

  /// Messages this bot sent, `to text`.
  final List<(String, String)> sent = [];
  final List<Map<String, Object?>> _updates = [];
  int _nextUpdate = 1;
  Completer<void>? _wake;
  int pollers = 0;

  /// Errors to answer the next calls with (consumed in order).
  final List<TelegramBotException> failNext = [];

  /// A message from an arbitrary user or bot arrives.
  void deliver({
    required int fromId,
    required bool isBot,
    String? fromUsername,
    required String text,
    String chatType = 'private',
  }) {
    _updates.add({
      'update_id': _nextUpdate++,
      'message': {
        'message_id': _nextUpdate,
        'from': {
          'id': fromId,
          'is_bot': isBot,
          if (fromUsername != null) 'username': fromUsername,
        },
        'chat': {'id': fromId, 'type': chatType},
        'text': text,
      },
    });
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }
}

class _FakeBotApi implements TelegramBotApi {
  _FakeBotApi(this.hub, this.token);

  final FakeTelegramBots hub;
  final String token;
  bool _closed = false;

  FakeBot _bot(String method) {
    final bot = hub._byToken[token];
    if (bot == null || bot.revoked) {
      throw TelegramBotException(method, 401, 'Unauthorized');
    }
    return bot;
  }

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    hub.calls.add('${token.split(':').first} $method');
    final bot = _bot(method);
    if (bot.failNext.isNotEmpty) throw bot.failNext.removeAt(0);
    switch (method) {
      case 'getMe':
        return {
          'id': bot.id,
          'is_bot': true,
          'username': bot.username,
          'first_name': 'Fake',
        };
      case 'getUpdates':
        final offset = parameters['offset'] as int? ?? 0;
        bot._updates.removeWhere((u) => (u['update_id'] as int) < offset);
        if (bot._updates.isEmpty && !_closed) {
          bot.pollers++;
          if (bot.pollers > 1) {
            bot.pollers--;
            throw const TelegramBotException(
              'getUpdates',
              409,
              'Conflict: terminated by other getUpdates request',
            );
          }
          final wake = bot._wake = Completer<void>();
          try {
            await wake.future.timeout(
              Duration(seconds: (parameters['timeout'] as int?) ?? 0),
              onTimeout: () {},
            );
          } finally {
            bot.pollers--;
            bot._wake = null;
          }
        }
        return List<Map<String, Object?>>.of(bot._updates);
      case 'sendMessage':
        final chat = parameters['chat_id'] as String;
        final text = parameters['text'] as String;
        if (text.length > 4096) {
          throw const TelegramBotException(
            'sendMessage',
            400,
            'message is too long',
          );
        }
        final target = chat.startsWith('@')
            ? hub._byUsername[chat.substring(1).toLowerCase()]
            : null;
        if (target == null) {
          throw const TelegramBotException(
            'sendMessage',
            400,
            'chat not found',
          );
        }
        if (!bot.botToBot || !target.botToBot) {
          throw const TelegramBotException(
            'sendMessage',
            403,
            'Forbidden: bots can\'t send messages to bots',
          );
        }
        bot.sent.add((target.username, text));
        target.deliver(
          fromId: bot.id,
          isBot: true,
          fromUsername: bot.username,
          text: text,
        );
        return {'message_id': 1};
    }
    throw TelegramBotException(method, 404, 'Not Found');
  }

  @override
  void close() => _closed = true;
}
