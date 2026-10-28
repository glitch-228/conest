import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'td_engine.dart';
import 'telegram_api_keys.dart';
import 'telegram_bridge.dart';
import 'telegram_client.dart';
import 'telegram_models.dart';
import 'telegram_mods.dart';

/// Owns the Telegram client for the app: whether it is available in this
/// build, its on/off state and TDLib's database key (kept in the vault by
/// the caller), and the mod settings.
class TelegramService extends ChangeNotifier {
  TelegramService({
    required this.keys,
    required TdEngine? Function() engineFactory,
    required this.directory,
    required this.readAccount,
    required this.writeAccount,
    required this.readMods,
    required this.writeMods,
    this.languageCode = 'en',
    this.log,
    this.readBridge,
    this.writeBridge,
    this.bridgeOut,
  }) : _engineFactory = engineFactory;

  /// Conest's own api_id and api_hash; null in builds without them.
  final TelegramApiKeys? keys;
  final TdEngine? Function() _engineFactory;

  /// Where TDLib keeps its database and files.
  final Future<Directory> Function() directory;
  final Map<String, Object?>? Function() readAccount;
  final Future<void> Function(Map<String, Object?>? account) writeAccount;
  final Object? Function() readMods;
  final void Function(Map<String, Object?> mods) writeMods;
  final String languageCode;
  final void Function(String line)? log;

  /// Saved bridge settings, and where relayed messages go (the account's
  /// other devices).
  final Object? Function()? readBridge;
  final void Function(Map<String, Object?> settings)? writeBridge;
  final void Function(Map<String, Object?> event)? bridgeOut;

  TelegramBridgeSettings? _bridge;

  late final TelegramBridgeBatcher? _batcher = bridgeOut == null
      ? null
      : TelegramBridgeBatcher(send: bridgeOut!);

  /// What this device relays to the account's other devices.
  TelegramBridgeSettings get bridge =>
      _bridge ??= TelegramBridgeSettings.fromJson(readBridge?.call());

  void saveBridge() {
    writeBridge?.call(bridge.toJson());
    notifyListeners();
  }

  void _relay(TelegramClient client, TgMessage message, TgChat chat) {
    if (_batcher == null || !bridge.any) return;
    final event = bridgeEventFor(
      message: message,
      chat: chat,
      chatTitle: chat.kind == TgChatKind.saved ? 'Saved Messages' : chat.title,
      from: message.outgoing
          ? client.selfName
          : client.nameOf(message.senderId),
      settings: bridge,
    );
    if (event != null) _batcher.add(event);
  }

  TelegramClient? _client;
  TelegramMods? _mods;
  bool? _engineAvailable;
  TdEngine? _probe;

  /// Whether this build can run a Telegram client: it has Conest's keys and
  /// TDLib. Without them the client is hidden.
  bool get supported {
    if (keys == null) return false;
    return _engineAvailable ??= (_probe = _engineFactory()) != null;
  }

  TelegramClient? get client => _client;

  /// The user turned the client on.
  bool get enabled => readAccount()?['enabled'] == true;

  TelegramMods get mods => _mods ??= TelegramMods.fromJson(readMods());

  Future<void> saveMods() async => writeMods(mods.toJson());

  /// Turns the client on (making TDLib's database key the first time) and
  /// starts it.
  Future<void> enable() async {
    if (!supported) {
      throw StateError('Telegram is not available in this build.');
    }
    final existing = readAccount();
    final key = existing?['dbKey'];
    await writeAccount({
      'enabled': true,
      'dbKey': key is String && key.isNotEmpty ? key : _newKey(),
    });
    notifyListeners();
    await start();
  }

  static String _newKey() {
    final random = Random.secure();
    return base64.encode(List.generate(32, (_) => random.nextInt(256)));
  }

  /// Starts the client if it is enabled and not running.
  Future<void> start() async {
    final account = readAccount();
    final keys = this.keys;
    if (_client != null || keys == null || account?['enabled'] != true) return;
    final key = account?['dbKey'];
    if (key is! String || key.isEmpty) return;
    final engine = _probe ?? _engineFactory();
    _probe = null;
    if (engine == null) return;
    final root = await directory();
    final client = TelegramClient(
      engine: engine,
      keys: keys,
      databaseDirectory: p.join(root.path, 'telegram', 'db'),
      filesDirectory: p.join(root.path, 'telegram', 'files'),
      databaseKey: key,
      mods: mods,
      languageCode: languageCode,
      log: log,
    )..addListener(notifyListeners);
    client.onLiveMessage = (message, chat) => _relay(client, message, chat);
    _client = client;
    await client.start();
    notifyListeners();
  }

  /// Stops the client but keeps the session (it signs in again at once on
  /// the next start).
  Future<void> stop() async {
    final client = _client;
    if (client == null) return;
    _client = null;
    _engineAvailable = null;
    client.removeListener(notifyListeners);
    try {
      await client.close();
    } catch (error) {
      log?.call('Telegram: close failed: $error');
    }
    notifyListeners();
  }

  /// Signs out of Telegram, deletes TDLib's database and files here and
  /// forgets the key.
  Future<void> disable() async {
    final client = _client;
    if (client != null && client.auth == TgAuth.ready) {
      try {
        await client.logOut();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      } catch (error) {
        log?.call('Telegram: log out failed: $error');
      }
    }
    await stop();
    try {
      final root = await directory();
      final folder = Directory(p.join(root.path, 'telegram'));
      if (await folder.exists()) await folder.delete(recursive: true);
    } catch (error) {
      log?.call('Telegram: could not delete the database: $error');
    }
    await writeAccount(null);
    notifyListeners();
  }

  @override
  void dispose() {
    _batcher?.flush();
    final client = _client;
    _client = null;
    if (client != null) {
      client.removeListener(notifyListeners);
      unawaited(client.close().catchError((Object _) {}));
    }
    super.dispose();
  }
}
