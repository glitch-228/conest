import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_locales.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';

/// The opt-in Discord client in Settings → Connectivity. Turning it on
/// first shows the warning that it is against Discord's terms.
class DiscordClientPanel extends StatefulWidget {
  const DiscordClientPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<DiscordClientPanel> createState() => _DiscordClientPanelState();
}

class _DiscordClientPanelState extends State<DiscordClientPanel> {
  final _token = TextEditingController();
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
    _token.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<bool> _warn(AppLocalizations l10n) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.discordWarningTitle),
          content: Text(l10n.discordWarningBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.actionCancel),
            ),
            FilledButton(
              key: const ValueKey('discord-accept-risk'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.discordWarningAccept),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _enable() async {
    final l10n = l10nOf(context);
    if (_token.text.trim().isEmpty) {
      setState(() => _error = l10n.discordTokenHelp);
      return;
    }
    final accepted = await _warn(l10n);
    if (!accepted || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.discord.enable(_token.text, acceptedRisk: true);
      _token.clear();
    } catch (error) {
      if (mounted) setState(() => _error = describeActionError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final theme = Theme.of(context);
    final service = widget.controller.discord;
    final client = service.client;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.discordClientTitle, style: theme.textTheme.titleSmall),
        Text(l10n.discordClientSubtitle, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (client != null && client.signedIn) ...[
          ListTile(
            key: const ValueKey('discord-signed-in'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.circle, size: 12, color: Colors.green),
            title: Text(l10n.discordSignedInAs(client.selfName)),
          ),
          OutlinedButton(
            key: const ValueKey('discord-remove'),
            onPressed: _busy
                ? null
                : () async {
                    await service.disable();
                  },
            child: Text(l10n.telegramLogOut),
          ),
        ] else ...[
          TextField(
            key: const ValueKey('discord-token-field'),
            controller: _token,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.discordAccountTokenField,
              helperText: l10n.discordTokenHelp,
              helperMaxLines: 3,
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('discord-enable'),
            onPressed: _busy ? null : _enable,
            child: Text(l10n.actionContinue),
          ),
        ],
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}
