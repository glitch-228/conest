import 'dart:async';

/// Where a hint that the links changed came from.
enum LinkEventSource {
  /// `connectivity_plus` (the default network changed).
  connectivity,

  /// The native monitor on Linux and Windows (netlink, IP change events).
  monitor,

  /// Android's `registerNetworkCallback`. It fires at once for the
  /// networks already there, and USB tethering with the phone as host raises
  /// none: it says nothing about whether the broadcasts below work.
  androidNetwork,

  /// Android's `USB_STATE` broadcast (extras `connected`, `rndis`, `ncm`).
  /// The initial sticky delivery at registration is not passed on.
  androidUsbState,

  /// Android's `TETHER_STATE_CHANGED` broadcast (same sticky rule).
  androidTether,

  /// A look nobody asked for: the Android fallback, or a rediscovery.
  manual,
}

/// Turns every kind of "the links may have changed" into one debounced call
/// of [onChanged], with no polling where the platform has events.
///
/// On Android the two broadcasts are undocumented, so a bounded fallback
/// looks at the interfaces every [fallbackInterval], but only while the app
/// is in the foreground, the cable page is open and LAN is on, and only
/// until a `USB_STATE` or `TETHER_STATE_CHANGED` event proves the events
/// work. A network callback never counts as such a proof.
class LinkWatcher {
  LinkWatcher({
    required Future<void> Function() onChanged,
    this.debounce = const Duration(milliseconds: 500),
    this.fallbackInterval = const Duration(seconds: 30),
    this.androidFallback = false,
    void Function(Object error)? onError,
  }) : _onChanged = onChanged,
       _onError = onError;

  final Future<void> Function() _onChanged;
  final void Function(Object error)? _onError;
  final Duration debounce;
  final Duration fallbackInterval;
  final bool androidFallback;

  Timer? _debounceTimer;
  Timer? _fallbackTimer;
  bool _running = false;
  bool _rerun = false;
  bool _disposed = false;
  bool _eventsWorking = false;
  bool _foreground = false;
  bool _pageOpen = false;
  bool _enabled = false;

  /// Whether an event only the broadcasts raise has come in this run.
  bool get eventsWorking => _eventsWorking;
  bool get fallbackRunning => _fallbackTimer != null;

  void note(LinkEventSource source) {
    if (_disposed) return;
    if (source == LinkEventSource.androidUsbState ||
        source == LinkEventSource.androidTether) {
      _eventsWorking = true;
      _syncFallback();
    }
    // The first event of a burst starts the wait; the rest join it.
    _debounceTimer ??= Timer(debounce, _fire);
  }

  void setForeground(bool value) {
    _foreground = value;
    _syncFallback();
  }

  void setPageOpen(bool value) {
    _pageOpen = value;
    _syncFallback();
  }

  /// LAN is on and Conest is not asleep (cold mode, dormant).
  void setEnabled(bool value) {
    _enabled = value;
    _syncFallback();
  }

  void _syncFallback() {
    final wanted =
        androidFallback &&
        !_eventsWorking &&
        _foreground &&
        _pageOpen &&
        _enabled &&
        !_disposed;
    if (!wanted) {
      _fallbackTimer?.cancel();
      _fallbackTimer = null;
    } else {
      _fallbackTimer ??= Timer.periodic(
        fallbackInterval,
        (_) => note(LinkEventSource.manual),
      );
    }
  }

  void _fire() {
    _debounceTimer = null;
    if (_disposed) return;
    if (_running) {
      _rerun = true;
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    _running = true;
    try {
      await _onChanged();
    } catch (error) {
      _onError?.call(error);
    } finally {
      _running = false;
    }
    if (_rerun && !_disposed) {
      _rerun = false;
      _debounceTimer ??= Timer(debounce, _fire);
    }
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
  }
}
