import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_locales.dart';
import '../../l10n/app_localizations.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../telegram/telegram_client.dart';
import '../telegram/telegram_mods.dart';

/// The Telegram client in Settings → Connectivity: turn it on, sign in with
/// a phone number (or a QR code), see who is signed in, open the mod
/// settings, and log out. Hidden in builds without Conest's Telegram keys
/// or TDLib.
class TelegramClientPanel extends StatefulWidget {
  const TelegramClientPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<TelegramClientPanel> createState() => _TelegramClientPanelState();
}

class _TelegramClientPanelState extends State<TelegramClientPanel> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = describeActionError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    TextEditingController text,
    String label,
    Key key, {
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      key: key,
      controller: text,
      enabled: !_busy,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final service = widget.controller.telegram;
    if (!service.supported) return const SizedBox.shrink();
    final l10n = l10nOf(context);
    final theme = Theme.of(context);
    final client = service.client;
    final on = service.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('telegram-client-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.telegramClientTitle),
          subtitle: Text(l10n.telegramClientSubtitle),
          value: on,
          onChanged: _busy
              ? null
              : (value) => _run(value ? service.enable : service.disable),
        ),
        if (on) Text(l10n.telegramUnofficial, style: theme.textTheme.bodySmall),
        if (on && client != null) ..._signIn(client, l10n, theme),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }

  List<Widget> _signIn(
    TelegramClient client,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    final authError = client.authError;
    Widget action(String label, Key key, Future<void> Function() run) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: FilledButton(
            key: key,
            onPressed: _busy ? null : () => _run(run),
            child: Text(label),
          ),
        );
    return [
      switch (client.auth) {
        TgAuth.starting || TgAuth.closed => ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(l10n.telegramConnecting),
        ),
        TgAuth.waitPhone || TgAuth.loggedOut => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(
              _phone,
              l10n.telegramPhoneField,
              const ValueKey('telegram-phone-field'),
            ),
            action(
              l10n.actionContinue,
              const ValueKey('telegram-phone-continue'),
              () => client.submitPhone(_phone.text),
            ),
            TextButton(
              key: const ValueKey('telegram-qr-login'),
              onPressed: _busy ? null : () => _run(client.requestQrLogin),
              child: Text(l10n.telegramQrLogin),
            ),
          ],
        ),
        TgAuth.waitCode => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(
              _code,
              l10n.telegramCodeField,
              const ValueKey('telegram-code-field'),
            ),
            action(
              l10n.actionContinue,
              const ValueKey('telegram-code-continue'),
              () async {
                await client.submitCode(_code.text);
                _code.clear();
              },
            ),
            TextButton(
              onPressed: _busy ? null : () => _run(client.requestQrLogin),
              child: Text(l10n.telegramQrLogin),
            ),
          ],
        ),
        TgAuth.waitPassword => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(
              _password,
              l10n.telegramPasswordField,
              const ValueKey('telegram-password-field'),
              obscure: true,
            ),
            action(
              l10n.actionContinue,
              const ValueKey('telegram-password-continue'),
              () async {
                await client.submitPassword(_password.text);
                _password.clear();
              },
            ),
          ],
        ),
        TgAuth.waitQr => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (client.qrLink != null)
              SizedBox.square(
                dimension: 220,
                child: QrImageView(
                  key: const ValueKey('telegram-qr'),
                  data: client.qrLink!,
                  backgroundColor: Colors.white,
                ),
              ),
            Text(l10n.telegramQrHint, style: theme.textTheme.bodySmall),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => client.submitPhone(_phone.text)),
              child: Text(l10n.telegramPhoneField),
            ),
          ],
        ),
        TgAuth.noAccount => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.telegramNoAccount,
              key: const ValueKey('telegram-no-account'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => client.submitPhone(_phone.text)),
              child: Text(l10n.telegramPhoneField),
            ),
          ],
        ),
        TgAuth.ready => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              key: const ValueKey('telegram-signed-in'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.circle, size: 12, color: Colors.green),
              title: Text(
                l10n.telegramSignedInAs(
                  client.selfName.isEmpty ? '?' : client.selfName,
                ),
              ),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('telegram-relay-saved'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.telegramRelaySaved),
              subtitle: Text(l10n.telegramRelayNote),
              value: widget.controller.telegram.bridge.savedMessages,
              onChanged: (value) {
                widget.controller.telegram.bridge.savedMessages = value;
                widget.controller.telegram.saveBridge();
              },
            ),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('telegram-mods-open'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          TelegramModsScreen(controller: widget.controller),
                    ),
                  ),
                  icon: const Icon(Icons.tune),
                  label: Text(l10n.telegramMods),
                ),
              ],
            ),
          ],
        ),
      },
      if (authError != null)
        Text(
          authError,
          key: const ValueKey('telegram-auth-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
    ];
  }
}

/// The mod settings: word filters, the deleted-message notice, translation
/// language and plugins.
class TelegramModsScreen extends StatefulWidget {
  const TelegramModsScreen({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<TelegramModsScreen> createState() => _TelegramModsScreenState();
}

class _TelegramModsScreenState extends State<TelegramModsScreen> {
  late final TextEditingController _words;
  late final TextEditingController _language;
  final _plugin = TextEditingController();
  String? _pluginError;

  TelegramMods get _mods => widget.controller.telegram.mods;

  @override
  void initState() {
    super.initState();
    _words = TextEditingController(text: _mods.hiddenWords.join('\n'));
    _language = TextEditingController(text: _mods.translateTo);
  }

  @override
  void dispose() {
    _words.dispose();
    _language.dispose();
    _plugin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _mods.hiddenWords = [
      for (final line in _words.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ].take(TelegramMods.maxHiddenWords).toList();
    _mods.translateTo = _language.text.trim().toLowerCase();
    await widget.controller.telegram.saveMods();
    widget.controller.telegram.client?.refresh();
  }

  String _permissions(TelegramPlugin plugin) {
    final l10n = l10nOf(context);
    return [
      for (final permission in plugin.permissions)
        switch (permission) {
          TelegramPermission.readMessages => l10n.telegramPermReadMessages,
          TelegramPermission.editOutgoing => l10n.telegramPermEditOutgoing,
          TelegramPermission.commands => l10n.telegramPermCommands,
        },
    ].join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.telegramMods)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            key: const ValueKey('telegram-hidden-words'),
            controller: _words,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(labelText: l10n.telegramHiddenWords),
            onChanged: (_) => _save(),
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            key: const ValueKey('telegram-deleted-notice'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.telegramDeletedNoticeSwitch),
            subtitle: Text(l10n.telegramDeletedNoticeNote),
            value: _mods.deletedNotice,
            onChanged: (value) {
              setState(() => _mods.deletedNotice = value);
              _save();
            },
          ),
          TextField(
            key: const ValueKey('telegram-translate-to'),
            controller: _language,
            decoration: InputDecoration(labelText: l10n.telegramTranslateTo),
            onChanged: (_) => _save(),
          ),
          const SizedBox(height: 20),
          Text(l10n.telegramPlugins, style: theme.textTheme.titleSmall),
          Text(l10n.telegramPluginHelp, style: theme.textTheme.bodySmall),
          for (final plugin in _mods.plugins)
            ListTile(
              key: ValueKey('telegram-plugin-${plugin.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(plugin.name),
              subtitle: Text(
                l10n.telegramPluginPermissions(_permissions(plugin)),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  setState(() => _mods.remove(plugin.id));
                  _save();
                },
              ),
            ),
          TextField(
            key: const ValueKey('telegram-plugin-source'),
            controller: _plugin,
            minLines: 2,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: l10n.telegramPluginInstall,
              errorText: _pluginError,
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('telegram-plugin-install'),
              onPressed: () {
                final ok = _mods.install(_plugin.text);
                setState(() {
                  _pluginError = ok ? null : l10n.telegramPluginBad;
                  if (ok) _plugin.clear();
                });
                if (ok) _save();
              },
              child: Text(l10n.actionSave),
            ),
          ),
        ],
      ),
    );
  }
}
