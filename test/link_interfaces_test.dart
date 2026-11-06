import 'package:conest/src/local_relay_node.dart';
import 'package:conest/src/net/link_interfaces.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/strict_link_fakes.dart';

RawInterface raw(String name, int index, List<String> addresses) =>
    RawInterface(name: name, index: index, addresses: addresses);

void main() {
  group('classifyLinkInterface', () {
    test('wired and USB names are cables', () {
      for (final name in [
        'usb0',
        'rndis0',
        'ncm0',
        'enx0a1b2c3d4e5f',
        'enp0s20f0u2',
        'enp3s0',
        'eno1',
        'eth0',
        'Ethernet',
        'Ethernet 3',
        'Local Area Connection* 10',
        'Remote NDIS based Internet Sharing Device',
      ]) {
        expect(classifyLinkInterface(name), LinkKind.cable, reason: name);
      }
    });

    test('Wi-Fi names are Wi-Fi, anything else is other', () {
      for (final name in ['wlan0', 'wlp3s0', 'swlan0', 'ap0', 'Wi-Fi']) {
        expect(classifyLinkInterface(name), LinkKind.wifi, reason: name);
      }
      for (final name in ['lo', 'dummy0', 'something']) {
        expect(classifyLinkInterface(name), LinkKind.other, reason: name);
      }
    });

    test('the names a cable can have all pass the interface ignore list', () {
      for (final name in [
        'usb0',
        'rndis0',
        'ncm0',
        'enx0a1b2c3d4e5f',
        'enp0s20f0u2',
        'eth1',
        'Ethernet 3',
        'Remote NDIS based Internet Sharing Device',
      ]) {
        expect(isIgnoredLanInterfaceName(name), isFalse, reason: name);
      }
    });
  });

  group('isLinkScopedHost', () {
    test('link-local addresses and anything with a zone', () {
      expect(isLinkScopedHost('169.254.3.4'), isTrue);
      expect(isLinkScopedHost('fe80::1'), isTrue);
      expect(isLinkScopedHost('fe80::1%3'), isTrue);
      expect(isLinkScopedHost('fe80::1%usb0'), isTrue);
      expect(isLinkScopedHost('192.168.1.5'), isFalse);
      expect(isLinkScopedHost('10.0.0.2'), isFalse);
      expect(isLinkScopedHost('relay.example'), isFalse);
      expect(isLinkScopedHost('fd00::1'), isFalse);
    });
  });

  group('listLinkInterfaces', () {
    test(
      'collects 169.254 (the system listing hides it unless asked)',
      () async {
        final source = StrictInterfaceSource([
          raw('wlan0', 3, ['192.168.3.11']),
          raw('enp3s0', 7, ['169.254.20.5']),
        ]);
        final links = await listLinkInterfaces(source: source.call);
        expect(links.map((l) => l.name), ['wlan0', 'enp3s0']);
        expect(links.last.v4, ['169.254.20.5']);
        expect(links.last.kind, LinkKind.cable);
        expect(links.last.pingable, isTrue);
      },
    );

    test(
      'the strict source really does hide link-local unless asked',
      () async {
        final source = StrictInterfaceSource([
          raw('enp3s0', 7, ['169.254.20.5']),
        ]);
        expect(await source.call(includeLinkLocal: false), isEmpty);
        expect(await source.call(includeLinkLocal: true), hasLength(1));
      },
    );

    test(
      'tethering names and addresses are kept; virtual ones are not',
      () async {
        final source = StrictInterfaceSource([
          raw('rndis0', 9, ['192.168.42.129']),
          raw('docker0', 5, ['172.17.0.1']),
          raw('tun0', 6, ['10.8.0.2']),
          raw('rmnet_data0', 8, ['10.2.3.4']),
          raw('lo', 1, ['127.0.0.1']),
        ]);
        final links = await listLinkInterfaces(source: source.call);
        expect(links.map((l) => l.name), ['rndis0']);
        expect(links.single.pingable, isTrue);
      },
    );

    test('public and non-IPv4 addresses are not LAN addresses', () async {
      final source = StrictInterfaceSource([
        raw('eth0', 2, ['8.8.4.4', 'fe80::1', '192.168.1.9']),
        raw('eth1', 3, ['203.0.113.5']),
      ]);
      final links = await listLinkInterfaces(source: source.call);
      expect(links.single.name, 'eth0');
      expect(links.single.v4, ['192.168.1.9']);
    });

    test('a Wi-Fi link with a DHCP address is not pingable, one with only a '
        'link-local address is', () async {
      final source = StrictInterfaceSource([
        raw('wlan0', 3, ['192.168.3.11']),
        raw('wlan1', 4, ['169.254.8.8']),
      ]);
      final links = await listLinkInterfaces(source: source.call);
      expect(links.firstWhere((l) => l.name == 'wlan0').pingable, isFalse);
      expect(links.firstWhere((l) => l.name == 'wlan1').pingable, isTrue);
    });

    test('discoverLanAddresses keeps its old results: no link-local', () async {
      // The unchanged function still lists only what the system lists
      // without link-local; a machine's real interfaces must not break it.
      final addresses = await discoverLanAddresses();
      expect(addresses.where(isLinkScopedHost), isEmpty);
    });
  });
}
