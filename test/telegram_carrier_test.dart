import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/telegram/telegram_bot_api.dart';
import 'package:conest/src/telegram/telegram_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_telegram_bots.dart';

class _Side {
  _Side(FakeTelegramBots hub, this.bot, {Duration sendSpacing = Duration.zero})
    : config = TelegramBotConfig(
        token: bot.token,
        username: bot.username,
        botId: bot.id,
      ) {
    channel = TelegramCarrierChannel(
      config: config,
      api: hub.network.botApi(bot.token),
      onFrame: (sender, frame) => received.add((sender, frame)),
      pollTimeout: const Duration(milliseconds: 300),
      retryDelay: const Duration(milliseconds: 10),
      sendSpacing: sendSpacing,
      wait: (delay) async {
        waits.add(delay);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
    );
  }

  final FakeBot bot;
  final TelegramBotConfig config;
  late final TelegramCarrierChannel channel;
  final received = <(String, Uint8List)>[];
  final waits = <Duration>[];
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  test('a frame goes from one bot to the other and arrives intact', () async {
    final hub = FakeTelegramBots();
    final alice = _Side(hub, hub.addBot('alice_conest_bot'));
    final bob = _Side(hub, hub.addBot('bob_conest_bot'));
    alice.channel.start();
    bob.channel.start();
    addTearDown(alice.channel.stop);
    addTearDown(bob.channel.stop);
    await until(() => bob.channel.state == TelegramCarrierState.connected);
    expect(alice.channel.localAddress, 'alice_conest_bot');
    final frame = Uint8List.fromList(List.generate(2800, (i) => i % 256));
    await alice.channel.sendFrame('bob_conest_bot', frame);
    await until(() => bob.received.isNotEmpty);
    expect(bob.received.single.$1, 'alice_conest_bot');
    expect(bob.received.single.$2, frame);
    // A full frame fits a message.
    expect(alice.bot.sent.single.$2.length, lessThanOrEqualTo(4096));
  });

  test('only frames from other bots in private chats are read', () async {
    final hub = FakeTelegramBots();
    final bobBot = hub.addBot('bob_conest_bot');
    final bob = _Side(hub, bobBot);
    bob.channel.start();
    addTearDown(bob.channel.stop);
    final good = base64.encode([1, 2, 3]);
    // A person (not a bot), a group, our own bot, bad text, too long.
    bobBot.deliver(
      fromId: 5,
      isBot: false,
      fromUsername: 'sneaky_conest_bot',
      text: good,
    );
    bobBot.deliver(
      fromId: 6,
      isBot: true,
      fromUsername: 'x_conest_bot',
      text: good,
      chatType: 'group',
    );
    bobBot.deliver(
      fromId: bobBot.id,
      isBot: true,
      fromUsername: 'bob_conest_bot',
      text: good,
    );
    bobBot.deliver(
      fromId: 7,
      isBot: true,
      fromUsername: 'y_conest_bot',
      text: 'hello there',
    );
    bobBot.deliver(
      fromId: 8,
      isBot: true,
      fromUsername: 'z_conest_bot',
      text: 'A' * 5000,
    );
    bobBot.deliver(
      fromId: 9,
      isBot: true,
      fromUsername: 'w_conest_bot',
      text: good,
    );
    await until(() => bob.received.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(bob.received.map((e) => e.$1), ['w_conest_bot']);
  });

  test('a token Telegram stops accepting ends the carrier', () async {
    final hub = FakeTelegramBots();
    final bot = hub.addBot('bob_conest_bot');
    final side = _Side(hub, bot);
    side.channel.start();
    await until(() => side.channel.state == TelegramCarrierState.connected);
    bot.revoked = true;
    bot.deliver(
      fromId: 1,
      isBot: true,
      fromUsername: 'a_conest_bot',
      text: 'AA==',
    );
    await until(() => side.channel.state == TelegramCarrierState.failed);
    expect(side.channel.lastError, contains('token'));
    final callsBefore = hub.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // It does not keep hammering Telegram with a dead token.
    expect(hub.calls.length, callsBefore);
  });

  test('a second reader of the same bot stops the carrier', () async {
    final hub = FakeTelegramBots();
    final bot = hub.addBot('bob_conest_bot');
    final side = _Side(hub, bot);
    bot.failNext.add(const TelegramBotException('getUpdates', 409, 'Conflict'));
    side.channel.start();
    await until(() => side.channel.state == TelegramCarrierState.failed);
    expect(side.channel.lastError, contains('Another program'));
  });

  test('a rate limit waits the time Telegram names, then sends', () async {
    final hub = FakeTelegramBots();
    final alice = _Side(hub, hub.addBot('alice_conest_bot'));
    final bob = _Side(hub, hub.addBot('bob_conest_bot'));
    alice.channel.start();
    bob.channel.start();
    addTearDown(alice.channel.stop);
    addTearDown(bob.channel.stop);
    await until(() => alice.channel.state == TelegramCarrierState.connected);
    alice.bot.failNext.add(
      const TelegramBotException(
        'sendMessage',
        429,
        'Too Many Requests',
        retryAfter: 7,
      ),
    );
    await alice.channel.sendFrame('bob_conest_bot', Uint8List.fromList([9]));
    expect(alice.waits, contains(const Duration(seconds: 7)));
    await until(() => bob.received.isNotEmpty);
  });

  test('a refusal explains that both bots need bot-to-bot messaging', () async {
    final hub = FakeTelegramBots();
    final alice = _Side(hub, hub.addBot('alice_conest_bot'));
    hub.addBot('bob_conest_bot', botToBot: false);
    alice.channel.start();
    addTearDown(alice.channel.stop);
    await expectLater(
      alice.channel.sendFrame('bob_conest_bot', Uint8List(3)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('bot-to-bot'),
        ),
      ),
    );
  });

  test('frames are spaced one a second per Telegram rules', () async {
    final hub = FakeTelegramBots();
    final alice = _Side(
      hub,
      hub.addBot('alice_conest_bot'),
      sendSpacing: const Duration(milliseconds: 1100),
    );
    hub.addBot('bob_conest_bot');
    alice.channel.start();
    addTearDown(alice.channel.stop);
    await alice.channel.sendFrame('bob_conest_bot', Uint8List(3));
    await alice.channel.sendFrame('bob_conest_bot', Uint8List(3));
    expect(
      alice.waits.where((d) => d == const Duration(milliseconds: 1100)).length,
      greaterThanOrEqualTo(1),
    );
  });

  test('sends to anything but a bot name or to itself are refused', () async {
    final hub = FakeTelegramBots();
    final alice = _Side(hub, hub.addBot('alice_conest_bot'));
    alice.channel.start();
    addTearDown(alice.channel.stop);
    expect(
      () => alice.channel.sendFrame('someone', Uint8List(1)),
      throwsArgumentError,
    );
    expect(
      () => alice.channel.sendFrame('alice_conest_bot', Uint8List(1)),
      throwsArgumentError,
    );
    expect(
      () => alice.channel.sendFrame('-1001234', Uint8List(1)),
      throwsArgumentError,
    );
  });

  test('setting up a bot checks the token with Telegram', () async {
    final hub = FakeTelegramBots();
    final bot = hub.addBot('Bob_Conest_Bot');
    final config = await checkTelegramBot('  ${bot.token} ', hub.network);
    expect(config.username, 'bob_conest_bot');
    expect(config.botId, bot.id);
    expect(TelegramBotConfig.fromJson(config.toJson())?.token, bot.token);
    await expectLater(
      checkTelegramBot('not a token', hub.network),
      throwsArgumentError,
    );
    bot.revoked = true;
    await expectLater(
      checkTelegramBot(bot.token, hub.network),
      throwsA(isA<StateError>()),
    );
    expect(TelegramBotConfig.fromJson({'token': 'x'}), isNull);
  });

  test('an I/O error that quotes the token never shows it', () async {
    const token = '123456:TOKEN_TOKEN_TOKEN_TOKEN_TOKEN_00';
    final api = _ThrowingApi(
      HttpException(
        'Connection closed',
        uri: Uri.parse('https://api.telegram.org/bot$token/getUpdates'),
      ),
    );
    final channel = TelegramCarrierChannel(
      config: const TelegramBotConfig(
        token: token,
        username: 'bob_conest_bot',
        botId: 123456,
      ),
      api: api,
      onFrame: (_, _) {},
      retryDelay: const Duration(milliseconds: 5),
      sendSpacing: Duration.zero,
      wait: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
    )..start();
    addTearDown(channel.stop);
    await until(() => channel.state == TelegramCarrierState.failed);
    expect(channel.lastError, isNotNull);
    expect(channel.lastError, isNot(contains('TOKEN_TOKEN')));
    Object? sendError;
    try {
      await channel.sendFrame('alice_conest_bot', Uint8List(2));
    } catch (error) {
      sendError = error;
    }
    expect(sendError, isNotNull);
    expect('$sendError', isNot(contains('TOKEN_TOKEN')));
  });

  test('the HTTP client scrubs the token from I/O errors', () async {
    const token = '123456:TOKEN_TOKEN_TOKEN_TOKEN_TOKEN_00';
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(raw.close);
    raw.listen((socket) {
      socket.add(utf8.encode('GARBAGE\r\n\r\n'));
      socket.close();
    });
    final api = HttpTelegramBotApi(
      token,
      apiRoot: Uri.parse('http://127.0.0.1:${raw.port}'),
    );
    try {
      await api.call('getMe');
      fail('should throw');
    } on TelegramBotException catch (error) {
      expect(error.toString(), isNot(contains('TOKEN_TOKEN')));
    }
  });

  group('the HTTP Bot API', () {
    late HttpServer server;
    late List<String> paths;
    late Map<String, Object?> Function(String path, Object? body) answer;

    setUp(() async {
      paths = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        paths.add(request.uri.path);
        final reply = answer(request.uri.path, jsonDecode(body));
        request.response
          ..statusCode = (reply['error_code'] as int?) ?? 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(reply));
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    HttpTelegramBotApi api(String token) => HttpTelegramBotApi(
      token,
      apiRoot: Uri.parse('http://127.0.0.1:${server.port}'),
    );

    test('calls go to /bot<token>/<method> with JSON', () async {
      Object? seen;
      answer = (path, body) {
        seen = body;
        return {
          'ok': true,
          'result': {'id': 1},
        };
      };
      final result = await api(
        '123456:TOKEN_TOKEN_TOKEN_TOKEN_TOKEN_00',
      ).call('getMe', {'a': 1});
      expect(result, {'id': 1});
      expect(paths.single, '/bot123456:TOKEN_TOKEN_TOKEN_TOKEN_TOKEN_00/getMe');
      expect(seen, {'a': 1});
    });

    test('errors carry the code and retry time, never the token', () async {
      const token = '123456:TOKEN_TOKEN_TOKEN_TOKEN_TOKEN_00';
      answer = (path, body) => {
        'ok': false,
        'error_code': 429,
        'description': 'Too Many Requests: retry after 5 for $token',
        'parameters': {'retry_after': 5},
      };
      try {
        await api(token).call('sendMessage');
        fail('should throw');
      } on TelegramBotException catch (error) {
        expect(error.rateLimited, isTrue);
        expect(error.retryAfter, 5);
        expect(error.toString(), isNot(contains(token)));
      }
    });
  });
}

class _ThrowingApi implements TelegramBotApi {
  _ThrowingApi(this.error);
  final Object error;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async => throw error;

  @override
  void close() {}
}
