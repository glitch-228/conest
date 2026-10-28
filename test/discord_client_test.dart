import 'package:conest/src/discord/discord_api.dart';
import 'package:conest/src/discord/discord_client.dart';
import 'package:conest/src/discord/discord_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_discord.dart';

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  late FakeDiscord hub;
  late FakeDiscordAccount me;
  late FakeDiscordAccount friend;
  late String guildId;
  late String general;
  late String dm;

  setUp(() {
    hub = FakeDiscord();
    me = hub.addUser('me');
    friend = hub.addUser('friend');
    guildId = hub.newId();
    general = hub.addChannel(members: [me, friend]);
    dm = hub.addChannel(members: [me, friend]);
    me.guilds[guildId] = 'Club';
    me.guildChannels[guildId] = [
      {'id': general, 'name': 'general', 'type': 0},
      {'id': hub.newId(), 'name': 'voice', 'type': 2},
    ];
    me.dms.add({
      'id': dm,
      'type': 1,
      'recipients': [
        {'id': friend.id, 'username': 'friend'},
      ],
    });
    hub.post(general, friend, 'hello everyone');
    hub.post(general, me, 'mine');
  });

  DiscordClient client() {
    final c = DiscordClient(
      api: hub.network.api(me.token, DiscordAuth.user),
      pollInterval: const Duration(milliseconds: 20),
    );
    addTearDown(c.dispose);
    return c;
  }

  test('starting loads servers and direct messages, nothing is sent', () async {
    final c = client();
    await c.start();
    expect(c.signedIn, isTrue);
    expect(c.selfName, 'me');
    expect(c.guilds.single.name, 'Club');
    expect(c.dms.single.name, 'friend');
    await c.loadChannels(guildId);
    // Voice channels are not shown.
    expect(c.channelsOf(guildId).map((e) => e.name), ['general']);
    expect(hub.calls.where((e) => e.contains('POST')), isEmpty);
    expect(me.sent, isEmpty);
  });

  test('a bot token is not a user account', () async {
    final bot = hub.addBot('b');
    final c = DiscordClient(api: hub.network.api(bot.token, DiscordAuth.user));
    addTearDown(c.dispose);
    // The fake refuses the mismatch like Discord does.
    await expectLater(c.start(), throwsA(isA<DiscordException>()));
    expect(c.signedIn, isFalse);
    expect(c.error, contains('token'));
  });

  test('messages load newest page, then older ones', () async {
    final c = client();
    await c.start();
    for (var i = 0; i < 70; i++) {
      hub.post(general, friend, 'm$i');
    }
    await c.loadMessages(general);
    expect(c.messagesOf(general).length, 50);
    expect(c.messagesOf(general).last.text, 'm69');
    await c.loadMessages(general, older: true);
    expect(c.messagesOf(general).length, 72);
    expect(c.messagesOf(general).first.text, 'hello everyone');
  });

  test('a channel keeps only a bounded number of messages', () async {
    final c = client();
    await c.start();
    for (var i = 0; i < 300; i++) {
      hub.post(general, friend, 'b$i');
    }
    for (var page = 0; page < 6; page++) {
      await c.loadMessages(general, older: page > 0);
    }
    expect(c.messagesOf(general).length, maxDiscordMessages);
  });

  test('only the open channel is watched, and watching stops', () async {
    final c = client();
    await c.start();
    await c.loadMessages(general);
    final stop = c.watch(general);
    hub.post(general, friend, 'fresh');
    await until(() => c.messagesOf(general).any((m) => m.text == 'fresh'));
    stop();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final calls = hub.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hub.calls.length, calls);
    // The other channel was never asked about.
    expect(hub.calls.where((e) => e.contains('/channels/$dm/')), isEmpty);
  });

  test(
    'others\' edits, deletions and reactions show up in the open channel',
    () async {
      final c = client();
      await c.start();
      await c.loadMessages(general);
      final stop = c.watch(general);
      addTearDown(stop);
      final hello = hub.channels[general]!.firstWhere(
        (m) => m['content'] == 'hello everyone',
      );
      hello['content'] = 'hello, edited';
      hello['edited_timestamp'] = '2026-10-28T12:00:00+00:00';
      await until(
        () => c
            .messagesOf(general)
            .any((m) => m.text == 'hello, edited' && m.edited),
      );
      hello['reactions'] = [
        {
          'emoji': {'name': '🎉'},
          'count': 2,
        },
      ];
      await until(
        () => c.messagesOf(general).any((m) => m.reactions['🎉'] == 2),
      );
      hub.channels[general]!.remove(hello);
      await until(() => !c.messagesOf(general).any((m) => m.id == hello['id']));
      // Mine is still there.
      expect(c.messagesOf(general).any((m) => m.text == 'mine'), isTrue);
    },
  );

  test('one failed look does not stop watching', () async {
    final c = client();
    await c.start();
    await c.loadMessages(general);
    final stop = c.watch(general);
    addTearDown(stop);
    me.failNext
      ..add(const DiscordException('/x', 403, 'Missing Access'))
      ..add(const DiscordException('/x', 500, 'oops'));
    hub.post(general, friend, 'after the errors');
    await until(
      () => c.messagesOf(general).any((m) => m.text == 'after the errors'),
    );
    expect(c.error, isNull);
  });

  test('sending, editing, reacting and deleting happen on request', () async {
    final c = client();
    await c.start();
    await c.loadMessages(general);
    await c.send(general, 'hi there');
    expect(me.sent.last.content, 'hi there');
    final mine = c.messagesOf(general).firstWhere((m) => m.text == 'hi there');
    await c.edit(general, mine.id, 'hi again');
    expect(c.messagesOf(general).any((m) => m.text == 'hi again'), isTrue);
    expect(
      c.messagesOf(general).firstWhere((m) => m.id == mine.id).edited,
      isTrue,
    );
    final theirs = c
        .messagesOf(general)
        .firstWhere((m) => m.text == 'hello everyone');
    await expectLater(c.edit(general, theirs.id, 'x'), throwsStateError);
    await c.react(general, theirs.id, '👍');
    expect(
      c.messagesOf(general).firstWhere((m) => m.id == theirs.id).reactions,
      {'👍': 1},
    );
    await c.delete(general, mine.id);
    expect(c.messagesOf(general).any((m) => m.id == mine.id), isFalse);
    await expectLater(c.send(general, 'a' * 2001), throwsArgumentError);
    await c.send(general, '   ');
    expect(me.sent.where((e) => e.content.trim().isEmpty), isEmpty);
  });

  test('mentions in sent text can ping users but never everyone', () async {
    final c = client();
    await c.start();
    await c.send(general, 'hey @everyone');
    // The request allows user mentions only.
    expect(me.bodies.last['allowed_mentions'], {
      'parse': ['users'],
    });
  });

  test('odd message shapes degrade', () {
    expect(DcMessage.parse(null), isNull);
    expect(DcMessage.parse({'id': 'x'}), isNull);
    final m = DcMessage.parse({
      'id': '1100000000000000001',
      'channel_id': '1100000000000000002',
      'author': {'id': '1100000000000000003', 'username': 'u'},
      'content': 'a' * 9000,
      'attachments': [
        {'url': 'http://insecure/x', 'filename': 'a'},
        {'url': 'https://cdn/x', 'filename': 'b'},
      ],
    })!;
    expect(m.text.length, maxDiscordTextChars);
    expect(m.attachments.map((e) => e.name), ['b']);
  });

  group('service', () {
    Future<DiscordService> service(
      Map<String, Object?>? Function() read,
      Future<void> Function(Map<String, Object?>?) write,
    ) async {
      final s = DiscordService(
        network: hub.network,
        readAccount: read,
        writeAccount: write,
      );
      addTearDown(s.dispose);
      return s;
    }

    test(
      'needs the warning accepted, a user token, and keeps it saved',
      () async {
        Map<String, Object?>? saved;
        final s = await service(() => saved, (a) async => saved = a);
        await expectLater(
          s.enable(me.token, acceptedRisk: false),
          throwsStateError,
        );
        expect(saved, isNull);
        expect(hub.calls, isEmpty);
        await expectLater(
          s.enable('short', acceptedRisk: true),
          throwsArgumentError,
        );
        await s.enable(me.token, acceptedRisk: true);
        expect(s.enabled, isTrue);
        expect(s.client!.signedIn, isTrue);
        expect(saved!['accepted'], isTrue);
        // A restart starts it again without asking.
        final again = await service(() => saved, (a) async => saved = a);
        expect(again.client, isNull);
        await again.start();
        expect(again.client!.signedIn, isTrue);
        await again.disable();
        expect(saved, isNull);
        expect(again.client, isNull);
      },
    );

    test('a saved token without the acceptance is not used', () async {
      final saved = <String, Object?>{'enabled': true, 'token': me.token};
      final s = await service(() => saved, (a) async {});
      await s.start();
      expect(s.client, isNull);
      expect(hub.calls, isEmpty);
    });

    test('a rejected token is not saved', () async {
      Map<String, Object?>? saved;
      final s = await service(() => saved, (a) async => saved = a);
      me.revoked = true;
      await expectLater(
        s.enable(me.token, acceptedRisk: true),
        throwsA(isA<DiscordException>()),
      );
      expect(saved, isNull);
      expect(s.client, isNull);
    });
  });
}
