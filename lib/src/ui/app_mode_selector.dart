import '../app_locales.dart';
import 'package:flutter/material.dart';

import '../messenger_controller.dart';
import '../models.dart';

/// Chooses what the app is used as: Conest only, Conest and Matrix, or a
/// Matrix-only client. Hidden in builds without the Matrix client.
class AppModeSelector extends StatelessWidget {
  const AppModeSelector({super.key, required this.controller});

  final MessengerController controller;

  static String describe(AppMode mode) => switch (mode) {
    AppMode.conest =>
      'Conest chats only. Matrix can still carry Conest '
          'messages as a fallback route.',
    AppMode.both =>
      'Conest and Matrix chats side by side, with filters in '
          'the chat list.',
    AppMode.matrixOnly =>
      'A Matrix client only. Conest chats are hidden and '
          'Conest networking stays off on this device.',
    AppMode.discordOnly =>
      'A Discord client only. Conest chats are hidden and '
          'Conest networking stays off on this device.',
    AppMode.telegramOnly =>
      'A Telegram client only. Conest chats are hidden and '
          'Conest networking stays off on this device.',
    AppMode.xmppOnly =>
      'An XMPP client only. Conest chats are hidden and '
          'Conest networking stays off on this device.',
  };

  /// The modes this build offers.
  static List<AppMode> available(MessengerController controller) => [
    AppMode.conest,
    if (controller.matrixAvailable) AppMode.both,
    if (controller.matrixAvailable) AppMode.matrixOnly,
    AppMode.xmppOnly,
    if (controller.telegram.supported) AppMode.telegramOnly,
    AppMode.discordOnly,
  ];

  static String label(BuildContext context, AppMode mode) => switch (mode) {
    AppMode.conest => l10nOf(context).uiConest26885B,
    AppMode.both => l10nOf(context).uiBoth1F4698,
    AppMode.matrixOnly => l10nOf(context).uiMatrix58947E,
    AppMode.xmppOnly => 'XMPP',
    AppMode.telegramOnly => 'Telegram',
    AppMode.discordOnly => 'Discord',
  };

  @override
  Widget build(BuildContext context) {
    final mode = controller.appMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10nOf(context).uiAppMode2965FD,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final option in available(controller))
              ChoiceChip(
                key: ValueKey('app-mode-${option.name}'),
                label: Text(label(context, option)),
                selected: option == mode,
                onSelected: (_) => choose(context, controller, option),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(describe(mode), style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  /// Stores [mode], confirming first when Conest would go dormant.
  static Future<void> choose(
    BuildContext context,
    MessengerController controller,
    AppMode mode,
  ) async {
    if (mode == controller.appMode) return;
    if (mode.clientOnly && controller.hasIdentity) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            mode == AppMode.matrixOnly
                ? l10nOf(context).uiUseConestAsAMatrix6A44C5
                : l10nOf(context).appModeClientOnlyTitle(label(context, mode)),
          ),
          content: Text(l10nOf(context).uiYourConestChatsAreHiddenCFD853),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10nOf(context).actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10nOf(context).uiSwitch3E44C9),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      await controller.setAppMode(mode);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text("${(error)}")));
      }
    }
  }
}
