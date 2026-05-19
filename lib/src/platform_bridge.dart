import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlatformBridge {
  PlatformBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.conest.conest/system');

  final MethodChannel _channel;

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
