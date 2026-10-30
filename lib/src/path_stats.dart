/// What one path (a route, or a transport to one contact) has shown so far:
/// how long a round trip takes, how many bytes a second it moves, how often
/// it fails, and whether it is resting after failing. The route health
/// tracker, the transport registry (route ranking, the wait before another
/// copy goes out) and the file-block striper all keep their numbers here, so
/// there is one set of figures per path rather than three.
library;

import 'dart:math';

/// Weight of a new sample in the moving averages.
const double kPathStatsAlpha = 0.3;

/// Weight of a new outcome in the loss figure.
const double kPathLossAlpha = 0.2;

class PathStats {
  PathStats({this.priorBytesPerSecond});

  /// Throughput assumed until a transfer has been measured.
  final double? priorBytesPerSecond;

  /// Moving average of round trips of small messages, in milliseconds.
  double? rttMs;

  /// Moving average of how fast transfers went, in bytes a second; the prior
  /// until [throughputSamples] is above zero.
  double? _bytesPerSecond;
  int throughputSamples = 0;

  /// Moving average of failures (0 never fails, 1 always).
  double loss = 0;
  int failureStreak = 0;
  DateTime? lastSuccessAt;
  DateTime? lastFailureAt;

  /// Until when the path rests after failing (or after a server asked for a
  /// pause).
  DateTime? cooldownUntil;

  double? get bytesPerSecond => throughputSamples > 0
      ? _bytesPerSecond
      : _bytesPerSecond ?? priorBytesPerSecond;

  /// Whether a transfer has been measured.
  bool get hasThroughput => throughputSamples > 0;

  /// Whether anything has been measured or has failed.
  bool get hasHistory =>
      rttMs != null ||
      throughputSamples > 0 ||
      lastSuccessAt != null ||
      lastFailureAt != null;

  bool coolingAt(DateTime now) => cooldownUntil?.isAfter(now) ?? false;

  /// The wait after the [streak]th failure in a row: 15 s, doubling to 10
  /// minutes (what transports to a contact use).
  static Duration defaultCooldown(int streak) =>
      Duration(seconds: min(15 * (1 << min(max(streak, 1) - 1, 10)), 600));

  /// A message or transfer went through. [rtt] times a small message;
  /// [bytes] over [took] times a transfer.
  void recordSuccess(
    DateTime now, {
    Duration? rtt,
    int? bytes,
    Duration? took,
  }) {
    if (rtt != null) {
      final sample = rtt.inMicroseconds / 1000;
      final previous = rttMs;
      rttMs = previous == null
          ? sample
          : previous * (1 - kPathStatsAlpha) + sample * kPathStatsAlpha;
    }
    if (bytes != null && took != null && bytes > 0) {
      final seconds = took.inMicroseconds / 1e6;
      if (seconds > 0) {
        final sample = bytes / seconds;
        final previous = _bytesPerSecond;
        _bytesPerSecond = throughputSamples == 0 || previous == null
            ? sample
            : previous * (1 - kPathStatsAlpha) + sample * kPathStatsAlpha;
        throughputSamples++;
      }
    }
    loss = loss * (1 - kPathLossAlpha);
    failureStreak = 0;
    cooldownUntil = null;
    lastSuccessAt = now;
  }

  /// A send failed. The path rests [cooldown] (or [until]); the streak and
  /// the loss grow unless [grow] is false (a server asking for a pause is
  /// not a broken path, and a failure while already resting adds nothing).
  void recordFailure(
    DateTime now, {
    Duration? cooldown,
    DateTime? until,
    bool grow = true,
  }) {
    lastFailureAt = now;
    if (grow) {
      failureStreak = failureStreak < 64 ? failureStreak + 1 : 64;
      loss = loss * (1 - kPathLossAlpha) + kPathLossAlpha;
    }
    cooldownUntil =
        until ?? now.add(cooldown ?? defaultCooldown(failureStreak));
  }

  /// Forgets the failures and the rest (the network changed), but keeps the
  /// speed figures.
  void clearCooldown() {
    failureStreak = 0;
    cooldownUntil = null;
  }

  PathStats clone() => PathStats(priorBytesPerSecond: priorBytesPerSecond)
    ..rttMs = rttMs
    .._bytesPerSecond = _bytesPerSecond
    ..throughputSamples = throughputSamples
    ..loss = loss
    ..failureStreak = failureStreak
    ..lastSuccessAt = lastSuccessAt
    ..lastFailureAt = lastFailureAt
    ..cooldownUntil = cooldownUntil;
}

/// Keeps the stats of many paths, the least recently used going first when
/// there are too many.
class PathStatsBook<K> {
  PathStatsBook({this.maxEntries = 4096, this.prior});

  final int maxEntries;
  final double? Function(K key)? prior;
  final Map<K, PathStats> _entries = {};

  int get length => _entries.length;

  /// The stats of [key] if any were kept; does not create them.
  PathStats? peek(K key) => _entries[key];

  /// The stats of [key], created when new; counts as a use.
  PathStats touch(K key) {
    final entry =
        _entries.remove(key) ??
        PathStats(priorBytesPerSecond: prior?.call(key));
    _entries[key] = entry;
    if (_entries.length > maxEntries) _entries.remove(_entries.keys.first);
    return entry;
  }

  void clear() => _entries.clear();
}
