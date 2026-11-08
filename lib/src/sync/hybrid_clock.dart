/// The clock of a shared setting (M33): the time it was written in
/// milliseconds, and the device that wrote it. A device writing takes the
/// later of its own time and one past the last clock it saw for that
/// setting, so a clock that runs slow never loses to an older write. Two
/// writes at the same millisecond go to the device with the higher id, so
/// every device ends up with the same winner.
class HybridClock implements Comparable<HybridClock> {
  const HybridClock(this.milliseconds, this.deviceId);

  final int milliseconds;
  final String deviceId;

  /// How far ahead of this device's own time a clock may be before it is
  /// taken as wrong (and refused, not cut down to size).
  static const Duration maxAhead = Duration(minutes: 5);

  /// The clock for a write made now by [deviceId]: never before one past
  /// [lastSeen].
  factory HybridClock.next({
    required int nowMilliseconds,
    required String deviceId,
    HybridClock? lastSeen,
  }) {
    final after = lastSeen == null ? 0 : lastSeen.milliseconds + 1;
    return HybridClock(
      nowMilliseconds > after ? nowMilliseconds : after,
      deviceId,
    );
  }

  /// `milliseconds|deviceId`.
  String encode() => '$milliseconds|$deviceId';

  /// Null for anything that is not an encoded clock.
  static HybridClock? parse(Object? text) {
    if (text is! String || text.length > 200) return null;
    final cut = text.indexOf('|');
    if (cut <= 0 || cut == text.length - 1) return null;
    final milliseconds = int.tryParse(text.substring(0, cut));
    if (milliseconds == null || milliseconds < 0) return null;
    return HybridClock(milliseconds, text.substring(cut + 1));
  }

  /// A clock from another device, [milliseconds] and [deviceId] as sent;
  /// null when it is not one, or lies further ahead of [nowMilliseconds]
  /// than [maxAhead].
  static HybridClock? fromPeer({
    required Object? milliseconds,
    required Object? deviceId,
    required int nowMilliseconds,
  }) {
    if (milliseconds is! int ||
        milliseconds < 0 ||
        deviceId is! String ||
        deviceId.isEmpty ||
        deviceId.length > 160 ||
        milliseconds > nowMilliseconds + maxAhead.inMilliseconds) {
      return null;
    }
    return HybridClock(milliseconds, deviceId);
  }

  @override
  int compareTo(HybridClock other) {
    final byTime = milliseconds.compareTo(other.milliseconds);
    return byTime != 0 ? byTime : deviceId.compareTo(other.deviceId);
  }

  bool isAfter(HybridClock other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is HybridClock &&
      other.milliseconds == milliseconds &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(milliseconds, deviceId);

  @override
  String toString() => encode();
}
