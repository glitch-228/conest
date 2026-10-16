import 'dart:convert';

import 'package:conest/src/models.dart';
import 'package:conest/src/network_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 16, 12);

  NetworkRecord home(NetworkHistory history, DateTime at) => history.enter(
    kind: 'wifi',
    lanSubnets: const ['192.168.3'],
    vpn: false,
    cost: NetworkCostClass.unmetered,
    now: at,
  );

  test('the same network is recognised again', () {
    final history = NetworkHistory();
    final first = home(history, t0);
    history.enter(
      kind: 'mobile',
      lanSubnets: const [],
      vpn: false,
      cost: NetworkCostClass.metered,
      now: t0.add(const Duration(hours: 1)),
    );
    final again = home(history, t0.add(const Duration(hours: 2)));
    expect(again.id, first.id);
    expect(again.seenCount, 2);
    expect(again.label, 'Wi-Fi 192.168.3.x');
    expect(history.networks, hasLength(2));
  });

  test('a route a network keeps cutting is blocked there, not elsewhere', () {
    final history = NetworkHistory();
    home(history, t0);
    history.worked('iroh', t0);
    for (var i = 0; i < 3; i++) {
      history.failed('nostr', RouteFailureKind.reset, t0);
    }
    // A peer away on the LAN times out the same way: never "blocked".
    for (var i = 0; i < 5; i++) {
      history.failed('lan', RouteFailureKind.timeout, t0);
    }
    // A relay that refuses (a server problem) is not the network's doing.
    for (var i = 0; i < 5; i++) {
      history.failed('relay:r.example:7667', RouteFailureKind.refused, t0);
    }
    expect(history.blockedHere(), {'nostr'});

    history.enter(
      kind: 'mobile',
      lanSubnets: const [],
      vpn: false,
      cost: NetworkCostClass.metered,
      now: t0,
    );
    expect(history.blockedHere(), isEmpty);

    // Working again lifts it.
    home(history, t0);
    history.worked('nostr', t0.add(const Duration(minutes: 1)));
    expect(history.blockedHere(), isEmpty);
  });

  test('nothing is blocked where nothing works at all', () {
    final history = NetworkHistory();
    home(history, t0);
    for (var i = 0; i < 4; i++) {
      history.failed('nostr', RouteFailureKind.dns, t0);
    }
    expect(history.blockedHere(), isEmpty);
  });

  test('history is bounded and forgets what was not seen for long', () {
    final history = NetworkHistory();
    for (var i = 0; i < NetworkHistory.maxNetworks + 10; i++) {
      history.enter(
        kind: 'wifi',
        lanSubnets: ['10.0.$i'],
        vpn: false,
        cost: NetworkCostClass.unmetered,
        now: t0.add(Duration(minutes: i)),
      );
    }
    expect(history.networks, hasLength(NetworkHistory.maxNetworks));
    // The newest are kept.
    expect(history.networks.first.label, contains('10.0.73'));

    home(history, t0.add(const Duration(days: 1)));
    for (var i = 0; i < NetworkHistory.maxRoutes + 5; i++) {
      history.worked('relay:r$i:7667', t0.add(Duration(days: 1, minutes: i)));
    }
    expect(history.current!.routes, hasLength(NetworkHistory.maxRoutes));

    history.enter(
      kind: 'mobile',
      lanSubnets: const [],
      vpn: false,
      cost: NetworkCostClass.metered,
      now: t0.add(const Duration(days: 40)),
    );
    expect(history.networks, hasLength(1));
  });

  test('it survives a restart', () {
    final history = NetworkHistory();
    home(history, t0);
    history.worked('iroh', t0);
    history.failed('tor', RouteFailureKind.tls, t0);
    final restored = NetworkHistory.fromJson(
      jsonDecode(jsonEncode(history.toJson())),
    );
    final record = restored.networks.single;
    expect(record.label, 'Wi-Fi 192.168.3.x');
    expect(record.routes['iroh']!.ok, 1);
    expect(record.routes['tor']!.failures[RouteFailureKind.tls], 1);
    expect(NetworkHistory.fromJson('nonsense').networks, isEmpty);
  });

  test('errors are sorted by what the network did', () {
    expect(
      routeFailureKindOf("Failed host lookup: 'relay.example'"),
      RouteFailureKind.dns,
    );
    expect(
      routeFailureKindOf('Connection reset by peer'),
      RouteFailureKind.reset,
    );
    expect(routeFailureKindOf('HandshakeException: …'), RouteFailureKind.tls);
    expect(routeFailureKindOf('Connection refused'), RouteFailureKind.refused);
    expect(
      routeFailureKindOf('Connection timed out'),
      RouteFailureKind.timeout,
    );
    expect(routeFailureKindOf('weird'), RouteFailureKind.other);
  });
}
