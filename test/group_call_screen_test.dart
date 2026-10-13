import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/ui/group_call_screen.dart';
import 'support/fake_call_network.dart';

void main() {
  testWidgets(
    'group screen controls capture and releases hold on pointer and keyboard',
    (tester) async {
      final net = FakeCallNetwork();
      await tester.runAsync(() async {
        await net.add('p0');
        await net.add('p1');
        await net.add('old');
        await net.add('offline');
        net.unsupported.add('old');
        net.noRoute.add('offline');
        await net.connect(['p0', 'p1']);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(net.dispose);
      });
      final local = net.peers['p0']!;
      await tester.pumpWidget(
        MaterialApp(
          home: GroupCallScreen(
            groupId: 'group',
            title: 'Friends',
            service: local.service,
            members: () => net.members('group'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text("Can't join (update needed)"), findsOneWidget);
      expect(find.text("Can't reach (no direct route)"), findsOneWidget);
      final remote = local.service.active!.participants.singleWhere(
        (p) => p.deviceId == 'p1',
      );
      local.media.play(remote.index, 1, Uint8List.fromList([1]));
      await local.service.setMuted(false);
      await tester.pump();
      expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
      await tester.tap(find.text('Mute'));
      await tester.pump();
      expect(local.media.muted, true);
      expect(find.text('Unmute'), findsOneWidget);
      await tester.tap(find.text('Unmute'));
      await tester.pump();
      await tester.tap(find.text('Noise suppression'));
      await tester.pump();
      expect(local.service.noiseSuppressionEnabled, false);
      expect(local.media.noise.last, false);
      await tester.tap(find.text('Push-to-talk'));
      await tester.pump();
      expect(local.media.muted, true);
      final hold = find.byKey(const ValueKey('group-call-hold-to-talk'));
      final pointer = await tester.startGesture(tester.getCenter(hold));
      await tester.pump();
      expect(local.media.muted, false);
      expect(find.text('Talking…'), findsOneWidget);
      await pointer.cancel();
      await tester.pump();
      expect(local.media.muted, true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(local.media.muted, false);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(local.media.muted, true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(local.media.muted, false);
      // Removing the call route must release held transmission before disposal.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      expect(local.media.muted, true);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    },
  );

  testWidgets('Leave closes capture and returns to the chat', (tester) async {
    final net = FakeCallNetwork();
    await tester.runAsync(() async {
      await net.add('p0');
      await net.add('p1');
      await net.connect(net.peers.keys);
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(net.dispose);
    });
    final service = net.peers['p0']!.service;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => GroupCallScreen(
                  groupId: 'group',
                  title: 'Friends',
                  service: service,
                  members: () => net.members('group'),
                ),
              ),
            ),
            child: const Text('Chat'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Leave'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('Chat'), findsOneWidget);
    expect(service.active, isNull);
    expect(net.peers['p0']!.media.opened, false);
    expect(net.summaries.single.callEnded, false);
  });

  test(
    'call summaries persist without blocking a call that is still running',
    () {
      final at = DateTime.utc(2026, 10, 13);
      final summary = GroupCallSummary(
        groupId: 'group',
        callId: 'call',
        startedBy: 'p0',
        startedAt: at,
        endedAt: at.add(const Duration(seconds: 65)),
        participants: ['p0', 'p1'],
        callEnded: false,
      );
      final vault = VaultSnapshot.empty().copyWith(
        groupCallSummaries: [summary],
      );
      final restored = VaultSnapshot.fromJson(
        jsonDecode(jsonEncode(vault.toJson())) as Map<String, dynamic>,
      );
      expect(restored.groupCallSummaries.single.callEnded, false);
      expect(restored.groupCallSummaries.single.duration.inSeconds, 65);
      final old = summary.toJson()..remove('callEnded');
      expect(GroupCallSummary.fromJson(old).callEnded, true);
      expect(
        VaultSnapshot.fromJson(
          VaultSnapshot.empty().toJson()..remove('groupCallSummaries'),
        ).groupCallSummaries,
        isEmpty,
      );
    },
  );

  testWidgets(
    'call summary is chronological and shows starter, duration and participants',
    (tester) async {
      final at = DateTime.utc(2026, 10, 13);
      final summary = GroupCallSummary(
        groupId: 'group',
        callId: 'call',
        startedBy: 'p0',
        startedAt: at,
        endedAt: at.add(const Duration(seconds: 65)),
        participants: ['p0', 'p1'],
      );
      ChatMessage message(String id, int seconds) => ChatMessage(
        id: id,
        conversationId: 'group',
        senderDeviceId: 'p0',
        recipientDeviceId: 'p1',
        body: id,
        outbound: false,
        state: DeliveryState.delivered,
        createdAt: at.add(Duration(seconds: seconds)),
      );
      final timeline = groupCallChatTimeline(
        [message('before', 5), message('after', 80)],
        [summary],
      );
      expect(timeline.map((e) => e.messageIndex), [0, null, 1]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupCallSummaryTile(
              summary: summary,
              labelFor: (_) => 'Alice',
            ),
          ),
        ),
      );
      expect(find.text('Voice call · 1:05'), findsOneWidget);
      expect(find.text('Started by Alice · 2 participants'), findsOneWidget);
    },
  );
}
