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
    this.onOpen,
    this.error,
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
  final VoidCallback? onOpen;
  final String? error;

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
        Text(filename, style: Theme.of(context).textTheme.titleSmall),
        Text(_bytes(total)),
        Text(status),
        if (!needsAcceptance && !complete) ...[
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: progress,
            semanticsLabel: 'Verified download progress',
            semanticsValue: '${(progress * 100).floor()}%',
          ),
          Text('${_bytes(verified)} of ${_bytes(total)} verified'),
        ],
        if (!needsAcceptance &&
            state == GroupFileDownloadState.failed &&
            error != null)
          Text(error!),
        if (sharing) const Text('Sharing with group'),
        Wrap(
          spacing: 8,
          children: [
            if (needsAcceptance)
              TextButton(onPressed: onDownload, child: const Text('Download'))
            else if (complete)
              TextButton(onPressed: onOpen, child: const Text('Open'))
            else if (state == GroupFileDownloadState.paused)
              TextButton(onPressed: onResume, child: const Text('Resume'))
            else if (state == GroupFileDownloadState.failed)
              TextButton(onPressed: onResume, child: const Text('Retry'))
            else
              TextButton(onPressed: onPause, child: const Text('Pause')),
            if (state == GroupFileDownloadState.failed &&
                error?.contains('free-space reserve') == true &&
                onDownloadAnyway != null)
              TextButton(
                onPressed: onDownloadAnyway,
                child: const Text('Download anyway'),
              ),
            if (sharing)
              TextButton(
                onPressed: onStopSharing,
                child: const Text('Stop sharing'),
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
