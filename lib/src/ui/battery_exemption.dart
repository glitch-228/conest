import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../messenger_controller.dart';

/// Makers whose phones stop background apps beyond Android's own battery
/// optimisation (an autostart switch, their own battery saver).
const _strictMakers = {
  'xiaomi',
  'redmi',
  'poco',
  'huawei',
  'honor',
  'oppo',
  'realme',
  'vivo',
  'oneplus',
};

/// The phone maker to name in the extra steps, or null when none apply.
String? strictBackgroundMaker(String? manufacturer) {
  final maker = manufacturer?.trim() ?? '';
  return _strictMakers.contains(maker.toLowerCase()) ? maker : null;
}

/// Before Android's request to leave Conest out of battery optimisation:
/// why, and (on phones that need it) the vendor's extra steps. Pops true
/// to go on to Android's request.
class BatteryExemptionDialog extends StatelessWidget {
  const BatteryExemptionDialog({super.key, this.manufacturer});

  final String? manufacturer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final maker = strictBackgroundMaker(manufacturer);
    return AlertDialog(
      title: Text(l10n.batteryExemptionPromptTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.batteryExemptionPromptBody),
          if (maker != null) ...[
            const SizedBox(height: 12),
            Text(l10n.batteryExemptionVendorHint(maker)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.transportsBannerDismiss),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.batteryExemptionAllow),
        ),
      ],
    );
  }
}

/// Settings row: whether Android limits Conest in the background, with a
/// way to lift it. Looked at again when the app comes back to the front
/// (after Android's own screen).
class BatteryExemptionTile extends StatefulWidget {
  const BatteryExemptionTile({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<BatteryExemptionTile> createState() => _BatteryExemptionTileState();
}

class _BatteryExemptionTileState extends State<BatteryExemptionTile>
    with WidgetsBindingObserver {
  bool? _exempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final exempt = await widget.controller.batteryOptimizationExempt();
    if (mounted) setState(() => _exempt = exempt);
  }

  @override
  Widget build(BuildContext context) {
    final exempt = _exempt;
    if (exempt == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.batteryExemptionTitle),
      subtitle: Text(
        exempt ? l10n.batteryExemptionAllowed : l10n.batteryExemptionLimited,
      ),
      trailing: exempt
          ? null
          : TextButton(
              onPressed: () => widget.controller.requestBatteryExemption(),
              child: Text(l10n.batteryExemptionAllow),
            ),
    );
  }
}
