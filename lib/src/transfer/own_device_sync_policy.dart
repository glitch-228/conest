import 'dart:convert';

import 'package:crypto/crypto.dart';

/// How fast this device syncs with the account's other devices. Persisted
/// by name: append only.
enum SyncSpeed {
  /// In the background at a capped rate, on few paths; stops on low
  /// battery or in battery saver.
  steady,

  /// Every path, no cap; needs the user's confirmation each time and gives
  /// way to steady on a metered network.
  fast,

  /// Nothing is synced.
  paused,
}

/// What a sync may use right now.
class SyncPermission {
  const SyncPermission({
    required this.allowed,
    this.bytesPerSecond,
    this.maxPaths = 2,
    this.reason,
    this.speed = SyncSpeed.steady,
  });

  final bool allowed;

  /// Null: no cap.
  final int? bytesPerSecond;
  final int maxPaths;

  /// Why it is not allowed, or why it is slower than asked.
  final String? reason;

  /// The speed in effect (fast can fall back to steady).
  final SyncSpeed speed;

  static const SyncPermission denied = SyncPermission(allowed: false);
}

/// The device conditions that decide what sync may use.
class SyncConditions {
  const SyncConditions({
    this.batteryPercent,
    this.charging = false,
    this.batterySaver = false,
    this.metered = false,
  });

  /// Null when unknown (a desktop without a battery).
  final int? batteryPercent;
  final bool charging;
  final bool batterySaver;
  final bool metered;
}

/// The speed policies (M33): steady, fast, paused.
class OwnDeviceSyncPolicy {
  const OwnDeviceSyncPolicy({
    this.speed = SyncSpeed.steady,
    this.fastConfirmed = false,
    this.steadyBytesPerSecond = 256 * 1024,
    this.steadyPaths = 2,
    this.lowBatteryPercent = 20,
  });

  final SyncSpeed speed;

  /// The user said yes to a fast sync (asked again each time).
  final bool fastConfirmed;
  final int steadyBytesPerSecond;
  final int steadyPaths;
  final int lowBatteryPercent;

  /// Backlog over which fast is worth offering.
  static const int fastOfferBytes = 200 * 1024 * 1024;
  static const int fastOfferMessages = 5000;

  OwnDeviceSyncPolicy copyWith({SyncSpeed? speed, bool? fastConfirmed}) =>
      OwnDeviceSyncPolicy(
        speed: speed ?? this.speed,
        fastConfirmed: fastConfirmed ?? this.fastConfirmed,
        steadyBytesPerSecond: steadyBytesPerSecond,
        steadyPaths: steadyPaths,
        lowBatteryPercent: lowBatteryPercent,
      );

  SyncPermission permit(SyncConditions now) {
    if (speed == SyncSpeed.paused) {
      return const SyncPermission(
        allowed: false,
        reason: 'Sync is paused.',
        speed: SyncSpeed.paused,
      );
    }
    final low =
        now.batteryPercent != null &&
        now.batteryPercent! < lowBatteryPercent &&
        !now.charging;
    if (low || (now.batterySaver && !now.charging)) {
      return SyncPermission(
        allowed: false,
        reason: low ? 'Battery is low.' : 'Battery saver is on.',
        speed: speed,
      );
    }
    if (speed == SyncSpeed.fast) {
      if (!fastConfirmed) {
        return _steady('Fast sync was not confirmed.');
      }
      if (now.metered) {
        return _steady('Fast sync gives way on a metered network.');
      }
      return const SyncPermission(
        allowed: true,
        maxPaths: 8,
        speed: SyncSpeed.fast,
      );
    }
    return _steady(null);
  }

  SyncPermission _steady(String? reason) => SyncPermission(
    allowed: true,
    bytesPerSecond: steadyBytesPerSecond,
    maxPaths: steadyPaths,
    reason: reason,
  );

  /// Whether to ask the user to start a fast sync: a big backlog, and a
  /// network or power that does not cost.
  bool shouldOfferFast({
    required int backlogBytes,
    required int backlogMessages,
    required SyncConditions now,
    bool onMains = false,
  }) =>
      speed != SyncSpeed.paused &&
      (backlogBytes > fastOfferBytes || backlogMessages > fastOfferMessages) &&
      (!now.metered || onMains);
}

/// Paces sending to a rate: how long to wait before [bytes] more may go.
class SyncPacer {
  SyncPacer({this.now = DateTime.now});

  final DateTime Function() now;
  DateTime? _freeAt;

  /// Reserves [bytes] at [bytesPerSecond] (null: no cap) and returns the
  /// wait before sending them.
  Duration reserve(int bytes, int? bytesPerSecond) {
    if (bytesPerSecond == null || bytesPerSecond <= 0) return Duration.zero;
    final t = now();
    final start = _freeAt != null && _freeAt!.isAfter(t) ? _freeAt! : t;
    _freeAt = start.add(
      Duration(microseconds: (bytes * 1e6 / bytesPerSecond).round()),
    );
    return start.difference(t);
  }
}

/// A chat's messages in short: how many and a hash of their ids, to tell
/// whether two devices hold the same without sending the messages.
class ChatDigest {
  const ChatDigest(this.count, this.hash);

  factory ChatDigest.of(Iterable<String> messageIds) {
    final ids = messageIds.toSet().toList()..sort();
    final hash = sha256.convert(utf8.encode(ids.join('\n'))).toString();
    return ChatDigest(ids.length, hash.substring(0, 16));
  }

  final int count;
  final String hash;

  List<Object> toJson() => [count, hash];

  static ChatDigest? fromJson(Object? json) {
    if (json is! List ||
        json.length != 2 ||
        json[0] is! int ||
        json[1] is! String ||
        (json[0] as int) < 0 ||
        (json[1] as String).length != 16) {
      return null;
    }
    return ChatDigest(json[0] as int, json[1] as String);
  }

  @override
  bool operator ==(Object other) =>
      other is ChatDigest && other.count == count && other.hash == hash;

  @override
  int get hashCode => Object.hash(count, hash);
}

/// The chats whose digests differ between [mine] and [theirs], or that the
/// other has and this does not: those are asked for.
List<String> chatsToAsk(
  Map<String, ChatDigest> mine,
  Map<String, ChatDigest> theirs,
) => [
  for (final entry in theirs.entries)
    if (entry.value.count > 0 && mine[entry.key] != entry.value) entry.key,
];
