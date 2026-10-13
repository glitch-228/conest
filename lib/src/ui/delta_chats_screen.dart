import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../delta_chats.dart';
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
              title: const Text('Delta Chat'),
              subtitle: Text(
                email == null
                    ? 'Chat with Delta Chat users through your email account. '
                          'Set up Email above first.'
                    : 'Chat with Delta Chat users as ${email.mail}, one to one '
                          'and in groups. End-to-end encrypted (OpenPGP, '
                          'without forward secrecy); the mail servers see who '
                          'writes to whom and when.',
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
                title: const Text('Your Delta Chat invite'),
                subtitle: const Text(
                  'Show the QR code to a Delta Chat user, or send the link. '
                  'Whoever has it can start a verified chat with you.',
                ),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: 'Show QR code',
                      icon: const Icon(Icons.qr_code),
                      onPressed: () => showDeltaInviteQr(
                        context,
                        'Your Delta Chat invite',
                        link,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy link',
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
                title: const Text('Delta Chat chats'),
                trailing: controller.deltaChats.totalUnread == 0
                    ? const Icon(Icons.chevron_right)
                    : Badge(
                        label: Text('${controller.deltaChats.totalUnread}'),
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
          child: const Text('Copy link'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
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
        title: const Text('Join with an invite'),
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Join'),
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
        ).showSnackBar(SnackBar(content: Text('$error')));
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
        ).showSnackBar(SnackBar(content: Text('$error')));
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
            title: const Text('Delta Chat'),
            actions: [
              IconButton(
                tooltip: 'New group',
                icon: const Icon(Icons.group_add_outlined),
                onPressed: () => _newGroup(context),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: 'Join with an invite',
            onPressed: () => _join(context),
            child: const Icon(Icons.qr_code_scanner),
          ),
          body: chats.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No Delta Chat chats yet. Share your invite, or join '
                      'with someone\'s.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final chat in chats)
                      ListTile(
                        leading: Icon(
                          chat.isGroup ? Icons.group_outlined : Icons.person,
                        ),
                        title: Text(deltaChatTitle(controller, chat)),
                        subtitle: Text(
                          chat.kept
                              ? (chat.messages.lastOrNull?.text ?? '')
                              : 'Request: ${chat.messages.lastOrNull?.text ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: chat.unread == 0
                            ? null
                            : Badge(label: Text('${chat.unread}')),
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
      title: const Text('New Delta Chat group'),
      content: SizedBox(
        width: 360,
        child: ListView(
          shrinkWrap: true,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Group name'),
            ),
            if (widget.peers.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Nobody to add yet: start a chat first. You can share the '
                  'group\'s invite once it exists.',
                ),
              ),
            for (final peer in widget.peers)
              CheckboxListTile(
                value: _chosen.contains(peer.fingerprint),
                title: Text(peer.name ?? peer.addr),
                subtitle: Text(peer.verified ? 'verified' : peer.addr),
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            _name.text.trim().isEmpty ? 'Group' : _name.text.trim(),
            _chosen.toList(),
          )),
          child: const Text('Create'),
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

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_markRead);
    _markRead();
  }

  @override
  void dispose() {
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
        ).showSnackBar(SnackBar(content: Text('$error')));
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
            title: Text('${current.members.length + 1} members'),
            content: SizedBox(
              width: 360,
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('You')),
                  for (final member in current.members)
                    ListTile(
                      title: Text(controller.deltaName(member)),
                      subtitle: Text(
                        controller.deltaChats.peers[member]?.verified ?? false
                            ? 'verified'
                            : controller.deltaChats.peers[member]?.addr ?? '',
                      ),
                      trailing: current.left
                          ? null
                          : IconButton(
                              tooltip: 'Remove',
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
                        title: Text('Add ${peer.name ?? peer.addr}'),
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
                child: const Text('Done'),
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
          return const Scaffold(body: Center(child: Text('Chat deleted')));
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
                Flexible(
                  child: Text(
                    deltaChatTitle(controller, chat),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (peer?.verified ?? false)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: 'Verified with an invite',
                      child: Icon(Icons.verified_user, size: 18),
                    ),
                  ),
              ],
            ),
            actions: [
              if (chat.isGroup && !chat.left) ...[
                IconButton(
                  tooltip: 'Members',
                  icon: const Icon(Icons.group_outlined),
                  onPressed: () => _members(chat),
                ),
                IconButton(
                  tooltip: 'Group invite',
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
                    const PopupMenuItem(
                      value: 'leave',
                      child: Text('Leave group'),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete chat'),
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
                      ? 'Waiting for the invite to be answered; this can take '
                            'a minute.'
                      : chat.kept
                      ? 'Encrypted with OpenPGP (Delta Chat), without forward '
                            'secrecy. The mail servers see who writes to whom '
                            'and when.'
                      : 'A request from someone you have not chatted with. '
                            'Replying accepts it.',
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
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
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
                              Text(message.text),
                              Text(
                                [
                                  TimeOfDay.fromDateTime(
                                    message.at.toLocal(),
                                  ).format(context),
                                  if (message.outgoing)
                                    switch (message.state) {
                                      DeltaMessageState.read => 'read',
                                      DeltaMessageState.failed => 'not sent',
                                      DeltaMessageState.sent => 'sent',
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
                      Expanded(
                        child: TextField(
                          key: const ValueKey('delta-composer'),
                          controller: _composer,
                          enabled: !chat.left,
                          minLines: 1,
                          maxLines: 4,
                          decoration: InputDecoration(
                            hintText: chat.left
                                ? 'You are not in this group'
                                : 'Message',
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Send',
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
