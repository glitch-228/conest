import 'dart:async';

import 'package:conest/src/net/link_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int changes;
  late LinkWatcher watcher;

  LinkWatcher make({bool androidFallback = false, Completer<void>? hold}) {
    changes = 0;
    return LinkWatcher(
      onChanged: () async {
        changes++;
        if (hold != null && changes == 1) await hold.future;
      },
      androidFallback: androidFallback,
    );
  }

  group('debounce', () {
    testWidgets('a burst of events is one change, 500 ms after the first', (
      tester,
    ) async {
      watcher = make();
      for (var i = 0; i < 50; i++) {
        watcher.note(LinkEventSource.monitor);
        await tester.pump(const Duration(milliseconds: 5));
      }
      // 250 ms have passed since the first event.
      await tester.pump(const Duration(milliseconds: 200));
      expect(changes, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(changes, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(changes, 1);
      watcher.dispose();
    });

    testWidgets('two bursts apart are two changes', (tester) async {
      watcher = make();
      watcher.note(LinkEventSource.connectivity);
      await tester.pump(const Duration(seconds: 1));
      watcher.note(LinkEventSource.androidNetwork);
      await tester.pump(const Duration(seconds: 1));
      expect(changes, 2);
      watcher.dispose();
    });

    testWidgets('an event while a change is being handled runs it once more, '
        'not many times', (tester) async {
      final hold = Completer<void>();
      watcher = make(hold: hold);
      watcher.note(LinkEventSource.monitor);
      await tester.pump(const Duration(seconds: 1));
      expect(changes, 1);
      for (var i = 0; i < 10; i++) {
        watcher.note(LinkEventSource.monitor);
        await tester.pump(const Duration(seconds: 1));
      }
      expect(changes, 1);
      hold.complete();
      await tester.pump(const Duration(seconds: 1));
      expect(changes, 2);
      watcher.dispose();
    });

    testWidgets('dispose cancels what is waiting; later events do nothing', (
      tester,
    ) async {
      watcher = make();
      watcher.note(LinkEventSource.monitor);
      watcher.dispose();
      watcher.note(LinkEventSource.monitor);
      await tester.pump(const Duration(seconds: 2));
      expect(changes, 0);
      // The test ends with no timer pending, or the framework fails it.
    });

    testWidgets('an error in the handler does not stop later changes', (
      tester,
    ) async {
      var calls = 0;
      watcher = LinkWatcher(
        onChanged: () async {
          calls++;
          if (calls == 1) throw StateError('listing failed');
        },
      );
      watcher.note(LinkEventSource.monitor);
      await tester.pump(const Duration(seconds: 1));
      watcher.note(LinkEventSource.monitor);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      watcher.dispose();
    });
  });

  group('Android fallback', () {
    void open(LinkWatcher w) => w
      ..setForeground(true)
      ..setEnabled(true)
      ..setPageOpen(true);

    testWidgets('does not run off Android, or with the page closed', (
      tester,
    ) async {
      watcher = make();
      open(watcher);
      await tester.pump(const Duration(minutes: 3));
      expect(changes, 0);
      watcher.dispose();

      watcher = make(androidFallback: true);
      watcher
        ..setForeground(true)
        ..setEnabled(true);
      await tester.pump(const Duration(minutes: 3));
      expect(changes, 0);
      watcher.dispose();
    });

    testWidgets('looks every 30 s while foreground, enabled and the page is '
        'open, and stops when any of them ends', (tester) async {
      watcher = make(androidFallback: true);
      open(watcher);
      expect(watcher.fallbackRunning, isTrue);
      await tester.pump(const Duration(seconds: 95));
      expect(changes, 3);

      watcher.setForeground(false);
      expect(watcher.fallbackRunning, isFalse);
      await tester.pump(const Duration(minutes: 2));
      expect(changes, 3);

      watcher.setForeground(true);
      expect(watcher.fallbackRunning, isTrue);
      watcher.setPageOpen(false);
      expect(watcher.fallbackRunning, isFalse);
      watcher.setPageOpen(true);
      watcher.setEnabled(false);
      expect(watcher.fallbackRunning, isFalse);
      watcher.dispose();
    });

    testWidgets('a network callback never switches it off (it fires at once '
        'for the networks already there, and tethering raises none)', (
      tester,
    ) async {
      watcher = make(androidFallback: true);
      open(watcher);
      watcher.note(LinkEventSource.androidNetwork);
      watcher.note(LinkEventSource.connectivity);
      watcher.note(LinkEventSource.monitor);
      expect(watcher.eventsWorking, isFalse);
      expect(watcher.fallbackRunning, isTrue);
      watcher.dispose();
    });

    for (final source in [
      LinkEventSource.androidUsbState,
      LinkEventSource.androidTether,
    ]) {
      testWidgets('a ${source.name} event switches it off for the run', (
        tester,
      ) async {
        watcher = make(androidFallback: true);
        open(watcher);
        watcher.note(source);
        expect(watcher.eventsWorking, isTrue);
        expect(watcher.fallbackRunning, isFalse);
        await tester.pump(const Duration(minutes: 2));
        final seen = changes;
        // Reopening the page does not bring the fallback back.
        watcher.setPageOpen(false);
        watcher.setPageOpen(true);
        expect(watcher.fallbackRunning, isFalse);
        await tester.pump(const Duration(minutes: 2));
        expect(changes, seen);
        watcher.dispose();
      });
    }
  });
}
