import 'app_locales.dart';
import 'dart:io';

import 'package:flutter/material.dart';

import 'group_file_download.dart';

/// A group attachment's local, verified download and sharing state.
class GroupFileTile extends StatelessWidget {
  const GroupFileTile({
    super.key,
    required this.filename,
    required this.size,
    required this.verifiedBytes,
    required this.state,
    required this.sharing,
    this.accepted = false,
    this.onDownload,
    this.onDownloadAnyway,
    this.onPause,
    this.onResume,
    this.onStopSharing,
    this.onEvict,
    this.onOpen,
    this.playbackControls,
    this.error,
    this.previewPath,
  });

  final String filename;
  final int size;
  final int verifiedBytes;
  final GroupFileDownloadState state;
  final bool sharing;
  final bool accepted;
  final VoidCallback? onDownload;
  final VoidCallback? onDownloadAnyway;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onStopSharing;
  final VoidCallback? onEvict;
  final VoidCallback? onOpen;
  final Widget? playbackControls;
  final String? error;

  /// A downloaded image shown above the file name.
  final String? previewPath;

  @override
  Widget build(BuildContext context) {
    final complete = state == GroupFileDownloadState.complete;
    final needsAcceptance = !accepted && !complete;
    final total = size < 0 ? 0 : size;
    final verified = verifiedBytes.clamp(0, total);
    final progress = total == 0 ? (complete ? 1.0 : 0.0) : verified / total;
    final status = needsAcceptance
        ? 'Download this file to your device'
        : switch (state) {
            GroupFileDownloadState.checking => 'Checking downloaded data',
            GroupFileDownloadState.waiting =>
              'Waiting for someone with this file',
            GroupFileDownloadState.downloading => 'Downloading',
            GroupFileDownloadState.paused => 'Download paused',
            GroupFileDownloadState.complete => 'Downloaded',
            GroupFileDownloadState.failed => 'Download failed',
          };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (complete && previewPath != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: onOpen,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: Image.file(
                    File(previewPath!),
                    fit: BoxFit.cover,
                    cacheWidth: 720,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        Text(filename, style: Theme.of(context).textTheme.titleSmall),
        Text(_bytes(total)),
        Text(status),
        if (!needsAcceptance && !complete) ...[
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: progress,
            semanticsLabel: l10nOf(context).uiVerifiedDownloadProgressBED7C2,
            semanticsValue: '${(progress * 100).floor()}%',
          ),
          Text(
            l10nOf(context).uiValueOfValueVerified63B11D(
              (_bytes(verified)).toString(),
              (_bytes(total)).toString(),
            ),
          ),
        ],
        if (!needsAcceptance &&
            state == GroupFileDownloadState.failed &&
            error != null)
          Text(error!),
        if (sharing) Text(l10nOf(context).uiSharingWithGroup2AED71),
        if (complete && playbackControls != null) playbackControls!,
        Wrap(
          spacing: 8,
          children: [
            if (needsAcceptance)
              TextButton(
                onPressed: onDownload,
                child: Text(l10nOf(context).uiDownloadA479C9),
              )
            else if (complete)
              TextButton(
                onPressed: onOpen,
                child: Text(l10nOf(context).uiOpenCF9B77),
              )
            else if (state == GroupFileDownloadState.paused)
              TextButton(
                onPressed: onResume,
                child: Text(l10nOf(context).uiResumeB3BD0B),
              )
            else if (state == GroupFileDownloadState.failed)
              TextButton(
                onPressed: onResume,
                child: Text(l10nOf(context).uiRetry9F5CD8),
              )
            else
              TextButton(
                onPressed: onPause,
                child: Text(l10nOf(context).uiPause781961),
              ),
            if (state == GroupFileDownloadState.failed &&
                error?.contains('free-space reserve') == true &&
                onDownloadAnyway != null)
              TextButton(
                onPressed: onDownloadAnyway,
                child: Text(l10nOf(context).uiDownloadAnyway42859F),
              ),
            if (sharing)
              TextButton(
                onPressed: onStopSharing,
                child: Text(l10nOf(context).uiStopSharing0E45AE),
              ),
            if (onEvict != null && (verified > 0 || complete))
              TextButton(
                onPressed: onEvict,
                child: Text(l10nOf(context).uiRemoveLocalCopy80FA01),
              ),
          ],
        ),
      ],
    );
  }

  static String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
