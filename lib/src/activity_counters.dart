/// What this app does while it looks idle, counted for the debug report
/// (lab runs only): which timers run and how often they fire, how many
/// sockets are kept open, how often the chat list and chat view are rebuilt,
/// how often the controller tells its listeners something changed and how
/// many log lines it writes. Nothing here runs unless [enabled] is set by a
/// debug run, so a release build only pays for one boolean test where a
/// timer is created.
library;

import 'dart:async';
import 'dart:io';

/// A copy of the counters at one moment, to subtract from a later one.
class ActivitySnapshot {
  const ActivitySnapshot._({
    required this.at,
    required this.timerFires,
    required this.timerFiresByOrigin,
    required this.rebuilds,
    required this.notifications,
    required this.logLines,
    required this.socketsOpened,
    required this.socketsClosed,
  });

  final DateTime at;
  final int timerFires;
  final Map<String, int> timerFiresByOrigin;
  final Map<String, int> rebuilds;
  final int notifications;
  final int logLines;
  final int socketsOpened;
  final int socketsClosed;
}

class _TimerStat {
  _TimerStat(this.origin, this.periodic);

  final String origin;
  bool periodic;
  int created = 0;
  int active = 0;
  int fires = 0;

  /// The latest period (periodic) or delay (one-shot).
  int intervalMs = 0;
  int shortestMs = 0;
}

class ActivityCounters {
  ActivityCounters._();

  static final ActivityCounters instance = ActivityCounters._();

  /// Turned on by a debug run before the controller starts.
  static bool enabled = false;
  static bool _socketsCounted = false;

  /// At most this many origins are kept apart; the rest count as "other".
  static const int maxOrigins = 192;

  final Map<String, _TimerStat> _timers = {};
  final Map<String, int> _rebuilds = {};
  int _timerFires = 0;
  int _notifications = 0;
  int _logLines = 0;
  int _socketsOpened = 0;
  int _socketsClosed = 0;
  int _serversBound = 0;
  final Map<int, int> _openByPort = {};
  DateTime _since = DateTime.now();

  /// The zone that counts the timers made in it (see [timerZone]).
  static final ZoneSpecification timerZone = ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      if (!enabled) return parent.createTimer(zone, duration, callback);
      return instance._timer(parent, zone, duration, (_) => callback(), false);
    },
    createPeriodicTimer: (self, parent, zone, period, callback) {
      if (!enabled) {
        return parent.createPeriodicTimer(zone, period, callback);
      }
      return instance._timer(parent, zone, period, callback, true);
    },
  );

  /// Counts from now on and forgets what was counted before.
  void reset() {
    _timers.clear();
    _rebuilds.clear();
    _timerFires = 0;
    _notifications = 0;
    _logLines = 0;
    _socketsOpened = 0;
    _socketsClosed = 0;
    _serversBound = 0;
    _openByPort.clear();
    _since = DateTime.now();
  }

  /// Installs the socket counter (dart:io), once.
  static void countSockets() {
    if (_socketsCounted) return;
    _socketsCounted = true;
    IOOverrides.global = _CountingSockets();
  }

  /// A rebuild of the screen named [what] ("chatList", "chatView").
  void noteRebuild(String what) {
    if (!enabled) return;
    _rebuilds[what] = (_rebuilds[what] ?? 0) + 1;
  }

  /// The controller told its listeners something changed.
  void noteNotification() {
    if (enabled) _notifications++;
  }

  /// A line went into the debug log.
  void noteLogLine() {
    if (enabled) _logLines++;
  }

  Timer _timer(
    ZoneDelegate parent,
    Zone zone,
    Duration duration,
    void Function(Timer) callback,
    bool periodic,
  ) {
    // One-shot and periodic timers of one line are told apart.
    // Short one-shots (a `Future.delayed`, a poll step) are too many to look
    // up where each came from: reading the stack costs a few hundred
    // microseconds each, many times that on a phone's debug build, and they
    // are not what keeps an idle app awake. They count together.
    final origin = !periodic && duration < const Duration(seconds: 1)
        ? 'short one-shots (under 1 s)'
        : '${_originOfCaller()}${periodic ? '' : ' (once)'}';
    final stat = _timers.putIfAbsent(
      _timers.length >= maxOrigins && !_timers.containsKey(origin)
          ? 'other'
          : origin,
      () => _TimerStat(origin, periodic),
    );
    stat.created++;
    stat.active++;
    stat.intervalMs = duration.inMilliseconds;
    if (stat.shortestMs == 0 || duration.inMilliseconds < stat.shortestMs) {
      stat.shortestMs = duration.inMilliseconds;
    }
    if (periodic) stat.periodic = true;
    late final Timer inner;
    var done = false;
    void settle() {
      if (done) return;
      done = true;
      stat.active--;
    }

    void fire(Timer timer) {
      _timerFires++;
      stat.fires++;
      if (!periodic) settle();
      callback(timer);
    }

    inner = periodic
        ? parent.createPeriodicTimer(zone, duration, fire)
        : parent.createTimer(zone, duration, () => fire(inner));
    return _CountedTimer(inner, settle);
  }

  /// The first frame of the call stack inside this app's own code, as
  /// "path/file.dart:line" (one-shot and periodic timers made by the same
  /// line are one origin).
  static String _originOfCaller() {
    final lines = StackTrace.current.toString().split('\n');
    final own = RegExp(r'package:conest/([^\s:)]+\.dart):(\d+)');
    for (final line in lines) {
      if (line.contains('activity_counters.dart')) continue;
      final match = own.firstMatch(line);
      if (match != null) return '${match.group(1)}:${match.group(2)}';
    }
    for (final line in lines) {
      if (line.contains('activity_counters.dart')) continue;
      final match = RegExp(
        r'package:([^\s:)]+/[^\s:)]+\.dart)',
      ).firstMatch(line);
      if (match != null) return match.group(1)!;
    }
    return 'other';
  }

  ActivitySnapshot snapshot() => ActivitySnapshot._(
    at: DateTime.now(),
    timerFires: _timerFires,
    timerFiresByOrigin: {
      for (final entry in _timers.entries) entry.key: entry.value.fires,
    },
    rebuilds: Map.of(_rebuilds),
    notifications: _notifications,
    logLines: _logLines,
    socketsOpened: _socketsOpened,
    socketsClosed: _socketsClosed,
  );

  /// The report section: totals since the start, or since [since] when
  /// given (rates and counts then cover only that time, the idle minutes
  /// of a run for one).
  Map<String, Object?> toJson({ActivitySnapshot? since}) {
    final now = snapshot();
    final from = since?.at ?? _since;
    final seconds = (now.at.difference(from).inMilliseconds / 1000).clamp(
      0.001,
      double.infinity,
    );
    double perMinute(int count) =>
        double.parse((count * 60 / seconds).toStringAsFixed(2));
    double perSecond(int count) =>
        double.parse((count / seconds).toStringAsFixed(2));
    final fires = now.timerFires - (since?.timerFires ?? 0);
    final timers = [
      for (final entry in _timers.entries)
        (
          origin: entry.key,
          stat: entry.value,
          fires:
              entry.value.fires - (since?.timerFiresByOrigin[entry.key] ?? 0),
        ),
    ]..sort((a, b) => b.fires.compareTo(a.fires));
    return {
      'seconds': seconds.round(),
      'timerWakeups': {'count': fires, 'perMinute': perMinute(fires)},
      // The busiest first; a timer that never fired is listed only while
      // it is armed.
      'timers': [
        for (final timer in timers.take(40))
          if (timer.fires > 0 || timer.stat.active > 0)
            {
              'origin': timer.origin,
              'periodic': timer.stat.periodic,
              'intervalMs': timer.stat.intervalMs,
              if (timer.stat.shortestMs != timer.stat.intervalMs)
                'shortestMs': timer.stat.shortestMs,
              'created': timer.stat.created,
              'active': timer.stat.active,
              'fires': timer.fires,
              'perMinute': perMinute(timer.fires),
            },
      ],
      'periodicTimersActive': _timers.values
          .where((stat) => stat.periodic)
          .fold<int>(0, (sum, stat) => sum + stat.active),
      'sockets': {
        'open': _socketsOpened - _socketsClosed,
        'opened': now.socketsOpened - (since?.socketsOpened ?? 0),
        'closed': now.socketsClosed - (since?.socketsClosed ?? 0),
        'listening': _serversBound,
        // Open now, by remote port.
        'openByPort': {
          for (final entry in _openByPort.entries)
            if (entry.value > 0) '${entry.key}': entry.value,
        },
      },
      'rebuilds': {
        for (final entry in now.rebuilds.entries)
          entry.key: {
            'count': entry.value - (since?.rebuilds[entry.key] ?? 0),
            'perSecond': perSecond(
              entry.value - (since?.rebuilds[entry.key] ?? 0),
            ),
          },
      },
      'notifications': {
        'count': now.notifications - (since?.notifications ?? 0),
        'perMinute': perMinute(now.notifications - (since?.notifications ?? 0)),
      },
      'logLines': {
        'count': now.logLines - (since?.logLines ?? 0),
        'perMinute': perMinute(now.logLines - (since?.logLines ?? 0)),
      },
    };
  }

  void _socketOpened(Socket socket, int port) {
    _socketsOpened++;
    _openByPort[port] = (_openByPort[port] ?? 0) + 1;
    socket.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _socketsClosed++;
      _openByPort[port] = (_openByPort[port] ?? 1) - 1;
    });
  }
}

class _CountedTimer implements Timer {
  _CountedTimer(this._inner, this._settle);

  final Timer _inner;
  final void Function() _settle;

  @override
  void cancel() {
    _settle();
    _inner.cancel();
  }

  @override
  bool get isActive => _inner.isActive;

  @override
  int get tick => _inner.tick;
}

/// Counts the sockets the app opens and the ones it listens on.
final class _CountingSockets extends IOOverrides {
  @override
  Future<Socket> socketConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) {
    final socket = super.socketConnect(
      host,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
      timeout: timeout,
    );
    if (ActivityCounters.enabled) {
      socket.then<void>(
        (socket) => ActivityCounters.instance._socketOpened(socket, port),
        onError: (Object _) {},
      );
    }
    return socket;
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) {
    final task = super.socketStartConnect(
      host,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
    );
    if (ActivityCounters.enabled) {
      task.then<void>(
        (task) => task.socket.then<void>(
          (socket) => ActivityCounters.instance._socketOpened(socket, port),
          onError: (Object _) {},
        ),
        onError: (Object _) {},
      );
    }
    return task;
  }

  @override
  Future<ServerSocket> serverSocketBind(
    dynamic address,
    int port, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
  }) {
    final server = super.serverSocketBind(
      address,
      port,
      backlog: backlog,
      v6Only: v6Only,
      shared: shared,
    );
    if (ActivityCounters.enabled) {
      server.then<void>(
        (_) => ActivityCounters.instance._serversBound++,
        onError: (Object _) {},
      );
    }
    return server;
  }
}
