import 'package:conest/src/conversation_sidebar_divider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('sidebar resize supports drag and keyboard in $direction', (
      tester,
    ) async {
      final deltas = <double>[];
      var resets = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: Align(
              child: SizedBox(
                height: 300,
                child: ConversationSidebarDivider(
                  color: Colors.grey,
                  onResize: deltas.add,
                  onReset: () => resets++,
                ),
              ),
            ),
          ),
        ),
      );
      final divider = find.byType(ConversationSidebarDivider);
      await tester.drag(divider, const Offset(60, 0));
      expect(deltas, isNotEmpty);
      expect(
        deltas.reduce((a, b) => a + b),
        direction == TextDirection.ltr ? isPositive : isNegative,
      );
      deltas.clear();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(deltas, direction == TextDirection.ltr ? [24, -24] : [-24, 24]);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      expect(resets, 1);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  }
}
