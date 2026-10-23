import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/src/ui/battery_exemption.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<bool?> open(WidgetTester tester, String? maker) async {
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              popped = await showDialog<bool>(
                context: context,
                builder: (_) => BatteryExemptionDialog(manufacturer: maker),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  testWidgets('a Xiaomi is told the extra steps, a Pixel is not', (
    tester,
  ) async {
    await open(tester, 'Xiaomi');
    expect(find.textContaining('Autostart'), findsOneWidget);
    expect(find.textContaining('Xiaomi phones'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    await open(tester, 'Google');
    expect(find.textContaining('Autostart'), findsNothing);
  });

  testWidgets('Allow goes on to Android, Not now does not', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await showDialog<bool>(
                context: context,
                builder: (_) => const BatteryExemptionDialog(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  test('only makers known to stop background apps are named', () {
    expect(strictBackgroundMaker('Xiaomi'), 'Xiaomi');
    expect(strictBackgroundMaker('OnePlus'), 'OnePlus');
    expect(strictBackgroundMaker('Google'), isNull);
    expect(strictBackgroundMaker(null), isNull);
  });
}
