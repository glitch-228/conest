import 'dart:async';

import 'package:conest/src/telegram/td_engine.dart';

/// A TDLib stand-in that speaks the same JSON: authorization states, chats,
/// history, sending, editing, deleting, reactions, files, folders and
/// sponsored messages, with the error answers real Telegram gives.
class FakeTdEngine implements TdEngine {
  FakeTdEngine({
    this.phone = '+15550001',
    this.code = '12345',
    this.password,
    this.selfId = 1,
    this.loggedIn = false,
  });

  final String phone;
  final String code;

  /// The 2FA password, if the account has one.
  final String? password;
  final int selfId;

  /// Starts signed in (a restored database).
  bool loggedIn;

  final _updates = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, Object?>> requests = [];
  final Map<int, Map<String, dynamic>> chats = {};
  final Map<int, List<Map<String, dynamic>>> history = {};
  final List<Map<String, dynamic>> sponsored = [];
  bool closed = false;
  bool failSends = false;

  /// Downloads finish only once this completes (they stay at 40% until then).
  Completer<void> downloadsFinish = Completer<void>()..complete();
  int _nextId = 1000;
  int _nextLocalId = 1;
  bool _started = false;
  Map<String, dynamic>? setParameters;
  String _state = 'none';

  @override
  Stream<Map<String, dynamic>> get updates => _updates.stream;

  void emit(Map<String, dynamic> update) {
    scheduleMicrotask(() {
      if (!_updates.isClosed) _updates.add(update);
    });
  }

  void _auth(String type, [Map<String, dynamic> extra = const {}]) {
    _state = type;
    emit({
      '@type': 'updateAuthorizationState',
      'authorization_state': {'@type': type, ...extra},
    });
  }

  static Map<String, dynamic> message({
    required int id,
    required int chatId,
    String text = 'hello',
    bool outgoing = false,
    int sender = 2,
    int date = 1790000000,
    Map<String, dynamic>? content,
    Map<String, dynamic>? replyTo,
  }) => {
    '@type': 'message',
    'id': id,
    'chat_id': chatId,
    'sender_id': {'@type': 'messageSenderUser', 'user_id': sender},
    'is_outgoing': outgoing,
    'date': date,
    'content':
        content ??
        {
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': text},
        },
    'reply_to': ?replyTo,
  };

  Map<String, dynamic> addChat(
    int id,
    String title, {
    String type = 'private',
    int userId = 2,
    int order = 100,
    int unread = 0,
    List<Map<String, dynamic>> messages = const [],
  }) {
    final chat = {
      '@type': 'chat',
      'id': id,
      'title': title,
      'type': switch (type) {
        'private' => {'@type': 'chatTypePrivate', 'user_id': userId},
        'channel' => {
          '@type': 'chatTypeSupergroup',
          'supergroup_id': id,
          'is_channel': true,
        },
        'group' => {'@type': 'chatTypeBasicGroup', 'basic_group_id': id},
        _ => {'@type': 'chatTypeSecret', 'user_id': userId},
      },
      'unread_count': unread,
      'positions': [
        {
          '@type': 'chatPosition',
          'list': {'@type': 'chatListMain'},
          'order': '$order',
          'is_pinned': false,
        },
      ],
      'permissions': {'can_send_basic_messages': true},
      'notification_settings': {'mute_for': 0},
      if (messages.isNotEmpty) 'last_message': messages.last,
    };
    chats[id] = chat;
    history[id] = [...messages];
    return chat;
  }

  @override
  Future<Map<String, dynamic>> send(
    Map<String, Object?> request, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    requests.add(request);
    if (closed) throw const TdError(500, 'closed');
    final type = request['@type'] as String;
    if (!_started) {
      _started = true;
      _auth('authorizationStateWaitTdlibParameters');
    }
    switch (type) {
      case 'getOption':
        return {'@type': 'optionValueString', 'value': '1.8.fake'};
      case 'setTdlibParameters':
        setParameters = Map<String, dynamic>.from(request);
        if (loggedIn) {
          _auth('authorizationStateReady');
        } else {
          _auth('authorizationStateWaitPhoneNumber');
        }
        return {'@type': 'ok'};
      case 'setAuthenticationPhoneNumber':
        final number = request['phone_number'] as String;
        if (!RegExp(r'^\+\d{6,15}$').hasMatch(number)) {
          throw const TdError(400, 'PHONE_NUMBER_INVALID');
        }
        _pendingPhone = number;
        _auth('authorizationStateWaitCode', {
          'code_info': {'phone_number': number},
        });
        return {'@type': 'ok'};
      case 'requestQrCodeAuthentication':
        _auth('authorizationStateWaitOtherDeviceConfirmation', {
          'link': 'tg://login?token=FAKE',
        });
        return {'@type': 'ok'};
      case 'checkAuthenticationCode':
        if (request['code'] != code) {
          throw const TdError(400, 'PHONE_CODE_INVALID');
        }
        if (_pendingPhone != phone) {
          _auth('authorizationStateWaitRegistration');
        } else if (password != null) {
          _auth('authorizationStateWaitPassword');
        } else {
          loggedIn = true;
          _auth('authorizationStateReady');
        }
        return {'@type': 'ok'};
      case 'checkAuthenticationPassword':
        if (request['password'] != password) {
          throw const TdError(400, 'PASSWORD_HASH_INVALID');
        }
        loggedIn = true;
        _auth('authorizationStateReady');
        return {'@type': 'ok'};
      case 'logOut':
        loggedIn = false;
        _auth('authorizationStateLoggingOut');
        Timer(Duration.zero, () => _auth('authorizationStateClosed'));
        return {'@type': 'ok'};
      case 'close':
        closed = true;
        return {'@type': 'ok'};
    }
    if (_state != 'authorizationStateReady') {
      throw const TdError(401, 'Unauthorized');
    }
    switch (type) {
      case 'getMe':
        return {
          '@type': 'user',
          'id': selfId,
          'first_name': 'Me',
          'last_name': 'Self',
        };
      case 'loadChats':
        final list = (request['chat_list'] as Map)['@type'];
        if (list == 'chatListMain' && !_chatsSent) {
          _chatsSent = true;
          for (final chat in chats.values) {
            emit({'@type': 'updateNewChat', 'chat': chat});
          }
          emit({
            '@type': 'updateChatFolders',
            'chat_folders': [
              {'@type': 'chatFolderInfo', 'id': 7, 'title': 'Work'},
            ],
          });
          return {'@type': 'ok'};
        }
        throw const TdError(404, 'Not Found');
      case 'openChat':
      case 'closeChat':
      case 'viewMessages':
      case 'viewSponsoredMessage':
      case 'cancelDownloadFile':
        return {'@type': 'ok'};
      case 'getChatHistory':
        final chatId = request['chat_id'] as int;
        final from = request['from_message_id'] as int;
        final limit = request['limit'] as int;
        final all = [...?history[chatId]]
          ..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
        final older = [
          for (final m in all)
            if (from == 0 || (m['id'] as int) < from) m,
        ];
        return {'@type': 'messages', 'messages': older.take(limit).toList()};
      case 'sendMessage':
        final chatId = request['chat_id'] as int;
        final content = request['input_message_content'] as Map;
        final localId = _nextLocalId++ << 20;
        final isFile = content['@type'] == 'inputMessageDocument';
        final text =
            ((content['text'] ?? content['caption']) as Map)['text'] as String;
        final reply = request['reply_to'] as Map?;
        final options = request['options'] as Map?;
        final sent = message(
          id: localId,
          chatId: chatId,
          text: text,
          outgoing: true,
          sender: selfId,
          content: isFile
              ? {
                  '@type': 'messageDocument',
                  'document': {
                    'file_name': (content['document'] as Map)['path'],
                    'document': {
                      'id': 500,
                      'size': 10,
                      'local': {'path': (content['document'] as Map)['path']},
                    },
                  },
                  'caption': {'text': text},
                }
              : null,
          replyTo: reply == null
              ? null
              : {
                  '@type': 'messageReplyToMessage',
                  'chat_id': chatId,
                  'message_id': reply['message_id'],
                },
        );
        if (options?['scheduling_state'] != null) {
          sent['scheduling_state'] = options!['scheduling_state'];
        }
        sent['sending_state'] = {'@type': 'messageSendingStatePending'};
        final id = _nextId++;
        Timer(Duration.zero, () {
          if (failSends) {
            emit({
              '@type': 'updateMessageSendFailed',
              'message': {...sent, 'sending_state': null},
              'old_message_id': localId,
              'chat_id': chatId,
            });
            return;
          }
          final done = {...sent}
            ..['id'] = id
            ..remove('sending_state');
          history.putIfAbsent(chatId, () => []).add(done);
          emit({
            '@type': 'updateMessageSendSucceeded',
            'message': done,
            'old_message_id': localId,
          });
        });
        emit({'@type': 'updateNewMessage', 'message': sent});
        return sent;
      case 'editMessageText':
        final text =
            ((request['input_message_content'] as Map)['text'] as Map)['text'];
        emit({
          '@type': 'updateMessageContent',
          'chat_id': request['chat_id'],
          'message_id': request['message_id'],
          'new_content': {
            '@type': 'messageText',
            'text': {'text': text},
          },
        });
        emit({
          '@type': 'updateMessageEdited',
          'chat_id': request['chat_id'],
          'message_id': request['message_id'],
          'edit_date': 1790000999,
        });
        return {'@type': 'ok'};
      case 'deleteMessages':
        emit({
          '@type': 'updateDeleteMessages',
          'chat_id': request['chat_id'],
          'message_ids': request['message_ids'],
          'is_permanent': true,
          'from_cache': false,
        });
        return {'@type': 'ok'};
      case 'addMessageReaction':
      case 'removeMessageReaction':
        final add = type == 'addMessageReaction';
        emit({
          '@type': 'updateMessageInteractionInfo',
          'chat_id': request['chat_id'],
          'message_id': request['message_id'],
          'interaction_info': add
              ? {
                  'reactions': {
                    'reactions': [
                      {
                        'type': request['reaction_type'],
                        'total_count': 1,
                        'is_chosen': true,
                      },
                    ],
                  },
                }
              : null,
        });
        return {'@type': 'ok'};
      case 'downloadFile':
        final id = request['file_id'] as int;
        emit({
          '@type': 'updateFile',
          'file': {
            'id': id,
            'size': 100,
            'local': {
              'is_downloading_active': true,
              'downloaded_size': 40,
              'is_downloading_completed': false,
            },
          },
        });
        unawaited(
          downloadsFinish.future.then((_) {
            emit({
              '@type': 'updateFile',
              'file': {
                'id': id,
                'size': 100,
                'local': {
                  'path': '/tmp/fake/$id.bin',
                  'is_downloading_active': false,
                  'downloaded_size': 100,
                  'is_downloading_completed': true,
                },
              },
            });
          }),
        );
        return {'@type': 'file', 'id': id};
      case 'getChatSponsoredMessages':
        return {'@type': 'sponsoredMessages', 'messages': sponsored};
      case 'translateText':
        final text = (request['text'] as Map)['text'] as String;
        return {
          '@type': 'formattedText',
          'text': '[${request['to_language_code']}] $text',
        };
    }
    throw TdError(400, 'unknown method $type');
  }

  String? _pendingPhone;
  bool _chatsSent = false;

  @override
  Future<void> close() async {
    closed = true;
    await _updates.close();
  }
}
