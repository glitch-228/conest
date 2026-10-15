import 'package:conest/src/ui/delta_content_widgets.dart';
import 'package:conest/src/messenger_controller.dart';
import 'package:conest/src/voice_message_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PendingVoice extends VoiceMessageService {
  _PendingVoice(this.recordingState, this.destination);
  final VoiceRecordingState recordingState;
  final String destination;
  var interrupted = false;
  String? startedFor;
  @override
  VoiceRecordingState get state => recordingState;
  @override
  String? get previewDestinationKey => destination;
  @override
  VoiceRecordingSnapshot get recordingSnapshot => VoiceRecordingSnapshot(
    state: recordingState,
    destinationKey: destination,
    elapsed: Duration.zero,
    waveform: const [],
  );
  @override
  Future<void> start({required String destinationKey}) async {
    startedFor = destinationKey;
  }

  @override
  Future<void> stopForInterruption() async {
    interrupted = true;
  }
}

class _VoiceController implements MessengerController {
  _VoiceController(this.voiceMessageService);
  @override
  final VoiceMessageService voiceMessageService;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('closing a Delta chat interrupts pending microphone startup', () async {
    final service = _PendingVoice(VoiceRecordingState.starting, 'delta:chat');
    await interruptDeltaVoiceOnClose(service, 'chat');
    expect(service.interrupted, isTrue);
    final another = _PendingVoice(
      VoiceRecordingState.starting,
      'delta:another',
    );
    await interruptDeltaVoiceOnClose(another, 'chat');
    expect(another.interrupted, isFalse);
  });
  testWidgets(
    'microphone permission failure leaves the Delta composer retryable',
    (tester) async {
      final service = _PendingVoice(VoiceRecordingState.error, 'delta:chat');
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeltaVoiceComposer(
              controller: _VoiceController(service),
              chatKey: 'chat',
              enabled: true,
              act: (action) => action(),
            ),
          ),
        ),
      );
      final mic = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Record voice message',
      );
      expect(tester.widget<IconButton>(mic).onPressed, isNotNull);
      await tester.tap(mic);
      await tester.pump();
      expect(service.startedFor, 'delta:chat');
    },
  );
}
