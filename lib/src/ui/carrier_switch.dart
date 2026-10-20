import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../transport_models.dart';

/// The switch of a way to reach people (a carrier). Before it is set up,
/// turning it on sets it up ([onSetUp]). Once set up it pauses and resumes,
/// keeping the account, address and keys; [onRemove], behind its own button
/// and a question, forgets them.
class CarrierSwitch extends StatelessWidget {
  const CarrierSwitch({
    super.key,
    required this.switchKey,
    required this.controller,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.configured,
    required this.busy,
    required this.run,
    required this.onSetUp,
    required this.onRemove,
  });

  final Key switchKey;
  final MessengerController controller;
  final TransportKind kind;
  final String title;
  final String subtitle;

  /// Whether an account (address, keys) is kept for [kind].
  final bool configured;
  final bool busy;

  /// Runs an action, showing it as busy and its error, as the panel does.
  final Future<void> Function(Future<void> Function() action) run;
  final Future<void> Function() onSetUp;
  final Future<void> Function() onRemove;

  Future<void> _confirmRemove(BuildContext context) async {
    final l10n = l10nOf(context);
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.carrierRemoveTitle(title)),
        content: Text(l10n.carrierRemoveBody(title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            key: ValueKey('$switchKey-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.carrierRemove),
          ),
        ],
      ),
    );
    if (remove == true) await run(onRemove);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final paused = configured && controller.isCarrierPaused(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: switchKey,
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(paused ? l10n.carrierPaused : subtitle),
          value: configured && !paused,
          onChanged: busy
              ? null
              : (on) => run(() async {
                  if (configured) {
                    await controller.setCarrierPaused(kind, !on);
                  } else if (on) {
                    // Setting up turns it on, whatever it was before.
                    await controller.setCarrierPaused(kind, false);
                    await onSetUp();
                  }
                }),
        ),
        if (configured)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('$switchKey-remove'),
              onPressed: busy ? null : () => _confirmRemove(context),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.carrierRemove),
            ),
          ),
      ],
    );
  }
}
