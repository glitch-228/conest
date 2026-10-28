import 'dart:async';

import 'package:conest/src/telegram/telegram_bridge.dart';
import 'package:conest/src/telegram/telegram_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_td_engine.dart';

TgChat chat(int id, {String type = 'private'}) => TgChat.parse({
  'id': id,
  'title': 'T$id',
  'type': type == 'saved'
      ? {'@type': 'chatTypePrivate', 'user_id': 1}
      : {'@type': 'chatTypePrivate', 'user_id': 2},
}, selfUserId: 1)!;

TgMessage message(int id, int chatId, {String text = 'hi', bool out = false}) =>
    TgMessage.parse(
      FakeTdEngine.message(id: id, chatId: chatId, text: text, outgoing: out),
    )!;

void main() {
  batcherTests();
  test('only chosen chats and Saved Messages are relayed', () {
    final settings = TelegramBridgeSettings(chats: {10});
    Map<String, Object?>? event(TgChat c, TgMessage m) => bridgeEventFor(
      message: m,
      chat: c,
      chatTitle: c.title,
      from: 'Bob',
      settings: settings,
    );
    expect(event(chat(10), message(1, 10)), isNotNull);
    expect(event(chat(11), message(1, 11)), isNull);
    expect(event(chat(1, type: 'saved'), message(1, 1)), isNull);
    settings.savedMessages = true;
    expect(event(chat(1, type: 'saved'), message(1, 1)), isNotNull);
  });

  test('the event carries text and names, nothing secret or large', () {
    final settings = TelegramBridgeSettings(chats: {10});
    final e = bridgeEventFor(
      message: message(5, 10, text: 'a' * 9000),
      chat: chat(10),
      chatTitle: 'Chat',
      from: 'Bob',
      settings: settings,
    )!;
    expect(e.keys.toSet(), {
      'type',
      'chat',
      'id',
      'title',
      'saved',
      'from',
      'out',
      'text',
      'at',
    });
    expect((e['text'] as String).length, maxBridgeTextChars);
    // A file is announced, not sent.
    final file = TgMessage.parse(
      FakeTdEngine.message(
        id: 6,
        chatId: 10,
        content: {
          '@type': 'messageDocument',
          'document': {
            'file_name': 'secret.pdf',
            'document': {
              'id': 1,
              'size': 5,
              'local': {'path': '/x/secret.pdf'},
            },
          },
        },
      ),
    )!;
    final f = bridgeEventFor(
      message: file,
      chat: chat(10),
      chatTitle: 'Chat',
      from: 'Bob',
      settings: settings,
    )!;
    expect(f['text'], '[document]');
    expect(f.toString(), isNot(contains('/x/secret.pdf')));
    // A deleted message is not relayed.
    final deleted = message(7, 10).copyWith(content: TgContent.deleted);
    expect(
      bridgeEventFor(
        message: deleted,
        chat: chat(10),
        chatTitle: 'Chat',
        from: 'Bob',
        settings: settings,
      ),
      isNull,
    );
  });

  test('the inbox takes valid events once and stays bounded', () {
    final inbox = TelegramBridgeInbox();
    Map<String, dynamic> event(String chat, String id, {String text = 'x'}) => {
      'type': 'tgx',
      'chat': chat,
      'id': id,
      'title': 'T',
      'from': 'B',
      'out': false,
      'text': text,
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    expect(inbox.accept(event('10', '1')), isTrue);
    expect(inbox.accept(event('10', '1')), isFalse);
    expect(inbox.chats['10']!.unread, 1);
    expect(inbox.accept(event('abc', '2')), isFalse);
    expect(inbox.accept(event('10', 'x')), isFalse);
    expect(inbox.accept(event('10', '3', text: '')), isFalse);
    expect(
      inbox.accept(event('10', '4', text: 'a' * (maxBridgeTextChars + 1))),
      isFalse,
    );
    for (var i = 0; i < TelegramBridgeInbox.maxMessagesPerChat + 20; i++) {
      inbox.accept(event('10', '${100 + i}'));
    }
    expect(
      inbox.chats['10']!.messages.length,
      TelegramBridgeInbox.maxMessagesPerChat,
    );
    for (var c = 0; c < TelegramBridgeInbox.maxChats + 10; c++) {
      inbox.accept(event('${1000 + c}', '1'));
    }
    expect(inbox.chats.length, TelegramBridgeInbox.maxChats);
    // A time from the future is pulled back to now.
    final future = event('9', '1')
      ..['at'] = DateTime.now()
          .toUtc()
          .add(const Duration(days: 30))
          .toIso8601String();
    final fresh = TelegramBridgeInbox()..accept(future);
    expect(
      fresh.chats['9']!.messages.single.at.isAfter(
        DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
      isFalse,
    );
  });

  test('settings and inbox survive saving', () {
    final settings = TelegramBridgeSettings(savedMessages: true, chats: {5, 6});
    final loaded = TelegramBridgeSettings.fromJson(settings.toJson());
    expect(loaded.savedMessages, isTrue);
    expect(loaded.chats, {5, 6});
    for (var i = 0; i < TelegramBridgeSettings.maxChats; i++) {
      expect(
        settings.setChat(100 + i, true),
        i < TelegramBridgeSettings.maxChats - 2,
      );
    }
    final inbox = TelegramBridgeInbox();
    inbox.accept({
      'chat': '10',
      'id': '1',
      'text': 'kept',
      'at': DateTime.now().toUtc().toIso8601String(),
      'saved': true,
    });
    final again = TelegramBridgeInbox.fromJson(inbox.toJson());
    expect(again.chats['10']!.messages.single.text, 'kept');
    expect(again.chats['10']!.saved, isTrue);
  });
}

class _FakeTimer implements Timer {
  _FakeTimer(this.callback);
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

void batcherTests() {
  group('the batcher', () {
    late List<Map<String, Object?>> sent;
    late List<_FakeTimer> timers;
    TelegramBridgeBatcher make({int maxItems = 20, int maxPending = 200}) =>
        TelegramBridgeBatcher(
          send: sent.add,
          maxItems: maxItems,
          maxPending: maxPending,
          timer: (_, callback) {
            final timer = _FakeTimer(callback);
            timers.add(timer);
            return timer;
          },
        );

    Map<String, Object?> event(int i, {int size = 5}) => {
      'type': 'tgx',
      'chat': '10',
      'id': '$i',
      'text': 'x' * size,
    };

    setUp(() {
      sent = [];
      timers = [];
    });

    test('a burst becomes one envelope, sent when the timer fires', () {
      final batcher = make();
      for (var i = 0; i < 5; i++) {
        batcher.add(event(i));
      }
      expect(sent, isEmpty);
      expect(timers, hasLength(1));
      timers.single.callback();
      expect(sent, hasLength(1));
      expect((sent.single['items'] as List).length, 5);
      expect(sent.single['type'], 'tgx');
      expect(batcher.pending, 0);
    });

    test('a full batch goes at once, in bounded pieces', () {
      final batcher = make(maxItems: 3);
      for (var i = 0; i < 7; i++) {
        batcher.add(event(i));
      }
      expect(sent.length, 2);
      expect((sent.first['items'] as List).length, 3);
      batcher.flush();
      expect(sent.length, 3);
      expect(sent.every((b) => (b['items'] as List).length <= 3), isTrue);
    });

    test('big texts flush early and the backlog is bounded', () {
      final batcher = make();
      batcher.add(event(1, size: 40 * 1024));
      expect(sent, hasLength(1));
      final bounded = make(maxItems: 1000, maxPending: 10);
      for (var i = 0; i < 50; i++) {
        bounded.add(event(i));
      }
      expect(bounded.pending, 10);
      bounded.flush();
      final ids = [
        for (final b in sent.skip(1))
          for (final i in b['items'] as List) (i as Map)['id'],
      ];
      expect(ids.first, '40');
    });

    test('dispose drops what is waiting', () {
      final batcher = make();
      batcher.add(event(1));
      batcher.dispose();
      expect(timers.single.cancelled, isTrue);
      expect(batcher.pending, 0);
    });
  });
}
