import 'package:conest/src/transfer/route_striper.dart';
import 'package:flutter_test/flutter_test.dart';

/// A simulated path: blocks on it go one after another at its speed.
class _Path {
  _Path(this.bytesPerSecond);
  final double bytesPerSecond;
  DateTime busyUntil = DateTime.utc(2026);
}

void main() {
  test('blocks are shared about as the two paths\' speeds are', () {
    var now = DateTime.utc(2026);
    final striper = RouteStriper<String>(now: () => now);
    final paths = {'lan': _Path(10e6), 'iroh': _Path(1e6)};
    const block = 1024 * 1024;
    const window = 8;
    final pending = <(DateTime, StripeLease<String>)>[];
    final sent = {'lan': 0, 'iroh': 0};
    var started = 0;
    while (started < 400 || pending.isNotEmpty) {
      while (pending.length < window && started < 400) {
        final route = striper.order(paths.keys).first;
        final path = paths[route]!;
        final start = path.busyUntil.isAfter(now) ? path.busyUntil : now;
        final done = start.add(
          Duration(microseconds: (block / path.bytesPerSecond * 1e6).round()),
        );
        path.busyUntil = done;
        pending.add((done, striper.begin(route, block)));
        sent[route] = sent[route]! + 1;
        started++;
      }
      pending.sort((a, b) => a.$1.compareTo(b.$1));
      final (at, lease) = pending.removeAt(0);
      now = at;
      striper.succeeded(lease);
    }
    final lanShare = sent['lan']! / 400;
    // 10 and 1 MB/s: about 91% and 9%.
    expect(lanShare, inInclusiveRange(0.82, 0.96));
    expect(sent['iroh'], greaterThan(0));
  });

  test('a route not measured yet gets one block to learn its speed', () {
    var now = DateTime.utc(2026);
    final striper = RouteStriper<String>(
      now: () => now,
      priorBytesPerSecond: {'lan': 10e6, 'iroh': 1e6},
    );
    final first = striper.begin(striper.order(['lan', 'iroh']).first, 1000);
    expect(first.route, 'lan');
    // LAN busy, Iroh never measured: Iroh gets the next block.
    final second = striper.begin(striper.order(['lan', 'iroh']).first, 1000);
    expect(second.route, 'iroh');
    now = now.add(const Duration(milliseconds: 1));
    striper.succeeded(second); // Iroh turns out fast: 1 MB/s → 1000 B/ms.
    expect(striper.speedOf('iroh'), closeTo(1e6, 1));
    // Both measured or busy: plain shares from here.
    expect(striper.order(['lan', 'iroh']).first, 'lan');
  });

  test('a failed route rests and the other takes the next blocks', () {
    var now = DateTime.utc(2026);
    final striper = RouteStriper<String>(
      now: () => now,
      priorBytesPerSecond: {'lan': 10e6, 'iroh': 1e6},
    );
    expect(striper.order(['lan', 'iroh']).first, 'lan');
    striper.failed(striper.begin('lan', 1000));
    expect(striper.order(['lan', 'iroh']).first, 'iroh');
    now = now.add(const Duration(seconds: 6));
    expect(striper.order(['lan', 'iroh']).first, 'lan');
    // Only one route left: it is used even while resting.
    striper.failed(striper.begin('lan', 1000));
    expect(striper.order(['lan']), ['lan']);
  });

  test('hedging waits for data, then stays within its budget', () {
    var now = DateTime.utc(2026);
    final striper = RouteStriper<String>(now: () => now);
    const block = 1000;
    expect(striper.mayHedge(block), isFalse);
    for (var i = 0; i < 100; i++) {
      final lease = striper.begin('lan', block);
      now = now.add(const Duration(milliseconds: 100));
      striper.succeeded(lease);
    }
    // 100 kB sent: 10% is 10 blocks' worth, two at a time.
    expect(striper.mayHedge(block), isTrue);
    final first = striper.begin('iroh', block, hedge: true);
    final second = striper.begin('iroh', block, hedge: true);
    expect(striper.mayHedge(block), isFalse);
    striper.succeeded(first);
    striper.failed(second);
    var hedges = 2;
    while (striper.mayHedge(block)) {
      striper.succeeded(striper.begin('iroh', block, hedge: true));
      hedges++;
    }
    expect(hedges * block, lessThanOrEqualTo((100 + hedges) * block * 0.1));
    // A late block waits at least 3 s, or twice its route's slow blocks.
    expect(striper.hedgeDelay('lan'), const Duration(seconds: 3));
  });

  test('an ended lease cannot be counted twice', () {
    final at = DateTime.utc(2026);
    final striper = RouteStriper<String>(
      now: () => at,
      priorBytesPerSecond: {'lan': 10e6, 'iroh': 1e6},
    );
    // No time passes: no speed sample, only the bookkeeping.
    final lease = striper.begin('lan', 10);
    striper.succeeded(lease);
    // A late failure report for the same block changes nothing: the route
    // does not rest, and it is not counted as in flight.
    striper.failed(lease);
    expect(striper.order(['iroh', 'lan']).first, 'lan');
  });

  test('a failing unmeasured route is not tried ahead of a working one, '
      'and rests longer each time', () {
    var now = DateTime.utc(2026);
    final striper = RouteStriper<String>(
      now: () => now,
      priorBytesPerSecond: {'lan': 10e6, 'iroh': 1e6},
    );
    // LAN is measured and idle; Iroh was never measured.
    final lan = striper.begin('lan', 1000);
    now = now.add(const Duration(microseconds: 100));
    striper.succeeded(lan);
    expect(striper.order(['iroh', 'lan']).first, 'lan');
    // LAN busy: Iroh is probed once, and fails.
    final busy = striper.begin('lan', 1000);
    expect(striper.order(['lan', 'iroh']).first, 'iroh');
    final probe = striper.begin('iroh', 1000);
    striper.failed(probe);
    expect(striper.order(['lan', 'iroh']).first, 'lan');
    expect(striper.unmeasured('iroh'), isTrue);
    // After the first rest it is probed again (LAN still busy) and fails
    // again: now it rests twice as long.
    now = now.add(const Duration(seconds: 6));
    expect(striper.order(['lan', 'iroh']).first, 'iroh');
    striper.failed(striper.begin('iroh', 1000));
    now = now.add(const Duration(seconds: 6));
    expect(striper.order(['lan', 'iroh']).first, 'lan');
    now = now.add(const Duration(seconds: 6));
    expect(striper.order(['lan', 'iroh']).first, 'iroh');
    striper.succeeded(busy);
    // With LAN idle, a dead unmeasured route never goes first.
    striper.failed(striper.begin('iroh', 1000));
    now = now.add(const Duration(minutes: 6));
    expect(striper.order(['lan', 'iroh']).first, 'lan');
  });

  test('a block on a route being probed may be hedged beyond the budget', () {
    final striper = RouteStriper<String>();
    expect(striper.mayHedge(1000), isFalse);
    expect(striper.mayHedge(1000, probing: true), isTrue);
  });
}
