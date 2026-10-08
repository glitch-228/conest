import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../messenger_controller.dart';
import '../nostr_chats.dart';

/// Nostr private messages (NIP-17) in Settings → Connectivity: on or off,
/// this account's npub, and new chats.
class NostrDirectPanel extends StatefulWidget {
  const NostrDirectPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<NostrDirectPanel> createState() => _NostrDirectPanelState();
}

class _NostrDirectPanelState extends State<NostrDirectPanel> {
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
        final on = controller.nostrDirectConfig != null;
        final npub = controller.nostrNpub;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              key: const ValueKey('nostr-direct-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Nostr private messages'),
              subtitle: const Text(
                'Chat with anyone on Nostr (0xchat, Amethyst, Damus and other '
                'apps that use NIP-17), one to one or in small groups. A '
                'Nostr account of its own, never linked to your Conest '
                'contacts. End-to-end encrypted, but without forward '
                'secrecy.',
              ),
              value: on,
              onChanged: _busy
                  ? null
                  : (value) => _run(
                      value
                          ? controller.enableNostrDirect
                          : controller.disableNostrDirect,
                    ),
            ),
            if (on && npub != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Your Nostr address'),
                subtitle: SelectableText(npub, maxLines: 2),
                trailing: IconButton(
                  tooltip: 'Copy (with your relays)',
                  icon: const Icon(Icons.copy),
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: controller.nostrProfile ?? npub),
                  ),
                ),
              ),
              ListTile(
                key: const ValueKey('nostr-chats'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.forum_outlined),
                title: const Text('Nostr chats'),
                trailing: controller.nostrChats.totalUnread == 0
                    ? const Icon(Icons.chevron_right)
                    : Badge(
                        label: Text('${controller.nostrChats.totalUnread}'),
                      ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NostrChatsScreen(controller: controller),
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

/// All Nostr chats, and a button for a new one.
class NostrChatsScreen extends StatelessWidget {
  const NostrChatsScreen({super.key, required this.controller});

  final MessengerController controller;

  Future<void> _newChat(BuildContext context) async {
    final field = TextEditingController();
    final profiles = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Nostr chat'),
        content: TextField(
          key: const ValueKey('nostr-new-chat-field'),
          controller: field,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'npub1… (several for a group)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    field.dispose();
    if (profiles == null || !context.mounted) return;
    try {
      final key = await controller.startNostrChat(profiles);
      if (context.mounted) openNostrChat(context, controller, key);
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
        final chats = controller.nostrChats.chats.values.toList()
          ..sort(
            (a, b) => (b.messages.lastOrNull?.at ?? DateTime(0)).compareTo(
              a.messages.lastOrNull?.at ?? DateTime(0),
            ),
          );
        return Scaffold(
          appBar: AppBar(title: const Text('Nostr chats')),
          floatingActionButton: FloatingActionButton(
            tooltip: 'New chat',
            onPressed: () => _newChat(context),
            child: const Icon(Icons.edit_outlined),
          ),
          body: chats.isEmpty
              ? const Center(child: Text('No Nostr chats yet'))
              : ListView(
                  children: [
                    for (final chat in chats)
                      ListTile(
                        leading: Icon(
                          chat.isGroup ? Icons.group_outlined : Icons.person,
                        ),
                        title: Text(nostrChatTitle(controller, chat)),
                        subtitle: Text(
                          chat.messages.lastOrNull?.text ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: chat.unread == 0
                            ? null
                            : Badge(label: Text('${chat.unread}')),
                        onTap: () =>
                            openNostrChat(context, controller, chat.key),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

/// A Nostr chat's title: its subject, or the names of its people.
String nostrChatTitle(MessengerController controller, NostrChat chat) =>
    chat.subject ?? chat.people.map(controller.nostrName).join(', ');

void openNostrChat(
  BuildContext context,
  MessengerController controller,
  String key,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _NostrChatScreen(controller: controller, chatKey: key),
    ),
  );
}

class _NostrChatScreen extends StatefulWidget {
  const _NostrChatScreen({required this.controller, required this.chatKey});

  final MessengerController controller;
  final String chatKey;

  @override
  State<_NostrChatScreen> createState() => _NostrChatScreenState();
}

class _NostrChatScreenState extends State<_NostrChatScreen> {
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
    final chat = widget.controller.nostrChats.chats[widget.chatKey];
    if (chat == null || chat.unread == 0) return;
    unawaited(
      widget.controller.markNostrChatRead(widget.chatKey).catchError((_) {}),
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
      await widget.controller.sendNostrMessage(widget.chatKey, text);
      _composer.clear();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final chat = controller.nostrChats.chats[widget.chatKey];
        if (chat == null) {
          return const Scaffold(body: Center(child: Text('Chat deleted')));
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(nostrChatTitle(controller, chat)),
            actions: [
              IconButton(
                tooltip: 'Delete chat',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await controller.deleteNostrChat(widget.chatKey);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
          body: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Encrypted on Nostr (NIP-17); relays see neither who wrote '
                  'nor when. No forward secrecy.',
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
                                  controller.nostrName(message.author),
                                  style: theme.textTheme.labelMedium,
                                ),
                              Text(message.text),
                              Text(
                                TimeOfDay.fromDateTime(
                                  message.at.toLocal(),
                                ).format(context),
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
                          key: const ValueKey('nostr-composer'),
                          controller: _composer,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: 'Message',
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Send',
                        icon: const Icon(Icons.send),
                        onPressed: _sending ? null : _send,
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
