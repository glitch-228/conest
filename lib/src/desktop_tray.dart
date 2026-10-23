import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';

/// What the tray shows, in the app's language.
typedef TrayLabels = ({String tooltip, String show, String quit});

/// Conest in the tray on desktops: closing the window hides it, and the
/// tray icon brings it back or quits. Windows uses the runner's own tray
/// icon; Linux a StatusNotifierItem over D-Bus (KDE, most other desktops,
/// GNOME with the AppIndicator extension). Without a tray host nothing
/// changes and closing quits, so Conest is never left out of reach.
class DesktopTray {
  DesktopTray({
    MethodChannel window = const MethodChannel('dev.conest.conest/window'),
    Future<DBusClient?> Function()? sessionBus,
  }) : _window = window,
       _sessionBus = sessionBus ?? _defaultSessionBus;

  final MethodChannel _window;
  final Future<DBusClient?> Function() _sessionBus;
  DBusClient? _bus;
  bool _active = false;

  /// Whether closing the window now keeps Conest in the tray.
  bool get active => _active;

  static Future<DBusClient?> _defaultSessionBus() async {
    try {
      return DBusClient.session();
    } catch (_) {
      return null;
    }
  }

  /// Puts Conest in the tray; false where there is no tray to put it in.
  /// [onQuit] runs for "Quit" (it saves, then calls [quit]).
  Future<bool> start(
    TrayLabels labels, {
    required void Function() onQuit,
  }) async {
    await stop();
    if (Platform.isWindows) {
      _window.setMethodCallHandler((call) async {
        if (call.method == 'quitRequested') onQuit();
      });
      final added = await _invoke<bool>('setCloseToTray', {
        'enabled': true,
        'tooltip': labels.tooltip,
        'show': labels.show,
        'quit': labels.quit,
      });
      return _active = added == true;
    }
    if (!Platform.isLinux) return false;
    final bus = await _sessionBus();
    if (bus == null) return false;
    final registered = await registerStatusNotifier(
      bus,
      labels,
      iconThemePath: _iconDirectory(),
      onShow: show,
      onQuit: onQuit,
    );
    if (!registered) {
      await bus.close();
      return false;
    }
    _bus = bus;
    await _invoke<void>('setCloseToTray', true);
    return _active = true;
  }

  /// Out of the tray: closing quits again.
  Future<void> stop() async {
    if (_active) {
      await _invoke<void>(
        'setCloseToTray',
        Platform.isWindows ? {'enabled': false} : false,
      );
    }
    _active = false;
    final bus = _bus;
    _bus = null;
    await bus?.close();
  }

  /// Brings the window back.
  Future<void> show() => _invoke<void>('show');

  /// Ends Conest (after it saved: see [start]'s onQuit).
  Future<void> quit() async {
    await stop();
    await _invoke<void>('quit');
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _window.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The bundle's data/ folder, where conest.png lies.
  static String _iconDirectory() =>
      '${File(Platform.resolvedExecutable).parent.path}/data';
}

/// Registers Conest as a StatusNotifierItem with its menu on [bus]; false
/// when no tray host (StatusNotifierWatcher) is running.
Future<bool> registerStatusNotifier(
  DBusClient bus,
  TrayLabels labels, {
  required String iconThemePath,
  required void Function() onShow,
  required void Function() onQuit,
}) async {
  final name = 'org.kde.StatusNotifierItem-$pid-1';
  try {
    await bus.requestName(name);
    await bus.registerObject(
      StatusNotifierItemObject(
        title: labels.tooltip,
        iconThemePath: iconThemePath,
        onActivate: onShow,
      ),
    );
    await bus.registerObject(
      TrayMenuObject(
        show: labels.show,
        quit: labels.quit,
        onShow: onShow,
        onQuit: onQuit,
      ),
    );
    await bus.callMethod(
      destination: 'org.kde.StatusNotifierWatcher',
      path: DBusObjectPath('/StatusNotifierWatcher'),
      interface: 'org.kde.StatusNotifierWatcher',
      name: 'RegisterStatusNotifierItem',
      values: [DBusString(name)],
      replySignature: DBusSignature(''),
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// org.kde.StatusNotifierItem: Conest's icon, opening the window when
/// clicked.
class StatusNotifierItemObject extends DBusObject {
  StatusNotifierItemObject({
    required this.title,
    required this.iconThemePath,
    required this.onActivate,
  }) : super(DBusObjectPath('/StatusNotifierItem'));

  static const interfaceName = 'org.kde.StatusNotifierItem';

  final String title;
  final String iconThemePath;
  final void Function() onActivate;

  Map<String, DBusValue> get _properties => {
    'Category': const DBusString('Communications'),
    'Id': const DBusString('conest'),
    'Title': DBusString(title),
    'Status': const DBusString('Active'),
    'IconName': const DBusString('conest'),
    'IconThemePath': DBusString(iconThemePath),
    'ItemIsMenu': const DBusBoolean(false),
    'Menu': DBusObjectPath('/MenuBar'),
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != interfaceName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'Activate':
      case 'SecondaryActivate':
        onActivate();
        return DBusMethodSuccessResponse();
      case 'ContextMenu':
      case 'Scroll':
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == interfaceName ? _properties[name] : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == interfaceName ? _properties : const {},
      );
}

/// com.canonical.dbusmenu: the tray icon's menu, "Show Conest" and "Quit".
class TrayMenuObject extends DBusObject {
  TrayMenuObject({
    required this.show,
    required this.quit,
    required this.onShow,
    required this.onQuit,
  }) : super(DBusObjectPath('/MenuBar'));

  static const interfaceName = 'com.canonical.dbusmenu';
  static const showId = 1;
  static const quitId = 2;

  final String show;
  final String quit;
  final void Function() onShow;
  final void Function() onQuit;

  Map<String, DBusValue> _itemProperties(int id) => switch (id) {
    0 => {'children-display': const DBusString('submenu')},
    showId => {'label': DBusString(show)},
    quitId => {'label': DBusString(quit)},
    _ => const {},
  };

  /// (ia{sv}av): an item, its properties, and its children each wrapped
  /// in a variant (once: DBusArray.variant wraps them).
  DBusStruct _item(int id, List<DBusValue> children) => DBusStruct([
    DBusInt32(id),
    DBusDict.stringVariant(_itemProperties(id)),
    DBusArray.variant(children),
  ]);

  /// The whole menu: the root (0) and its two items.
  DBusStruct layout() =>
      _item(0, [_item(showId, const []), _item(quitId, const [])]);

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != interfaceName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final values = methodCall.values;
    switch (methodCall.name) {
      case 'GetLayout':
        return DBusMethodSuccessResponse([const DBusUint32(1), layout()]);
      case 'GetGroupProperties':
        final ids = values.isEmpty
            ? const <int>[]
            : values.first.asInt32Array().toList();
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in ids)
              if (_itemProperties(id).isNotEmpty)
                DBusStruct([
                  DBusInt32(id),
                  DBusDict.stringVariant(_itemProperties(id)),
                ]),
          ]),
        ]);
      case 'GetProperty':
        final id = values.first.asInt32();
        final name = values[1].asString();
        final value = _itemProperties(id)[name];
        return value == null
            ? DBusMethodErrorResponse.unknownProperty()
            : DBusMethodSuccessResponse([DBusVariant(value)]);
      case 'Event':
        _event(values.first.asInt32(), values[1].asString());
        return DBusMethodSuccessResponse();
      case 'EventGroup':
        for (final event in values.first.asArray()) {
          final fields = event.asStruct();
          _event(fields.first.asInt32(), fields[1].asString());
        }
        return DBusMethodSuccessResponse([DBusArray.int32(const [])]);
      case 'AboutToShow':
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'AboutToShowGroup':
        return DBusMethodSuccessResponse([
          DBusArray.int32(const []),
          DBusArray.int32(const []),
        ]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  void _event(int id, String event) {
    if (event != 'clicked') return;
    if (id == showId) onShow();
    if (id == quitId) onQuit();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == interfaceName ? _menuProperties[name] : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == interfaceName ? _menuProperties : const {},
      );

  static final Map<String, DBusValue> _menuProperties = {
    'Version': const DBusUint32(3),
    'TextDirection': const DBusString('ltr'),
    'Status': const DBusString('normal'),
    'IconThemePath': DBusArray.string(const []),
  };
}
