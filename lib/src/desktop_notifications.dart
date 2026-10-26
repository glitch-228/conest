import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';

/// An action taken on a desktop message notification.
typedef DesktopNotificationAction = ({
  String chat,
  String action,
  String? text,
  String? throughMessageId,
});

/// Message notifications on desktops: Linux through the desktop's
/// notification service (org.freedesktop.Notifications, over D-Bus with no
/// native library), Windows from Conest's tray icon. One notification per
/// chat, replaced as more arrives; clicking it brings Conest forward and
/// names the chat ([opened]).
class DesktopNotifications {
  DesktopNotifications({
    MethodChannel window = const MethodChannel('dev.conest.conest/window'),
    Future<DBusClient?> Function()? sessionBus,
  }) : _window = window,
       _sessionBus = sessionBus ?? _defaultSessionBus;

  final MethodChannel _window;
  final Future<DBusClient?> Function() _sessionBus;
  final _opened = StreamController<String>.broadcast();
  final _taken = StreamController<DesktopNotificationAction>.broadcast();

  /// The chat whose notification was clicked.
  Stream<String> get opened => _opened.stream;

  /// "Mark as read" or a reply typed into a notification (Linux; a reply
  /// where the desktop offers inline replies, such as KDE Plasma).
  Stream<DesktopNotificationAction> get actions => _taken.stream;

  DBusClient? _bus;
  Future<DBusClient?>? _connecting;
  StreamSubscription<DBusSignal>? _actions;
  StreamSubscription<DBusSignal>? _replies;
  Set<String>? _capabilities;

  /// The newest message each chat's notification showed (what "read"
  /// covers).
  final Map<String, String?> _through = {};

  /// Notification ids by chat (Linux), and chats by id.
  final Map<String, int> _ids = {};
  final Map<int, String> _chats = {};

  static Future<DBusClient?> _defaultSessionBus() async {
    try {
      return DBusClient.session();
    } catch (_) {
      return null;
    }
  }

  static final _path = DBusObjectPath('/org/freedesktop/Notifications');
  static const _name = 'org.freedesktop.Notifications';

  Future<DBusClient?> _connect() => _connecting ??= () async {
    final bus = await _sessionBus();
    if (bus == null) return null;
    _bus = bus;
    _actions =
        DBusSignalStream(
          bus,
          sender: _name,
          interface: _name,
          name: 'ActionInvoked',
          path: _path,
          signature: DBusSignature('us'),
        ).listen((signal) {
          final chat = _chats[signal.values.first.asUint32()];
          if (chat == null) return;
          switch (signal.values[1].asString()) {
            case 'default':
              _opened.add(chat);
            case 'mark-read':
              _taken.add((
                chat: chat,
                action: 'markRead',
                text: null,
                throughMessageId: _through[chat],
              ));
          }
        });
    _replies =
        DBusSignalStream(
          bus,
          sender: _name,
          interface: _name,
          name: 'NotificationReplied',
          path: _path,
          signature: DBusSignature('us'),
        ).listen((signal) {
          final chat = _chats[signal.values.first.asUint32()];
          final text = signal.values[1].asString();
          if (chat == null || text.trim().isEmpty || text.length > 4096) {
            return;
          }
          _taken.add((
            chat: chat,
            action: 'reply',
            text: text,
            throughMessageId: _through[chat],
          ));
        });
    try {
      final reply = await bus.callMethod(
        destination: _name,
        path: _path,
        interface: _name,
        name: 'GetCapabilities',
        replySignature: DBusSignature('as'),
      );
      _capabilities = reply.values.first.asStringArray().toSet();
    } catch (_) {
      _capabilities = const {};
    }
    return bus;
  }();

  /// Shows (or replaces) [chat]'s notification.
  Future<void> show({
    required String chat,
    required String title,
    required String body,
    bool silent = false,
    String? replyLabel,
    String? markReadLabel,
    String? throughMessageId,
  }) async {
    _through[chat] = throughMessageId;
    if (Platform.isWindows) {
      try {
        await _window.invokeMethod<void>('notify', {
          'chat': chat,
          'title': title,
          'body': body,
          'silent': silent,
        });
      } on MissingPluginException {
        // An older runner: no notification.
      } on PlatformException {
        // No tray icon to show it from.
      }
      return;
    }
    if (!Platform.isLinux) return;
    final bus = await _connect();
    if (bus == null) return;
    try {
      final reply = await bus.callMethod(
        destination: _name,
        path: _path,
        interface: _name,
        name: 'Notify',
        values: [
          const DBusString('Conest'),
          DBusUint32(_ids[chat] ?? 0),
          const DBusString('conest'),
          DBusString(title),
          DBusString(body),
          DBusArray.string([
            'default',
            'Open',
            if (markReadLabel != null) ...['mark-read', markReadLabel],
            if (replyLabel != null &&
                _capabilities?.contains('inline-reply') == true) ...[
              'inline-reply',
              replyLabel,
            ],
          ]),
          DBusDict.stringVariant({
            'category': const DBusString('im.received'),
            'desktop-entry': const DBusString('conest'),
            // Quiet hours: shown, not heard.
            if (silent) 'suppress-sound': const DBusBoolean(true),
            if (silent) 'urgency': const DBusByte(0),
          }),
          const DBusInt32(-1),
        ],
        replySignature: DBusSignature('u'),
      );
      final id = reply.values.first.asUint32();
      final previous = _ids[chat];
      if (previous != null && previous != id) _chats.remove(previous);
      _ids[chat] = id;
      _chats[id] = chat;
    } catch (_) {
      // No notification service on this desktop.
    }
  }

  /// Takes [chat]'s notification away (it was read).
  Future<void> dismiss(String chat) async {
    if (Platform.isWindows) {
      try {
        await _window.invokeMethod<void>('dismissNotification', chat);
      } on MissingPluginException {
        // An older runner.
      } on PlatformException {
        // Nothing shown.
      }
      return;
    }
    _through.remove(chat);
    final id = _ids.remove(chat);
    if (id == null) return;
    _chats.remove(id);
    final bus = _bus;
    if (bus == null) return;
    try {
      await bus.callMethod(
        destination: _name,
        path: _path,
        interface: _name,
        name: 'CloseNotification',
        values: [DBusUint32(id)],
        replySignature: DBusSignature(''),
      );
    } catch (_) {}
  }

  /// Windows: the runner reports a click on its notification.
  void clickedOnWindows(String chat) => _opened.add(chat);

  Future<void> close() async {
    await _actions?.cancel();
    await _replies?.cancel();
    await _taken.close();
    await _bus?.close();
    await _opened.close();
  }
}
