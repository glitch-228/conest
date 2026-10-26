import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../circumvention/circumvention.dart';
import '../messenger_controller.dart';

/// Settings → Connectivity → Censorship circumvention (Advanced mode):
/// private DNS and split TLS greetings, each automatic, always or off.
class CircumventionSettingsSection extends StatelessWidget {
  const CircumventionSettingsSection({
    super.key,
    required this.controller,
    required this.busy,
  });

  final MessengerController controller;
  final bool busy;

  Future<void> _set(CircumventionPreferences preferences) async {
    final identity = controller.identity;
    if (identity == null) return;
    await controller.updateGlobalConnectivity(
      identity.connectivity.copyWith(circumvention: preferences),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final identity = controller.identity;
    if (identity == null) return const SizedBox.shrink();
    final preferences = identity.connectivity.circumvention;
    final inUse = controller.circumventionInUse;
    Widget choice({
      required Key key,
      required String title,
      String? subtitle,
      required CircumventionPolicy value,
      required bool active,
      required CircumventionPreferences Function(CircumventionPolicy) apply,
    }) {
      return ListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(
          [
            ?subtitle,
            active ? l10n.circumventionActiveHere : l10n.circumventionIdleHere,
          ].join('\n'),
        ),
        trailing: DropdownButton<CircumventionPolicy>(
          value: value,
          onChanged: busy
              ? null
              : (policy) {
                  if (policy != null) _set(apply(policy));
                },
          items: [
            for (final policy in CircumventionPolicy.values)
              DropdownMenuItem(
                value: policy,
                child: Text(switch (policy) {
                  CircumventionPolicy.automatic => l10n.circumventionAutomatic,
                  CircumventionPolicy.always => l10n.circumventionAlways,
                  CircumventionPolicy.never => l10n.circumventionNever,
                }),
              ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          l10n.circumventionTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.circumventionIntro,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        choice(
          key: const ValueKey('circumvention-private-dns'),
          title: l10n.circumventionPrivateDns,
          value: preferences.privateDns,
          active: inUse.privateDns,
          apply: (policy) => preferences.copyWith(privateDns: policy),
        ),
        choice(
          key: const ValueKey('circumvention-split-greeting'),
          title: l10n.circumventionSplitGreeting,
          subtitle: l10n.circumventionSplitGreetingHint,
          value: preferences.splitGreeting,
          active: inUse.splitGreeting,
          apply: (policy) => preferences.copyWith(splitGreeting: policy),
        ),
      ],
    );
  }
}
