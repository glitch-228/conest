import 'models.dart';

/// Length of time `lastTwoWaySuccessAt` keeps a contact in the
/// [ContactReachabilityState.online] band.
const Duration kOnlineReachabilityWindow = Duration(minutes: 2);

/// `lastAnySignalAt` keeps a contact in the [seenRecently] band for this long.
const Duration kSeenRecentlyReachabilityWindow = Duration(minutes: 10);

/// `lastTwoWaySuccessAt` keeps a contact in the [known] band for this long
/// (the fallback below `online`/`seenRecently`).
const Duration kKnownReachabilityWindow = Duration(hours: 24);

/// Per-contact reachability state machine. Reads and writes go through the
/// snapshot callbacks the controller supplies, so the source of truth still
/// lives on [VaultSnapshot.reachabilityRecords] — this class is just the
/// logic that mutates it.
class ReachabilityTracker {
  ReachabilityTracker({
    required List<ContactReachabilityRecord> Function() recordsProvider,
    required void Function(List<ContactReachabilityRecord>) recordsUpdater,
    required DateTime Function() nowProvider,
  }) : _recordsProvider = recordsProvider,
       _recordsUpdater = recordsUpdater,
       _nowProvider = nowProvider;

  final List<ContactReachabilityRecord> Function() _recordsProvider;
  final void Function(List<ContactReachabilityRecord>) _recordsUpdater;
  final DateTime Function() _nowProvider;

  ContactReachabilityRecord? recordByDeviceId(String deviceId) {
    for (final record in _recordsProvider()) {
      if (record.deviceId == deviceId) {
        return record;
      }
    }
    return null;
  }

  ContactReachabilityState stateFor(String deviceId, {DateTime? now}) {
    final record = recordByDeviceId(deviceId);
    if (record == null) {
      return ContactReachabilityState.unknown;
    }
    final currentTime = (now ?? _nowProvider()).toUtc();
    final lastTwoWaySuccessAt = record.lastTwoWaySuccessAt;
    if (lastTwoWaySuccessAt != null &&
        currentTime.difference(lastTwoWaySuccessAt) <=
            kOnlineReachabilityWindow) {
      return ContactReachabilityState.online;
    }
    // "Seen recently" must reflect a real encrypted exchange, not just a
    // successful route probe. lastAvailablePathAt is still recorded for
    // diagnostics and contributes to the "known" fallback below, but it does
    // not by itself promote the visible chip.
    final recentObservation = record.lastAnySignalAt;
    if (recentObservation != null &&
        currentTime.difference(recentObservation) <=
            kSeenRecentlyReachabilityWindow) {
      return ContactReachabilityState.seenRecently;
    }
    if (lastTwoWaySuccessAt != null &&
        currentTime.difference(lastTwoWaySuccessAt) <=
            kKnownReachabilityWindow) {
      return ContactReachabilityState.known;
    }
    return ContactReachabilityState.unknown;
  }

  void noteAnySignal(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _nowProvider()).toUtc();
    _upsert(
      deviceId,
      (current) => current.copyWith(lastAnySignalAt: timestamp),
    );
  }

  void noteTwoWaySuccess(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _nowProvider()).toUtc();
    _upsert(
      deviceId,
      (current) => current.copyWith(
        lastTwoWaySuccessAt: timestamp,
        lastAnySignalAt: timestamp,
      ),
    );
  }

  void noteHeartbeatAttempt(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _nowProvider()).toUtc();
    _upsert(
      deviceId,
      (current) => current.copyWith(lastHeartbeatAttemptAt: timestamp),
    );
  }

  void noteHeartbeatReply(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _nowProvider()).toUtc();
    _upsert(
      deviceId,
      (current) => current.copyWith(lastHeartbeatReplyAt: timestamp),
    );
  }

  void noteAvailablePath(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _nowProvider()).toUtc();
    _upsert(
      deviceId,
      (current) => current.copyWith(lastAvailablePathAt: timestamp),
    );
  }

  void noteFailure(String deviceId, {DateTime? at}) {
    final timestamp = (at ?? _nowProvider()).toUtc();
    _upsert(deviceId, (current) => current.copyWith(lastFailureAt: timestamp));
  }

  /// Ensures a record exists for [deviceId] without modifying any timestamps.
  /// Used when adding/repairing a contact to avoid a later state lookup
  /// returning [ContactReachabilityState.unknown] just because no record
  /// has been written.
  void ensure(String deviceId) {
    _upsert(deviceId, (current) => current);
  }

  void remove(String deviceId) {
    final records = _recordsProvider()
        .where((record) => record.deviceId != deviceId)
        .toList(growable: false);
    _recordsUpdater(records);
  }

  void _upsert(
    String deviceId,
    ContactReachabilityRecord Function(ContactReachabilityRecord current)
    update,
  ) {
    final current =
        recordByDeviceId(deviceId) ??
        ContactReachabilityRecord(deviceId: deviceId);
    final updated = update(current);
    final records = List<ContactReachabilityRecord>.from(_recordsProvider());
    final index = records.indexWhere((record) => record.deviceId == deviceId);
    if (index == -1) {
      records.add(updated);
    } else {
      records[index] = updated;
    }
    _recordsUpdater(records);
  }
}
