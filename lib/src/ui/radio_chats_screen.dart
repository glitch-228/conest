import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../messenger_controller.dart';
import '../radio_chats.dart';

/// What a radio's app chats need from the controller.
class RadioChatsAccess {
  const RadioChatsAccess({
    required this.network,
    required this.chats,
    required this.title,
    required this.send,
    required this.markRead,
    required this.delete,
    required this.start,
    required this.nodes,
    required this.canWrite,
    required this.channelNote,
    required this.directNote,
    this.refresh,
  });

  /// Reads the radio's node list again, before a new chat.
  final Future<void> Function()? refresh;

  /// "Meshtastic" or "MeshCore".
  final String network;
  final RadioChats Function() chats;
  final String Function(String key) title;
  final Future<void> Function(String key, String text) send;
  final Future<void> Function(String key) markRead;
  final Future<void> Function(String key) delete;
  final Future<String> Function(String node) start;

  /// Nodes to start a chat with, by address, with their names.
  final Map<String, String> Function() nodes;
  final bool Function() canWrite;

  /// What to say about how messages travel.
  final String channelNote;
  final String directNote;
}

/// The Meshtastic apps' chats, as the controller keeps them.
RadioChatsAccess meshtasticChatsAccess(MessengerController controller) =>
    RadioChatsAccess(
      network: 'Meshtastic',
      chats: () => controller.meshtasticChats,
      title: (key) => RadioChats.isChannel(key)
          ? (key == RadioChats.channel(0)
                ? 'Primary channel'
                : 'Channel ${key.substring(3)}')
          : controller.meshtasticNodeName(key.substring(3)),
      send: controller.sendMeshtasticMessage,
      markRead: controller.markMeshtasticChatRead,
      delete: controller.deleteMeshtasticChat,
      start: controller.startMeshtasticChat,
      nodes: () => controller.meshtasticNodes,
      canWrite: () => controller.meshtasticAppMessages,
      channelNote:
          'Everyone on this channel of the mesh reads it, encrypted only '
          'with the channel key. Anyone with that key can write here under '
          'any name.',
      directNote:
          'Between the two radios, not with Conest\'s keys. Messages marked '
          '"sender not verified" came under the channel key: anyone on the '
          'channel could have sent them.',
    );

/// The MeshCore apps' chats, as the controller keeps them.
RadioChatsAccess meshCoreChatsAccess(MessengerController controller) =>
    RadioChatsAccess(
      network: 'MeshCore',
      chats: () => controller.meshCoreChats,
      title: (key) => RadioChats.isChannel(key)
          ? (key == RadioChats.channel(0)
                ? 'Public channel'
                : 'Channel ${key.substring(3)}')
          : controller.meshCoreName(key.substring(3)),
      send: controller.sendMeshCoreMessage,
      markRead: controller.markMeshCoreChatRead,
      delete: controller.deleteMeshCoreChat,
      start: controller.startMeshCoreChat,
      nodes: () => controller.meshCoreNodes,
      refresh: controller.refreshMeshCoreContacts,
      canWrite: () => controller.meshCoreAppMessages,
      channelNote:
          'Everyone on this channel reads it, encrypted only with the '
          'channel key. Anyone with that key can write here under any name.',
      directNote:
          'Encrypted by MeshCore for this contact (weaker than Conest\'s '
          'own encryption).',
    );

/// A radio's app chats: channels and direct chats, and new chats.
class RadioChatsScreen extends StatelessWidget {
  const RadioChatsScreen({
    super.key,
    required this.controller,
    required this.access,
  });

  final MessengerController controller;
  final RadioChatsAccess access;

  Future<void> _newChat(BuildContext context) async {
    try {
      await access.refresh?.call();
    } catch (_) {
      // The list read before is still shown.
    }
    if (!context.mounted) return;
    final nodes = access.nodes();
    final picked = await showDialog<String>(
      context: context,
      builder: (context) {
        final field = TextEditingController();
        return AlertDialog(
          title: const Text('New chat'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                TextField(
                  controller: field,
                  decoration: const InputDecoration(hintText: 'Node address'),
                  onSubmitted: (value) => Navigator.of(context).pop(value),
                ),
                for (final MapEntry(key: node, value: name) in nodes.entries)
                  ListTile(
                    title: Text(name),
                    subtitle: Text(node),
                    onTap: () => Navigator.of(context).pop(node),
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
              onPressed: () => Navigator.of(context).pop(field.text),
              child: const Text('Start'),
            ),
          ],
        );
      },
    );
    if (picked == null || picked.trim().isEmpty || !context.mounted) return;
    try {
      final key = await access.start(picked);
      if (context.mounted) openRadioChat(context, controller, access, key);
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
        final chats = access.chats();
        final keys = {RadioChats.channel(0), ...chats.chats.keys}.toList()
          ..sort((a, b) {
            DateTime last(String key) =>
                chats.chats[key]?.lastOrNull?.at ?? DateTime(0);
            return last(b).compareTo(last(a));
          });
        return Scaffold(
          appBar: AppBar(title: Text('${access.network} chats')),
          floatingActionButton: access.canWrite()
              ? FloatingActionButton(
                  tooltip: 'New chat',
                  onPressed: () => _newChat(context),
                  child: const Icon(Icons.edit_outlined),
                )
              : null,
          body: ListView(
            children: [
              for (final key in keys)
                ListTile(
                  leading: Icon(
                    RadioChats.isChannel(key) ? Icons.cell_tower : Icons.person,
                  ),
                  title: Text(access.title(key)),
                  subtitle: Text(
                    chats.chats[key]?.lastOrNull?.text ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: (chats.unread[key] ?? 0) == 0
                      ? null
                      : Badge(label: Text('${chats.unread[key]}')),
                  onTap: () => openRadioChat(context, controller, access, key),
                ),
            ],
          ),
        );
      },
    );
  }
}

void openRadioChat(
  BuildContext context,
  MessengerController controller,
  RadioChatsAccess access,
  String key,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _RadioChatScreen(
        controller: controller,
        access: access,
        chatKey: key,
      ),
    ),
  );
}

class _RadioChatScreen extends StatefulWidget {
  const _RadioChatScreen({
    required this.controller,
    required this.access,
    required this.chatKey,
  });

  final MessengerController controller;
  final RadioChatsAccess access;
  final String chatKey;

  @override
  State<_RadioChatScreen> createState() => _RadioChatScreenState();
}

class _RadioChatScreenState extends State<_RadioChatScreen> {
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
    if ((widget.access.chats().unread[widget.chatKey] ?? 0) == 0) return;
    unawaited(widget.access.markRead(widget.chatKey).catchError((_) {}));
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.access.send(widget.chatKey, text);
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
    final channel = RadioChats.isChannel(widget.chatKey);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final messages =
            widget.access.chats().chats[widget.chatKey] ??
            const <RadioChatMessage>[];
        final canWrite = widget.access.canWrite();
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.access.title(widget.chatKey)),
            actions: [
              IconButton(
                tooltip: 'Delete chat',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await widget.access.delete(widget.chatKey);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  channel
                      ? widget.access.channelNote
                      : widget.access.directNote,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[messages.length - 1 - index];
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
                              if (channel && !message.outgoing)
                                Text(
                                  // The id shows who sent it when names
                                  // are alike (names are self-chosen).
                                  message.from.isEmpty
                                      ? message.name
                                      : '${message.name} '
                                            '(${message.from.substring(0, min(6, message.from.length))})',
                                  style: theme.textTheme.labelMedium,
                                ),
                              Text(message.text),
                              Text(
                                [
                                  TimeOfDay.fromDateTime(
                                    message.at.toLocal(),
                                  ).format(context),
                                  if (message.outgoing && !channel)
                                    switch (message.state) {
                                      RadioMessageState.delivered =>
                                        'delivered',
                                      RadioMessageState.failed =>
                                        'not delivered (their radio could '
                                            'not read it)',
                                      RadioMessageState.sent => 'sent',
                                    },
                                  if (!message.outgoing &&
                                      !channel &&
                                      !message.authentic)
                                    'sender not verified',
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
                          key: const ValueKey('radio-composer'),
                          controller: _composer,
                          enabled: canWrite,
                          decoration: InputDecoration(
                            hintText: canWrite
                                ? 'Message'
                                : 'Turn on app messages to write',
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Send',
                        icon: const Icon(Icons.send),
                        onPressed: canWrite && !_sending ? _send : null,
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
