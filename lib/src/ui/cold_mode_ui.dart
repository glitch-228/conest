import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../cold_mode.dart';
import '../messenger_controller.dart';

/// "Cold mode · checked 3 min ago" with a refresh action; nothing when cold
/// mode is off.
class ColdModeBanner extends StatelessWidget {
  const ColdModeBanner({
    super.key,
    required this.controller,
    this.compact = false,
    this.now,
  });

  final MessengerController controller;

  /// Inside a chat: a thin row.
  final bool compact;

  /// The clock (tests).
  final DateTime Function()? now;

  static String agoLabel(BuildContext context, Duration age) {
    final l10n = l10nOf(context);
    if (age < const Duration(minutes: 1)) return l10n.coldAgoJustNow;
    if (age < const Duration(hours: 1)) {
      return l10n.coldAgoMinutes(age.inMinutes);
    }
    return l10n.coldAgoHours(age.inHours);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.coldModeActive) return const SizedBox.shrink();
        final l10n = l10nOf(context);
        final checked = controller.coldLastCheckedAt;
        final age = checked == null
            ? null
            : (now ?? DateTime.now)().difference(checked);
        final text = age == null
            ? l10n.coldBannerNeverChecked
            : l10n.coldBannerChecked(agoLabel(context, age));
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: EdgeInsets.only(bottom: compact ? 0 : 10),
          child: Container(
            key: const ValueKey('cold-mode-banner'),
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: compact ? 0 : 2,
            ),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(compact ? 0 : 12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.ac_unit,
                  size: 16,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('cold-mode-refresh'),
                  tooltip: l10n.coldRefresh,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.refresh,
                    size: 18,
                    color: scheme.onSecondaryContainer,
                  ),
                  onPressed: () => controller.refreshNow(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Pull to refresh for the chat list in cold mode.
class ColdRefresh extends StatelessWidget {
  const ColdRefresh({super.key, required this.controller, required this.child});

  final MessengerController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) => controller.coldModeActive
          ? RefreshIndicator(onRefresh: controller.refreshNow, child: child!)
          : child!,
      child: child,
    );
  }
}

/// Settings → Connectivity, under Power use: how often a cold device looks
/// for news, and what each route does in cold mode.
class ColdModeSettings extends StatelessWidget {
  const ColdModeSettings({
    super.key,
    required this.controller,
    required this.busy,
  });

  final MessengerController controller;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final identity = controller.identity;
    if (identity == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final l10n = l10nOf(context);
        final prefs = controller.identity!.connectivity;
        String modeLabel(ColdTransportMode mode) => switch (mode) {
          ColdTransportMode.cold => l10n.coldTransportCold,
          ColdTransportMode.alwaysOn => l10n.coldTransportAlwaysOn,
          ColdTransportMode.off => l10n.coldTransportOff,
        };
        return Column(
          key: const ValueKey('cold-mode-settings'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.coldWakeTitle),
              subtitle: Text(l10n.coldWakeNote),
              trailing: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: DropdownButton<int>(
                  key: const ValueKey('cold-wake-minutes'),
                  isExpanded: true,
                  value: prefs.coldWakeMinutes,
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          controller.updateGlobalConnectivity(
                            prefs.copyWith(coldWakeMinutes: value),
                          );
                        },
                  items: [
                    for (final minutes in coldWakeMinuteChoices)
                      DropdownMenuItem(
                        value: minutes,
                        child: Text(
                          minutes == 0
                              ? l10n.coldWakeManual
                              : l10n.coldWakeMinutes(minutes),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (controller.coldTransports.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.coldTransportsTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final transport in controller.coldTransports)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(transport.id),
                  trailing: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: DropdownButton<ColdTransportMode>(
                      key: ValueKey('cold-mode-${transport.id}'),
                      isExpanded: true,
                      value:
                          prefs.coldTransportModes[transport.id] ??
                          ColdTransportMode.cold,
                      onChanged: busy
                          ? null
                          : (value) {
                              if (value == null) return;
                              controller.updateGlobalConnectivity(
                                prefs.copyWith(
                                  coldTransportModes: {
                                    ...prefs.coldTransportModes,
                                    transport.id: value,
                                  },
                                ),
                              );
                            },
                      items: [
                        for (final mode in ColdTransportMode.values)
                          DropdownMenuItem(
                            value: mode,
                            child: Text(
                              modeLabel(mode),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}
