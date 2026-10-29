/// How long to wait before resubscribing after a subscription was cut off
/// for being slow: 2 s, doubling to a minute, back to 2 s only after a
/// batch with envelopes was processed and acknowledged (an empty "in
/// place" batch or a heartbeat proves nothing).
class SubscriptionBackoff {
  final Map<String, int> _cutOffs = {};

  /// Notes one more cut-off for [route] and returns how long to wait.
  Duration cutOff(String route) {
    if (_cutOffs.length >= 64 && !_cutOffs.containsKey(route)) {
      _cutOffs.remove(_cutOffs.keys.first);
    }
    final count = _cutOffs[route] = (_cutOffs[route] ?? 0) + 1;
    final seconds = 2 << (count - 1).clamp(0, 5);
    return Duration(seconds: seconds.clamp(2, 60));
  }

  /// A real batch got through for [route].
  void delivered(String route) => _cutOffs.remove(route);
}
