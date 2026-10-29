import 'dart:async';

import 'package:flutter/foundation.dart';

import 'discord_api.dart';
import 'discord_client.dart';

/// Owns the opt-in Discord client: the user's own account token, kept in
/// the vault, used only for the client and never for the carrier.
///
/// Using a user token is against Discord's terms and the account may be
/// banned. Turning it on needs the user to accept that, once, in words.
class DiscordService extends ChangeNotifier {
  DiscordService({
    required this.network,
    required this.readAccount,
    required this.writeAccount,
    this.log,
  });

  final DiscordNetwork network;
  final Map<String, Object?>? Function() readAccount;
  final Future<void> Function(Map<String, Object?>? account) writeAccount;
  final void Function(String line)? log;

  DiscordClient? _client;

  DiscordClient? get client => _client;

  /// The user accepted the warning and turned the client on.
  bool get enabled =>
      readAccount()?['enabled'] == true && readAccount()?['accepted'] == true;

  /// Turns the client on with [token], after [acceptedRisk]: the user read
  /// that this is against Discord's terms and may get the account banned.
  Future<void> enable(String token, {required bool acceptedRisk}) async {
    if (!acceptedRisk) {
      throw StateError(
        'Accept that this is against Discord\'s terms and may get your '
        'account banned.',
      );
    }
    final trimmed = token.trim();
    if (trimmed.length < 20 || trimmed.length > 200 || trimmed.contains(' ')) {
      throw ArgumentError('That does not look like an account token.');
    }
    await stop();
    final client = DiscordClient(
      api: network.api(trimmed, DiscordAuth.user),
      pollInterval: network.pollInterval + const Duration(seconds: 2),
      log: log,
    );
    try {
      await client.start();
    } catch (_) {
      client.dispose();
      rethrow;
    }
    _client = client..addListener(notifyListeners);
    await writeAccount({'enabled': true, 'accepted': true, 'token': trimmed});
    notifyListeners();
  }

  /// Starts the saved client, if the user turned it on.
  Future<void> start() async {
    final account = readAccount();
    final token = account?['token'];
    if (_client != null ||
        account?['enabled'] != true ||
        account?['accepted'] != true ||
        token is! String) {
      return;
    }
    final client = DiscordClient(
      api: network.api(token, DiscordAuth.user),
      pollInterval: network.pollInterval + const Duration(seconds: 2),
      log: log,
    );
    try {
      await client.start();
    } catch (error) {
      log?.call('Discord client: start failed: $error');
      client.dispose();
      return;
    }
    _client = client..addListener(notifyListeners);
    notifyListeners();
  }

  /// Stops the client but keeps the token.
  Future<void> stop() async {
    final client = _client;
    if (client == null) return;
    _client = null;
    client.removeListener(notifyListeners);
    client.dispose();
    notifyListeners();
  }

  /// Stops the client and forgets the token.
  Future<void> disable() async {
    await stop();
    await writeAccount(null);
    notifyListeners();
  }

  @override
  void dispose() {
    final client = _client;
    _client = null;
    client?.removeListener(notifyListeners);
    client?.dispose();
    super.dispose();
  }
}
