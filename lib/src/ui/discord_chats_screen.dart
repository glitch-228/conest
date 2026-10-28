import 'dart:async';

import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../discord/discord_client.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';

String discordChannelTitle(DcChannel channel) => switch (channel.kind) {
  DcChannelKind.dm ||
  DcChannelKind.groupDm => channel.name.isEmpty ? '?' : channel.name,
  _ => '#${channel.name}',
};

void openDiscordChannel(
  BuildContext context,
  MessengerController controller,
  DcChannel channel,
) => unawaited(
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          DiscordChannelScreen(controller: controller, channel: channel),
    ),
  ),
);

/// Direct messages and servers; a server opens to its text channels.
class DiscordChatList extends StatefulWidget {
  const DiscordChatList({
    super.key,
    required this.controller,
    required this.client,
  });

  final MessengerController controller;
  final DiscordClient client;

  @override
  State<DiscordChatList> createState() => _DiscordChatListState();
}

class _DiscordChatListState extends State<DiscordChatList> {
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_changed);
  }

  @override
  void dispose() {
    widget.client.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final client = widget.client;
    if (client.dms.isEmpty && client.guilds.isEmpty) {
      return Center(child: Text(l10n.discordNoChats));
    }
    return ListView(
      children: [
        if (client.dms.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              l10n.discordDirectMessages,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        for (final dm in client.dms)
          ListTile(
            key: ValueKey('discord-dm-${dm.id}'),
            leading: const CircleAvatar(child: Icon(Icons.person_outline)),
            title: Text(discordChannelTitle(dm)),
            onTap: () => openDiscordChannel(context, widget.controller, dm),
          ),
        if (client.guilds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              l10n.discordServers,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        for (final guild in client.guilds) ...[
          ListTile(
            key: ValueKey('discord-guild-${guild.id}'),
            leading: const CircleAvatar(child: Icon(Icons.groups_outlined)),
            title: Text(guild.name),
            trailing: Icon(
              _open.contains(guild.id) ? Icons.expand_less : Icons.expand_more,
            ),
            onTap: () async {
              if (_open.remove(guild.id)) {
                setState(() {});
                return;
              }
              setState(() => _open.add(guild.id));
              try {
                await client.loadChannels(guild.id);
              } catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(describeActionError(error))),
                  );
                }
              }
            },
          ),
          if (_open.contains(guild.id))
            for (final channel in client.channelsOf(guild.id))
              ListTile(
                key: ValueKey('discord-channel-${channel.id}'),
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                dense: true,
                title: Text(discordChannelTitle(channel)),
                onTap: () =>
                    openDiscordChannel(context, widget.controller, channel),
              ),
        ],
      ],
    );
  }
}

/// One channel: it looks for news only while this screen is open, and
/// sends, edits, deletes and reacts only when the user does.
class DiscordChannelScreen extends StatefulWidget {
  const DiscordChannelScreen({
    super.key,
    required this.controller,
    required this.channel,
  });

  final MessengerController controller;
  final DcChannel channel;

  @override
  State<DiscordChannelScreen> createState() => _DiscordChannelScreenState();
}

class _DiscordChannelScreenState extends State<DiscordChannelScreen> {
  final _text = TextEditingController();
  void Function()? _stopWatching;
  DcMessage? _replyTo;
  DcMessage? _editing;

  DiscordClient? get _client => widget.controller.discord.client;

  @override
  void initState() {
    super.initState();
    final client = _client;
    client?.addListener(_changed);
    unawaited(_load());
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) return;
    try {
      await client.loadMessages(widget.channel.id);
      if (!mounted) return;
      _stopWatching = client.watch(widget.channel.id);
    } catch (error) {
      _toast(error);
    }
  }

  @override
  void dispose() {
    _stopWatching?.call();
    _client?.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _toast(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(describeActionError(error))));
  }

  Future<void> _send() async {
    final client = _client;
    final text = _text.text.trim();
    if (client == null || text.isEmpty) return;
    try {
      if (_editing != null) {
        await client.edit(widget.channel.id, _editing!.id, text);
      } else {
        await client.send(widget.channel.id, text, replyTo: _replyTo?.id);
      }
      _text.clear();
      setState(() {
        _replyTo = null;
        _editing = null;
      });
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _menu(DcMessage message) async {
    final client = _client;
    if (client == null) return;
    final mine = message.authorId == client.selfId;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            for (final emoji in const ['👍', '❤', '😂'])
              TextButton(
                onPressed: () => Navigator.pop(context, 'react:$emoji'),
                child: Text(emoji, style: const TextStyle(fontSize: 22)),
              ),
            ListTile(
              key: const ValueKey('discord-reply'),
              leading: const Icon(Icons.reply),
              title: Text(l10nOf(context).xmppReply),
              onTap: () => Navigator.pop(context, 'reply'),
            ),
            if (mine)
              ListTile(
                key: const ValueKey('discord-edit'),
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10nOf(context).xmppEdit),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            if (mine)
              ListTile(
                key: const ValueKey('discord-delete'),
                leading: const Icon(Icons.delete_outline),
                title: Text(l10nOf(context).telegramDeleteForAll),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      if (action.startsWith('react:')) {
        await client.react(widget.channel.id, message.id, action.substring(6));
      } else if (action == 'reply') {
        setState(() {
          _replyTo = message;
          _editing = null;
        });
      } else if (action == 'edit') {
        setState(() {
          _editing = message;
          _replyTo = null;
          _text.text = message.text;
        });
      } else if (action == 'delete') {
        await client.delete(widget.channel.id, message.id);
      }
    } catch (error) {
      _toast(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final theme = Theme.of(context);
    final client = _client;
    if (client == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.xmppChatGone)),
      );
    }
    final messages = client.messagesOf(widget.channel.id).reversed.toList();
    return Scaffold(
      appBar: AppBar(title: Text(discordChannelTitle(widget.channel))),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: messages.length + 1,
              itemBuilder: (context, index) {
                if (index == messages.length) {
                  return TextButton(
                    key: const ValueKey('discord-load-older'),
                    onPressed: () async {
                      try {
                        await client.loadMessages(
                          widget.channel.id,
                          older: true,
                        );
                      } catch (error) {
                        _toast(error);
                      }
                    },
                    child: Text(l10n.discordLoadOlder),
                  );
                }
                final message = messages[index];
                final mine = message.authorId == client.selfId;
                return Align(
                  alignment: mine
                      ? AlignmentDirectional.centerEnd
                      : AlignmentDirectional.centerStart,
                  child: GestureDetector(
                    onLongPress: () => _menu(message),
                    child: Container(
                      key: ValueKey('discord-message-${message.id}'),
                      margin: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      padding: const EdgeInsets.all(10),
                      constraints: const BoxConstraints(maxWidth: 520),
                      decoration: BoxDecoration(
                        color: mine
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!mine)
                            Text(
                              message.author,
                              style: theme.textTheme.labelSmall,
                            ),
                          if (message.text.isNotEmpty)
                            SelectableText(message.text),
                          for (final file in message.attachments)
                            TextButton(
                              onPressed: () => widget.controller
                                  .openExternalUrl(Uri.parse(file.url)),
                              child: Text(file.name.isEmpty ? '…' : file.name),
                            ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (message.reactions.isNotEmpty)
                                Text(
                                  message.reactions.entries
                                      .map((e) => '${e.key} ${e.value}')
                                      .join('  '),
                                ),
                              if (message.edited)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Text(
                                    l10n.xmppEdited,
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_replyTo != null || _editing != null)
            ListTile(
              dense: true,
              title: Text(
                (_editing ?? _replyTo)!.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _replyTo = null;
                  _editing = null;
                  _text.clear();
                }),
              ),
            ),
          SafeArea(
            child: Row(
              children: [
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('discord-composer'),
                    controller: _text,
                    minLines: 1,
                    maxLines: 5,
                    decoration: InputDecoration(
                      hintText: l10n.xmppMessageHint,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('discord-send'),
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
