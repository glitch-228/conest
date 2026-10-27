part of 'messenger_controller.dart';

/// Settings → Voice: saving it, using it in calls at once, push-to-talk
/// and the microphone test.
extension VoiceSettingsController on MessengerController {
  VoiceSettings get voiceSettings =>
      identity?.voiceSettings ?? const VoiceSettings();

  /// Saves [next] and applies it to any open call audio: volumes and
  /// processing at once, a changed microphone or output by switching to it.
  Future<void> updateVoiceSettings(VoiceSettings next) async {
    final me = identity;
    if (me == null) return;
    final previous = me.voiceSettings;
    _snapshot = _snapshot.copyWith(identity: me.copyWith(voiceSettings: next));
    _applyVoiceSettings(next);
    if (_callAudioOpen) {
      try {
        if (next.inputDevice != previous.inputDevice &&
            next.inputDevice != null) {
          await _platformBridge.selectVoiceCallInputDevice(next.inputDevice!);
        }
        if (next.outputDevice != previous.outputDevice &&
            next.outputDevice != null) {
          await _platformBridge.selectVoiceCallOutputDevice(next.outputDevice!);
        }
      } catch (error) {
        appendDebugLog('Voice device not switched: $error');
      }
    }
    if (next.inputMode != previous.inputMode) await _applyPushToTalk();
    await _saveSnapshotSilently(notify: true);
  }

  /// Sets one group-call member's volume on this device (0 to 2).
  Future<void> setCallParticipantVolume(String deviceId, double gain) =>
      updateVoiceSettings(voiceSettings.withParticipantVolume(deviceId, gain));

  bool get _callAudioOpen =>
      _microphoneTestOpen ||
      _groupCallService?.active?.joined == true ||
      _voiceCallService?.mediaBusy == true;

  void _applyVoiceSettings(VoiceSettings settings) {
    _platformBridge.applyVoiceSettings(settings);
    _voiceCallSoundCues
      ..enabled = settings.callSounds
      ..ringAllowed = () {
        final quiet = identity?.quietHours;
        return quiet == null ||
            quiet.callsRing ||
            !quiet.quietAt(_now().toLocal());
      };
    _appliedParticipantVolumes = '';
    _applyParticipantVolumes();
  }

  /// Group-call members' volumes, by their place in the native mixer;
  /// only when who sits where (or a volume) changed.
  void _applyParticipantVolumes() {
    final room = _groupCallService?.active;
    if (room == null || !room.joined) {
      _appliedParticipantVolumes = '';
      return;
    }
    final settings = voiceSettings;
    final me = identity?.deviceId;
    final volumes = [
      for (final peer in room.participants)
        if (peer.deviceId != me)
          (peer.index, settings.volumeFor(peer.deviceId)),
    ];
    final signature = volumes.map((v) => '${v.$1}:${v.$2}').join(',');
    if (signature == _appliedParticipantVolumes) return;
    _appliedParticipantVolumes = signature;
    for (final (index, gain) in volumes) {
      _platformBridge.setGroupCallParticipantVolume(index, gain);
    }
  }

  /// Push-to-talk: the microphone is on only while held (the key on
  /// desktop, or the call's button). 1:1 calls and group calls alike.
  Future<void> setPushToTalkHeld(bool held) async {
    if (_pushToTalkHeld == held) return;
    _pushToTalkHeld = held;
    await _applyPushToTalk();
    notifyListeners();
  }

  bool get pushToTalkHeld => _pushToTalkHeld;

  /// Lets go of push-to-talk (the key's release can be missed: the call
  /// ended, the window lost the focus).
  Future<void> releasePushToTalk() => setPushToTalkHeld(false);

  /// A different call (or none) has the microphone: a hold from before
  /// does not carry over, so the next call starts muted.
  void _syncPushToTalkSession() {
    // One key for both kinds of call: the joined group room, else the 1:1
    // call (a reconnecting one is the same call). Only its change resets.
    final room = _groupCallService?.active;
    final call = _voiceCallService?.active;
    final Object? session = room != null && room.joined
        ? room
        : call != null &&
              (call.state == VoiceCallState.connected ||
                  call.state == VoiceCallState.reconnecting)
        ? call.callId
        : null;
    if (_pushToTalkSession == session) return;
    _pushToTalkSession = session;
    _pushToTalkHeld = false;
  }

  /// Whether a call is sending this device's microphone (push-to-talk
  /// keys mean something only then).
  bool get callUsesMicrophone =>
      _groupCallService?.active?.joined == true ||
      _voiceCallService?.active?.state == VoiceCallState.connected;

  Future<void> _applyPushToTalk() async {
    final pushToTalk = voiceSettings.inputMode == VoiceInputMode.pushToTalk;
    final group = _groupCallService?.active;
    if (group != null && group.joined) {
      // Only a change: setting it notifies, and this runs on every change.
      if (group.pushToTalk != pushToTalk ||
          group.holdingToTalk != (pushToTalk && _pushToTalkHeld)) {
        await _groupCallService!.setPushToTalk(
          pushToTalk,
          held: _pushToTalkHeld,
        );
      }
      return;
    }
    final call = _voiceCallService?.active;
    if (call == null || call.state != VoiceCallState.connected) return;
    // The call's own mute (which the other side is told about) wins.
    try {
      await _voiceCallService!.media.setMuted(
        call.muted || (pushToTalk && !_pushToTalkHeld),
      );
    } catch (error) {
      appendDebugLog('Push-to-talk not applied: $error');
    }
  }

  Future<List<String>> voiceInputDevices() =>
      _platformBridge.voiceCallInputDevices();

  Future<List<String>> voiceOutputDevices() =>
      _platformBridge.voiceCallOutputDevices();

  bool get microphoneTestOpen => _microphoneTestOpen;

  bool get _microphoneTestOpen => _platformBridge.microphoneTestOpen;

  /// The microphone's level now (0 to 1), in a call or the test.
  double get microphoneLevel => _platformBridge.voiceCallInputLevel();

  /// Opens the microphone (and, with [loopback], plays it back) without a
  /// call. Refused while a call has the audio.
  Future<bool> startMicrophoneTest({bool loopback = false}) async {
    if (_groupCallService?.mediaBusy == true ||
        _voiceCallService?.mediaBusy == true ||
        !_platformBridge.supportsVoiceCallMedia) {
      return false;
    }
    try {
      return await _platformBridge.openMicrophoneTest(loopback: loopback);
    } catch (error) {
      appendDebugLog('Microphone test did not start: $error');
      return false;
    } finally {
      notifyListeners();
    }
  }

  void setMicrophoneTestLoopback(bool loopback) {
    if (_microphoneTestOpen) {
      _platformBridge.setMicrophoneTestLoopback(loopback);
    }
  }

  Future<void> stopMicrophoneTest() async {
    // Never a call's audio: leaving the page must not end a call's sound.
    if (!_microphoneTestOpen ||
        _groupCallService?.mediaBusy == true ||
        _voiceCallService?.mediaBusy == true) {
      return;
    }
    await _platformBridge.closeMicrophoneTest();
    notifyListeners();
  }
}
