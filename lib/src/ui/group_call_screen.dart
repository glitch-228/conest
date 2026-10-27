import '../app_locales.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../group_call/group_call_models.dart';
import '../group_call/group_call_service.dart';
import '../messenger_controller.dart';
import '../models.dart' show ChatMessage;
import '../voice_settings.dart';
import 'voice_settings_panel.dart';

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
          // Push-to-talk is Settings → Voice's input mode (1:1 calls too).
          onPushToTalkChanged: (enabled) => controller.updateVoiceSettings(
            controller.voiceSettings.copyWith(
              inputMode: enabled
                  ? VoiceInputMode.pushToTalk
                  : VoiceInputMode.always,
            ),
          ),
          onHoldToTalk: controller.setPushToTalkHeld,
          // A chosen key works app-wide; without one, space here.
          hasPushToTalkKey: () =>
              controller.voiceSettings.pushToTalkKey != null,
          volumeFor: (deviceId) => controller.voiceSettings.volumeFor(deviceId),
          onVolumeChanged: controller.setCallParticipantVolume,
          onOpenVoiceSettings: (context) =>
              showVoiceSettingsSheet(context, controller),
        ),
      ),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10nOf(context).uiCouldNotJoinTheCall252D45)),
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
        ? l10nOf(context).uiStartGroupCallC2A083
        : l10nOf(context).uiJoinGroupCallC9ECF8,
    onPressed: controller.groupVoiceCallsAvailable
        ? () => openGroupCallScreen(context, controller, groupId)
        : null,
    icon: const Icon(Icons.call_outlined),
  );
}

/// A group call: in the group's own chat ([groupId]), its invitation ("…
/// started a call") or the way back into it; everywhere else (no
/// [groupId]) only the way back into a call this device has joined.
class GroupCallBanner extends StatelessWidget {
  const GroupCallBanner({super.key, required this.controller, this.groupId});
  final MessengerController controller;
  final String? groupId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final service = controller.groupCallService;
      final only = groupId;
      final room = only == null
          ? (service?.active?.joined == true ? service!.active : null)
          : (service?.active?.groupId == only
                ? service!.active
                : service?.rooms.where((r) => r.groupId == only).firstOrNull);
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
                      ? l10nOf(
                          context,
                        ).uiCallInValue16F998((group.title).toString())
                      : l10nOf(context).uiValueStartedACallIn278E96(
                          (caller?.name ?? l10nOf(context).groupUnknownMember)
                              .toString(),
                          (group.title).toString(),
                        ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: controller.groupVoiceCallsAvailable
                    ? () =>
                          openGroupCallScreen(context, controller, room.groupId)
                    : null,
                child: Text(
                  room.joined
                      ? l10nOf(context).uiReturn24F096
                      : l10nOf(context).uiJoinE0D731,
                ),
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
    this.onPushToTalkChanged,
    this.onHoldToTalk,
    this.hasPushToTalkKey,
    this.volumeFor,
    this.onVolumeChanged,
    this.onOpenVoiceSettings,
  });
  final String groupId;
  final String title;
  final GroupCallService service;
  final List<GroupCallMember> Function() members;
  final Future<void> Function(bool)? onNoiseChanged;
  final Future<void> Function(bool enabled)? onPushToTalkChanged;
  final Future<void> Function(bool held)? onHoldToTalk;
  final bool Function()? hasPushToTalkKey;
  final double Function(String deviceId)? volumeFor;
  final Future<void> Function(String deviceId, double gain)? onVolumeChanged;
  final void Function(BuildContext context)? onOpenVoiceSettings;
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
      unawaited(
        (widget.onHoldToTalk?.call(false) ?? widget.service.setPushToTalk(true))
            .catchError((Object _) {}),
      );
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
          SnackBar(
            content: Text(l10nOf(context).uiCouldNotUpdateTheCall33517D),
          ),
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
      (widget.onHoldToTalk?.call(held) ??
              widget.service.setPushToTalk(true, held: held))
          .catchError((Object _) {}),
    );
  }

  Future<void> _chooseVolume(GroupCallMember member) async {
    final change = widget.onVolumeChanged;
    if (change == null) return;
    var value = widget.volumeFor?.call(member.deviceId) ?? 1;
    final chosen = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(l10nOf(context).voiceParticipantVolume(member.name)),
          content: Slider(
            key: const ValueKey('group-call-member-volume'),
            value: value,
            max: 2,
            divisions: 40,
            label: '${(value * 100).round()}%',
            onChanged: (v) => setDialog(() => value = v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10nOf(context).actionCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(value),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      ),
    );
    if (chosen != null) await change(member.deviceId, chosen);
    if (mounted) setState(() {});
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (_room?.pushToTalk != true ||
        widget.hasPushToTalkKey?.call() == true ||
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
                          ? l10nOf(context).uiCallEnded9933A4
                          : room.connected
                          ? l10nOf(context).uiVoiceCallB8499D
                          : l10nOf(context).uiConnectingFD3E79,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (room?.forwarder != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          l10nOf(context).uiCallViaValue0A68E8(
                            (members
                                        .where(
                                          (m) => m.deviceId == room!.forwarder,
                                        )
                                        .firstOrNull
                                        ?.name ??
                                    l10nOf(context).groupUnknownMember)
                                .toString(),
                          ),
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
                                    ? l10nOf(context).uiValueYouEFED9A(
                                        (member.name).toString(),
                                      )
                                    : member.name,
                              ),
                              subtitle: Text(
                                room == null
                                    ? l10nOf(context).uiCallEnded9933A4
                                    : _quality(member, room),
                              ),
                              trailing:
                                  widget.onVolumeChanged == null ||
                                      member.deviceId ==
                                          widget.service.localDeviceId
                                  ? null
                                  : IconButton(
                                      key: ValueKey(
                                        'group-call-volume-${member.deviceId}',
                                      ),
                                      tooltip: l10nOf(
                                        context,
                                      ).voiceParticipantVolume(member.name),
                                      icon: Icon(
                                        (widget.volumeFor?.call(
                                                      member.deviceId,
                                                    ) ??
                                                    1) ==
                                                1
                                            ? Icons.volume_up_outlined
                                            : Icons.tune,
                                      ),
                                      onPressed: () => _chooseVolume(member),
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
                            label: Text(
                              room.muted
                                  ? l10nOf(context).uiUnmute7044C3
                                  : l10nOf(context).uiMute0F0973,
                            ),
                          ),
                          FilterChip(
                            label: Text(l10nOf(context).uiPushToTalk032E78),
                            selected: room.pushToTalk,
                            onSelected: _busy
                                ? null
                                : (enabled) => _run(
                                    () =>
                                        (widget.onPushToTalkChanged ??
                                        widget.service.setPushToTalk)(enabled),
                                  ),
                          ),
                          if (widget.onOpenVoiceSettings != null)
                            OutlinedButton.icon(
                              key: const ValueKey('group-call-voice-settings'),
                              onPressed: () =>
                                  widget.onOpenVoiceSettings!(context),
                              icon: const Icon(Icons.tune),
                              label: Text(l10nOf(context).voiceSettingsButton),
                            ),
                          FilterChip(
                            label: Text(
                              l10nOf(context).uiNoiseSuppression71DE3C,
                            ),
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
                              label: l10nOf(context).uiHoldToTalkOrHold74FC22,
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
                                      ? l10nOf(context).uiTalkingC34D84
                                      : l10nOf(context).uiHoldToTalkSpace869505,
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
                          label: Text(l10nOf(context).uiLeave7E3520),
                        ),
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(l10nOf(context).uiDoneE9B450),
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
        title: Text(
          l10nOf(context).uiVoiceCallValueBD3141((duration).toString()),
        ),
        subtitle: Text(
          l10nOf(context).uiStartedByValueValueParticipants99F03D(
            (labelFor(summary.startedBy)).toString(),
            (summary.participants.length),
          ),
        ),
      ),
    );
  }
}
