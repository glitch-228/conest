import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../conest_theme.dart';
import '../matrix_service.dart';
import '../matrix_timeline.dart';
import 'matrix_verification_dialog.dart';

/// Asks for a Matrix ID, opens (or creates) the direct chat with it and
/// shows the room.
Future<void> startMatrixChat(
  BuildContext context,
  MatrixClientService client,
  ConestPalette palette,
) async {
  final input = TextEditingController();
  final userId = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('New Matrix chat'),
      content: TextField(
        controller: input,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Matrix user',
          hintText: '@name:matrix.org',
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text),
          child: const Text('Start chat'),
        ),
      ],
    ),
  );
  input.dispose();
  final target = userId?.trim() ?? '';
  if (target.isEmpty || !context.mounted) return;
  try {
    final roomId = await client.createDirectMessage(target);
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            MatrixRoomScreen(client: client, roomId: roomId, palette: palette),
      ),
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start the chat: $error')),
      );
    }
  }
}

/// One Matrix room or DM: timeline with history paging, media, replies,
/// edits, reactions and deletes, and a composer with attachments.
class MatrixRoomScreen extends StatefulWidget {
  const MatrixRoomScreen({
    super.key,
    required this.client,
    required this.roomId,
    required this.palette,
  });

  final MatrixClientService client;
  final String roomId;
  final ConestPalette palette;

  @override
  State<MatrixRoomScreen> createState() => _MatrixRoomScreenState();
}

class _MatrixRoomScreenState extends State<MatrixRoomScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  MatrixTimelineItem? _replyTo;
  MatrixTimelineItem? _editing;
  bool _loadingOlder = false;
  bool _sending = false;
  String? _lastRead;

  MatrixClientService get _client => widget.client;

  /// The other person of a direct chat, and whether they are verified.
  String? get _partner {
    final room = _client.room(widget.roomId);
    if (room == null || !room.direct || room.directTargets.length != 1) {
      return null;
    }
    return room.directTargets.single;
  }

  ({bool verified, bool crossSigning})? _partnerState;

  Future<void> _checkPartner() async {
    final partner = _partner;
    if (partner == null) return;
    try {
      final state = await _client.userVerification(partner);
      if (mounted) setState(() => _partnerState = state);
    } catch (_) {
      // Unknown for now; the action stays available.
    }
  }

  Future<void> _verifyPartner() async {
    final partner = _partner;
    if (partner == null) return;
    try {
      final flowId = await _client.verifyUser(partner);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => MatrixVerificationDialog(
          client: _client,
          userId: partner,
          flowId: flowId,
          weStarted: true,
          otherName: _client.room(widget.roomId)?.name ?? partner,
        ),
      );
    } catch (error) {
      _show('Could not verify: $error');
    }
    await _checkPartner();
  }

  @override
  void initState() {
    super.initState();
    _client.addListener(_changed);
    unawaited(_checkPartner());
    if (_client.timeline(widget.roomId).items.isEmpty) {
      unawaited(_loadOlder());
    }
  }

  @override
  void dispose() {
    _client.removeListener(_changed);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // Timelines are dropped after recovery or verification to decrypt again.
    if (_client.timeline(widget.roomId).items.isEmpty &&
        _client.hasOlder(widget.roomId) &&
        !_loadingOlder) {
      unawaited(_loadOlder());
    }
    _markRead();
  }

  void _markRead() {
    final items = _client.timeline(widget.roomId).items;
    if (items.isEmpty || _client.room(widget.roomId)?.invited == true) return;
    final last = items.last.eventId;
    if (last == _lastRead) return;
    _lastRead = last;
    unawaited(_client.markRead(widget.roomId, last).catchError((Object _) {}));
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      await _client.loadOlder(widget.roomId);
    } catch (error) {
      _show('Could not load history: $error');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
    _markRead();
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final editing = _editing;
      if (editing != null) {
        await _client.edit(widget.roomId, editing.eventId, body);
      } else {
        await _client.sendText(widget.roomId, body, replyTo: _replyTo?.eventId);
      }
      _composer.clear();
      if (mounted) {
        setState(() {
          _replyTo = null;
          _editing = null;
        });
      }
    } catch (error) {
      _show('Not sent: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attach() async {
    final picked = await FilePicker.pickFiles();
    final file = picked?.files.singleOrNull;
    final path = file?.path;
    if (file == null || path == null) return;
    setState(() => _sending = true);
    try {
      await _client.sendFile(
        widget.roomId,
        path: path,
        name: file.name,
        mimeType: _mimeFor(file.name),
      );
    } catch (error) {
      _show('File not sent: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _actions(MatrixTimelineItem item) async {
    final mine = item.sender == _client.userId;
    final readable =
        item.kind != MatrixItemKind.redacted &&
        item.kind != MatrixItemKind.undecryptable;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (readable)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final key in const ['👍', '❤️', '😂', '😮', '😢'])
                      IconButton(
                        onPressed: () => Navigator.pop(context, 'react:$key'),
                        icon: Text(key, style: const TextStyle(fontSize: 24)),
                      ),
                  ],
                ),
              ),
            if (readable)
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
            if (readable && item.body.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy text'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
            if (mine && item.kind == MatrixItemKind.text)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            if (mine && item.kind != MatrixItemKind.redacted)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete for everyone'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      switch (choice) {
        case 'reply':
          setState(() {
            _replyTo = item;
            _editing = null;
          });
        case 'edit':
          setState(() {
            _editing = item;
            _replyTo = null;
            _composer.text = item.body;
          });
        case 'copy':
          await Clipboard.setData(ClipboardData(text: item.body));
        case 'delete':
          await _client.redact(widget.roomId, item.eventId);
        default:
          if (choice.startsWith('react:')) {
            await _client.toggleReaction(
              widget.roomId,
              item.eventId,
              choice.substring(6),
            );
          }
      }
    } catch (error) {
      _show('$error');
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final room = _client.room(widget.roomId);
    final items = _displayRows(
      _client.timeline(widget.roomId).items,
      showMembership: _client.showMembershipEvents,
    );
    return Scaffold(
      backgroundColor: palette.appBackground,
      appBar: AppBar(
        backgroundColor: palette.panel,
        title: Row(
          children: [
            Flexible(
              child: Text(
                room?.name ?? widget.roomId,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _MatrixBadge(palette: palette),
            if (room?.encrypted == true) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: 'End-to-end encrypted (Matrix)',
                child: Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: palette.success,
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_partner != null)
            _partnerState?.verified == true
                ? Tooltip(
                    key: const ValueKey('matrix-partner-verified'),
                    message: 'Verified',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(Icons.verified_user, color: palette.success),
                    ),
                  )
                : IconButton(
                    key: const ValueKey('matrix-verify-partner'),
                    tooltip: 'Verify ${room?.name ?? _partner}',
                    icon: const Icon(Icons.gpp_maybe_outlined),
                    onPressed: _verifyPartner,
                  ),
        ],
      ),
      body: Column(
        children: [
          if (_partner != null && _partnerState?.verified != true)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                room?.encrypted == true
                    ? 'Messages are end-to-end encrypted, but your homeserver '
                          'and theirs see who talks to whom and when. Verify '
                          '${room?.name ?? _partner} to be sure it is them.'
                    : 'This chat is not encrypted: your homeserver and theirs '
                          'can read it.',
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              ),
            ),
          if (room?.invited == true)
            _InviteBanner(
              palette: palette,
              onAccept: () => _client
                  .join(widget.roomId)
                  .catchError(
                    (Object error) => _show('Could not join: $error'),
                  ),
              onDecline: () async {
                try {
                  await _client.leave(widget.roomId);
                  if (context.mounted) Navigator.of(context).pop();
                } catch (error) {
                  _show('Could not decline: $error');
                }
              },
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length + 1,
              itemBuilder: (context, index) {
                if (index == items.length) {
                  if (!_client.hasOlder(widget.roomId)) {
                    return const SizedBox(height: 8);
                  }
                  return Center(
                    child: TextButton(
                      onPressed: _loadingOlder ? null : _loadOlder,
                      child: Text(
                        _loadingOlder ? 'Loading…' : 'Load earlier messages',
                      ),
                    ),
                  );
                }
                final row = items[items.length - 1 - index];
                if (row.length > 1 ||
                    row.single.kind == MatrixItemKind.membership) {
                  return _MembershipSummary(items: row);
                }
                final item = row.single;
                return _MatrixBubble(
                  item: item,
                  mine: item.sender == _client.userId,
                  quoted: item.replyToEventId == null
                      ? null
                      : _client.timeline(widget.roomId)[item.replyToEventId!],
                  client: _client,
                  palette: palette,
                  onLongPress: () => unawaited(_actions(item)),
                  onReact: (key) => unawaited(
                    _client
                        .toggleReaction(widget.roomId, item.eventId, key)
                        .catchError((Object error) => _show('$error')),
                  ),
                );
              },
            ),
          ),
          if (_replyTo != null || _editing != null)
            Container(
              color: palette.panel2,
              padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
              child: Row(
                children: [
                  Icon(
                    _editing != null ? Icons.edit_outlined : Icons.reply,
                    size: 18,
                    color: palette.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _editing != null
                          ? 'Editing'
                          : 'Reply to ${_shortName(_replyTo!.sender)}: '
                                '${_preview(_replyTo!)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel',
                    onPressed: () => setState(() {
                      if (_editing != null) _composer.clear();
                      _replyTo = null;
                      _editing = null;
                    }),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          if (room?.invited != true)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Attach a file',
                      onPressed: _sending ? null : _attach,
                      icon: const Icon(Icons.attach_file),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _composer,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: 'Message',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Send',
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.send, color: palette.primary),
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

/// Timeline rows: one message each, or a run of membership changes shown
/// as one line (skipped unless the user turned them on).
List<List<MatrixTimelineItem>> _displayRows(
  List<MatrixTimelineItem> items, {
  required bool showMembership,
}) {
  final rows = <List<MatrixTimelineItem>>[];
  for (final item in items) {
    if (item.kind != MatrixItemKind.membership) {
      rows.add([item]);
    } else if (showMembership) {
      final last = rows.isEmpty ? null : rows.last;
      if (last != null && last.first.kind == MatrixItemKind.membership) {
        last.add(item);
      } else {
        rows.add([item]);
      }
    }
  }
  return rows;
}

/// Joins, leaves and profile changes, collapsed like other Matrix apps.
class _MembershipSummary extends StatefulWidget {
  const _MembershipSummary({required this.items});

  final List<MatrixTimelineItem> items;

  @override
  State<_MembershipSummary> createState() => _MembershipSummaryState();
}

class _MembershipSummaryState extends State<_MembershipSummary> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final texts = widget.items.map((item) => item.body).toList();
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final collapsed = texts.length <= 2
        ? texts.join(', ')
        : '${texts.take(2).join(', ')} and ${texts.length - 2} more';
    return InkWell(
      onTap: texts.length > 2
          ? () => setState(() => _expanded = !_expanded)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: Text(
          _expanded ? texts.join('\n') : collapsed,
          textAlign: TextAlign.center,
          style: style,
        ),
      ),
    );
  }
}

String _shortName(String userId) {
  final colon = userId.indexOf(':');
  return userId.startsWith('@') && colon > 1
      ? userId.substring(1, colon)
      : userId;
}

String _preview(MatrixTimelineItem item) => switch (item.kind) {
  MatrixItemKind.redacted => 'Message deleted',
  MatrixItemKind.undecryptable => 'Unable to decrypt',
  MatrixItemKind.image => '📷 ${item.body}',
  MatrixItemKind.file ||
  MatrixItemKind.audio ||
  MatrixItemKind.video => '📎 ${item.fileName ?? item.body}',
  _ => item.body,
};

/// Last message preview for chat lists.
String matrixPreview(MatrixTimelineItem item) =>
    item.kind == MatrixItemKind.membership
    ? item.body
    : '${_shortName(item.sender)}: ${_preview(item)}';

String? _mimeFor(String name) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return const {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'mp4': 'video/mp4',
    'webm': 'video/webm',
    'ogg': 'audio/ogg',
    'opus': 'audio/ogg',
    'mp3': 'audio/mpeg',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
  }[extension];
}

class _MatrixBadge extends StatelessWidget {
  const _MatrixBadge({required this.palette});
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: palette.secondary.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      'Matrix',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: palette.secondary,
      ),
    ),
  );
}

class _InviteBanner extends StatelessWidget {
  const _InviteBanner({
    required this.palette,
    required this.onAccept,
    required this.onDecline,
  });

  final ConestPalette palette;
  final Future<void> Function() onAccept;
  final Future<void> Function() onDecline;

  @override
  Widget build(BuildContext context) => Container(
    color: palette.panel2,
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        const Expanded(child: Text('You were invited to this Matrix chat.')),
        TextButton(onPressed: onDecline, child: const Text('Decline')),
        const SizedBox(width: 8),
        FilledButton(onPressed: onAccept, child: const Text('Join')),
      ],
    ),
  );
}

class _MatrixBubble extends StatelessWidget {
  const _MatrixBubble({
    required this.item,
    required this.mine,
    required this.quoted,
    required this.client,
    required this.palette,
    required this.onLongPress,
    required this.onReact,
  });

  final MatrixTimelineItem item;
  final bool mine;
  final MatrixTimelineItem? quoted;
  final MatrixClientService client;
  final ConestPalette palette;
  final VoidCallback onLongPress;
  final ValueChanged<String> onReact;

  @override
  Widget build(BuildContext context) {
    final background = mine ? palette.outboundBubble : palette.inboundBubble;
    final foreground = mine ? palette.outboundText : palette.inboundText;
    final meta = mine ? palette.outboundMeta : palette.inboundMeta;
    final time = TimeOfDay.fromDateTime(item.timestamp.toLocal());
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine)
                Text(
                  _shortName(item.sender),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: palette.secondary,
                  ),
                ),
              if (quoted != null)
                Container(
                  margin: const EdgeInsets.only(top: 4, bottom: 4),
                  padding: const EdgeInsets.only(left: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: palette.primary, width: 3),
                    ),
                  ),
                  child: Text(
                    '${_shortName(quoted!.sender)}: ${_preview(quoted!)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: meta),
                  ),
                ),
              _content(context, foreground, meta),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.edited)
                    Text(
                      'edited · ',
                      style: TextStyle(fontSize: 10, color: meta),
                    ),
                  Text(
                    time.format(context),
                    style: TextStyle(fontSize: 10, color: meta),
                  ),
                ],
              ),
              if (item.reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final entry in item.reactions.entries)
                        InkWell(
                          onTap: entry.value.contains(client.userId)
                              ? null
                              : () => onReact(entry.key),
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: entry.value.contains(client.userId)
                                  ? palette.primary.withValues(alpha: 0.25)
                                  : palette.chipBackground,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('${entry.key} ${entry.value.length}'),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Color foreground, Color meta) {
    switch (item.kind) {
      case MatrixItemKind.redacted:
        return Text(
          'Message deleted',
          style: TextStyle(fontStyle: FontStyle.italic, color: meta),
        );
      case MatrixItemKind.undecryptable:
        return Text(
          'Unable to decrypt this message yet',
          style: TextStyle(fontStyle: FontStyle.italic, color: meta),
        );
      case MatrixItemKind.image when item.media != null:
        return _MatrixImage(client: client, item: item);
      case MatrixItemKind.file || MatrixItemKind.audio || MatrixItemKind.video
          when item.media != null:
        return _MatrixFile(client: client, item: item, color: foreground);
      case MatrixItemKind.emote:
        return SelectableText(
          '* ${_shortName(item.sender)} ${item.body}',
          style: TextStyle(color: foreground, fontStyle: FontStyle.italic),
        );
      case MatrixItemKind.unsupported:
        return Text(
          item.body.isEmpty ? 'Unsupported message' : item.body,
          style: TextStyle(color: meta),
        );
      default:
        return SelectableText(item.body, style: TextStyle(color: foreground));
    }
  }
}

/// Decrypted media, cached inside the login's own store (private to the
/// user, removed with the store at sign-out) and keyed by the reference.
Future<File> _cachedMedia(
  MatrixClientService client,
  Map<String, dynamic> media, {
  int? width,
  int? height,
  String suffix = '',
}) async {
  final key = hashes.sha256
      .convert('$media|$width|$height'.codeUnits)
      .toString()
      .substring(0, 32);
  final directory = await client.mediaCacheDirectory();
  if (directory == null) throw StateError('Not signed in to Matrix.');
  if (!Platform.isWindows && !Platform.isAndroid) {
    await Process.run('chmod', ['700', directory.path]);
  }
  final file = File('${directory.path}/$key$suffix');
  if (!await file.exists()) {
    await client.download(media, file.path, width: width, height: height);
  }
  return file;
}

class _MatrixImage extends StatefulWidget {
  const _MatrixImage({required this.client, required this.item});
  final MatrixClientService client;
  final MatrixTimelineItem item;

  @override
  State<_MatrixImage> createState() => _MatrixImageState();
}

class _MatrixImageState extends State<_MatrixImage> {
  late final Future<File> _file = _cachedMedia(
    widget.client,
    widget.item.media!,
    width: 640,
    height: 640,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: _file,
    builder: (context, snapshot) {
      final file = snapshot.data;
      if (snapshot.hasError) {
        return Text('Image unavailable: ${snapshot.error}');
      }
      if (file == null) {
        return const SizedBox(
          width: 220,
          height: 160,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360, maxWidth: 480),
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Text(widget.item.body),
          ),
        ),
      );
    },
  );
}

class _MatrixFile extends StatefulWidget {
  const _MatrixFile({
    required this.client,
    required this.item,
    required this.color,
  });
  final MatrixClientService client;
  final MatrixTimelineItem item;
  final Color color;

  @override
  State<_MatrixFile> createState() => _MatrixFileState();
}

class _MatrixFileState extends State<_MatrixFile> {
  String? _savedPath;
  bool _busy = false;

  Future<void> _download() async {
    setState(() => _busy = true);
    try {
      final name = (widget.item.fileName ?? widget.item.body).replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );
      final directory =
          await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final target = File('${directory.path}/$name');
      await widget.client.download(widget.item.media!, target.path);
      if (mounted) setState(() => _savedPath = target.path);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.item.sizeBytes;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(switch (widget.item.kind) {
          MatrixItemKind.audio => Icons.audiotrack,
          MatrixItemKind.video => Icons.movie_outlined,
          _ => Icons.insert_drive_file_outlined,
        }, color: widget.color),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.fileName ?? widget.item.body,
                style: TextStyle(color: widget.color),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _savedPath ??
                    (size == null
                        ? 'File'
                        : '${(size / 1024).toStringAsFixed(size < 10240 ? 1 : 0)} KiB'),
                style: TextStyle(fontSize: 11, color: widget.color),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Download',
          onPressed: _busy || _savedPath != null ? null : _download,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _savedPath != null ? Icons.check : Icons.download,
                  color: widget.color,
                ),
        ),
      ],
    );
  }
}
