import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/discord/discord_api.dart';
import 'package:conest/src/limits/network_budgets.dart';
import 'package:conest/src/limits/network_limiter.dart';
import 'package:conest/src/matrix_client.dart';
import 'package:conest/src/telegram/telegram_bot_api.dart';
import 'package:conest/src/transport.dart';
import 'package:conest/src/transport_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clock the test moves by hand; timers fire as it passes them.
class _Clock {
  DateTime now = DateTime.utc(2026, 10, 30, 12);
  final List<_FakeTimer> _timers = [];

  Timer timer(Duration after, void Function() callback) {
    final timer = _FakeTimer(now.add(after), callback);
    _timers.add(timer);
    return timer;
  }

  int get pendingTimers => _timers.where((t) => t.isActive).length;

  Future<void> advance(Duration by) async {
    final end = now.add(by);
    while (true) {
      final due =
          _timers.where((t) => t.isActive && !t.at.isAfter(end)).toList()
            ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final next = due.first;
      now = next.at.isAfter(now) ? next.at : now;
      next.fire();
      _timers.remove(next);
      await _settle();
    }
    now = end;
    await _settle();
  }

  Future<void> _settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this._callback);
  final DateTime at;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

NetworkLimiter _limiter(_Clock clock, LimiterBudget budget) =>
    NetworkLimiter(budget, now: () => clock.now, timer: clock.timer);

/// Resolves to when each acquire got its turn, in seconds from [clock]'s
/// start.
Future<void> _note(
  _Clock clock,
  NetworkLimiter limiter,
  List<int> turns, {
  int cost = 1,
  Duration? maxWait,
  LimiterPriority priority = LimiterPriority.interactive,
}) {
  final start = DateTime.utc(2026, 10, 30, 12);
  return limiter
      .acquire(cost: cost, maxWait: maxWait, priority: priority)
      .then((_) => turns.add(clock.now.difference(start).inMilliseconds));
}

void main() {
  const paced = LimiterBudget(
    name: 'test',
    gap: Duration(seconds: 1),
    burst: 2,
    maxQueue: 4,
    maxWait: Duration(seconds: 30),
  );

  group('pacing', () {
    test('a burst is paced: the burst at once, then one a gap', () async {
      final clock = _Clock();
      final limiter = _limiter(clock, paced);
      final turns = <int>[];
      for (var i = 0; i < 4; i++) {
        unawaited(_note(clock, limiter, turns));
      }
      await clock.advance(Duration.zero);
      expect(turns, [0, 0], reason: 'the burst goes at once');
      await clock.advance(const Duration(seconds: 3));
      expect(turns, [0, 0, 1000, 2000]);
      expect(clock.pendingTimers, 0, reason: 'no timer while idle');
    });

    test('a quota per window holds sends back until it frees', () async {
      final clock = _Clock();
      final limiter = _limiter(
        clock,
        const LimiterBudget(
          name: 'quota',
          quota: 3,
          window: Duration(minutes: 1),
          maxWait: Duration(minutes: 5),
        ),
      );
      final turns = <int>[];
      for (var i = 0; i < 5; i++) {
        unawaited(_note(clock, limiter, turns));
        await clock.advance(Duration.zero);
        await clock.advance(const Duration(seconds: 10));
      }
      await clock.advance(const Duration(minutes: 2));
      // Three at 0, 10, 20 s; the fourth waits for the first to leave the
      // window (60 s), the fifth for the second (70 s).
      expect(turns, [0, 10000, 20000, 60000, 70000]);
    });

    test('a send whose turn is past its deadline is refused at once', () async {
      final clock = _Clock();
      final limiter = _limiter(clock, paced);
      final turns = <int>[];
      for (var i = 0; i < 4; i++) {
        unawaited(_note(clock, limiter, turns));
      }
      await expectLater(
        limiter.acquire(maxWait: const Duration(milliseconds: 500)),
        throwsA(
          isA<LimiterRefused>().having(
            (e) => e.reason,
            'reason',
            LimiterRefusal.wouldWait,
          ),
        ),
      );
    });
  });

  group('a server asking to slow down', () {
    test('FLOOD_WAIT rests the account exactly that long', () async {
      final clock = _Clock();
      final limiter = _limiter(clock, NetworkBudgets.telegram);
      await expectLater(
        limiter.run<void>(
          () async => throw const TelegramBotException(
            'sendMessage',
            429,
            'Too Many Requests: retry after 7',
            retryAfter: 7,
          ),
        ),
        throwsA(isA<TelegramBotException>()),
      );
      expect(limiter.isResting, isTrue);
      expect(limiter.restRemaining, const Duration(seconds: 7));
      final turns = <int>[];
      unawaited(_note(clock, limiter, turns));
      await clock.advance(const Duration(milliseconds: 6900));
      expect(turns, isEmpty, reason: 'not a moment early');
      await clock.advance(const Duration(milliseconds: 100));
      expect(turns, isEmpty, reason: 'then one gap before the first send');
      await clock.advance(const Duration(seconds: 1));
      expect(turns, [8000]);
    });

    test('every chat on the account rests, not just the one that hit it', () {
      final clock = _Clock();
      final limiter = _limiter(clock, NetworkBudgets.matrix);
      limiter.pushedBack(retryAfter: const Duration(seconds: 20));
      expect(
        limiter.projectedWait,
        greaterThanOrEqualTo(const Duration(seconds: 20)),
      );
      expect(limiter.nearLimit, isTrue);
    });

    test(
      'a wait the server did not name doubles the gap, then eases',
      () async {
        final clock = _Clock();
        final limiter = _limiter(clock, NetworkBudgets.nostrRelay);
        expect(limiter.currentGap, const Duration(milliseconds: 200));
        limiter.pushedBack();
        expect(limiter.currentGap, const Duration(milliseconds: 400));
        limiter.pushedBack();
        expect(limiter.currentGap, const Duration(milliseconds: 800));
        limiter.succeeded();
        expect(limiter.currentGap, const Duration(milliseconds: 600));
        for (var i = 0; i < 8; i++) {
          limiter.succeeded();
        }
        expect(limiter.currentGap, const Duration(milliseconds: 200));
      },
    );

    test('a wait is capped, and the servers\' errors all name theirs', () {
      final clock = _Clock();
      final limiter = _limiter(clock, NetworkBudgets.matrix);
      limiter.pushedBack(retryAfter: const Duration(days: 9));
      expect(limiter.restRemaining, const Duration(hours: 24));
      expect(
        serverSlowDownOf(
          const DiscordException(
            '/x',
            429,
            'slow',
            retryAfter: 2.5,
            global: true,
          ),
        ),
        const Duration(milliseconds: 2500),
      );
      expect(
        serverSlowDownOf(
          const MatrixException(
            'slow',
            status: 429,
            errcode: 'M_LIMIT_EXCEEDED',
            retryAfter: Duration(milliseconds: 1500),
          ),
        ),
        const Duration(milliseconds: 1500),
      );
      expect(
        serverSlowDownOf(const DiscordException('/x', 500, 'broken')),
        isNull,
      );
      expect(serverSlowDownOf(StateError('no')), isNull);
    });

    test('queued sends whose deadline the rest passes give way', () async {
      final clock = _Clock();
      final limiter = _limiter(clock, paced);
      await limiter.acquire();
      await limiter.acquire();
      final waiting = limiter.acquire(maxWait: const Duration(seconds: 5));
      final refused = expectLater(waiting, throwsA(isA<LimiterRefused>()));
      limiter.pushedBack(retryAfter: const Duration(minutes: 1));
      await refused;
    });
  });

  test('each network has its own budget', () {
    expect(NetworkBudgets.forKind(TransportKind.telegram), isNotNull);
    expect(NetworkBudgets.forKind(TransportKind.matrix)!.burst, 10);
    expect(NetworkBudgets.forKind(TransportKind.lan), isNull);
    expect(
      NetworkBudgets.forKind(TransportKind.meshtastic)!.costInBytes,
      isTrue,
    );
    expect(NetworkBudgets.forKind(TransportKind.iroh), isNull);
    final chatmail = NetworkBudgets.forKind(
      TransportKind.deltaChat,
      chatmail: true,
    )!;
    final ordinary = NetworkBudgets.forKind(TransportKind.deltaChat)!;
    expect(chatmail.quota, lessThan(60));
    expect(chatmail.window, const Duration(minutes: 1));
    expect(ordinary.window, const Duration(hours: 1));
  });

  group('hostile servers and clocks', () {
    test('a rest does not hand out the whole burst when it ends', () async {
      final clock = _Clock();
      final limiter = _limiter(clock, NetworkBudgets.matrix);
      limiter.pushedBack(retryAfter: const Duration(seconds: 60));
      final turns = <int>[];
      for (var i = 0; i < 4; i++) {
        unawaited(
          _note(clock, limiter, turns, maxWait: const Duration(minutes: 2)),
        );
      }
      await clock.advance(const Duration(seconds: 70));
      // After the rest the bucket is empty: one a gap, not ten at once.
      expect(turns.length, 4);
      expect(turns.first, greaterThanOrEqualTo(60000));
      expect(turns.last - turns.first, greaterThanOrEqualTo(2000));
    });

    test('a clock that jumps back does not stall the account', () async {
      final clock = _Clock();
      final limiter = _limiter(clock, paced);
      await limiter.acquire();
      await limiter.acquire();
      clock.now = clock.now.subtract(const Duration(hours: 1));
      final turns = <int>[];
      unawaited(
        _note(clock, limiter, turns, maxWait: const Duration(seconds: 5)),
      );
      await clock.advance(const Duration(seconds: 3));
      expect(turns, hasLength(1));
    });

    test('an absurd retry-after is capped, not trusted', () {
      final clock = _Clock();
      final limiter = _limiter(clock, NetworkBudgets.matrix);
      limiter.pushedBack(retryAfter: const Duration(days: 4000));
      expect(
        limiter.restRemaining,
        lessThanOrEqualTo(const Duration(hours: 24)),
      );
      expect(
        const DiscordException(
          '/x',
          429,
          'x',
          retryAfter: 86400,
          global: true,
        ).slowDownFor,
        const Duration(days: 1),
      );
    });
  });

  group('a full queue', () {
    test(
      'sheds expired sends, then bulk for interactive, never the reverse',
      () async {
        final clock = _Clock();
        final limiter = _limiter(
          clock,
          const LimiterBudget(
            name: 'full',
            gap: Duration(seconds: 10),
            maxQueue: 3,
            maxWait: Duration(minutes: 5),
          ),
        );
        await limiter.acquire(); // takes the only token
        final results = <String, Object?>{};
        Future<void> queue(
          String name,
          LimiterPriority priority, {
          Duration? maxWait,
        }) => limiter
            .acquire(priority: priority, maxWait: maxWait)
            .then<void>(
              (_) => results[name] = 'turn',
              onError: (Object e) =>
                  results[name] = (e as LimiterRefused).reason,
            );
        unawaited(queue('bulk1', LimiterPriority.bulk));
        unawaited(queue('inter1', LimiterPriority.interactive));
        unawaited(queue('bulk2', LimiterPriority.bulk));
        await clock.advance(Duration.zero);
        expect(limiter.queueLength, 3);

        // A bulk send finds the queue full: refused, nothing displaced.
        await queue('bulk3', LimiterPriority.bulk);
        expect(results['bulk3'], LimiterRefusal.queueFull);
        expect(results.containsKey('bulk1'), isFalse);

        // An interactive send displaces the oldest bulk one.
        unawaited(queue('inter2', LimiterPriority.interactive));
        await clock.advance(Duration.zero);
        expect(results['bulk1'], LimiterRefusal.shed);
        expect(results.containsKey('bulk2'), isFalse);
        expect(limiter.queueLength, 3);

        // Everything else gets its turn in order.
        await clock.advance(const Duration(minutes: 1));
        expect(results['inter1'], 'turn');
        expect(results['bulk2'], 'turn');
        expect(results['inter2'], 'turn');
      },
    );

    test('sheds a send past its deadline before anything else', () async {
      final clock = _Clock();
      final limiter = _limiter(
        clock,
        const LimiterBudget(
          name: 'full',
          gap: Duration(seconds: 10),
          maxQueue: 2,
          maxWait: Duration(minutes: 5),
        ),
      );
      await limiter.acquire();
      final results = <String, Object?>{};
      Future<void> queue(String name, Duration maxWait) => limiter
          .acquire(maxWait: maxWait)
          .then<void>(
            (_) => results[name] = 'turn',
            onError: (Object e) => results[name] = (e as LimiterRefused).reason,
          );
      unawaited(queue('short', const Duration(seconds: 15)));
      unawaited(queue('long', const Duration(minutes: 4)));
      await clock.advance(Duration.zero);
      // The clock jumps past the short one's deadline before its timer runs.
      clock.now = clock.now.add(const Duration(seconds: 16));
      unawaited(queue('new', const Duration(minutes: 4)));
      await clock.advance(Duration.zero);
      expect(results['short'], LimiterRefusal.expired);
      expect(results.containsKey('long'), isFalse);
      limiter.close();
    });

    test('a queue full of interactive sends refuses a newcomer', () async {
      final clock = _Clock();
      final limiter = _limiter(
        clock,
        const LimiterBudget(
          name: 'full',
          gap: Duration(seconds: 10),
          maxQueue: 2,
          maxWait: Duration(minutes: 5),
        ),
      );
      await limiter.acquire();
      for (var i = 0; i < 2; i++) {
        unawaited(limiter.acquire().then<void>((_) {}, onError: (Object _) {}));
      }
      await expectLater(
        limiter.acquire(),
        throwsA(
          isA<LimiterRefused>().having(
            (e) => e.reason,
            'reason',
            LimiterRefusal.queueFull,
          ),
        ),
      );
      limiter.close();
    });
  });

  group('review fixes', () {
    final peer = const TransportPeer(
      deviceId: 'peer',
      transportIdentity: 'peer',
      identityPinned: true,
    );

    test('Reticulum over TCP has no airtime budget, over a radio it has', () {
      expect(
        NetworkBudgets.forKind(TransportKind.reticulum, radio: false),
        isNull,
      );
      expect(
        NetworkBudgets.forKind(TransportKind.reticulum)!.costInBytes,
        isTrue,
      );
    });

    test('queued bytes count for the next send\'s turn', () async {
      final clock = _Clock();
      final limiter = _limiter(
        clock,
        const LimiterBudget(
          name: 'radio',
          costInBytes: true,
          quota: 450,
          maxQueue: 16,
          maxWait: Duration(seconds: 90),
        ),
      );
      final turns = <int>[];
      unawaited(_note(clock, limiter, turns, cost: 300));
      unawaited(_note(clock, limiter, turns, cost: 300));
      await clock.advance(Duration.zero);
      expect(turns, [0], reason: 'the second waits for the window');
      // The second takes the next window; a third 300 bytes is a window
      // further, so it is past 90 s and refused, not queued.
      expect(limiter.projectedWaitFor(1, cost: 300).inSeconds, 120);
      await expectLater(
        limiter.acquire(cost: 300),
        throwsA(isA<LimiterRefused>()),
      );
      await clock.advance(const Duration(minutes: 3));
      expect(turns, [0, 60000]);
    });

    test('a clock that jumps back does not hold the quota longer', () async {
      final clock = _Clock();
      final limiter = _limiter(
        clock,
        const LimiterBudget(
          name: 'quota',
          quota: 2,
          maxWait: Duration(minutes: 3),
        ),
      );
      await limiter.acquire();
      await limiter.acquire();
      clock.now = clock.now.subtract(const Duration(hours: 1));
      // The window is a minute from now, not an hour and a minute.
      expect(limiter.projectedWait.inSeconds, lessThanOrEqualTo(60));
      final turns = <int>[];
      unawaited(
        _note(clock, limiter, turns, maxWait: const Duration(minutes: 3)),
      );
      await clock.advance(const Duration(minutes: 2));
      expect(turns, hasLength(1));
    });

    test('one Discord route\'s 429 does not rest the whole account', () {
      expect(
        serverSlowDownOf(
          const DiscordException('/x', 429, 'slow', retryAfter: 2.5),
        ),
        isNull,
      );
    });

    test('the limiter\'s own clock only moves forward', () async {
      var last = monotonicNow();
      for (var i = 0; i < 50; i++) {
        final next = monotonicNow();
        expect(next.isBefore(last), isFalse);
        last = next;
      }
    });

    test(
      'an attempt that times out while the account rests is not a failure',
      () async {
        final clock = _Clock();
        final held = _Adapter(TransportKind.iroh, TransportPathKind.direct)
          ..limiter = _limiter(clock, paced)
          ..hang = true;
        held.limiter!.pushedBack(retryAfter: const Duration(minutes: 5));
        final registry = TransportRegistry([held]);
        await expectLater(
          registry.deliverEnvelope(
            peer: peer,
            envelope: _envelope(),
            policies: const {},
            attemptTimeout: const Duration(milliseconds: 30),
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          registry.statsFor('peer', TransportKind.iroh)?.failureStreak ?? 0,
          0,
        );
        expect(held.cancelled, [
          'peer|m-peer',
        ], reason: 'the abandoned send is told to stop');
      },
    );

    test('an attempt that times out for its own sake is still a failure', () {
      final held = _Adapter(TransportKind.iroh, TransportPathKind.direct)
        ..hang = true;
      final registry = TransportRegistry([held]);
      return expectLater(
        registry
            .deliverEnvelope(
              peer: peer,
              envelope: _envelope(),
              policies: const {},
              attemptTimeout: const Duration(milliseconds: 30),
            )
            .catchError((Object _) => throw 'x'),
        throwsA(anything),
      ).then((_) {
        expect(registry.statsFor('peer', TransportKind.iroh)!.failureStreak, 1);
      });
    });

    test('a send that queued gives no round-trip sample', () async {
      final clock = _Clock();
      final queued = _Adapter(TransportKind.iroh, TransportPathKind.direct)
        ..limiter = _limiter(clock, paced);
      queued.limiter!.pushedBack(retryAfter: const Duration(minutes: 1));
      final registry = TransportRegistry([queued]);
      await registry.deliverEnvelope(
        peer: peer,
        envelope: _envelope(),
        policies: const {},
      );
      expect(registry.statsFor('peer', TransportKind.iroh)!.rttMs, isNull);
      final free = _Adapter(TransportKind.matrix, TransportPathKind.relayed);
      final other = TransportRegistry([free]);
      await other.deliverEnvelope(
        peer: peer,
        envelope: _envelope(),
        policies: const {},
      );
      expect(other.statsFor('peer', TransportKind.matrix)!.rttMs, isNotNull);
    });
  });

  group('the dispatcher', () {
    final peer = const TransportPeer(
      deviceId: 'peer',
      transportIdentity: 'peer',
      identityPinned: true,
    );

    test('picks another route when one is near its limit', () async {
      final clock = _Clock();
      final direct = _Adapter(TransportKind.iroh, TransportPathKind.direct)
        ..limiter = _limiter(clock, paced);
      final relayed = _Adapter(TransportKind.matrix, TransportPathKind.relayed);
      final registry = TransportRegistry([direct, relayed]);
      // Not throttled: the direct path goes first.
      expect(
        (await registry.routesFor(peer, policies: const {})).first.transport,
        TransportKind.iroh,
      );
      // The direct route's account is told to rest.
      direct.limiter!.pushedBack(retryAfter: const Duration(minutes: 1));
      expect(
        (await registry.routesFor(peer, policies: const {})).first.transport,
        TransportKind.matrix,
      );
      final result = await registry.deliverEnvelope(
        peer: peer,
        envelope: _envelope(),
        policies: const {},
      );
      expect(result.receipt.route.transport, TransportKind.matrix);
      expect(direct.sent, 0);
    });

    test(
      'a send the limiter held back does not mark the route failed',
      () async {
        final clock = _Clock();
        final held = _Adapter(TransportKind.iroh, TransportPathKind.direct)
          ..refuse = true;
        final other = _Adapter(TransportKind.matrix, TransportPathKind.relayed);
        final registry = TransportRegistry([held, other]);
        final result = await registry.deliverEnvelope(
          peer: peer,
          envelope: _envelope(),
          policies: const {},
        );
        expect(result.receipt.route.transport, TransportKind.matrix);
        expect(
          registry.statsFor('peer', TransportKind.iroh)?.failureStreak ?? 0,
          0,
        );
        expect(clock.pendingTimers, 0);
      },
    );
  });
}

TransportEnvelope _envelope({String to = 'peer'}) => TransportEnvelope(
  id: 'm-$to',
  recipientDeviceId: to,
  bytes: Uint8List(3),
  createdAt: DateTime.utc(2026, 10, 30),
);

class _Adapter implements TransportAdapter, RateLimited {
  _Adapter(this.kind, this.path);

  @override
  final TransportKind kind;
  final TransportPathKind path;
  @override
  NetworkLimiter? limiter;
  int sent = 0;
  bool refuse = false;

  /// The send never finishes (a send stuck waiting for its turn).
  bool hang = false;
  final List<String> cancelled = [];

  @override
  TransportCapabilities get capabilities => const TransportCapabilities(
    requiresPeerOnline: false,
    supportsStoreForward: false,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: false,
    reportsPath: true,
  );

  RouteCandidate get _route => RouteCandidate(
    transport: kind,
    path: path,
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
  Future<void> cancel(String operationId) async => cancelled.add(operationId);
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
    if (refuse) throw const LimiterRefused(LimiterRefusal.wouldWait);
    if (hang) await Completer<void>().future;
    sent++;
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
