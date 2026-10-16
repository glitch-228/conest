import 'package:conest/src/conest_theme.dart';
import 'package:conest/src/matrix_service.dart';
import 'package:conest/src/ui/forwarding.dart';
import 'package:conest/src/ui/matrix_room_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_matrix_native.dart';

void main() {
  testWidgets('a direct chat offers to verify the other person', (
    tester,
  ) async {
    final native = FakeMatrixNative(FakeMatrixHub())
      ..rooms = [
        {
          'roomId': '!dm:x',
          'name': 'Bob',
          'direct': true,
          'encrypted': true,
          'directTargets': ['@bob:x'],
        },
      ]
      ..crossSigningUsers.add('@bob:x');
    late MatrixClientService client;
    await tester.runAsync(() async {
      client = MatrixClientService(
        api: native,
        store: () async => (path: '/store', passphrase: 'p'),
        onSession: (_) async {},
      );
      await client.signInWithPassword(
        homeserver: 'https://x',
        user: 'alice',
        password: 'p',
      );
      await client.refreshRooms();
    });
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MatrixRoomScreen(
          client: client,
          roomId: '!dm:x',
          palette: ConestPalette(),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.byKey(const ValueKey('matrix-verify-partner')), findsOneWidget);
    expect(find.textContaining('see who talks to whom'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('matrix-verify-partner')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(native.verificationsStarted, ['@bob:x']);
    expect(find.text('Verify Bob'), findsOneWidget);
    await tester.runAsync(() async {
      native.emit({
        'type': 'verification',
        'flowId': 'flow-@bob:x',
        'state': 'done',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    native.verifiedUsers.add('@bob:x');
    await tester.tap(find.text('Close').last);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('matrix-partner-verified')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a Matrix message can be forwarded into Conest', (tester) async {
    final native = FakeMatrixNative(FakeMatrixHub())
      ..rooms = [
        {'roomId': '!r:x', 'name': 'Room', 'direct': false, 'encrypted': true},
      ];
    late MatrixClientService client;
    await tester.runAsync(() async {
      client = MatrixClientService(
        api: native,
        store: () async => (path: '/store', passphrase: 'p'),
        onSession: (_) async {},
      );
      await client.signInWithPassword(
        homeserver: 'https://x',
        user: 'alice',
        password: 'p',
      );
      await client.refreshRooms();
    });
    addTearDown(client.dispose);
    String? forwarded;
    forwardTextToConest = (context, text) async => forwarded = text;
    addTearDown(() => forwardTextToConest = null);
    await tester.pumpWidget(
      MaterialApp(
        home: MatrixRoomScreen(
          client: client,
          roomId: '!r:x',
          palette: ConestPalette(),
        ),
      ),
    );
    await tester.runAsync(() async {
      native.emit({
        'type': 'timeline',
        'roomId': '!r:x',
        'events': [
          {
            'event_id': r'$1',
            'type': 'm.room.message',
            'sender': '@bob:x',
            'origin_server_ts': 1,
            'content': {'msgtype': 'm.text', 'body': 'worth passing on'},
          },
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    expect(find.text('worth passing on'), findsOneWidget);
    // The message's actions (long press, or a secondary click).
    final bubble = tester.widget(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_MatrixBubble',
      ),
    );
    (bubble as dynamic).onLongPress();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('matrix-forward')));
    await tester.pumpAndSettle();
    expect(forwarded, 'worth passing on');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an unencrypted direct chat says so', (tester) async {
    final native = FakeMatrixNative(FakeMatrixHub())
      ..rooms = [
        {
          'roomId': '!plain:x',
          'name': 'Bridge',
          'direct': true,
          'encrypted': false,
          'directTargets': ['@bridge:x'],
        },
      ];
    late MatrixClientService client;
    await tester.runAsync(() async {
      client = MatrixClientService(
        api: native,
        store: () async => (path: '/store', passphrase: 'p'),
        onSession: (_) async {},
      );
      await client.signInWithPassword(
        homeserver: 'https://x',
        user: 'alice',
        password: 'p',
      );
      await client.refreshRooms();
    });
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MatrixRoomScreen(
          client: client,
          roomId: '!plain:x',
          palette: ConestPalette(),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.textContaining('This chat is not encrypted'), findsOneWidget);
    expect(find.textContaining('end-to-end encrypted'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
