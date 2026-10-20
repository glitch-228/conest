import 'package:conest/src/ui/chat_paste_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<int Function()> pump(WidgetTester tester, {bool active = true}) async {
    var pastes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPasteScope(
            active: () => active,
            onPaste: () => pastes++,
            child: Column(
              children: [
                Focus(
                  key: const ValueKey('message-list'),
                  child: Builder(
                    builder: (context) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Focus.of(context).requestFocus(),
                      child: const SizedBox(width: 200, height: 100),
                    ),
                  ),
                ),
                const TextField(key: ValueKey('search')),
              ],
            ),
          ),
        ),
      ),
    );
    return () => pastes;
  }

  Future<void> pressPaste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('Ctrl+V pastes into the open chat from the message list', (
    tester,
  ) async {
    final pastes = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('message-list')));
    await tester.pump();
    await pressPaste(tester);
    expect(pastes(), 1);
  });

  testWidgets('a text field keeps its own paste', (tester) async {
    final pastes = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('search')));
    await tester.pump();
    await pressPaste(tester);
    expect(pastes(), 0);
  });

  testWidgets('with no chat open nothing is pasted', (tester) async {
    final pastes = await pump(tester, active: false);
    await tester.tap(find.byKey(const ValueKey('message-list')));
    await tester.pump();
    await pressPaste(tester);
    expect(pastes(), 0);
  });
}
