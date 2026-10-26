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
    double score(R route) {
      final state = _state(route);
      return state.bytesPerSecond / (state.inFlight + 1);
    }

    bool resting(R route) => _state(route).restingUntil?.isAfter(now) == true;
    // A route not measured yet gets one block (when it has none), so its
    // speed is learned rather than guessed.
    bool probe(R route) =>
        _state(route).samples == 0 && _state(route).inFlight == 0;
    final routes = available.toSet().toList()
      ..sort((a, b) {
        final rest = (resting(a) ? 1 : 0).compareTo(resting(b) ? 1 : 0);
        if (rest != 0) return rest;
        final first = (probe(a) ? 0 : 1).compareTo(probe(b) ? 0 : 1);
        if (first != 0) return first;
        return score(b).compareTo(score(a));
      });
    return routes;
  }

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
    _sentBytes += lease.bytes;
  }

  /// The block did not go on [route]: it rests for a few seconds.
  void failed(StripeLease<R> lease) {
    if (!_end(lease)) return;
    _state(lease.route).restingUntil = _now().add(_restAfterFailure);
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

  /// Whether a block of [bytes] may be sent once more on another route.
  bool mayHedge(int bytes) =>
      _hedgesInFlight < maxHedgesInFlight &&
      _hedgedBytes + bytes <= (_sentBytes + bytes) * maxHedgeShare;
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
  DateTime? restingUntil;
  final List<double> blockSeconds = [];
}
