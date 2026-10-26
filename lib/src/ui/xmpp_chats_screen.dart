import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_locales.dart';
import '../conest_theme.dart';
import '../messenger_controller.dart';
import '../network_errors.dart';
import '../xmpp/xmpp_chat_client.dart';
import '../xmpp/xmpp_chats.dart';
import '../xmpp/xmpp_files.dart';
import 'linked_text.dart';

/// What to call [jid] in XMPP chats: the room's subject or the contact
/// list's name, else the address.
String xmppChatTitle(MessengerController controller, XmppChat chat) =>
    (chat.title?.isNotEmpty ?? false)
    ? chat.title!
    : controller.xmppChats.names[chat.jid] ?? chat.jid;

/// The last message as the chat list shows it.
String xmppPreview(BuildContext? context, XmppChatMessage? message) {
  if (message == null) return l10nOf(context).uiNewChat009BF6;
  if (message.retracted) return l10nOf(context).xmppRetracted;
  if (message.fileUrl != null) return l10nOf(context).xmppFile;
  return message.text;
}

void openXmppChat(
  BuildContext context,
  MessengerController controller,
  String jid,
) => unawaited(
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => XmppChatScreen(controller: controller, jid: jid),
    ),
  ),
);

/// Asks for an address or `xmpp:` link and opens the chat: a person, or a
/// group chat joined under a nickname.
Future<void> startXmppChat(
  BuildContext context,
  MessengerController controller,
) async {
  final client = controller.xmppChatClient;
  if (client == null) return;
  final address = TextEditingController();
  final nick = TextEditingController();
  var room = false;
  final l10n = l10nOf(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(l10n.xmppNewChat),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('xmpp-new-chat-address'),
              controller: address,
              autofocus: true,
              autocorrect: false,
              decoration: InputDecoration(labelText: l10n.xmppNewChatAddress),
              onChanged: (value) {
                final link = parseXmppUri(value);
                if (link?.action == 'join' && !room) {
                  setState(() => room = true);
                }
              },
            ),
            CheckboxListTile(
              key: const ValueKey('xmpp-new-chat-room'),
              contentPadding: EdgeInsets.zero,
              value: room,
              title: Text(l10n.xmppGroupChat),
              onChanged: (value) => setState(() => room = value ?? false),
            ),
            if (room)
              TextField(
                controller: nick,
                decoration: InputDecoration(labelText: l10n.xmppNickname),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('xmpp-new-chat-open'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.xmppOpenChat),
          ),
        ],
      ),
    ),
  );
  if (result != true || !context.mounted) return;
  try {
    final jid = room
        ? client.joinRoom(
            address.text,
            nick: nick.text.trim().isEmpty ? null : nick.text.trim(),
          )
        : client.startChat(address.text);
    openXmppChat(context, controller, jid);
  } catch (error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(describeActionError(error))));
  }
}

/// One XMPP chat: messages, replies, reactions, corrections, retractions,
/// files, and the request banner for strangers.
class XmppChatScreen extends StatefulWidget {
  const XmppChatScreen({
    super.key,
    required this.controller,
    required this.jid,
  });

  final MessengerController controller;
  final String jid;

  @override
  State<XmppChatScreen> createState() => _XmppChatScreenState();
}

class _XmppChatScreenState extends State<XmppChatScreen> {
  final _text = TextEditingController();
  XmppChatMessage? _replyTo;
  XmppChatMessage? _editing;
  bool _busy = false;
  int _seen = -1;

  static const _quickReactions = ['👍', '❤', '😂', '😮', '😢', '🎉'];

  XmppChatClient? get _client => widget.controller.xmppChatClient;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _markRead();
  }

  void _markRead() {
    final chat = widget.controller.xmppChats.chats[widget.jid];
    if (chat == null || chat.request) return;
    final count = chat.messages.length;
    if (chat.unread == 0 && count == _seen) return;
    _seen = count;
    _client?.markRead(widget.jid);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(describeActionError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final client = _client;
    final text = _text.text.trim();
    if (client == null || text.isEmpty) return;
    final editing = _editing;
    final reply = _replyTo;
    await _run(() async {
      if (editing != null) {
        await client.correct(widget.jid, editing.id, text);
      } else {
        await client.sendText(widget.jid, text, replyTo: reply?.id);
      }
      _text.clear();
      setState(() {
        _editing = null;
        _replyTo = null;
      });
    });
  }

  Future<void> _attach() async {
    final client = _client;
    if (client == null) return;
    final picked = await FilePicker.pickFiles();
    final path = picked?.files.singleOrNull?.path;
    if (path == null || !mounted) return;
    final l10n = l10nOf(context);
    await _run(() async {
      final upload = await prepareXmppUpload(path);
      try {
        if (upload.needsConsent && mounted) {
          final go = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l10n.xmppMetadataTitle),
              content: Text(l10n.xmppMetadataBody),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l10n.actionCancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(l10n.xmppSendAnyway),
                ),
              ],
            ),
          );
          if (go != true) return;
        }
        await client.sendFile(
          widget.jid,
          upload.file,
          contentType: xmppContentType(upload.file.path),
        );
      } finally {
        await upload.discard();
      }
    });
  }

  Future<void> _actions(XmppChatMessage message, XmppChat chat) async {
    final client = _client;
    if (client == null || message.retracted) return;
    final l10n = l10nOf(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final emoji in _quickReactions)
                  ActionChip(
                    label: Text(emoji),
                    onPressed: () => Navigator.pop(context, 'react:$emoji'),
                  ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text(l10n.xmppReply),
              onTap: () => Navigator.pop(context, 'reply'),
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(l10n.xmppCopy),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            if (message.outgoing) ...[
              ListTile(
                key: const ValueKey('xmpp-message-edit'),
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.xmppEdit),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
              ListTile(
                key: const ValueKey('xmpp-message-retract'),
                leading: const Icon(Icons.delete_outline),
                title: Text(l10n.xmppRetract),
                onTap: () => Navigator.pop(context, 'retract'),
              ),
            ],
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice.startsWith('react:')) {
      final emoji = choice.substring(6);
      final me = chat.room ? (chat.nick ?? '') : client.jid;
      final mine = {
        for (final MapEntry(:key, :value) in message.reactions.entries)
          if (value.contains(me)) key,
      };
      // Tapping a reaction already given takes it back.
      final next = mine.contains(emoji) ? (mine..remove(emoji)) : {emoji};
      await _run(() => client.react(widget.jid, message.id, next));
      return;
    }
    switch (choice) {
      case 'reply':
        setState(() {
          _replyTo = message;
          _editing = null;
        });
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text));
      case 'edit':
        setState(() {
          _editing = message;
          _replyTo = null;
          _text.text = message.text;
        });
      case 'retract':
        await _run(() => client.retract(widget.jid, message.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final controller = widget.controller;
    final chat = controller.xmppChats.chats[widget.jid];
    final client = _client;
    final theme = Theme.of(context);
    final palette = ConestPalette(brightness: Theme.of(context).brightness);
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.xmppChatGone)),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              xmppChatTitle(controller, chat),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              // Encryption (OMEMO) comes later: said plainly per chat.
              '${chat.room ? l10n.xmppGroupChat : chat.jid} · '
              '${l10n.xmppNotEncrypted}',
              key: const ValueKey('xmpp-encryption-mark'),
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'leave') {
                client?.removeChat(widget.jid);
                if (context.mounted) Navigator.pop(context);
              } else if (value == 'block') {
                await _run(() async => client?.block(widget.jid));
                if (context.mounted) Navigator.pop(context);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'leave',
                child: Text(
                  chat.room ? l10n.xmppLeaveRoom : l10n.xmppDeleteChat,
                ),
              ),
              if (!chat.room)
                PopupMenuItem(value: 'block', child: Text(l10n.xmppBlock)),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (chat.request)
            MaterialBanner(
              key: const ValueKey('xmpp-request-banner'),
              content: Text(
                chat.room ? l10n.xmppRoomInvitation : l10n.xmppRequest,
              ),
              actions: [
                if (!chat.room)
                  TextButton(
                    onPressed: () =>
                        _run(() async => client?.block(widget.jid)),
                    child: Text(l10n.xmppBlock),
                  ),
                FilledButton(
                  key: const ValueKey('xmpp-request-accept'),
                  onPressed: () => _run(() async {
                    client?.acceptRequest(widget.jid);
                  }),
                  child: Text(l10n.xmppAccept),
                ),
              ],
            ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(8),
              itemCount: chat.messages.length,
              itemBuilder: (context, index) {
                final message = chat.messages[chat.messages.length - 1 - index];
                return _bubble(context, chat, message, palette);
              },
            ),
          ),
          if (_replyTo != null || _editing != null)
            ListTile(
              dense: true,
              leading: Icon(
                _editing != null ? Icons.edit_outlined : Icons.reply,
              ),
              title: Text(
                xmppSnippet((_editing ?? _replyTo)!.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _replyTo = null;
                  if (_editing != null) _text.clear();
                  _editing = null;
                }),
              ),
            ),
          if (!chat.request)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  children: [
                    if (client?.canSendFiles ?? false)
                      IconButton(
                        tooltip: l10n.xmppAttach,
                        onPressed: _busy ? null : _attach,
                        icon: const Icon(Icons.attach_file),
                      ),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('xmpp-composer'),
                        controller: _text,
                        minLines: 1,
                        maxLines: 5,
                        decoration: InputDecoration(
                          hintText: l10n.xmppMessageHint,
                          isDense: true,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('xmpp-send'),
                      onPressed: _busy || client == null ? null : _send,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bubble(
    BuildContext context,
    XmppChat chat,
    XmppChatMessage message,
    ConestPalette palette,
  ) {
    final l10n = l10nOf(context);
    final theme = Theme.of(context);
    final outgoing = message.outgoing;
    final state = switch (message.state) {
      XmppMessageState.sending => Icons.schedule,
      XmppMessageState.sent => Icons.check,
      XmppMessageState.delivered => Icons.done_all,
      XmppMessageState.read => Icons.visibility_outlined,
      XmppMessageState.failed => Icons.error_outline,
    };
    return Align(
      alignment: outgoing
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: GestureDetector(
        onLongPress: () => _actions(message, chat),
        onSecondaryTap: () => _actions(message, chat),
        child: Container(
          key: ValueKey('xmpp-message-${message.id}'),
          constraints: const BoxConstraints(maxWidth: 480),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: outgoing
                ? palette.primary.withValues(alpha: 0.15)
                : palette.panel,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (chat.room && !outgoing)
                Text(message.from, style: theme.textTheme.labelMedium),
              if (message.replySnippet != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsetsDirectional.only(start: 6),
                  decoration: BoxDecoration(
                    border: BorderDirectional(
                      start: BorderSide(color: palette.primary, width: 2),
                    ),
                  ),
                  child: Text(
                    message.replySnippet!,
                    maxLines: 2,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (message.retracted)
                Text(
                  l10n.xmppRetracted,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                )
              else if (message.fileUrl != null)
                ActionChip(
                  avatar: const Icon(Icons.insert_drive_file_outlined),
                  label: Text(
                    Uri.parse(message.fileUrl!).pathSegments.lastOrNull ??
                        l10n.xmppFile,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => widget.controller.openExternalUrl(
                    Uri.parse(message.fileUrl!),
                  ),
                )
              else
                LinkedText(
                  message.text,
                  openUrl: widget.controller.openExternalUrl,
                ),
              if (message.reactions.isNotEmpty)
                Wrap(
                  spacing: 4,
                  children: [
                    for (final MapEntry(:key, :value)
                        in message.reactions.entries)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('$key ${value.length}'),
                      ),
                  ],
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    TimeOfDay.fromDateTime(
                      message.at.toLocal(),
                    ).format(context),
                    style: theme.textTheme.labelSmall,
                  ),
                  if (message.editedAt != null) ...[
                    const SizedBox(width: 4),
                    Text(l10n.xmppEdited, style: theme.textTheme.labelSmall),
                  ],
                  if (outgoing) ...[
                    const SizedBox(width: 4),
                    Icon(state, size: 14),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// XMPP chats in Settings → Connectivity: on with the carrier's account or
/// another, the state, and new chats.
class XmppChatsPanel extends StatefulWidget {
  const XmppChatsPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<XmppChatsPanel> createState() => _XmppChatsPanelState();
}

class _XmppChatsPanelState extends State<XmppChatsPanel> {
  final _jid = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _other = false;
  String? _error;

  @override
  void dispose() {
    _jid.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = describeActionError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final l10n = l10nOf(context);
        final controller = widget.controller;
        final config = controller.xmppClientConfig;
        final client = controller.xmppChatClient;
        final carrier = controller.xmppCarrierConfig;
        final useOther = _other || carrier == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              key: const ValueKey('xmpp-chats-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.xmppChats),
              subtitle: Text(
                config == null
                    ? l10n.xmppChatsSubtitle
                    : '${config.jid} · ${client?.connected ?? false ? l10n.xmppConnected : l10n.xmppConnecting}',
              ),
              value: config != null,
              onChanged: _busy
                  ? null
                  : (on) => _run(
                      on
                          ? () => controller.enableXmppChats(
                              jid: useOther ? _jid.text : null,
                              password: useOther ? _password.text : null,
                            )
                          : controller.disableXmppChats,
                    ),
            ),
            if (config == null) ...[
              if (carrier != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _other,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _other = value ?? false),
                  title: Text(l10n.xmppChatsOtherAccount),
                ),
              if (useOther) ...[
                TextField(
                  key: const ValueKey('xmpp-chats-jid'),
                  controller: _jid,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l10n.xmppAddressField,
                    isDense: true,
                  ),
                ),
                TextField(
                  key: const ValueKey('xmpp-chats-password'),
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.xmppPasswordField,
                    isDense: true,
                  ),
                ),
              ],
            ] else
              ListTile(
                key: const ValueKey('xmpp-new-chat'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add_comment_outlined),
                title: Text(l10n.xmppNewChat),
                onTap: client == null
                    ? null
                    : () => startXmppChat(context, controller),
              ),
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
