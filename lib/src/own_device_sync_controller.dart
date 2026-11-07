part of 'messenger_controller.dart';

/// Own-device sync, phase P0 (M33): the speed policy is asked on every path
/// that syncs, and what is kept for another own device is forgotten when
/// that device goes. State lives in the controller's fields (this file adds
/// no fields); everything here is cleared by [_clearOwnDeviceSyncState].
extension OwnDeviceSyncController on MessengerController {
  /// Most blocks waiting for their turn to be served to own devices: in
  /// all, and for one device (a fetch asks for a few at a time).
  static const int _maxOwnServeTimers = 64;
  static const int _maxOwnServeTimersPerDevice = 8;

  /// Requests for blocks that were turned away because the policy said no
  /// (paused, cold in the background, metered): kept to be served when it
  /// says yes, so the other device does not wait for its own slow retry.
  static const int _maxParkedOwnBlocks = 64;
  static const Duration _parkedOwnBlockLifetime = Duration(minutes: 10);

  /// Whether live sync events are held, not sent (sync is paused).
  bool get _liveSyncHeld =>
      ownDeviceSyncPolicy.permitFor(SyncTraffic.live, _syncConditions).hold;

  /// Whether the fast sync the user confirmed still counts.
  bool get _fastSyncConfirmedNow {
    final until = _fastSyncUntil;
    return until != null && _now().isBefore(until);
  }

  /// What serving or fetching file bytes with another own device may use.
  SyncPermission get _ownDeviceFilePermission =>
      ownDeviceSyncPolicy.permitFor(SyncTraffic.files, _syncConditions);

  /// For a block of [bytes] about to be served to own device [requester]:
  /// null to serve nothing now (the policy says no, or it would wait too
  /// long: the device asks again), otherwise how long to wait first.
  Duration? _admitOwnDeviceBlock(ContactRecord requester, int bytes) =>
      _ownServeGate.admit(requester.deviceId, bytes, _ownDeviceFilePermission);

  static String _ownBlockKey(String deviceId, Map<String, dynamic> payload) =>
      '$deviceId|${payload['attachmentId']}|${payload['index']}';

  /// Serves the block asked for in [payload] after [wait], unless the
  /// device was forgotten or this controller disposed meanwhile. Never
  /// holds the inbound path: the request is let go at once. A request for
  /// a block already waiting, or more than a device or this one may keep
  /// waiting, is let go (the other device asks again).
  void _deferOwnDeviceBlock(
    ContactRecord requester,
    Map<String, dynamic> payload,
    Duration wait,
  ) {
    final key = _ownBlockKey(requester.deviceId, payload);
    if (_ownServeTimers.length >= _maxOwnServeTimers ||
        _ownServeTimers.values.any((entry) => entry.key == key) ||
        _ownServeTimers.values
                .where((entry) => entry.deviceId == requester.deviceId)
                .length >=
            _maxOwnServeTimersPerDevice) {
      return;
    }
    _ownServeDeferrals++;
    late final Timer timer;
    timer = Timer(wait, () {
      _ownServeTimers.remove(timer);
      if (_disposed) return;
      unawaited(
        _serveAttachmentChunkRequest(
          requester,
          payload,
          paced: true,
        ).catchError((Object error) {
          appendDebugLog('A deferred block was not served: $error');
        }),
      );
    });
    _ownServeTimers[timer] = _DeferredOwnBlock(requester.deviceId, key);
  }

  /// Keeps a request the policy turned away, to serve when it allows.
  void _parkOwnDeviceBlock(
    ContactRecord requester,
    Map<String, dynamic> payload,
  ) {
    final key = _ownBlockKey(requester.deviceId, payload);
    _parkedOwnBlocks
      ..removeWhere((parked) => parked.key == key)
      ..add(_ParkedOwnBlock(key, requester.deviceId, payload, _now()));
    while (_parkedOwnBlocks.length > _maxParkedOwnBlocks) {
      _parkedOwnBlocks.removeAt(0);
    }
  }

  /// The conditions may have changed (resumed, plugged in, the app opened,
  /// a network switched): the requests kept are asked again, through the
  /// gate like any other, so they are paced.
  void _resumeParkedOwnBlocks() {
    if (_parkedOwnBlocks.isEmpty || !_ownDeviceFilePermission.allowed) return;
    final cutoff = _now().subtract(_parkedOwnBlockLifetime);
    final due = [
      for (final parked in _parkedOwnBlocks)
        if (parked.parkedAt.isAfter(cutoff)) parked,
    ];
    _parkedOwnBlocks.clear();
    for (final parked in due) {
      final requester = _contactByDeviceId(parked.deviceId);
      if (requester == null || !requester.ownDevice) continue;
      unawaited(
        _handleAttachmentChunkRequest(requester, parked.payload).catchError((
          Object error,
        ) {
          appendDebugLog('A kept block request failed: $error');
        }),
      );
    }
  }

  /// Everything kept for the own devices [deviceIds] goes: they were
  /// removed from the account. Their queued sync events, what they said
  /// they hold, what was asked of them, what is waiting to be served to
  /// them, and the sources they were in running fetches.
  void _forgetOwnDevices(Iterable<String> deviceIds) {
    for (final id in deviceIds) {
      _ownReach.remove(id);
      _historyQueue.remove(id);
      _historyAsked.remove(id);
      _historyAskedAt.remove(id);
      _historyTimers.remove(id)?.cancel();
      _historyPagesServed.remove(id);
      _parkedOwnSync.remove(id);
      _ownDeviceAdditions.remove(id);
      _ownListMerges.remove(id);
      _ownDeviceFiles.forgetDevice(id);
      _ownServeGate.forget(id);
      for (final key in [
        for (final key in _ownServing.keys)
          if (key.startsWith('$id|')) key,
      ]) {
        _ownServingCheckedAt.remove(key);
        unawaited(_ownServing.remove(key)?.closeFile() ?? Future<void>.value());
      }
      for (final timer in [
        for (final entry in _ownServeTimers.entries)
          if (entry.value.deviceId == id) entry.key,
      ]) {
        timer.cancel();
        _ownServeTimers.remove(timer);
      }
      _parkedOwnBlocks.removeWhere((parked) => parked.deviceId == id);
      for (final state in _inboundAttachments.values) {
        state.requestedInFlight.removeAll(
          state.sources.remove(BlockSource.peer(id)),
        );
      }
      final queued = _snapshot.pendingAckDeliveries.where(
        (entry) =>
            entry.targetDeviceId == id &&
            entry.kind == PendingAckKind.accountSync,
      );
      if (queued.isNotEmpty) {
        _snapshot = _snapshot.copyWith(
          pendingAckDeliveries: [
            for (final entry in _snapshot.pendingAckDeliveries)
              if (!(entry.targetDeviceId == id &&
                  entry.kind == PendingAckKind.accountSync))
                entry,
          ],
        );
      }
    }
  }

  /// Everything kept in memory for syncing with own devices goes: on
  /// dispose and on a vault reset.
  void _clearOwnDeviceSyncState() {
    for (final timer in _ownServeTimers.keys) {
      timer.cancel();
    }
    _ownServeTimers.clear();
    _parkedOwnBlocks.clear();
    _ownServeGate.clear();
    _fastSyncUntil = null;
    _ownReach.clear();
    _reachSentAt = null;
    for (final timer in _historyTimers.values) {
      timer.cancel();
    }
    _historyTimers.clear();
    _historyQueue.clear();
    _historyAsked.clear();
    _historyAskedAt.clear();
    _historyPagesServed.clear();
    _historyTaken.clear();
    _parkedOwnSync.clear();
    _earlySyncStates.clear();
    _ownDeviceAdditions.clear();
    _ownListMerges.clear();
    _unconfirmedNoticed.clear();
    _seenTimer?.cancel();
    _seenTimer = null;
    _seenToTell.clear();
    _ownDeviceFiles.clear();
    for (final state in _ownServing.values) {
      unawaited(state.closeFile());
    }
    _ownServing.clear();
    _ownServingCheckedAt.clear();
    _digestCache = null;
  }

  // ---- For tests --------------------------------------------------------

  @visibleForTesting
  SyncPermission get ownDeviceFilePermissionForTesting =>
      _ownDeviceFilePermission;

  @visibleForTesting
  SyncPermission get ownDeviceLivePermissionForTesting =>
      ownDeviceSyncPolicy.permitFor(SyncTraffic.live, _syncConditions);

  @visibleForTesting
  Future<void> refreshEnergyForTesting() => _energyPolicy.refresh(force: true);

  @visibleForTesting
  DateTime? get coldRetryDueForTesting => _coldRetryDue();

  @visibleForTesting
  int get ownServeDeferralsForTesting => _ownServeDeferrals;

  @visibleForTesting
  int get historyRequestsAnsweredForTesting => _historyRequestsAnswered;

  @visibleForTesting
  int get ownServeTimerCountForTesting => _ownServeTimers.length;

  @visibleForTesting
  List<Timer> get ownServeTimersForTesting => _ownServeTimers.keys.toList();

  /// A block waiting to be served to [deviceId] for [wait], as a paced
  /// request leaves one.
  @visibleForTesting
  void deferOwnServeForTesting(String deviceId, Duration wait) {
    late final Timer timer;
    timer = Timer(wait, () => _ownServeTimers.remove(timer));
    _ownServeTimers[timer] = _DeferredOwnBlock(deviceId, 'test|$deviceId');
  }

  @visibleForTesting
  int get parkedOwnBlockCountForTesting => _parkedOwnBlocks.length;

  /// A request for a block, turned away by the policy and kept.
  @visibleForTesting
  void parkOwnBlockForTesting(String deviceId, Map<String, dynamic> payload) {
    final requester = _contactByDeviceId(deviceId);
    if (requester != null) _parkOwnDeviceBlock(requester, payload);
  }

  @visibleForTesting
  set steadySyncBytesPerSecondForTesting(int bytesPerSecond) =>
      _steadySyncBytesPerSecond = bytesPerSecond;

  @visibleForTesting
  set steadySyncPathsForTesting(int paths) => _steadySyncPaths = paths;

  @visibleForTesting
  Set<String> ownDeviceFileHoldersForTesting(String attachmentId) =>
      _ownDeviceFiles.devicesWith(attachmentId);

  /// How many things this device keeps for own device [deviceId].
  @visibleForTesting
  int ownDeviceSyncStateSizeForTesting(String deviceId) =>
      (_ownReach.containsKey(deviceId) ? 1 : 0) +
      (_historyQueue.containsKey(deviceId) ? 1 : 0) +
      (_historyAsked.containsKey(deviceId) ? 1 : 0) +
      (_historyAskedAt.containsKey(deviceId) ? 1 : 0) +
      (_historyTimers.containsKey(deviceId) ? 1 : 0) +
      (_historyPagesServed.containsKey(deviceId) ? 1 : 0) +
      (_parkedOwnSync.containsKey(deviceId) ? 1 : 0) +
      (_ownDeviceFiles.holds(deviceId) ? 1 : 0) +
      _ownServing.keys.where((key) => key.startsWith('$deviceId|')).length +
      _ownServeTimers.values.where((e) => e.deviceId == deviceId).length +
      _parkedOwnBlocks.where((p) => p.deviceId == deviceId).length +
      _snapshot.pendingAckDeliveries
          .where(
            (entry) =>
                entry.targetDeviceId == deviceId &&
                entry.kind == PendingAckKind.accountSync,
          )
          .length;
}

/// A block waiting for its turn to be served to an own device.
class _DeferredOwnBlock {
  const _DeferredOwnBlock(this.deviceId, this.key);
  final String deviceId;
  final String key;
}

/// A request for a block the policy turned away.
class _ParkedOwnBlock {
  const _ParkedOwnBlock(this.key, this.deviceId, this.payload, this.parkedAt);
  final String key;
  final String deviceId;
  final Map<String, dynamic> payload;
  final DateTime parkedAt;
}
