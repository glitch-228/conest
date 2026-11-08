part of 'messenger_controller.dart';

/// What this device syncs with the account's other devices, and what they
/// said they want (M33 P1): the choice, the `prefs` event, and the check
/// every sync path makes against the smaller of the two. State lives in
/// the controller's fields; [_clearOwnDeviceSyncState] clears it.
extension OwnDevicePrefsController on MessengerController {
  /// Most devices whose prefs are kept (an account holds at most a few).
  static const int _maxKnownDevicePrefs = 16;

  /// What this device wants to sync.
  OwnDeviceSyncPrefs get ownDeviceSyncPrefs =>
      _snapshot.identity?.connectivity.ownDeviceSync ??
      OwnDeviceSyncPrefs.legacy;

  /// Whether [device] understands the P1 events (`prefs`, `mut`,
  /// `contact`, `verify`, `settings2`).
  bool _speaksSyncV2(ContactRecord device) => device.featureCapabilities
      .contains(ApplicationCapability.ownDeviceSyncV2);

  /// What this device and [device] may sync: the smaller of what each
  /// wants. A device that has not said (an older build, or not heard from
  /// yet) gets what the app did before.
  OwnDeviceScope _scopeFor(ContactRecord device) => OwnDeviceScope(
    mine: ownDeviceSyncPrefs,
    theirs: _ownDevicePrefs[device.deviceId],
  );

  /// Whether [event], on its way to [device], is in what the two may sync.
  /// Bookkeeping (no category) always is.
  bool _eventInScope(ContactRecord device, Map<String, Object?> event) {
    final category = categoryOfSyncEvent(
      event['type'] is String ? event['type']! as String : '',
      event['chat'],
    );
    return category == null || _scopeFor(device).allows(category);
  }

  /// Whether this device takes [event] from [sender]: what this device does
  /// not want to sync is dropped on arrival, whatever the sender thought.
  bool _acceptOwnDeviceEvent(ContactRecord sender, Map<String, dynamic> event) {
    final type = event['type'];
    if (type is! String) return false;
    final category = categoryOfSyncEvent(type, event['chat']);
    // Asking is the sender's wish; what is served is checked on serving.
    if (type == 'history_req') return true;
    return category == null || ownDeviceSyncPrefs.allows(category);
  }

  /// The prefs [sender] declared, when it is one of this account's devices
  /// (the caller has checked that), kept for the scope. It is told this
  /// device's prefs in return, once.
  void _takeOwnDevicePrefs(ContactRecord sender, Map<String, dynamic> event) {
    final prefs = OwnDeviceSyncPrefs.fromJson(event);
    if (prefs == null) return;
    if (!_ownDevicePrefs.containsKey(sender.deviceId) &&
        _ownDevicePrefs.length >= _maxKnownDevicePrefs) {
      return;
    }
    _ownDevicePrefs[sender.deviceId] = prefs;
    _announcePrefsOnce(sender);
  }

  /// Tells [device] what this device wants to sync, if it understands and
  /// has not been told since this device started.
  void _announcePrefsOnce(ContactRecord device) {
    if (!_speaksSyncV2(device) ||
        _prefsAnnounced.contains(device.deviceId) ||
        _prefsAnnounced.length >= _maxKnownDevicePrefs) {
      return;
    }
    _sendPrefsTo(device);
  }

  void _sendPrefsTo(ContactRecord device) {
    if (!_speaksSyncV2(device)) return;
    _prefsAnnounced.add(device.deviceId);
    _syncToOwnDevices({
      'type': 'prefs',
      ...ownDeviceSyncPrefs.toWire(),
    }, only: device.deviceId);
  }

  /// Chooses what this device syncs with the account's other devices, and
  /// tells them. What newly counts is asked for from them.
  Future<void> setOwnDeviceSyncPrefs(OwnDeviceSyncPrefs next) async {
    final me = _requireIdentity();
    final before = me.connectivity.ownDeviceSync;
    if (before == next) return;
    await updateGlobalConnectivity(
      me.connectivity.copyWith(ownDeviceSync: next),
    );
    final gained = [
      SyncCategory.messages,
      SyncCategory.saved,
    ].any((category) => !before.allows(category) && next.allows(category));
    for (final device in ownDevices) {
      _sendPrefsTo(device);
      if (gained) _requestHistoryFrom(device.deviceId);
    }
  }

  /// The chats this device wants history of, by its own prefs.
  List<String> get _wantedHistoryChats => [
    for (final chat in _historyChats)
      if (ownDeviceSyncPrefs.allows(
        chat == 'saved' ? SyncCategory.saved : SyncCategory.messages,
      ))
        chat,
  ];

  // ---- For tests --------------------------------------------------------

  @visibleForTesting
  set ownDeviceSyncV2ForTesting(bool on) {
    _advertiseOwnDeviceSyncV2 = on;
  }

  @visibleForTesting
  OwnDeviceSyncPrefs? ownDevicePrefsOfForTesting(String deviceId) =>
      _ownDevicePrefs[deviceId];

  @visibleForTesting
  bool prefsToldForTesting(String deviceId) =>
      _prefsAnnounced.contains(deviceId);

  /// What a `sent` event carries for a message with [body].
  @visibleForTesting
  String encodeSyncPayloadForTesting(String body) =>
      _crypto.encodeDirectMessagePayload(
        ChatMessage(
          id: 'payload',
          conversationId: 'c',
          senderDeviceId: _requireIdentity().deviceId,
          recipientDeviceId: 'r',
          body: body,
          outbound: true,
          state: DeliveryState.delivered,
          createdAt: _now().toUtc(),
        ),
      );
}
