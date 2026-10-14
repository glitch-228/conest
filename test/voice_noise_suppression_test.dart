import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/voice_call_service.dart';

void main() {
  test(
    'saved noise preference is applied on open and toggles immediately',
    () async {
      final media = _Media();
      final service = VoiceCallService(
        localDeviceId: 'alice',
        transport: _Transport(),
        media: media,
        noiseSuppressionEnabled: false,
      );
      final call = await service.startOutgoing('bob');
      await service.onAccepted(callId: call.callId);
      expect(media.noise, [false]);
      await service.setNoiseSuppression(true);
      expect(media.noise, [false, true]);
      await service.dispose();
    },
  );
}

class _Transport implements VoiceCallSignalTransport {
  @override
  Future<void> send(VoiceCallSignal signal) async {}
}

class _Media implements VoiceCallMediaEngine {
  final noise = <bool>[];
  @override
  bool get available => true;
  @override
  Future<void> prepare() async {}
  @override
  Future<void> open({
    required String peerDeviceId,
    required bool outgoing,
  }) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setNoiseSuppression(bool enabled) async {
    noise.add(enabled);
  }

  @override
  Future<bool> setSpeakerphoneEnabled(bool enabled) async => false;
  @override
  Future<List<String>> availableOutputDevices() async => [];
  @override
  Future<void> selectOutputDevice(String name) async {}
  @override
  Future<void> close() async {}
}
