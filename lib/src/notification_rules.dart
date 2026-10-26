/// Quiet hours: notifications still appear, without sound or vibration,
/// between [startMinute] and [endMinute] (local time, minutes after
/// midnight; across midnight when the end is earlier) on the chosen days.
class QuietHours {
  const QuietHours({
    this.enabled = false,
    this.startMinute = 22 * 60,
    this.endMinute = 7 * 60,
    this.days = const {1, 2, 3, 4, 5, 6, 7},
    this.callsRing = true,
  });

  final bool enabled;
  final int startMinute;
  final int endMinute;

  /// Weekdays (DateTime.monday = 1 … sunday = 7) on which quiet hours
  /// start.
  final Set<int> days;

  /// Whether an incoming call still rings during quiet hours.
  final bool callsRing;

  /// Whether [local] (this device's local time) falls in quiet hours.
  bool quietAt(DateTime local) {
    if (!enabled || startMinute == endMinute) return false;
    final minute = local.hour * 60 + local.minute;
    if (startMinute < endMinute) {
      return days.contains(local.weekday) &&
          minute >= startMinute &&
          minute < endMinute;
    }
    // Across midnight: the evening part counts for today, the morning
    // part for the day before.
    if (minute >= startMinute) return days.contains(local.weekday);
    if (minute < endMinute) {
      return days.contains(local.subtract(const Duration(days: 1)).weekday);
    }
    return false;
  }

  QuietHours copyWith({
    bool? enabled,
    int? startMinute,
    int? endMinute,
    Set<int>? days,
    bool? callsRing,
  }) => QuietHours(
    enabled: enabled ?? this.enabled,
    startMinute: _minute(startMinute ?? this.startMinute),
    endMinute: _minute(endMinute ?? this.endMinute),
    days: _days(days ?? this.days),
    callsRing: callsRing ?? this.callsRing,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'startMinute': startMinute,
    'endMinute': endMinute,
    'days': (days.toList()..sort()),
    'callsRing': callsRing,
  };

  factory QuietHours.fromJson(Object? json) {
    if (json is! Map) return const QuietHours();
    final days = json['days'];
    return QuietHours(
      enabled: json['enabled'] == true,
      startMinute: _minute(json['startMinute'], 22 * 60),
      endMinute: _minute(json['endMinute'], 7 * 60),
      days: days is List
          ? _days(days.whereType<int>().toSet())
          : const {1, 2, 3, 4, 5, 6, 7},
      callsRing: json['callsRing'] as bool? ?? true,
    );
  }

  static int _minute(Object? value, [int fallback = 0]) =>
      value is int && value >= 0 && value < 24 * 60 ? value : fallback;
  static Set<int> _days(Set<int> days) =>
      days.where((day) => day >= 1 && day <= 7).toSet();
}

/// Whether a group message mentions this device's user: "@" and their
/// name (not followed by more of a word), or a reply to their message.
bool mentionsMe({
  required String body,
  required String myName,
  required bool replyToMe,
}) {
  if (replyToMe) return true;
  final name = myName.trim();
  if (name.isEmpty || body.length > 65536) return false;
  final at = RegExp(
    '@${RegExp.escape(name)}(?![\\p{L}\\p{N}_])',
    caseSensitive: false,
    unicode: true,
  );
  return at.hasMatch(body);
}
