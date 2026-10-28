/// Shares a file's blocks between the routes to one peer (LAN, Iroh…) in
/// proportion to what each delivers: each block goes to the route whose
/// measured speed, shared with the blocks already on it, is best. A route
/// that fails rests for a while; a block that is late is sent again on
/// another route, within a small budget (hedging).
///
/// Pure bookkeeping with an injectable clock; the caller sends.
class RouteStriper<R> {
  RouteStriper({
    DateTime Function()? now,
    Map<R, double> priorBytesPerSecond = const {},
    this.maxHedgeShare = 0.10,
    this.maxHedgesInFlight = 2,
  }) : _now = now ?? DateTime.now,
       _prior = priorBytesPerSecond;

  final DateTime Function() _now;
  final Map<R, double> _prior;

  /// Extra bytes hedging may add, as a share of the bytes sent.
  final double maxHedgeShare;
  final int maxHedgesInFlight;

  static const _defaultPrior = 1024.0 * 1024; // 1 MB/s until measured.
  static const _restAfterFailure = Duration(seconds: 5);
  static const _maxRest = Duration(minutes: 5);
  static const _minHedgeDelay = Duration(seconds: 3);

  final Map<R, _RouteState> _routes = {};
  int _sentBytes = 0;
  int _hedgedBytes = 0;
  int _hedgesInFlight = 0;

  _RouteState _state(R route) => _routes.putIfAbsent(
    route,
    () => _RouteState(_prior[route] ?? _defaultPrior),
  );

  /// Measured speed of [route] (bytes a second, smoothed).
  double speedOf(R route) => _state(route).bytesPerSecond;

  /// [available] routes, best first for the next block: resting routes
  /// last, then by speed shared with the blocks already in flight on it.
  List<R> order(Iterable<R> available) {
    final now = _now();
    final routes = available.toSet().toList();
    double score(R route) {
      final state = _state(route);
      return state.bytesPerSecond / (state.inFlight + 1);
    }

    bool resting(R route) => _state(route).restingUntil?.isAfter(now) == true;
    // A route known to work, and not resting.
    final working = routes
        .where((r) => _state(r).samples > 0 && !resting(r))
        .toList();
    // A route not measured yet gets one block, so its speed is learned
    // rather than guessed: when nothing is known to work, or when every
    // route known to work is busy. Never ahead of an idle working route,
    // and a route that failed rests longer each time (see [failed]).
    final workingAllBusy = working.every((r) => _state(r).inFlight > 0);
    bool probe(R route) =>
        _state(route).samples == 0 &&
        _state(route).inFlight == 0 &&
        !resting(route) &&
        (working.isEmpty || workingAllBusy);
    routes.sort((a, b) {
      final rest = (resting(a) ? 1 : 0).compareTo(resting(b) ? 1 : 0);
      if (rest != 0) return rest;
      final first = (probe(a) ? 0 : 1).compareTo(probe(b) ? 0 : 1);
      if (first != 0) return first;
      return score(b).compareTo(score(a));
    });
    return routes;
  }

  /// Whether [route] failed lately and is resting.
  bool isResting(R route) =>
      _state(route).restingUntil?.isAfter(_now()) == true;

  /// Whether [route] has not delivered a block yet (its speed is a guess).
  bool unmeasured(R route) => _state(route).samples == 0;

  /// A block of [bytes] starts on [route].
  StripeLease<R> begin(R route, int bytes, {bool hedge = false}) {
    final state = _state(route);
    state.inFlight++;
    if (hedge) {
      _hedgesInFlight++;
      _hedgedBytes += bytes;
    }
    return StripeLease._(route, bytes, _now(), hedge);
  }

  /// The block arrived: its time feeds [route]'s speed.
  void succeeded(StripeLease<R> lease) {
    if (!_end(lease)) return;
    final state = _state(lease.route);
    final seconds = _now().difference(lease.startedAt).inMicroseconds / 1e6;
    if (seconds > 0 && lease.bytes > 0) {
      final sample = lease.bytes / seconds;
      state.bytesPerSecond = state.samples == 0
          ? sample
          : state.bytesPerSecond * 0.7 + sample * 0.3;
      state.samples++;
      state.blockSeconds
        ..add(seconds)
        ..removeRange(
          0,
          state.blockSeconds.length > 32 ? state.blockSeconds.length - 32 : 0,
        );
    }
    state.restingUntil = null;
    state.failures = 0;
    _sentBytes += lease.bytes;
  }

  /// The block did not go on [route]: it rests, for 5 s the first time and
  /// twice as long for each failure in a row (to 5 minutes).
  void failed(StripeLease<R> lease) {
    if (!_end(lease)) return;
    final state = _state(lease.route);
    // Blocks that were already in flight when it began resting do not
    // make it rest longer.
    final already = state.restingUntil?.isAfter(_now()) == true;
    if (!already) {
      state.failures = state.failures < 16 ? state.failures + 1 : 16;
    }
    final rest = _restAfterFailure * (1 << (state.failures - 1).clamp(0, 6));
    state.restingUntil = _now().add(rest > _maxRest ? _maxRest : rest);
  }

  bool _end(StripeLease<R> lease) {
    if (lease._ended) return false;
    lease._ended = true;
    final state = _state(lease.route);
    if (state.inFlight > 0) state.inFlight--;
    if (lease.hedge && _hedgesInFlight > 0) _hedgesInFlight--;
    return true;
  }

  /// How long a block on [route] may take before another route may send
  /// it too: twice the slow end (90th percentile) of its recent blocks, at
  /// least 3 s.
  Duration hedgeDelay(R route) {
    final times = List<double>.of(_state(route).blockSeconds)..sort();
    if (times.isEmpty) return _minHedgeDelay;
    final p90 = times[((times.length - 1) * 0.9).round()];
    final delay = Duration(microseconds: (p90 * 2 * 1e6).round());
    return delay > _minHedgeDelay ? delay : _minHedgeDelay;
  }

  /// Whether a block of [bytes] may be sent once more on another route. A
  /// block on a route not measured yet ([probing]) may always be, within the
  /// number in flight: it would otherwise wait out a route that may be dead.
  bool mayHedge(int bytes, {bool probing = false}) =>
      _hedgesInFlight < maxHedgesInFlight &&
      (probing || _hedgedBytes + bytes <= (_sentBytes + bytes) * maxHedgeShare);
}

class StripeLease<R> {
  StripeLease._(this.route, this.bytes, this.startedAt, this.hedge);
  final R route;
  final int bytes;
  final DateTime startedAt;
  final bool hedge;
  bool _ended = false;
}

class _RouteState {
  _RouteState(this.bytesPerSecond);
  double bytesPerSecond;
  int samples = 0;
  int inFlight = 0;
  int failures = 0;
  DateTime? restingUntil;
  final List<double> blockSeconds = [];
}
