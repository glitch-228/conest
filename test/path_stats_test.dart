import 'dart:typed_data';

import 'package:conest/src/energy_policy.dart';
import 'package:conest/src/models.dart';
import 'package:conest/src/path_stats.dart';
import 'package:conest/src/route_health_tracker.dart';
import 'package:conest/src/transfer/route_striper.dart';
import 'package:conest/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const peer = TransportPeer(
    deviceId: 'peer',
    transportIdentity: 'peer',
    identityPinned: true,
  );

  group('PathStats', () {
    final t0 = DateTime.utc(2026, 10, 30, 12);

    test('smooths round trips and throughput, and a failure rests', () {
      final stats = PathStats(priorBytesPerSecond: 1000);
      expect(stats.bytesPerSecond, 1000);
      expect(stats.hasThroughput, isFalse);
      stats.recordSuccess(t0, rtt: const Duration(milliseconds: 100));
      stats.recordSuccess(t0, rtt: const Duration(milliseconds: 200));
      expect(stats.rttMs, closeTo(130, 0.001));
      stats.recordSuccess(t0, bytes: 4000, took: const Duration(seconds: 1));
      expect(stats.bytesPerSecond, 4000);
      expect(stats.hasThroughput, isTrue);
      stats.recordFailure(t0);
      expect(stats.failureStreak, 1);
      expect(stats.loss, greaterThan(0));
      expect(stats.coolingAt(t0.add(const Duration(seconds: 14))), isTrue);
      expect(stats.coolingAt(t0.add(const Duration(seconds: 16))), isFalse);
      stats.recordFailure(t0);
      expect(stats.coolingAt(t0.add(const Duration(seconds: 29))), isTrue);
      stats.recordSuccess(t0);
      expect(stats.failureStreak, 0);
      expect(stats.cooldownUntil, isNull);
    });

    test('a server asking for a pause rests the path without a streak', () {
      final stats = PathStats();
      stats.recordFailure(
        t0,
        until: t0.add(const Duration(seconds: 40)),
        grow: false,
      );
      expect(stats.failureStreak, 0);
      expect(stats.coolingAt(t0.add(const Duration(seconds: 39))), isTrue);
      expect(stats.coolingAt(t0.add(const Duration(seconds: 41))), isFalse);
    });

    test('the book keeps a bounded number of paths', () {
      final book = PathStatsBook<int>(maxEntries: 3);
      for (var i = 0; i < 5; i++) {
        book.touch(i);
      }
      expect(book.length, 3);
      expect(book.peek(0), isNull);
      expect(book.peek(4), isNotNull);
    });
  });

  group('one set of numbers', () {
    test(
      'the registry ranks by, and escalation waits on, the same rtt',
      () async {
        final slow = _Adapter(
          TransportKind.iroh,
          const Duration(milliseconds: 120),
        );
        final fast = _Adapter(TransportKind.conestRelay, Duration.zero);
        final registry = TransportRegistry([slow, fast]);
        // Unmeasured, Iroh (expected faster) goes first.
        expect(
          (await registry.routesFor(peer, policies: const {})).first.transport,
          TransportKind.iroh,
        );
        for (final kind in [TransportKind.iroh, TransportKind.conestRelay]) {
          await registry.deliverEnvelope(
            peer: peer,
            envelope: _envelope(3),
            policies: {kind: TransportPolicy.preferred},
          );
        }
        final irohStats = registry.statsFor('peer', TransportKind.iroh)!;
        final relayStats = registry.statsFor(
          'peer',
          TransportKind.conestRelay,
        )!;
        expect(irohStats.rttMs, greaterThan(relayStats.rttMs!));
        // Ranking follows the figures.
        expect(
          (await registry.routesFor(peer, policies: const {})).first.transport,
          TransportKind.conestRelay,
        );
        // The wait before another copy is 1.5 x the first route's rtt (never
        // under the base).
        final wait = escalationInterval(
          const Duration(milliseconds: 100),
          irohStats.rttMs,
        );
        expect(wait.inMilliseconds, (irohStats.rttMs! * 1.5).round());
        expect(
          escalationInterval(const Duration(seconds: 3), relayStats.rttMs),
          const Duration(seconds: 3),
        );
      },
    );

    test('a large envelope feeds throughput, not the round trip', () async {
      final adapter = _Adapter(
        TransportKind.iroh,
        const Duration(milliseconds: 50),
      );
      final registry = TransportRegistry([adapter]);
      await registry.deliverEnvelope(
        peer: peer,
        envelope: _envelope(200 * 1024),
        policies: const {},
      );
      final stats = registry.statsFor('peer', TransportKind.iroh)!;
      expect(stats.rttMs, isNull);
      expect(stats.hasThroughput, isTrue);
      expect(stats.bytesPerSecond, greaterThan(200 * 1024));
    });

    test('the connection map sees a link failing on every transport', () async {
      var now = DateTime.utc(2026, 10, 30, 12);
      final iroh = _Adapter(TransportKind.iroh, Duration.zero)..fail = true;
      final relay = _Adapter(TransportKind.conestRelay, Duration.zero)
        ..fail = true;
      final registry = TransportRegistry([iroh, relay], now: () => now);
      expect(registry.failingToReach('peer'), isFalse, reason: 'untried');
      await expectLater(
        registry.deliverEnvelope(
          peer: peer,
          envelope: _envelope(3),
          policies: const {},
        ),
        throwsStateError,
      );
      expect(registry.failingToReach('peer'), isTrue);
      // One transport works again: no longer failing.
      relay.fail = false;
      now = now.add(const Duration(minutes: 1));
      await registry.deliverEnvelope(
        peer: peer,
        envelope: _envelope(3),
        policies: const {},
      );
      expect(registry.failingToReach('peer'), isFalse);
      // Old news is not news.
      iroh.fail = true;
      now = now.add(const Duration(hours: 2));
      expect(registry.failingToReach('peer'), isFalse);
    });

    test('route health ranks by the smoothed rtt of its stats', () {
      var now = DateTime.utc(2026, 10, 30, 12);
      final tracker = RouteHealthTracker(nowProvider: () => now);
      final a = PeerEndpoint(
        kind: PeerRouteKind.directInternet,
        host: 'a.example',
        port: 1,
        protocol: PeerRouteProtocol.tcp,
      );
      final b = PeerEndpoint(
        kind: PeerRouteKind.directInternet,
        host: 'b.example',
        port: 1,
        protocol: PeerRouteProtocol.tcp,
      );
      // a: usually 50 ms but the last check took 200 ms. b: steady 120 ms.
      for (var i = 0; i < 6; i++) {
        tracker.recordSuccess(a, latency: const Duration(milliseconds: 50));
      }
      tracker.recordSuccess(a, latency: const Duration(milliseconds: 200));
      tracker.recordSuccess(b, latency: const Duration(milliseconds: 120));
      expect(tracker.healthFor(a)!.latency, const Duration(milliseconds: 200));
      expect(
        tracker.compareHealth(tracker.healthFor(a)!, tracker.healthFor(b)!),
        lessThan(0),
      );
      expect(tracker.rankMicrosFor(a), lessThan(tracker.rankMicrosFor(b)));
      // The runtime state is the same figures.
      expect(
        tracker.runtimeFor(a)!.stats.rttMs,
        tracker.rttOf(a)!.inMicroseconds / 1000,
      );
      tracker.recordFailure(a);
      expect(tracker.runtimeFor(a)!.stats.failureStreak, 1);
      expect(tracker.isBackedOff(a), isTrue);
      now = now.add(const Duration(minutes: 1));
      expect(tracker.isBackedOff(a), isFalse);
    });

    test('the striper keeps its speed, failures and rest in PathStats', () {
      var now = DateTime.utc(2026, 10, 30, 12);
      final striper = RouteStriper<String>(
        now: () => now,
        priorBytesPerSecond: const {'lan': 8e6},
      );
      expect(striper.statsOf('lan').bytesPerSecond, 8e6);
      final lease = striper.begin('lan', 1000000);
      now = now.add(const Duration(seconds: 1));
      striper.succeeded(lease);
      expect(striper.statsOf('lan').bytesPerSecond, 1000000);
      expect(striper.speedOf('lan'), 1000000);
      striper.failed(striper.begin('lan', 10));
      expect(striper.statsOf('lan').failureStreak, 1);
      expect(striper.isResting('lan'), isTrue);
      now = now.add(const Duration(seconds: 6));
      expect(striper.isResting('lan'), isFalse);
    });
  });
}

TransportEnvelope _envelope(int size) => TransportEnvelope(
  id: 'm-$size',
  recipientDeviceId: 'peer',
  bytes: Uint8List(size),
  createdAt: DateTime.utc(2026, 10, 30),
);

class _Adapter implements TransportAdapter {
  _Adapter(this.kind, this.delay);

  @override
  final TransportKind kind;
  final Duration delay;
  bool fail = false;

  @override
  TransportCapabilities get capabilities => const TransportCapabilities(
    requiresPeerOnline: false,
    supportsStoreForward: false,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: true,
    reportsPath: true,
  );

  RouteCandidate get _route => RouteCandidate(
    transport: kind,
    path: TransportPathKind.relayed,
    routeId: kind.name,
    label: kind.label,
    trust: TransportTrustState.pinnedTransport,
  );

  @override
  Stream<TransportInboundEnvelope> get inboundEnvelopes => const Stream.empty();
  @override
  Stream<RouteCandidate> get pathChanges => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel(String operationId) async {}
  @override
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer) async => [
    _route,
  ];

  @override
  Future<DeliveryReceipt> sendEnvelope({
    required TransportPeer peer,
    required RouteCandidate route,
    required TransportEnvelope envelope,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('unavailable');
    return DeliveryReceipt(
      state: DeliveryReceiptState.deliveredToPeer,
      route: route,
      at: DateTime.now().toUtc(),
    );
  }

  @override
  Future<DeliveryReceipt> sendAttachmentRange({
    required TransportPeer peer,
    required RouteCandidate route,
    required AttachmentRange range,
  }) => throw UnimplementedError();
}
