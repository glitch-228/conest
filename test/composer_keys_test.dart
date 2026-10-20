import 'dart:io';

import 'package:conest/src/conest_theme.dart';
import 'package:conest/src/ui/composer_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TextEditingController text;
  late int sent;

  setUp(() {
    text = TextEditingController();
    sent = 0;
  });

  Future<void> pump(WidgetTester tester, {bool? enterSends}) async {
    final box = ComposerKeys(
      controller: text,
      onSend: () => sent++,
      child: TextField(controller: text, minLines: 1, maxLines: 5),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: enterSends == null
              ? box
              : ComposerSettings(enterSends: enterSends, child: box),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  Future<void> withModifier(
    WidgetTester tester,
    LogicalKeyboardKey modifier,
    LogicalKeyboardKey key,
  ) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  testWidgets('Enter sends, Shift+Enter is left for a new line', (
    tester,
  ) async {
    await pump(tester, enterSends: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    expect(sent, 2);
    await withModifier(
      tester,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.enter,
    );
    expect(sent, 2);
  });

  testWidgets('Enter goes to an input method that is composing', (
    tester,
  ) async {
    await pump(tester, enterSends: true);
    text.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 0);
  });

  testWidgets('with the setting off, Ctrl+Enter sends', (tester) async {
    await pump(tester, enterSends: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 0);
    await withModifier(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.enter,
    );
    expect(sent, 1);
  });

  testWidgets('by default Enter sends on desktops, not on phones', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 1);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  test('the choice is kept', () async {
    final dir = await Directory.systemTemp.createTemp('conest-enter');
    addTearDown(() => dir.delete(recursive: true));
    final store = ThemePreferenceStore(
      fileProvider: () async => File('${dir.path}/theme.json'),
    );
    final theme = ConestThemeController(store: store);
    await theme.initialize();
    // Tests run as a phone, where Enter does not send by default.
    expect(theme.enterSends, isFalse);
    await theme.setEnterSends(true);
    final again = ConestThemeController(store: store);
    await again.initialize();
    expect(again.enterSends, isTrue);
  });
}
