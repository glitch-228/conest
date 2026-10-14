import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:conest/src/voice_call_service.dart';
import 'package:conest/src/feature_models.dart';
import 'support/fake_call_network.dart';

void main() {
  test(
    '1:1 close retains microphone ownership until teardown completes',
    () async {
      final hardware = _Hardware();
      final media = _VoiceMedia(hardware);
      final voice = VoiceCallService(
        localDeviceId: 'p0',
        transport: _Transport(),
        media: media,
      );
      final net = FakeCallNetwork();
      final group = await net.add(
        'p0',
        canOpenMedia: () => !voice.mediaBusy,
        mediaOverride: _GroupMedia(hardware),
      );
      await net.add('p1');
      addTearDown(net.dispose);
      addTearDown(voice.dispose);
      final call = await voice.startOutgoing('p1');
      await voice.onAccepted(callId: call.callId);
      media.closeGate = Completer<void>();
      final ending = voice.endRemote(reason: 'Peer left');
      expect(voice.active!.state, VoiceCallState.ended);
      expect(voice.mediaBusy, true);
      await expectLater(group.service.start('group'), throwsStateError);
      expect(hardware.owner, 'voice');
      media.closeGate!.complete();
      await ending;
      expect(voice.mediaBusy, false);
      await group.service.start('group');
      expect(hardware.owner, 'group');
      await Future<void>.delayed(Duration.zero);
      expect(hardware.owner, 'group');
    },
  );

  test(
    'late 1:1 setup and its cleanup finish before group capture can open',
    () async {
      final hardware = _Hardware();
      final media = _VoiceMedia(hardware)..prepareGate = Completer<void>();
      final voice = VoiceCallService(
        localDeviceId: 'p0',
        transport: _Transport(),
        media: media,
      );
      final net = FakeCallNetwork();
      final group = await net.add(
        'p0',
        canOpenMedia: () => !voice.mediaBusy,
        mediaOverride: _GroupMedia(hardware),
      );
      await net.add('p1');
      addTearDown(net.dispose);
      addTearDown(voice.dispose);
      var endedSetupRejected = false;
      final setup = voice
          .startOutgoing('p1')
          .then<void>(
            (_) {},
            onError: (Object _) {
              endedSetupRejected = true;
            },
          );
      await voice.endRemote(reason: 'Cancelled during permission');
      expect(voice.mediaBusy, true);
      await expectLater(group.service.start('group'), throwsStateError);
      media.closeGate = Completer<void>();
      media.prepareGate!.complete();
      await setup;
      expect(endedSetupRejected, true);
      expect(voice.mediaBusy, true);
      await expectLater(group.service.start('group'), throwsStateError);
      media.closeGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(voice.mediaBusy, false);
      await group.service.start('group');
      expect(hardware.owner, 'group');
      await Future<void>.delayed(Duration.zero);
      expect(hardware.owner, 'group');
    },
  );

  test('active group ownership refuses a new 1:1 microphone', () async {
    final hardware = _Hardware();
    final net = FakeCallNetwork();
    final group = await net.add('p0', mediaOverride: _GroupMedia(hardware));
    await net.add('p1');
    final voice = VoiceCallService(
      localDeviceId: 'p0',
      transport: _Transport(),
      media: _VoiceMedia(hardware),
      canOpenMedia: () => !group.service.mediaBusy,
    );
    addTearDown(net.dispose);
    addTearDown(voice.dispose);
    await group.service.start('group');
    await expectLater(voice.startOutgoing('p1'), throwsStateError);
    expect(hardware.owner, 'group');
  });
}

class _Hardware {
  String? owner;
}

class _Transport implements VoiceCallSignalTransport {
  @override
  Future<void> send(VoiceCallSignal signal) async {}
}

class _GroupMedia extends FakeCallMedia {
  _GroupMedia(this.hardware);
  final _Hardware hardware;
  @override
  Future<void> open(String groupId) async {
    hardware.owner = 'group';
    await super.open(groupId);
  }

  @override
  Future<void> close() async {
    hardware.owner = null;
    await super.close();
  }
}

class _VoiceMedia implements VoiceCallMediaEngine {
  _VoiceMedia(this.hardware);
  final _Hardware hardware;
  Completer<void>? prepareGate;
  Completer<void>? closeGate;
  @override
  bool get available => true;
  @override
  Future<void> prepare() async {
    await prepareGate?.future;
    hardware.owner = 'voice';
  }

  @override
  Future<void> open({
    required String peerDeviceId,
    required bool outgoing,
  }) async {
    hardware.owner = 'voice';
  }

  @override
  Future<void> close() async {
    await closeGate?.future;
    hardware.owner = null;
  }

  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setNoiseSuppression(bool enabled) async {}
  @override
  Future<bool> setSpeakerphoneEnabled(bool enabled) async => false;
  @override
  Future<List<String>> availableOutputDevices() async => [];
  @override
  Future<void> selectOutputDevice(String name) async {}
}
