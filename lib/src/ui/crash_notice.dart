import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../crash_catcher.dart';

/// "Conest closed unexpectedly last time", once, at the top of the app,
/// with the details a bug report needs.
void showCrashNotice({
  required ScaffoldMessengerState messenger,
  required CrashCatcher crashes,
  required BuildContext? Function() dialogContext,
}) {
  final report = crashes.previousRun;
  if (!report.crashed) return;
  void dismiss() {
    crashes.dismissPrevious();
    messenger.hideCurrentMaterialBanner();
  }

  messenger.showMaterialBanner(
    MaterialBanner(
      key: const ValueKey('crash-notice'),
      leading: const Icon(Icons.report_problem_outlined),
      content: const Text(
        'Conest closed unexpectedly last time. The details stay on this '
        'device; you can copy them into a bug report.',
      ),
      actions: [
        TextButton(
          onPressed: () {
            final context = dialogContext();
            if (context == null) return;
            showDialog<void>(
              context: context,
              builder: (context) => CrashReportDialog(report: report),
            );
          },
          child: const Text('Details'),
        ),
        TextButton(onPressed: dismiss, child: const Text('Dismiss')),
      ],
    ),
  );
}

class CrashReportDialog extends StatelessWidget {
  const CrashReportDialog({super.key, required this.report});

  final CrashReport report;

  @override
  Widget build(BuildContext context) {
    final text = report.format();
    return AlertDialog(
      title: const Text('What happened'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
