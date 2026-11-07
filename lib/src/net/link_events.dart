import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'link_monitor_bridge.dart';
import 'link_watcher.dart';

/// The Android plugin's event, as a [LinkEventSource]; null for anything
/// else. `network` is a network callback, `usb` the USB_STATE broadcast and
/// `tether` the TETHER_STATE_CHANGED broadcast (see LinkEventsPlugin.kt).
LinkEventSource? linkEventSourceFromAndroid(Object? event) {
  if (event is! Map) return null;
  return switch (event['source']) {
    'network' => LinkEventSource.androidNetwork,
    'usb' => LinkEventSource.androidUsbState,
    'tether' => LinkEventSource.androidTether,
    _ => null,
  };
}

/// The platform's own sources of "the links may have changed": the native
/// monitor on Linux and Windows, the plugin's network callback and
/// broadcasts on Android. They are only started while Conest runs, and each
/// event goes to [note] (the controller debounces them).
class LinkEventSources {
  LinkEventSources._(this._monitor, this._subscription);

  static const MethodChannel _methods = MethodChannel('dev.conest/links');
  static const EventChannel _events = EventChannel('dev.conest/links/events');

  final LinkMonitorLoop? _monitor;
  final StreamSubscription<Object?>? _subscription;

  static LinkEventSources start(void Function(LinkEventSource source) note) {
    LinkMonitorLoop? monitor;
    StreamSubscription<Object?>? subscription;
    try {
      if (Platform.isAndroid) {
        subscription = _events.receiveBroadcastStream().listen((event) {
          final source = linkEventSourceFromAndroid(event);
          if (source != null) note(source);
        }, onError: (Object _) {});
      } else if (Platform.isLinux || Platform.isWindows) {
        monitor = NativeLinkMonitor.tryCreate()?.loop(
          () => note(LinkEventSource.monitor),
        );
        monitor?.start();
      }
    } catch (_) {
      // No platform source: connectivity_plus and the page's rediscovery
      // remain.
    }
    return LinkEventSources._(monitor, subscription);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _monitor?.stop();
  }

  /// Opens the system page for USB tethering (apps cannot turn it on).
  /// False where there is none.
  static Future<bool> openTetherSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _methods.invokeMethod<bool>('openTetherSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
