import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../chat_day_separator.dart';
import '../models.dart';

/// What a message bubble knows about when it got there, beyond when it was
/// sent: a message delivered (outgoing) or arrived (incoming) more than a
/// minute after it was sent shows both times.
class MessageTimes {
  const MessageTimes._();

  /// A message later than this shows its second time.
  static const Duration lateAfter = Duration(minutes: 1);

  /// When the first of [traces] reached the other side (their receipt, or
  /// their radio).
  static DateTime? firstReachedAt(Iterable<RouteTrace> traces) {
    DateTime? first;
    for (final trace in traces) {
      if (trace.mark.index < MessageRouteMark.reachedDevice.index) continue;
      if (first == null || trace.at.isBefore(first)) first = trace.at;
    }
    return first;
  }

  /// When an outgoing message was confirmed: in a chat, by the first route
  /// that reached them; in a group, once the last member who still counts
  /// had it. Null while it is not confirmed (everywhere, in a group), or
  /// when no time was kept.
  static DateTime? deliveredAt(ChatMessage message) {
    if (!message.outbound) return null;
    if (message.state != DeliveryState.delivered &&
        message.state != DeliveryState.read) {
      return null;
    }
    if (message.recipientStates.isEmpty) {
      return firstReachedAt(message.routeTrace);
    }
    DateTime? last;
    for (final MapEntry(key: deviceId, value: state)
        in message.recipientStates.entries) {
      if (state == DeliveryState.canceled) continue;
      final at = firstReachedAt(
        message.routeTrace.where((trace) => trace.deviceId == deviceId),
      );
      if (at != null && (last == null || at.isAfter(last))) last = at;
    }
    return last;
  }

  /// The second time to show and whether it is an arrival (incoming) or a
  /// delivery (outgoing); null when the message was not late.
  /// [senderClockOffset] is how far the sender's clock is behind ours.
  static ({DateTime time, bool arrived})? second(
    ChatMessage message, {
    Duration? senderClockOffset,
  }) {
    if (message.outbound) {
      final at = deliveredAt(message);
      if (at == null || at.difference(message.createdAt) <= lateAfter) {
        return null;
      }
      return (time: at, arrived: false);
    }
    final at = message.receivedAt;
    if (at == null) return null;
    final sent = message.createdAt.add(senderClockOffset ?? Duration.zero);
    if (at.difference(sent) <= lateAfter) return null;
    return (time: at, arrived: true);
  }

  /// How many members of a group confirmed an outgoing [message], and how
  /// many still count; null for a chat.
  static ({int delivered, int total})? groupProgress(ChatMessage message) {
    if (!message.outbound || message.recipientStates.isEmpty) return null;
    var delivered = 0;
    var total = 0;
    for (final state in message.recipientStates.values) {
      if (state == DeliveryState.canceled) continue;
      total++;
      if (state == DeliveryState.delivered || state == DeliveryState.read) {
        delivered++;
      }
    }
    return (delivered: delivered, total: total);
  }
}

/// The time row of a bubble: when the message was sent, and, when it came
/// late, when it was delivered or arrived.
class MessageTimeLabel extends StatelessWidget {
  const MessageTimeLabel({
    super.key,
    required this.message,
    required this.format,
    this.senderClockOffset,
    this.style,
  });

  final ChatMessage message;

  /// Formats a time of day.
  final String Function(DateTime time) format;
  final Duration? senderClockOffset;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final sent = format(message.createdAt);
    final second = MessageTimes.second(
      message,
      senderClockOffset: senderClockOffset,
    );
    if (second == null) return Text(sent, style: style);
    final l10n = l10nOf(context);
    var time = format(second.time);
    // A different day says which.
    if (!sameChatDay(second.time, message.createdAt)) {
      time =
          '${MaterialLocalizations.of(context).formatShortDate(second.time.toLocal())} $time';
    }
    final label = second.arrived
        ? l10n.messageTimeArrived(time)
        : l10n.messageTimeDelivered(time);
    return Text(
      '$sent · $label',
      key: const ValueKey('message-time-late'),
      style: style,
    );
  }
}
