/// Automatic tests a debug build runs when started for them (Q6), so a
/// device can be tested from a shell over adb or ssh:
///
///   conest --debug-run=routes [--debug-report=PATH] [--debug-wait=20]
///          [--debug-exit]
///   adb shell am start -n dev.conest.conest.debug/dev.conest.conest.MainActivity \
///       --es conestDebugRun routes
///
/// It waits for the transports to come up, runs a full transport test
/// with every contact, and writes one JSON report (with the error
/// history) to PATH, or next to the app's files.
library;

import 'dart:convert';
import 'dart:io';

import 'messenger_controller.dart';

class DebugRunRequest {
  const DebugRunRequest({
    required this.what,
    this.reportPath,
    this.exitAfter = false,
    this.wait = const Duration(seconds: 20),
  });

  /// 'routes' (the only kind so far).
  final String what;
  final String? reportPath;
  final bool exitAfter;
  final Duration wait;

  static const Set<String> kinds = {'routes'};

  /// From command-line arguments; null when none asks for a run.
  static DebugRunRequest? fromArgs(List<String> args) {
    String? value(String name) {
      for (final arg in args) {
        if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
      }
      return null;
    }

    final what = value('debug-run');
    if (what == null || !kinds.contains(what)) return null;
    final seconds = int.tryParse(value('debug-wait') ?? '');
    return DebugRunRequest(
      what: what,
      reportPath: value('debug-report'),
      exitAfter: args.contains('--debug-exit'),
      wait: seconds != null && seconds >= 0 && seconds <= 600
          ? Duration(seconds: seconds)
          : const Duration(seconds: 20),
    );
  }

  /// From the Android intent extra (`conestDebugRun`).
  static DebugRunRequest? fromExtra(String? extra) =>
      extra != null && kinds.contains(extra.trim())
      ? DebugRunRequest(what: extra.trim())
      : null;
}

/// Runs [request] on [controller] (already set up) and writes the report.
/// Returns where it was written.
Future<String> runDebugRequest(
  MessengerController controller,
  DebugRunRequest request, {
  required Future<String> Function() defaultReportPath,
}) async {
  final startedAt = DateTime.now().toUtc();
  await Future<void>.delayed(request.wait);
  final results = <Map<String, Object?>>[];
  for (final contact in controller.contacts) {
    if (!contact.canSendOutbound ||
        contact.deviceId == controller.identity?.deviceId) {
      continue;
    }
    try {
      final report = await controller.runTransportExchangeTest(contact);
      results.add({
        'contact': contact.alias,
        'deviceId': contact.deviceId,
        'report': report.toJson(),
        'text': report.toText(),
      });
    } catch (error) {
      results.add({
        'contact': contact.alias,
        'deviceId': contact.deviceId,
        'error': '$error',
      });
    }
  }
  final path = request.reportPath ?? await defaultReportPath();
  final report = {
    'kind': request.what,
    'build': controller.debugBuildId,
    'deviceId': controller.identity?.deviceId,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    'contacts': results,
    'errorHistory': controller.exportErrorHistory(),
  };
  final file = File(path);
  await file.parent.create(recursive: true);
  // Whole or not at all: a script waiting for the file never reads half.
  final temporary = File('$path.tmp');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  await temporary.rename(file.path);
  controller.recordError(
    'test',
    'Automatic ${request.what} run written to $path',
  );
  return path;
}
