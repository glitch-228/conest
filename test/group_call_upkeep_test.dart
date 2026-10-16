import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/fake_call_network.dart';

void main() {
  test('members who stay out of a call get no call upkeep', () async {
    final net = FakeCallNetwork();
    for (var i = 0; i < 3; i++) {
      await net.add('p$i');
    }
    addTearDown(net.dispose);
    await net.connect(['p0', 'p1']);
    net.signals.clear();
    await net.advance(const Duration(seconds: 12));

    final toOutsider = net.signals
        .where((s) => s.$2 == 'p2')
        .map((s) => s.$3.action)
        .toSet();
    expect(toOutsider, isNot(contains('stats')));
    expect(toOutsider, isNot(contains('topology')));
    expect(toOutsider, isNot(contains('join')));
    // The call is still announced to them.
    expect(toOutsider, contains('start'));
    // Those in the call still keep each other up to date.
    final inCall = net.signals
        .where((s) => s.$2 == 'p1')
        .map((s) => s.$3.action)
        .toSet();
    expect(inCall, containsAll(['stats', 'join']));
  });

  test('closing the calls does not wait forever on a stuck one', () async {
    final net = FakeCallNetwork();
    addTearDown(net.dispose);
    final stuck = Completer<void>();
    // (Tear-downs run last first: this one frees the stuck save before the
    // network is disposed.)
    addTearDown(() {
      if (!stuck.isCompleted) stuck.complete();
    });
    // Saving the call's summary never finishes.
    final peer = await net.add('p0', onSummary: (_) => stuck.future);
    await net.add('p1');
    await net.connect(['p0', 'p1']);
    unawaited(peer.service.leave().catchError((Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final watch = Stopwatch()..start();
    await peer.service.dispose().timeout(const Duration(seconds: 9));
    expect(watch.elapsed, lessThan(const Duration(seconds: 9)));
  });
}
