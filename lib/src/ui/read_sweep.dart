import 'dart:async';

/// When an open chat marks what is on screen as read: a short delay after
/// the last scroll, so the unread badge has time to show and a burst of new
/// messages doesn't clear it at once.
///
/// Scrolling pushes a pending sweep out, but only [maxRestarts] times; any
/// other reason to sweep (a rebuild, a new message) leaves a pending sweep
/// alone. Rebuilds come with every controller change, so restarting on each
/// could put the sweep off for as long as the app stays busy.
class ReadSweepTimer {
  ReadSweepTimer({
    this.delay = const Duration(milliseconds: 800),
    this.maxRestarts = 3,
  });

  final Duration delay;
  final int maxRestarts;
  Timer? _timer;
  int _restarts = 0;

  bool get pending => _timer?.isActive == true;

  void schedule(void Function() run, {bool restart = false}) {
    if (pending) {
      if (!restart || _restarts >= maxRestarts) return;
      _restarts++;
      _timer!.cancel();
    } else {
      _restarts = 0;
    }
    _timer = Timer(delay, run);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
