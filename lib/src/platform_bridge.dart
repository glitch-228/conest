import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_audio_ffi.dart';

class PlatformBridge {
  PlatformBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.conest.conest/system') {
    // Some pure-Dart unit tests construct PlatformBridge without a Flutter
    // binding. Production bootstrap initializes the binding first; in a
    // binding-less process there cannot be native callbacks, so skipping the
    // handler is both safe and avoids MethodChannel's messenger assertion.
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'transferControl') {
          final action = call.arguments is Map
              ? (call.arguments as Map)['action'] as String?
              : null;
          if (action != null) _transferControls.add(action);
        } else if (call.method == 'voiceCallAudioFailure') {
          final reason = call.arguments is Map
              ? (call.arguments as Map)['reason']?.toString()
              : null;
          _voiceAudio?.reportPlatformFailure(
            reason ?? 'Android voice audio stopped.',
          );
        } else if (call.method == 'scheduledMessageDue') {
          _scheduledMessageWakeups.add(1);
        }
      });
    } on AssertionError {
      // No BinaryMessenger is active.
    }
  }

  final MethodChannel _channel;
  final StreamController<String> _transferControls =
      StreamController<String>.broadcast();
  final StreamController<int> _scheduledMessageWakeups =
      StreamController<int>.broadcast();
  final NativeVoiceCallAudio? _voiceAudio = NativeVoiceCallAudio.tryCreate();

  Stream<String> get transferControlEvents => _transferControls.stream;
  Stream<int> get scheduledMessageWakeupEvents =>
      _scheduledMessageWakeups.stream;
  Stream<Uint8List> get voiceCallAudioFrames =>
      _voiceAudio?.frames ?? const Stream<Uint8List>.empty();

  /// True only when a platform plugin implements a complete foreground audio
  /// session. Datagram framing alone does not make calls available.
  bool get supportsVoiceCallMedia =>
      const bool.fromEnvironment('CONEST_EXPERIMENTAL_VOICE_CALLS') &&
      _voiceAudio != null;

  bool get supportsNativeVoiceMessageRecording =>
      !kIsWeb &&
      (Platform.isLinux || Platform.isWindows) &&
      _voiceAudio != null;

  Future<void> startVoiceMessageRecording(String path) async {
    if (!supportsNativeVoiceMessageRecording) {
      throw StateError(
        'Native Ogg/Opus recording is unavailable on this device.',
      );
    }
    await _voiceAudio!.startVoiceMessageRecording(path);
  }

  Future<Map<String, dynamic>> stopVoiceMessageRecording() async {
    if (!supportsNativeVoiceMessageRecording) {
      throw StateError(
        'Native Ogg/Opus recording is unavailable on this device.',
      );
    }
    return _voiceAudio!.stopVoiceMessageRecording();
  }

  Future<void> cancelVoiceMessageRecording() async {
    await _voiceAudio?.cancelVoiceMessageRecording();
  }

  bool get _supportsAndroidSystemCalls => !kIsWeb && Platform.isAndroid;

  Future<void> setAndroidBackgroundRuntimeEnabled(
    bool enabled, {
    bool callsEnabled = false,
  }) async {
    if (!_supportsAndroidSystemCalls) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setBackgroundRuntimeEnabled', {
        'enabled': enabled,
        'callsEnabled': callsEnabled,
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<void> updateAndroidVoiceCallForeground({
    required bool runtimeEnabled,
    required bool callsEnabled,
    required String? peerName,
    required String callState,
    required bool incoming,
  }) async {
    if (!_supportsAndroidSystemCalls) return;
    try {
      await _channel.invokeMethod<void>('updateVoiceCallForeground', {
        'runtimeEnabled': runtimeEnabled,
        'callsEnabled': callsEnabled,
        'peerName': peerName,
        'callState': callState,
        'incoming': incoming,
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<void> scheduleAndroidScheduledMessageWakeup(DateTime? dueAt) async {
    if (!_supportsAndroidSystemCalls) return;
    try {
      await _channel.invokeMethod<void>('scheduleScheduledMessageWakeup', {
        'timestampMs': dueAt?.toUtc().millisecondsSinceEpoch,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      // The normal Dart timer remains active while Conest is running. This
      // native alarm only improves dispatch reliability during Android sleep.
      return;
    }
  }

  Future<void> updateTransferForeground({
    required String title,
    required int transferredBytes,
    required int totalBytes,
    required bool paused,
  }) async {
    if (!_supportsAndroidSystemCalls) return;
    try {
      await _channel.invokeMethod<void>('updateTransferForeground', {
        'title': title,
        'transferredBytes': transferredBytes,
        'totalBytes': totalBytes,
        'paused': paused,
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<void> stopTransferForeground() async {
    if (!_supportsAndroidSystemCalls) return;
    try {
      await _channel.invokeMethod<void>('stopTransferForeground');
    } on MissingPluginException {
      return;
    }
  }

  Future<void> requestNotificationPermission() async {
    if (!_supportsAndroidSystemCalls) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on MissingPluginException {
      return;
    }
  }

  /// Audio hooks are optional until the native Opus engine is bundled. The
  /// Dart call state machine treats a missing plugin as an unavailable media
  /// engine and ends the call cleanly.
  Future<bool> openVoiceCallMedia({
    required String peerDeviceId,
    required bool outgoing,
  }) async {
    final nativeAudio = _voiceAudio;
    if (!supportsVoiceCallMedia || nativeAudio == null) return false;
    await prepareVoiceCallMedia();
    await nativeAudio.open();
    if (Platform.isAndroid) {
      try {
        final started = await _channel
            .invokeMethod<bool>('openVoiceCallMedia', {
              'handle': nativeAudio.handle,
              'peerDeviceId': peerDeviceId,
              'outgoing': outgoing,
            });
        if (started != true) {
          await nativeAudio.close();
          return false;
        }
      } catch (_) {
        await nativeAudio.close();
        rethrow;
      }
    }
    return nativeAudio.isOpen;
  }

  Future<void> prepareVoiceCallMedia() async {
    if (!supportsVoiceCallMedia) {
      throw StateError('Native voice audio is unavailable in this build.');
    }
    if (Platform.isAndroid && !await _requestVoiceCallMicrophonePermission()) {
      throw StateError('Microphone permission is required for voice calls.');
    }
  }

  Future<bool> _requestVoiceCallMicrophonePermission() async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestVoiceCallMicrophonePermission',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> setVoiceCallMuted(bool muted) async {
    if (!(_voiceAudio?.setMuted(muted) ?? false)) {
      throw StateError('Could not update microphone mute state.');
    }
  }

  void setVoiceCallNetworkCongested(bool congested) {
    _voiceAudio?.setNetworkCongested(congested);
  }

  Future<bool> setVoiceCallSpeakerphoneEnabled(bool enabled) async {
    if (!_supportsAndroidSystemCalls) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'setVoiceCallSpeakerphoneEnabled',
            {'enabled': enabled},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<List<String>> voiceCallOutputDevices() async {
    if (kIsWeb || (!Platform.isLinux && !Platform.isWindows)) {
      return const [];
    }
    final audio = _voiceAudio;
    if (audio == null) return const [];
    return audio.availableOutputDevices();
  }

  Future<void> selectVoiceCallOutputDevice(String name) async {
    if (kIsWeb || (!Platform.isLinux && !Platform.isWindows)) {
      throw StateError(
        'Manual audio output selection is available on desktop.',
      );
    }
    final audio = _voiceAudio;
    if (audio == null) throw StateError('Native voice audio is unavailable.');
    await audio.selectOutputDevice(name);
  }

  Future<void> closeVoiceCallMedia() async {
    final nativeAudio = _voiceAudio;
    if (nativeAudio == null) return;
    if (Platform.isAndroid && nativeAudio.isOpen) {
      try {
        await _channel.invokeMethod<void>('closeVoiceCallMedia');
      } on MissingPluginException {
        // Still close Rust workers below if the platform implementation is
        // unexpectedly absent.
      } finally {
        await nativeAudio.close();
      }
    } else {
      await nativeAudio.close();
    }
  }

  Future<void> playVoiceCallAudioFrame(
    Uint8List bytes, {
    required int sequence,
  }) async {
    if (sequence <= 0 || bytes.isEmpty || bytes.length > 1100) return;
    _voiceAudio?.playPacket(sequence, bytes);
  }

  Future<Map<String, dynamic>?> startVoiceRecording() async {
    try {
      final value = await _channel.invokeMethod<dynamic>('startVoiceRecording');
      return value is Map
          ? value.map((key, value) => MapEntry('$key', value))
          : null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> stopVoiceRecording() async {
    try {
      final value = await _channel.invokeMethod<dynamic>('stopVoiceRecording');
      return value is Map
          ? value.map((key, value) => MapEntry('$key', value))
          : null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> cancelVoiceRecording() async {
    try {
      await _channel.invokeMethod<void>('cancelVoiceRecording');
    } on MissingPluginException {
      return;
    }
  }

  Future<bool> playVoiceMessage({required String path}) async {
    try {
      return await _channel.invokeMethod<bool>('playVoiceMessage', {
            'path': path,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stopVoicePlayback() async {
    try {
      await _channel.invokeMethod<void>('stopVoicePlayback');
    } on MissingPluginException {
      return;
    }
  }

  Future<void> showMessageNotification({
    required String title,
    required String body,
    required String conversationId,
    String? senderName,
    String? selfName,
    List<({String sender, String body, int timestampMs})> recentMessages =
        const [],
  }) async {
    if (!_supportsAndroidSystemCalls) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('showMessageNotification', {
        'title': title,
        'body': body,
        'conversationId': conversationId,
        'senderName': ?senderName,
        'selfName': ?selfName,
        'recentMessages': recentMessages
            .map(
              (m) => <String, Object?>{
                'sender': m.sender,
                'body': m.body,
                'timestampMs': m.timestampMs,
              },
            )
            .toList(growable: false),
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<void> dismissMessageNotification({
    required String conversationId,
  }) async {
    if (!_supportsAndroidSystemCalls) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('dismissMessageNotification', {
        'conversationId': conversationId,
      });
    } on MissingPluginException {
      return;
    } catch (_) {
      // Best-effort: never raise from a UI-event side-effect.
    }
  }

  /// Save attachment bytes into the Android public media collections. `kind`
  /// is one of 'image' (Pictures/conest), 'video' (Movies/conest), or 'other'
  /// (Download/conest). Returns the saved URI/path on success, null when the
  /// bridge is unavailable (non-Android, missing plugin), or throws on
  /// underlying I/O failure.
  Future<String?> saveMediaToGallery({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String kind,
  }) async {
    if (!_supportsAndroidSystemCalls) {
      return null;
    }
    try {
      final result = await _channel.invokeMethod<String>('saveMediaToGallery', {
        'bytes': bytes,
        'fileName': fileName,
        'mimeType': mimeType,
        'kind': kind,
      });
      return result;
    } on MissingPluginException {
      return null;
    }
  }

  /// Streaming counterpart to [saveMediaToGallery]. Passing a path keeps
  /// large attachments out of the method-channel heap.
  Future<String?> saveMediaFileToGallery({
    required String sourcePath,
    required String fileName,
    required String mimeType,
    required String kind,
  }) async {
    if (!_supportsAndroidSystemCalls) return null;
    try {
      return await _channel.invokeMethod<String>('saveMediaFileToGallery', {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
        'kind': kind,
      });
    } on MissingPluginException {
      return null;
    }
  }

  /// Stages the image bytes into the Android cache directory's
  /// `clipboard/` subdir via FileProvider and puts a content URI on the
  /// system clipboard via `ClipboardManager.setPrimaryClip`. Returns the
  /// resolved URI string on success, null when the bridge is unavailable
  /// (non-Android / missing plugin). Throws a `PlatformException` on
  /// underlying I/O or clipboard failure so the caller can fall back to
  /// the cross-platform super_clipboard path.
  Future<String?> copyImageToClipboard({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (!_supportsAndroidSystemCalls) return null;
    try {
      return await _channel.invokeMethod<String>('copyImageToClipboard', {
        'bytes': bytes,
        'fileName': fileName,
        'mimeType': mimeType,
      });
    } on MissingPluginException {
      return null;
    }
  }

  /// Show a native toast on Android. Other platforms / missing-plugin
  /// gracefully no-op so the call site doesn't need a platform guard.
  Future<void> showToast(String text, {bool long = false}) async {
    if (!_supportsAndroidSystemCalls) return;
    if (text.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('showToast', {
        'text': text,
        'long': long,
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<void> installDownloadedApk(String path) async {
    if (!_supportsAndroidSystemCalls) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('installDownloadedApk', {'path': path});
    } on MissingPluginException {
      return;
    }
  }
}
