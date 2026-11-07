import 'dart:typed_data';

import 'package:conest/l10n/app_localizations.dart';
import 'package:conest/src/net/cable_links.dart';
import 'package:conest/src/net/link_interfaces.dart';
import 'package:conest/src/ui/cable_links_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/strict_link_fakes.dart';

void main() {
  late StrictInterfaceSource interfaces;
  late CableLinks cable;
  final switched = <bool>[];
  var tetherOpened = 0;

  CableLinks makeCable({bool androidFallback = false}) => CableLinks(
    now: DateTime.now,
    interfaceSource: interfaces.call,
    pingSockets: (_) async => throw StateError('no sockets in this test'),
    buildPing: () async => <Uint8List>[],
    isKnownDevice: (_) => true,
    feedBeacon: (_, _) {},
    sendProbe: (_, _) async => true,
    newProbeId: () => 'probe',
    androidFallback: androidFallback,
  );

  Widget page({
    bool enabled = true,
    bool tether = false,
    bool linux = false,
    bool windows = false,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(
      body: CableLinksView(
        cable: cable,
        enabled: enabled,
        onEnabledChanged: switched.add,
        contactName: (id) => id == 'dev-anna' ? 'Anna' : id,
        onOpenTetherSettings: () async {
          tetherOpened++;
          return true;
        },
        showTetherButton: tether,
        showLinuxHelp: linux,
        showWindowsHelp: windows,
      ),
    ),
  );

  setUp(() {
    switched.clear();
    tetherOpened = 0;
    interfaces = StrictInterfaceSource([
      RawInterface(name: 'enp3s0', index: 7, addresses: ['169.254.10.1']),
      RawInterface(name: 'rndis0', index: 9, addresses: ['192.168.42.5']),
      RawInterface(name: 'wlan0', index: 3, addresses: ['192.168.3.11']),
    ]);
    cable = makeCable();
  });

  tearDown(() => cable.dispose());

  testWidgets('shows each link with its kind and addresses, and "looking" '
      'for those that look for contacts', (tester) async {
    await cable.onLinksChanged();
    await tester.pumpWidget(page());
    expect(find.text('Ethernet cable · enp3s0'), findsOneWidget);
    expect(find.text('USB tethering · rndis0'), findsOneWidget);
    expect(find.text('Wi-Fi · wlan0'), findsOneWidget);
    expect(find.textContaining('169.254.10.1'), findsOneWidget);
    expect(find.textContaining('192.168.42.5'), findsOneWidget);
    // Two cable-like links look for contacts, the Wi-Fi one does not.
    expect(find.textContaining('Looking for contacts'), findsNWidgets(2));
    // The page stops its own pings' sockets: nothing in this test opens one.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('contacts that proved themselves on a link are named', (
    tester,
  ) async {
    await cable.onLinksChanged();
    cable.table.confirm(
      deviceId: 'dev-anna',
      ifIndex: 9,
      ifName: 'rndis0',
      address: '192.168.42.129',
      relayPort: 7667,
    );
    await tester.pumpWidget(page());
    expect(find.textContaining('Reachable: Anna'), findsOneWidget);
    expect(find.textContaining('Looking for contacts'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('no link: it says so; the switch calls back and off hides the '
      'links', (tester) async {
    interfaces.interfaces = [];
    await cable.onLinksChanged();
    await tester.pumpWidget(page());
    expect(find.byKey(const ValueKey('cable-links-none')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cable-links-enabled')));
    expect(switched, [false]);
    await tester.pumpWidget(page(enabled: false));
    expect(find.byKey(const ValueKey('cable-links-none')), findsNothing);
    expect(find.byKey(const ValueKey('cable-link-enp3s0')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('help: the plug line always, Linux and Windows lines on their '
      'systems, the tethering button on Android', (tester) async {
    await cable.onLinksChanged();
    await tester.pumpWidget(page());
    expect(find.textContaining('Plug in a cable'), findsOneWidget);
    expect(find.textContaining('Link-local only'), findsNothing);
    expect(find.textContaining('Windows may ask'), findsNothing);
    expect(
      find.byKey(const ValueKey('cable-links-open-tethering')),
      findsNothing,
    );
    await tester.pumpWidget(page(linux: true, windows: true, tether: true));
    expect(find.textContaining('Link-local only'), findsOneWidget);
    expect(find.textContaining('Windows may ask'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cable-links-open-tethering')));
    expect(tetherOpened, 1);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an IPv6 link-local address is never shown', (tester) async {
    interfaces.interfaces = [
      RawInterface(
        name: 'enp3s0',
        index: 7,
        addresses: ['169.254.10.1', 'fe80::1234:5678'],
      ),
    ];
    await cable.onLinksChanged();
    await tester.pumpWidget(page());
    expect(find.textContaining('fe80'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('while the page is shown the Android fallback may look, and '
      'when it goes the fallback stops', (tester) async {
    cable.dispose();
    cable = makeCable(androidFallback: true);
    cable.watcher
      ..setForeground(true)
      ..setEnabled(true);
    expect(cable.watcher.fallbackRunning, isFalse);
    await cable.onLinksChanged();
    await tester.pumpWidget(page());
    expect(cable.watcher.fallbackRunning, isTrue);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(cable.watcher.fallbackRunning, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('kind labels: usb names are tethering, other wired names are '
      'cables', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    String label(String name, LinkKind kind) => cableLinkKindLabel(
      context,
      CableLinkView(
        name: name,
        kind: kind,
        addresses: const [],
        contactDeviceIds: const [],
        pingable: true,
      ),
    );
    for (final name in [
      'usb0',
      'rndis0',
      'ncm0',
      'enx0a1b2c3d4e5f',
      'enp0s20f0u2',
      'Remote NDIS based Internet Sharing Device',
    ]) {
      expect(label(name, LinkKind.cable), 'USB tethering', reason: name);
    }
    for (final name in ['enp3s0', 'eth0', 'Ethernet 3', 'eno1']) {
      expect(label(name, LinkKind.cable), 'Ethernet cable', reason: name);
    }
    expect(label('wlan0', LinkKind.wifi), 'Wi-Fi');
    expect(label('dummy0', LinkKind.other), 'Network link');
  });
}
