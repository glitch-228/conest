import 'package:conest/src/discord/discord_api.dart';

/// Discord's REST API in memory: bots with tokens, channels with messages
/// (newest first, snowflake ids), 401/403/429 errors, and user accounts
/// with guilds for the client.
class FakeDiscord {
  final Map<String, FakeDiscordAccount> _byToken = {};
  final Map<String, List<Map<String, Object?>>> channels = {};
  final Set<String> botsInChannel = {};
  int _nextId = 1100000000000000000;
  final List<String> calls = [];

  String newId() => '${_nextId++}';

  FakeDiscordAccount addBot(String name) {
    final id = newId();
    final account = FakeDiscordAccount(
      this,
      id,
      name,
      bot: true,
    )..token = 'MTAwMDAwMDAwMDAwMDAwMDAw.GabcDe.${'x' * 27}${id.substring(15)}';
    _byToken[account.token] = account;
    return account;
  }

  FakeDiscordAccount addUser(String name) {
    final id = newId();
    final account = FakeDiscordAccount(this, id, name, bot: false)
      ..token = 'user-token-$id-${'u' * 40}';
    _byToken[account.token] = account;
    return account;
  }

  String addChannel({List<FakeDiscordAccount> members = const []}) {
    final id = newId();
    channels[id] = [];
    for (final member in members) {
      member.channelIds.add(id);
    }
    return id;
  }

  Map<String, Object?> post(
    String channelId,
    FakeDiscordAccount author,
    String content,
  ) {
    final message = {
      'id': newId(),
      'channel_id': channelId,
      'content': content,
      'author': {
        'id': author.id,
        'username': author.name,
        if (author.bot) 'bot': true,
      },
      'timestamp': '2026-10-28T10:00:00.000000+00:00',
    };
    channels[channelId]!.insert(0, message);
    return message;
  }

  DiscordNetwork get network => DiscordNetwork(
    api: (token, auth) => _FakeApi(this, token, auth),
    pollInterval: const Duration(milliseconds: 30),
  );
}

class FakeDiscordAccount {
  FakeDiscordAccount(this.hub, this.id, this.name, {required this.bot});
  final FakeDiscord hub;
  final String id;
  final String name;
  final bool bot;
  late final String token;
  bool revoked = false;
  final Set<String> channelIds = {};

  /// Servers the account is in: id to name, and their channels.
  final Map<String, String> guilds = {};
  final Map<String, List<Map<String, Object?>>> guildChannels = {};
  final List<Map<String, Object?>> dms = [];
  final List<DiscordException> failNext = [];

  /// Errors for the next sends only (not reads).
  final List<DiscordException> failNextPost = [];
  final List<Map> bodies = [];
  final List<({String channel, String content})> sent = [];
}

class _FakeApi implements DiscordApi {
  _FakeApi(this.hub, this.token, this.auth);
  final FakeDiscord hub;
  final String token;
  final DiscordAuth auth;

  @override
  Future<Object?> call(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    hub.calls.add('${auth.name} $method $path');
    final account = hub._byToken[token];
    if (account == null ||
        account.revoked ||
        (auth == DiscordAuth.bot) != account.bot) {
      throw DiscordException(path, 401, '401: Unauthorized');
    }
    if (account.failNext.isNotEmpty) throw account.failNext.removeAt(0);
    if (method == 'GET' && path == '/users/@me') {
      return {
        'id': account.id,
        'username': account.name,
        if (account.bot) 'bot': true,
      };
    }
    if (method == 'GET' && path == '/users/@me/guilds') {
      return [
        for (final e in account.guilds.entries) {'id': e.key, 'name': e.value},
      ];
    }
    if (method == 'GET' && path == '/users/@me/channels') return account.dms;
    final guild = RegExp(r'^/guilds/(\d+)/channels$').firstMatch(path);
    if (method == 'GET' && guild != null) {
      return account.guildChannels[guild.group(1)] ?? [];
    }
    final item = RegExp(
      r'^/channels/(\d+)/messages/(\d+)(/reactions/.*)?$',
    ).firstMatch(path);
    if (item != null) {
      final id = item.group(1)!;
      if (!account.channelIds.contains(id)) {
        throw DiscordException(path, 403, 'Missing Access');
      }
      final list = hub.channels[id]!;
      final index = list.indexWhere((m) => m['id'] == item.group(2));
      if (index < 0) throw DiscordException(path, 404, 'Unknown Message');
      if (item.group(3) != null) {
        (list[index]['reactions'] ??= <Map<String, Object?>>[]);
        (list[index]['reactions'] as List).add({
          'emoji': {'name': Uri.decodeComponent(item.group(3)!.split('/')[2])},
          'count': 1,
        });
        account.sent.add((channel: id, content: 'REACT ${item.group(3)}'));
        return null;
      }
      final author = (list[index]['author'] as Map)['id'];
      if (author != account.id) {
        throw DiscordException(
          path,
          403,
          'Cannot edit a message authored by another user',
        );
      }
      if (method == 'PATCH') {
        list[index]['content'] = (body as Map)['content'];
        list[index]['edited_timestamp'] = '2026-10-28T11:00:00+00:00';
        account.sent.add((channel: id, content: 'EDIT ${(body)['content']}'));
        return list[index];
      }
      if (method == 'DELETE') {
        list.removeAt(index);
        account.sent.add((channel: id, content: 'DELETE'));
        return null;
      }
    }
    final channel = RegExp(r'^/channels/(\d+)/messages$').firstMatch(path);
    if (channel != null) {
      final id = channel.group(1)!;
      if (!hub.channels.containsKey(id)) {
        throw DiscordException(path, 404, 'Unknown Channel');
      }
      if (!account.channelIds.contains(id)) {
        throw DiscordException(path, 403, 'Missing Access');
      }
      if (method == 'GET') {
        final limit = int.parse(query?['limit'] ?? '50');
        final after = query?['after'];
        final before = query?['before'];
        var list = hub.channels[id]!;
        if (before != null) {
          list = [
            for (final m in list)
              if (BigInt.parse(m['id']! as String) < BigInt.parse(before)) m,
          ];
        }
        if (after != null) {
          list = [
            for (final m in list)
              if (BigInt.parse(m['id']! as String) > BigInt.parse(after)) m,
          ];
        }
        return list.take(limit).toList();
      }
      if (method == 'POST') {
        final data = body as Map;
        final content = data['content'] as String;
        if (content.length > 2000) {
          throw DiscordException(path, 400, 'Must be 2000 or fewer in length.');
        }
        if (account.failNextPost.isNotEmpty) {
          throw account.failNextPost.removeAt(0);
        }
        account.bodies.add(data);
        account.sent.add((channel: id, content: content));
        return hub.post(id, account, content);
      }
    }
    throw DiscordException(path, 404, 'Unknown');
  }

  @override
  void close() {}
}
