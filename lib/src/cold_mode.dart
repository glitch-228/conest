/// Cold mode (M25 follow-up): the transports that are not needed right now
/// are stopped outright, not just polled less. One light push stays (the
/// Conest relay's subscription, which the controller keeps), the chat
/// networks keep syncing themselves, and everything else wakes only
///
/// - on a timer, every few minutes (or never: manual refresh only),
/// - when the user refreshes,
/// - to send, for the routes the message needs, and then lingers a little
///   for receipts and replies before going cold again.
library;

import 'dart:async';

/// What the user says about one transport while cold mode is on.
/// Stored by name; new values are appended.
enum ColdTransportMode {
  /// Stopped while not needed (the default in cold mode).
  cold,

  /// Never stopped.
  alwaysOn,

  /// Never started while cold mode is on.
  off;

  static ColdTransportMode parse(Object? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => ColdTransportMode.cold,
  );
}

/// How often a cold device looks for news. Zero is manual only.
const List<int> coldWakeMinuteChoices = [0, 5, 15, 30, 60];
const int defaultColdWakeMinutes = 15;

/// Clamps a stored value to a known choice.
int normalizeColdWakeMinutes(Object? value) {
  final minutes = value is num ? value.toInt() : defaultColdWakeMinutes;
  return coldWakeMinuteChoices.contains(minutes)
      ? minutes
      : defaultColdWakeMinutes;
}

/// One thing cold mode can stop and start: a transport's connections.
class ColdHandle {
  ColdHandle({
    required this.id,
    required this.start,
    required this.stop,
    this.exempt = false,
  });

  /// The transport's name ("iroh", "nostr", "lan", …).
  final String id;
  final Future<void> Function() start;
  final Future<void> Function() stop;

  /// A chat network that syncs by itself: never touched.
  final bool exempt;

  /// Whether it runs now.
  bool up = true;
}

class ColdMode {
  ColdMode({
    DateTime Function()? now,
    this.lingerAfterSend = const Duration(seconds: 60),
    this.holdAfterWake = const Duration(seconds: 30),
    this.fetch,
    this.wakeEvery = _minutes,
  }) : _now = now ?? DateTime.now;

  static Duration _minutes(int minutes) => Duration(minutes: minutes);

  /// How long [configure]'s wake minutes are (tests make them short).
  Duration Function(int minutes) wakeEvery;

  final DateTime Function() _now;

  /// How long routes woken to send stay up for receipts and replies.
  Duration lingerAfterSend;

  /// How long routes woken to look for news stay up.
  Duration holdAfterWake;

  /// Asked to look for news once the routes are up (a poll of the relays
  /// and a group catch-up).
  final Future<void> Function()? fetch;

  /// The user's choice per transport id; unknown ids are cold.
  ColdTransportMode Function(String id) modeOf = (_) => ColdTransportMode.cold;

  /// Told when something the screens show changed.
  void Function()? onChanged;

  /// Told when a transport would not start or stop.
  void Function(String id, Object error)? onError;

  final Map<String, ColdHandle> _handles = {};
  final Map<String, Timer> _sleepTimers = {};
  final Map<String, DateTime> _sleepAt = {};
  final Map<String, Future<void>> _busy = {};
  Timer? _timer;
  Duration? _interval;
  bool _active = false;
  bool _disposed = false;
  DateTime? _lastCheckedAt;
  DateTime? _nextCheckAt;

  bool get active => _active;

  /// Something outside started every transport (the connectivity flags were
  /// applied): they count as up again, and cold ones are stopped next.
  void markAllUp() {
    for (final timer in _sleepTimers.values) {
      timer.cancel();
    }
    _sleepTimers.clear();
    _sleepAt.clear();
    for (final handle in _handles.values) {
      handle.up = true;
    }
  }

  /// When cold mode last looked for news (a timer, a refresh or leaving it).
  DateTime? get lastCheckedAt => _lastCheckedAt;

  /// When the timer looks next; null for manual only or when not cold.
  DateTime? get nextCheckAt => _nextCheckAt;

  /// Ids of the transports that run now.
  Set<String> get upIds => {
    for (final handle in _handles.values)
      if (handle.up) handle.id,
  };

  /// Ids of the transports cold mode manages.
  Set<String> get handleIds => _handles.keys.toSet();

  /// The set of things to manage. Handles seen before keep their state.
  void setHandles(Iterable<ColdHandle> handles) {
    final next = {for (final handle in handles) handle.id: handle};
    for (final id in _handles.keys.toList()) {
      if (!next.containsKey(id)) {
        _sleepTimers.remove(id)?.cancel();
        _sleepAt.remove(id);
        _handles.remove(id);
      }
    }
    for (final handle in next.values) {
      final old = _handles[handle.id];
      if (old != null) {
        handle.up = old.up;
        // The one that stopped is stopped for good: the new handle takes
        // over its state.
      }
      _handles[handle.id] = handle;
      // A transport that appeared while cold: it starts cold, too.
      if (_active && old == null && handle.up) {
        unawaited(_sleepNow(handle));
      }
    }
  }

  /// Turns cold mode on or off, and sets how often it looks for news
  /// (zero: never by itself).
  Future<void> configure({
    required bool active,
    required int wakeMinutes,
  }) async {
    final interval = wakeMinutes <= 0 ? null : wakeEvery(wakeMinutes);
    if (active == _active && interval == _interval) {
      if (active) await _applyModes();
      return;
    }
    _interval = interval;
    if (!active) {
      if (_active) {
        _active = false;
        _timer?.cancel();
        _timer = null;
        _nextCheckAt = null;
        for (final timer in _sleepTimers.values) {
          timer.cancel();
        }
        _sleepTimers.clear();
        _sleepAt.clear();
        // Back to normal: everything runs again.
        for (final handle in _handles.values.toList()) {
          if (!handle.up) await _wakeNow(handle);
        }
        onChanged?.call();
      }
      return;
    }
    final entering = !_active;
    _active = true;
    if (entering) {
      _lastCheckedAt = _now();
    }
    await _applyModes();
    _armTimer();
    onChanged?.call();
  }

  /// Stops what is cold now and starts what is off or always on no more.
  Future<void> _applyModes() async {
    for (final handle in _handles.values.toList()) {
      if (handle.exempt) continue;
      switch (modeOf(handle.id)) {
        case ColdTransportMode.alwaysOn:
          _sleepTimers.remove(handle.id)?.cancel();
          _sleepAt.remove(handle.id);
          if (!handle.up) await _wakeNow(handle);
        case ColdTransportMode.off:
          _sleepTimers.remove(handle.id)?.cancel();
          _sleepAt.remove(handle.id);
          if (handle.up) await _sleepNow(handle);
        case ColdTransportMode.cold:
          // Left up while a wake or a send holds it.
          if (handle.up && !_sleepTimers.containsKey(handle.id)) {
            await _sleepNow(handle);
          }
      }
    }
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = null;
    _nextCheckAt = null;
    final interval = _interval;
    if (!_active || _disposed || interval == null) return;
    _nextCheckAt = _now().add(interval);
    _timer = Timer(interval, () {
      _timer = null;
      unawaited(refresh().catchError((Object _) {}));
    });
  }

  /// Wakes every cold transport, asks for news, and lets them go cold again
  /// after [holdAfterWake]. A timer, a pull to refresh and a refresh button
  /// all come here.
  Future<void> refresh() async {
    if (_disposed) return;
    if (!_active) {
      _lastCheckedAt = _now();
      await fetch?.call();
      onChanged?.call();
      return;
    }
    for (final handle in _handles.values.toList()) {
      if (handle.exempt || modeOf(handle.id) != ColdTransportMode.cold) {
        continue;
      }
      await _hold(handle, holdAfterWake);
    }
    try {
      await fetch?.call();
    } finally {
      _lastCheckedAt = _now();
      _armTimer();
      onChanged?.call();
    }
  }

  /// A message needs the transports [ids]: they start now (the ones that are
  /// cold) and stay up for [lingerAfterSend].
  Future<void> wakeFor(Iterable<String> ids, {Duration? linger}) async {
    if (!_active || _disposed) return;
    for (final id in ids) {
      final handle = _handles[id];
      if (handle == null ||
          handle.exempt ||
          modeOf(id) != ColdTransportMode.cold) {
        continue;
      }
      await _hold(handle, linger ?? lingerAfterSend);
    }
  }

  /// Brings [handle] up if it is down, and keeps it up for [hold] (never
  /// shortening a wait already running).
  Future<void> _hold(ColdHandle handle, Duration hold) async {
    final until = _now().add(hold);
    final current = _sleepAt[handle.id];
    if (current == null || until.isAfter(current)) {
      _sleepAt[handle.id] = until;
      _sleepTimers.remove(handle.id)?.cancel();
      _sleepTimers[handle.id] = Timer(hold, () {
        _sleepTimers.remove(handle.id);
        _sleepAt.remove(handle.id);
        if (_active &&
            !_disposed &&
            modeOf(handle.id) == ColdTransportMode.cold) {
          unawaited(_sleepNow(handle).catchError((Object _) {}));
        }
      });
    }
    if (!handle.up) await _wakeNow(handle);
  }

  Future<void> _wakeNow(ColdHandle handle) => _serial(handle.id, () async {
    if (handle.up) return;
    handle.up = true; // Marked first: a failing start is retried later.
    try {
      await handle.start();
    } catch (error) {
      handle.up = false;
      onError?.call(handle.id, error);
    }
    onChanged?.call();
  });

  Future<void> _sleepNow(ColdHandle handle) => _serial(handle.id, () async {
    if (!handle.up) return;
    handle.up = false;
    try {
      await handle.stop();
    } catch (error) {
      // Counted as stopped: nothing more can be done about it here.
      onError?.call(handle.id, error);
    }
    onChanged?.call();
  });

  /// One start or stop of a transport at a time.
  Future<void> _serial(String id, Future<void> Function() work) {
    final previous = _busy[id] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) => work());
    _busy[id] = next;
    return next.whenComplete(() {
      if (identical(_busy[id], next)) _busy.remove(id);
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final timer in _sleepTimers.values) {
      timer.cancel();
    }
    _sleepTimers.clear();
  }
}
