import 'dart:convert';
import 'dart:io';

import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/src/app_locales.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/ui/message_info_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String code) =>
    jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
        as Map<String, dynamic>;

Set<String> _placeholders(String message) => {
  for (final match in RegExp(r'\{(\w+)[,}]').allMatches(message))
    match.group(1)!,
};

void main() {
  final template = _arb('en');
  final keys = template.keys.where((key) => !key.startsWith('@')).toSet();

  test('every shipped language translates every string', () {
    for (final code in appLanguageNames.keys) {
      final arb = _arb(code);
      final translated = arb.keys.where((key) => !key.startsWith('@')).toSet();
      expect(translated, keys, reason: 'app_$code.arb');
      for (final key in keys) {
        expect(
          _placeholders(arb[key] as String),
          _placeholders(template[key] as String),
          reason: '$code: $key keeps its placeholders',
        );
      }
      expect(
        arb['@@x-ai-translated'] == true,
        aiTranslatedLanguages.contains(code),
        reason: '$code is marked as AI-translated exactly when it is',
      );
    }
  });

  test('every template string explains itself to translators', () {
    for (final key in keys) {
      final meta = template['@$key'];
      expect(meta, isA<Map<String, dynamic>>(), reason: key);
      expect((meta as Map)['description'], isNotEmpty, reason: key);
    }
  });

  Future<void> show(WidgetTester tester, String code, Widget child) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(code),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final code in appLanguageNames.keys) {
    testWidgets('message details read well in $code at phone width', (
      tester,
    ) async {
      final at = DateTime.utc(2026, 10, 14, 12);
      await show(
        tester,
        code,
        MessageInfoDialog(
          message: ChatMessage(
            id: 'm1',
            conversationId: 'c1',
            senderDeviceId: 'me',
            recipientDeviceId: 'bob',
            body: 'hello',
            outbound: true,
            state: DeliveryState.read,
            createdAt: at,
            recipientStates: const {'bob': DeliveryState.read},
            routeTrace: [
              RouteTrace(
                route: MessageRoute.irohDirect,
                mark: MessageRouteMark.confirmed,
                at: at,
                deviceId: 'bob',
              ),
            ],
            recipientReadAt: {'bob': at},
          ),
          memberLabel: (_) => 'Bob',
          showRoutes: false,
        ),
      );
      final strings = lookupAppLocalizations(Locale(code));
      expect(find.text(strings.messageDetails), findsOneWidget);
      // Arabic and Persian read right to left.
      final direction = Directionality.of(
        tester.element(find.text(strings.messageDetails)),
      );
      expect(
        direction,
        {'ar', 'fa'}.contains(code) ? TextDirection.rtl : TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a missing localization falls back to English', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => Text(l10nOf(context).actionClose)),
      ),
    );
    expect(find.text('Close'), findsOneWidget);
  });
}
