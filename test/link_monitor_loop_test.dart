import 'dart:async';

import 'package:conest/src/net/link_monitor_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The native monitor as the Rust side behaves: generations count up from 1,
/// a wait returns on a change, on its timeout (the same generation) or at
/// once with 0 when the monitor is stopped or unknown, and stopping wakes a
/// wait that is running.
class FakeNativeMonitor {
  int generation = 1;
  bool stopped = false;
  int starts = 0;
  int stops = 0;
  int waits = 0;
  int waitsRunning = 0;
  Completer<void> _wake = Completer<void>();

  int start() {
    starts++;
    return 7;
  }

  void change() {
    generation++;
    _wake.complete();
    _wake = Completer<void>();
  }

  void stop(int handle) {
    stops++;
    stopped = true;
    _wake.complete();
    _wake = Completer<void>();
  }

  /// [timeout] stands for the native 60 s: the test releases it with
  /// [timeoutNow].
  Completer<void> timeoutGate = Completer<void>();
  void timeoutNow() {
    timeoutGate.complete();
    timeoutGate = Completer<void>();
  }

  Future<int> wait(int handle, int seen) async {
    waits++;
    if (stopped) return 0;
    if (generation != seen) return generation;
    waitsRunning++;
    try {
      await Future.any([_wake.future, timeoutGate.future]);
    } finally {
      waitsRunning--;
    }
    if (stopped) return 0;
    return generation;
  }
}

void main() {
  late FakeNativeMonitor native;
  late List<String> events;
  late LinkMonitorLoop loop;

  setUp(() {
    native = FakeNativeMonitor();
    events = [];
    loop = LinkMonitorLoop(
      start: native.start,
      wait: native.wait,
      stop: native.stop,
      onChange: () => events.add('change'),
    );
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  test(
    'the first generation is the state at the start, not a change',
    () async {
      loop.start();
      await settle();
      expect(events, isEmpty);
      expect(native.waitsRunning, 1);
      await loop.stop();
    },
  );

  test('a change is reported once, a timeout is not a change', () async {
    loop.start();
    await settle();
    native.change();
    await settle();
    expect(events, ['change']);
    native.timeoutNow();
    await settle();
    native.timeoutNow();
    await settle();
    expect(events, ['change']);
    native.change();
    native.change();
    await settle();
    // Two changes before the loop looked again are one report.
    expect(events.length, lessThanOrEqualTo(3));
    expect(events.length, greaterThanOrEqualTo(2));
    await loop.stop();
  });

  test('stopping while a wait is running ends the loop, stops the native '
      'monitor once, and nothing is reported afterwards', () async {
    loop.start();
    await settle();
    expect(native.waitsRunning, 1);
    await loop.stop();
    expect(native.stops, 1);
    expect(native.waitsRunning, 0);
    native.generation++;
    await settle();
    expect(events, isEmpty);
    // A second stop is harmless.
    await loop.stop();
    expect(native.stops, 1);
  });

  test('a monitor that cannot start does nothing', () async {
    final failing = LinkMonitorLoop(
      start: () => 0,
      wait: native.wait,
      stop: native.stop,
      onChange: () => events.add('change'),
    );
    failing.start();
    await settle();
    expect(native.waits, 0);
    await failing.stop();
    expect(native.stops, 0);
  });

  test('a monitor that stops by itself (a wait returning 0) ends the loop '
      'without waiting again', () async {
    loop.start();
    await settle();
    native.stopped = true;
    native.change();
    await settle();
    final waitsThen = native.waits;
    await settle();
    expect(native.waits, waitsThen);
    await loop.stop();
  });

  test('starting twice runs one loop', () async {
    loop.start();
    loop.start();
    await settle();
    expect(native.starts, 1);
    await loop.stop();
  });
}
