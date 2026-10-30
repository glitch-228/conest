import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../carrier.dart';
import '../transport_models.dart';
import 'discord_api.dart';

/// Discord messages hold 2000 characters; a frame is "<@bot> " plus base64:
/// 1300 sealed bytes are about 1750 characters. At most 24 frames per
/// envelope.
const CarrierFraming discordFraming = CarrierFraming(
  maxSealedBytes: 30 * 1024,
  chunkBytes: 1300,
);

/// The bot a user made in Discord's developer portal, and the private
/// channel the two bots share. The token is a secret kept in the vault.
class DiscordBotConfig {
  const DiscordBotConfig({
    required this.token,
    required this.botId,
    required this.username,
    required this.channelId,
  });

  final String token;
  final String botId;
  final String username;

  /// The channel frames for this bot are posted in and read from.
  final String channelId;

  /// This device's address: `botId|channelId` (the bot names the sender).
  String get address => '$botId|$channelId';

  Map<String, Object?> toJson() => {
    'token': token,
    'botId': botId,
    'username': username,
    'channelId': channelId,
  };

  static DiscordBotConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final token = json['token'];
    final botId = json['botId'];
    final channelId = json['channelId'];
    final username = json['username'];
    if (token is! String ||
        !isValidDiscordBotToken(token) ||
        botId is! String ||
        !isDiscordId(botId) ||
        channelId is! String ||
        !isDiscordId(channelId)) {
      return null;
    }
    return DiscordBotConfig(
      token: token,
      botId: botId,
      username: username is String && username.length <= 64 ? username : '',
      channelId: channelId,
    );
  }
}

/// A contact's address: `botId|channelId`.
({String botId, String channelId})? parseDiscordAddress(String address) {
  if (address.length > 64) return null;
  final parts = address.split('|');
  if (parts.length != 2 || !isDiscordId(parts[0]) || !isDiscordId(parts[1])) {
    return null;
  }
  return (botId: parts[0], channelId: parts[1]);
}

bool isValidDiscordCarrierAddress(String address) =>
    parseDiscordAddress(address) != null;

/// Checks [token] and [channelId] with Discord and returns the bot.
Future<DiscordBotConfig> checkDiscordBot(
  String token,
  String channelId,
  DiscordNetwork network,
) async {
  final trimmed = token.trim();
  final channel = channelId.trim();
  if (!isValidDiscordBotToken(trimmed)) {
    throw ArgumentError('That is not a bot token.');
  }
  if (!isDiscordId(channel)) {
    throw ArgumentError('The channel id is a long number.');
  }
  final api = network.api(trimmed, DiscordAuth.bot);
  try {
    final me = await api.call('GET', '/users/@me');
    if (me is! Map || me['bot'] != true || me['id'] is! String) {
      throw StateError('Discord did not describe a bot.');
    }
    final botId = me['id'] as String;
    if (!isDiscordId(botId)) throw StateError('Discord sent an odd bot id.');
    // The bot must see the channel.
    await api.call('GET', '/channels/$channel/messages', query: {'limit': '1'});
    return DiscordBotConfig(
      token: trimmed,
      botId: botId,
      username: me['username'] is String
          ? (me['username'] as String).substring(
              0,
              min(64, (me['username'] as String).length),
            )
          : '',
      channelId: channel,
    );
  } on DiscordException catch (error) {
    if (error.unauthorized) {
      throw StateError('Discord does not accept that bot token.');
    }
    if (error.forbidden || error.code == 404) {
      throw StateError(
        'The bot cannot see that channel. Add it to the server and give '
        'it View Channel, Read Message History and Send Messages.',
      );
    }
    rethrow;
  } finally {
    api.close();
  }
}

enum DiscordCarrierState { stopped, connecting, connected, failed }

/// The bot side of the carrier: frames are posted as messages that mention
/// the other bot (so Discord shows their text to a bot without the
/// privileged message-content permission), and read back by asking the
/// channel for what is new. Only messages written by other bots that
/// mention this bot are taken.
class DiscordCarrierChannel
    implements ManagedCarrierChannel, PeerAwareCarrierChannel {
  DiscordCarrierChannel({
    required this.config,
    required this.api,
    required this.onFrame,
    this.onStatusChanged,
    this.log,
    this.pollInterval = const Duration(seconds: 4),
    this.maxIdleInterval = const Duration(seconds: 60),
    this.slowdown,
    this.retryDelay = const Duration(seconds: 5),
    this.sendSpacing = const Duration(milliseconds: 700),
    this.onRateLimited,
    Future<void> Function(Duration delay)? wait,
  }) : _wait = wait ?? Future<void>.delayed;

  final DiscordBotConfig config;
  final DiscordApi api;
  final void Function(String sender, Uint8List frame) onFrame;

  /// Told of every wait Discord asks for (a 429's `retry_after`), so the
  /// account's limiter rests that long for every chat.
  final void Function(Duration wait)? onRateLimited;
  final void Function()? onStatusChanged;
  final void Function(String line)? log;

  /// The fastest look: right after activity.
  final Duration pollInterval;

  /// The slowest look: after a long quiet spell.
  final Duration maxIdleInterval;

  /// Extra factor from the device (battery saver, app in the background);
  /// 1 for none.
  final int Function()? slowdown;
  Duration _idle = Duration.zero;
  final Duration retryDelay;
  final Duration sendSpacing;
  final Future<void> Function(Duration delay) _wait;

  static final int _maxFrameChars =
      (discordFraming.chunkBytes + 16) * 4 ~/ 3 + 8;
  static final _base64Text = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

  DiscordCarrierState _state = DiscordCarrierState.stopped;
  String? _lastError;
  bool _running = false;
  String? _after;
  Future<void> _sendQueue = Future.value();
  int _queued = 0;
  final Random _random = Random.secure();

  DiscordCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress => config.address;

  @override
  String get routeLabel => 'Discord bot ${config.username}';

  void _set(DiscordCarrierState state, [String? error]) {
    if (_state == state && _lastError == error) return;
    _state = state;
    _lastError = error;
    onStatusChanged?.call();
  }

  @override
  void start() {
    if (_running) return;
    _running = true;
    _set(DiscordCarrierState.connecting);
    unawaited(_poll());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _set(DiscordCarrierState.stopped);
    api.close();
  }

  @override
  void updatePeers(Set<String> addresses) {}

  Future<void> _poll() async {
    var failures = 0;
    var first = true;
    while (_running) {
      try {
        final result = await api.call(
          'GET',
          '/channels/${config.channelId}/messages',
          query: {'limit': first ? '1' : '50', 'after': ?_after},
        );
        if (!_running) return;
        failures = 0;
        _set(DiscordCarrierState.connected);
        var delivered = 0;
        if (result is List) {
          // Newest first; handle oldest first.
          final messages = result.whereType<Map>().take(100).toList().reversed;
          for (final message in messages) {
            final id = message['id'];
            if (id is String && isDiscordId(id)) {
              if (_after == null || _newer(id, _after!)) _after = id;
            }
            // The very first look only finds where "now" is: older frames
            // were for an earlier run and are in the sender's retry queue.
            if (!first && _onMessage(message)) delivered++;
          }
        }
        first = false;
        await _sleep(_nextLook(gotFrames: delivered > 0));
      } on DiscordException catch (error) {
        if (!_running) return;
        if (error.unauthorized || error.forbidden || error.code == 404) {
          _running = false;
          _set(
            DiscordCarrierState.failed,
            error.unauthorized
                ? 'Discord no longer accepts the bot token.'
                : 'The bot cannot see its channel any more.',
          );
          return;
        }
        failures++;
        _set(DiscordCarrierState.failed, error.toString());
        // Only the account-wide limit rests the whole account; one route's
        // bucket is waited out on that route (below).
        if (error.slowDownFor case final wait?) onRateLimited?.call(wait);
        await _wait(
          error.retryAfter != null
              ? Duration(
                  milliseconds: (min(error.retryAfter!, 3600) * 1000).ceil(),
                )
              : _backoff(failures),
        );
      } catch (error) {
        if (!_running) return;
        failures++;
        _set(DiscordCarrierState.failed, error.toString());
        await _wait(_backoff(failures));
      }
    }
  }

  static bool _newer(String a, String b) =>
      a.length != b.length ? a.length > b.length : a.compareTo(b) > 0;

  Duration _backoff(int failures) {
    final base = retryDelay.inMilliseconds * (1 << min(failures - 1, 5));
    return Duration(
      milliseconds: base + _random.nextInt(retryDelay.inMilliseconds + 1),
    );
  }

  /// The wait before the next look: short while frames flow, longer and
  /// longer (up to [maxIdleInterval]) while nothing happens, and longer
  /// again when the device asks to save energy.
  Duration _nextLook({required bool gotFrames}) {
    if (gotFrames || _recentSend) {
      _idle = Duration.zero;
      _recentSend = false;
    } else {
      final next = _idle == Duration.zero ? pollInterval : _idle * 3 ~/ 2;
      _idle = next > maxIdleInterval ? maxIdleInterval : next;
    }
    final base = _idle == Duration.zero ? pollInterval : _idle;
    final factor = (slowdown?.call() ?? 1).clamp(1, 20);
    final wait = base * factor;
    return wait > maxIdleInterval * 2 ? maxIdleInterval * 2 : wait;
  }

  bool _recentSend = false;
  Completer<void>? _wake;

  /// Waits [delay], or less when a send wakes the loop: an answer to what
  /// was just sent should not wait out a long idle pause.
  Future<void> _sleep(Duration delay) {
    if (_recentSend) return Future.value();
    final wake = _wake = Completer<void>();
    return Future.any([_wait(delay), wake.future]);
  }

  bool _onMessage(Map message) {
    final author = message['author'];
    final content = message['content'];
    if (author is! Map || content is! String) return false;
    final sender = author['id'];
    if (author['bot'] != true || sender is! String || !isDiscordId(sender)) {
      return false;
    }
    if (sender == config.botId) return false;
    final prefix = '<@${config.botId}> ';
    if (!content.startsWith(prefix)) return false;
    final text = content.substring(prefix.length).trim();
    if (text.isEmpty || text.length > _maxFrameChars) return false;
    if (!_base64Text.hasMatch(text)) return false;
    final Uint8List frame;
    try {
      frame = base64.decode(text);
    } on FormatException {
      return false;
    }
    onFrame(sender, frame);
    return true;
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) {
    if (!_running) throw StateError('Discord is not running.');
    final target = parseDiscordAddress(address);
    if (target == null) throw ArgumentError('Not a Discord bot address.');
    if (target.botId == config.botId) throw ArgumentError('That is this bot.');
    if (_queued >= 64) throw StateError('Discord sending is backed up.');
    _queued++;
    _recentSend = true;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    final text = '<@${target.botId}> ${base64.encode(frame)}';
    final done = Completer<void>();
    _sendQueue = _sendQueue.then((_) async {
      try {
        await _sendOne(target.channelId, target.botId, text);
        done.complete();
      } catch (error) {
        done.completeError(error);
      } finally {
        _queued--;
      }
      if (sendSpacing > Duration.zero) await _wait(sendSpacing);
    });
    return done.future;
  }

  Future<void> _sendOne(String channelId, String botId, String text) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await api.call(
          'POST',
          '/channels/$channelId/messages',
          body: {
            'content': text,
            // Ping only that bot; never anyone else.
            'allowed_mentions': {
              'parse': <String>[],
              'users': [botId],
            },
            'flags': 4096, // suppress notifications
          },
        );
        return;
      } on DiscordException catch (error) {
        // Only the account-wide limit rests the whole account; one route's
        // bucket is waited out on that route (below).
        if (error.slowDownFor case final wait?) onRateLimited?.call(wait);
        if (error.rateLimited && attempt < 3 && (error.retryAfter ?? 1) <= 30) {
          await _wait(
            Duration(
              milliseconds: (min(error.retryAfter ?? 1, 30) * 1000).ceil(),
            ),
          );
          continue;
        }
        if (error.forbidden || error.code == 404) {
          throw StateError(
            'Discord refused the message: the bot needs to be in the '
            'contact\'s server with Send Messages.',
          );
        }
        rethrow;
      }
    }
  }
}

/// A Discord bot carrier adapter. Not store and forward: the channel keeps
/// its history, but a bot that starts again looks from "now", so frames sent
/// while it was away are never read. The sender is told only that Discord
/// took the frame, and the usual retries cover an absent peer.
CarrierTransportAdapter createDiscordCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.discord,
  sealer: sealer,
  framing: discordFraming,
  path: TransportPathKind.relayed,
  sendAttemptTimeout: const Duration(seconds: 120),
  isValidAddress: isValidDiscordCarrierAddress,
  now: now,
);
