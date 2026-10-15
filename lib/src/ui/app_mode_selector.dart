import 'localized_ui_text.dart';
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
          localizedUiText(context, 'App mode'),
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SegmentedButton<AppMode>(
          segments:  [
            ButtonSegment(value: AppMode.conest, label: Text(localizedUiText(context, 'Conest'))),
            ButtonSegment(value: AppMode.both, label: Text(localizedUiText(context, 'Both'))),
            ButtonSegment(value: AppMode.matrixOnly, label: Text(localizedUiText(context, 'Matrix'))),
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
          title:  Text(localizedUiText(context, 'Use Conest as a Matrix client only?')),
          content:  Text(
            localizedUiText(context, 'Your Conest chats are hidden and Conest stops connecting on this ' 'device until you switch back. Nothing is deleted. Contacts ' "cannot reach you over Conest meanwhile; their apps keep " 'retrying and deliver when you switch back.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child:  Text(localizedUiText(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child:  Text(localizedUiText(context, 'Switch')),
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
        )?.showSnackBar(SnackBar(content: Text(localizedUiText(context, '$error'))));
      }
    }
  }
}
