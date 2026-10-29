import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../link/link_archive.dart';
import '../messenger_controller.dart';
import '../models.dart';

/// Settings → Devices → "This device's old chats": the chats this device
/// gave up when it joined an account with "Replace". Read only; the only way
/// out of the vault is the explicit export, which warns first.
class LinkArchiveScreen extends StatefulWidget {
  const LinkArchiveScreen({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<LinkArchiveScreen> createState() => _LinkArchiveScreenState();
}

class _LinkArchiveScreenState extends State<LinkArchiveScreen> {
  String _date(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _export(LinkArchive archive) async {
    final l10n = l10nOf(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.linkArchiveExportWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('archive-export-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.linkArchiveExport),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      final bytes = widget.controller.exportLinkArchive(archive.id);
      final path = await FilePicker.saveFile(
        dialogTitle: l10n.linkArchiveExport,
        fileName:
            'conest-old-chats-${archive.createdAt.millisecondsSinceEpoch}'
            '.json',
        bytes: bytes,
      );
      if (path == null) return;
      if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
        await File(path).writeAsBytes(bytes);
      }
      widget.controller.setStatus(l10n.linkArchiveSaved(path));
    } catch (error) {
      widget.controller.setStatus('$error');
    }
  }

  Future<void> _delete(LinkArchive archive) async {
    final l10n = l10nOf(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.linkArchiveDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('archive-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.linkArchiveDelete),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await widget.controller.deleteLinkArchive(archive.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final archives = widget.controller.linkArchives.reversed.toList();
        return Scaffold(
          appBar: AppBar(title: Text(l10n.devicesOldChats)),
          body: archives.isEmpty
              ? Center(child: Text(l10n.linkArchiveEmpty))
              : ListView(
                  children: [
                    for (final archive in archives)
                      ExpansionTile(
                        key: ValueKey('archive-${archive.id}'),
                        title: Text(_date(archive.createdAt)),
                        subtitle: Text(
                          l10n.linkArchiveSummary(
                            archive.conversations.length,
                            archive.messageCount,
                          ),
                        ),
                        children: [
                          for (final chat in archive.conversations)
                            ListTile(
                              key: ValueKey('archive-chat-${chat.id}'),
                              title: Text(archive.nameOf(chat.peerDeviceId)),
                              subtitle: Text('${chat.messages.length}'),
                              onTap: () => Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => _ArchiveChatPage(
                                    title: archive.nameOf(chat.peerDeviceId),
                                    messages: chat.messages,
                                    date: _date,
                                  ),
                                ),
                              ),
                            ),
                          OverflowBar(
                            children: [
                              TextButton.icon(
                                key: ValueKey('archive-export-${archive.id}'),
                                onPressed: () => _export(archive),
                                icon: const Icon(Icons.save_alt),
                                label: Text(l10n.linkArchiveExport),
                              ),
                              TextButton.icon(
                                onPressed: () => _delete(archive),
                                icon: const Icon(Icons.delete_outline),
                                label: Text(l10n.linkArchiveDelete),
                              ),
                            ],
                          ),
                        ],
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _ArchiveChatPage extends StatelessWidget {
  const _ArchiveChatPage({
    required this.title,
    required this.messages,
    required this.date,
  });

  final String title;
  final List<ChatMessage> messages;
  final String Function(DateTime) date;

  @override
  Widget build(BuildContext context) {
    final sorted = [...messages]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView.builder(
        itemCount: sorted.length,
        itemBuilder: (context, index) {
          final message = sorted[index];
          final file = message.attachment?.fileName;
          return ListTile(
            dense: true,
            title: Text(
              [if (message.body.isNotEmpty) message.body, ?file].join('\n'),
            ),
            subtitle: Text(date(message.createdAt)),
            trailing: Icon(
              message.outbound ? Icons.call_made : Icons.call_received,
              size: 16,
            ),
          );
        },
      ),
    );
  }
}
