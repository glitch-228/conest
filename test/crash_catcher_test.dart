import 'dart:io';

import 'package:conest/src/crash_catcher.dart';
import 'package:conest/src/ui/crash_notice.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('conest_crash_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('errors before the folder is known are kept for it', () async {
    final crashes = CrashCatcher();
    crashes.record('zone', 'early trouble', StackTrace.current);
    await crashes.attach(root, markRunning: true);
    crashes.markStopped();

    final next = CrashCatcher();
    await next.attach(root, markRunning: true);
    expect(next.previousRun.records.single.text, contains('early trouble'));
    expect(next.previousRun.crashed, isFalse);
  });

  test('a run that never closed is reported as a crash', () async {
    final first = CrashCatcher();
    await first.attach(root, markRunning: true);
    // ... and the process ends here, without markStopped.

    final next = CrashCatcher();
    await next.attach(root, markRunning: true);
    expect(next.previousRun.crashed, isTrue);
    expect(next.previousRun.records.single.kind, 'exit');
  });

  test('an update replacing the app is no crash', () async {
    // The updater (desktop) or the installer (Android) ends the app.
    final first = CrashCatcher();
    await first.attach(root, markRunning: true, build: '0.4.0+60@aaa');
    first.markUpdating();
    // The same build (an install the user cancelled, then a restart) is no
    // crash either.
    final next = CrashCatcher();
    await next.attach(root, markRunning: true, build: '0.4.0+60@aaa');
    expect(next.previousRun.isEmpty, isTrue);
  });

  test('a newer build finding the old one still running is no crash', () {
    // The process was ended by the update before it could say so.
    return () async {
      final first = CrashCatcher();
      await first.attach(root, markRunning: true, build: '0.4.0+60@aaa');
      final next = CrashCatcher();
      await next.attach(root, markRunning: true, build: '0.4.0+61@bbb');
      expect(next.previousRun.isEmpty, isTrue);
      // The same build ending that way is reported, as before.
      final third = CrashCatcher();
      await third.attach(root, markRunning: true, build: '0.4.0+61@bbb');
      expect(third.previousRun.crashed, isTrue);
    }();
  });

  test('a marker from an older version (only a time) still counts', () async {
    Directory(root.path).createSync(recursive: true);
    File(
      p.join(root.path, CrashCatcher.markerName),
    ).writeAsStringSync('2026-10-19T10:00:00.000Z');
    final next = CrashCatcher();
    await next.attach(root, markRunning: true, build: '0.4.0+61@bbb');
    expect(next.previousRun.crashed, isTrue);
    expect(next.previousRun.records.single.at, DateTime.utc(2026, 10, 19, 10));
  });

  test('an older version updated since its marker is no crash', () async {
    // Updating from a version whose marker names no build: the app was
    // installed after that run began.
    Directory(root.path).createSync(recursive: true);
    File(
      p.join(root.path, CrashCatcher.markerName),
    ).writeAsStringSync('2026-10-19T10:00:00.000Z');
    final next = CrashCatcher();
    await next.attach(
      root,
      markRunning: true,
      build: '0.4.0+61@bbb',
      installedAt: DateTime.utc(2026, 10, 20, 9),
    );
    expect(next.previousRun.crashed, isFalse);
  });

  test('installed before the run that did not close: still a crash', () async {
    Directory(root.path).createSync(recursive: true);
    File(
      p.join(root.path, CrashCatcher.markerName),
    ).writeAsStringSync('2026-10-19T10:00:00.000Z');
    final next = CrashCatcher();
    await next.attach(
      root,
      markRunning: true,
      build: '0.4.0+61@bbb',
      installedAt: DateTime.utc(2026, 10, 18),
    );
    expect(next.previousRun.crashed, isTrue);
  });

  test('a run that closed properly leaves nothing to report', () async {
    final first = CrashCatcher();
    await first.attach(root, markRunning: true);
    first.markStopped();

    final next = CrashCatcher();
    await next.attach(root, markRunning: true);
    expect(next.previousRun.isEmpty, isTrue);
  });

  test('what the native library wrote is reported once', () async {
    File(
      p.join(root.path, CrashCatcher.nativeName),
    ).writeAsStringSync('Rust panic on thread \'iroh\': boom\n\n');
    final crashes = CrashCatcher();
    await crashes.attach(root, markRunning: false);
    expect(crashes.previousRun.crashed, isTrue);
    expect(crashes.previousRun.records.single.kind, 'native');
    expect(crashes.previousRun.records.single.text, contains('boom'));
    expect(
      File(p.join(root.path, CrashCatcher.nativeName)).existsSync(),
      false,
    );
  });

  test('reports stay until dismissed, then are gone', () async {
    final first = CrashCatcher();
    await first.attach(root, markRunning: true);
    first.record('uncaught', 'first run', null);

    final second = CrashCatcher();
    await second.attach(root, markRunning: true);
    second.record('uncaught', 'second run', null);

    final third = CrashCatcher();
    await third.attach(root, markRunning: true);
    final texts = third.previousRun.records.map((r) => r.text).join('|');
    expect(texts, allOf(contains('first run'), contains('second run')));
    third.dismissPrevious();
    third.markStopped();

    final fourth = CrashCatcher();
    await fourth.attach(root, markRunning: true);
    expect(fourth.previousRun.isEmpty, isTrue);
  });

  test('records are bounded in size', () async {
    final crashes = CrashCatcher(maxBytes: 4096, maxTextChars: 500);
    await crashes.attach(root, markRunning: false);
    for (var i = 0; i < 200; i++) {
      crashes.record('uncaught', 'x' * 2000, null);
    }
    final log = File(p.join(root.path, CrashCatcher.logName));
    expect(log.lengthSync(), lessThanOrEqualTo(4096 + 600));
    final next = CrashCatcher(maxBytes: 4096, maxTextChars: 500);
    await next.attach(root, markRunning: false);
    expect(next.previousRun.records, isNotEmpty);
    expect(next.previousRun.records.every((r) => r.text.length <= 501), isTrue);
    expect(
      File(p.join(root.path, CrashCatcher.previousName)).lengthSync(),
      lessThanOrEqualTo(4096),
    );
  });

  test('the error history gets earlier runs and this one', () async {
    final first = CrashCatcher();
    await first.attach(root, markRunning: true);
    final next = CrashCatcher();
    await next.attach(root, markRunning: true);
    next.record('zone', 'now', null);
    final seen = <String>[];
    next.connect((kind, text) => seen.add(kind));
    next.record('flutter', 'later', null);
    expect(seen, ['exit', 'zone', 'flutter']);
  });

  test('Flutter and platform errors are caught once installed', () async {
    final flutterHandler = FlutterError.onError;
    final platformHandler = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = flutterHandler;
      PlatformDispatcher.instance.onError = platformHandler;
    });
    // What install() finds and passes errors on to: quiet here, instead of
    // the test harness's reporting.
    FlutterError.onError = (details) {};
    final crashes = CrashCatcher();
    await crashes.attach(root, markRunning: false);
    crashes.install();
    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('broken build')),
    );
    final caught = PlatformDispatcher.instance.onError!(
      StateError('lost future'),
      StackTrace.current,
    );
    expect(caught, isTrue);
    final log = File(
      p.join(root.path, CrashCatcher.logName),
    ).readAsStringSync();
    expect(log, allOf(contains('lost future'), contains('broken build')));
  });

  testWidgets('the notice shows after a crash and goes when dismissed', (
    tester,
  ) async {
    final crashes = CrashCatcher();
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.runAsync(() async {
      final first = CrashCatcher();
      await first.attach(root, markRunning: true);
      await crashes.attach(root, markRunning: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messengerKey,
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    showCrashNotice(
      messenger: messengerKey.currentState!,
      crashes: crashes,
      dialogContext: () => navigatorKey.currentContext,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('crash-notice')), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('closed without finishing'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('crash-notice')), findsNothing);
    expect(crashes.previousRun.isEmpty, isTrue);
  });
}
