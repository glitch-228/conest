import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../crash_catcher.dart';
import '../app_locales.dart';

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
      content: Builder(
        builder: (context) => Text(l10nOf(context).crashNoticeBody),
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
          child: Builder(
            builder: (context) => Text(l10nOf(context).crashNoticeDetails),
          ),
        ),
        TextButton(
          onPressed: dismiss,
          child: Builder(
            builder: (context) => Text(l10nOf(context).crashNoticeDismiss),
          ),
        ),
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
      title: Text(l10nOf(context).crashReportTitle),
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
          child: Text(l10nOf(context).crashReportCopy),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).crashReportClose),
        ),
      ],
    );
  }
}
