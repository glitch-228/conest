import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../telegram/telegram_client.dart';
import '../telegram/telegram_models.dart';

/// What to call a chat: Saved Messages by its own name.
String telegramChatTitle(BuildContext? context, TgChat chat) =>
    chat.kind == TgChatKind.saved
    ? l10nOf(context).telegramSaved
    : (chat.title.isEmpty ? '?' : chat.title);

/// A message as the chat list and replies show it.
String telegramPreview(BuildContext? context, TgMessage? message) {
  if (message == null) return l10nOf(context).uiNewChat009BF6;
  final content = message.content;
  if (content.kind == TgContentKind.deleted) {
    return l10nOf(context).telegramDeletedBySender;
  }
  if (content.text.isNotEmpty) return content.text;
  return switch (content.kind) {
    TgContentKind.text => '',
    TgContentKind.sticker => content.text,
    _ =>
      content.file?.name.isNotEmpty ?? false
          ? content.file!.name
          : l10nOf(context).xmppFile,
  };
}

void openTelegramChat(
  BuildContext context,
  MessengerController controller,
  int chatId,
) => unawaited(
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          TelegramChatScreen(controller: controller, chatId: chatId),
    ),
  ),
);

/// The chat list with the user's folders as tabs.
class TelegramChatList extends StatefulWidget {
  const TelegramChatList({super.key, required this.client, required this.open});

  final TelegramClient client;
  final void Function(int chatId) open;

  @override
  State<TelegramChatList> createState() => _TelegramChatListState();
}

class _TelegramChatListState extends State<TelegramChatList> {
  String _list = 'main';

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
    final tabs = <(String, String)>[
      ('main', l10n.telegramAllChats),
      for (final folder in client.folders) (folder.key, folder.title),
      if (client.chatList('archive').isNotEmpty)
        ('archive', l10n.telegramArchive),
    ];
    if (!tabs.any((tab) => tab.$1 == _list)) _list = 'main';
    final chats = client.chatList(_list);
    return Column(
      children: [
        if (tabs.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                for (final (key, title) in tabs)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: ValueKey('telegram-tab-$key'),
                      label: Text(title),
                      selected: key == _list,
                      onSelected: (_) => setState(() => _list = key),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: chats.isEmpty
              ? Center(child: Text(l10n.telegramNoChats))
              : ListView(
                  children: [
                    for (final chat in chats)
                      ListTile(
                        key: ValueKey('telegram-chat-${chat.id}'),
                        leading: CircleAvatar(
                          child: Icon(switch (chat.kind) {
                            TgChatKind.saved => Icons.bookmark_outline,
                            TgChatKind.channel => Icons.campaign_outlined,
                            TgChatKind.group => Icons.group_outlined,
                            _ => Icons.person_outline,
                          }),
                        ),
                        title: Text(
                          telegramChatTitle(context, chat),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          telegramPreview(context, chat.lastMessage),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: chat.unread > 0
                            ? Badge(
                                label: Text('${chat.unread}'),
                                backgroundColor: chat.muted
                                    ? Theme.of(context).disabledColor
                                    : null,
                              )
                            : null,
                        onTap: () => widget.open(chat.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// One Telegram chat: messages, replies, reactions, edits, deletions, files,
/// sponsored messages in channels, and the mod actions.
class TelegramChatScreen extends StatefulWidget {
  const TelegramChatScreen({
    super.key,
    required this.controller,
    required this.chatId,
  });

  final MessengerController controller;
  final int chatId;

  @override
  State<TelegramChatScreen> createState() => _TelegramChatScreenState();
}

class _TelegramChatScreenState extends State<TelegramChatScreen> {
  final _text = TextEditingController();
  TgMessage? _replyTo;
  TgMessage? _editing;
  bool _busy = false;
  int _seen = -1;
  List<TgSponsored> _sponsored = const [];
  final Map<int, String> _translated = {};

  static const _quickReactions = ['👍', '❤', '😂', '😮', '😢', '🎉'];

  TelegramClient? get _client => widget.controller.telegram.client;

  @override
  void initState() {
    super.initState();
    final client = _client;
    client?.addListener(_changed);
    unawaited(_open());
  }

  Future<void> _open() async {
    final client = _client;
    if (client == null) return;
    try {
      await client.openChat(widget.chatId);
      final ads = await client.sponsoredFor(widget.chatId);
      for (final ad in ads) {
        unawaited(client.sponsoredShown(widget.chatId, ad));
      }
      if (mounted) setState(() => _sponsored = ads);
    } catch (error) {
      _toast(error);
    }
    _markRead();
  }

  @override
  void dispose() {
    final client = _client;
    client?.removeListener(_changed);
    if (client != null) unawaited(client.closeChat(widget.chatId));
    _text.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _markRead();
  }

  void _markRead() {
    final client = _client;
    final chat = client?.chats[widget.chatId];
    if (client == null || chat == null) return;
    final count = client.messagesOf(widget.chatId).length;
    if (chat.unread == 0 && count == _seen) return;
    _seen = count;
    unawaited(client.markRead(widget.chatId).catchError((Object _) {}));
  }

  void _toast(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(describeActionError(error))));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _toast(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send({bool silent = false, DateTime? sendAt}) async {
    final client = _client;
    final text = _text.text.trim();
    if (client == null || text.isEmpty) return;
    final editing = _editing;
    final reply = _replyTo;
    await _run(() async {
      if (editing != null) {
        await client.edit(widget.chatId, editing.id, text);
      } else {
        await client.sendText(
          widget.chatId,
          text,
          replyTo: reply?.id,
          silent: silent,
          sendAt: sendAt,
        );
      }
      _text.clear();
      if (mounted) {
        setState(() {
          _replyTo = null;
          _editing = null;
        });
      }
    });
  }

  Future<void> _schedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null) return;
    await _send(
      sendAt: DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  Future<void> _attach() async {
    final client = _client;
    if (client == null) return;
    final picked = await FilePicker.pickFiles();
    final path = picked?.files.single.path;
    if (path == null) return;
    await _run(
      () => client.sendFile(
        widget.chatId,
        path,
        caption: _text.text.trim(),
        replyTo: _replyTo?.id,
      ),
    );
    _text.clear();
  }

  Future<void> _export() async {
    final client = _client;
    if (client == null) return;
    final bytes = utf8.encode(client.exportChat(widget.chatId));
    try {
      final path = await FilePicker.saveFile(
        fileName: 'telegram-chat-${widget.chatId}.json',
        bytes: bytes,
      );
      if (path != null &&
          !Platform.isLinux &&
          !Platform.isMacOS &&
          !Platform.isWindows) {
        await File(path).writeAsBytes(bytes);
      }
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _menu(TgMessage message) async {
    final client = _client;
    if (client == null) return;
    final l10n = l10nOf(context);
    final text = message.content.text;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                spacing: 4,
                children: [
                  for (final emoji in _quickReactions)
                    TextButton(
                      key: ValueKey('telegram-react-$emoji'),
                      onPressed: () => Navigator.pop(context, 'react:$emoji'),
                      child: Text(emoji, style: const TextStyle(fontSize: 22)),
                    ),
                ],
              ),
            ),
            ListTile(
              key: const ValueKey('telegram-reply'),
              leading: const Icon(Icons.reply),
              title: Text(l10n.xmppReply),
              onTap: () => Navigator.pop(context, 'reply'),
            ),
            if (text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(l10n.xmppCopy),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
            if (text.isNotEmpty)
              ListTile(
                key: const ValueKey('telegram-translate'),
                leading: const Icon(Icons.translate),
                title: Text(l10n.telegramTranslate),
                onTap: () => Navigator.pop(context, 'translate'),
              ),
            if (message.outgoing && message.content.kind == TgContentKind.text)
              ListTile(
                key: const ValueKey('telegram-edit'),
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.xmppEdit),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            ListTile(
              key: const ValueKey('telegram-delete-me'),
              leading: const Icon(Icons.delete_outline),
              title: Text(l10n.telegramDeleteForMe),
              onTap: () => Navigator.pop(context, 'delete-me'),
            ),
            ListTile(
              key: const ValueKey('telegram-delete-all'),
              leading: const Icon(Icons.delete_forever_outlined),
              title: Text(l10n.telegramDeleteForAll),
              onTap: () => Navigator.pop(context, 'delete-all'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action.startsWith('react:')) {
      await _run(
        () => client.react(widget.chatId, message.id, action.substring(6)),
      );
      return;
    }
    switch (action) {
      case 'reply':
        setState(() {
          _replyTo = message;
          _editing = null;
        });
      case 'copy':
        await Clipboard.setData(ClipboardData(text: text));
      case 'translate':
        await _run(() async {
          final result = await client.translate(text);
          if (mounted) setState(() => _translated[message.id] = result);
        });
      case 'edit':
        setState(() {
          _editing = message;
          _replyTo = null;
          _text.text = text;
        });
      case 'delete-me':
        await _run(
          () => client.delete(widget.chatId, message.id, forEveryone: false),
        );
      case 'delete-all':
        await _run(
          () => client.delete(widget.chatId, message.id, forEveryone: true),
        );
    }
  }

  Widget _content(TgMessage message, ThemeData theme) {
    final l10n = l10nOf(context);
    final content = message.content;
    final client = _client!;
    if (content.kind == TgContentKind.deleted) {
      return Text(
        l10n.telegramDeletedBySender,
        key: ValueKey('telegram-deleted-${message.id}'),
        style: theme.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.hintColor,
        ),
      );
    }
    final file = content.file;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (file != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 18),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  file.name.isEmpty ? l10n.xmppFile : file.name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              if (file.downloaded)
                IconButton(
                  key: ValueKey('telegram-open-${message.id}'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: () =>
                      widget.controller.openExternalUrl(Uri.file(file.path!)),
                )
              else if (file.downloading)
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: file.size > 0
                        ? file.downloadedBytes / file.size
                        : null,
                  ),
                )
              else
                TextButton(
                  key: ValueKey('telegram-download-${message.id}'),
                  onPressed: () => _run(() => client.download(file)),
                  child: Text(l10n.telegramDownload),
                ),
            ],
          )
        else if (content.kind != TgContentKind.text &&
            content.kind != TgContentKind.sticker)
          Text(content.typeName.isEmpty ? '…' : content.typeName),
        if (content.text.isNotEmpty) SelectableText(content.text),
        if (_translated[message.id] case final translation?)
          Text(
            translation,
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final theme = Theme.of(context);
    final client = _client;
    final chat = client?.chats[widget.chatId];
    if (client == null || chat == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.xmppChatGone)),
      );
    }
    final messages = client.messagesOf(widget.chatId).reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(telegramChatTitle(context, chat)),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('telegram-chat-menu'),
            onSelected: (value) {
              if (value == 'export') unawaited(_export());
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'export', child: Text(l10n.telegramExport)),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: messages.length + 1,
              itemBuilder: (context, index) {
                if (index == messages.length) {
                  return client.historyComplete(widget.chatId)
                      ? const SizedBox(height: 8)
                      : TextButton(
                          key: const ValueKey('telegram-load-older'),
                          onPressed: () =>
                              _run(() => client.loadOlder(widget.chatId)),
                          child: Text(l10n.telegramLoadOlder),
                        );
                }
                final message = messages[index];
                final mine = message.outgoing;
                return Align(
                  alignment: mine
                      ? AlignmentDirectional.centerEnd
                      : AlignmentDirectional.centerStart,
                  child: GestureDetector(
                    onLongPress: () => _menu(message),
                    child: Container(
                      key: ValueKey('telegram-message-${message.id}'),
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
                          if (!mine &&
                              chat.kind != TgChatKind.private &&
                              client.nameOf(message.senderId).isNotEmpty)
                            Text(
                              client.nameOf(message.senderId),
                              style: theme.textTheme.labelSmall,
                            ),
                          if (message.replyToId != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                telegramPreview(
                                  context,
                                  client
                                      .messagesOf(widget.chatId)
                                      .where((m) => m.id == message.replyToId)
                                      .firstOrNull,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.hintColor,
                                ),
                              ),
                            ),
                          _content(message, theme),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (message.reactions.isNotEmpty)
                                Text(
                                  message.reactions.entries
                                      .map((e) => '${e.key} ${e.value}')
                                      .join('  '),
                                ),
                              if (message.editedAt != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Text(
                                    l10n.xmppEdited,
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                              if (message.sendState == TgSendState.sending)
                                const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(Icons.schedule, size: 12),
                                ),
                              if (message.sendState == TgSendState.failed)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(
                                    Icons.error_outline,
                                    size: 14,
                                    color: theme.colorScheme.error,
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
          for (final ad in _sponsored)
            Container(
              key: ValueKey('telegram-sponsored-${ad.id}'),
              margin: const EdgeInsets.fromLTRB(10, 2, 10, 2),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${l10n.telegramSponsored} · ${ad.title}',
                          style: theme.textTheme.labelSmall,
                        ),
                        if (ad.text.isNotEmpty) Text(ad.text),
                      ],
                    ),
                  ),
                  if (ad.url.isNotEmpty)
                    TextButton(
                      onPressed: () =>
                          widget.controller.openExternalUrl(Uri.parse(ad.url)),
                      child: Text(
                        ad.buttonText.isEmpty
                            ? l10n.telegramOpenSponsored
                            : ad.buttonText,
                      ),
                    ),
                ],
              ),
            ),
          if (!chat.canPost)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l10n.telegramChannelReadOnly),
            )
          else ...[
            if (_replyTo != null || _editing != null)
              ListTile(
                dense: true,
                title: Text(
                  telegramPreview(context, _editing ?? _replyTo),
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
                  IconButton(
                    tooltip: l10n.xmppAttach,
                    onPressed: _busy ? null : _attach,
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('telegram-composer'),
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: l10n.xmppMessageHint,
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('telegram-send-options'),
                    icon: const Icon(Icons.expand_less),
                    onSelected: (value) {
                      if (value == 'silent') unawaited(_send(silent: true));
                      if (value == 'later') unawaited(_schedule());
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'silent',
                        child: Text(l10n.telegramSendSilently),
                      ),
                      PopupMenuItem(
                        value: 'later',
                        child: Text(l10n.telegramSchedule),
                      ),
                    ],
                  ),
                  IconButton(
                    key: const ValueKey('telegram-send'),
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
