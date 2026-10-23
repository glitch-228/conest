import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conest/src/desktop_notifications.dart';
import 'package:conest/src/desktop_tray.dart';
import 'package:conest/src/storage.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tray host's watcher: notes what registers with it.
class _FakeWatcher extends DBusObject {
  _FakeWatcher() : super(DBusObjectPath('/StatusNotifierWatcher'));
  final registered = <String>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.name == 'RegisterStatusNotifierItem') {
      registered.add(methodCall.values.first.asString());
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

/// The desktop's notification service: notes what is shown and closed.
class _FakeNotifications extends DBusObject {
  _FakeNotifications()
    : super(DBusObjectPath('/org/freedesktop/Notifications'));
  final shown = <(int, String, String)>[];
  final closed = <int>[];
  var _next = 1;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    switch (methodCall.name) {
      case 'Notify':
        final replaces = methodCall.values[1].asUint32();
        final id = replaces == 0 ? _next++ : replaces;
        shown.add((
          id,
          methodCall.values[3].asString(),
          methodCall.values[4].asString(),
        ));
        return DBusMethodSuccessResponse([DBusUint32(id)]);
      case 'CloseNotification':
        closed.add(methodCall.values.first.asUint32());
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

/// A private session bus for one test; null where dbus-daemon is missing.
Future<(Process, String)?> _privateBus() async {
  try {
    final daemon = await Process.start('dbus-daemon', [
      '--session',
      '--nofork',
      '--print-address',
    ]);
    final address = await daemon.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    return (daemon, address.trim());
  } catch (_) {
    return null;
  }
}

const _labels = (tooltip: 'Conest', show: 'Show Conest', quit: 'Quit');

void main() {
  final skip = Platform.isLinux ? null : 'D-Bus tray: Linux only';

  test(
    'with no tray host, nothing registers and closing still quits',
    () async {
      final bus = await _privateBus();
      if (bus == null) return markTestSkipped('no dbus-daemon here');
      final (daemon, address) = bus;
      addTearDown(daemon.kill);
      final client = DBusClient(DBusAddress(address));
      addTearDown(client.close);
      expect(
        await registerStatusNotifier(
          client,
          _labels,
          iconThemePath: '/nowhere',
          onShow: () {},
          onQuit: () {},
        ),
        isFalse,
      );
      // And without a bus at all, the tray stays off.
      final tray = DesktopTray(sessionBus: () async => null);
      expect(await tray.start(_labels, onQuit: () {}), isFalse);
      expect(tray.active, isFalse);
    },
    skip: skip,
  );

  test('with a tray host, the icon opens Conest and its menu quits', () async {
    final bus = await _privateBus();
    if (bus == null) return markTestSkipped('no dbus-daemon here');
    final (daemon, address) = bus;
    addTearDown(daemon.kill);
    final host = DBusClient(DBusAddress(address));
    addTearDown(host.close);
    final watcher = _FakeWatcher();
    await host.requestName('org.kde.StatusNotifierWatcher');
    await host.registerObject(watcher);

    final app = DBusClient(DBusAddress(address));
    addTearDown(app.close);
    var shown = 0;
    var quit = 0;
    expect(
      await registerStatusNotifier(
        app,
        _labels,
        iconThemePath: '/opt/conest/data',
        onShow: () => shown++,
        onQuit: () => quit++,
      ),
      isTrue,
    );
    expect(
      watcher.registered.single,
      startsWith('org.kde.StatusNotifierItem-'),
    );
    final item = watcher.registered.single;

    // The panel reads the icon and clicks it.
    final icon = await host.callMethod(
      destination: item,
      path: DBusObjectPath('/StatusNotifierItem'),
      interface: 'org.freedesktop.DBus.Properties',
      name: 'Get',
      values: const [
        DBusString('org.kde.StatusNotifierItem'),
        DBusString('IconThemePath'),
      ],
    );
    expect(icon.values.single.asVariant().asString(), '/opt/conest/data');
    await host.callMethod(
      destination: item,
      path: DBusObjectPath('/StatusNotifierItem'),
      interface: 'org.kde.StatusNotifierItem',
      name: 'Activate',
      values: const [DBusInt32(0), DBusInt32(0)],
    );
    expect(shown, 1);

    // Its menu: two items with the app's labels; "Quit" quits.
    final layout = await host.callMethod(
      destination: item,
      path: DBusObjectPath('/MenuBar'),
      interface: 'com.canonical.dbusmenu',
      name: 'GetLayout',
      values: [
        const DBusInt32(0),
        const DBusInt32(-1),
        DBusArray.string(const []),
      ],
    );
    final children = layout.values[1].asStruct()[2].asArray();
    final labels = [
      for (final child in children)
        child
            .asVariant()
            .asStruct()[1]
            .asStringVariantDict()['label']!
            .asString(),
    ];
    expect(labels, ['Show Conest', 'Quit']);
    await host.callMethod(
      destination: item,
      path: DBusObjectPath('/MenuBar'),
      interface: 'com.canonical.dbusmenu',
      name: 'Event',
      values: [
        const DBusInt32(TrayMenuObject.quitId),
        const DBusString('clicked'),
        const DBusVariant(DBusString('')),
        const DBusUint32(0),
      ],
    );
    expect(quit, 1);
    expect(shown, 1);
  }, skip: skip);

  test(
    'Linux notifications: one per chat, a click names it, read closes it',
    () async {
      final bus = await _privateBus();
      if (bus == null) return markTestSkipped('no dbus-daemon here');
      final (daemon, address) = bus;
      addTearDown(daemon.kill);
      final desktop = DBusClient(DBusAddress(address));
      addTearDown(desktop.close);
      final service = _FakeNotifications();
      await desktop.requestName('org.freedesktop.Notifications');
      await desktop.registerObject(service);

      final notifications = DesktopNotifications(
        sessionBus: () async => DBusClient(DBusAddress(address)),
      );
      addTearDown(notifications.close);
      final opened = <String>[];
      final listening = notifications.opened.listen(opened.add);
      addTearDown(listening.cancel);
      await notifications.show(chat: 'chat-a', title: 'Alice', body: 'hi');
      await notifications.show(chat: 'chat-a', title: 'Alice', body: 'again');
      await notifications.show(chat: 'chat-b', title: 'Bob', body: 'yo');
      // A second message in a chat replaces its notification.
      expect(service.shown.map((s) => s.$1), [1, 1, 2]);
      expect(service.shown.first.$2, 'Alice');
      expect(service.shown[1].$3, 'again');

      await service.emitSignal(
        'org.freedesktop.Notifications',
        'ActionInvoked',
        [const DBusUint32(2), const DBusString('default')],
      );
      for (var i = 0; i < 50 && opened.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(opened, ['chat-b']);

      await notifications.dismiss('chat-a');
      expect(service.closed, [1]);
    },
    skip: skip,
  );

  test('another start asks the running Conest to come forward', () async {
    final directory = await Directory.systemTemp.createTemp('conest_show_');
    addTearDown(() => directory.delete(recursive: true));
    final running = AppInstanceLock(directory: directory);
    final asked = Completer<void>();
    final subscription = running.showRequests().listen((_) {
      if (!asked.isCompleted) asked.complete();
    });
    addTearDown(subscription.cancel);
    // The watch is set up asynchronously.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await AppInstanceLock(directory: directory).requestShow();
    await asked.future.timeout(const Duration(seconds: 5));
  });
}
