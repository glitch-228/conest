import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'td_engine.dart';
import 'telegram_api_keys.dart';
import 'telegram_models.dart';
import 'telegram_mods.dart';

/// Where sign-in stands, following TDLib's authorization states.
enum TgAuth {
  /// Not started, or TDLib is starting.
  starting,
  waitPhone,
  waitCode,
  waitPassword,

  /// The number has no Telegram account. Conest only logs in; it does not
  /// sign people up.
  noAccount,

  /// A QR code is shown for another Telegram app to scan.
  waitQr,
  ready,
  loggedOut,
  closed,
}

/// A Telegram client over TDLib, the way other third-party clients are
/// built: chats, history, sending, files, reactions, folders. It signs in
/// with a phone number (code, then the 2FA password) or a QR code, never
/// signs up, and shows the sponsored messages Telegram requires in
/// channels. The login session lives in TDLib's own database on this
/// device, encrypted with a key kept in the vault, and is never copied to
/// other devices.
class TelegramClient extends ChangeNotifier {
  TelegramClient({
    required this.engine,
    required this.keys,
    required this.databaseDirectory,
    required this.filesDirectory,
    required this.databaseKey,
    TelegramMods? mods,
    this.languageCode = 'en',
    this.log,
  }) : mods = mods ?? TelegramMods();

  final TdEngine engine;
  final TelegramApiKeys keys;
  final String databaseDirectory;
  final String filesDirectory;

  /// Base64 of the 32 random bytes that encrypt TDLib's database.
  final String databaseKey;
  final TelegramMods mods;
  final String languageCode;
  final void Function(String line)? log;

  TgAuth auth = TgAuth.starting;

  /// The tg://login link for the QR code while [auth] is waitQr.
  String? qrLink;

  /// Why the last sign-in step failed, in Telegram's words.
  String? authError;
  int selfUserId = 0;
  String selfName = '';

  final Map<int, TgChat> chats = {};
  final Map<int, List<TgMessage>> _messages = {};
  final Map<int, String> userNames = {};
  List<TgFolder> folders = const [];
  final Map<int, TgFile> files = {};
  StreamSubscription<Map<String, dynamic>>? _subscription;
  bool _closed = false;
  final Set<int> _fullyLoaded = {};

  /// Messages of [chatId], oldest first, without those mods hide.
  List<TgMessage> messagesOf(int chatId) => [
    for (final message in _messages[chatId] ?? const <TgMessage>[])
      if (!mods.hidden(message)) message,
  ];

  /// Whether [chatId]'s whole history is loaded.
  bool historyComplete(int chatId) => _fullyLoaded.contains(chatId);

  /// The chats of a list (`main`, `archive`, `folder:<id>`), newest first.
  List<TgChat> chatList([String list = 'main']) {
    final shown = [
      for (final chat in chats.values)
        if (chat.orders.containsKey(list)) chat,
    ]..sort((a, b) => b.orders[list]!.compareTo(a.orders[list]!));
    return shown;
  }

  String nameOf(int userId) => userNames[userId] ?? '';

  /// Starts TDLib. Sign-in then proceeds through [auth].
  Future<void> start() async {
    _subscription = engine.updates.listen((update) {
      try {
        _onUpdate(update);
      } catch (error) {
        log?.call('Telegram: update ${update['@type']} not taken: $error');
      }
    });
    // The first request makes TDLib report its authorization state.
    unawaited(
      engine
          .send({'@type': 'getOption', 'name': 'version'})
          .then<void>((_) {})
          .catchError((Object error) {
            log?.call('Telegram: start failed: $error');
          }),
    );
  }

  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    await engine.close();
  }

  void _set(TgAuth next) {
    auth = next;
    notifyListeners();
  }

  // Sign-in.

  Future<void> _sendParameters() async {
    try {
      await _tdlibParameters();
    } catch (error) {
      authError = '$error';
      notifyListeners();
    }
  }

  Future<void> _sendEncryptionKey() async {
    try {
      await engine.send({
        '@type': 'checkDatabaseEncryptionKey',
        'encryption_key': databaseKey,
      });
    } catch (error) {
      authError = '$error';
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _tdlibParameters() => engine.send({
    '@type': 'setTdlibParameters',
    'use_test_dc': false,
    'database_directory': databaseDirectory,
    'files_directory': filesDirectory,
    'database_encryption_key': databaseKey,
    'use_file_database': true,
    'use_chat_info_database': true,
    'use_message_database': true,
    'use_secret_chats': false,
    'api_id': keys.apiId,
    'api_hash': keys.apiHash,
    'system_language_code': languageCode,
    'device_model': 'Conest (unofficial Telegram client)',
    'system_version': 'Conest',
    'application_version': 'Conest',
  });

  Future<void> _authStep(Map<String, Object?> request) async {
    authError = null;
    try {
      await engine.send(request);
    } on TdError catch (error) {
      authError = error.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> submitPhone(String phone) => _authStep({
    '@type': 'setAuthenticationPhoneNumber',
    'phone_number': phone.trim(),
  });

  Future<void> submitCode(String code) =>
      _authStep({'@type': 'checkAuthenticationCode', 'code': code.trim()});

  Future<void> submitPassword(String password) =>
      _authStep({'@type': 'checkAuthenticationPassword', 'password': password});

  Future<void> requestQrLogin() => _authStep({
    '@type': 'requestQrCodeAuthentication',
    'other_user_ids': <int>[],
  });

  /// Ends the session on Telegram's side and clears TDLib's database here.
  Future<void> logOut() async {
    await engine.send({'@type': 'logOut'});
  }

  // Updates.

  void _onUpdate(Map<String, dynamic> update) {
    switch (update['@type']) {
      case 'updateAuthorizationState':
        _onAuthState(update['authorization_state']);
      case 'updateNewChat':
        _putChat(update['chat']);
      case 'updateChatTitle':
        final chat = chats[tdInt(update['chat_id'])];
        if (chat != null) {
          chat.title = tdText(update['title'], maxTelegramNameChars);
          notifyListeners();
        }
      case 'updateChatLastMessage':
        final chat = chats[tdInt(update['chat_id'])];
        if (chat != null) {
          chat.lastMessage = TgMessage.parse(update['last_message']);
          for (final position in _list(update['positions'])) {
            chat.applyPosition(position);
          }
          notifyListeners();
        }
      case 'updateChatPosition':
        final chat = chats[tdInt(update['chat_id'])];
        if (chat != null) {
          chat.applyPosition(update['position']);
          notifyListeners();
        }
      case 'updateChatReadInbox':
        final chat = chats[tdInt(update['chat_id'])];
        if (chat != null) {
          chat.unread = tdInt(update['unread_count']) ?? chat.unread;
          notifyListeners();
        }
      case 'updateChatNotificationSettings':
        final chat = chats[tdInt(update['chat_id'])];
        if (chat != null) {
          chat.muted = TgChat.parse({
            'id': chat.id,
            'notification_settings': update['notification_settings'],
          }, selfUserId: selfUserId)!.muted;
          notifyListeners();
        }
      case 'updateChatFolders':
        folders = [
          for (final folder in _list(update['chat_folders']).take(64))
            ?TgFolder.parse(folder),
        ];
        notifyListeners();
      case 'updateUser':
        _putUser(update['user']);
      case 'updateNewMessage':
        final message = TgMessage.parse(update['message']);
        if (message != null) _addMessage(message);
      case 'updateMessageContent':
        _changeMessage(
          tdInt(update['chat_id']),
          tdInt(update['message_id']),
          (message) =>
              message.copyWith(content: TgContent.parse(update['new_content'])),
        );
      case 'updateMessageEdited':
        final date = tdInt(update['edit_date']);
        _changeMessage(
          tdInt(update['chat_id']),
          tdInt(update['message_id']),
          (message) => message.copyWith(
            editedAt: date == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true),
          ),
        );
      case 'updateMessageInteractionInfo':
        final (counts, mine) = TgMessage.parseReactions(
          update['interaction_info'],
        );
        _changeMessage(
          tdInt(update['chat_id']),
          tdInt(update['message_id']),
          (message) => message.copyWith(reactions: counts, myReactions: mine),
        );
      case 'updateDeleteMessages':
        _onDeleted(update);
      case 'updateMessageSendSucceeded':
        final message = TgMessage.parse(update['message']);
        final old = tdInt(update['old_message_id']);
        if (message != null && old != null) {
          final list = _messages[message.chatId];
          list?.removeWhere((m) => m.id == old);
          _addMessage(message);
        }
      case 'updateMessageSendFailed':
        _changeMessage(
          tdInt(update['chat_id']) ??
              (update['message'] is Map
                  ? tdInt((update['message'] as Map)['chat_id'])
                  : null),
          tdInt(update['old_message_id']),
          (message) => message.copyWith(sendState: TgSendState.failed),
        );
      case 'updateFile':
        _onFile(update['file']);
    }
  }

  Iterable<Object?> _list(Object? value) =>
      value is List ? value.take(256) : const [];

  void _onAuthState(Object? state) {
    if (state is! Map) return;
    switch (state['@type']) {
      case 'authorizationStateWaitTdlibParameters':
        _set(TgAuth.starting);
        unawaited(_sendParameters());
      case 'authorizationStateWaitEncryptionKey':
        unawaited(_sendEncryptionKey());
      case 'authorizationStateWaitPhoneNumber':
        qrLink = null;
        _set(TgAuth.waitPhone);
      case 'authorizationStateWaitOtherDeviceConfirmation':
        qrLink = tdText(state['link'], 512);
        _set(TgAuth.waitQr);
      case 'authorizationStateWaitCode':
        _set(TgAuth.waitCode);
      case 'authorizationStateWaitPassword':
        _set(TgAuth.waitPassword);
      case 'authorizationStateWaitRegistration':
        // Log in only: a number without an account is not signed up here.
        _set(TgAuth.noAccount);
      case 'authorizationStateReady':
        _set(TgAuth.ready);
        unawaited(_afterReady());
      case 'authorizationStateLoggingOut':
        _set(TgAuth.loggedOut);
      case 'authorizationStateClosing':
      case 'authorizationStateClosed':
        _clear();
        _set(_closed ? TgAuth.closed : TgAuth.loggedOut);
    }
  }

  void _clear() {
    chats.clear();
    _messages.clear();
    userNames.clear();
    files.clear();
    _fullyLoaded.clear();
    folders = const [];
    selfUserId = 0;
    selfName = '';
  }

  Future<void> _afterReady() async {
    try {
      final me = await engine.send({'@type': 'getMe'});
      _putUser(me);
      selfUserId = tdInt(me['id']) ?? 0;
      selfName = nameOf(selfUserId);
      for (final list in const ['chatListMain', 'chatListArchive']) {
        await engine
            .send({
              '@type': 'loadChats',
              'chat_list': {'@type': list},
              'limit': 100,
            })
            .catchError((Object error) {
              // TDLib answers 404 once everything is loaded.
              return <String, dynamic>{};
            });
      }
      notifyListeners();
    } catch (error) {
      log?.call('Telegram: loading chats failed: $error');
    }
  }

  void _putUser(Object? user) {
    if (user is! Map) return;
    final id = tdInt(user['id']);
    if (id == null) return;
    final name = [
      tdText(user['first_name'], 100),
      tdText(user['last_name'], 100),
    ].where((part) => part.isNotEmpty).join(' ');
    if (userNames.length < 20000 || userNames.containsKey(id)) {
      userNames[id] = name;
    }
    final chat = chats.values.where((c) => c.userId == id).firstOrNull;
    if (chat != null && chat.kind == TgChatKind.private && name.isNotEmpty) {
      chat.title = name;
    }
    notifyListeners();
  }

  void _putChat(Object? json) {
    final chat = TgChat.parse(json, selfUserId: selfUserId);
    if (chat == null) return;
    if (chats.length >= maxTelegramChats && !chats.containsKey(chat.id)) {
      // Keep the most recently active chats.
      final oldest = chats.values.toList()
        ..sort(
          (a, b) => (a.orders['main'] ?? 0).compareTo(b.orders['main'] ?? 0),
        );
      chats.remove(oldest.first.id);
    }
    if (chat.kind == TgChatKind.saved && chat.title.isEmpty) {
      chat.title = 'Saved Messages';
    }
    chats[chat.id] = chat;
    notifyListeners();
  }

  void _addMessage(TgMessage message) {
    final list = _messages.putIfAbsent(message.chatId, () => []);
    final index = list.indexWhere((m) => m.id == message.id);
    if (index >= 0) {
      list[index] = message;
    } else {
      list.add(message);
      list.sort((a, b) => a.id.compareTo(b.id));
      while (list.length > maxTelegramMessagesPerChat) {
        list.removeAt(0);
      }
    }
    final chat = chats[message.chatId];
    if (chat != null &&
        (chat.lastMessage == null || message.id >= chat.lastMessage!.id)) {
      chat.lastMessage = message;
    }
    notifyListeners();
  }

  void _changeMessage(
    int? chatId,
    int? messageId,
    TgMessage Function(TgMessage message) change,
  ) {
    final list = chatId == null ? null : _messages[chatId];
    if (list == null) return;
    final index = list.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    list[index] = change(list[index]);
    final chat = chats[chatId];
    if (chat?.lastMessage?.id == messageId) chat!.lastMessage = list[index];
    notifyListeners();
  }

  void _onDeleted(Map<String, dynamic> update) {
    // Only deletions that really happened; a cache eviction is not one.
    if (update['is_permanent'] != true || update['from_cache'] == true) return;
    final chatId = tdInt(update['chat_id']);
    final list = chatId == null ? null : _messages[chatId];
    final ids = {for (final id in _list(update['message_ids'])) tdInt(id)};
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      if (!ids.contains(list[i].id)) continue;
      if (mods.deletedNotice && !list[i].outgoing) {
        // A notice only: the content is dropped, not kept.
        list[i] = list[i].copyWith(content: TgContent.deleted);
      } else {
        list.removeAt(i--);
      }
    }
    final chat = chats[chatId];
    if (chat?.lastMessage != null && ids.contains(chat!.lastMessage!.id)) {
      chat.lastMessage = list.lastOrNull;
    }
    notifyListeners();
  }

  void _onFile(Object? json) {
    if (json is! Map) return;
    final id = tdInt(json['id']);
    if (id == null) return;
    final previous = files[id];
    final next = (previous ?? TgFile(id: id)).withProgress(
      Map<String, dynamic>.from(json),
    );
    if (files.length < 2000 || previous != null) files[id] = next;
    // Messages keep a copy of the file: refresh those that show it.
    for (final list in _messages.values) {
      for (var i = 0; i < list.length; i++) {
        final file = list[i].content.file;
        if (file != null && file.id == id) {
          list[i] = list[i].copyWith(
            content: list[i].content.withFile(
              TgFile(
                id: id,
                name: file.name,
                size: next.size,
                path: next.path,
                downloading: next.downloading,
                downloadedBytes: next.downloadedBytes,
              ),
            ),
          );
        }
      }
    }
    notifyListeners();
  }

  // Chats.

  Future<void> openChat(int chatId) async {
    await engine.send({'@type': 'openChat', 'chat_id': chatId});
    if ((_messages[chatId] ?? const []).isEmpty) await loadOlder(chatId);
  }

  Future<void> closeChat(int chatId) async {
    try {
      await engine.send({'@type': 'closeChat', 'chat_id': chatId});
    } on TdError {
      // Already gone.
    }
  }

  /// Loads a page of history before the oldest message shown.
  Future<void> loadOlder(int chatId, {int limit = 50}) async {
    if (_fullyLoaded.contains(chatId)) return;
    final oldest = _messages[chatId]?.firstOrNull?.id ?? 0;
    final answer = await engine.send({
      '@type': 'getChatHistory',
      'chat_id': chatId,
      'from_message_id': oldest,
      'offset': 0,
      'limit': limit.clamp(1, 100),
      'only_local': false,
    });
    final page = _list(answer['messages']).toList();
    var added = 0;
    for (final json in page) {
      final message = TgMessage.parse(json);
      if (message != null && message.chatId == chatId) {
        _addMessage(message);
        added++;
      }
    }
    if (added == 0) _fullyLoaded.add(chatId);
  }

  /// Tells Telegram the user read [chatId] up to now. This sends a read
  /// receipt: Telegram offers no way to read without one.
  Future<void> markRead(int chatId) async {
    final newest = _messages[chatId]?.lastOrNull;
    if (newest == null) return;
    await engine.send({
      '@type': 'viewMessages',
      'chat_id': chatId,
      'message_ids': [newest.id],
      'source': {'@type': 'messageSourceChatHistory'},
      'force_read': true,
    });
  }

  // Sending.

  /// Sends [text]. [silent] sends without a notification sound; [sendAt]
  /// schedules it. Mod filters and commands apply first; a message a plugin
  /// blocks is not sent (returns false).
  Future<bool> sendText(
    int chatId,
    String text, {
    int? replyTo,
    bool silent = false,
    DateTime? sendAt,
  }) async {
    final out = mods.outgoing(text);
    if (out == null) return false;
    if (out.length > 4096) {
      throw ArgumentError('Telegram messages are at most 4096 characters.');
    }
    await engine.send({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyTo != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyTo,
        },
      'options': _sendOptions(silent, sendAt),
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': out},
      },
    });
    return true;
  }

  Map<String, Object?> _sendOptions(bool silent, DateTime? sendAt) => {
    '@type': 'messageSendOptions',
    'disable_notification': silent,
    if (sendAt != null)
      'scheduling_state': {
        '@type': 'messageSchedulingStateSendAtDate',
        'send_date': sendAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      },
  };

  Future<void> sendFile(
    int chatId,
    String path, {
    String caption = '',
    int? replyTo,
    bool silent = false,
  }) async {
    await engine.send({
      '@type': 'sendMessage',
      'chat_id': chatId,
      if (replyTo != null)
        'reply_to': {
          '@type': 'inputMessageReplyToMessage',
          'message_id': replyTo,
        },
      'options': _sendOptions(silent, null),
      'input_message_content': {
        '@type': 'inputMessageDocument',
        'document': {'@type': 'inputFileLocal', 'path': path},
        'caption': {'@type': 'formattedText', 'text': caption},
      },
    });
  }

  Future<void> edit(int chatId, int messageId, String text) async {
    final message = _messages[chatId]
        ?.where((m) => m.id == messageId)
        .firstOrNull;
    if (message == null || !message.outgoing) {
      throw StateError('Only your own messages can be edited.');
    }
    await engine.send({
      '@type': 'editMessageText',
      'chat_id': chatId,
      'message_id': messageId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': text},
      },
    });
  }

  Future<void> delete(int chatId, int messageId, {required bool forEveryone}) =>
      engine.send({
        '@type': 'deleteMessages',
        'chat_id': chatId,
        'message_ids': [messageId],
        'revoke': forEveryone,
      });

  Future<void> react(int chatId, int messageId, String emoji) async {
    final message = _messages[chatId]
        ?.where((m) => m.id == messageId)
        .firstOrNull;
    final mine = message?.myReactions.contains(emoji) ?? false;
    await engine.send({
      '@type': mine ? 'removeMessageReaction' : 'addMessageReaction',
      'chat_id': chatId,
      'message_id': messageId,
      'reaction_type': {'@type': 'reactionTypeEmoji', 'emoji': emoji},
      if (!mine) 'is_big': false,
      if (!mine) 'update_recent_reactions': false,
    });
  }

  // Files.

  Future<void> download(TgFile file) => engine.send({
    '@type': 'downloadFile',
    'file_id': file.id,
    'priority': 1,
    'offset': 0,
    'limit': 0,
    'synchronous': false,
  });

  Future<void> cancelDownload(TgFile file) => engine.send({
    '@type': 'cancelDownloadFile',
    'file_id': file.id,
    'only_if_pending': false,
  });

  /// Files being downloaded now (the download manager).
  List<TgFile> get activeDownloads => [
    for (final file in files.values)
      if (file.downloading) file,
  ];

  // Sponsored messages (required in channels) and tools.

  /// The sponsored messages Telegram serves for a channel; shown marked as
  /// sponsored.
  Future<List<TgSponsored>> sponsoredFor(int chatId) async {
    final chat = chats[chatId];
    if (chat == null || chat.kind != TgChatKind.channel) return const [];
    try {
      final answer = await engine.send({
        '@type': 'getChatSponsoredMessages',
        'chat_id': chatId,
      });
      return [
        for (final json in _list(answer['messages']).take(5))
          ?TgSponsored.parse(json),
      ];
    } on TdError {
      return const [];
    }
  }

  /// Tells Telegram a sponsored message was shown (its terms require it).
  Future<void> sponsoredShown(int chatId, TgSponsored sponsored) async {
    try {
      await engine.send({
        '@type': 'viewSponsoredMessage',
        'chat_id': chatId,
        'sponsored_message_id': sponsored.id,
      });
    } on TdError {
      // Counted when possible.
    }
  }

  /// Translates [text] with Telegram's own translation service.
  Future<String> translate(String text) async {
    final answer = await engine.send({
      '@type': 'translateText',
      'text': {'@type': 'formattedText', 'text': text},
      'to_language_code': mods.translateTo.isEmpty
          ? languageCode
          : mods.translateTo,
    });
    return tdText(answer['text'], maxTelegramTextChars);
  }

  /// The loaded history of [chatId] as JSON, for the user's own export.
  String exportChat(int chatId) {
    final chat = chats[chatId];
    return const JsonEncoder.withIndent('  ').convert({
      'chat': chat?.title ?? '$chatId',
      'exportedFrom': 'Conest (unofficial Telegram client)',
      'messages': [
        for (final message in _messages[chatId] ?? const <TgMessage>[])
          if (message.content.kind != TgContentKind.deleted)
            {
              'id': message.id,
              'date': message.date.toIso8601String(),
              'from': message.outgoing
                  ? selfName
                  : (nameOf(message.senderId).isEmpty
                        ? '${message.senderId}'
                        : nameOf(message.senderId)),
              'text': message.content.text,
              'type': message.content.kind.name,
            },
      ],
    });
  }

  @override
  void dispose() {
    _closed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
