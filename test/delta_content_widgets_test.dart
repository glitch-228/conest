import 'package:conest/src/ui/delta_content_widgets.dart';
import 'package:conest/src/voice_message_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _PendingVoice extends VoiceMessageService {
  _PendingVoice(this.recordingState, this.destination);
  final VoiceRecordingState recordingState;
  final String destination;
  var interrupted = false;
  @override
  VoiceRecordingState get state => recordingState;
  @override
  String? get previewDestinationKey => destination;
  @override
  Future<void> stopForInterruption() async {
    interrupted = true;
  }
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
}
