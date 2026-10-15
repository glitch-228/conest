import 'localized_ui_text.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../group_call/group_call_models.dart';
import '../group_call/group_call_service.dart';
import '../messenger_controller.dart';
import '../models.dart' show ChatMessage;

Future<void> openGroupCallScreen(
  BuildContext context,
  MessengerController controller,
  String groupId,
) async {
  try {
    final current = controller.groupCallService?.active;
    if (current?.groupId != groupId) {
      await controller.joinOrStartGroupCall(groupId);
    }
    if (!context.mounted) return;
    final service = controller.groupCallService;
    if (service == null) return;
    final title =
        controller.groups
            .where((g) => g.groupId == groupId)
            .firstOrNull
            ?.title ??
        'Group';
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GroupCallScreen(
          groupId: groupId,
          title: title,
          service: service,
          members: () => controller.groupCallMembersFor(groupId),
          onNoiseChanged: controller.setVoiceNoiseSuppression,
        ),
      ),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
         SnackBar(
          content: Text(
            localizedUiText(context, 'Could not join the call. Check your route or leave the current call.'),
          ),
        ),
      );
    }
  }
}

class GroupCallButton extends StatelessWidget {
  const GroupCallButton({
    super.key,
    required this.controller,
    required this.groupId,
  });
  final MessengerController controller;
  final String groupId;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: controller.groupCallService?.roomFor(groupId) == null
        ? localizedUiText(context, 'Start group call')
        : localizedUiText(context, 'Join group call'),
    onPressed: controller.groupVoiceCallsAvailable
        ? () => openGroupCallScreen(context, controller, groupId)
        : null,
    icon: const Icon(Icons.call_outlined),
  );
}

/// Global incoming banner and return bar use the same foreground call state.
class GroupCallBanner extends StatelessWidget {
  const GroupCallBanner({super.key, required this.controller});
  final MessengerController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final service = controller.groupCallService;
      final room = service?.active ?? service?.rooms.firstOrNull;
      if (room == null) return const SizedBox.shrink();
      final group = controller.groups
          .where((g) => g.groupId == room.groupId)
          .firstOrNull;
      if (group == null) return const SizedBox.shrink();
      final caller = controller
          .groupCallMembersFor(room.groupId)
          .where((m) => m.deviceId == room.startedBy)
          .firstOrNull;
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.call),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  room.joined
                      ? localizedUiText(context, 'Call in ${group.title}')
                      : localizedUiText(context, '${caller?.name ?? 'A member'} started a call in ${group.title}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: controller.groupVoiceCallsAvailable
                    ? () =>
                          openGroupCallScreen(context, controller, room.groupId)
                    : null,
                child: Text(room.joined ? localizedUiText(context, 'Return') : localizedUiText(context, 'Join')),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class GroupCallScreen extends StatefulWidget {
  const GroupCallScreen({
    super.key,
    required this.groupId,
    required this.title,
    required this.service,
    required this.members,
    this.onNoiseChanged,
  });
  final String groupId;
  final String title;
  final GroupCallService service;
  final List<GroupCallMember> Function() members;
  final Future<void> Function(bool)? onNoiseChanged;
  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen>
    with WidgetsBindingObserver {
  bool _busy = false;
  GroupCallRoom? get _room => widget.service.roomFor(widget.groupId);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _releaseTalk() {
    final room = _room;
    if (room?.holdingToTalk == true) {
      unawaited(widget.service.setPushToTalk(true).catchError((Object _) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _releaseTalk();
  }

  @override
  void dispose() {
    _releaseTalk();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text(localizedUiText(context, 'Could not update the call.'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  void _hold(bool held) {
    if (_room?.pushToTalk != true) return;
    unawaited(
      widget.service.setPushToTalk(true, held: held).catchError((Object _) {}),
    );
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (_room?.pushToTalk != true ||
        event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _hold(true);
    if (event is KeyUpEvent) _hold(false);
    return KeyEventResult.handled;
  }

  String _quality(GroupCallMember member, GroupCallRoom room) {
    if (!member.canJoin) return "Can't join (update needed)";
    if (!member.directRoute) return "Can't reach (no direct route)";
    if (!room.participants.any((p) => p.deviceId == member.deviceId)) {
      return 'Not in the call';
    }
    if (!room.connected) return 'Connecting…';
    final stats = room.stats[member.deviceId];
    if (stats == null) return 'Connected';
    return stats.poor
        ? 'Weak connection'
        : stats.rttMs == 0
        ? 'Connected'
        : '${stats.rttMs} ms';
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.service.changes,
    builder: (context, _) {
      final room = _room;
      final members = widget.members();
      return Focus(
        autofocus: true,
        onKeyEvent: _key,
        onFocusChange: (focused) {
          if (!focused) _releaseTalk();
        },
        child: Scaffold(
          appBar: AppBar(title: Text(widget.title)),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Text(
                      room == null
                          ? localizedUiText(context, 'Call ended')
                          : room.connected
                          ? localizedUiText(context, 'Voice call')
                          : localizedUiText(context, 'Connecting…'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (room?.forwarder != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          localizedUiText(context, 'Call via ${members.where((m) => m.deviceId == room!.forwarder).firstOrNull?.name ?? 'a member'}'),
                        ),
                      ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final member in members)
                            ListTile(
                              leading: Icon(
                                widget.service.level(member.deviceId) > 0.015
                                    ? Icons.graphic_eq
                                    : Icons.person_outline,
                                color:
                                    widget.service.level(member.deviceId) >
                                        0.015
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              title: Text(
                                member.deviceId == widget.service.localDeviceId
                                    ? localizedUiText(context, '${member.name} (you)')
                                    : member.name,
                              ),
                              subtitle: Text(
                                room == null
                                    ? localizedUiText(context, 'Call ended')
                                    : _quality(member, room),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (room?.joined == true) ...[
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => widget.service.setMuted(!room!.muted),
                                  ),
                            icon: Icon(room!.muted ? Icons.mic_off : Icons.mic),
                            label: Text(room.muted ? localizedUiText(context, 'Unmute') : localizedUiText(context, 'Mute')),
                          ),
                          FilterChip(
                            label:  Text(localizedUiText(context, 'Push-to-talk')),
                            selected: room.pushToTalk,
                            onSelected: _busy
                                ? null
                                : (enabled) => _run(
                                    () => widget.service.setPushToTalk(enabled),
                                  ),
                          ),
                          FilterChip(
                            label:  Text(localizedUiText(context, 'Noise suppression')),
                            selected: widget.service.noiseSuppressionEnabled,
                            onSelected: _busy
                                ? null
                                : (enabled) => _run(
                                    () =>
                                        (widget.onNoiseChanged ??
                                        widget.service.setNoiseSuppression)(
                                          enabled,
                                        ),
                                  ),
                          ),
                        ],
                      ),
                      if (room.pushToTalk)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Listener(
                            key: const ValueKey('group-call-hold-to-talk'),
                            onPointerDown: (_) => _hold(true),
                            onPointerUp: (_) => _hold(false),
                            onPointerCancel: (_) => _hold(false),
                            child: Semantics(
                              label: localizedUiText(context, 'Hold to talk, or hold Space'),
                              button: true,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 18,
                                ),
                                decoration: BoxDecoration(
                                  color: room.holdingToTalk
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  room.holdingToTalk
                                      ? localizedUiText(context, 'Talking…')
                                      : localizedUiText(context, 'Hold to talk · Space'),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await widget.service.leave();
                                  if (context.mounted) {
                                    Navigator.of(context).pop();
                                  }
                                }),
                          icon: const Icon(Icons.call_end),
                          label:  Text(localizedUiText(context, 'Leave')),
                        ),
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child:  Text(localizedUiText(context, 'Done')),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class GroupCallChatEntry {
  const GroupCallChatEntry({this.messageIndex, this.summary, required this.at});
  final int? messageIndex;
  final GroupCallSummary? summary;
  final DateTime at;
}

List<GroupCallChatEntry> groupCallChatTimeline(
  List<ChatMessage> messages,
  List<GroupCallSummary> summaries,
) {
  final entries = [
    for (var i = 0; i < messages.length; i++)
      GroupCallChatEntry(messageIndex: i, at: messages[i].createdAt),
    for (final summary in summaries)
      GroupCallChatEntry(summary: summary, at: summary.endedAt),
  ];
  entries.sort((a, b) => a.at.compareTo(b.at));
  return entries;
}

class GroupCallSummaryTile extends StatelessWidget {
  const GroupCallSummaryTile({
    super.key,
    required this.summary,
    required this.labelFor,
  });
  final GroupCallSummary summary;
  final String Function(String) labelFor;
  @override
  Widget build(BuildContext context) {
    final seconds = summary.duration.inSeconds.clamp(0, 86400);
    final duration =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.call_end_outlined),
        title: Text(localizedUiText(context, 'Voice call · $duration')),
        subtitle: Text(
          localizedUiText(context, 'Started by ${labelFor(summary.startedBy)} · ${summary.participants.length} participants'),
        ),
      ),
    );
  }
}
