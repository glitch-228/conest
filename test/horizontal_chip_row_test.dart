import 'package:conest/src/ui/horizontal_chip_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({TargetPlatform platform = TargetPlatform.linux}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: Scaffold(
    body: ListView(
      children: [
        SizedBox(
          height: 42,
          child: HorizontalChipRow(
            children: [
              for (var i = 0; i < 30; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('Chat source number $i'),
                    selected: false,
                    onSelected: (_) {},
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 2000),
      ],
    ),
  ),
);

double _rowOffset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(HorizontalChipRow),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

void main() {
  testWidgets('the vertical wheel scrolls the row sideways', (tester) async {
    await tester.pumpWidget(_app());
    expect(_rowOffset(tester), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(ChoiceChip).first),
    );
    await mouse.moveTo(tester.getCenter(find.byType(ChoiceChip).first));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ChoiceChip).first),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump();
    expect(_rowOffset(tester), 120);
  });

  testWidgets('a mouse can drag the row', (tester) async {
    await tester.pumpWidget(_app());
    final mouse = await tester.startGesture(
      tester.getCenter(find.byType(ChoiceChip).at(1)),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-80, 0));
    await mouse.moveBy(const Offset(-80, 0));
    await mouse.up();
    await tester.pump();
    expect(_rowOffset(tester), greaterThan(50));
  });

  testWidgets('desktop shows a scrollbar, phones do not', (tester) async {
    await tester.pumpWidget(_app());
    final rowScrollbar = find.descendant(
      of: find.byType(HorizontalChipRow),
      matching: find.byType(Scrollbar),
    );
    expect(rowScrollbar, findsOneWidget);
    await tester.pumpWidget(_app(platform: TargetPlatform.android));
    await tester.pumpAndSettle();
    expect(rowScrollbar, findsNothing);
  });
}
