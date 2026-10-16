import '../app_locales.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../messenger_controller.dart';

/// Settings → Error history (debug and nightly builds): what went wrong,
/// kept across restarts, to copy or save for a bug report.
class ErrorHistoryScreen extends StatefulWidget {
  const ErrorHistoryScreen({super.key, required this.controller});

  final MessengerController controller;

  static Future<void> show(
    BuildContext context,
    MessengerController controller,
  ) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ErrorHistoryScreen(controller: controller),
    ),
  );

  @override
  State<ErrorHistoryScreen> createState() => _ErrorHistoryScreenState();
}

class _ErrorHistoryScreenState extends State<ErrorHistoryScreen> {
  final _filter = TextEditingController();
  bool _errorsOnly = true;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  String get _query => _filter.text.trim().toLowerCase();

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: widget.controller.exportErrorHistory(filter: _query)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10nOf(context).uiCopiedTheErrorHistoryCE02E2)),
    );
  }

  Future<void> _save() async {
    final bytes = utf8.encode(
      widget.controller.exportErrorHistory(filter: _query),
    );
    final name =
        'conest-errors-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.txt';
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: l10nOf(context).uiSaveTheErrorHistory0B3413,
        fileName: name,
        bytes: bytes,
      );
      if (path == null) return;
      if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
        await File(path).writeAsBytes(bytes);
      }
      widget.controller.setStatus('Saved the error history to $path.');
    } catch (error) {
      widget.controller.setStatus('Saving the error history failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10nOf(context).uiErrorHistory25AFF8),
        actions: [
          IconButton(
            key: const ValueKey('error-history-copy'),
            tooltip: l10nOf(context).uiCopyAF74F7,
            icon: const Icon(Icons.copy),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: l10nOf(context).uiSaveToAFile5BB648,
            icon: const Icon(Icons.save_alt),
            onPressed: _save,
          ),
          IconButton(
            tooltip: l10nOf(context).uiClear719EA3,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => widget.controller.clearErrorHistory(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final query = _query;
          final entries = widget.controller.errorHistoryEntries.reversed
              .where(
                (entry) =>
                    (!_errorsOnly || entry.kind != 'log') &&
                    (query.isEmpty ||
                        entry.text.toLowerCase().contains(query) ||
                        entry.kind.contains(query)),
              )
              .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  key: const ValueKey('error-history-filter'),
                  controller: _filter,
                  decoration: InputDecoration(
                    labelText: l10nOf(context).uiFilterD7DECF,
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SwitchListTile(
                key: const ValueKey('error-history-errors-only'),
                title: Text(l10nOf(context).uiErrorsOnlyHideTheDebugECA1DD),
                value: _errorsOnly,
                onChanged: (value) => setState(() => _errorsOnly = value),
              ),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(l10nOf(context).uiNothingRecordedA27006),
                      )
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return ListTile(
                            dense: true,
                            title: SelectableText(entry.text),
                            subtitle: Text(
                              "${(entry.at.toLocal())}  ·  ${(entry.kind)}",
                              style: theme.textTheme.bodySmall,
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
