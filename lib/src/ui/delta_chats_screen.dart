import '../app_locales.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../main.dart' show buildDeltaAttachment;
import '../delta_chats.dart';
import 'delta_content_widgets.dart';
import '../messenger_controller.dart';

/// Delta Chat in Settings → Connectivity: on or off, this account's
/// invite, and the chats.
class DeltaChatPanel extends StatefulWidget {
  const DeltaChatPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<DeltaChatPanel> createState() => _DeltaChatPanelState();
}

class _DeltaChatPanelState extends State<DeltaChatPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final email = controller.emailCarrierConfig;
        final on = controller.deltaChatEnabled;
        final link = controller.deltaInviteLink;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              key: const ValueKey('delta-chat-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10nOf(context).uiDeltaChat8BDA67),
              subtitle: Text(
                email == null
                    ? l10nOf(context).uiChatWithDeltaChatUsers3B8607
                    : l10nOf(
                        context,
                      ).uiChatWithDeltaChatUsersABD3F5((email.mail).toString()),
              ),
              value: on,
              onChanged: _busy || email == null
                  ? null
                  : (value) => _run(
                      value
                          ? controller.enableDeltaChat
                          : controller.disableDeltaChat,
                    ),
            ),
            if (on && link != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10nOf(context).uiYourDeltaChatInviteEE073F),
                subtitle: Text(l10nOf(context).uiShowTheQRCodeTo0769AD),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: l10nOf(context).uiShowQRCode2DF2DD,
                      icon: const Icon(Icons.qr_code),
                      onPressed: () => showDeltaInviteQr(
                        context,
                        'Your Delta Chat invite',
                        link,
                      ),
                    ),
                    IconButton(
                      tooltip: l10nOf(context).uiCopyLink2F84EE,
                      icon: const Icon(Icons.copy),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: link)),
                    ),
                  ],
                ),
              ),
              ListTile(
                key: const ValueKey('delta-chats'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.forum_outlined),
                title: Text(l10nOf(context).uiDeltaChatChats8EBCBC),
                trailing: controller.deltaChats.totalUnread == 0
                    ? const Icon(Icons.chevron_right)
                    : Badge(
                        label: Text("${(controller.deltaChats.totalUnread)}"),
                      ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DeltaChatsScreen(controller: controller),
                  ),
                ),
              ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        );
      },
    );
  }
}

/// Shows [link] as a QR code to scan with Delta Chat.
void showDeltaInviteQr(BuildContext context, String title, String link) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 280,
        height: 280,
        child: QrImageView(
          data: link,
          backgroundColor: Colors.white,
          padding: const EdgeInsets.all(12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: link)),
          child: Text(l10nOf(context).uiCopyLink2F84EE),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).uiDoneE9B450),
        ),
      ],
    ),
  );
}

/// A Delta Chat chat's title: the group's name, or the person's.
String deltaChatTitle(MessengerController controller, DeltaChat chat) =>
    chat.isGroup
    ? (chat.name ?? 'Group')
    : (chat.name ?? controller.deltaName(chat.key));

/// All Delta Chat chats, joining by invite and new groups.
class DeltaChatsScreen extends StatelessWidget {
  const DeltaChatsScreen({super.key, required this.controller});

  final MessengerController controller;

  Future<void> _join(BuildContext context) async {
    final field = TextEditingController();
    final invite = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiJoinWithAnInviteC76024),
        content: TextField(
          key: const ValueKey('delta-invite-field'),
          controller: field,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'https://i.delta.chat/#…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: Text(l10nOf(context).uiJoinE0D731),
          ),
        ],
      ),
    );
    field.dispose();
    if (invite == null || invite.trim().isEmpty || !context.mounted) return;
    try {
      final key = await controller.joinDeltaChat(invite);
      if (context.mounted) openDeltaChat(context, controller, key);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${(error)}")));
      }
    }
  }

  Future<void> _newGroup(BuildContext context) async {
    final peers = [
      for (final peer in controller.deltaChats.peers.values)
        if (peer.key != null) peer,
    ]..sort((a, b) => (a.name ?? a.addr).compareTo(b.name ?? b.addr));
    final result = await showDialog<(String, List<String>)>(
      context: context,
      builder: (context) => _NewGroupDialog(peers: peers),
    );
    if (result == null || !context.mounted) return;
    try {
      final key = await controller.createDeltaGroup(result.$1, result.$2);
      if (context.mounted) openDeltaChat(context, controller, key);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${(error)}")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final chats = controller.deltaChats.chats.values.toList()
          ..sort(
            (a, b) => (b.messages.lastOrNull?.at ?? DateTime(0)).compareTo(
              a.messages.lastOrNull?.at ?? DateTime(0),
            ),
          );
        return Scaffold(
          appBar: AppBar(
            title: Text(l10nOf(context).uiDeltaChat8BDA67),
            actions: [
              IconButton(
                tooltip: l10nOf(context).uiNewGroupF9850C,
                icon: const Icon(Icons.group_add_outlined),
                onPressed: () => _newGroup(context),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: l10nOf(context).uiJoinWithAnInviteC76024,
            onPressed: () => _join(context),
            child: const Icon(Icons.qr_code_scanner),
          ),
          body: chats.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      l10nOf(context).uiNoDeltaChatChatsYetF4C538,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final chat in chats)
                      ListTile(
                        leading: deltaChatAvatar(controller, chat),
                        title: Text(deltaChatTitle(controller, chat)),
                        subtitle: Text(
                          chat.kept
                              ? (chat.messages.lastOrNull?.preview(
                                      DateTime.now(),
                                    ) ??
                                    '')
                              : 'Request: ${chat.messages.lastOrNull?.preview(DateTime.now()) ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: chat.unread == 0
                            ? null
                            : Badge(label: Text("${(chat.unread)}")),
                        onTap: () =>
                            openDeltaChat(context, controller, chat.key),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog({required this.peers});

  final List<DeltaPeer> peers;

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  final _name = TextEditingController();
  final _chosen = <String>{};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(l10nOf(context).uiNewDeltaChatGroup7D5142),
      content: SizedBox(
        width: 360,
        child: ListView(
          shrinkWrap: true,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: l10nOf(context).uiGroupNameEBB7E1,
              ),
            ),
            if (widget.peers.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(l10nOf(context).uiNobodyToAddYetStart0983BB),
              ),
            for (final peer in widget.peers)
              CheckboxListTile(
                value: _chosen.contains(peer.fingerprint),
                title: Text(peer.name ?? peer.addr),
                subtitle: Text(
                  peer.verified ? l10nOf(context).uiVerifiedEC734B : peer.addr,
                ),
                onChanged: (value) => setState(
                  () => value == true
                      ? _chosen.add(peer.fingerprint)
                      : _chosen.remove(peer.fingerprint),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            _name.text.trim().isEmpty ? 'Group' : _name.text.trim(),
            _chosen.toList(),
          )),
          child: Text(l10nOf(context).actionCreate),
        ),
      ],
    );
  }
}

void openDeltaChat(
  BuildContext context,
  MessengerController controller,
  String key,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _DeltaChatScreen(controller: controller, chatKey: key),
    ),
  );
}

class _DeltaChatScreen extends StatefulWidget {
  const _DeltaChatScreen({required this.controller, required this.chatKey});

  final MessengerController controller;
  final String chatKey;

  @override
  State<_DeltaChatScreen> createState() => _DeltaChatScreenState();
}

class _DeltaChatScreenState extends State<_DeltaChatScreen> {
  final _composer = TextEditingController();
  String? _error;
  bool _sending = false;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _expiryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    widget.controller.addListener(_markRead);
    _markRead();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    unawaited(
      interruptDeltaVoiceOnClose(
        widget.controller.voiceMessageService,
        widget.chatKey,
      ).catchError((_) {}),
    );
    widget.controller.removeListener(_markRead);
    _composer.dispose();
    super.dispose();
  }

  void _markRead() {
    final chat = widget.controller.deltaChats.chats[widget.chatKey];
    if (chat == null ||
        (chat.unread == 0 &&
            !chat.messages.any((message) => message.wantsReceipt))) {
      return;
    }
    unawaited(
      widget.controller.markDeltaChatRead(widget.chatKey).catchError((_) {}),
    );
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.controller.sendDeltaMessage(widget.chatKey, text);
      _composer.clear();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${(error)}")));
      }
    }
  }

  Future<void> _members(DeltaChat chat) async {
    final controller = widget.controller;
    await showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final current = controller.deltaChats.chats[chat.key] ?? chat;
          final others = [
            for (final peer in controller.deltaChats.peers.values)
              if (peer.key != null &&
                  !current.members.contains(peer.fingerprint))
                peer,
          ];
          return AlertDialog(
            title: Text(
              l10nOf(
                context,
              ).uiValueMembersCEF563((current.members.length + 1)),
            ),
            content: SizedBox(
              width: 360,
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(title: Text(l10nOf(context).uiYou905CB3)),
                  for (final member in current.members)
                    ListTile(
                      title: Text(controller.deltaName(member)),
                      subtitle: Text(
                        controller.deltaChats.peers[member]?.verified ?? false
                            ? l10nOf(context).uiVerifiedEC734B
                            : controller.deltaChats.peers[member]?.addr ?? '',
                      ),
                      trailing: current.left
                          ? null
                          : IconButton(
                              tooltip: l10nOf(context).uiRemoveE96390,
                              icon: const Icon(Icons.person_remove_outlined),
                              onPressed: () => _act(
                                () => controller.removeDeltaGroupMember(
                                  chat.key,
                                  member,
                                ),
                              ),
                            ),
                    ),
                  if (!current.left)
                    for (final peer in others)
                      ListTile(
                        leading: const Icon(Icons.person_add_outlined),
                        title: Text(
                          l10nOf(context).uiAddValueF546E5(
                            (peer.name ?? peer.addr).toString(),
                          ),
                        ),
                        onTap: () => _act(
                          () => controller.addDeltaGroupMember(
                            chat.key,
                            peer.fingerprint,
                          ),
                        ),
                      ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10nOf(context).uiDoneE9B450),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final chat = controller.deltaChats.chats[widget.chatKey];
        if (chat == null) {
          return Scaffold(
            body: Center(child: Text(l10nOf(context).uiChatDeleted73DC61)),
          );
        }
        final peer = chat.isGroup
            ? null
            : controller.deltaChats.peers[chat.key];
        final waiting =
            controller.deltaChats.joins.any(
              (join) =>
                  join.fingerprint == chat.key ||
                  (chat.groupId != null && join.groupId == chat.groupId),
            ) ||
            (peer != null && peer.key == null);
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                deltaChatAvatar(controller, chat, radius: 16),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    deltaChatTitle(controller, chat),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (peer?.verified ?? false)
                  Padding(
                    padding: EdgeInsetsDirectional.only(start: 6),
                    child: Tooltip(
                      message: l10nOf(context).uiVerifiedWithAnInviteBD826F,
                      child: Icon(Icons.verified_user, size: 18),
                    ),
                  ),
              ],
            ),
            actions: [
              if (chat.isGroup && !chat.left) ...[
                IconButton(
                  tooltip: l10nOf(context).uiMembers1CB449,
                  icon: const Icon(Icons.group_outlined),
                  onPressed: () => _members(chat),
                ),
                IconButton(
                  tooltip: l10nOf(context).uiGroupInviteD64669,
                  icon: const Icon(Icons.qr_code),
                  onPressed: () => _act(() async {
                    final link = await controller.deltaGroupInviteLink(
                      chat.key,
                    );
                    if (context.mounted) {
                      showDeltaInviteQr(
                        context,
                        'Invite to ${deltaChatTitle(controller, chat)}',
                        link,
                      );
                    }
                  }),
                ),
              ],
              PopupMenuButton<String>(
                onSelected: (action) => _act(() async {
                  switch (action) {
                    case 'leave':
                      await controller.leaveDeltaGroup(chat.key);
                    case 'delete':
                      await controller.deleteDeltaChat(chat.key);
                      if (context.mounted) Navigator.of(context).pop();
                  }
                }),
                itemBuilder: (context) => [
                  if (chat.isGroup && !chat.left)
                    PopupMenuItem(
                      value: 'leave',
                      child: Text(l10nOf(context).uiLeaveGroup925789),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(l10nOf(context).uiDeleteChatDB9121),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  waiting
                      ? l10nOf(context).uiWaitingForTheInviteTo1C712D
                      : chat.kept
                      ? l10nOf(context).uiEncryptedWithOpenPGPDeltaChat9C6326
                      : l10nOf(context).uiARequestFromSomeoneYouAE0967,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: chat.messages.length,
                  itemBuilder: (context, index) {
                    final message =
                        chat.messages[chat.messages.length - 1 - index];
                    if (message.info) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Center(
                          child: Text(
                            message.text,
                            style: theme.textTheme.labelMedium,
                          ),
                        ),
                      );
                    }
                    return Align(
                      alignment: message.outgoing
                          ? AlignmentDirectional.centerEnd
                          : AlignmentDirectional.centerStart,
                      child: Card(
                        color: message.outgoing
                            ? theme.colorScheme.primaryContainer
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (chat.isGroup && !message.outgoing)
                                Text(
                                  controller.deltaName(message.author),
                                  style: theme.textTheme.labelMedium,
                                ),
                              if (message.deleted)
                                Text(l10nOf(context).uiMessageDeleted3271A7)
                              else ...[
                                if (message.text.isNotEmpty) Text(message.text),
                                if (message.pending != null)
                                  Text(
                                    '${message.pending!.name}, ${(message.pending!.size / (1024 * 1024)).toStringAsFixed(1)} MB, '
                                    '${message.pendingExpired(DateTime.now()) ? 'not received' : 'downloading…'}',
                                  ),
                                for (final attachment in message.attachments)
                                  buildDeltaAttachment(
                                    context,
                                    controller,
                                    attachment,
                                    message.outgoing,
                                  ),
                                if (message.reactions.values.any(
                                  (v) => v.isNotEmpty,
                                ))
                                  Wrap(
                                    spacing: 4,
                                    children: [
                                      for (final emoji
                                          in message.reactions.values
                                              .where((v) => v.isNotEmpty)
                                              .toSet())
                                        Chip(
                                          label: Text(
                                            '$emoji ${message.reactions.values.where((v) => v == emoji).length}',
                                          ),
                                        ),
                                    ],
                                  ),
                                if (!chat.left)
                                  DeltaMessageMenu(
                                    controller: controller,
                                    chat: chat,
                                    message: message,
                                    act: _act,
                                  ),
                              ],
                              Text(
                                [
                                  TimeOfDay.fromDateTime(
                                    message.at.toLocal(),
                                  ).format(context),
                                  if (message.editedAt != null) 'edited',
                                  if (message.outgoing)
                                    switch (message.state) {
                                      DeltaMessageState.read => l10nOf(
                                        context,
                                      ).uiReadA7AFDD,
                                      DeltaMessageState.failed => l10nOf(
                                        context,
                                      ).uiNotSentBE2B9D,
                                      DeltaMessageState.sent => l10nOf(
                                        context,
                                      ).uiSent27E770,
                                    },
                                ].join(' · '),
                                style: theme.textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      PopupMenuButton<bool>(
                        tooltip: l10nOf(context).deltaAttach,
                        enabled: !chat.left && !_sending,
                        icon: const Icon(Icons.attach_file),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: false,
                            child: Text('File'),
                          ),
                          const PopupMenuItem(
                            value: true,
                            child: Text('Photo or video'),
                          ),
                        ],
                        onSelected: (photos) => _act(() async {
                          setState(() => _sending = true);
                          try {
                            await pickDeltaFiles(
                              context,
                              controller,
                              chat.key,
                              photos: photos,
                              caption: _composer.text,
                            );
                          } finally {
                            if (mounted) setState(() => _sending = false);
                          }
                        }),
                      ),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('delta-composer'),
                          controller: _composer,
                          enabled: !chat.left,
                          minLines: 1,
                          maxLines: 4,
                          decoration: InputDecoration(
                            hintText: chat.left
                                ? l10nOf(context).uiYouAreNotInThisCF5BD5
                                : l10nOf(context).uiMessage68F414,
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      DeltaVoiceComposer(
                        controller: controller,
                        chatKey: chat.key,
                        enabled: !chat.left && !_sending,
                        act: _act,
                      ),
                      IconButton(
                        tooltip: l10nOf(context).composerSend,
                        icon: const Icon(Icons.send),
                        onPressed: _sending || chat.left ? null : _send,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
