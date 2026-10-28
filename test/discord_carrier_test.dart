import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/carrier.dart';
import 'package:conest/src/discord/discord_api.dart';
import 'package:conest/src/telegram/telegram_carrier.dart';
import 'package:conest/src/transport_models.dart';
import 'package:conest/src/discord/discord_carrier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_discord.dart';

class _Side {
  _Side(FakeDiscord hub, this.account, String channelId)
    : config = DiscordBotConfig(
        token: account.token,
        botId: account.id,
        username: account.name,
        channelId: channelId,
      ) {
    channel = DiscordCarrierChannel(
      config: config,
      api: hub.network.api(account.token, DiscordAuth.bot),
      onFrame: (sender, frame) => received.add((sender, frame)),
      pollInterval: const Duration(milliseconds: 10),
      retryDelay: const Duration(milliseconds: 10),
      sendSpacing: Duration.zero,
      wait: (delay) async {
        waits.add(delay);
        await Future<void>.delayed(
          delay > const Duration(milliseconds: 50)
              ? const Duration(milliseconds: 5)
              : delay,
        );
      },
    );
  }

  final FakeDiscordAccount account;
  final DiscordBotConfig config;
  late final DiscordCarrierChannel channel;
  final received = <(String, Uint8List)>[];
  final waits = <Duration>[];
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

class _PlainSealer implements CarrierSealer {
  @override
  bool acceptsSender(TransportKind kind, String sender) => true;

  @override
  Future<({String peerDeviceId, Uint8List envelope})?> open(
    TransportKind kind,
    String sender,
    Uint8List sealed,
  ) async => (peerDeviceId: sender, envelope: sealed);

  @override
  Future<Uint8List> seal(
    TransportKind kind,
    String peerDeviceId,
    Uint8List envelope,
  ) async => envelope;
}

void main() {
  test('the adapter does not claim store and forward', () {
    final adapter = createDiscordCarrierAdapter(sealer: _PlainSealer());
    expect(adapter.capabilities.supportsStoreForward, isFalse);
    expect(
      createTelegramCarrierAdapter(
        sealer: _PlainSealer(),
      ).capabilities.supportsStoreForward,
      isTrue,
    );
  });

  late FakeDiscord hub;
  late FakeDiscordAccount aliceBot;
  late FakeDiscordAccount bobBot;
  late String channel;

  setUp(() {
    hub = FakeDiscord();
    aliceBot = hub.addBot('alice-bot');
    bobBot = hub.addBot('bob-bot');
    channel = hub.addChannel(members: [aliceBot, bobBot]);
  });

  test('a frame goes from one bot to the other and arrives intact', () async {
    final alice = _Side(hub, aliceBot, channel);
    final bob = _Side(hub, bobBot, channel);
    alice.channel.start();
    bob.channel.start();
    addTearDown(alice.channel.stop);
    addTearDown(bob.channel.stop);
    await until(() => bob.channel.state == DiscordCarrierState.connected);
    expect(alice.channel.localAddress, '${aliceBot.id}|$channel');
    final frame = Uint8List.fromList(List.generate(1300, (i) => i % 256));
    await alice.channel.sendFrame(bob.config.address, frame);
    await until(() => bob.received.isNotEmpty);
    expect(bob.received.single.$1, aliceBot.id);
    expect(bob.received.single.$2, frame);
    // The post pings only the other bot and fits 2000 characters.
    final posted = aliceBot.sent.single.content;
    expect(posted, startsWith('<@${bobBot.id}> '));
    expect(posted.length, lessThanOrEqualTo(2000));
    expect(aliceBot.bodies.single['allowed_mentions'], {
      'parse': <String>[],
      'users': [bobBot.id],
    });
    // Alice never reads her own frame.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(alice.received, isEmpty);
  });

  test('only bots mentioning this bot with base64 text are read', () async {
    final bob = _Side(hub, bobBot, channel);
    final person = hub.addUser('person');
    final other = hub.addBot('other-bot');
    person.channelIds.add(channel);
    other.channelIds.add(channel);
    bob.channel.start();
    addTearDown(bob.channel.stop);
    await until(() => bob.channel.state == DiscordCarrierState.connected);
    final good = base64.encode([1, 2, 3]);
    hub.post(channel, person, '<@${bobBot.id}> $good'); // not a bot
    hub.post(channel, other, '<@${aliceBot.id}> $good'); // for someone else
    hub.post(channel, other, good); // no mention
    hub.post(channel, other, '<@${bobBot.id}> hello there'); // not base64
    hub.post(channel, other, '<@${bobBot.id}> ${'A' * 3000}'); // too long
    hub.post(channel, bobBot, '<@${bobBot.id}> $good'); // our own
    hub.post(channel, other, '<@${bobBot.id}> $good'); // the one
    await until(() => bob.received.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(bob.received.map((e) => e.$1), [other.id]);
  });

  test('frames from before the carrier started are not replayed', () async {
    final bob = _Side(hub, bobBot, channel);
    hub.post(channel, aliceBot, '<@${bobBot.id}> ${base64.encode([9])}');
    bob.channel.start();
    addTearDown(bob.channel.stop);
    await until(() => bob.channel.state == DiscordCarrierState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(bob.received, isEmpty);
  });

  test('a revoked token or lost channel access ends the carrier', () async {
    final bob = _Side(hub, bobBot, channel);
    bob.channel.start();
    await until(() => bob.channel.state == DiscordCarrierState.connected);
    bobBot.revoked = true;
    await until(() => bob.channel.state == DiscordCarrierState.failed);
    expect(bob.channel.lastError, contains('token'));
    final calls = hub.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(hub.calls.length, calls);

    final alice = _Side(hub, aliceBot, channel);
    alice.channel.start();
    await until(() => alice.channel.state == DiscordCarrierState.connected);
    aliceBot.channelIds.clear();
    await until(() => alice.channel.state == DiscordCarrierState.failed);
    expect(alice.channel.lastError, contains('channel'));
  });

  test(
    'idle polling backs off, resets on activity and obeys the slowdown',
    () async {
      final waits = <Duration>[];
      var factor = 1;
      final bob = DiscordCarrierChannel(
        config: DiscordBotConfig(
          token: bobBot.token,
          botId: bobBot.id,
          username: 'b',
          channelId: channel,
        ),
        api: hub.network.api(bobBot.token, DiscordAuth.bot),
        onFrame: (_, _) {},
        pollInterval: const Duration(milliseconds: 10),
        maxIdleInterval: const Duration(milliseconds: 80),
        slowdown: () => factor,
        wait: (delay) async {
          waits.add(delay);
          await Future<void>.delayed(const Duration(milliseconds: 2));
        },
      )..start();
      addTearDown(bob.stop);
      await until(() => waits.length >= 10);
      expect(waits.first, const Duration(milliseconds: 10));
      expect(
        waits.reduce((a, b) => a > b ? a : b),
        const Duration(milliseconds: 80),
      );
      expect(waits.where((w) => w > const Duration(milliseconds: 80)), isEmpty);
      // A frame brings the fast pace back.
      final mark = waits.length;
      hub.post(channel, aliceBot, '<@${bobBot.id}> ${base64.encode([1])}');
      await until(
        () =>
            waits.skip(mark).any((w) => w == const Duration(milliseconds: 10)),
      );
      // Background or battery saver: slower again, but bounded.
      factor = 3;
      final mark2 = waits.length;
      await until(() => waits.length >= mark2 + 6);
      expect(
        waits
            .skip(mark2 + 3)
            .every((w) => w >= const Duration(milliseconds: 30)),
        isTrue,
      );
      expect(
        waits.skip(mark2).every((w) => w <= const Duration(milliseconds: 160)),
        isTrue,
      );
    },
  );

  test('a send cuts the idle wait short', () async {
    var looks = 0;
    final api = hub.network.api(bobBot.token, DiscordAuth.bot);
    final counting = _CountingApi(api, onPoll: () => looks++);
    final bob = DiscordCarrierChannel(
      config: DiscordBotConfig(
        token: bobBot.token,
        botId: bobBot.id,
        username: 'b',
        channelId: channel,
      ),
      api: counting,
      onFrame: (_, _) {},
      pollInterval: const Duration(seconds: 30),
      sendSpacing: Duration.zero,
      // Every wait is long, as after a long quiet spell.
      wait: (delay) => Future<void>.delayed(const Duration(seconds: 30)),
    )..start();
    addTearDown(bob.stop);
    await until(() => looks >= 1);
    final before = looks;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(looks, before);
    await bob.sendFrame('${aliceBot.id}|$channel', Uint8List(3));
    await until(() => looks > before);
  });

  test('the slowdown stretches every look', () async {
    final waits = <Duration>[];
    final bob = DiscordCarrierChannel(
      config: DiscordBotConfig(
        token: bobBot.token,
        botId: bobBot.id,
        username: 'b',
        channelId: channel,
      ),
      api: hub.network.api(bobBot.token, DiscordAuth.bot),
      onFrame: (_, _) {},
      pollInterval: const Duration(milliseconds: 10),
      maxIdleInterval: const Duration(milliseconds: 80),
      slowdown: () => 4,
      wait: (delay) async {
        waits.add(delay);
        await Future<void>.delayed(const Duration(milliseconds: 2));
      },
    )..start();
    addTearDown(bob.stop);
    await until(() => waits.length >= 5);
    expect(waits.every((w) => w >= const Duration(milliseconds: 40)), isTrue);
    expect(waits.every((w) => w <= const Duration(milliseconds: 160)), isTrue);
  });

  test('a rate limit waits the time Discord names, then sends', () async {
    final alice = _Side(hub, aliceBot, channel);
    final bob = _Side(hub, bobBot, channel);
    alice.channel.start();
    bob.channel.start();
    addTearDown(alice.channel.stop);
    addTearDown(bob.channel.stop);
    await until(() => bob.channel.state == DiscordCarrierState.connected);
    aliceBot.failNextPost.add(
      const DiscordException('/x', 429, 'rate limited', retryAfter: 2.5),
    );
    await alice.channel.sendFrame(bob.config.address, Uint8List(3));
    expect(alice.waits, contains(const Duration(milliseconds: 2500)));
    await until(() => bob.received.isNotEmpty);
  });

  test('a refusal says what the bot needs', () async {
    final alice = _Side(hub, aliceBot, channel);
    alice.channel.start();
    addTearDown(alice.channel.stop);
    final lonely = hub.addChannel();
    await expectLater(
      alice.channel.sendFrame('${bobBot.id}|$lonely', Uint8List(3)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Send Messages'),
        ),
      ),
    );
  });

  test('bad addresses and self-sends are refused', () async {
    final alice = _Side(hub, aliceBot, channel);
    alice.channel.start();
    addTearDown(alice.channel.stop);
    for (final bad in ['someone', '123|456', bobBot.id, '${bobBot.id}|abc']) {
      expect(
        () => alice.channel.sendFrame(bad, Uint8List(1)),
        throwsArgumentError,
      );
    }
    expect(
      () => alice.channel.sendFrame(alice.config.address, Uint8List(1)),
      throwsArgumentError,
    );
    expect(parseDiscordAddress('${bobBot.id}|$channel')?.channelId, channel);
  });

  test('setting up checks the token and the channel', () async {
    final config = await checkDiscordBot(
      ' ${aliceBot.token} ',
      channel,
      hub.network,
    );
    expect(config.botId, aliceBot.id);
    expect(DiscordBotConfig.fromJson(config.toJson())?.channelId, channel);
    await expectLater(
      checkDiscordBot('nope', channel, hub.network),
      throwsArgumentError,
    );
    await expectLater(
      checkDiscordBot(aliceBot.token, 'abc', hub.network),
      throwsArgumentError,
    );
    final hidden = hub.addChannel();
    await expectLater(
      checkDiscordBot(aliceBot.token, hidden, hub.network),
      throwsA(isA<StateError>()),
    );
    // A user account token is not a bot.
    final user = hub.addUser('u');
    await expectLater(
      checkDiscordBot(user.token, channel, hub.network),
      throwsArgumentError,
    );
    aliceBot.revoked = true;
    await expectLater(
      checkDiscordBot(aliceBot.token, channel, hub.network),
      throwsA(isA<StateError>()),
    );
  });

  group('the HTTP API', () {
    late HttpServer server;
    late List<Map<String, String>> seen;
    late int status;
    late Object body;

    setUp(() async {
      seen = [];
      status = 200;
      body = {'ok': 1};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add({
          'method': request.method,
          'path': request.uri.path,
          'query': request.uri.query,
          'auth': request.headers.value('authorization') ?? '',
        });
        await utf8.decoder.bind(request).drain<void>();
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(body));
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    HttpDiscordApi api(String token, DiscordAuth auth) => HttpDiscordApi(
      token,
      auth,
      apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v10'),
    );

    test('bots send "Bot <token>", users the bare token', () async {
      await api('abc', DiscordAuth.bot).call('GET', '/users/@me');
      await api(
        'xyz',
        DiscordAuth.user,
      ).call('GET', '/channels/1/messages', query: {'limit': '5'});
      expect(seen[0]['auth'], 'Bot abc');
      expect(seen[0]['path'], '/api/v10/users/@me');
      expect(seen[1]['auth'], 'xyz');
      expect(seen[1]['query'], 'limit=5');
    });

    test('errors carry the status and wait time, never the token', () async {
      status = 429;
      body = {'message': 'slow down TOKEN123', 'retry_after': 1.5};
      try {
        await api('TOKEN123', DiscordAuth.bot).call('POST', '/x', body: {});
        fail('should throw');
      } on DiscordException catch (error) {
        expect(error.rateLimited, isTrue);
        expect(error.retryAfter, 1.5);
        expect(error.toString(), isNot(contains('TOKEN123')));
      }
    });
  });

  test('token and id shapes', () {
    expect(isValidDiscordBotToken(aliceBot.token), isTrue);
    expect(isValidDiscordBotToken('a.b.c'), isFalse);
    expect(isDiscordId('1234567890123456789'), isTrue);
    expect(isDiscordId('12ab'), isFalse);
  });
}

class _CountingApi implements DiscordApi {
  _CountingApi(this.inner, {required this.onPoll});
  final DiscordApi inner;
  final void Function() onPoll;

  @override
  Future<Object?> call(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (method == 'GET' && path.endsWith('/messages')) onPoll();
    return inner.call(method, path, query: query, body: body, timeout: timeout);
  }

  @override
  void close() => inner.close();
}
