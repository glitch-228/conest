import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../messenger_controller.dart';
import '../models.dart';

/// The shared attachment viewer with the file actions used by Delta bubbles.
class DeltaAttachmentCard extends StatelessWidget {
  const DeltaAttachmentCard({
    super.key,
    required this.controller,
    required this.descriptor,
    required this.child,
    required this.open,
    required this.save,
    required this.forward,
  });
  final MessengerController controller;
  final AttachmentDescriptor descriptor;
  final Widget child;
  final Future<void> Function() open;
  final Future<void> Function() save;
  final Future<void> Function() forward;

  @override
  Widget build(BuildContext context) {
    final available = controller.deltaAttachmentAvailableLocally(descriptor);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: child),
        PopupMenuButton<String>(
          tooltip: 'File actions',
          icon: const Icon(Icons.more_vert, size: 18),
          onSelected: (action) => unawaited(() async {
            try {
              if (!controller.deltaAttachmentAvailableLocally(descriptor)) {
                return;
              }
              switch (action) {
                case 'open':
                  await open();
                case 'save':
                  await save();
                case 'forward':
                  await forward();
              }
            } catch (error) {
              controller.setStatus('$error');
            }
          }()),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'open',
              enabled: available,
              child: const Text('Open'),
            ),
            PopupMenuItem(
              value: 'save',
              enabled: available,
              child: const Text('Save'),
            ),
            PopupMenuItem(
              value: 'forward',
              enabled: available,
              child: const Text('Forward'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Generic files use the same system handoff as Conest group files.
Future<void> openDeltaCachedFile(
  MessengerController controller,
  AttachmentDescriptor descriptor,
) async {
  final path = await controller.attachmentCachePathFor(descriptor.id);
  if (path == null) throw StateError('The file is not available locally.');
  if (Platform.isAndroid) {
    final saved = await controller.platformBridge.saveMediaFileToGallery(
      sourcePath: path,
      fileName: descriptor.fileName,
      mimeType: descriptor.mimeType,
      kind: 'other',
    );
    if (saved == null) {
      throw StateError('The Android file saver is unavailable.');
    }
    controller.setStatus('Saved ${descriptor.fileName}.');
  } else if (Platform.isLinux) {
    await Process.start('xdg-open', [path]);
  } else if (Platform.isMacOS) {
    await Process.start('open', [path]);
  } else if (Platform.isWindows) {
    await Process.start('cmd', ['/c', 'start', '', path]);
  } else {
    throw StateError('Opening files is unavailable on this platform.');
  }
}
