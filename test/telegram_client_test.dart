import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conest/src/telegram/td_engine.dart';
import 'package:conest/src/telegram/telegram_api_keys.dart';
import 'package:conest/src/telegram/telegram_client.dart';
import 'package:conest/src/telegram/telegram_models.dart';
import 'package:conest/src/telegram/telegram_mods.dart';
import 'package:conest/src/telegram/telegram_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_td_engine.dart';

const _keys = TelegramApiKeys(424242, 'abcdef0123456789abcdef0123456789');
final _dbKey = base64.encode(List.generate(32, (i) => i));

Future<void> pump([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await pump(5);
  }
  expect(done(), isTrue);
}

Future<TelegramClient> startClient(
  FakeTdEngine engine, {
  TelegramMods? mods,
}) async {
  final client = TelegramClient(
    engine: engine,
    keys: _keys,
    databaseDirectory: '/tmp/fake/db',
    filesDirectory: '/tmp/fake/files',
    databaseKey: _dbKey,
    mods: mods,
  );
  addTearDown(client.dispose);
  await client.start();
  return client;
}

/// A signed-in client with two chats loaded.
Future<(TelegramClient, FakeTdEngine)> signedIn({
  TelegramMods? mods,
  void Function(FakeTdEngine engine)? seed,
}) async {
  final engine = FakeTdEngine(loggedIn: true);
  engine.addChat(
    10,
    'Alice',
    order: 300,
    unread: 2,
    messages: [
      FakeTdEngine.message(id: 100, chatId: 10, text: 'one'),
      FakeTdEngine.message(id: 101, chatId: 10, text: 'two', sender: 3),
      FakeTdEngine.message(
        id: 102,
        chatId: 10,
        text: 'mine',
        outgoing: true,
        sender: 1,
      ),
    ],
  );
  engine.addChat(11, 'News', type: 'channel', order: 200);
  engine.addChat(1, '', userId: 1, order: 100);
  seed?.call(engine);
  final client = await startClient(engine, mods: mods);
  await until(() => client.auth == TgAuth.ready && client.chats.length >= 3);
  return (client, engine);
}

void main() {
  group('keys', () {
    test('come only from complete, well-formed build defines', () {
      expect(TelegramApiKeys.parse('', ''), isNull);
      expect(TelegramApiKeys.parse('123', ''), isNull);
      expect(TelegramApiKeys.parse('0', 'a' * 32), isNull);
      expect(TelegramApiKeys.parse('123', 'xyz'), isNull);
      expect(TelegramApiKeys.parse('123', 'A' * 32), isNull);
      expect(TelegramApiKeys.parse('123', 'a' * 32)?.apiId, 123);
      // No keys are compiled into the test build.
      expect(TelegramApiKeys.fromEnvironment(), isNull);
    });
  });

  group('sign-in', () {
    test('phone, code, then the 2FA password', () async {
      final engine = FakeTdEngine(password: 'secret');
      final client = await startClient(engine);
      await until(() => client.auth == TgAuth.waitPhone);
      // TDLib gets Conest's own keys, an encrypted database and no secret
      // chats; the app calls itself unofficial.
      final params = engine.setParameters!;
      expect(params['api_id'], 424242);
      expect(params['api_hash'], _keys.apiHash);
      expect(params['database_encryption_key'], _dbKey);
      expect(params['use_secret_chats'], false);
      expect(params['use_test_dc'], false);
      expect(params['device_model'], contains('unofficial'));

      await expectLater(client.submitPhone('12'), throwsA(isA<TdError>()));
      expect(client.authError, 'PHONE_NUMBER_INVALID');
      await client.submitPhone(' +15550001 ');
      await until(() => client.auth == TgAuth.waitCode);
      expect(client.authError, isNull);
      await expectLater(client.submitCode('00000'), throwsA(isA<TdError>()));
      expect(client.authError, 'PHONE_CODE_INVALID');
      expect(client.auth, TgAuth.waitCode);
      await client.submitCode('12345');
      await until(() => client.auth == TgAuth.waitPassword);
      await expectLater(client.submitPassword('nope'), throwsA(isA<TdError>()));
      await client.submitPassword('secret');
      await until(() => client.auth == TgAuth.ready);
      expect(client.selfUserId, 1);
    });

    test('a number without an account is not signed up', () async {
      final engine = FakeTdEngine();
      final client = await startClient(engine);
      await until(() => client.auth == TgAuth.waitPhone);
      await client.submitPhone('+15559999');
      await client.submitCode('12345');
      await until(() => client.auth == TgAuth.noAccount);
      // Only log-in calls were ever made: no registration request exists.
      expect(
        engine.requests.map((r) => r['@type']),
        isNot(contains('registerUser')),
      );
    });

    test('a QR code can be shown for another Telegram app to scan', () async {
      final engine = FakeTdEngine();
      final client = await startClient(engine);
      await until(() => client.auth == TgAuth.waitPhone);
      await client.requestQrLogin();
      await until(() => client.auth == TgAuth.waitQr);
      expect(client.qrLink, 'tg://login?token=FAKE');
    });

    test('a restored database goes straight to ready', () async {
      final (client, engine) = await signedIn();
      expect(client.auth, TgAuth.ready);
      expect(
        engine.requests.map((r) => r['@type']),
        isNot(contains('setAuthenticationPhoneNumber')),
      );
    });

    test('logging out clears what was loaded', () async {
      final (client, _) = await signedIn();
      await client.logOut();
      await until(() => client.auth == TgAuth.loggedOut);
      expect(client.chats, isEmpty);
    });
  });

  group('chats', () {
    test('lists come newest first, with Saved Messages and folders', () async {
      final (client, _) = await signedIn();
      expect(client.chatList().map((c) => c.title), [
        'Alice',
        'News',
        'Saved Messages',
      ]);
      expect(client.chats[1]!.kind, TgChatKind.saved);
      expect(client.chats[11]!.kind, TgChatKind.channel);
      expect(client.chats[11]!.canPost, isFalse);
      expect(client.chats[10]!.unread, 2);
      expect(client.folders.single.title, 'Work');
    });

    test('opening a chat loads history, then older pages', () async {
      final (client, _) = await signedIn(
        seed: (engine) {
          engine.addChat(
            12,
            'Long',
            order: 50,
            messages: [
              for (var i = 1; i <= 120; i++)
                FakeTdEngine.message(id: i, chatId: 12, text: 'm$i'),
            ],
          );
        },
      );
      await until(() => client.chats.containsKey(12));
      await client.openChat(12);
      expect(client.messagesOf(12).length, 50);
      expect(client.messagesOf(12).last.content.text, 'm120');
      await client.loadOlder(12);
      await client.loadOlder(12);
      expect(client.messagesOf(12).length, 120);
      expect(client.messagesOf(12).first.content.text, 'm1');
      expect(client.historyComplete(12), isFalse);
      await client.loadOlder(12);
      expect(client.historyComplete(12), isTrue);
    });

    test('a chat keeps only a bounded number of messages', () async {
      final (client, _) = await signedIn(
        seed: (engine) {
          engine.addChat(12, 'Long', order: 50);
        },
      );
      await until(() => client.chats.containsKey(12));
      for (var i = 1; i <= maxTelegramMessagesPerChat + 50; i++) {
        client.engine is FakeTdEngine
            ? (client.engine as FakeTdEngine).emit({
                '@type': 'updateNewMessage',
                'message': FakeTdEngine.message(id: i, chatId: 12),
              })
            : null;
      }
      await until(() => (client.messagesOf(12).lastOrNull?.id ?? 0) > 400);
      expect(client.messagesOf(12).length, maxTelegramMessagesPerChat);
    });

    test('only a bounded number of chats is kept', () async {
      final (client, engine) = await signedIn();
      for (var i = 0; i < maxTelegramChats + 20; i++) {
        engine.emit({
          '@type': 'updateNewChat',
          'chat': engine.addChat(5000 + i, 'c$i', order: 1000 + i),
        });
      }
      await until(() => client.chats.containsKey(5000 + maxTelegramChats + 19));
      expect(client.chats.length, maxTelegramChats);
    });

    test('new messages and read counts update the list', () async {
      final (client, engine) = await signedIn();
      engine.emit({
        '@type': 'updateNewMessage',
        'message': FakeTdEngine.message(id: 103, chatId: 10, text: 'fresh'),
      });
      engine.emit({
        '@type': 'updateChatReadInbox',
        'chat_id': 10,
        'unread_count': 0,
      });
      await until(() => client.chats[10]!.lastMessage?.id == 103);
      expect(client.chats[10]!.unread, 0);
      await client.markRead(10);
      expect(engine.requests.last, containsPair('@type', 'viewMessages'));
    });
  });

  group('sending', () {
    test(
      'a message is pending, then replaces itself with the sent one',
      () async {
        final (client, engine) = await signedIn();
        await client.openChat(10);
        expect(await client.sendText(10, 'hi there', replyTo: 101), isTrue);
        final request = engine.requests.lastWhere(
          (r) => r['@type'] == 'sendMessage',
        );
        expect((request['reply_to'] as Map)['message_id'], 101);
        expect((request['options'] as Map)['disable_notification'], false);
        await until(
          () => client.messagesOf(10).any((m) => m.content.text == 'hi there'),
        );
        await until(
          () => client
              .messagesOf(10)
              .where((m) => m.content.text == 'hi there')
              .every((m) => m.sendState == TgSendState.sent && m.id >= 1000),
        );
        expect(
          client.messagesOf(10).where((m) => m.content.text == 'hi there'),
          hasLength(1),
        );
        final sent = client
            .messagesOf(10)
            .singleWhere((m) => m.content.text == 'hi there');
        expect(sent.replyToId, 101);
      },
    );

    test('a failed send is marked failed', () async {
      final (client, engine) = await signedIn();
      await client.openChat(10);
      engine.failSends = true;
      await client.sendText(10, 'lost');
      await until(
        () =>
            client.messagesOf(10).any((m) => m.sendState == TgSendState.failed),
      );
    });

    test('silent and scheduled sending go in the options', () async {
      final (client, engine) = await signedIn();
      await client.sendText(
        10,
        'quiet',
        silent: true,
        sendAt: DateTime.utc(2026, 11, 1, 12),
      );
      final options =
          engine.requests.lastWhere(
                (r) => r['@type'] == 'sendMessage',
              )['options']
              as Map;
      expect(options['disable_notification'], true);
      expect(
        (options['scheduling_state'] as Map)['send_date'],
        DateTime.utc(2026, 11, 1, 12).millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('messages over 4096 characters are refused before sending', () async {
      final (client, engine) = await signedIn();
      final before = engine.requests.length;
      await expectLater(client.sendText(10, 'a' * 4097), throwsArgumentError);
      expect(engine.requests.length, before);
    });

    test('a file is sent as a document with its caption', () async {
      final (client, engine) = await signedIn();
      await client.sendFile(10, '/tmp/x/report.pdf', caption: 'see');
      final content =
          engine.requests.lastWhere(
                (r) => r['@type'] == 'sendMessage',
              )['input_message_content']
              as Map;
      expect(content['@type'], 'inputMessageDocument');
      expect((content['document'] as Map)['path'], '/tmp/x/report.pdf');
    });

    test('only your own messages can be edited', () async {
      final (client, _) = await signedIn();
      await client.openChat(10);
      await expectLater(client.edit(10, 100, 'x'), throwsStateError);
      await client.edit(10, 102, 'mine, fixed');
      await until(
        () => client
            .messagesOf(10)
            .any((m) => m.id == 102 && m.content.text == 'mine, fixed'),
      );
      expect(
        client.messagesOf(10).singleWhere((m) => m.id == 102).editedAt,
        isNotNull,
      );
    });

    test('reactions toggle', () async {
      final (client, _) = await signedIn();
      await client.openChat(10);
      await client.react(10, 101, '👍');
      await until(
        () => client
            .messagesOf(10)
            .any((m) => m.id == 101 && m.reactions.isNotEmpty),
      );
      expect(
        client.messagesOf(10).singleWhere((m) => m.id == 101).myReactions,
        {'👍'},
      );
      await client.react(10, 101, '👍');
      await until(
        () => client
            .messagesOf(10)
            .any((m) => m.id == 101 && m.reactions.isEmpty),
      );
    });
  });

  group('deleted messages', () {
    test('show a notice and drop the content, not keep it', () async {
      final (client, engine) = await signedIn();
      await client.openChat(10);
      engine.emit({
        '@type': 'updateDeleteMessages',
        'chat_id': 10,
        'message_ids': [101],
        'is_permanent': true,
        'from_cache': false,
      });
      await until(
        () => client
            .messagesOf(10)
            .any((m) => m.id == 101 && m.content.kind == TgContentKind.deleted),
      );
      final gone = client.messagesOf(10).singleWhere((m) => m.id == 101);
      expect(gone.content.text, isEmpty);
      // Not in an export either.
      expect(client.exportChat(10), isNot(contains('two')));
      expect(client.exportChat(10), contains('one'));
      expect((jsonDecode(client.exportChat(10))['messages'] as List).length, 2);
    });

    test('without the notice they simply disappear', () async {
      final (client, engine) = await signedIn(
        mods: TelegramMods(deletedNotice: false),
      );
      await client.openChat(10);
      engine.emit({
        '@type': 'updateDeleteMessages',
        'chat_id': 10,
        'message_ids': [101],
        'is_permanent': true,
        'from_cache': false,
      });
      await until(() => !client.messagesOf(10).any((m) => m.id == 101));
    });

    test('a cache eviction is not a deletion', () async {
      final (client, engine) = await signedIn();
      await client.openChat(10);
      engine.emit({
        '@type': 'updateDeleteMessages',
        'chat_id': 10,
        'message_ids': [101],
        'is_permanent': true,
        'from_cache': true,
      });
      await pump();
      expect(
        client.messagesOf(10).singleWhere((m) => m.id == 101).content.kind,
        TgContentKind.text,
      );
    });

    test('deleting for everyone asks Telegram to revoke', () async {
      final (client, engine) = await signedIn();
      await client.delete(10, 102, forEveryone: true);
      expect(
        engine.requests.lastWhere(
          (r) => r['@type'] == 'deleteMessages',
        )['revoke'],
        true,
      );
    });
  });

  group('files', () {
    test('a download shows progress, then its path', () async {
      final (client, _) = await signedIn(
        seed: (engine) {
          engine.history[10]!.add(
            FakeTdEngine.message(
              id: 110,
              chatId: 10,
              content: {
                '@type': 'messageDocument',
                'document': {
                  'file_name': 'a.pdf',
                  'document': {'id': 77, 'size': 100, 'local': {}},
                },
                'caption': {'text': 'doc'},
              },
            ),
          );
        },
      );
      await client.openChat(10);
      final file = client
          .messagesOf(10)
          .singleWhere((m) => m.id == 110)
          .content
          .file!;
      expect(file.downloaded, isFalse);
      await client.download(file);
      await until(() => client.activeDownloads.isNotEmpty);
      expect(client.activeDownloads.single.downloadedBytes, 40);
      await until(
        () => client
            .messagesOf(10)
            .singleWhere((m) => m.id == 110)
            .content
            .file!
            .downloaded,
      );
      expect(client.activeDownloads, isEmpty);
      expect(
        client
            .messagesOf(10)
            .singleWhere((m) => m.id == 110)
            .content
            .file!
            .path,
        '/tmp/fake/77.bin',
      );
    });
  });

  group('sponsored messages', () {
    test('channels show them, other chats never ask', () async {
      final (client, engine) = await signedIn(
        seed: (engine) {
          engine.sponsored.add({
            '@type': 'sponsoredMessage',
            'message_id': 9,
            'title': 'Brand',
            'button_text': 'Open',
            'content': {
              '@type': 'messageText',
              'text': {'text': 'Buy now'},
            },
            'sponsor': {'url': 'https://example.com/x'},
          });
          engine.sponsored.add({
            '@type': 'sponsoredMessage',
            'message_id': 10,
            'title': 'Bad link',
            'content': {
              '@type': 'messageText',
              'text': {'text': 'x'},
            },
            'sponsor': {'url': 'javascript:alert(1)'},
          });
        },
      );
      expect(await client.sponsoredFor(10), isEmpty);
      expect(
        engine.requests.where((r) => r['@type'] == 'getChatSponsoredMessages'),
        isEmpty,
      );
      final ads = await client.sponsoredFor(11);
      expect(ads, hasLength(2));
      expect(ads.first.title, 'Brand');
      expect(ads.first.url, 'https://example.com/x');
      // A link that is not http(s) is not offered.
      expect(ads.last.url, isEmpty);
      await client.sponsoredShown(11, ads.first);
      expect(
        engine.requests.last,
        containsPair('@type', 'viewSponsoredMessage'),
      );
    });
  });

  group('mods', () {
    test('hidden words hide incoming messages locally only', () async {
      final (client, _) = await signedIn(
        mods: TelegramMods(hiddenWords: ['TWO']),
      );
      await client.openChat(10);
      final texts = client.messagesOf(10).map((m) => m.content.text).toList();
      expect(texts, ['one', 'mine']);
    });

    test('hidden words never hide your own messages', () async {
      final (client, _) = await signedIn(
        mods: TelegramMods(hiddenWords: ['mine']),
      );
      await client.openChat(10);
      expect(
        client.messagesOf(10).map((m) => m.content.text),
        contains('mine'),
      );
    });

    test('a rule plugin works only within its declared permissions', () {
      const source = '''
{"id":"tidy","name":"Tidy","permissions":["editOutgoing","commands"],
 "rules":[
  {"do":"replace","from":"TEH","to":"the"},
  {"do":"block","contains":"password:"},
  {"do":"command","name":"shrug","insert":"¯\\\\_(ツ)_/¯"},
  {"do":"hide","contains":"spoiler"}
 ]}''';
      final mods = TelegramMods();
      expect(mods.install(source), isTrue);
      expect(mods.outgoing('teh cat'), 'the cat');
      expect(mods.outgoing('my password: 123'), isNull);
      expect(mods.outgoing('/shrug'), '¯\\_(ツ)_/¯');
      expect(mods.outgoing('/shrug ok'), '¯\\_(ツ)_/¯ ok');
      // "hide" needs readMessages, which was not declared: it never runs.
      final plugin = mods.plugins.single as TelegramRulePlugin;
      expect(plugin.hideWords, isEmpty);
      final message = TgMessage.parse(
        FakeTdEngine.message(id: 1, chatId: 1, text: 'a spoiler'),
      )!;
      expect(mods.hidden(message), isFalse);
    });

    test('a plugin with read permission can hide messages', () {
      final mods = TelegramMods();
      expect(
        mods.install(
          '{"id":"calm","name":"Calm","permissions":["readMessages"],'
          '"rules":[{"do":"hide","contains":"Spoiler"}]}',
        ),
        isTrue,
      );
      final message = TgMessage.parse(
        FakeTdEngine.message(id: 1, chatId: 1, text: 'a SPOILER here'),
      )!;
      expect(mods.hidden(message), isTrue);
    });

    test('a plugin cannot take over commands people send to bots', () {
      final mods = TelegramMods();
      mods.install(
        '{"id":"p","name":"P","permissions":["commands"],"rules":['
        '{"do":"command","name":"start","insert":"EVIL"},'
        '{"do":"command","name":"Help","insert":"EVIL"},'
        '{"do":"command","name":"shrug","insert":"ok"}]}',
      );
      final plugin = mods.plugins.single as TelegramRulePlugin;
      expect(plugin.commands.keys, ['shrug']);
      expect(mods.outgoing('/start'), '/start');
      expect(mods.outgoing('/start@some_bot x'), '/start@some_bot x');
    });

    test('malformed or oversized plugins are refused', () {
      final mods = TelegramMods();
      expect(mods.install('not json'), isFalse);
      expect(mods.install('{"id":"Bad Id","name":"x"}'), isFalse);
      expect(
        mods.install('{"id":"big","name":"x","pad":"${'a' * 70000}"}'),
        isFalse,
      );
      expect(mods.plugins, isEmpty);
    });

    test('plugins are limited in number and survive saving', () {
      final mods = TelegramMods();
      for (var i = 0; i < TelegramMods.maxPlugins; i++) {
        expect(mods.install('{"id":"p$i","name":"P"}'), isTrue);
      }
      expect(mods.install('{"id":"extra","name":"P"}'), isFalse);
      final loaded = TelegramMods.fromJson(
        jsonDecode(jsonEncode(mods.toJson())),
      );
      expect(loaded.plugins, hasLength(TelegramMods.maxPlugins));
    });

    test('outgoing messages go through the filters before sending', () async {
      final mods = TelegramMods();
      mods.install(
        '{"id":"tidy","name":"Tidy","permissions":["editOutgoing"],'
        '"rules":[{"do":"replace","from":"teh","to":"the"},'
        '{"do":"block","contains":"secret"}]}',
      );
      final (client, engine) = await signedIn(mods: mods);
      expect(await client.sendText(10, 'teh end'), isTrue);
      expect(
        ((engine.requests.lastWhere(
                  (r) => r['@type'] == 'sendMessage',
                )['input_message_content']
                as Map)['text']
            as Map)['text'],
        'the end',
      );
      final count = engine.requests.length;
      expect(await client.sendText(10, 'a secret'), isFalse);
      expect(engine.requests.length, count);
    });

    test('translation uses Telegram, into the chosen language', () async {
      final (client, _) = await signedIn(mods: TelegramMods(translateTo: 'de'));
      expect(await client.translate('hello'), '[de] hello');
    });
  });

  group('stopping and starting', () {
    test('a start during a close waits: one TDLib client at a time', () async {
      var live = 0;
      var maxLive = 0;
      var created = 0;
      final service = TelegramService(
        keys: _keys,
        engineFactory: () {
          created++;
          return _SlowCloseEngine(
            onOpen: () {
              live++;
              if (live > maxLive) maxLive = live;
            },
            onClosed: () => live--,
          );
        },
        directory: () async => Directory.systemTemp,
        readAccount: () => {'enabled': true, 'dbKey': _dbKey},
        writeAccount: (_) async {},
        readMods: () => null,
        writeMods: (_) {},
      );
      await service.start();
      await until(() => service.client?.auth == TgAuth.ready);
      // Online toggled off and on again in a blink, nobody awaiting.
      unawaited(service.stop());
      unawaited(service.start());
      unawaited(service.stop());
      unawaited(service.start());
      await service.start();
      await until(() => service.client?.auth == TgAuth.ready);
      expect(maxLive, 1);
      expect(created, greaterThanOrEqualTo(2));
      expect(live, 1);
      service.dispose();
    });

    test('probing support creates no client', () {
      var created = 0;
      final service = TelegramService(
        keys: _keys,
        engineFactory: () {
          created++;
          return FakeTdEngine();
        },
        probe: () => true,
        directory: () async => Directory.systemTemp,
        readAccount: () => null,
        writeAccount: (_) async {},
        readMods: () => null,
        writeMods: (_) {},
      );
      addTearDown(service.dispose);
      expect(service.supported, isTrue);
      expect(created, 0);
    });
  });

  group('the bridge respects mods', () {
    test('messages hidden by the user are not relayed', () async {
      final engine = FakeTdEngine(loggedIn: true)
        ..addChat(10, 'Alice', order: 300);
      final relayed = <Map<String, Object?>>[];
      Map<String, Object?>? mods;
      Map<String, Object?>? bridge = {
        'saved': false,
        'chats': [10],
      };
      final service = TelegramService(
        keys: _keys,
        engineFactory: () => engine,
        directory: () async => Directory.systemTemp,
        readAccount: () => {'enabled': true, 'dbKey': _dbKey},
        writeAccount: (_) async {},
        readMods: () =>
            mods ??
            {
              'hidden': ['secret'],
            },
        writeMods: (m) => mods = m,
        readBridge: () => bridge,
        writeBridge: (b) => bridge = b,
        bridgeOut: relayed.add,
      );
      await service.start();
      await until(() => service.client?.auth == TgAuth.ready);
      await until(() => service.client!.chats.containsKey(10));
      engine.emit({
        '@type': 'updateNewMessage',
        'message': FakeTdEngine.message(id: 1, chatId: 10, text: 'a secret'),
      });
      engine.emit({
        '@type': 'updateNewMessage',
        'message': FakeTdEngine.message(id: 2, chatId: 10, text: 'fine'),
      });
      await pump(50);
      service.dispose();
      final texts = [
        for (final batch in relayed)
          for (final item in batch['items'] as List) (item as Map)['text'],
      ];
      expect(texts, ['fine']);
    });
  });

  group('models', () {
    test('odd TDLib shapes degrade instead of throwing', () {
      expect(TgMessage.parse(null), isNull);
      expect(TgMessage.parse({'id': 1}), isNull);
      expect(TgContent.parse(42).kind, TgContentKind.other);
      expect(TgContent.parse({'@type': 'messagePoll'}).typeName, 'messagePoll');
      expect(tdInt('9007199254740993'), 9007199254740993);
      expect(tdText('a' * 500, 10).length, 10);
    });

    test('reactions are bounded', () {
      final (counts, _) = TgMessage.parseReactions({
        'reactions': {
          'reactions': [
            for (var i = 0; i < 100; i++)
              {
                'type': {'@type': 'reactionTypeEmoji', 'emoji': 'e$i'},
                'total_count': 1,
              },
          ],
        },
      });
      expect(counts.length, maxTelegramReactions);
    });
  });
}

/// A fake whose close takes a while, like TDLib closing its database.
class _SlowCloseEngine extends FakeTdEngine {
  _SlowCloseEngine({required this.onOpen, required this.onClosed})
    : super(loggedIn: true) {
    onOpen();
  }

  final void Function() onOpen;
  final void Function() onClosed;
  bool _counted = true;

  @override
  Future<void> close() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await super.close();
    if (_counted) {
      _counted = false;
      onClosed();
    }
  }
}
