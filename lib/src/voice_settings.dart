/// When the microphone is sent in a call.
enum VoiceInputMode {
  /// Always (as before Settings → Voice existed).
  always,

  /// While you speak: above a sensitivity, set by hand or automatic.
  voiceActivity,

  /// While a key (desktop) or the call's button is held.
  pushToTalk,
}

/// Settings → Voice: devices, volumes, processing and how the microphone
/// is sent, for 1:1 and group calls alike. Kept on this device only.
class VoiceSettings {
  const VoiceSettings({
    this.inputDevice,
    this.outputDevice,
    this.inputVolume = 1,
    this.outputVolume = 1,
    this.echoCancellation = true,
    this.autoGain = false,
    this.inputMode = VoiceInputMode.always,
    this.automaticSensitivity = true,
    this.sensitivityDb = -50,
    this.pushToTalkKey,
    this.callSounds = true,
    this.participantVolumes = const {},
  });

  /// Device names as the sound system gives them; null: its default.
  final String? inputDevice;
  final String? outputDevice;

  /// Linear gains, 0 to 2 (1 = unchanged).
  final double inputVolume;
  final double outputVolume;
  final bool echoCancellation;
  final bool autoGain;
  final VoiceInputMode inputMode;
  final bool automaticSensitivity;

  /// Voice-activity threshold in dBFS (-90 to 0) when not automatic.
  final double sensitivityDb;

  /// The push-to-talk key (a Flutter logical key id); null: the button only.
  final int? pushToTalkKey;

  /// Ringing, joining and leaving sounds.
  final bool callSounds;

  /// Group-call members' volumes on this device (device id → 0 to 2).
  final Map<String, double> participantVolumes;

  static const maxParticipantVolumes = 64;

  /// The volume for [deviceId] (1 when unset).
  double volumeFor(String deviceId) => participantVolumes[deviceId] ?? 1;

  /// What the native audio engine takes (Settings → Voice, live).
  Map<String, Object?> toNative({bool loopback = false}) => {
    'inputGain': inputVolume,
    'outputGain': outputVolume,
    'echoCancellation': echoCancellation,
    'autoGain': autoGain,
    'gateMode': switch (inputMode) {
      VoiceInputMode.voiceActivity => automaticSensitivity ? 2 : 1,
      _ => 0,
    },
    'gateThresholdDb': sensitivityDb,
    'loopback': loopback,
  };

  VoiceSettings copyWith({
    String? inputDevice,
    bool clearInputDevice = false,
    String? outputDevice,
    bool clearOutputDevice = false,
    double? inputVolume,
    double? outputVolume,
    bool? echoCancellation,
    bool? autoGain,
    VoiceInputMode? inputMode,
    bool? automaticSensitivity,
    double? sensitivityDb,
    int? pushToTalkKey,
    bool clearPushToTalkKey = false,
    bool? callSounds,
    Map<String, double>? participantVolumes,
  }) => VoiceSettings(
    inputDevice: clearInputDevice ? null : inputDevice ?? this.inputDevice,
    outputDevice: clearOutputDevice ? null : outputDevice ?? this.outputDevice,
    inputVolume: _gain(inputVolume ?? this.inputVolume),
    outputVolume: _gain(outputVolume ?? this.outputVolume),
    echoCancellation: echoCancellation ?? this.echoCancellation,
    autoGain: autoGain ?? this.autoGain,
    inputMode: inputMode ?? this.inputMode,
    automaticSensitivity: automaticSensitivity ?? this.automaticSensitivity,
    sensitivityDb: _threshold(sensitivityDb ?? this.sensitivityDb),
    pushToTalkKey: clearPushToTalkKey
        ? null
        : pushToTalkKey ?? this.pushToTalkKey,
    callSounds: callSounds ?? this.callSounds,
    participantVolumes: _volumes(participantVolumes ?? this.participantVolumes),
  );

  /// [deviceId]'s volume set to [gain] (1 removes it).
  VoiceSettings withParticipantVolume(String deviceId, double gain) {
    final volumes = Map<String, double>.of(participantVolumes)
      ..remove(deviceId);
    if ((gain - 1).abs() > 0.001) {
      // The newest wins when the list is full.
      while (volumes.length >= maxParticipantVolumes) {
        volumes.remove(volumes.keys.first);
      }
      volumes[deviceId] = _gain(gain);
    }
    return copyWith(participantVolumes: volumes);
  }

  Map<String, Object?> toJson() => {
    if (inputDevice != null) 'inputDevice': inputDevice,
    if (outputDevice != null) 'outputDevice': outputDevice,
    'inputVolume': inputVolume,
    'outputVolume': outputVolume,
    'echoCancellation': echoCancellation,
    'autoGain': autoGain,
    'inputMode': inputMode.name,
    'automaticSensitivity': automaticSensitivity,
    'sensitivityDb': sensitivityDb,
    if (pushToTalkKey != null) 'pushToTalkKey': pushToTalkKey,
    'callSounds': callSounds,
    if (participantVolumes.isNotEmpty) 'participantVolumes': participantVolumes,
  };

  factory VoiceSettings.fromJson(Object? json) {
    if (json is! Map) return const VoiceSettings();
    String? name(Object? value) =>
        value is String && value.isNotEmpty && value.length <= 256
        ? value
        : null;
    double number(Object? value, double fallback) =>
        value is num && value.isFinite ? value.toDouble() : fallback;
    final volumes = json['participantVolumes'];
    final key = json['pushToTalkKey'];
    return VoiceSettings(
      inputDevice: name(json['inputDevice']),
      outputDevice: name(json['outputDevice']),
      inputVolume: _gain(number(json['inputVolume'], 1)),
      outputVolume: _gain(number(json['outputVolume'], 1)),
      echoCancellation: json['echoCancellation'] as bool? ?? true,
      autoGain: json['autoGain'] as bool? ?? false,
      inputMode:
          VoiceInputMode.values
              .where((mode) => mode.name == json['inputMode'])
              .firstOrNull ??
          VoiceInputMode.always,
      automaticSensitivity: json['automaticSensitivity'] as bool? ?? true,
      sensitivityDb: _threshold(number(json['sensitivityDb'], -50)),
      pushToTalkKey: key is int && key > 0 ? key : null,
      callSounds: json['callSounds'] as bool? ?? true,
      participantVolumes: _volumes({
        if (volumes is Map)
          for (final entry in volumes.entries)
            if (entry.key is String &&
                (entry.key as String).length <= 128 &&
                entry.value is num &&
                (entry.value as num).isFinite)
              entry.key as String: (entry.value as num).toDouble(),
      }),
    );
  }

  static double _gain(double value) => value.isFinite ? value.clamp(0, 2) : 1;
  static double _threshold(double value) =>
      value.isFinite ? value.clamp(-90, 0) : -50;
  static Map<String, double> _volumes(Map<String, double> volumes) => {
    for (final entry in volumes.entries.take(maxParticipantVolumes))
      entry.key: _gain(entry.value),
  };
}
