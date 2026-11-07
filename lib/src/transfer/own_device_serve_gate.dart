import 'own_device_sync_policy.dart';

/// Decides, per other own device, whether a block of a file may be served
/// now, and how long it has to wait to keep to the sync speed.
///
/// One gate for every route a block can leave on (LAN, Iroh, relay): the
/// caller asks once, before it reads or sends anything. A permission that
/// says no spends nothing. A block that would wait longer than [maxWait] is
/// refused and spends nothing either (the other device asks again), so one
/// device that asks for far more than the cap cannot build up a debt that
/// holds back its later requests. Bounded in devices; a pacer that is
/// evicted only forgets how busy it was.
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

  int get length => _freeAt.length;

  /// How long to wait before serving [bytes] to [deviceId] under
  /// [permission]; [Duration.zero] to serve at once; null to serve nothing
  /// now.
  Duration? admit(String deviceId, int bytes, SyncPermission permission) {
    if (!permission.allowed) return null;
    final rate = permission.bytesPerSecond;
    if (rate == null || rate <= 0) return Duration.zero;
    final now = _now();
    final busyUntil = _freeAt[deviceId];
    final start = busyUntil != null && busyUntil.isAfter(now) ? busyUntil : now;
    final wait = start.difference(now);
    if (wait > maxWait) return null;
    // Most recently used last, so the oldest is the one to go.
    _freeAt.remove(deviceId);
    _freeAt[deviceId] = start.add(
      Duration(microseconds: (bytes * 1e6 / rate).round()),
    );
    while (_freeAt.length > maxDevices) {
      _freeAt.remove(_freeAt.keys.first);
    }
    return wait;
  }

  void forget(String deviceId) => _freeAt.remove(deviceId);

  void clear() => _freeAt.clear();
}
