import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/models.dart';
import 'package:conest/src/reachability_tracker.dart';

void main() {
  group('ReachabilityTracker', () {
    late List<ContactReachabilityRecord> records;
    late DateTime now;
    late ReachabilityTracker tracker;

    setUp(() {
      records = <ContactReachabilityRecord>[];
      now = DateTime.utc(2026, 5, 17, 12);
      tracker = ReachabilityTracker(
        recordsProvider: () => records,
        recordsUpdater: (next) => records = List.of(next),
        nowProvider: () => now,
      );
    });

    test('no record returns ContactReachabilityState.unknown', () {
      expect(tracker.stateFor('absent'), ContactReachabilityState.unknown);
    });

    test('noteTwoWaySuccess flips contact to online inside the window', () {
      tracker.noteTwoWaySuccess('dev-bob');
      expect(tracker.stateFor('dev-bob'), ContactReachabilityState.online);

      // Just past the online window, still inside seenRecently.
      now = now.add(kOnlineReachabilityWindow + const Duration(seconds: 1));
      expect(
        tracker.stateFor('dev-bob'),
        ContactReachabilityState.seenRecently,
      );

      // Past seenRecently, but lastTwoWaySuccessAt keeps it known.
      now = now.add(kSeenRecentlyReachabilityWindow);
      expect(tracker.stateFor('dev-bob'), ContactReachabilityState.known);

      // Past the known window — back to unknown.
      now = now.add(kKnownReachabilityWindow);
      expect(tracker.stateFor('dev-bob'), ContactReachabilityState.unknown);
    });

    test(
      'noteAvailablePath alone never lifts a contact above unknown',
      () {
        tracker.noteAvailablePath('dev-bob');
        // No two-way success and no other signal — diagnostic only.
        expect(tracker.stateFor('dev-bob'), ContactReachabilityState.unknown);
      },
    );

    test('remove deletes the record', () {
      tracker.noteTwoWaySuccess('dev-bob');
      tracker.remove('dev-bob');
      expect(tracker.stateFor('dev-bob'), ContactReachabilityState.unknown);
      expect(records, isEmpty);
    });

    test('ensure creates an empty record without changing state', () {
      tracker.ensure('dev-bob');
      expect(records, hasLength(1));
      expect(tracker.stateFor('dev-bob'), ContactReachabilityState.unknown);
    });
  });
}
