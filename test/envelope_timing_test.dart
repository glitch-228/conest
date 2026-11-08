import 'package:conest/src/envelope_timing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stopwatch the test sets by hand.
class _Watch implements Stopwatch {
  _Watch(this._micros);

  final int _micros;
  bool _running = false;

  @override
  void start() => _running = true;
  @override
  void stop() => _running = false;
  @override
  void reset() {}
  @override
  bool get isRunning => _running;
  @override
  int get elapsedMicroseconds => _micros;
  @override
  int get elapsedMilliseconds => _micros ~/ 1000;
  @override
  int get elapsedTicks => _micros;
  @override
  Duration get elapsed => Duration(microseconds: _micros);
  @override
  int get frequency => 1000000;
}

void main() {
  /// Times the next envelopes by the microseconds in [micros], in order.
  EnvelopeKindTimings timings(List<int> micros, {int maxKinds = 48}) {
    final queue = List.of(micros);
    return EnvelopeKindTimings(
      maxKinds: maxKinds,
      stopwatch: () => _Watch(queue.removeAt(0)),
    );
  }

  test('each kind has its own count and its slowest envelope named', () {
    final t = timings([5000, 31000000, 7000, 2000]);
    final batch = t.slices();
    batch.next('direct_message');
    batch.next('group_history');
    batch.next('direct_message');
    batch.next('ack');
    batch.finish();
    final json = t.toJson();
    expect(json.keys.first, 'group_history', reason: 'slowest first');
    expect((json['group_history']! as Map)['maxMs'], 31000);
    expect((json['direct_message']! as Map)['count'], 2);
    expect((json['direct_message']! as Map)['maxMs'], 7);
    expect(t.slowestKind, 'group_history');
    expect(t.slowestMicros, 31000000);
  });

  test('a batch that ends early (finish twice, none started) adds nothing', () {
    final t = timings([1000]);
    t.slices().finish();
    final batch = t.slices();
    batch.finish();
    batch.next('ack');
    batch.finish();
    batch.finish();
    expect((t.toJson()['ack']! as Map)['count'], 1);
  });

  test('kinds a peer makes up are bounded, and long names cut', () {
    final t = timings(List.filled(10, 1000), maxKinds: 3);
    final batch = t.slices();
    for (var i = 0; i < 6; i++) {
      batch.next('kind-$i');
    }
    batch.next('x' * 500);
    batch.finish();
    final json = t.toJson(top: 100);
    expect(json.keys.toSet(), {'kind-0', 'kind-1', 'kind-2', 'other'});
    expect((json['other']! as Map)['count'], 4);
  });
}
