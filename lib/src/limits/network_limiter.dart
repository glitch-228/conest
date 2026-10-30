/// One limiter per network account (and per relay), shared by every chat,
/// group and own device that sends through it, so no account is banned for
/// sending too much or too fast.
///
/// What it does:
/// - Paces sends with a token bucket ([LimiterBudget.gap] between tokens,
///   [LimiterBudget.burst] at most at once) and an optional quota per
///   window (messages an hour, bytes a minute).
/// - Queues a burst, oldest first, in a bounded queue; a send whose turn
///   would come after its deadline is refused at once, so the caller tries
///   another route instead of waiting behind this one.
/// - Obeys a server's "slow down" exactly: the account rests as long as the
///   server said ([NetworkLimiter.pushedBack]); without a named wait the gap
///   doubles and eases after each send that goes through.
/// - Tells the dispatcher when it is [NetworkLimiter.nearLimit], so another
///   route goes first.
///
/// It runs on one timer, armed only while something waits: no polling.
library;

import 'dart:async';

/// Which sends go first when the queue is full: [interactive] sends (a
/// message someone is waiting for) displace [bulk] ones (file blocks, copies,
/// sync), never the other way round.
enum LimiterPriority { interactive, bulk }

enum LimiterRefusal {
  /// The turn would come after the send's deadline.
  wouldWait,

  /// The queue is full of sends that rank at least as high.
  queueFull,

  /// A higher-priority send took the place in the queue.
  shed,

  /// The deadline passed while waiting.
  expired,

  /// The limiter was closed.
  closed,
}

/// A send was not let through. The caller tries another route, or later.
class LimiterRefused implements Exception {
  const LimiterRefused(this.reason, {this.retryIn});

  final LimiterRefusal reason;

  /// When a send would have its turn, if known.
  final Duration? retryIn;

  @override
  String toString() =>
      'Rate limit: ${reason.name}'
      '${retryIn == null ? '' : ' (turn in ${retryIn!.inSeconds} s)'}';
}

/// An error that says a server asked to slow down (HTTP 429, Telegram
/// FLOOD_WAIT, Matrix `M_LIMIT_EXCEEDED`, an email "450 too much mail").
abstract interface class ServerSlowDown {
  /// Null when this error is not a slow-down; the wait the server named, or
  /// [Duration.zero] when it asked to slow down without naming one.
  Duration? get slowDownFor;
}

/// The slow-down in [error], if it is one.
Duration? serverSlowDownOf(Object error) =>
    error is ServerSlowDown ? error.slowDownFor : null;

/// What a network allows one account; see [NetworkBudgets] for the values
/// and where they come from.
class LimiterBudget {
  const LimiterBudget({
    required this.name,
    this.gap = Duration.zero,
    this.burst = 1,
    this.maxGap = const Duration(seconds: 30),
    this.quota,
    this.window = const Duration(minutes: 1),
    this.maxQueue = 32,
    this.maxWait = const Duration(seconds: 30),
    this.comfortWait = const Duration(seconds: 2),
    this.maxRest = const Duration(hours: 24),
  });

  final String name;

  /// Time for one more send to be allowed (zero: no pacing).
  final Duration gap;

  /// Sends allowed back to back after a quiet time.
  final int burst;

  /// The most the gap grows to when a server pushes back without a wait.
  final Duration maxGap;

  /// Units (sends, or bytes when sends have a cost) per [window]; null for
  /// no quota.
  final int? quota;
  final Duration window;

  /// Sends waiting for their turn, at most.
  final int maxQueue;

  /// How long a send waits for its turn unless it says otherwise.
  final Duration maxWait;

  /// A route that would make a send wait longer than this is "near its
  /// limit": the dispatcher prefers another.
  final Duration comfortWait;

  /// The longest rest a server's "slow down" is obeyed for.
  final Duration maxRest;

  /// The same budget without a quota (tests and carriers whose quota is
  /// not wanted).
  LimiterBudget withoutQuota() => LimiterBudget(
    name: name,
    gap: gap,
    burst: burst,
    maxGap: maxGap,
    window: window,
    maxQueue: maxQueue,
    maxWait: maxWait,
    comfortWait: comfortWait,
    maxRest: maxRest,
  );

  LimiterBudget copyWith({Duration? gap, int? burst, int? quota}) =>
      LimiterBudget(
        name: name,
        gap: gap ?? this.gap,
        burst: burst ?? this.burst,
        maxGap: maxGap,
        quota: quota ?? this.quota,
        window: window,
        maxQueue: maxQueue,
        maxWait: maxWait,
        comfortWait: comfortWait,
        maxRest: maxRest,
      );
}

/// Something that sends through a [NetworkLimiter] (the dispatcher asks
/// whether it is near its limit before choosing a route).
abstract interface class RateLimited {
  NetworkLimiter? get limiter;
}

class _Waiter {
  _Waiter(this.cost, this.priority, this.deadline);

  final int cost;
  final LimiterPriority priority;
  final DateTime deadline;
  final Completer<void> done = Completer<void>();
}

typedef LimiterTimerFactory = Timer Function(Duration after, void Function());

class NetworkLimiter {
  NetworkLimiter(
    this.budget, {
    DateTime Function()? now,
    LimiterTimerFactory? timer,
  }) : _now = now ?? DateTime.now,
       _timerFactory = timer ?? Timer.new,
       _gap = budget.gap,
       _tokens = budget.burst.toDouble() {
    _refilledAt = _now();
  }

  final LimiterBudget budget;
  final DateTime Function() _now;
  final LimiterTimerFactory _timerFactory;

  Duration _gap;
  double _tokens;
  late DateTime _refilledAt;
  DateTime? _restUntil;
  final List<(DateTime, int)> _spent = [];
  final List<_Waiter> _queue = [];
  Timer? _timer;
  bool _closed = false;

  /// The gap in force now (grows when a server pushes back).
  Duration get currentGap => _gap;
  int get queueLength => _queue.length;

  /// Whether the account is resting because a server said so.
  bool get isResting => restRemaining > Duration.zero;

  Duration get restRemaining {
    final until = _restUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// The share of the quota spent in the current window (0 without one).
  double get usedShare {
    final quota = budget.quota;
    if (quota == null || quota <= 0) return 0;
    final now = _now();
    _forget(now);
    var used = 0;
    for (final (_, cost) in _spent) {
      used += cost;
    }
    return used / quota;
  }

  /// How long a send of [cost] would wait for its turn now.
  Duration get projectedWait => _projectedWait(1);

  /// How long the last of [sends] sends made now would wait for its turn.
  Duration projectedWaitFor(int sends) {
    final now = _now();
    final extra = sends > 1 ? sends - 1 : 0;
    final at = _earliest(now, 1).add(_gap * (_queue.length + extra));
    final wait = at.difference(now);
    return wait.isNegative ? Duration.zero : wait;
  }

  Duration _projectedWait(int cost) {
    final now = _now();
    final at = _earliest(now, cost).add(_gap * _queue.length);
    final wait = at.difference(now);
    return wait.isNegative ? Duration.zero : wait;
  }

  /// Whether the dispatcher should prefer another route: resting, a turn
  /// that is more than [LimiterBudget.comfortWait] away, most of the quota
  /// spent, or a queue half full.
  bool get nearLimit =>
      !_closed &&
      (isResting ||
          projectedWait > budget.comfortWait ||
          usedShare >= 0.8 ||
          _queue.length * 2 >= budget.maxQueue);

  /// Waits for this send's turn. Throws [LimiterRefused] when the turn would
  /// come after [maxWait] (default [LimiterBudget.maxWait]), when the queue
  /// is full of sends that rank at least as high, or when it is displaced or
  /// expires while waiting. [cost] counts against the quota.
  Future<void> acquire({
    int cost = 1,
    Duration? maxWait,
    LimiterPriority priority = LimiterPriority.interactive,
  }) async {
    if (_closed) throw const LimiterRefused(LimiterRefusal.closed);
    final now = _now();
    final quota = budget.quota;
    final charged = quota == null
        ? (cost < 1 ? 1 : cost)
        : (cost < 1 ? 1 : (cost > quota ? quota : cost));
    final deadline = now.add(maxWait ?? budget.maxWait);
    final first = _earliest(now, charged);
    if (_queue.isEmpty && !first.isAfter(now)) {
      _start(now, charged);
      return;
    }
    final projected = first.add(_gap * _queue.length);
    if (projected.isAfter(deadline)) {
      throw LimiterRefused(
        LimiterRefusal.wouldWait,
        retryIn: projected.difference(now),
      );
    }
    if (_queue.length >= budget.maxQueue && !_makeRoom(now, priority)) {
      throw const LimiterRefused(LimiterRefusal.queueFull);
    }
    final waiter = _Waiter(charged, priority, deadline);
    _queue.add(waiter);
    _arm();
    return waiter.done.future;
  }

  /// [acquire], then [action]; a server's slow-down in its error is obeyed
  /// ([pushedBack]) and a send that goes through eases the gap.
  Future<T> run<T>(
    Future<T> Function() action, {
    int cost = 1,
    Duration? maxWait,
    LimiterPriority priority = LimiterPriority.interactive,
  }) async {
    await acquire(cost: cost, maxWait: maxWait, priority: priority);
    try {
      final result = await action();
      succeeded();
      return result;
    } catch (error) {
      final slow = serverSlowDownOf(error);
      if (slow != null) pushedBack(retryAfter: slow);
      rethrow;
    }
  }

  /// A send went through: the gap eases back towards the budget's.
  void succeeded() {
    if (_gap <= budget.gap) return;
    _refill(_now());
    final eased = _gap * 3 ~/ 4;
    _gap = eased < budget.gap ? budget.gap : eased;
  }

  /// A server asked to slow down. With [retryAfter] (a named wait) the
  /// account rests exactly that long (at most [LimiterBudget.maxRest]);
  /// without one the gap doubles, up to [LimiterBudget.maxGap].
  void pushedBack({Duration? retryAfter}) {
    final now = _now();
    if (retryAfter != null && retryAfter > Duration.zero) {
      final rest = retryAfter > budget.maxRest ? budget.maxRest : retryAfter;
      final until = now.add(rest);
      final current = _restUntil;
      if (current == null || until.isAfter(current)) _restUntil = until;
    } else {
      _refill(now);
      final base = _gap > Duration.zero
          ? _gap
          : const Duration(milliseconds: 250);
      final doubled = base * 2;
      _gap = doubled > budget.maxGap ? budget.maxGap : doubled;
      // The slower pace starts now, not after the burst left in the bucket.
      _tokens = 0;
    }
    // Sends that cannot get their turn before their deadline give way now.
    final earliest = _earliest(now, 1);
    for (final waiter in List.of(_queue)) {
      if (earliest.isAfter(waiter.deadline)) {
        _queue.remove(waiter);
        waiter.done.completeError(
          LimiterRefused(
            LimiterRefusal.wouldWait,
            retryIn: earliest.difference(now),
          ),
        );
      }
    }
    _arm();
  }

  /// Fails everything waiting; later sends are refused.
  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    for (final waiter in List.of(_queue)) {
      waiter.done.completeError(const LimiterRefused(LimiterRefusal.closed));
    }
    _queue.clear();
  }

  // Making room: first anything past its deadline, then the oldest bulk send
  // (only for an interactive one).
  bool _makeRoom(DateTime now, LimiterPriority incoming) {
    for (final waiter in List.of(_queue)) {
      if (waiter.deadline.isBefore(now)) {
        _queue.remove(waiter);
        waiter.done.completeError(const LimiterRefused(LimiterRefusal.expired));
        return true;
      }
    }
    if (incoming == LimiterPriority.interactive) {
      for (final waiter in _queue) {
        if (waiter.priority == LimiterPriority.bulk) {
          _queue.remove(waiter);
          waiter.done.completeError(const LimiterRefused(LimiterRefusal.shed));
          return true;
        }
      }
    }
    return false;
  }

  void _refill(DateTime now) {
    if (_gap > Duration.zero) {
      final elapsed = now.difference(_refilledAt);
      if (!elapsed.isNegative) {
        _tokens = (_tokens + elapsed.inMicroseconds / _gap.inMicroseconds)
            .clamp(0, budget.burst.toDouble())
            .toDouble();
      }
    } else {
      _tokens = budget.burst.toDouble();
    }
    _refilledAt = now;
  }

  void _forget(DateTime now) {
    final cutoff = now.subtract(budget.window);
    while (_spent.isNotEmpty && !_spent.first.$1.isAfter(cutoff)) {
      _spent.removeAt(0);
    }
  }

  /// When a send of [cost] may start, ignoring the queue.
  DateTime _earliest(DateTime now, int cost) {
    var at = now;
    final rest = _restUntil;
    if (rest != null && rest.isAfter(at)) at = rest;
    if (_gap > Duration.zero) {
      final elapsed = now.difference(_refilledAt);
      final tokens = (_tokens + elapsed.inMicroseconds / _gap.inMicroseconds)
          .clamp(0, budget.burst.toDouble());
      if (tokens < 1) {
        final wait = Duration(
          microseconds: ((1 - tokens) * _gap.inMicroseconds).ceil(),
        );
        final tokenAt = now.add(wait);
        if (tokenAt.isAfter(at)) at = tokenAt;
      }
    }
    final quota = budget.quota;
    if (quota != null) {
      _forget(now);
      var used = 0;
      for (final (_, spent) in _spent) {
        used += spent;
      }
      // Walk the window forward until enough of it has been spent and
      // forgotten.
      var index = 0;
      while (used + cost > quota && index < _spent.length) {
        used -= _spent[index].$2;
        final frees = _spent[index].$1.add(budget.window);
        if (frees.isAfter(at)) at = frees;
        index++;
      }
    }
    return at;
  }

  void _start(DateTime now, int cost) {
    _refill(now);
    if (_gap > Duration.zero) {
      _tokens = _tokens >= 1 ? _tokens - 1 : 0;
    }
    if (budget.quota != null) {
      _spent.add((now, cost));
      // A cap on the book, whatever the quota.
      if (_spent.length > 4096) _spent.removeAt(0);
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_queue.isEmpty || _closed) return;
    final now = _now();
    var at = _earliest(now, _queue.first.cost);
    // Wake for the first deadline too, to let that send go.
    for (final waiter in _queue) {
      if (waiter.deadline.isBefore(at)) at = waiter.deadline;
    }
    var delay = at.difference(now);
    if (delay < const Duration(milliseconds: 1)) {
      delay = const Duration(milliseconds: 1);
    }
    _timer = _timerFactory(delay, _pump);
  }

  void _pump() {
    _timer = null;
    if (_closed) return;
    final now = _now();
    // The head may start when its turn has come; whoever missed their
    // deadline gives way.
    var progressed = true;
    while (progressed && _queue.isNotEmpty) {
      progressed = false;
      final head = _queue.first;
      if (head.deadline.isBefore(now)) {
        _queue.removeAt(0);
        head.done.completeError(const LimiterRefused(LimiterRefusal.expired));
        progressed = true;
        continue;
      }
      if (!_earliest(now, head.cost).isAfter(now)) {
        _queue.removeAt(0);
        _start(now, head.cost);
        head.done.complete();
        progressed = true;
      }
    }
    // Others behind the head that missed their deadline.
    for (final waiter in List.of(_queue)) {
      if (waiter.deadline.isBefore(now)) {
        _queue.remove(waiter);
        waiter.done.completeError(const LimiterRefused(LimiterRefusal.expired));
      }
    }
    _arm();
  }
}

/// The limiters of the accounts this device has, by key; the least recently
/// used go first when there are many.
class LimiterBook {
  LimiterBook({this.maxLimiters = 64, DateTime Function()? now}) : _now = now;

  final int maxLimiters;
  final DateTime Function()? _now;
  final Map<String, NetworkLimiter> _limiters = {};

  int get length => _limiters.length;

  NetworkLimiter forAccount(String key, LimiterBudget budget) {
    final existing = _limiters.remove(key);
    if (existing != null) return _limiters[key] = existing;
    final limiter = NetworkLimiter(budget, now: _now);
    _limiters[key] = limiter;
    while (_limiters.length > maxLimiters) {
      final oldest = _limiters.keys.first;
      _limiters.remove(oldest)?.close();
    }
    return limiter;
  }

  NetworkLimiter? peek(String key) => _limiters[key];

  void remove(String key) => _limiters.remove(key)?.close();

  void close() {
    for (final limiter in _limiters.values) {
      limiter.close();
    }
    _limiters.clear();
  }
}
