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
  }) async {
    if (!_supportsAndroidSystemCalls) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('showMessageNotification', {
        'title': title,
        'body': body,
        'conversationId': conversationId,
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
