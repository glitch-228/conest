import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../discord/discord_carrier.dart';
import '../transport_models.dart';
import 'carrier_switch.dart';

/// The Discord bot carrier in Settings → Connectivity: the token of a bot
/// the user made with @BotFather, and its state.
class DiscordCarrierPanel extends StatefulWidget {
  const DiscordCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<DiscordCarrierPanel> createState() => _DiscordCarrierPanelState();
}

class _DiscordCarrierPanelState extends State<DiscordCarrierPanel> {
  final _token = TextEditingController();
  final _channel = TextEditingController();
  bool _busy = false;
  bool _editing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _token.dispose();
    _channel.dispose();
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

  Future<void> _setUp() async {
    await widget.controller.enableDiscordCarrier(_token.text, _channel.text);
    if (mounted) {
      setState(() {
        _editing = false;
        _token.clear();
        _channel.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final controller = widget.controller;
    final config = controller.discordBotConfig;
    final channel = controller.discordChannel;
    final theme = Theme.of(context);
    final form = config == null || _editing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CarrierSwitch(
          switchKey: const ValueKey('discord-carrier-switch'),
          controller: controller,
          kind: TransportKind.discord,
          title: 'Discord',
          subtitle: l10n.discordCarrierSubtitle,
          configured: config != null,
          busy: _busy,
          run: _run,
          onSetUp: _setUp,
          onRemove: controller.disableDiscordCarrier,
        ),
        if (config != null)
          ListTile(
            key: const ValueKey('discord-carrier-status'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                DiscordCarrierState.connected => Colors.green,
                DiscordCarrierState.connecting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: SelectableText(
              config.username.isEmpty ? config.botId : config.username,
            ),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 3),
          ),
        if (config != null && !_editing)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('discord-change-bot'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _editing = true;
                      _error = null;
                    }),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.discordChangeBot),
            ),
          ),
        if (form) ...[
          Text(l10n.discordBotHelp, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('discord-token-field'),
            controller: _token,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.discordBotTokenField,
              isDense: true,
            ),
          ),
          TextField(
            key: const ValueKey('discord-channel-field'),
            controller: _channel,
            enabled: !_busy,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.discordChannelField,
              isDense: true,
            ),
          ),
          if (_editing)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  FilledButton(
                    key: const ValueKey('discord-save-bot'),
                    onPressed: _busy ? null : () => _run(_setUp),
                    child: Text(l10n.actionSave),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _editing = false),
                    child: Text(l10n.actionCancel),
                  ),
                ],
              ),
            ),
        ],
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}
