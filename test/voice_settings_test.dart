import 'package:conest/src/voice_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('voice settings round-trip and stay in bounds', () {
    final settings = const VoiceSettings()
        .copyWith(
          inputDevice: 'USB mic',
          outputVolume: 1.5,
          inputMode: VoiceInputMode.voiceActivity,
          automaticSensitivity: false,
          sensitivityDb: -40,
          pushToTalkKey: 0x00100000061,
          callSounds: false,
        )
        .withParticipantVolume('peer', 0.5);
    final again = VoiceSettings.fromJson(settings.toJson());
    expect(again.inputDevice, 'USB mic');
    expect(again.outputDevice, isNull);
    expect(again.outputVolume, 1.5);
    expect(again.inputMode, VoiceInputMode.voiceActivity);
    expect(again.automaticSensitivity, isFalse);
    expect(again.sensitivityDb, -40);
    expect(again.pushToTalkKey, 0x00100000061);
    expect(again.callSounds, isFalse);
    expect(again.volumeFor('peer'), 0.5);
    expect(again.volumeFor('other'), 1);

    final wild = VoiceSettings.fromJson({
      'inputVolume': 9,
      'outputVolume': double.nan,
      'sensitivityDb': -500,
      'inputMode': 'shout',
      'participantVolumes': {'a': 7, 'b': 'x'},
    });
    expect(wild.inputVolume, 2);
    expect(wild.outputVolume, 1);
    expect(wild.sensitivityDb, -90);
    expect(wild.inputMode, VoiceInputMode.always);
    expect(wild.participantVolumes, {'a': 2.0});
    // Older saves have none: today's behaviour.
    expect(VoiceSettings.fromJson(null).inputMode, VoiceInputMode.always);
  });

  test('the native engine gets the gate the input mode means', () {
    const always = VoiceSettings();
    expect(always.toNative()['gateMode'], 0);
    final automatic = always.copyWith(inputMode: VoiceInputMode.voiceActivity);
    expect(automatic.toNative()['gateMode'], 2);
    final manual = automatic.copyWith(
      automaticSensitivity: false,
      sensitivityDb: -35,
    );
    expect(manual.toNative()['gateMode'], 1);
    expect(manual.toNative()['gateThresholdDb'], -35);
    // Push-to-talk mutes instead of gating.
    expect(
      always
          .copyWith(inputMode: VoiceInputMode.pushToTalk)
          .toNative()['gateMode'],
      0,
    );
    expect(always.toNative(loopback: true)['loopback'], isTrue);
  });

  test('participant volumes keep the newest when full', () {
    var settings = const VoiceSettings();
    for (var i = 0; i < VoiceSettings.maxParticipantVolumes + 5; i++) {
      settings = settings.withParticipantVolume('p$i', 0.5);
    }
    expect(
      settings.participantVolumes,
      hasLength(VoiceSettings.maxParticipantVolumes),
    );
    expect(settings.volumeFor('p0'), 1);
    expect(
      settings.volumeFor('p${VoiceSettings.maxParticipantVolumes + 4}'),
      0.5,
    );
    expect(
      settings.withParticipantVolume('p10', 1).participantVolumes,
      isNot(contains('p10')),
    );
  });
}
