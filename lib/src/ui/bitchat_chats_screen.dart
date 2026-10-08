import 'package:flutter/material.dart';

import '../bitchat_chats.dart';
import '../messenger_controller.dart';

/// Chats with bitchat users nearby: the mesh chat everyone in range shares
/// and private chats.
class BitchatChatsScreen extends StatelessWidget {
  const BitchatChatsScreen({super.key, required this.controller});

  final MessengerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final chats = controller.bitchatChats;
        final nearby = controller.bitchatNearbyPeers;
        final peers =
            <String>{
              ...chats.direct.keys,
              for (final peer in nearby) peer.peerId,
            }.toList()..sort((a, b) {
              DateTime last(String peer) =>
                  chats.direct[peer]?.last.at ??
                  DateTime.fromMillisecondsSinceEpoch(0);
              return last(b).compareTo(last(a));
            });
        final nearbyIds = {for (final peer in nearby) peer.peerId};
        String name(String peer) =>
            nearby
                .where((candidate) => candidate.peerId == peer)
                .firstOrNull
                ?.nickname ??
            chats.nicknameOf(peer) ??
            peer.substring(0, 8);
        return Scaffold(
          appBar: AppBar(title: const Text('bitchat nearby')),
          body: ListView(
            children: [
              if (!controller.bitchatReachable)
                const ListTile(
                  leading: Icon(Icons.visibility_off_outlined),
                  title: Text('You are hidden'),
                  subtitle: Text(
                    'You read the mesh chat, but bitchat users cannot see '
                    'you or write to you. Turn on "Reachable by bitchat '
                    'users" in Settings → Connectivity to write.',
                  ),
                ),
              ListTile(
                key: const ValueKey('bitchat-mesh-chat'),
                leading: const Icon(Icons.cell_tower),
                title: const Text('Mesh chat'),
                subtitle: Text(
                  chats.mesh.isEmpty
                      ? 'Everyone nearby, over Bluetooth'
                      : chats.mesh.last.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _Unread(chats.unread[BitchatChats.meshKey] ?? 0),
                onTap: () => _open(context, BitchatChats.meshKey, 'Mesh chat'),
              ),
              const Divider(),
              if (peers.isEmpty)
                const ListTile(
                  title: Text('No bitchat users nearby yet'),
                  subtitle: Text(
                    'Phones in Bluetooth range that announce themselves '
                    'show up here.',
                  ),
                ),
              for (final peer in peers)
                ListTile(
                  leading: Icon(
                    nearbyIds.contains(peer)
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                  ),
                  title: Text(name(peer)),
                  subtitle: Text(
                    chats.direct[peer]?.last.text ??
                        (nearbyIds.contains(peer) ? 'Nearby' : ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _Unread(chats.unread[peer] ?? 0),
                  onTap: () => _open(context, peer, name(peer)),
                ),
            ],
          ),
        );
      },
    );
  }

  void _open(BuildContext context, String key, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _BitchatChatScreen(
          controller: controller,
          chatKey: key,
          title: title,
        ),
      ),
    );
  }
}

class _Unread extends StatelessWidget {
  const _Unread(this.count);

  final int count;

  @override
  Widget build(BuildContext context) =>
      count == 0 ? const SizedBox.shrink() : Badge(label: Text('$count'));
}

class _BitchatChatScreen extends StatefulWidget {
  const _BitchatChatScreen({
    required this.controller,
    required this.chatKey,
    required this.title,
  });

  final MessengerController controller;

  /// [BitchatChats.meshKey] or a peer id.
  final String chatKey;
  final String title;

  @override
  State<_BitchatChatScreen> createState() => _BitchatChatScreenState();
}

class _BitchatChatScreenState extends State<_BitchatChatScreen> {
  final _composer = TextEditingController();
  String? _error;

  bool get _mesh => widget.chatKey == BitchatChats.meshKey;

  /// The chat's last message went through an identity no longer in use.
  bool get _earlierIdentity {
    final last = widget.controller.bitchatChats.direct[widget.chatKey]?.last;
    return last != null &&
        last.via != null &&
        last.via != widget.controller.bitchatPeerId;
  }

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

  /// What arrives while the chat is open counts as read.
  void _markRead() {
    if ((widget.controller.bitchatChats.unread[widget.chatKey] ?? 0) == 0) {
      return;
    }
    widget.controller.markBitchatChatRead(widget.chatKey).catchError((_) {});
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    setState(() => _error = null);
    try {
      _mesh
          ? await widget.controller.sendBitchatMeshMessage(text)
          : await widget.controller.sendBitchatDirectMessage(
              widget.chatKey,
              text,
            );
      _composer.clear();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (!_mesh)
            IconButton(
              tooltip: 'Delete chat',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await widget.controller.deleteBitchatChat(widget.chatKey);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
        ],
      ),
      body: Column(
        children: [
          if (_mesh)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Everyone in Bluetooth range reads this chat, and anyone can '
                'relay it. Messages are signed, not encrypted.',
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Encrypted between the two phones (bitchat\'s Noise), with '
                'forward secrecy only while you are both nearby.',
              ),
            ),
          if (!_mesh && _earlierIdentity)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'This chat was with an earlier bitchat identity of yours. '
                'Writing now tells them your new one is the same person.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final chats = widget.controller.bitchatChats;
                final messages = _mesh
                    ? chats.mesh
                    : chats.direct[widget.chatKey] ??
                          const <BitchatChatMessage>[];
                return ListView.builder(
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
                              if (_mesh && !message.outgoing)
                                // The id's start tells people with the same
                                // name apart, as bitchat shows it.
                                Text(
                                  '${message.nickname}'
                                  '#${message.peerId.substring(0, 4)}',
                                  style: theme.textTheme.labelMedium,
                                ),
                              Text(message.text),
                              Text(
                                [
                                  TimeOfDay.fromDateTime(
                                    message.at.toLocal(),
                                  ).format(context),
                                  if (message.outgoing && !_mesh)
                                    switch (message.state) {
                                      BitchatMessageState.sent => 'sent',
                                      BitchatMessageState.delivered =>
                                        'delivered',
                                      BitchatMessageState.read => 'read',
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
                      key: const ValueKey('bitchat-composer'),
                      controller: _composer,
                      enabled: widget.controller.bitchatReachable,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: widget.controller.bitchatReachable
                            ? 'Message'
                            : 'Hidden: turn on "Reachable by bitchat users"',
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Send',
                    icon: const Icon(Icons.send),
                    onPressed: widget.controller.bitchatReachable
                        ? _send
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
