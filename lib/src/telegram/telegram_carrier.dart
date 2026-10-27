import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../carrier.dart';
import '../transport_models.dart';
import 'telegram_bot_api.dart';

/// Telegram messages hold 4096 characters: 2800 sealed bytes are 3755
/// characters in base64, and an envelope is at most 24 frames. Bigger
/// envelopes use other routes.
const CarrierFraming telegramFraming = CarrierFraming(
  maxSealedBytes: 64 * 1024,
  chunkBytes: 2800,
);

/// The bot a user made for Conest and told Conest the token of. The token
/// is a secret kept in the vault; the username is the address contacts use.
class TelegramBotConfig {
  const TelegramBotConfig({
    required this.token,
    required this.username,
    required this.botId,
  });

  final String token;

  /// Lower case, without "@".
  final String username;
  final int botId;

  Map<String, Object?> toJson() => {
    'token': token,
    'username': username,
    'botId': botId,
  };

  static TelegramBotConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final token = json['token'];
    final username = json['username'];
    final botId = json['botId'];
    if (token is! String ||
        !isValidTelegramBotToken(token) ||
        username is! String ||
        !isValidTelegramBotUsername(username) ||
        botId is! int) {
      return null;
    }
    return TelegramBotConfig(token: token, username: username, botId: botId);
  }
}

bool isValidTelegramCarrierAddress(String address) =>
    isValidTelegramBotUsername(address);

/// Checks [token] with Telegram and returns the bot it belongs to.
Future<TelegramBotConfig> checkTelegramBot(
  String token,
  TelegramNetwork network,
) async {
  final trimmed = token.trim();
  if (!isValidTelegramBotToken(trimmed)) {
    throw ArgumentError('That is not a bot token (12345:ABC...).');
  }
  final api = network.botApi(trimmed);
  try {
    final me = await api.call('getMe');
    if (me is! Map ||
        me['is_bot'] != true ||
        me['id'] is! int ||
        me['username'] is! String) {
      throw StateError('Telegram did not describe a bot.');
    }
    final username = (me['username'] as String).toLowerCase();
    if (!isValidTelegramBotUsername(username)) {
      throw StateError('Telegram sent an unusable bot name.');
    }
    return TelegramBotConfig(
      token: trimmed,
      username: username,
      botId: me['id'] as int,
    );
  } on TelegramBotException catch (error) {
    if (error.unauthorized) {
      throw StateError('Telegram does not accept that bot token.');
    }
    rethrow;
  } finally {
    api.close();
  }
}

enum TelegramCarrierState { stopped, connecting, connected, failed }

/// The Bot API side of the carrier. Frames go as base64 text messages from
/// the user's bot to the contact's bot (bot-to-bot messaging, Bot API 10.0,
/// which both bots must have switched on); incoming ones are fetched with
/// long polling. Only messages from bots in a private chat are read.
class TelegramCarrierChannel
    implements ManagedCarrierChannel, PeerAwareCarrierChannel {
  TelegramCarrierChannel({
    required this.config,
    required this.api,
    required this.onFrame,
    this.onStatusChanged,
    this.log,
    this.pollTimeout = const Duration(seconds: 25),
    this.retryDelay = const Duration(seconds: 5),
    this.sendSpacing = const Duration(milliseconds: 1100),
    this.maxRateRetries = 3,
    Future<void> Function(Duration delay)? wait,
  }) : _wait = wait ?? Future<void>.delayed;

  final TelegramBotConfig config;
  final TelegramBotApi api;
  final void Function(String sender, Uint8List frame) onFrame;
  final void Function()? onStatusChanged;
  final void Function(String line)? log;
  final Duration pollTimeout;
  final Duration retryDelay;

  /// Telegram allows about one message a second into one chat.
  final Duration sendSpacing;
  final int maxRateRetries;
  final Future<void> Function(Duration delay) _wait;

  static final int _maxFrameChars =
      (telegramFraming.chunkBytes + 16) * 4 ~/ 3 + 8;
  static final _base64Text = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

  TelegramCarrierState _state = TelegramCarrierState.stopped;
  String? _lastError;
  bool _running = false;
  int _offset = 0;
  Future<void> _sendQueue = Future.value();
  int _queued = 0;
  final Random _random = Random.secure();

  TelegramCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress => config.username;

  @override
  String get routeLabel => 'Telegram bot @${config.username}';

  void _set(TelegramCarrierState state, [String? error]) {
    if (_state == state && _lastError == error) return;
    _state = state;
    _lastError = error;
    onStatusChanged?.call();
  }

  @override
  void start() {
    if (_running) return;
    _running = true;
    _set(TelegramCarrierState.connecting);
    unawaited(_poll());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _set(TelegramCarrierState.stopped);
    api.close();
  }

  /// Any bot may send a first request, as on the other carriers; frames
  /// from strangers are kept apart by the carrier adapter.
  @override
  void updatePeers(Set<String> addresses) {}

  Future<void> _poll() async {
    var failures = 0;
    while (_running) {
      try {
        final result = await api.call('getUpdates', {
          'offset': _offset,
          // The first call answers at once, so the state is known.
          'timeout': _state == TelegramCarrierState.connected
              ? pollTimeout.inSeconds
              : 0,
          'limit': 50,
          'allowed_updates': ['message'],
        }, pollTimeout + const Duration(seconds: 15));
        if (!_running) return;
        failures = 0;
        _set(TelegramCarrierState.connected);
        if (result is List) {
          for (final update in result.take(100)) {
            if (update is! Map) continue;
            final id = update['update_id'];
            if (id is int && id >= _offset) _offset = id + 1;
            _onUpdate(update);
          }
        }
      } on TelegramBotException catch (error) {
        if (!_running) return;
        if (error.unauthorized) {
          _running = false;
          _set(
            TelegramCarrierState.failed,
            'Telegram no longer accepts the bot token.',
          );
          return;
        }
        if (error.conflict) {
          // Another program polls the same bot: it would steal updates.
          _running = false;
          _set(
            TelegramCarrierState.failed,
            'Another program is reading this bot. Use a bot only Conest uses.',
          );
          return;
        }
        failures++;
        _set(TelegramCarrierState.failed, error.toString());
        await _wait(
          error.retryAfter != null
              ? Duration(seconds: min(error.retryAfter!, 120))
              : _backoff(failures),
        );
      } catch (error) {
        if (!_running) return;
        failures++;
        _set(TelegramCarrierState.failed, error.toString());
        await _wait(_backoff(failures));
      }
    }
  }

  Duration _backoff(int failures) {
    final base = retryDelay.inMilliseconds * (1 << min(failures - 1, 5));
    return Duration(
      milliseconds: base + _random.nextInt(retryDelay.inMilliseconds + 1),
    );
  }

  void _onUpdate(Map update) {
    final message = update['message'];
    if (message is! Map) return;
    final from = message['from'];
    final chat = message['chat'];
    final text = message['text'];
    if (from is! Map || chat is! Map || text is! String) return;
    if (from['is_bot'] != true || chat['type'] != 'private') return;
    if (from['id'] == config.botId) return;
    final username = from['username'];
    if (username is! String) return;
    final sender = username.toLowerCase();
    if (!isValidTelegramBotUsername(sender)) return;
    if (text.isEmpty || text.length > _maxFrameChars) return;
    if (!_base64Text.hasMatch(text)) return;
    final Uint8List frame;
    try {
      frame = base64.decode(text);
    } on FormatException {
      return;
    }
    onFrame(sender, frame);
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) {
    if (!_running) throw StateError('Telegram is not running.');
    if (!isValidTelegramBotUsername(address)) {
      throw ArgumentError('Not a Telegram bot name.');
    }
    if (address == config.username) {
      throw ArgumentError('That is this bot.');
    }
    // Bound what waits for the one-a-second send slot.
    if (_queued >= 64) throw StateError('Telegram sending is backed up.');
    _queued++;
    final text = base64.encode(frame);
    final done = Completer<void>();
    _sendQueue = _sendQueue.then((_) async {
      try {
        await _sendOne(address, text);
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

  Future<void> _sendOne(String address, String text) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await api.call('sendMessage', {
          'chat_id': '@$address',
          'text': text,
          'disable_notification': true,
          'protect_content': true,
        });
        return;
      } on TelegramBotException catch (error) {
        if (error.rateLimited && attempt < maxRateRetries) {
          await _wait(Duration(seconds: min(error.retryAfter ?? 1, 30)));
          continue;
        }
        if (error.code == 400 || error.code == 403) {
          throw StateError(
            'Telegram refused the message to @$address: ${error.description}. '
            'Both bots need bot-to-bot messaging switched on.',
          );
        }
        rethrow;
      }
    }
  }
}

/// A Telegram bot carrier adapter. Store and forward: Telegram keeps the
/// messages for a bot that is away for up to 24 hours.
CarrierTransportAdapter createTelegramCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.telegram,
  sealer: sealer,
  framing: telegramFraming,
  sendAttemptTimeout: const Duration(seconds: 120),
  isValidAddress: isValidTelegramCarrierAddress,
  now: now,
);
