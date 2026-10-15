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
  };

  @override
  Widget build(BuildContext context) {
    if (!controller.matrixAvailable) return const SizedBox.shrink();
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
        SegmentedButton<AppMode>(
          segments: [
            ButtonSegment(
              value: AppMode.conest,
              label: Text(l10nOf(context).uiConest26885B),
            ),
            ButtonSegment(
              value: AppMode.both,
              label: Text(l10nOf(context).uiBoth1F4698),
            ),
            ButtonSegment(
              value: AppMode.matrixOnly,
              label: Text(l10nOf(context).uiMatrix58947E),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (selection) =>
              choose(context, controller, selection.single),
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
    if (mode == AppMode.matrixOnly && controller.hasIdentity) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10nOf(context).uiUseConestAsAMatrix6A44C5),
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
