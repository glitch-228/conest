import 'package:conest/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'long lists get one scrollbar with a fixed-size thumb',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StableScrollbar(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                itemCount: 400,
                itemBuilder: (context, index) => SizedBox(
                  height: index.isEven ? 40 : 400,
                  child: Text('$index'),
                ),
              ),
            ),
          ),
        ),
      );
      // On desktop the default scrollbar (whose thumb follows estimated
      // heights) is off: only the stable one remains.
      expect(find.byType(Scrollbar), findsNothing);
      final scrollbar = tester.widget<RawScrollbar>(find.byType(RawScrollbar));
      // On any long list the thumb is this size, whatever the estimates.
      expect(scrollbar.minThumbLength, StableScrollbar.minThumbLength);
      expect(scrollbar.controller, controller);
      expect(scrollbar.interactive, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('using the window brings the app to the foreground', (
    tester,
  ) async {
    var foreground = false;
    var raised = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UserActivityForeground(
          isForeground: () => foreground,
          onForeground: () {
            raised++;
            foreground = true;
          },
          child: const Scaffold(body: Center(child: Text('chat'))),
        ),
      ),
    );
    await tester.tap(find.text('chat'));
    expect(raised, 1);
    await tester.tap(find.text('chat'));
    expect(raised, 1, reason: 'already in front');
  });
}
