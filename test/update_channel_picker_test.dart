import 'dart:async';

import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/src/build_info.dart';
import 'package:conest/src/crash_catcher.dart';
import 'package:conest/src/problem_report.dart';
import 'package:conest/src/ui/crash_notice.dart';
import 'package:conest/src/ui/report_problem.dart';
import 'package:conest/src/ui/update_channel_picker.dart';
import 'package:conest/src/update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ConestBuildInfo _info(UpdateChannel channel) => ConestBuildInfo(
  appName: 'Conest',
  packageName: 'dev.conest.conest',
  version: '0.4.3',
  buildNumber: '306201',
  channel: channel,
  isDebugBuild: false,
  buildTag: 'v0.4.3-canary.20261103.1',
);

class _FakeUpdates extends UpdateService {
  _FakeUpdates(this.channel)
    : super(
        buildInfo: _info(UpdateChannel.stable),
        automaticStartupChecksEnabled: false,
      );

  UpdateChannel channel;
  bool waiting = false;
  bool checking = false;
  final requested = <UpdateChannel>[];

  @override
  UpdateChannel get updateChannel => channel;

  @override
  bool get waitingForNewerThanInstalled => waiting;

  @override
  bool get isChecking => checking;

  @override
  Future<void> setUpdateChannel(UpdateChannel next) async {
    requested.add(next);
    channel = next;
    notifyListeners();
  }
}

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  Widget picker(_FakeUpdates service) => _app(
    ListenableBuilder(
      listenable: service,
      builder: (context, _) => UpdateChannelPicker(updateService: service),
    ),
  );

  testWidgets('three choices with an explanation each, the current selected', (
    tester,
  ) async {
    final service = _FakeUpdates(UpdateChannel.nightly);
    addTearDown(service.dispose);
    await tester.pumpWidget(picker(service));
    expect(find.text('Stable'), findsOneWidget);
    expect(find.text('Nightly'), findsOneWidget);
    expect(find.text('Canary'), findsOneWidget);
    expect(find.textContaining('safest choice'), findsOneWidget);
    expect(find.textContaining('May break'), findsOneWidget);
    RadioListTile<UpdateChannel> tile(UpdateChannel c) =>
        tester.widget<RadioListTile<UpdateChannel>>(
          find.byKey(ValueKey('update-channel-${c.label}')),
        );
    expect(tile(UpdateChannel.nightly).value, UpdateChannel.nightly);
    expect(find.byType(RadioGroup<UpdateChannel>), findsOneWidget);
    expect(
      tester
          .widget<RadioGroup<UpdateChannel>>(
            find.byType(RadioGroup<UpdateChannel>),
          )
          .groupValue,
      UpdateChannel.nightly,
    );
  });

  testWidgets('going down or to stable switches at once', (tester) async {
    final service = _FakeUpdates(UpdateChannel.nightly);
    addTearDown(service.dispose);
    await tester.pumpWidget(picker(service));
    await tester.tap(find.byKey(const ValueKey('update-channel-stable')));
    await tester.pump();
    expect(service.requested, [UpdateChannel.stable]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('canary asks first; cancelling changes nothing', (tester) async {
    final service = _FakeUpdates(UpdateChannel.stable);
    addTearDown(service.dispose);
    await tester.pumpWidget(picker(service));
    await tester.tap(find.byKey(const ValueKey('update-channel-canary')));
    await tester.pumpAndSettle();
    expect(find.text('Switch to canary?'), findsOneWidget);
    expect(find.textContaining('does not go back'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('update-channel-confirm-cancel')),
    );
    await tester.pumpAndSettle();
    expect(service.requested, isEmpty);
    expect(service.updateChannel, UpdateChannel.stable);

    await tester.tap(find.byKey(const ValueKey('update-channel-canary')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('update-channel-confirm-switch')),
    );
    await tester.pumpAndSettle();
    expect(service.requested, [UpdateChannel.canary]);
  });

  testWidgets('nothing can be chosen while a check runs', (tester) async {
    final service = _FakeUpdates(UpdateChannel.stable)..checking = true;
    addTearDown(service.dispose);
    await tester.pumpWidget(picker(service));
    await tester.tap(find.byKey(const ValueKey('update-channel-nightly')));
    await tester.pump();
    expect(service.requested, isEmpty);
  });

  testWidgets('says so when the build waits for a newer release', (
    tester,
  ) async {
    final service = _FakeUpdates(UpdateChannel.nightly);
    addTearDown(service.dispose);
    await tester.pumpWidget(picker(service));
    expect(find.byKey(const ValueKey('update-channel-waiting')), findsNothing);
    service
      ..waiting = true
      ..notifyListeners();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('update-channel-waiting')),
      findsOneWidget,
    );
    expect(find.textContaining('stays on it'), findsOneWidget);
  });

  testWidgets('the canary banner shows on canary builds only', (tester) async {
    for (final channel in UpdateChannel.values) {
      await tester.pumpWidget(_app(CanaryBanner(buildInfo: _info(channel))));
      expect(
        find.byKey(const ValueKey('canary-banner')),
        channel == UpdateChannel.canary ? findsOneWidget : findsNothing,
        reason: channel.label,
      );
    }
    await tester.pumpWidget(
      _app(CanaryBanner(buildInfo: _info(UpdateChannel.canary))),
    );
    expect(find.text('Canary: new features, may break'), findsOneWidget);
  });

  group('Report a problem', () {
    final clipboard = <String>[];
    setUp(() {
      clipboard.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('shows the report once built, and copies exactly that text', (
      tester,
    ) async {
      final done = Completer<String>();
      ProblemReportInputs? seen;
      final crashes = CrashCatcher(now: () => DateTime.utc(2026, 11, 3))
        ..record('zone', 'boom', null);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ReportProblemScreen(
            buildInfo: _info(UpdateChannel.canary),
            updateChannel: 'canary',
            crashes: crashes,
            build: (inputs) {
              seen = inputs;
              return done.future;
            },
          ),
        ),
      );
      expect(find.text('Preparing the report…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('report-problem-copy')),
            )
            .onPressed,
        isNull,
      );
      done.complete('Conest problem report\nChannel: canary');
      await tester.pumpAndSettle();
      expect(find.text('Channel: canary'), findsOneWidget);
      expect(
        find.textContaining('Read it before you share it'),
        findsOneWidget,
      );
      expect(seen!.channel, 'canary');
      expect(seen!.crashes.single.text, 'boom');
      expect(seen!.transportsAvailable, isFalse);
      await tester.tap(find.byKey(const ValueKey('report-problem-copy')));
      await tester.pump();
      expect(clipboard, ['Conest problem report\nChannel: canary']);
    });

    testWidgets('the crash dialog offers it only when it can open it', (
      tester,
    ) async {
      final report = CrashReport([
        CrashRecord(
          at: DateTime.utc(2026, 11, 3),
          kind: 'exit',
          text: 'closed',
        ),
      ]);
      var opened = 0;
      await tester.pumpWidget(
        _app(CrashReportDialog(report: report, onReport: (_) => opened++)),
      );
      await tester.tap(find.byKey(const ValueKey('crash-report-problem')));
      expect(opened, 1);
      await tester.pumpWidget(_app(CrashReportDialog(report: report)));
      expect(find.byKey(const ValueKey('crash-report-problem')), findsNothing);
    });
  });
}
