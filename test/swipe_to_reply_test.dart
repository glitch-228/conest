import 'package:conest/src/swipe_to_reply.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pump(WidgetTester tester) async {
    final replies = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SwipeToReply(
              color: Colors.blue,
              onReply: () => replies.add('reply'),
              child: const SizedBox(
                width: 300,
                height: 60,
                child: Text('a message'),
              ),
            ),
          ),
        ),
      ),
    );
    return replies;
  }

  Future<void> swipe(WidgetTester tester, PointerDeviceKind kind) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('a message')),
      kind: kind,
    );
    for (var step = 0; step < 10; step++) {
      await gesture.moveBy(const Offset(-12, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('a finger swiping a message replies to it', (tester) async {
    final replies = await pump(tester);
    await swipe(tester, PointerDeviceKind.touch);
    expect(replies, ['reply']);
  });

  testWidgets('a mouse dragging across a message does not reply', (
    tester,
  ) async {
    // With a mouse a drag selects text, and a hold beside a message
    // selects the message.
    final replies = await pump(tester);
    await swipe(tester, PointerDeviceKind.mouse);
    expect(replies, isEmpty);
  });
}
