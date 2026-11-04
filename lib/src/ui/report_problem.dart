import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_locales.dart';
import '../build_info.dart';
import '../crash_catcher.dart';
import '../messenger_controller.dart';
import '../problem_report.dart';
import '../problem_report_sources.dart';

/// "Report a problem": builds the report once (off the main isolate), shows
/// it for reading, and lets the user copy it or save it to a file. Nothing is
/// sent anywhere.
class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({
    super.key,
    required this.buildInfo,
    required this.updateChannel,
    this.controller,
    this.crashes,
    this.build = buildProblemReportOffMain,
  });

  final ConestBuildInfo buildInfo;

  /// The channel updates are taken from, by name.
  final String updateChannel;

  /// Null before the vault is open (the crash notice at start).
  final MessengerController? controller;
  final CrashCatcher? crashes;

  /// The builder; replaced in tests.
  final Future<String> Function(ProblemReportInputs inputs) build;

  static Future<void> show(
    BuildContext context, {
    required ConestBuildInfo buildInfo,
    required String updateChannel,
    MessengerController? controller,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ReportProblemScreen(
        buildInfo: buildInfo,
        updateChannel: updateChannel,
        controller: controller,
      ),
    ),
  );

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  String? _text;
  List<String> _lines = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    final inputs = collectProblemReportInputs(
      buildInfo: widget.buildInfo,
      updateChannel: widget.updateChannel,
      crashes: widget.crashes ?? CrashCatcher.instance,
      controller: widget.controller,
    );
    widget
        .build(inputs)
        .then(
          (text) {
            if (!mounted) return;
            setState(() {
              _text = text;
              _lines = const LineSplitter().convert(text);
            });
          },
          onError: (Object error) {
            if (mounted) setState(() => _error = error);
          },
        );
  }

  Future<void> _copy() async {
    final text = _text;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10nOf(context).reportProblemCopied)),
    );
  }

  Future<void> _save() async {
    final text = _text;
    if (text == null) return;
    final bytes = utf8.encode(text);
    final name =
        'conest-report-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.txt';
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: l10nOf(context).reportProblemSaveTitle,
        fileName: name,
        bytes: bytes,
      );
      if (path == null) return;
      if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
        await File(path).writeAsBytes(bytes);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Saved the report to $path.')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Saving the report failed: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _text != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10nOf(context).reportProblemTitle),
        actions: [
          IconButton(
            key: const ValueKey('report-problem-copy'),
            tooltip: l10nOf(context).crashReportCopy,
            icon: const Icon(Icons.copy),
            onPressed: ready ? _copy : null,
          ),
          IconButton(
            key: const ValueKey('report-problem-save'),
            tooltip: l10nOf(context).uiSaveToAFile5BB648,
            icon: const Icon(Icons.save_alt),
            onPressed: ready ? _save : null,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10nOf(context).reportProblemNote,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text('$_error'))
                : !ready
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(l10nOf(context).reportProblemBuilding),
                      ],
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      key: const ValueKey('report-problem-text'),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _lines.length,
                      itemBuilder: (context, index) => Text(
                        _lines[index],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
