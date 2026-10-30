import '../app_locales.dart';
import 'package:flutter/material.dart';

import '../bitchat_chats.dart';
import '../messenger_controller.dart';
import 'composer_keys.dart';
import 'link_cleaning.dart';
import 'linked_text.dart';

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
        final nearbyById = {for (final peer in nearby) peer.peerId: peer};
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
        String name(String peer) =>
            nearbyById[peer]?.nickname ??
            chats.nicknameOf(peer) ??
            peer.substring(0, 8);
        return Scaffold(
          appBar: AppBar(title: Text(l10nOf(context).uiBitchatNearbyD0C416)),
          body: ListView(
            children: [
              if (!controller.bitchatReachable)
                ListTile(
                  leading: Icon(Icons.visibility_off_outlined),
                  title: Text(l10nOf(context).uiYouAreHidden56DCC1),
                  subtitle: Text(l10nOf(context).uiYouReadTheMeshChatAEACC5),
                ),
              ListTile(
                key: const ValueKey('bitchat-mesh-chat'),
                leading: const Icon(Icons.cell_tower),
                title: Text(l10nOf(context).uiMeshChat7BF668),
                subtitle: Text(
                  chats.mesh.isEmpty
                      ? l10nOf(context).uiEveryoneNearbyOverBluetooth7B8D63
                      : chats.mesh.last.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _Unread(chats.unread[BitchatChats.meshKey] ?? 0),
                onTap: () => _open(context, BitchatChats.meshKey, 'Mesh chat'),
              ),
              const Divider(),
              if (peers.isEmpty)
                ListTile(
                  title: Text(l10nOf(context).uiNoBitchatUsersNearbyYetD30471),
                  subtitle: Text(
                    l10nOf(context).uiPhonesInBluetoothRangeThatDCCC0D,
                  ),
                ),
              for (final peer in peers)
                ListTile(
                  leading: Icon(
                    nearbyById.containsKey(peer)
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                  ),
                  title: Text(name(peer)),
                  subtitle: Text(
                    [
                      ?chats.direct[peer]?.last.text,
                      if (nearbyById[peer] case final nearbyPeer?)
                        l10nOf(context).bitchatLastHeard(
                          TimeOfDay.fromDateTime(
                            nearbyPeer.lastSeen.toLocal(),
                          ).format(context),
                        ),
                    ].join('\n'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Unread(chats.unread[peer] ?? 0),
                      if (nearbyById.containsKey(peer))
                        TextButton(
                          key: ValueKey('bitchat-message-$peer'),
                          onPressed: () => _message(context, peer, name(peer)),
                          child: Text(l10nOf(context).uiMessage68F414),
                        ),
                    ],
                  ),
                  onTap: () => chats.direct.containsKey(peer)
                      ? _open(context, peer, name(peer))
                      : _message(context, peer, name(peer)),
                ),
            ],
          ),
        );
      },
    );
  }

  void _open(BuildContext context, String key, String title) =>
      openBitchatChat(context, controller, key, title);

  void _message(BuildContext context, String key, String title) =>
      messageBitchatPeer(context, controller, key, title);
}

/// Asks before becoming visible to start messaging a nearby bitchat peer.
Future<void> messageBitchatPeer(
  BuildContext context,
  MessengerController controller,
  String chatKey,
  String title,
) async {
  if (!controller.bitchatReachable) {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiReachableByBitchatUsers568021),
        content: Text(
          l10nOf(
            context,
          ).uiBitchatUsersNearbySeeYou1B54FC(controller.bitchatNickname),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10nOf(context).actionContinue),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    try {
      await controller.setBitchatReachable(true);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
      return;
    }
    if (!context.mounted || !controller.bitchatReachable) return;
  }
  if (!context.mounted) return;
  openBitchatChat(context, controller, chatKey, title);
}

/// Opens one bitchat chat, including saved history while hidden.
/// [chatKey] is [BitchatChats.meshKey] or a peer id.
void openBitchatChat(
  BuildContext context,
  MessengerController controller,
  String chatKey,
  String title,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _BitchatChatScreen(
        controller: controller,
        chatKey: chatKey,
        title: title,
      ),
    ),
  );
}

class _Unread extends StatelessWidget {
  const _Unread(this.count);

  final int count;

  @override
  Widget build(BuildContext context) =>
      count == 0 ? const SizedBox.shrink() : Badge(label: Text("${(count)}"));
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
    finishComposerLinks(_composer);
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
              tooltip: l10nOf(context).uiDeleteChatDB9121,
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
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                l10nOf(context).uiEveryoneInBluetoothRangeReadsA7628A,
              ),
            )
          else
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(l10nOf(context).uiEncryptedBetweenTheTwoPhones3871C4),
            ),
          if (!_mesh && _earlierIdentity)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                l10nOf(context).uiThisChatWasWithAn0507F9,
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
                              if (_mesh && !message.outgoing)
                                // The id's start tells people with the same
                                // name apart, as bitchat shows it.
                                Text(
                                  "${(message.nickname)}#${(message.peerId.substring(0, 4))}",
                                  style: theme.textTheme.labelMedium,
                                ),
                              LinkedText(
                                message.text,
                                openUrl: widget.controller.openExternalUrl,
                              ),
                              Text(
                                [
                                  TimeOfDay.fromDateTime(
                                    message.at.toLocal(),
                                  ).format(context),
                                  if (message.outgoing && !_mesh)
                                    switch (message.state) {
                                      BitchatMessageState.sent => l10nOf(
                                        context,
                                      ).uiSent27E770,
                                      BitchatMessageState.delivered => l10nOf(
                                        context,
                                      ).uiDeliveredF81891,
                                      BitchatMessageState.read => l10nOf(
                                        context,
                                      ).uiReadA7AFDD,
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
                    child: ComposerKeys(
                      controller: _composer,
                      onSend: _send,
                      child: TextField(
                        key: const ValueKey('bitchat-composer'),
                        controller: _composer,
                        enabled: widget.controller.bitchatReachable,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: widget.controller.bitchatReachable
                              ? l10nOf(context).uiMessage68F414
                              : l10nOf(context).uiHiddenTurnOnReachableBy0103C9,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10nOf(context).composerSend,
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
