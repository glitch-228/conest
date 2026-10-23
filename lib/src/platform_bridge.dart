import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_notifications.dart';
import 'energy_policy.dart';
import 'voice_audio_ffi.dart';

/// Reply or "Mark as read" chosen on a message notification (Android).
/// [throughMessageId] is the newest message the notification showed: what
/// "read" covers, not messages that came after it.
typedef NotificationAction = ({
  String conversationId,
  String action,
  String? text,
  String? throughMessageId,
});

/// Native calls. Each bridge takes the system channel's callbacks for
/// itself, so the app keeps one (the controller's); elsewhere use static
/// helpers such as [PlatformBridge.openUrl].
class PlatformBridge {
  static const notificationReply = 'reply';
  static const notificationMarkRead = 'markRead';

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
        } else if (call.method == 'shareAvailable') {
          _shareAvailable.add(null);
        } else if (call.method == 'openConversation' &&
            call.arguments is String) {
          _conversationOpens.add(call.arguments as String);
        } else if (call.method == 'notificationAction') {
          final action = notificationActionFrom(call.arguments);
          if (action != null) _notificationActions.add(action);
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
  final StreamController<void> _shareAvailable =
      StreamController<void>.broadcast();
  final StreamController<String> _conversationOpens =
      StreamController<String>.broadcast();
  final StreamController<NotificationAction> _notificationActions =
      StreamController<NotificationAction>.broadcast();

  /// Reply and "Mark as read" from message notifications while Conest runs;
  /// those from before it ran come from [takePendingNotificationActions].
  Stream<NotificationAction> get notificationActions =>
      _notificationActions.stream;

  /// What Android sends for a notification action; null for anything else.
  static NotificationAction? notificationActionFrom(Object? arguments) {
    if (arguments is! Map) return null;
    final conversationId = arguments['conversationId'];
    final action = arguments['action'];
    final text = arguments['text'];
    final through = arguments['throughMessageId'];
    if (conversationId is! String || action is! String) return null;
    return (
      conversationId: conversationId,
      action: action,
      text: text is String ? text : null,
      throughMessageId: through is String ? through : null,
    );
  }

  /// The notification actions taken so far are handled: Android lets
  /// Conest leave the foreground again (unless it runs in the background).
  Future<void> notificationActionsDone() async {
    if (!_supportsAndroidSystemCalls) return;
    try {
      await _channel.invokeMethod<void>('notificationActionsDone');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// Notification actions taken while Conest was not running yet (Android).
  Future<List<NotificationAction>> takePendingNotificationActions() async {
    if (!_supportsAndroidSystemCalls) return const [];
    try {
      final pending = await _channel.invokeMethod<List<Object?>>(
        'takePendingNotificationActions',
      );
      return [
        for (final entry in pending ?? const <Object?>[])
          ?notificationActionFrom(entry),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Another app shared something with Conest (Android): take it with
  /// [takePendingShare].
  Stream<void> get shareAvailableEvents => _shareAvailable.stream;

  /// The clipboard's image or file (Android), copied into the cache; null
  /// when it holds only text, or nothing.
  Future<({String path, String name, String mimeType})?>
  takeClipboardMedia() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final value = await _channel.invokeMethod<Object?>('takeClipboardMedia');
      return SharedContent.fromPlatform({
        'files': [value],
      })?.files.firstOrNull;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Battery, charging and battery saver (Android); null elsewhere or
  /// when unknown.
  Future<PowerState?> powerState() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final value = await _channel.invokeMethod<Object?>('powerState');
      if (value is! Map) return null;
      final percent = value['batteryPercent'];
      return PowerState(
        hasBattery: value['hasBattery'] is bool
            ? value['hasBattery'] as bool
            : null,
        charging: value['charging'] is bool ? value['charging'] as bool : null,
        batteryPercent: percent is int && percent >= 0 && percent <= 100
            ? percent
            : null,
        batterySaver: value['batterySaver'] == true,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// What another app shared, copied into the cache; null when nothing
  /// waits (or not on Android).
  Future<SharedContent?> takePendingShare() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final value = await _channel.invokeMethod<Object?>('takePendingShare');
      return SharedContent.fromPlatform(value);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

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

  /// Whether this is Android (tests stand in for one).
  bool get runsOnAndroid => _supportsAndroidSystemCalls;

  /// Message notifications on Linux and Windows.
  late final DesktopNotifications? _desktopNotifications =
      !kIsWeb && (Platform.isLinux || Platform.isWindows)
      ? (DesktopNotifications()..opened.listen(_conversationOpens.add))
      : null;

  /// The chat (its conversation id) whose notification was clicked.
  Stream<String> get notificationOpens {
    _desktopNotifications;
    return _conversationOpens.stream;
  }

  /// Android: the chat of the notification that opened the app, if any.
  Future<String?> takePendingConversation() async {
    if (!_supportsAndroidSystemCalls) return null;
    try {
      return await _channel.invokeMethod<String>('takePendingConversation');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Windows: the runner reports a click on its tray notification.
  void notificationClicked(String chat) =>
      _desktopNotifications?.clickedOnWindows(chat);

  /// Whether Android leaves Conest out of battery optimisation; null where
  /// that cannot be told (not Android, an older app part).
  Future<bool?> batteryOptimizationExempt() async {
    if (!_supportsAndroidSystemCalls) return null;
    try {
      return await _channel.invokeMethod<bool>('batteryOptimizationExempt');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens Android's request to leave Conest out of battery optimisation;
  /// false when it could not be opened.
  Future<bool> requestBatteryOptimizationExemption() async {
    if (!_supportsAndroidSystemCalls) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'requestBatteryOptimizationExemption',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// The phone's maker (for vendor-specific background limits).
  Future<String?> deviceManufacturer() async {
    if (!_supportsAndroidSystemCalls) return null;
    try {
      return await _channel.invokeMethod<String>('deviceManufacturer');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// [persist]: kept for a start without the app (after a reboot, an
  /// update, the process killed); false for a shutdown that is no choice.
  Future<void> setAndroidBackgroundRuntimeEnabled(
    bool enabled, {
    bool callsEnabled = false,
    bool persist = true,
  }) async {
    if (!_supportsAndroidSystemCalls) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setBackgroundRuntimeEnabled', {
        'enabled': enabled,
        'callsEnabled': callsEnabled,
        'persist': persist,
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
    } on PlatformException {
      // Android refuses a foreground start from the background: the next
      // change tries again.
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

  Future<void> setVoiceCallNoiseSuppression(bool enabled) async {
    if (!(_voiceAudio?.setNoiseSuppression(enabled) ?? false)) {
      throw StateError('Could not update noise suppression.');
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

  /// The last call's audio statistics, taken as it closed (see
  /// [NativeVoiceCallAudio.stats]); the current call's while one is open.
  Map<String, Object?>? get voiceCallStats =>
      _voiceAudio?.stats() ?? _lastVoiceCallStats;
  Map<String, Object?>? _lastVoiceCallStats;

  Future<void> closeVoiceCallMedia() async {
    final nativeAudio = _voiceAudio;
    if (nativeAudio == null) return;
    _lastVoiceCallStats = nativeAudio.stats() ?? _lastVoiceCallStats;
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

  bool setGroupCallParticipant(int participant, bool active) =>
      _voiceAudio?.setParticipant(participant, active) ?? false;

  double groupCallParticipantLevel(int participant) =>
      _voiceAudio?.participantLevel(participant) ?? 0;

  bool playGroupCallFrame(int participant, int sequence, Uint8List bytes) =>
      _voiceAudio?.playParticipantPacket(participant, sequence, bytes) ?? false;

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
    String? replyLabel,
    String? markReadLabel,
    String? throughMessageId,
  }) async {
    if (!_supportsAndroidSystemCalls) {
      await _desktopNotifications?.show(
        chat: conversationId,
        title: title,
        body: body,
      );
      return;
    }
    try {
      await _channel.invokeMethod<void>('showMessageNotification', {
        'title': title,
        'body': body,
        'conversationId': conversationId,
        'senderName': ?senderName,
        'selfName': ?selfName,
        'replyLabel': ?replyLabel,
        'markReadLabel': ?markReadLabel,
        'throughMessageId': ?throughMessageId,
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
      await _desktopNotifications?.dismiss(conversationId);
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
  /// Opens [url] in the system browser.
  Future<void> openExternalUrl(Uri url) => openUrl(url, channel: _channel);

  /// Opens [url] in the system's browser or mail app, with no bridge of
  /// its own (see the class note).
  static Future<void> openUrl(
    Uri url, {
    MethodChannel channel = const MethodChannel('dev.conest.conest/system'),
  }) async {
    if (kIsWeb) return;
    final link = url.toString();
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('openUrl', {'url': link});
    } else if (Platform.isWindows) {
      // `start` would split the link at each `&` of its query.
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', link]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [link]);
    } else {
      await Process.start('xdg-open', [link]);
    }
  }

  /// On Android, the automatic tests a debug build was started for
  /// (`adb shell am start … --es conestDebugRun routes`); null otherwise.
  /// Why earlier runs ended badly (crashes, native crashes, freezes), as
  /// Android recorded it; each is reported once.
  Future<List<Map<Object?, Object?>>> takeAndroidExitReports() async {
    if (!_supportsAndroidSystemCalls) return const [];
    try {
      final reports = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'takeExitReports',
      );
      return reports ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  Future<String?> debugRunRequest() async {
    if (!_supportsAndroidSystemCalls) return null;
    try {
      return await _channel.invokeMethod<String>('debugRunRequest');
    } on MissingPluginException {
      return null;
    }
  }

  /// Where Android extracted the app's native libraries, which may also
  /// hold bundled helper programs (such as Tor's pluggable transports).
  Future<String?> nativeLibraryDirectory() async {
    if (!_supportsAndroidSystemCalls) return null;
    try {
      return await _channel.invokeMethod<String>('nativeLibraryDir');
    } on MissingPluginException {
      return null;
    }
  }

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

/// Files and text another app shared with Conest.
class SharedContent {
  const SharedContent({this.files = const [], this.text});

  final List<({String path, String name, String mimeType})> files;
  final String? text;

  bool get isEmpty => files.isEmpty && (text == null || text!.isEmpty);

  static SharedContent? fromPlatform(Object? value) {
    if (value is! Map) return null;
    final files = <({String path, String name, String mimeType})>[];
    for (final file in value['files'] as List? ?? const []) {
      if (file is! Map) continue;
      final path = file['path'];
      final name = file['name'];
      if (path is! String || name is! String) continue;
      files.add((
        path: path,
        name: name,
        mimeType: file['mimeType'] as String? ?? 'application/octet-stream',
      ));
    }
    final text = value['text'];
    final content = SharedContent(
      files: files,
      text: text is String ? text : null,
    );
    return content.isEmpty ? null : content;
  }
}

/// Android's power state, through the platform channel.
class PlatformBridgePowerSource implements PowerStateSource {
  const PlatformBridgePowerSource(this.bridge);

  final PlatformBridge bridge;

  @override
  Future<PowerState> read() async =>
      await bridge.powerState() ?? PowerState.unknown;
}
