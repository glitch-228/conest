import 'package:flutter/material.dart';

bool sameChatDay(DateTime left, DateTime right) {
  final a = left.toLocal();
  final b = right.toLocal();
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String chatMessageTime(BuildContext context, DateTime timestamp) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(timestamp.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

class ChatDaySeparator extends StatelessWidget {
  const ChatDaySeparator({
    super.key,
    required this.timestamp,
    required this.background,
    required this.foreground,
  });
  final DateTime timestamp;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final date = timestamp.toLocal();
    final label = sameChatDay(date, now)
        ? 'Today'
        : sameChatDay(date, yesterday)
        ? 'Yesterday'
        : '${MaterialLocalizations.of(context).formatMediumDate(date)}${date.year == now.year ? '' : ', ${date.year}'}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Semantics(
          header: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
