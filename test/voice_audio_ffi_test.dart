import 'dart:async';
import 'dart:io';

import 'package:conest/src/voice_audio_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final audio = NativeVoiceCallAudio.tryCreate();

  test(
    'native helper isolates never capture the frames listener graph',
    () async {
      // The app subscribes to call frames from MessengerController, whose
      // graph holds Futures. A closure that captures `this` would try to
      // copy that graph into the helper isolate and fail as unsendable.
      final unsendable = Completer<void>().future;
      final subscription = audio!.frames.listen((_) => unsendable);
      addTearDown(subscription.cancel);

      if (Platform.isLinux || Platform.isWindows) {
        await audio.availableOutputDevices();
      }
      final dir = await Directory.systemTemp.createTemp('conest-voice-ffi-');
      addTearDown(() => dir.delete(recursive: true));
      try {
        await audio.startVoiceMessageRecording('${dir.path}/probe.ogg');
        await audio.cancelVoiceMessageRecording();
      } on StateError {
        // No microphone on this runner; the isolate handoff still ran.
      }
      await audio.close();
    },
    skip: audio == null ? 'conest_native is not available' : false,
  );
}
