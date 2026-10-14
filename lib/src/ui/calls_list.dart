import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_locales.dart';
import '../messenger_controller.dart';
import '../models.dart';

/// Recent calls, newest first: who, which way, how it ended, when. A tap
/// opens the chat with them (the call button is there).
class CallsList extends StatelessWidget {
  const CallsList({
    super.key,
    required this.controller,
    required this.onOpenContact,
  });

  final MessengerController controller;
  final void Function(ContactRecord contact) onOpenContact;

  static String _outcome(AppLocalizations l10n, VoiceCallSummary call) =>
      switch (call.outcome) {
        'completed' => call.outgoing ? l10n.callOutgoing : l10n.callIncoming,
        'missed' => l10n.callMissed,
        'rejected' => l10n.callDeclined,
        'canceled' => l10n.callCancelled,
        _ => l10n.callFailed,
      };

  static String _duration(AppLocalizations l10n, VoiceCallSummary call) {
    final length = call.endedAt.difference(call.startedAt);
    if (call.outcome != 'completed' || length.inSeconds < 1) return '';
    return ' · ${l10n.callDuration(length.inMinutes, length.inSeconds % 60)}';
  }

  static String _when(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final clock = '${two(local.hour)}:${two(local.minute)}';
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return clock;
    }
    return '${local.day}.${two(local.month)}. $clock';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final calls = [...controller.voiceCallSummaries]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (calls.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.callsEmpty, textAlign: TextAlign.center),
        ),
      );
    }
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: calls.length,
      itemBuilder: (context, index) {
        final call = calls[index];
        final contact = controller.contactByDeviceId(call.peerDeviceId);
        final missed = call.outcome == 'missed' && !call.outgoing;
        return ListTile(
          key: ValueKey('call-${call.callId}'),
          leading: Icon(
            call.outgoing ? Icons.call_made : Icons.call_received,
            color: missed ? theme.colorScheme.error : null,
          ),
          title: Text(contact?.alias ?? l10n.unknownContact),
          subtitle: Text('${_outcome(l10n, call)}${_duration(l10n, call)}'),
          trailing: Text(_when(call.startedAt)),
          onTap: contact == null ? null : () => onOpenContact(contact),
        );
      },
    );
  }
}
