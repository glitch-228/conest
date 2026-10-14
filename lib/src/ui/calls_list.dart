import 'package:flutter/material.dart';

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

  static String _outcome(VoiceCallSummary call) => switch (call.outcome) {
    'completed' => call.outgoing ? 'Outgoing' : 'Incoming',
    'missed' => 'Missed',
    'rejected' => 'Declined',
    'canceled' => 'Cancelled',
    _ => 'Failed',
  };

  static String _duration(VoiceCallSummary call) {
    final length = call.endedAt.difference(call.startedAt);
    if (call.outcome != 'completed' || length.inSeconds < 1) return '';
    final minutes = length.inMinutes;
    final seconds = length.inSeconds % 60;
    return ' · ${minutes > 0 ? '$minutes min ' : ''}$seconds s';
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
    final calls = [...controller.voiceCallSummaries]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (calls.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No calls yet. Open a chat and tap the call button.',
            textAlign: TextAlign.center,
          ),
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
          title: Text(contact?.alias ?? 'Unknown contact'),
          subtitle: Text('${_outcome(call)}${_duration(call)}'),
          trailing: Text(_when(call.startedAt)),
          onTap: contact == null ? null : () => onOpenContact(contact),
        );
      },
    );
  }
}
