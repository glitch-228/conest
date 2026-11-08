part of 'messenger_controller.dart';

/// Settings shared key by key between the account's devices (M33 P1), with
/// a clock per key; and the digest `dgs` that carries what is held and a
/// hash of those clocks, sent with the events when it has been long. State
/// lives in the controller's fields; [_clearOwnDeviceSyncState] clears it.
extension OwnDeviceSettingsController on MessengerController {
  /// A setting that lowers protection (a privacy switch turned off) from
  /// another device waits for this device's user: it is applied only after
  /// they say yes.
  static bool _weakens(String key, Object old, Object next) =>
      key == 'suppressReadReceipts' && old == true && next == false;

  /// The settings shared, by key: how to read what a device sends and the
  /// value this device holds.
  static const List<String> _sharedKeys = [
    'autoDownloadPreset',
    'storageReserveEnabled',
    'irohTransferLimitEnabled',
    'suppressReadReceipts',
  ];

  static const int _maxSettingsPerEvent = 16;

  /// A status (`dgs`) goes with the events after this many to one device,
  /// or this long since the last, whichever comes first.
  static const int _statusEveryEvents = 50;
  static const Duration _statusEvery = Duration(minutes: 30);

  /// A device is sent all shared settings, because their clocks differ,
  /// at most this often.
  static const Duration _settingsRepairEvery = Duration(minutes: 5);

  Object? _sharedValueOf(String key) {
    final me = _snapshot.identity;
    if (me == null) return null;
    return switch (key) {
      'autoDownloadPreset' => me.connectivity.autoDownloadPreset.name,
      'storageReserveEnabled' => me.connectivity.storageReserveEnabled,
      'irohTransferLimitEnabled' => me.connectivity.irohTransferLimitEnabled,
      'suppressReadReceipts' => me.suppressReadReceipts,
      _ => null,
    };
  }

  /// [raw], from another device, as a value [key] can have; null if not.
  static Object? _parseSharedValue(String key, Object? raw) => switch (key) {
    'autoDownloadPreset' =>
      raw is String
          ? AutoDownloadPreset.values
                .where((value) => value.name == raw)
                .firstOrNull
                ?.name
          : null,
    'storageReserveEnabled' ||
    'irohTransferLimitEnabled' ||
    'suppressReadReceipts' => raw is bool ? raw : null,
    _ => null,
  };

  /// Settings that changed between [before] and [after] get this device's
  /// clock (for the event [_tellSharedSettings] sends next).
  GlobalConnectivityPreferences _stampSharedSettings(
    GlobalConnectivityPreferences before,
    GlobalConnectivityPreferences after,
  ) {
    final me = _requireIdentity();
    final clocks = {...after.settingsClocks};
    final nowMs = _now().millisecondsSinceEpoch;
    final stamped = <String>{};
    for (final key in _sharedKeys) {
      if (key == 'suppressReadReceipts') continue;
      final changed =
          !before.shareSettings ||
          _connectivityValue(before, key) != _connectivityValue(after, key);
      if (!changed) continue;
      clocks[key] = HybridClock.next(
        nowMilliseconds: nowMs,
        deviceId: me.deviceId,
        lastSeen: HybridClock.parse(clocks[key]),
      ).encode();
      stamped.add(key);
    }
    _stampedSettingKeys = stamped;
    return after.copyWith(settingsClocks: clocks);
  }

  static Object? _connectivityValue(
    GlobalConnectivityPreferences prefs,
    String key,
  ) => switch (key) {
    'autoDownloadPreset' => prefs.autoDownloadPreset.name,
    'storageReserveEnabled' => prefs.storageReserveEnabled,
    'irohTransferLimitEnabled' => prefs.irohTransferLimitEnabled,
    _ => null,
  };

  /// Tells the devices that understand it the settings just stamped, key by
  /// key (the others get the old whole-bundle event, sent separately).
  void _tellSharedSettingsV2(GlobalConnectivityPreferences prefs) {
    final keys = _stampedSettingKeys;
    _stampedSettingKeys = const {};
    _sendSettings2(keys, prefs.settingsClocks);
  }

  void _sendSettings2(
    Iterable<String> keys,
    Map<String, String> clocks, {
    String? only,
  }) {
    final k = <String, Object?>{};
    for (final key in keys) {
      final clock = HybridClock.parse(clocks[key]);
      final value = _sharedValueOf(key);
      if (clock == null || value == null) continue;
      k[key] = [value, clock.milliseconds, clock.deviceId];
      if (k.length >= _maxSettingsPerEvent) break;
    }
    if (k.isEmpty) return;
    _syncToOwnDevices(
      {'type': 'settings2', 'k': k},
      only: only,
      to: _speaksSyncV2,
    );
  }

  /// A shared setting that lives outside the connectivity preferences
  /// (the read-receipts switch) was changed here: it is stamped and told.
  Future<void> _sharedIdentitySettingChanged(String key) async {
    final me = _snapshot.identity;
    if (me == null ||
        !me.connectivity.shareSettings ||
        _applyingSharedSettings) {
      return;
    }
    final clocks = {...me.connectivity.settingsClocks};
    clocks[key] = HybridClock.next(
      nowMilliseconds: _now().millisecondsSinceEpoch,
      deviceId: me.deviceId,
      lastSeen: HybridClock.parse(clocks[key]),
    ).encode();
    _applyingSharedSettings = true;
    try {
      await updateGlobalConnectivity(
        me.connectivity.copyWith(settingsClocks: clocks),
      );
    } finally {
      _applyingSharedSettings = false;
    }
    _sendSettings2([key], clocks);
  }

  /// Settings another own device shared, key by key: taken when this device
  /// shares too, for each key whose clock is newer than the one here, whose
  /// clock is not far ahead of this device's own time, and whose value is
  /// one the key can have. One that lowers protection waits for the user.
  Future<void> _takeSharedSettingsV2(
    ContactRecord sender,
    Map<String, dynamic> event,
  ) async {
    final me = identity;
    final k = event['k'];
    if (me == null ||
        !me.connectivity.shareSettings ||
        k is! Map ||
        k.length > _maxSettingsPerEvent) {
      return;
    }
    final nowMs = _now().millisecondsSinceEpoch;
    final clocks = {...me.connectivity.settingsClocks};
    var next = me.connectivity;
    var identityRead = me.suppressReadReceipts;
    final changed = <String>[];
    var clocksChanged = false;
    for (final entry in k.entries) {
      final key = entry.key;
      final item = entry.value;
      if (key is! String ||
          !_sharedKeys.contains(key) ||
          item is! List ||
          item.length != 3) {
        continue;
      }
      final value = _parseSharedValue(key, item[0]);
      final remote = HybridClock.fromPeer(
        milliseconds: item[1],
        deviceId: item[2],
        nowMilliseconds: nowMs,
      );
      if (value == null || remote == null) continue;
      final local = HybridClock.parse(clocks[key]);
      if (local != null && !remote.isAfter(local)) continue;
      clocks[key] = remote.encode();
      clocksChanged = true;
      final old = _sharedValueOf(key);
      if (old == value) continue;
      if (_weakens(key, old!, value)) {
        if (_pendingSharedSettings.containsKey(key) ||
            _pendingSharedSettings.length < _maxSettingsPerEvent) {
          _pendingSharedSettings[key] = (
            value: value,
            clock: remote,
            deviceId: sender.deviceId,
          );
        }
        continue;
      }
      switch (key) {
        case 'autoDownloadPreset':
          next = next.copyWith(
            autoDownloadPreset: AutoDownloadPreset.values.firstWhere(
              (preset) => preset.name == value,
            ),
          );
        case 'storageReserveEnabled':
          next = next.copyWith(storageReserveEnabled: value as bool);
        case 'irohTransferLimitEnabled':
          next = next.copyWith(irohTransferLimitEnabled: value as bool);
        case 'suppressReadReceipts':
          identityRead = value as bool;
      }
      changed.add(key);
    }
    if (!clocksChanged) return;
    final limitLifted =
        me.connectivity.irohTransferLimitEnabled &&
        !next.irohTransferLimitEnabled;
    _applyingSharedSettings = true;
    try {
      await updateGlobalConnectivity(next.copyWith(settingsClocks: clocks));
      if (identityRead != me.suppressReadReceipts) {
        await updateSuppressReadReceipts(identityRead);
      }
    } finally {
      _applyingSharedSettings = false;
    }
    if (limitLifted) _resumeTransfersAfterIrohLimitLifted();
    if (changed.isNotEmpty || _pendingSharedSettings.isNotEmpty) {
      _lastSharedSettingsNotice = changed.isEmpty
          ? 'Your other device ${sender.deviceName ?? sender.alias} asks to '
                'change a privacy setting here.'
          : 'Settings were changed from your other device '
                '${sender.deviceName ?? sender.alias}.';
      _setTransientStatus(_lastSharedSettingsNotice!);
    }
  }

  /// Shared settings from another device that wait for this device's user
  /// (they lower protection): key, and the value it asks for.
  Map<String, Object> get pendingSharedSettings => {
    for (final entry in _pendingSharedSettings.entries)
      entry.key: entry.value.value,
  };

  /// The user says yes to a pending setting: it is applied (and not told
  /// on: the other devices have it).
  Future<void> confirmSharedSetting(String key) async {
    final pending = _pendingSharedSettings.remove(key);
    if (pending == null) return;
    _applyingSharedSettings = true;
    try {
      switch (key) {
        case 'suppressReadReceipts':
          await updateSuppressReadReceipts(pending.value as bool);
      }
    } finally {
      _applyingSharedSettings = false;
    }
    notifyListeners();
  }

  /// The user says no: the setting stays as it is here.
  void dismissSharedSetting(String key) {
    if (_pendingSharedSettings.remove(key) != null) notifyListeners();
  }

  /// A short hash of the clocks of the shared settings, for devices to tell
  /// whether they agree without sending the settings.
  String _settingsClockHash() {
    final clocks = _snapshot.identity?.connectivity.settingsClocks ?? const {};
    final lines = [
      for (final key in clocks.keys.toList()..sort()) '$key=${clocks[key]}',
    ];
    return dart_crypto.sha256
        .convert(utf8.encode(lines.join('\n')))
        .toString()
        .substring(0, 16);
  }

  /// [sender] says what it holds (chats, and a hash of its settings'
  /// clocks): what differs in chats is asked for, and when the clocks
  /// differ it is sent this device's settings (it takes those newer than
  /// its own).
  void _takeStatus(ContactRecord sender, Map<String, dynamic> event) {
    _takeDigests(sender, event['chats']);
    final theirs = event['settings'];
    final me = _snapshot.identity;
    if (theirs is! String ||
        me == null ||
        !me.connectivity.shareSettings ||
        theirs == _settingsClockHash() ||
        me.connectivity.settingsClocks.isEmpty) {
      return;
    }
    final now = _now();
    final last = _settingsRepairAt[sender.deviceId];
    if (last != null && isFresh(last, now, _settingsRepairEvery)) return;
    if (_settingsRepairAt.length >= _maxStatusTracked &&
        !_settingsRepairAt.containsKey(sender.deviceId)) {
      return;
    }
    _settingsRepairAt[sender.deviceId] = now;
    _sendSettings2(
      me.connectivity.settingsClocks.keys,
      me.connectivity.settingsClocks,
      only: sender.deviceId,
    );
  }

  static const int _maxStatusTracked = 16;

  /// An event went to [device]: after enough of them, or enough time, it is
  /// told what this device holds too (no timer: this runs with the events).
  void _noteSyncEventSent(ContactRecord device, Map<String, Object?> event) {
    final type = event['type'];
    if (type == 'dgs' ||
        type == 'digest' ||
        type == 'prefs' ||
        type == 'reach') {
      return;
    }
    final id = device.deviceId;
    final now = _now();
    if (!_eventsSinceStatus.containsKey(id) &&
        _eventsSinceStatus.length >= _maxStatusTracked) {
      return;
    }
    final count = (_eventsSinceStatus[id] ?? 0) + 1;
    final since = _statusSentAt.putIfAbsent(id, () => now);
    _eventsSinceStatus[id] = count;
    if (count >= _statusEveryEvents || !isFresh(since, now, _statusEvery)) {
      _sendSyncStatusTo(id);
    }
  }

  // ---- For tests --------------------------------------------------------

  @visibleForTesting
  int get statusSentCountForTesting => _statusSentCount;

  @visibleForTesting
  String settingsClockHashForTesting() => _settingsClockHash();

  /// Turns the storage reserve off here with a new clock and tells nobody:
  /// the state of a device whose event for it was lost on the way.
  @visibleForTesting
  Future<void> changeStorageReserveWithoutTellingForTesting(bool on) async {
    final me = _requireIdentity();
    final clocks = {...me.connectivity.settingsClocks};
    clocks['storageReserveEnabled'] = HybridClock.next(
      nowMilliseconds: _now().millisecondsSinceEpoch,
      deviceId: me.deviceId,
      lastSeen: HybridClock.parse(clocks['storageReserveEnabled']),
    ).encode();
    _applyingSharedSettings = true;
    try {
      await updateGlobalConnectivity(
        me.connectivity.copyWith(
          storageReserveEnabled: on,
          settingsClocks: clocks,
        ),
      );
    } finally {
      _applyingSharedSettings = false;
    }
  }
}
