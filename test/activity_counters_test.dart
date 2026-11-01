import 'dart:async';
import 'dart:io';

import 'package:conest/src/activity_counters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final counters = ActivityCounters.instance;

  setUp(() {
    ActivityCounters.enabled = true;
    counters.reset();
  });
  tearDown(() => ActivityCounters.enabled = false);

  test(
    'timers made in the zone are counted with where they came from',
    () async {
      final done = Completer<void>();
      late Timer periodic;
      var ticks = 0;
      runZoned(() {
        periodic = Timer.periodic(const Duration(milliseconds: 20), (_) {
          if (++ticks == 3) done.complete();
        });
        Timer(const Duration(milliseconds: 5), () {});
      }, zoneSpecification: ActivityCounters.timerZone);
      await done.future;
      final json = counters.toJson();
      final timers = (json['timers']! as List).cast<Map<String, Object?>>();
      final mine = timers.firstWhere((t) => t['periodic'] == true);
      expect(mine['origin'], isNot('other'));
      expect(mine['intervalMs'], 20);
      expect(mine['fires'], greaterThanOrEqualTo(3));
      expect(json['periodicTimersActive'], 1);
      expect((json['timerWakeups']! as Map)['count'], greaterThanOrEqualTo(4));
      periodic.cancel();
      expect(counters.toJson()['periodicTimersActive'], 0);
    },
  );

  test('nothing is counted unless a debug run asks', () async {
    ActivityCounters.enabled = false;
    final done = Completer<void>();
    runZoned(() {
      Timer(const Duration(milliseconds: 5), done.complete);
    }, zoneSpecification: ActivityCounters.timerZone);
    await done.future;
    counters.noteRebuild('chatList');
    counters.noteNotification();
    counters.noteLogLine();
    final json = counters.toJson();
    expect((json['timerWakeups']! as Map)['count'], 0);
    expect(json['rebuilds'], isEmpty);
    expect((json['logLines']! as Map)['count'], 0);
  });

  test('rebuilds, notifications and log lines have rates, and a snapshot '
      'narrows the report to the time after it', () async {
    counters.noteRebuild('chatList');
    counters.noteRebuild('chatView');
    counters.noteNotification();
    counters.noteLogLine();
    final before = counters.snapshot();
    counters.noteRebuild('chatList');
    counters.noteRebuild('chatList');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final all = counters.toJson();
    expect(((all['rebuilds']! as Map)['chatList']! as Map)['count'], 3);
    final later = counters.toJson(since: before);
    expect(((later['rebuilds']! as Map)['chatList']! as Map)['count'], 2);
    expect(
      ((later['rebuilds']! as Map)['chatList']! as Map)['perSecond'],
      greaterThan(0),
    );
    expect((later['notifications']! as Map)['count'], 0);
    expect((all['logLines']! as Map)['count'], 1);
  });

  test('sockets opened and closed are counted', () async {
    ActivityCounters.countSockets();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) => socket.destroy());
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final open = counters.toJson()['sockets']! as Map;
    expect(open['opened'], 1);
    expect(open['open'], 1);
    await socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((counters.toJson()['sockets']! as Map)['open'], 0);
  });
}
