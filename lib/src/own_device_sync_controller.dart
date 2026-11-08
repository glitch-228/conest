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
    if (until == null) return false;
    final now = _now();
    // Not past its end, and not further off than it was given (a clock that
    // was set back must not stretch it).
    return now.isBefore(until) &&
        until.difference(now) <= OwnDeviceSyncPolicy.fastConfirmationLasts;
  }

  /// What is not kept while sync is paused: pages and answers that are
  /// pointless later (the digests after resuming ask again for what matters).
  static const Set<String> _droppedWhilePaused = {
    'history_page',
    'have',
    'have_q',
  };

  /// What serving or fetching file bytes with another own device may use.
  SyncPermission get _ownDeviceFilePermission =>
      ownDeviceSyncPolicy.permitFor(SyncTraffic.files, _syncConditions);

  /// For a block of [bytes] about to be served to own device [requester]:
  /// null to serve nothing now (the policy says no, or it would wait too
  /// long: the device asks again), otherwise how long to wait first.
  Duration? _admitOwnDeviceBlock(ContactRecord requester, int bytes) =>
      _ownServeGate.admit(requester.deviceId, bytes, _ownDeviceFilePermission);

  /// A block admitted but not served after all gives its pace back.
  void _refundOwnDeviceBlock(ContactRecord requester, int bytes) =>
      _ownServeGate.refund(requester.deviceId, bytes, _ownDeviceFilePermission);

  /// Whether the block asked for in [payload] already waits for its turn.
  bool _ownBlockWaiting(ContactRecord requester, Map<String, dynamic> payload) {
    final key = _ownBlockKey(requester.deviceId, payload);
    return _ownServeTimers.values.any((entry) => entry.key == key);
  }

  static String _ownBlockKey(String deviceId, Map<String, dynamic> payload) =>
      '$deviceId|${payload['attachmentId']}|${payload['index']}';

  /// Serves the block asked for in [payload] after [wait], unless the
  /// device was forgotten or this controller disposed meanwhile. Never
  /// holds the inbound path: the request is let go at once. A request for
  /// a block already waiting, or more than a device or this one may keep
  /// waiting, is let go (the other device asks again).
  bool _deferOwnDeviceBlock(
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
      return false;
    }
    _ownServeDeferrals++;
    late final Timer timer;
    timer = Timer(wait, () {
      _ownServeTimers.remove(timer);
      if (_disposed) return;
      // Through the same guard as any request, so it is not sent twice.
      unawaited(
        _handleAttachmentChunkRequest(
          requester,
          payload,
          paced: true,
        ).catchError((Object error) {
          appendDebugLog('A deferred block was not served: $error');
        }),
      );
    });
    _ownServeTimers[timer] = _DeferredOwnBlock(requester.deviceId, key);
    return true;
  }

  /// Sends a history page after [wait] (at the pace the speed allows),
  /// unless the device is forgotten or this controller disposed meanwhile;
  /// by then it must still be allowed, or the other device is told to ask
  /// again later.
  void _sendHistoryPageLater(
    String deviceId,
    String chat,
    Map<String, Object?> pageEvent,
    Duration wait,
  ) {
    late final Timer timer;
    timer = Timer(wait, () {
      _historyPageTimers.remove(timer);
      if (_disposed) return;
      if (ownDeviceSyncPermission.allowed) {
        _syncToOwnDevices(pageEvent, only: deviceId);
      } else {
        _syncToOwnDevices({
          'type': 'history_wait',
          'chats': [
            {'chat': chat},
          ],
          'seconds': 300,
        }, only: deviceId);
      }
    });
    _historyPageTimers[timer] = deviceId;
  }

  /// What was held while paused goes now: its lifetime counts from here (it
  /// would otherwise run out in the first pass after a long pause), and
  /// each other device is told what this one holds, so what a full queue
  /// dropped is asked for again.
  void _resumeOwnDeviceSync() {
    final now = _now().toUtc();
    final refreshed = <PendingAckDelivery>[];
    var changed = false;
    for (final entry in _snapshot.pendingAckDeliveries) {
      final payload = entry.payload;
      if (entry.kind == PendingAckKind.accountSync &&
          payload != null &&
          payload.createdAt.isBefore(now.subtract(const Duration(hours: 1)))) {
        refreshed.add(
          entry.copyWith(
            payload: QueuedEnvelopePayload(
              kind: payload.kind,
              messageId: payload.messageId,
              conversationId: payload.conversationId,
              plaintext: payload.plaintext,
              createdAt: now,
              acknowledgedMessageId: payload.acknowledgedMessageId,
            ),
          ),
        );
        changed = true;
      } else {
        refreshed.add(entry);
      }
    }
    if (changed) {
      _snapshot = _snapshot.copyWith(pendingAckDeliveries: refreshed);
    }
    unawaited(_retryPendingAckDeliveries().catchError((Object _) {}));
    for (final device in ownDevices) {
      _sendSyncStatusTo(device.deviceId);
    }
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
    final now = _now();
    final due = [
      for (final parked in _parkedOwnBlocks)
        if (isFresh(parked.parkedAt, now, _parkedOwnBlockLifetime)) parked,
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
      for (final timer in [
        for (final entry in _historyPageTimers.entries)
          if (entry.value == id) entry.key,
      ]) {
        timer.cancel();
        _historyPageTimers.remove(timer);
      }
      for (final state in _inboundAttachments.values) {
        state.requestedInFlight.removeAll(
          state.sources.remove(BlockSource.peer(id)),
        );
        // A file that came from the removed device itself cannot go on: it
        // is shown as failed, not left to wait for a device that is gone.
        if (state.peerDeviceId == id) {
          state.retryTimer?.cancel();
          _setTransferSessionState(
            state.descriptor.id,
            TransferState.failed,
            error:
                'The device this file came from was removed from your '
                'account.',
          );
        }
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
    for (final timer in _historyPageTimers.keys) {
      timer.cancel();
    }
    _historyPageTimers.clear();
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

  @visibleForTesting
  int get historyPageTimerCountForTesting => _historyPageTimers.length;

  /// As if [requesterDeviceId] had asked for the block in [payload].
  @visibleForTesting
  Future<void> serveOwnBlockForTesting(
    String requesterDeviceId,
    Map<String, dynamic> payload,
  ) async {
    final requester = _contactByDeviceId(requesterDeviceId);
    if (requester != null) {
      await _handleAttachmentChunkRequest(requester, payload);
    }
  }

  @visibleForTesting
  DateTime? ownServeBusyUntilForTesting(String deviceId) =>
      _ownServeGate.busyUntil(deviceId);

  /// Sync events as [_syncToOwnDevices] takes them.
  @visibleForTesting
  void syncToOwnDevicesForTesting(Map<String, Object?> event, {String? only}) =>
      _syncToOwnDevices(event, only: only);

  /// Forgets what is queued for [deviceId], as a full queue does.
  @visibleForTesting
  void dropQueuedSyncForTesting(String deviceId) {
    _snapshot = _snapshot.copyWith(
      pendingAckDeliveries: [
        for (final entry in _snapshot.pendingAckDeliveries)
          if (!(entry.targetDeviceId == deviceId &&
              entry.kind == PendingAckKind.accountSync))
            entry,
      ],
    );
  }

  @visibleForTesting
  ({TransferState state, String? error})? transferStateForTesting(
    String attachmentId,
  ) {
    final session = _transferSessionById(attachmentId);
    return session == null
        ? null
        : (state: session.state, error: session.lastError);
  }

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
      _historyPageTimers.values.where((id) => id == deviceId).length +
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
