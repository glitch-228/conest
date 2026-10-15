import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../main.dart' show confirmSendingMetadata;
import '../conest_theme.dart';
import '../delta_chats.dart';
import '../email/delta_content.dart';
import '../media_picker_sheet.dart';
import '../messenger_controller.dart';
import '../voice_message_service.dart';

Future<void> interruptDeltaVoiceOnClose(
  VoiceMessageService service,
  String chatKey,
) async {
  if (service.previewDestinationKey == 'delta:$chatKey' &&
      (service.state == VoiceRecordingState.starting ||
          service.state == VoiceRecordingState.recording)) {
    await service.stopForInterruption();
  }
}

Widget? deltaListAvatar(MessengerController controller, String seed) {
  const prefix = 'deltaChat:';
  if (!seed.startsWith(prefix)) return null;
  final chat = controller.deltaChats.chats[seed.substring(prefix.length)];
  if (chat == null) return null;
  final bytes = chat.isGroup
      ? chat.avatar
      : controller.deltaChats.peers[chat.key]?.avatar;
  return bytes == null ? null : deltaChatAvatar(controller, chat, radius: 22);
}

Widget deltaChatAvatar(
  MessengerController controller,
  DeltaChat chat, {
  double radius = 20,
}) {
  final bytes = chat.isGroup
      ? chat.avatar
      : controller.deltaChats.peers[chat.key]?.avatar;
  return CircleAvatar(
    radius: radius,
    backgroundImage: bytes == null ? null : MemoryImage(bytes),
    child: bytes == null
        ? Icon(chat.isGroup ? Icons.group_outlined : Icons.person)
        : null,
  );
}

Future<void> sendDeltaFileAsking(
  BuildContext context,
  String fileName,
  Future<void> Function(bool keepMetadata) send,
) async {
  try {
    await send(false);
  } on FileMetadataException catch (error) {
    if (!context.mounted ||
        !await confirmSendingMetadata(
          context,
          fileName,
          partial: error.partial,
        )) {
      return;
    }
    await send(true);
  }
}

Future<void> pickDeltaFiles(
  BuildContext context,
  MessengerController controller,
  String chatKey, {
  bool photos = false,
  String caption = '',
}) async {
  Future<void> send(StagedAttachment source, String text) =>
      sendDeltaFileAsking(
        context,
        source.fileName,
        (keepMetadata) => controller.sendDeltaAttachment(
          chatKey,
          source,
          caption: text,
          keepMetadata: keepMetadata,
        ),
      );

  if (photos) {
    final result = await showMediaPickerSheet(
      context: context,
      palette: ConestPalette(brightness: Theme.of(context).brightness),
      maxBytes: DeltaLimits.fileBytes,
    );
    if (result == null || !context.mounted) return;
    if (!result.fallbackToFilePicker) {
      if (result.hasItems) {
        for (final item in result.items!.take(DeltaLimits.attachments)) {
          await send(
            StagedAttachment(
              id: UniqueKey().toString(),
              fileName: item.fileName,
              mimeType: item.mimeType,
              sizeBytes: item.sizeBytes,
              bytes: item.bytes,
              filePath: item.filePath,
              poster: item.poster,
            ),
            item.caption.isEmpty ? caption : item.caption,
          );
        }
      } else {
        await send(
          StagedAttachment(
            id: UniqueKey().toString(),
            fileName: result.fileName!,
            mimeType: result.mimeType!,
            sizeBytes: result.sizeBytes!,
            bytes: result.bytes,
            filePath: result.filePath,
          ),
          caption,
        );
      }
      return;
    }
  }
  final picked = await FilePicker.pickFiles(
    type: photos ? FileType.media : FileType.any,
    withData: false,
    allowMultiple: true,
  );
  if (picked == null || !context.mounted) return;
  if (picked.files.length > DeltaLimits.attachments) {
    throw ArgumentError('Choose at most 20 files.');
  }
  for (final file in picked.files) {
    if (file.size > DeltaLimits.fileBytes) {
      throw ArgumentError('Delta Chat files must be at most 21 MiB.');
    }
    await send(
      StagedAttachment(
        id: UniqueKey().toString(),
        fileName: file.name,
        mimeType: 'application/octet-stream',
        sizeBytes: file.size,
        filePath: file.path,
        bytes: file.bytes,
      ),
      caption,
    );
  }
}

class DeltaVoiceComposer extends StatelessWidget {
  const DeltaVoiceComposer({
    super.key,
    required this.controller,
    required this.chatKey,
    required this.enabled,
    required this.act,
  });
  final MessengerController controller;
  final String chatKey;
  final bool enabled;
  final Future<void> Function(Future<void> Function()) act;

  @override
  Widget build(BuildContext context) {
    final service = controller.voiceMessageService;
    return StreamBuilder<VoiceRecordingSnapshot>(
      stream: service.recordingSnapshots,
      initialData: service.recordingSnapshot,
      builder: (context, snapshot) {
        final value = snapshot.data!;
        final mine = value.destinationKey == 'delta:$chatKey';
        final preview = mine && service.preview != null;
        final recording = mine && service.isRecording;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (recording) Text('${value.elapsed.inSeconds}s'),
            if (preview) ...[
              IconButton(
                tooltip: 'Play voice message',
                icon: const Icon(Icons.play_circle_outline),
                onPressed: () => act(service.playPreview),
              ),
              IconButton(
                tooltip: 'Send voice message',
                icon: const Icon(Icons.send),
                onPressed: enabled
                    ? () => act(
                        () => controller.sendRecordedDeltaVoiceMessage(chatKey),
                      )
                    : null,
              ),
            ],
            if (recording || preview)
              IconButton(
                tooltip: 'Discard voice message',
                icon: const Icon(Icons.close),
                onPressed: () => act(service.cancel),
              ),
            if (!preview)
              IconButton(
                tooltip: recording ? 'Stop recording' : 'Record voice message',
                icon: Icon(
                  recording ? Icons.stop_circle_outlined : Icons.mic_none,
                ),
                onPressed:
                    !enabled ||
                        (service.state != VoiceRecordingState.idle &&
                            service.state != VoiceRecordingState.error &&
                            !recording)
                    ? null
                    : () => act(() async {
                        if (recording) {
                          await service.stop();
                        } else {
                          await service.start(destinationKey: 'delta:$chatKey');
                        }
                      }),
              ),
          ],
        );
      },
    );
  }
}

class DeltaMessageMenu extends StatelessWidget {
  const DeltaMessageMenu({
    super.key,
    required this.controller,
    required this.chat,
    required this.message,
    required this.act,
  });
  final MessengerController controller;
  final DeltaChat chat;
  final DeltaChatMessage message;
  final Future<void> Function(Future<void> Function()) act;

  Future<void> _react(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('React'),
        content: Wrap(
          spacing: 8,
          children: [
            for (final emoji in ['👍', '❤️', '😂', '😮', '😢', '🙏'])
              TextButton(
                onPressed: () => Navigator.pop(context, emoji),
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Remove'),
            ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await controller.reactDeltaMessage(chat.key, message.id, selected);
    }
  }

  Future<void> _edit(BuildContext context) async {
    final text = TextEditingController(text: message.text);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(controller: text, minLines: 1, maxLines: 6),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    text.dispose();
    if (result != null) {
      await controller.editDeltaMessage(chat.key, message.id, result);
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Message actions',
    icon: const Icon(Icons.more_horiz, size: 18),
    onSelected: (action) => unawaited(
      act(() async {
        switch (action) {
          case 'react':
            await _react(context);
          case 'edit':
            await _edit(context);
          case 'delete':
            await controller.deleteDeltaMessage(chat.key, message.id);
        }
      }),
    ),
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'react', child: Text('React')),
      if (message.outgoing) ...[
        if (message.text.isNotEmpty)
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete for everyone'),
        ),
      ],
    ],
  );
}
