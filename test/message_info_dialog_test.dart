import 'package:conest/src/models.dart';
import 'package:conest/src/ui/message_info_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime.utc(2026, 10, 13, 12);
  String time(DateTime value) =>
      value.toUtc().toIso8601String().substring(11, 19);

  ChatMessage message({
    required bool outbound,
    Map<String, DeliveryState> states = const {},
    List<RouteTrace> traces = const [],
    Map<String, DateTime> readAt = const {},
  }) => ChatMessage(
    id: 'm1',
    conversationId: 'c1',
    senderDeviceId: outbound ? 'me' : 'alice',
    recipientDeviceId: outbound ? 'bob' : 'me',
    body: 'hello',
    outbound: outbound,
    state: outbound ? DeliveryState.delivered : DeliveryState.delivered,
    createdAt: at,
    recipientStates: states,
    routeTrace: traces,
    recipientReadAt: readAt,
  );

  Future<void> show(
    WidgetTester tester,
    ChatMessage message, {
    String Function(String)? members,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageInfoDialog(
            message: message,
            memberLabel: members,
            timestamp: time,
          ),
        ),
      ),
    );
  }

  testWidgets('an incoming message lists every route it arrived by', (
    tester,
  ) async {
    await show(
      tester,
      message(
        outbound: false,
        traces: [
          RouteTrace(
            route: MessageRoute.nostrCarrier,
            mark: MessageRouteMark.confirmed,
            at: at.add(const Duration(seconds: 9)),
          ),
          RouteTrace(
            route: MessageRoute.lanDirect,
            mark: MessageRouteMark.confirmed,
            at: at.add(const Duration(seconds: 3)),
          ),
        ],
      ),
    );
    expect(find.text('Arrived by'), findsOneWidget);
    expect(find.text('LAN direct: received 12:00:03'), findsOneWidget);
    expect(find.text('Nostr: received 12:00:09'), findsOneWidget);
    // In the order they came.
    expect(
      tester.getTopLeft(find.textContaining('LAN direct')).dy,
      lessThan(tester.getTopLeft(find.textContaining('Nostr')).dy),
    );
  });

  testWidgets('a group message shows each member with routes and read time', (
    tester,
  ) async {
    await show(
      tester,
      message(
        outbound: true,
        states: {'bob': DeliveryState.read, 'carol': DeliveryState.relayed},
        traces: [
          RouteTrace(
            route: MessageRoute.irohDirect,
            mark: MessageRouteMark.confirmed,
            at: at.add(const Duration(seconds: 1)),
            deviceId: 'bob',
          ),
          RouteTrace(
            route: MessageRoute.conestRelay,
            mark: MessageRouteMark.stored,
            at: at.add(const Duration(seconds: 2)),
            deviceId: 'carol',
          ),
        ],
        readAt: {'bob': at.add(const Duration(minutes: 1))},
      ),
      members: (id) => id == 'bob' ? 'Bob' : 'Carol',
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Carol'), findsOneWidget);
    expect(find.text('Iroh direct: delivered 12:00:01'), findsOneWidget);
    expect(
      find.text('Conest relay: waiting on the relay 12:00:02'),
      findsOneWidget,
    );
    expect(find.textContaining('read 12:01:00'), findsOneWidget);
  });

  test('route marks only go up, and keep their first time', () {
    final first = message(
      outbound: true,
      traces: [
        RouteTrace(
          route: MessageRoute.irohDirect,
          mark: MessageRouteMark.confirmed,
          at: at,
        ),
      ],
    );
    final traced = first.tracedWith(
      RouteTrace(
        route: MessageRoute.irohDirect,
        mark: MessageRouteMark.sent,
        at: at.add(const Duration(seconds: 5)),
      ),
    );
    expect(traced.single.mark, MessageRouteMark.confirmed);
    expect(traced.single.at, at);
    // And they survive a save.
    final restored = ChatMessage.fromJson(
      first.copyWith(routeTrace: traced).toJson(),
    );
    expect(restored.routeTrace.single.route, MessageRoute.irohDirect);
    expect(restored.routeTrace.single.mark, MessageRouteMark.confirmed);
  });
}
