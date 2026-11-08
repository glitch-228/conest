import 'package:conest/src/models.dart';
import 'package:conest/src/stealth/hidden_routes.dart';
import 'package:flutter_test/flutter_test.dart';

PeerEndpoint _borrowed(String host, String site, {int port = 443}) =>
    PeerEndpoint(
      kind: PeerRouteKind.relay,
      host: host,
      port: port,
      protocol: PeerRouteProtocol.borrowed,
      path: site,
    );

PeerEndpoint _wss(String host, String path) => PeerEndpoint(
  kind: PeerRouteKind.relay,
  host: host,
  port: 443,
  protocol: PeerRouteProtocol.wss,
  path: path,
);

void main() {
  test(
    'a route key does not name the site, which is why a change needs this',
    () {
      expect(
        _borrowed('203.0.113.7', 'www.bing.com').routeKey,
        _borrowed('203.0.113.7', 'www.microsoft.com').routeKey,
      );
    },
  );

  test('a changed site replaces the relay\'s old one and nothing else', () {
    final old = _borrowed('203.0.113.7', 'www.bing.com');
    final announced = _borrowed('203.0.113.7', 'www.microsoft.com');
    final otherRelay = _borrowed('203.0.113.8', 'www.bing.com');
    final plain = PeerEndpoint(
      kind: PeerRouteKind.relay,
      host: '203.0.113.7',
      port: 443,
    );
    final replaced = replacedHiddenRoute(
      relays: [plain, otherRelay, old],
      announced: announced,
      identityKey: 'K1',
      pins: {old.routeKey: 'K1', otherRelay.routeKey: 'K1'},
    );
    expect(identical(replaced, old), isTrue);
  });

  test('a rotated secret path replaces the old path', () {
    final old = _wss('relay.example.org', '/old-secret-path');
    final announced = _wss('relay.example.org', '/new-secret-path');
    final replaced = replacedHiddenRoute(
      relays: [old],
      announced: announced,
      identityKey: 'K1',
      pins: {old.routeKey: 'K1'},
    );
    expect(identical(replaced, old), isTrue);
  });

  test('the same name, another relay\'s route, or no pin replaces nothing', () {
    final same = _borrowed('203.0.113.7', 'www.bing.com');
    expect(
      replacedHiddenRoute(
        relays: [same],
        announced: same,
        identityKey: 'K1',
        pins: {same.routeKey: 'K1'},
      ),
      isNull,
      reason: 'nothing changed',
    );
    final other = _borrowed('203.0.113.7', 'www.microsoft.com');
    expect(
      replacedHiddenRoute(
        relays: [other],
        announced: same,
        identityKey: 'K1',
        pins: {other.routeKey: 'K2'},
      ),
      isNull,
      reason: 'pinned to another identity: another relay\'s',
    );
    expect(
      replacedHiddenRoute(
        relays: [other],
        announced: same,
        identityKey: 'K1',
        pins: const {},
      ),
      isNull,
      reason: 'nobody pinned it to this relay',
    );
    final wss = _wss('203.0.113.7', '/some-secret-path');
    expect(
      replacedHiddenRoute(
        relays: [wss],
        announced: same,
        identityKey: 'K1',
        pins: {wss.routeKey: 'K1'},
      ),
      isNull,
      reason: 'another kind of route',
    );
  });
}
