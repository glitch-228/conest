import 'own_device_sync_policy.dart';

/// Whether something noted at [at] still counts at [now] for [lifetime]. A
/// time ahead of [now] (a clock that was set back) does not count: it would
/// otherwise never run out.
bool isFresh(DateTime at, DateTime now, Duration lifetime) {
  final age = now.difference(at);
  return !age.isNegative && age <= lifetime;
}

/// Decides, per other own device, whether a block of a file may be served
/// now, and how long it has to wait to keep to the sync speed.
///
/// One gate for every route a block can leave on (LAN, Iroh, relay): the
/// caller asks once, when it is about to read and send a block. A permission
/// that says no spends nothing. A block that would wait longer than
/// [maxWait] is refused and spends nothing either (the other device asks
/// again), and what was spent for a block that then is not served is given
/// back with [refund]. A clock set back clears what was owed, so it cannot
/// hold a device's requests off for hours.
/// Bounded in devices; a pacer that is evicted only forgets how busy it was.
class OwnDeviceServeGate {
  OwnDeviceServeGate({
    DateTime Function()? now,
    this.maxDevices = 16,
    this.maxWait = const Duration(minutes: 3),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final int maxDevices;
  final Duration maxWait;
  final Map<String, DateTime> _freeAt = {};
  DateTime? _lastNow;

  int get length => _freeAt.length;

  /// When [deviceId] is served next without waiting, if it is busy.
  DateTime? busyUntil(String deviceId) => _freeAt[deviceId];

  static Duration _cost(int bytes, int rate) =>
      Duration(microseconds: (bytes * 1e6 / rate).round());

  /// How long to wait before serving [bytes] to [deviceId] under
  /// [permission]; [Duration.zero] to serve at once; null to serve nothing
  /// now.
  Duration? admit(String deviceId, int bytes, SyncPermission permission) {
    if (!permission.allowed) return null;
    final rate = permission.bytesPerSecond;
    if (rate == null || rate <= 0) return Duration.zero;
    final now = _now();
    // A clock set back would leave debts hours ahead: start again.
    final seen = _lastNow;
    _lastNow = now;
    if (seen != null && now.isBefore(seen)) _freeAt.clear();
    final busyUntil = _freeAt[deviceId];
    final start = busyUntil != null && busyUntil.isAfter(now) ? busyUntil : now;
    final wait = start.difference(now);
    if (wait > maxWait) return null;
    // Most recently used last, so the oldest is the one to go.
    _freeAt.remove(deviceId);
    _freeAt[deviceId] = start.add(_cost(bytes, rate));
    while (_freeAt.length > maxDevices) {
      _freeAt.remove(_freeAt.keys.first);
    }
    return wait;
  }

  /// A block admitted for [deviceId] was not served after all: its share
  /// of the pace is given back.
  void refund(String deviceId, int bytes, SyncPermission permission) {
    final rate = permission.bytesPerSecond;
    final busyUntil = _freeAt[deviceId];
    if (rate == null || rate <= 0 || busyUntil == null) return;
    final back = busyUntil.subtract(_cost(bytes, rate));
    _freeAt[deviceId] = back.isBefore(_now()) ? _now() : back;
  }

  void forget(String deviceId) => _freeAt.remove(deviceId);

  void clear() => _freeAt.clear();
}
