import 'package:conest/src/models.dart';
import 'package:conest/src/ui/message_info_dialog.dart';
import 'package:conest/src/ui/message_times.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sent = DateTime.utc(2026, 10, 13, 12);
  String hm(DateTime value) =>
      value.toUtc().toIso8601String().substring(11, 16);

  ChatMessage message({
    required bool outbound,
    DeliveryState state = DeliveryState.delivered,
    DateTime? receivedAt,
    Map<String, DeliveryState> states = const {},
    List<RouteTrace> traces = const [],
  }) => ChatMessage(
    id: 'm1',
    conversationId: 'c1',
    senderDeviceId: outbound ? 'me' : 'alice',
    recipientDeviceId: outbound ? 'bob' : 'me',
    body: 'hello',
    outbound: outbound,
    state: state,
    createdAt: sent,
    receivedAt: receivedAt,
    recipientStates: states,
    routeTrace: traces,
  );

  RouteTrace receipt(DateTime at, {String? device}) => RouteTrace(
    route: MessageRoute.irohDirect,
    mark: MessageRouteMark.confirmed,
    at: at,
    deviceId: device,
  );

  Future<void> show(
    WidgetTester tester,
    ChatMessage message, {
    Duration? offset,
    ThemeData? theme,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: MessageTimeLabel(
          message: message,
          format: hm,
          senderClockOffset: offset,
        ),
      ),
    ),
  );

  Duration min(int minutes, [int seconds = 0]) =>
      Duration(minutes: minutes, seconds: seconds);

  group('outgoing chat message', () {
    testWidgets('delivered within a minute shows one time', (tester) async {
      await show(
        tester,
        message(outbound: true, traces: [receipt(sent.add(min(1)))]),
      );
      expect(find.text('12:00'), findsOneWidget);
      expect(find.byKey(const ValueKey('message-time-late')), findsNothing);
    });

    testWidgets('delivered later shows when it was sent and delivered', (
      tester,
    ) async {
      await show(
        tester,
        message(outbound: true, traces: [receipt(sent.add(min(1, 1)))]),
      );
      expect(find.text('12:00 · delivered 12:01'), findsOneWidget);
      await show(
        tester,
        message(outbound: true, traces: [receipt(sent.add(min(18)))]),
      );
      expect(find.text('12:00 · delivered 12:18'), findsOneWidget);
    });

    testWidgets('not delivered yet shows one time', (tester) async {
      await show(
        tester,
        message(
          outbound: true,
          state: DeliveryState.relayed,
          traces: [receipt(sent.add(min(18)))],
        ),
      );
      expect(find.text('12:00'), findsOneWidget);
    });

    testWidgets('a different day names the day', (tester) async {
      await show(
        tester,
        message(
          outbound: true,
          traces: [receipt(sent.add(const Duration(hours: 20)))],
        ),
      );
      expect(find.textContaining('12:00 · delivered '), findsOneWidget);
      expect(find.textContaining('08:00'), findsOneWidget);
      expect(find.textContaining('Oct 14'), findsOneWidget);
    });
  });

  group('incoming message', () {
    testWidgets('arriving within a minute shows one time', (tester) async {
      await show(
        tester,
        message(outbound: false, receivedAt: sent.add(min(1))),
      );
      expect(find.text('12:00'), findsOneWidget);
    });

    testWidgets('arriving later shows when it was sent and arrived', (
      tester,
    ) async {
      await show(
        tester,
        message(outbound: false, receivedAt: sent.add(min(25))),
      );
      expect(find.text('12:00 · arrived 12:25'), findsOneWidget);
    });

    testWidgets('a sender whose clock is behind is not late by that', (
      tester,
    ) async {
      // Their clock runs 2 hours behind; arrival is on time by it.
      await show(
        tester,
        message(
          outbound: false,
          receivedAt: sent.add(const Duration(hours: 2, seconds: 20)),
        ),
        offset: const Duration(hours: 2),
      );
      expect(find.text('12:00'), findsOneWidget);
    });
  });

  group('group message', () {
    testWidgets('delivered to everyone shows the last member to confirm', (
      tester,
    ) async {
      await show(
        tester,
        message(
          outbound: true,
          states: const {
            'a': DeliveryState.delivered,
            'b': DeliveryState.read,
            'gone': DeliveryState.canceled,
          },
          traces: [
            receipt(sent.add(min(0, 5)), device: 'a'),
            receipt(sent.add(min(7)), device: 'b'),
            receipt(sent.add(min(90)), device: 'gone'),
          ],
        ),
      );
      expect(find.text('12:00 · delivered 12:07'), findsOneWidget);
    });

    testWidgets('while a member still has nothing there is no delivered '
        'time', (tester) async {
      await show(
        tester,
        message(
          outbound: true,
          state: DeliveryState.relayed,
          states: const {
            'a': DeliveryState.delivered,
            'b': DeliveryState.relayed,
          },
          traces: [receipt(sent.add(min(7)), device: 'a')],
        ),
      );
      expect(find.text('12:00'), findsOneWidget);
    });

    testWidgets('message info says how many members have it', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageInfoDialog(
              message: message(
                outbound: true,
                state: DeliveryState.relayed,
                states: const {
                  'a': DeliveryState.delivered,
                  'b': DeliveryState.relayed,
                  'c': DeliveryState.read,
                  'gone': DeliveryState.canceled,
                },
              ),
              memberLabel: (id) => id,
              timestamp: hm,
            ),
          ),
        ),
      );
      expect(find.text('Delivered to 2 of 3'), findsOneWidget);
    });
  });

  testWidgets('the late time stays readable in both themes', (tester) async {
    final late = message(outbound: false, receivedAt: sent.add(min(25)));
    for (final theme in [ThemeData.light(), ThemeData.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 140,
                child: MessageTimeLabel(
                  message: late,
                  format: hm,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('12:00 · arrived 12:25'), findsOneWidget);
    }
  });
}
