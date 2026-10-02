import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/feature_models.dart';
import 'package:conest/src/voice_call_service.dart';
import 'package:conest/src/voice_call_sound_cues.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('call sound cues follow the call state machine', () {
    late List<String> played;
    late VoiceCallSoundCues cues;
    late VoiceCallService service;
    late StreamSubscription<VoiceCallSession?> subscription;

    setUp(() {
      played = [];
      cues = VoiceCallSoundCues(_RecordingCuePlayer(played));
      service = VoiceCallService(
        localDeviceId: 'me',
        transport: _NullTransport(),
        media: const _WorkingMedia(),
      );
      subscription = service.changes.listen(cues.handle);
    });

    tearDown(() async {
      await subscription.cancel();
      await cues.dispose();
    });

    Future<void> settle() => cues.dispose();

    test('an answered outgoing call rings, connects, and hangs up', () async {
      final session = await service.startOutgoing('peer');
      await service.onAccepted(callId: session.callId);
      await service.toggleMute();
      await service.toggleMute();
      await service.end();
      await settle();

      expect(played, [
        'play outgoingRing',
        'stop',
        'play connected',
        'play muted',
        'play unmuted',
        'play ended',
        'dispose',
      ]);
    });

    test('an accepted incoming call stops ringing before connecting', () async {
      await service.receiveInvite(_invite('call-1'));
      await service.accept();
      await service.endRemote(reason: 'Remote hang-up');
      await settle();

      expect(played, [
        'play incomingRing',
        'stop',
        'play connected',
        'play ended',
        'dispose',
      ]);
    });

    test('a rejected outgoing call plays the busy tone', () async {
      await service.startOutgoing('peer');
      await service.endRemote(reason: 'Call rejected.');
      await settle();

      expect(played, ['play outgoingRing', 'play busy', 'dispose']);
    });

    test('canceling an outgoing call plays the hang-up cue', () async {
      await service.startOutgoing('peer');
      await service.end();
      await settle();

      expect(played, ['play outgoingRing', 'play ended', 'dispose']);
    });

    test('declining an incoming call plays the hang-up cue', () async {
      await service.receiveInvite(_invite('call-2'));
      await service.end(reason: 'Call rejected.');
      await settle();

      expect(played, ['play incomingRing', 'play ended', 'dispose']);
    });

    test('a dropped connection warns once and chimes on recovery', () async {
      final session = await service.startOutgoing('peer');
      await service.onAccepted(callId: session.callId);
      await service.reconnecting(callId: session.callId);
      await service.reconnecting(callId: session.callId);
      service.noteMediaReceived(session.callId);
      await service.end();
      await settle();

      expect(played, [
        'play outgoingRing',
        'stop',
        'play connected',
        'play reconnecting',
        'play connected',
        'play ended',
        'dispose',
      ]);
    });
  });

  test('reset silences a ring and forgets the call', () async {
    final played = <String>[];
    final cues = VoiceCallSoundCues(_RecordingCuePlayer(played));
    final ringing = VoiceCallSession(
      callId: 'call-3',
      peerDeviceId: 'peer',
      outgoing: false,
      startedAt: DateTime.utc(2026),
    );
    cues.handle(ringing);
    cues.reset();
    // The same session arriving from a new service rings again.
    cues.handle(ringing);
    await cues.dispose();

    expect(played, [
      'play incomingRing',
      'stop',
      'play incomingRing',
      'dispose',
    ]);
  });

  test('a failing player is reported without blocking later cues', () async {
    final errors = <Object>[];
    final played = <String>[];
    final cues = VoiceCallSoundCues(
      _RecordingCuePlayer(played, failOn: VoiceCallCue.outgoingRing),
      onError: errors.add,
    );
    final ringing = VoiceCallSession(
      callId: 'call-4',
      peerDeviceId: 'peer',
      outgoing: true,
      startedAt: DateTime.utc(2026),
    );
    cues.handle(ringing);
    cues.handle(ringing.copyWith(state: VoiceCallState.ended));
    await cues.dispose();

    expect(errors, hasLength(1));
    expect(played, ['play busy', 'dispose']);
  });

  test('every cue renders as valid, audible, unclipped 16-bit WAV', () {
    for (final cue in VoiceCallCue.values) {
      final wav = synthesizeVoiceCallCue(cue);
      final header = ByteData.sublistView(wav, 0, 44);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF', reason: cue.name);
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint32(24, Endian.little), voiceCallCueSampleRate);
      expect(header.getUint32(40, Endian.little), wav.length - 44);

      final samples = ByteData.sublistView(wav, 44);
      var peak = 0;
      for (var i = 0; i < samples.lengthInBytes; i += 2) {
        final value = samples.getInt16(i, Endian.little).abs();
        if (value > peak) peak = value;
      }
      expect(peak, greaterThan(3000), reason: '${cue.name} is audible');
      expect(peak, lessThan(32000), reason: '${cue.name} does not clip');

      // Looping cues must start and end near silence to loop without a click.
      if (cue.loops) {
        expect(samples.getInt16(0, Endian.little).abs(), lessThan(200));
        expect(
          samples.getInt16(samples.lengthInBytes - 2, Endian.little).abs(),
          lessThan(200),
        );
      }
    }
  });
}

VoiceCallSignal _invite(String callId) => VoiceCallSignal(
  callId: callId,
  action: 'invite',
  senderDeviceId: 'peer',
  recipientDeviceId: 'me',
  issuedAt: DateTime.now().toUtc(),
);

class _RecordingCuePlayer implements VoiceCallCuePlayer {
  _RecordingCuePlayer(this.log, {this.failOn});

  final List<String> log;
  final VoiceCallCue? failOn;

  @override
  Future<void> play(VoiceCallCue cue) async {
    if (cue == failOn) throw StateError('no audio device');
    log.add('play ${cue.name}');
  }

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => log.add('dispose');
}

class _NullTransport implements VoiceCallSignalTransport {
  @override
  Future<void> send(VoiceCallSignal signal) async {}
}

class _WorkingMedia implements VoiceCallMediaEngine {
  const _WorkingMedia();

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
  Future<bool> setSpeakerphoneEnabled(bool enabled) async => true;

  @override
  Future<List<String>> availableOutputDevices() async => const [];

  @override
  Future<void> selectOutputDevice(String name) async {}

  @override
  Future<void> close() async {}
}
