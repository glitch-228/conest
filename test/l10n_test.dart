import 'dart:convert';
import 'dart:io';

import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/src/app_locales.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/ui/message_info_dialog.dart';
import 'package:conest/src/ui/localized_ui_text.dart';
import 'package:conest/src/ui/localized_labels.dart';
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

  test('new translations are not English recovery placeholders', () {
    for (final code in aiTranslatedLanguages) {
      final arb = _arb(code);
      for (final key in keys) {
        final english = template[key] as String;
        if ((template['@$key'] as Map)['x-preserve-english'] != null) continue;
        // Short borrowed words and names can legitimately stay the same.
        // A whole untranslated sentence is a broken recovery checkpoint.
        final words = english.replaceAll(RegExp(r'\{\w+\}'), '');
        if (RegExp(r'[A-Za-z]').allMatches(words).length >= 30) {
          expect(
            arb[key],
            isNot(english),
            reason: '$code: $key needs a translation',
          );
        }
      }
    }
  });

  test('ICU count messages use the shipped languages plural categories', () {
    for (final code in appLanguageNames.keys) {
      final arb = _arb(code);
      for (final key in keys) {
        final english = template[key] as String;
        if (!english.contains(', plural,')) continue;
        final value = arb[key] as String;
        for (final category in switch (code) {
          'ar' => ['zero', 'one', 'two', 'few', 'many', 'other'],
          'ru' => ['one', 'few', 'many', 'other'],
          'en' || 'fa' => ['one', 'other'],
          _ => ['other'],
        }) {
          // The pre-existing duration uses an exact =0 branch and other.
          if (key == 'callDuration') continue;
          expect(value, contains('$category{'), reason: '$code: $key');
        }
      }
    }
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect(ru.uiValueMembersCEF563(1), '1 участник');
    expect(ru.uiValueMembersCEF563(2), '2 участника');
    expect(ru.uiValueMembersCEF563(5), '5 участников');
    expect(ru.uiValueMembersCEF563(21), '21 участник');
    final ar = lookupAppLocalizations(const Locale('ar'));
    expect(ar.uiValueMembersCEF563(0), 'لا أعضاء');
    expect(ar.uiValueMembersCEF563(1), 'عضو واحد');
    expect(ar.uiValueMembersCEF563(2), 'عضوان');
    expect(ar.uiValueMembersCEF563(3), contains('أعضاء'));
    expect(ar.uiValueMembersCEF563(11), contains('عضوًا'));
  });

  test(
    'store listings exist in every language within the short-text limit',
    () {
      for (final locale in ['en-US', 'ar', 'fa', 'id', 'ru', 'zh-CN']) {
        final folder = 'fastlane/metadata/android/$locale';
        expect(File('$folder/title.txt').readAsStringSync().trim(), 'Conest');
        final short = File(
          '$folder/short_description.txt',
        ).readAsStringSync().trim();
        expect(short, isNotEmpty);
        expect(short.runes.length, lessThanOrEqualTo(80), reason: locale);
        final full = File('$folder/full_description.txt').readAsStringSync();
        expect(full, contains('Conest'));
        if (locale != 'en-US') {
          expect(full, matches(RegExp('ذكاء الاصطناعي|هوش مصنوعی|AI|ИИ|人工智能')));
        }
      }
    },
  );

  test('main has no additional literal Text labels outside debug screens', () {
    final source = File('lib/main.dart').readAsStringSync();
    final classes = source.split(RegExp(r'(?=\nclass )'));
    final allowedDebugClasses = RegExp(
      r'^\s*class (DebugMenuDialog|_DebugMenuDialogState|_DebugInfoBlock|_DebugResultTile|_DebugPeerTile|_DebugFlagChip)\b',
    );
    final literal = RegExp(r'''\bText\(\s*(?:r)?['"]''');
    final count = classes
        .where((part) => !allowedDebugClasses.hasMatch(part))
        .fold(0, (sum, part) => sum + literal.allMatches(part).length);
    // Remaining literals are numeric controls and interpolation-only display
    // data. Keep this ceiling fixed when adding UI, not a rolling count.
    const baseline = 36;
    expect(
      count,
      lessThanOrEqualTo(baseline),
      reason: 'Use a stable ARB key for new Text labels; current count: $count',
    );
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
    testWidgets(
      'controller notices translate in $code without changing display data',
      (tester) async {
        late BuildContext context;
        await show(
          tester,
          code,
          Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        );
        final strings = lookupAppLocalizations(Locale(code));
        expect(
          deliveryStateLabel(context, DeliveryState.read),
          strings.deliveryRead,
        );
        expect(
          reachabilityLabel(context, ContactReachabilityState.seenRecently),
          strings.reachabilityRecent,
        );
        expect(
          transferPhaseLabel(context, TransferPhase.waitingForPeer),
          strings.transferPeer,
        );
        expect(
          messageRouteDescription(context, MessageRoute.plainMatrix),
          strings.routePlainMatrixDescription,
        );
        for (final route in MessageRoute.values) {
          expect(messageRouteLabel(context, route), isNotEmpty);
          expect(messageRouteDescription(context, route), isNotEmpty);
          if (code != 'en') {
            expect(
              messageRouteDescription(context, route),
              isNot(route.description),
            );
          }
        }
        expect(
          localizedUiText(
            context,
            'This device is now linked to your account.',
          ),
          strings.uiThisDeviceIsNowLinked7EA826,
        );
        expect(
          localizedUiText(context, 'Shared Delete "Save" with the group.'),
          strings.uiSharedValueWithTheGroupAE4134('Delete "Save"'),
        );
        expect(
          localizedUiText(context, 'Imported 5 relay(s) from Save this name.'),
          strings.statusImportedRelaySFromB1DB2D(5, 'Save this name'),
        );
        expect(
          localizedUiText(
            context,
            'Imported many relay(s) from Save this name.',
          ),
          'Imported many relay(s) from Save this name.',
        );
        for (final raw in [
          'Delete "peer supplied title"',
          '4 days',
          'Unknown transport detail: Keep this name',
          'x' * 20000,
        ]) {
          expect(localizedUiText(context, raw), raw);
        }
        const ambiguous = 'Could not read name: containing: separators';
        expect(localizedUiText(context, ambiguous), ambiguous);
        expect(tester.takeException(), isNull);
      },
    );

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
