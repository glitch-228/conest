import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../models.dart';

/// What happened to a message on its way: when it was sent, every route it
/// took or arrived by, how far it got on each, and when it was read. In a
/// group, one section per member.
class MessageInfoDialog extends StatelessWidget {
  const MessageInfoDialog({
    super.key,
    required this.message,
    this.memberLabel,
    this.timestamp,
    this.showRoutes = true,
  });

  /// Routes and transports show only in advanced mode; otherwise the
  /// details are times and states.
  final bool showRoutes;

  final ChatMessage message;

  /// Names a group member by device id; null in a direct chat.
  final String Function(String deviceId)? memberLabel;

  /// Formats a time; defaults to local hours, minutes and seconds.
  final String Function(DateTime time)? timestamp;

  static Future<void> show(
    BuildContext context, {
    required ChatMessage message,
    String Function(String deviceId)? memberLabel,
    String Function(DateTime time)? timestamp,
    bool showRoutes = true,
  }) => showDialog<void>(
    context: context,
    builder: (context) => MessageInfoDialog(
      message: message,
      memberLabel: memberLabel,
      timestamp: timestamp,
      showRoutes: showRoutes,
    ),
  );

  String _time(DateTime time) {
    final format = timestamp;
    if (format != null) return format(time);
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  static String sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String markLabel(MessageRouteMark mark, {required bool outbound}) =>
      switch (mark) {
        MessageRouteMark.sent => 'sent',
        MessageRouteMark.stored => 'waiting on the relay',
        MessageRouteMark.reachedDevice => 'reached their device',
        MessageRouteMark.confirmed => outbound ? 'delivered' : 'received',
      };

  /// When it first reached them (their receipt, or their radio).
  static DateTime? _deliveredAt(Iterable<RouteTrace> traces) {
    DateTime? first;
    for (final trace in traces) {
      if (trace.mark.index < MessageRouteMark.reachedDevice.index) continue;
      if (first == null || trace.at.isBefore(first)) first = trace.at;
    }
    return first;
  }

  List<Widget> _routeLines(
    BuildContext context,
    Iterable<RouteTrace> traces, {
    required bool outbound,
  }) {
    final sorted = traces.toList()..sort((a, b) => a.at.compareTo(b.at));
    final style = Theme.of(context).textTheme.bodyMedium;
    return [
      for (final trace in sorted)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${trace.route.label}: ${markLabel(trace.mark, outbound: outbound)} '
            '${_time(trace.at)}'
            '${trace.bytes == null ? '' : ', ${sizeLabel(trace.bytes!)}'}',
            style: style,
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final theme = Theme.of(context);
    final heading = theme.textTheme.titleSmall;
    final outbound = message.outbound;
    final members = memberLabel;
    final children = <Widget>[
      Text(
        outbound
            ? l10n.messageSentAt(_time(message.createdAt))
            : l10n.messageReceivedAt(_time(message.createdAt)),
        key: const ValueKey('message-info-time'),
      ),
    ];
    if (members == null || !outbound) {
      children.add(const SizedBox(height: 8));
      children.add(Text(message.state.label));
      final traces = message.routeTrace.where(
        (trace) =>
            members == null ||
            trace.deviceId == null ||
            trace.deviceId == message.senderDeviceId,
      );
      if (!showRoutes) {
        final deliveredAt = outbound ? _deliveredAt(traces) : null;
        if (deliveredAt != null) {
          children
            ..add(const SizedBox(height: 8))
            ..add(Text(l10n.messageDeliveredAt(_time(deliveredAt))));
        }
      } else if (traces.isNotEmpty) {
        children
          ..add(const SizedBox(height: 12))
          ..add(
            Text(
              outbound ? l10n.messageRoutes : l10n.messageArrivedBy,
              style: heading,
            ),
          )
          ..addAll(_routeLines(context, traces, outbound: outbound));
      } else if (message.effectiveRoute case final route?) {
        children
          ..add(const SizedBox(height: 12))
          ..add(Text('Route: ${route.label}'));
      }
      final readAt = message.recipientReadAt[message.recipientDeviceId];
      if (outbound && readAt != null) {
        children
          ..add(const SizedBox(height: 8))
          ..add(Text(l10n.messageReadAt(_time(readAt))));
      }
    } else {
      // A group message of ours: each member, with their routes.
      final memberIds = {
        ...message.recipientStates.keys,
        for (final trace in message.routeTrace)
          if (trace.deviceId != null) trace.deviceId!,
      }.toList()..sort((a, b) => members(a).compareTo(members(b)));
      for (final deviceId in memberIds) {
        final state = message.recipientStates[deviceId];
        final readAt = message.recipientReadAt[deviceId];
        final memberTraces = message.routeTrace.where(
          (trace) => trace.deviceId == deviceId,
        );
        final deliveredAt = showRoutes ? null : _deliveredAt(memberTraces);
        children
          ..add(const SizedBox(height: 12))
          ..add(
            Text(
              members(deviceId),
              key: ValueKey('message-info-member-$deviceId'),
              style: heading,
            ),
          )
          ..add(
            Text(
              [
                if (state != null) state.label,
                if (deliveredAt != null)
                  l10n.memberDeliveredAt(_time(deliveredAt)),
                if (readAt != null) l10n.memberReadAt(_time(readAt)),
              ].join(', '),
            ),
          )
          ..addAll(
            showRoutes
                ? _routeLines(context, memberTraces, outbound: true)
                : const <Widget>[],
          );
      }
    }
    return AlertDialog(
      title: Text(l10n.messageDetails),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionClose),
        ),
      ],
    );
  }
}
