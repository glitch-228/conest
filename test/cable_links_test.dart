import 'dart:convert';
import 'dart:typed_data';

import 'package:conest/src/models.dart';
import 'package:conest/src/net/cable_links.dart';
import 'package:conest/src/net/link_interfaces.dart';
import 'package:conest/src/net/link_table.dart';
import 'package:conest/src/net/link_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/strict_link_fakes.dart';

/// Our device `dev-me` on 169.254.10.1 and one neighbour on the same cable.
class Rig {
  Rig({List<String> known = const ['dev-peer']}) : knownDevices = {...known} {
    me = network.addHost('169.254.10.1');
    peer = network.addHost(
      '169.254.20.2',
      onListenerDatagram: (host, data, from, fromPort) {
        final message = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
        if (message['kind'] != 'pairing_ping') return;
        pingsSeenByPeer++;
        // What an old build does: the reply goes to the ping's own source
        // address and port, from a socket of its own.
        final reply = host.bind(host.address)
          ..send(
            utf8.encode(
              jsonEncode({
                'app': 'conest',
                'kind': 'pairing_route',
                'version': 2,
                'deviceId': 'dev-peer',
                'relayPort': 7667,
              }),
            ),
            from,
            fromPort,
          );
        reply.close();
      },
    );
    interfaces = StrictInterfaceSource([
      RawInterface(name: 'enp3s0', index: 7, addresses: ['169.254.10.1']),
    ]);
    links = CableLinks(
      now: () => now,
      interfaceSource: interfaces.call,
      pingSockets: (local) async {
        pingSocketsOpened++;
        return me.bind(local);
      },
      buildPing: () async => [
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'app': 'conest',
              'kind': 'pairing_ping',
              'version': 1,
              'deviceId': 'dev-me',
              'relayPort': 7667,
            }),
          ),
        ),
      ],
      enabled: () => enabled,
      isKnownDevice: knownDevices.contains,
      feedBeacon: (datagram, ifIndex) {
        beaconsFed++;
        final message =
            jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
        if (message['kind'] == 'pairing_route') {
          links.observeBeacon(
            deviceId: message['deviceId'] as String,
            address: datagram.address.address,
            relayPort: message['relayPort'] as int,
            ifIndex: ifIndex,
          );
        }
      },
      sendProbe: (entry, probeId) async {
        probes.add((entry.deviceId, entry.address, probeId));
        return probeAnswer;
      },
      newProbeId: () => 'probe-${probes.length + 1}',
      onConfirmed: confirmed.add,
      onDropped: dropped.addAll,
      networkChanged: () async => networkChanges++,
      log: logLines.add,
    );
  }

  final network = StrictBeaconNetwork();
  late final StrictHost me;
  late final StrictHost peer;
  late final StrictInterfaceSource interfaces;
  late final CableLinks links;
  final Set<String> knownDevices;
  DateTime now = DateTime.utc(2026, 11, 6, 12);
  int pingsSeenByPeer = 0;
  int pingSocketsOpened = 0;
  int beaconsFed = 0;
  int networkChanges = 0;
  bool probeAnswer = true;
  bool enabled = true;
  final probes = <(String, String, String)>[];
  final confirmed = <LinkEntry>[];
  final dropped = <LinkEntry>[];
  final logLines = <String>[];
}

void main() {
  late Rig rig;

  setUp(() => rig = Rig());

  /// Lets timers and the zero-delay microtasks of one change run.
  Future<void> settle(WidgetTester tester, [int ms = 600]) async {
    await tester.pump(Duration(milliseconds: ms));
    await tester.pump(const Duration(milliseconds: 10));
  }

  group('a link appears', () {
    testWidgets('a cable link is pinged from its own address and the reply, '
        'which goes to the ping socket and not to 7668, finds the contact', (
      tester,
    ) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      // The limited and the directed broadcast both arrive.
      expect(rig.pingsSeenByPeer, 2);
      // From our address on an ephemeral port, never from 7668.
      expect(
        rig.network.log.first,
        matches(RegExp(r'^169\.254\.10\.1:4\d{4} -> 255\.255\.255\.255:7668$')),
      );
      expect(rig.network.log, contains(matches(r'-> 169\.254\.255\.255:7668')));
      // The reply came back to that socket and made an unconfirmed entry.
      expect(rig.beaconsFed, 2);
      expect(
        rig.links.table.unconfirmedFor('dev-peer').single.address,
        '169.254.20.2',
      );
      expect(rig.links.table.unconfirmedFor('dev-peer').single.ifIndex, 7);
      // One probe was sent for it.
      expect(rig.probes.single.$1, 'dev-peer');
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('the ping socket listens for 5 s and is then closed', (
      tester,
    ) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.me.openSockets, 1);
      await tester.pump(const Duration(seconds: 4));
      expect(rig.me.openSockets, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(rig.me.openSockets, 0);
      rig.links.dispose();
    });

    testWidgets('a reply after the socket closed is not seen', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      final before = rig.beaconsFed;
      // The peer answers late, to the port the socket had.
      final late = rig.peer.bind(rig.peer.address)
        ..send([1], '169.254.10.1', 40001);
      late.close();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.beaconsFed, before);
      rig.links.dispose();
    });

    testWidgets('a link that is not a cable and has a DHCP address is not '
        'pinged; one with only a link-local address is', (tester) async {
      rig.interfaces.interfaces = [
        RawInterface(name: 'wlan0', index: 3, addresses: ['192.168.3.11']),
      ];
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.pingSocketsOpened, 0);
      rig.interfaces.interfaces = [
        RawInterface(name: 'wlan0', index: 3, addresses: ['169.254.10.1']),
      ];
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.pingSocketsOpened, 1);
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('the same addresses again are not pinged again; a new one is', (
      tester,
    ) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      expect(rig.pingSocketsOpened, 1);
      rig.interfaces.interfaces = [
        RawInterface(
          name: 'enp3s0',
          index: 7,
          addresses: ['169.254.10.1', '192.168.50.2'],
        ),
      ];
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      expect(rig.pingSocketsOpened, 2);
      rig.links.dispose();
    });

    testWidgets('a tethering link with a DHCP address is pinged on that '
        'address and its subnet broadcast', (tester) async {
      final tether = Rig();
      tether.interfaces.interfaces = [
        RawInterface(name: 'rndis0', index: 9, addresses: ['192.168.42.5']),
      ];
      // The host with that address (the phone is .129).
      final host = tether.network.addHost('192.168.42.5', segment: 'usb');
      tether.network.addHost('192.168.42.129', segment: 'usb');
      final captured = <String>[];
      final links = CableLinks(
        now: () => tether.now,
        interfaceSource: tether.interfaces.call,
        pingSockets: (local) async => host.bind(local),
        buildPing: () async => [
          Uint8List.fromList([1, 2, 3]),
        ],
        isKnownDevice: (_) => true,
        feedBeacon: (_, _) {},
        sendProbe: (_, _) async => true,
        newProbeId: () => 'p',
      );
      await links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      captured.addAll(tether.network.log);
      expect(captured, contains('192.168.42.5:40001 -> 192.168.42.255:7668'));
      await tester.pump(const Duration(seconds: 6));
      links.dispose();
      tether.links.dispose();
    });
  });

  group('who is believed', () {
    testWidgets('a device that is no contact or group member changes nothing: '
        'no entry, no probe, no listing', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      final listings = rig.interfaces.calls;
      final probes = rig.probes.length;
      expect(
        rig.links.observeBeacon(
          deviceId: 'dev-stranger',
          address: '10.99.99.9',
          relayPort: 7667,
        ),
        isFalse,
      );
      expect(
        rig.links.observeBeacon(
          deviceId: 'dev-stranger',
          address: '169.254.77.7',
          relayPort: 7667,
          ifIndex: 7,
        ),
        isFalse,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(
        rig.links.table.all.where((e) => e.deviceId == 'dev-stranger'),
        isEmpty,
      );
      expect(rig.probes.length, probes);
      expect(rig.interfaces.calls, listings);
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('a beacon on a Wi-Fi link with a DHCP address is left to '
        'the existing LAN route path; our own address is ignored', (
      tester,
    ) async {
      rig.interfaces.interfaces = [
        RawInterface(name: 'wlan0', index: 3, addresses: ['192.168.3.11']),
      ];
      await rig.links.onLinksChanged();
      expect(
        rig.links.observeBeacon(
          deviceId: 'dev-peer',
          address: '192.168.3.20',
          relayPort: 7667,
          ifIndex: 3,
        ),
        isFalse,
      );
      rig.interfaces.interfaces = [
        RawInterface(name: 'enp3s0', index: 7, addresses: ['169.254.10.1']),
      ];
      await rig.links.onLinksChanged();
      expect(
        rig.links.observeBeacon(
          deviceId: 'dev-peer',
          address: '169.254.10.1',
          relayPort: 7667,
          ifIndex: 7,
        ),
        isFalse,
      );
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('a beacon from an address on no listed link asks for one '
        'new listing, at most one in 10 s, and only for a known device', (
      tester,
    ) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      final before = rig.interfaces.calls;
      for (var i = 0; i < 20; i++) {
        rig.links.observeBeacon(
          deviceId: 'dev-peer',
          address: '172.20.10.$i',
          relayPort: 7667,
        );
      }
      await settle(tester);
      expect(rig.interfaces.calls, before + 1);
      // Another one a moment later, after the first listing is done: not
      // within 10 s.
      rig.links.observeBeacon(
        deviceId: 'dev-peer',
        address: '172.20.10.50',
        relayPort: 7667,
      );
      await settle(tester);
      expect(rig.interfaces.calls, before + 1);
      rig.now = rig.now.add(const Duration(seconds: 11));
      rig.links.observeBeacon(
        deviceId: 'dev-peer',
        address: '172.20.10.77',
        relayPort: 7667,
      );
      await settle(tester);
      expect(rig.interfaces.calls, before + 2);
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });
  });

  group('the probe', () {
    testWidgets('its authenticated answer confirms the entry; a wrong id or '
        'an unknown probe does not', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      final probeId = rig.probes.single.$3;
      expect(rig.links.onProbeReply('probe-other', 'dev-peer'), isFalse);
      expect(rig.links.onProbeReply(probeId, 'dev-someone-else'), isFalse);
      expect(rig.links.candidateRoutes('dev-peer'), isEmpty);
      expect(rig.links.onProbeReply(probeId, 'dev-peer'), isTrue);
      expect(rig.confirmed.single.address, '169.254.20.2');
      expect(rig.links.candidateRoutes('dev-peer').first.host, '169.254.20.2');
      // The same answer twice confirms nothing more.
      expect(rig.links.onProbeReply(probeId, 'dev-peer'), isFalse);
      expect(rig.confirmed, hasLength(1));
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('one probe per entry in 30 s, and at most 4 in flight', (
      tester,
    ) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.probes, hasLength(1));
      rig.links.observeBeacon(
        deviceId: 'dev-peer',
        address: '169.254.20.2',
        relayPort: 7667,
        ifIndex: 7,
      );
      expect(rig.probes, hasLength(1));
      rig.now = rig.now.add(const Duration(seconds: 31));
      rig.links.observeBeacon(
        deviceId: 'dev-peer',
        address: '169.254.20.2',
        relayPort: 7667,
        ifIndex: 7,
      );
      expect(rig.probes, hasLength(2));
      // Many forged entries: at most 4 probes wait for an answer at once.
      rig.probeAnswer = true;
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) {
        rig.knownDevices.add('dev-$id');
      }
      var forged = 0;
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) {
        rig.links.observeBeacon(
          deviceId: 'dev-$id',
          address: '169.254.30.${forged++}',
          relayPort: 7667,
          ifIndex: 7,
        );
      }
      expect(rig.links.probesInFlight, lessThanOrEqualTo(4));
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('a probe that could not be sent frees its place, an '
        'unanswered one does after 60 s', (tester) async {
      rig.probeAnswer = false;
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.links.probesInFlight, 0);
      rig.probeAnswer = true;
      rig.now = rig.now.add(const Duration(seconds: 31));
      rig.links.observeBeacon(
        deviceId: 'dev-peer',
        address: '169.254.20.2',
        relayPort: 7667,
        ifIndex: 7,
      );
      expect(rig.links.probesInFlight, 1);
      rig.now = rig.now.add(const Duration(seconds: 61));
      expect(rig.links.probesInFlight, 0);
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('an unconfirmed entry is no candidate route, a hint or a '
        'fresh host; a confirmed one is all three', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.links.candidateRoutes('dev-peer'), isEmpty);
      expect(rig.links.freshHostsFor('dev-peer'), isEmpty);
      rig.links.onProbeReply(rig.probes.single.$3, 'dev-peer');
      expect(rig.links.candidateRoutes('dev-peer'), isNotEmpty);
      expect(rig.links.freshHostsFor('dev-peer').single.host, '169.254.20.2');
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('a forged flood never pushes the confirmed entry out', (
      tester,
    ) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      rig.links.onProbeReply(rig.probes.single.$3, 'dev-peer');
      for (var i = 0; i < 80; i++) {
        rig.links.observeBeacon(
          deviceId: 'dev-peer',
          address: '169.254.99.$i',
          relayPort: 7667,
          ifIndex: 7,
        );
        rig.now = rig.now.add(const Duration(seconds: 1));
      }
      expect(
        rig.links.table.confirmedFor('dev-peer').single.address,
        '169.254.20.2',
      );
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });

    testWidgets('fresh hosts need a sign of life in the last 10 minutes, '
        'from a beacon, a delivery or a healthy route', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      rig.links.onProbeReply(rig.probes.single.$3, 'dev-peer');
      rig.now = rig.now.add(const Duration(minutes: 11));
      expect(rig.links.freshHostsFor('dev-peer'), isEmpty);
      // The route answered a health check a minute ago.
      expect(
        rig.links
            .freshHostsFor(
              'dev-peer',
              healthyAt: (route) =>
                  rig.now.subtract(const Duration(minutes: 1)),
            )
            .single
            .host,
        '169.254.20.2',
      );
      rig.links.touch('dev-peer', '169.254.20.2');
      expect(rig.links.freshHostsFor('dev-peer'), hasLength(1));
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });
  });

  group('a link goes', () {
    testWidgets('its entries go, the owner hears of them, and Iroh is told '
        'the network changed', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      rig.links.onProbeReply(rig.probes.single.$3, 'dev-peer');
      await tester.pump(const Duration(seconds: 6));
      rig.interfaces.interfaces = [];
      await rig.links.onLinksChanged();
      expect(rig.links.candidateRoutes('dev-peer'), isEmpty);
      expect(rig.dropped.map((e) => e.deviceId), ['dev-peer']);
      expect(rig.networkChanges, 1);
      // Nothing is told when nothing vanished.
      await rig.links.onLinksChanged();
      expect(rig.networkChanges, 1);
      rig.links.dispose();
    });

    testWidgets('one cable of two goes: only its entries', (tester) async {
      rig.interfaces.interfaces = [
        RawInterface(name: 'enp3s0', index: 7, addresses: ['169.254.10.1']),
        RawInterface(name: 'usb0', index: 9, addresses: ['169.254.10.1']),
      ];
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      rig.links.table.confirm(
        deviceId: 'dev-peer',
        ifIndex: 7,
        ifName: 'enp3s0',
        address: '169.254.20.2',
        relayPort: 7667,
      );
      rig.links.table.confirm(
        deviceId: 'dev-peer',
        ifIndex: 9,
        ifName: 'usb0',
        address: '192.168.42.129',
        relayPort: 7667,
      );
      rig.interfaces.interfaces = [
        RawInterface(name: 'usb0', index: 9, addresses: ['169.254.10.1']),
      ];
      await rig.links.onLinksChanged();
      expect(rig.links.table.confirmedFor('dev-peer').single.ifIndex, 9);
      expect(rig.dropped.single.ifIndex, 7);
      rig.links.dispose();
    });
  });

  group('first contact', () {
    testWidgets('pingNow pings the cable links already there, at most once '
        'in 10 s', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      final opened = rig.pingSocketsOpened;
      await rig.links.pingNow();
      await tester.pump(const Duration(seconds: 6));
      expect(rig.pingSocketsOpened, opened + 1);
      await rig.links.pingNow();
      await tester.pump(const Duration(seconds: 6));
      expect(rig.pingSocketsOpened, opened + 1);
      rig.now = rig.now.add(const Duration(seconds: 11));
      await rig.links.pingNow();
      await tester.pump(const Duration(seconds: 6));
      expect(rig.pingSocketsOpened, opened + 2);
      rig.links.dispose();
    });
  });

  group('dispose and reset', () {
    testWidgets('dispose closes ping sockets and leaves no timer; stray '
        'datagrams and events afterwards do nothing', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.me.openSockets, 1);
      rig.links.dispose();
      expect(rig.me.openSockets, 0);
      rig.links.note(LinkEventSource.monitor);
      expect(
        rig.links.observeBeacon(
          deviceId: 'dev-peer',
          address: '169.254.20.2',
          relayPort: 7667,
          ifIndex: 7,
        ),
        isFalse,
      );
      await tester.pump(const Duration(seconds: 2));
      // No pending timer is left, or the framework fails this test.
    });

    testWidgets('reset forgets entries, probes and ports but keeps working', (
      tester,
    ) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      rig.links.onProbeReply(rig.probes.single.$3, 'dev-peer');
      rig.links.notePorts('dev-peer', {'iroh4': 4000});
      await tester.pump(const Duration(seconds: 6));
      rig.links.reset();
      expect(rig.links.candidateRoutes('dev-peer'), isEmpty);
      expect(rig.links.hints.portsFor('dev-peer'), isNull);
      expect(rig.links.probesInFlight, 0);
      rig.links.dispose();
    });
  });

  group('switched off', () {
    testWidgets('nothing is listed, pinged, noted or probed while the '
        'setting is off', (tester) async {
      // The link is known (the setting was on), then it is switched off.
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      rig.probes.clear();
      final listings = rig.interfaces.calls;
      final opened = rig.pingSocketsOpened;
      rig.enabled = false;
      await rig.links.onLinksChanged();
      await rig.links.pingNow();
      await tester.pump(const Duration(seconds: 1));
      expect(rig.interfaces.calls, listings);
      expect(rig.pingSocketsOpened, opened);
      expect(
        rig.links.observeBeacon(
          deviceId: 'dev-peer',
          address: '169.254.20.77',
          relayPort: 7667,
          ifIndex: 7,
        ),
        isFalse,
      );
      expect(rig.probes, isEmpty);
      rig.links.dispose();
    });
  });

  group('a route that keeps failing', () {
    PeerEndpoint route(String host) =>
        PeerEndpoint(kind: PeerRouteKind.lan, host: host, port: 7667);

    Future<void> confirmPeer(WidgetTester tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      rig.links.onProbeReply(rig.probes.first.$3, 'dev-peer');
      await tester.pump(const Duration(seconds: 6));
    }

    testWidgets('is evicted after three failures in a row, and the link is '
        'looked at again', (tester) async {
      await confirmPeer(tester);
      final opened = rig.pingSocketsOpened;
      rig.links.noteRouteOutcome(route('169.254.20.2'), false);
      rig.links.noteRouteOutcome(route('169.254.20.2'), false);
      expect(rig.links.candidateRoutes('dev-peer'), isNotEmpty);
      rig.links.noteRouteOutcome(route('169.254.20.2'), false);
      expect(rig.links.candidateRoutes('dev-peer'), isEmpty);
      expect(rig.dropped.map((e) => e.address), ['169.254.20.2']);
      await tester.pump(const Duration(seconds: 6));
      expect(rig.pingSocketsOpened, opened + 1);
      rig.links.dispose();
    });

    testWidgets('a success in between starts the count again; other routes '
        'are none of its business', (tester) async {
      await confirmPeer(tester);
      rig.links.noteRouteOutcome(route('169.254.20.2'), false);
      rig.links.noteRouteOutcome(route('169.254.20.2'), false);
      rig.links.noteRouteOutcome(route('169.254.20.2'), true);
      rig.links.noteRouteOutcome(route('169.254.20.2'), false);
      rig.links.noteRouteOutcome(route('169.254.20.2'), false);
      for (var i = 0; i < 10; i++) {
        rig.links.noteRouteOutcome(route('192.168.1.9'), false);
      }
      expect(rig.links.candidateRoutes('dev-peer'), isNotEmpty);
      expect(rig.dropped, isEmpty);
      rig.links.dispose();
    });
  });

  group('Iroh hints', () {
    testWidgets('a confirmed cable host and a healthy LAN host come first, '
        'with the ports the contact told us', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(milliseconds: 50));
      rig.links.onProbeReply(rig.probes.first.$3, 'dev-peer');
      await tester.pump(const Duration(seconds: 6));
      rig.links.notePorts('dev-peer', {'iroh4': 41000, 'junk': 1});
      PeerRouteHealth health(PeerEndpoint route, {required bool ok}) =>
          PeerRouteHealth(
            route: route,
            available: ok,
            latency: null,
            checkedAt: rig.now.subtract(const Duration(minutes: 1)),
          );
      final lanOk = PeerEndpoint(
        kind: PeerRouteKind.lan,
        host: '192.168.7.7',
        port: 7667,
      );
      final lanDown = PeerEndpoint(
        kind: PeerRouteKind.lan,
        host: '192.168.7.8',
        port: 7667,
      );
      final hints = rig.links.irohHints(
        deviceId: 'dev-peer',
        stored: [
          PeerEndpoint(
            kind: PeerRouteKind.directInternet,
            host: '203.0.113.9',
            port: 5000,
            protocol: PeerRouteProtocol.udp,
          ),
        ],
        lanHints: [lanOk, lanDown],
        healthOf: (route) => route.host == '192.168.7.7'
            ? health(route, ok: true)
            : health(route, ok: false),
      );
      expect(hints.last, '203.0.113.9:5000');
      expect(hints.take(2).toSet(), {
        '169.254.20.2:41000',
        '192.168.7.7:41000',
      });
      expect(hints, hasLength(3));
      rig.links.dispose();
    });

    testWidgets('a LAN host not checked in the last 10 minutes is not fresh', (
      tester,
    ) async {
      rig.links.notePorts('dev-peer', {'iroh4': 41000});
      final hints = rig.links.irohHints(
        deviceId: 'dev-peer',
        stored: const [],
        lanHints: [
          PeerEndpoint(
            kind: PeerRouteKind.lan,
            host: '192.168.7.7',
            port: 7667,
          ),
        ],
        healthOf: (route) => PeerRouteHealth(
          route: route,
          available: true,
          latency: null,
          checkedAt: rig.now.subtract(const Duration(minutes: 11)),
        ),
      );
      expect(hints, isEmpty);
      rig.links.dispose();
    });
  });

  group('own addresses', () {
    testWidgets('are those of the listed links, and a request to list again '
        'is limited', (tester) async {
      await rig.links.onLinksChanged();
      await tester.pump(const Duration(seconds: 6));
      expect(rig.links.ownsAddress('169.254.10.1'), isTrue);
      expect(rig.links.ownsAddress('169.254.20.2'), isFalse);
      expect(rig.links.ownsAddress('not an address'), isFalse);
      final before = rig.interfaces.calls;
      rig.links.requestRelist();
      rig.links.requestRelist();
      await tester.pump(const Duration(seconds: 1));
      expect(rig.interfaces.calls, before + 1);
      rig.interfaces.interfaces = [
        RawInterface(name: 'enp3s0', index: 7, addresses: ['169.254.10.9']),
      ];
      rig.now = rig.now.add(const Duration(seconds: 11));
      rig.links.requestRelist();
      await tester.pump(const Duration(seconds: 1));
      expect(rig.links.ownsAddress('169.254.10.9'), isTrue);
      expect(rig.links.ownsAddress('169.254.10.1'), isFalse);
      await tester.pump(const Duration(seconds: 6));
      rig.links.dispose();
    });
  });
}
