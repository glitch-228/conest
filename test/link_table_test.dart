import 'package:conest/src/net/link_table.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late LinkTable table;

  setUp(() {
    now = DateTime.utc(2026, 11, 6, 12);
    table = LinkTable(now: () => now);
  });

  LinkEntry? observe(
    String device,
    String address, {
    int ifIndex = 7,
    int relayPort = 7667,
  }) => table.observe(
    deviceId: device,
    ifIndex: ifIndex,
    ifName: 'enp3s0',
    address: address,
    relayPort: relayPort,
  );

  LinkEntry confirm(String device, String address, {int ifIndex = 7}) =>
      table.confirm(
        deviceId: device,
        ifIndex: ifIndex,
        ifName: 'enp3s0',
        address: address,
        relayPort: 7667,
      );

  group('unconfirmed entries', () {
    test('are listed apart and never as confirmed', () {
      observe('dev-a', '169.254.1.2');
      expect(table.confirmedFor('dev-a'), isEmpty);
      expect(table.unconfirmedFor('dev-a').single.address, '169.254.1.2');
    });

    test('expire after 60 s on the injected clock', () {
      observe('dev-a', '169.254.1.2');
      now = now.add(const Duration(seconds: 59));
      expect(table.unconfirmedFor('dev-a'), hasLength(1));
      now = now.add(const Duration(seconds: 2));
      expect(table.unconfirmedFor('dev-a'), isEmpty);
    });

    test('a repeated beacon keeps the entry alive and updates its port', () {
      observe('dev-a', '169.254.1.2');
      now = now.add(const Duration(seconds: 50));
      observe('dev-a', '169.254.1.2', relayPort: 7700);
      now = now.add(const Duration(seconds: 50));
      expect(table.unconfirmedFor('dev-a').single.relayPort, 7700);
    });

    test('at most two per device and link; the oldest goes', () {
      observe('dev-a', '169.254.1.1');
      now = now.add(const Duration(seconds: 1));
      observe('dev-a', '169.254.1.2');
      now = now.add(const Duration(seconds: 1));
      observe('dev-a', '169.254.1.3');
      expect(table.unconfirmedFor('dev-a').map((e) => e.address).toSet(), {
        '169.254.1.2',
        '169.254.1.3',
      });
    });

    test('one device id per source address: the first claim wins', () {
      expect(observe('dev-a', '169.254.1.2'), isNotNull);
      expect(observe('dev-b', '169.254.1.2'), isNull);
      expect(table.unconfirmedFor('dev-b'), isEmpty);
    });
  });

  group('confirmed entries', () {
    test('confirm makes an entry usable and pins it', () {
      observe('dev-a', '169.254.1.2');
      final entry = confirm('dev-a', '169.254.1.2');
      expect(entry.confirmed, isTrue);
      expect(table.confirmedFor('dev-a').single.address, '169.254.1.2');
      expect(table.unconfirmedFor('dev-a'), isEmpty);
    });

    test('a proven answer creates the entry if forged ones pushed it out', () {
      observe('dev-a', '169.254.1.2');
      observe('dev-a', '169.254.1.8');
      observe('dev-a', '169.254.1.9');
      expect(
        table.unconfirmedFor('dev-a').map((e) => e.address),
        isNot(contains('169.254.1.2')),
      );
      confirm('dev-a', '169.254.1.2');
      expect(table.confirmedFor('dev-a').single.address, '169.254.1.2');
    });

    test('forged beacons never push a confirmed entry out', () {
      observe('dev-a', '169.254.1.2');
      confirm('dev-a', '169.254.1.2');
      for (var i = 10; i < 60; i++) {
        observe('dev-a', '169.254.1.$i');
        now = now.add(const Duration(seconds: 1));
      }
      expect(table.confirmedFor('dev-a').single.address, '169.254.1.2');
    });

    test('forged beacons for other devices cannot fill a link and lock a '
        'real device out', () {
      for (var i = 0; i < 20; i++) {
        observe('dev-forged-$i', '169.254.2.$i');
      }
      // The real device still gets an entry (the oldest unconfirmed goes).
      expect(observe('dev-a', '169.254.9.9'), isNotNull);
      expect(table.entriesOnLink(7).length, lessThanOrEqualTo(8));
    });

    test('a confirmed address cannot be claimed by another device', () {
      observe('dev-a', '169.254.1.2');
      confirm('dev-a', '169.254.1.2');
      expect(observe('dev-b', '169.254.1.2'), isNull);
      expect(table.confirmedFor('dev-a'), hasLength(1));
    });

    test('at most two confirmed per device and link; a newer one replaces '
        'the oldest', () {
      confirm('dev-a', '169.254.1.1');
      now = now.add(const Duration(seconds: 1));
      confirm('dev-a', '169.254.1.2');
      now = now.add(const Duration(seconds: 1));
      confirm('dev-a', '169.254.1.3');
      expect(table.confirmedFor('dev-a').map((e) => e.address), [
        '169.254.1.3',
        '169.254.1.2',
      ]);
    });

    test('newest first by last sign of life; touch refreshes', () {
      confirm('dev-a', '169.254.1.1');
      now = now.add(const Duration(seconds: 5));
      confirm('dev-a', '169.254.1.2');
      now = now.add(const Duration(seconds: 5));
      table.touch('dev-a', '169.254.1.1');
      expect(
        table.confirmedFor('dev-a').map((e) => e.address).first,
        '169.254.1.1',
      );
    });

    test('a confirmed entry keeps its port when a beacon says another', () {
      observe('dev-a', '169.254.1.2');
      confirm('dev-a', '169.254.1.2');
      observe('dev-a', '169.254.1.2', relayPort: 9999);
      expect(table.confirmedFor('dev-a').single.relayPort, 7667);
    });

    test('a failing route is evicted', () {
      confirm('dev-a', '169.254.1.2');
      table.evict('dev-a', '169.254.1.2');
      expect(table.confirmedFor('dev-a'), isEmpty);
    });
  });

  group('links', () {
    test('at most 16 links and 8 entries on each', () {
      for (var link = 0; link < 20; link++) {
        observe('dev-$link', '169.254.$link.1', ifIndex: link + 1);
      }
      expect(table.linkCount, 16);
      for (var i = 0; i < 30; i++) {
        confirm('dev-x$i', '169.254.200.$i', ifIndex: 1);
      }
      expect(table.entriesOnLink(1).length, lessThanOrEqualTo(8));
    });

    test('dropMissingLinks removes the entries of a link that went', () {
      confirm('dev-a', '169.254.1.2', ifIndex: 7);
      confirm('dev-b', '192.168.42.2', ifIndex: 9);
      final removed = table.dropMissingLinks({9});
      expect(removed.map((e) => e.deviceId), ['dev-a']);
      expect(table.confirmedFor('dev-a'), isEmpty);
      expect(table.confirmedFor('dev-b'), hasLength(1));
    });

    test('routes: candidates are confirmed only, newest first, at most 3 '
        'entries with tcp and udp each', () {
      for (var i = 1; i <= 4; i++) {
        confirm('dev-a', '169.254.1.$i', ifIndex: i);
        now = now.add(const Duration(seconds: 1));
      }
      observe('dev-a', '169.254.7.7', ifIndex: 9);
      final routes = table.candidateRoutes('dev-a');
      expect(routes, hasLength(6));
      expect(routes.first.host, '169.254.1.4');
      expect(routes.map((r) => r.host), isNot(contains('169.254.7.7')));
      expect(routes.map((r) => r.routeKey).toSet(), hasLength(6));
    });

    test('replyRoutes include the unconfirmed ones', () {
      observe('dev-a', '169.254.1.2');
      confirm('dev-a', '169.254.1.3');
      expect(table.replyRoutes('dev-a').map((r) => r.host).toSet(), {
        '169.254.1.2',
        '169.254.1.3',
      });
    });

    test('clear empties everything', () {
      confirm('dev-a', '169.254.1.2');
      table.clear();
      expect(table.confirmedFor('dev-a'), isEmpty);
      expect(table.linkCount, 0);
    });
  });
}
