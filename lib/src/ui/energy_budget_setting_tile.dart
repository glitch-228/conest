import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../energy_budget_setting.dart';
import '../messenger_controller.dart';

/// Settings → Connectivity → Power use: Balanced, Eco (more only while
/// charging) or Fast.
class EnergyBudgetSettingTile extends StatelessWidget {
  const EnergyBudgetSettingTile({
    super.key,
    required this.controller,
    required this.busy,
  });

  final MessengerController controller;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final identity = controller.identity;
    if (identity == null) return const SizedBox.shrink();
    String label(EnergyBudgetSetting setting) => switch (setting) {
      EnergyBudgetSetting.balanced => l10n.energyBudgetBalanced,
      EnergyBudgetSetting.eco => l10n.energyBudgetEco,
      EnergyBudgetSetting.fast => l10n.energyBudgetFast,
    };
    return ListTile(
      key: const Key('energy-budget-setting'),
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.energyBudgetTitle),
      subtitle: Text(l10n.energyBudgetSubtitle),
      trailing: DropdownButton<EnergyBudgetSetting>(
        value: identity.connectivity.energyBudget,
        onChanged: busy
            ? null
            : (value) {
                if (value != null) controller.setEnergyBudget(value);
              },
        items: [
          for (final setting in EnergyBudgetSetting.values)
            DropdownMenuItem(value: setting, child: Text(label(setting))),
        ],
      ),
    );
  }
}
