import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../notification_rules.dart';

/// Settings → Notifications: quiet hours (notifications come without
/// sound or vibration at night, or as set).
class QuietHoursSettings extends StatelessWidget {
  const QuietHoursSettings({
    super.key,
    required this.quietHours,
    required this.onChanged,
  });

  final QuietHours quietHours;
  final ValueChanged<QuietHours> onChanged;

  static String _time(BuildContext context, int minute) =>
      TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context);

  Future<void> _pick(
    BuildContext context, {
    required int minute,
    required ValueChanged<int> onPicked,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
    if (picked != null) onPicked(picked.hour * 60 + picked.minute);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final quiet = quietHours;
    final dayNames = MaterialLocalizations.of(context).narrowWeekdays;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('quiet-hours-enabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.quietHoursTitle),
          subtitle: Text(l10n.quietHoursHint),
          value: quiet.enabled,
          onChanged: (on) => onChanged(quiet.copyWith(enabled: on)),
        ),
        if (quiet.enabled) ...[
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                key: const ValueKey('quiet-hours-start'),
                onPressed: () => _pick(
                  context,
                  minute: quiet.startMinute,
                  onPicked: (m) => onChanged(quiet.copyWith(startMinute: m)),
                ),
                child: Text(
                  l10n.quietHoursFrom(_time(context, quiet.startMinute)),
                ),
              ),
              OutlinedButton(
                key: const ValueKey('quiet-hours-end'),
                onPressed: () => _pick(
                  context,
                  minute: quiet.endMinute,
                  onPicked: (m) => onChanged(quiet.copyWith(endMinute: m)),
                ),
                child: Text(
                  l10n.quietHoursUntil(_time(context, quiet.endMinute)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            children: [
              // Monday first; Material's list starts on Sunday.
              for (final day in const [1, 2, 3, 4, 5, 6, 7])
                FilterChip(
                  key: ValueKey('quiet-hours-day-$day'),
                  label: Text(dayNames[day % 7]),
                  selected: quiet.days.contains(day),
                  onSelected: (on) => onChanged(
                    quiet.copyWith(
                      days: on
                          ? {...quiet.days, day}
                          : ({...quiet.days}..remove(day)),
                    ),
                  ),
                ),
            ],
          ),
          SwitchListTile.adaptive(
            key: const ValueKey('quiet-hours-calls'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.quietHoursCallsRing),
            value: quiet.callsRing,
            onChanged: (on) => onChanged(quiet.copyWith(callsRing: on)),
          ),
        ],
      ],
    );
  }
}
