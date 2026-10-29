import 'package:conest/src/transfer/gateway_election.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const near = RouteScore(heardAgo: Duration(minutes: 1), direct: true);
  const far = RouteScore(heardAgo: Duration(minutes: 5));
  const gone = RouteScore();

  test('in reach beats not, a direct path beats a relayed one', () {
    expect(rankGateways('c', {'a': gone, 'b': far, 'c': near}), [
      'c',
      'b',
      'a',
    ]);
  });

  test('then quicker, mains, desktop, unmetered', () {
    const slow = RouteScore(heardAgo: Duration(minutes: 1), rttMs: 400);
    const quick = RouteScore(heardAgo: Duration(minutes: 1), rttMs: 40);
    expect(rankGateways('t', {'a': slow, 'b': quick}).first, 'b');
    const plain = RouteScore(heardAgo: Duration(minutes: 1));
    const mains = RouteScore(heardAgo: Duration(minutes: 1), mains: true);
    expect(rankGateways('t', {'a': plain, 'b': mains}).first, 'b');
    const metered = RouteScore(heardAgo: Duration(minutes: 1), metered: true);
    expect(rankGateways('t', {'a': metered, 'b': plain}).first, 'b');
  });

  test('every device ranks the same, and ties spread over targets', () {
    final scores = {'a': far, 'b': far, 'c': far};
    expect(rankGateways('x', scores), rankGateways('x', {...scores}));
    final firsts = {
      for (var i = 0; i < 40; i++) rankGateways('target$i', scores).first,
    };
    expect(firsts.length, greaterThan(1));
  });

  test('the gateway does not flap between equals but yields to reach', () {
    final scores = {'a': far, 'b': far};
    final best = rankGateways('t', scores).first;
    final other = best == 'a' ? 'b' : 'a';
    expect(electGateway('t', scores, current: other), other);
    expect(electGateway('t', {...scores, other: gone}, current: other), best);
    expect(electGateway('t', {}, current: 'a'), isNull);
  });

  test('the pass-on wait grows with the place, to a cap', () {
    const ranked = ['a', 'b', 'c', 'd'];
    expect(passOnDelay('a', ranked), Duration.zero);
    expect(passOnDelay('c', ranked), const Duration(seconds: 4));
    expect(passOnDelay('z', ranked), const Duration(seconds: 8));
    expect(
      passOnDelay('d', ranked, step: const Duration(seconds: 10)),
      const Duration(seconds: 15),
    );
  });

  test('a score read from another device is bounded', () {
    final s = RouteScore.fromJson({'heard': -5, 'rtt': 99999999, 'direct': 1});
    expect(s.heardAgo, isNull);
    expect(s.rttMs, isNull);
    expect(s.direct, isFalse);
    expect(RouteScore.fromJson(near.toJson()).inReach, isTrue);
    expect(RouteScore.fromJson('x').inReach, isFalse);
  });
}
