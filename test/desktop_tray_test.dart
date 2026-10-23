import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
