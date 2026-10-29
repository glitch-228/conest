import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../telegram/telegram_carrier.dart';
import '../transport_models.dart';
import 'carrier_switch.dart';

/// The Telegram bot carrier in Settings → Connectivity: the token of a bot
/// the user made with @BotFather, and its state.
class TelegramCarrierPanel extends StatefulWidget {
  const TelegramCarrierPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<TelegramCarrierPanel> createState() => _TelegramCarrierPanelState();
}

class _TelegramCarrierPanelState extends State<TelegramCarrierPanel> {
  final _token = TextEditingController();
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
    await widget.controller.enableTelegramCarrier(_token.text);
    if (mounted) {
      setState(() {
        _editing = false;
        _token.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final controller = widget.controller;
    final config = controller.telegramBotConfig;
    final channel = controller.telegramChannel;
    final theme = Theme.of(context);
    final form = config == null || _editing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CarrierSwitch(
          switchKey: const ValueKey('telegram-carrier-switch'),
          controller: controller,
          kind: TransportKind.telegram,
          title: 'Telegram',
          subtitle: l10n.telegramCarrierSubtitle,
          configured: config != null,
          busy: _busy,
          run: _run,
          onSetUp: _setUp,
          onRemove: controller.disableTelegramCarrier,
        ),
        if (config != null)
          ListTile(
            key: const ValueKey('telegram-carrier-status'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: switch (channel?.state) {
                TelegramCarrierState.connected => Colors.green,
                TelegramCarrierState.connecting => Colors.amber,
                _ => theme.colorScheme.error,
              },
            ),
            title: SelectableText('@${config.username}'),
            subtitle: channel?.lastError == null
                ? null
                : Text(channel!.lastError!, maxLines: 3),
          ),
        if (config != null && !_editing)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('telegram-change-bot'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _editing = true;
                      _error = null;
                    }),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.telegramChangeBot),
            ),
          ),
        if (form) ...[
          Text(l10n.telegramBotHelp, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('telegram-token-field'),
            controller: _token,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.telegramBotTokenField,
              isDense: true,
            ),
          ),
          if (_editing)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  FilledButton(
                    key: const ValueKey('telegram-save-bot'),
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
