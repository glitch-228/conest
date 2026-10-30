import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../transport_models.dart';

/// A radio's page: how much of its airtime budget the last minute used.
class AirtimeBudgetLine extends StatelessWidget {
  const AirtimeBudgetLine({
    super.key,
    required this.controller,
    required this.kind,
  });

  final MessengerController controller;
  final TransportKind kind;

  @override
  Widget build(BuildContext context) {
    final used = controller.radioAirtimeUsed(kind);
    if (used == null) return const SizedBox.shrink();
    final percent = (used * 100).clamp(0, 100).round();
    return ListTile(
      key: ValueKey('airtime-budget-${kind.name}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(l10nOf(context).airtimeBudgetUsed(percent)),
      subtitle: LinearProgressIndicator(value: used.clamp(0, 1).toDouble()),
    );
  }
}
