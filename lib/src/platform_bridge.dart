import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
        }
      });
    } on AssertionError {
      // No BinaryMessenger is active.
    }
  }

  final MethodChannel _channel;
  final StreamController<String> _transferControls =
      StreamController<String>.broadcast();

  Stream<String> get transferControlEvents => _transferControls.stream;

  bool get _supportsAndroidSystemCalls => !kIsWeb && Platform.isAndroid;

  Future<void> setAndroidBackgroundRuntimeEnabled(bool enabled) async {
    if (!_supportsAndroidSystemCalls) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setBackgroundRuntimeEnabled', {
        'enabled': enabled,
      });
    } on MissingPluginException {
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
