import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/models.dart';
import 'package:conest/src/route_health_tracker.dart';

void main() {
  group('RouteHealthTracker', () {
    late DateTime now;
    late RouteHealthTracker tracker;
    final lanRoute = PeerEndpoint(
      kind: PeerRouteKind.lan,
      host: '10.0.0.1',
      port: 7117,
      protocol: PeerRouteProtocol.tcp,
    );
    final relayRoute = PeerEndpoint(
      kind: PeerRouteKind.relay,
      host: 'relay.example',
      port: 7117,
      protocol: PeerRouteProtocol.tcp,
    );

    setUp(() {
      now = DateTime.utc(2026, 5, 17, 12);
      tracker = RouteHealthTracker(nowProvider: () => now);
    });

    test('a fresh route is eligible and has no health entry', () {
      expect(tracker.isEligibleNow(lanRoute), isTrue);
      expect(tracker.healthFor(lanRoute), isNull);
    });

    test(
      'recordFailure marks the route backed off with an escalating window',
      () {
        tracker.recordFailure(lanRoute, error: 'boom');
        expect(tracker.isBackedOff(lanRoute), isTrue);
        // First-failure backoff for LAN is 5s — advancing past clears it.
        now = now.add(const Duration(seconds: 6));
        expect(tracker.isBackedOff(lanRoute), isFalse);

        // Second failure escalates to 15s.
        tracker.recordFailure(lanRoute);
        expect(
          tracker.backoffDurationFor(lanRoute, failureStreak: 2),
          const Duration(seconds: 15),
        );
        // Third escalates to 30s, fourth+ caps at 60s.
        expect(
          tracker.backoffDurationFor(lanRoute, failureStreak: 3),
          const Duration(seconds: 30),
        );
        expect(
          tracker.backoffDurationFor(lanRoute, failureStreak: 4),
          const Duration(seconds: 60),
        );
      },
    );

    test('recordSuccess clears the backoff and seeds a healthy cache', () {
      tracker.recordFailure(lanRoute);
      expect(tracker.isBackedOff(lanRoute), isTrue);

      tracker.recordSuccess(lanRoute, fetch: true);
      expect(tracker.isBackedOff(lanRoute), isFalse);
      expect(tracker.hasFreshHealthyCache(lanRoute), isTrue);
      expect(tracker.hasRecentRouteSuccess(lanRoute), isTrue);
    });

    test('health cache expires after the kind-specific TTL', () {
      tracker.recordSuccess(lanRoute);
      // LAN cache TTL = 15s.
      now = now.add(kLanHealthCacheTtl + const Duration(seconds: 1));
      expect(tracker.hasFreshHealthyCache(lanRoute), isFalse);
    });

    test('kindDeliveryPriority puts LAN before direct before relay', () {
      expect(
        tracker.kindDeliveryPriority(lanRoute),
        lessThan(tracker.kindDeliveryPriority(relayRoute)),
      );
    });

    test('clear drops both maps', () {
      tracker.recordSuccess(lanRoute);
      tracker.recordFailure(relayRoute);
      tracker.clear();
      expect(tracker.healthMap, isEmpty);
      expect(tracker.runtimeMap, isEmpty);
    });

    test('connectivity reset clears backoff without discarding history', () {
      tracker.recordSuccess(lanRoute, fetch: true);
      tracker.recordFailure(lanRoute);
      expect(tracker.isBackedOff(lanRoute), isTrue);

      tracker.clearBackoffWindows();

      expect(tracker.isEligibleNow(lanRoute), isTrue);
      expect(tracker.healthFor(lanRoute), isNotNull);
      expect(tracker.runtimeFor(lanRoute)?.failureStreak, 0);
      expect(tracker.runtimeFor(lanRoute)?.lastFetchSuccessAt, isNotNull);
    });
  });
}
