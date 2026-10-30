import 'package:conest/src/transfer/block_sources.dart';
import 'package:flutter_test/flutter_test.dart';

const _block = 128 * 1024;
const _laptop = BlockSource.peer('laptop');
const _phone = BlockSource.peer('phone');
const _sender = BlockSource.peer('sender');

/// A source as the tests simulate it: blocks on it go one after another.
class _Path {
  _Path(this.secondsPerBlock);
  final double secondsPerBlock;
  DateTime busyUntil = DateTime.utc(2026);
}

/// Fetches [blocks] blocks from [paths] the way the controller does
/// (window per source, ask for the next block whenever there is room) and
/// returns how many came from each. [onDelivered] may change the set.
Map<BlockSource, int> _fetch(
  BlockSourceSet Function(DateTime Function() now) make, {
  required int blocks,
  required Map<BlockSource, _Path> paths,
  void Function(BlockSourceSet set, int delivered)? onDelivered,
  Set<int>? received,
}) {
  var now = DateTime.utc(2026);
  final set = make(() => now);
  final have = received ?? <int>{};
  final asked = <int>{};
  final pending = <(DateTime, int, BlockSource)>[];
  void topUp() {
    set.reconcile(asked);
    while (true) {
      int next = -1;
      for (var i = 0; i < blocks; i++) {
        if (!have.contains(i) && !asked.contains(i)) {
          next = i;
          break;
        }
      }
      if (next < 0) return;
      final source = set.choose(next);
      if (source == null) return;
      final path = paths[source]!;
      final start = path.busyUntil.isAfter(now) ? path.busyUntil : now;
      final done = start.add(
        Duration(microseconds: (path.secondsPerBlock * 1e6).round()),
      );
      path.busyUntil = done;
      asked.add(next);
      set.begin(next, source);
      pending.add((done, next, source));
    }
  }

  topUp();
  final counts = <BlockSource, int>{};
  while (have.length < blocks) {
    expect(pending, isNotEmpty, reason: 'the fetch stalled');
    pending.sort((a, b) => a.$1.compareTo(b.$1));
    final (at, index, source) = pending.removeAt(0);
    now = at;
    // A source taken out meanwhile: its blocks never come.
    if (!set.contains(source)) continue;
    if (have.contains(index)) continue;
    set.delivered(index, source);
    have.add(index);
    asked.remove(index);
    counts[source] = (counts[source] ?? 0) + 1;
    onDelivered?.call(set, have.length);
    // What a removed source had asked is asked again.
    asked.retainAll(
      pending.where((p) => set.contains(p.$3)).map((p) => p.$2).toSet(),
    );
    topUp();
  }
  return counts;
}

void main() {
  group('BlockSourceSet', () {
    test('two sources at different speeds share the blocks by speed', () {
      final counts = _fetch(
        (now) =>
            BlockSourceSet(primary: _sender, blockBytes: _block, now: now)
              ..add(_laptop),
        blocks: 200,
        paths: {_sender: _Path(0.5), _laptop: _Path(0.05)},
      );
      final fast = counts[_laptop] ?? 0;
      final slow = counts[_sender] ?? 0;
      expect(fast + slow, 200);
      // 10:1 in speed: the fast one carries the bulk, the slow one still
      // helps.
      expect(fast, greaterThan(slow * 5));
      expect(slow, greaterThan(0));
    });

    test('with room on both, the next block goes to the faster source, '
        'less as it fills up', () {
      var now = DateTime.utc(2026);
      final set = BlockSourceSet(
        primary: _sender,
        blockBytes: _block,
        now: () => now,
      )..add(_laptop);
      // Measured: the sender takes 1 s a block, the laptop 0.1 s.
      for (var i = 0; i < 3; i++) {
        set.begin(i, _sender);
        now = now.add(const Duration(seconds: 1));
        set.delivered(i, _sender);
        set.begin(10 + i, _laptop);
        now = now.add(const Duration(milliseconds: 100));
        set.delivered(10 + i, _laptop);
      }
      expect(set.choose(20), _laptop);
      set.begin(20, _laptop);
      // Shared with what is on it: a laptop with many blocks asked is
      // worth less than an idle sender.
      for (var i = 21; i < 28; i++) {
        set.begin(i, _laptop);
      }
      expect(set.choose(30), _sender);
    });

    test('a source that drops out mid-file loses nothing', () {
      final received = <int>{};
      final counts = _fetch(
        (now) =>
            BlockSourceSet(primary: _sender, blockBytes: _block, now: now)
              ..add(_laptop),
        blocks: 60,
        paths: {_sender: _Path(0.1), _laptop: _Path(0.1)},
        received: received,
        onDelivered: (set, delivered) {
          if (delivered == 20) set.remove(_laptop);
        },
      );
      expect(received.length, 60);
      expect(counts.values.fold(0, (a, b) => a + b), 60);
      // What the laptop had asked for was asked of the sender.
      expect(counts[_sender], greaterThan(30));
    });

    test('a source that serves a bad block is dropped, the block asked '
        'elsewhere, and it does not come back', () {
      var now = DateTime.utc(2026);
      final set = BlockSourceSet(
        primary: _sender,
        blockBytes: _block,
        now: () => now,
      )..add(_laptop);
      set.begin(0, _laptop);
      set.begin(1, _sender);
      set.begin(2, _laptop);
      final again = set.corrupt(0, _laptop);
      expect(set.contains(_laptop), isFalse);
      expect(set.wasDropped(_laptop), isTrue);
      expect(again, unorderedEquals([0, 2]));
      // The blocks are asked of the sender now.
      expect(set.choose(0), _sender);
      // Told again (a "have" from the same device) it is refused.
      expect(set.add(_laptop), isFalse);
      expect(set.sources, [_sender]);
      // Dropping releases what was asked of it.
      expect(set.inFlightOn(_laptop), 0);
    });

    test('the only source is kept after a bad block (asked again as '
        'before)', () {
      final set = BlockSourceSet(primary: _sender, blockBytes: _block)
        ..begin(3, _sender);
      expect(set.corrupt(3, _sender), isEmpty);
      expect(set.contains(_sender), isTrue);
      expect(set.wasDropped(_sender), isFalse);
      // It rests, so a source that is added now is preferred.
      set.add(_phone);
      expect(set.choose(3), _phone);
    });

    test('at most one window of blocks is asked of a source, and at '
        'most the allowed sources are taken', () {
      final set = BlockSourceSet(
        primary: _sender,
        blockBytes: _block,
        windowPerSource: 3,
        maxSources: 2,
      );
      expect(set.add(_laptop), isTrue);
      expect(set.add(_phone), isFalse, reason: 'only two sources');
      for (var i = 0; i < 6; i++) {
        final source = set.choose(i);
        expect(source, isNotNull, reason: 'block $i');
        set.begin(i, source!);
      }
      expect(set.inFlightOn(_sender), 3);
      expect(set.inFlightOn(_laptop), 3);
      expect(set.choose(6), isNull);
      // A source is asked for a block once at a time.
      final set2 = BlockSourceSet(primary: _sender, blockBytes: _block)
        ..begin(0, _sender);
      expect(set2.choose(0), isNull);
    });

    test('a source that failed rests: used again only when no other '
        'works, one block at a time', () {
      final set = BlockSourceSet(primary: _sender, blockBytes: _block)
        ..add(_laptop);
      set.begin(0, _sender);
      set.failed(0, _sender);
      for (var i = 1; i < 5; i++) {
        final source = set.choose(i)!;
        expect(source, _laptop);
        set.begin(i, source);
      }
      // The laptop goes too: the resting sender is tried, with one block.
      set.remove(_laptop);
      set.begin(10, set.choose(10)!);
      expect(set.choose(11), isNull, reason: 'one probe at a time');
    });

    test('nothing arriving in time rests every asked source and forgets '
        'the asks', () {
      final set = BlockSourceSet(primary: _sender, blockBytes: _block)
        ..add(_laptop);
      set.begin(0, _sender);
      set.begin(1, _laptop);
      set.timedOut();
      expect(set.hasRequests, isFalse);
      expect(set.striper.isResting(_sender), isTrue);
      expect(set.striper.isResting(_laptop), isTrue);
    });

    test('a block that is late is asked of a second source too, once, '
        'and the first to answer counts', () {
      var now = DateTime.utc(2026);
      final set = BlockSourceSet(
        primary: _sender,
        blockBytes: _block,
        now: () => now,
      )..add(_laptop);
      expect(set.nextHedgeIn(), isNull, reason: 'nothing asked');
      set.begin(0, _sender);
      final wait = set.nextHedgeIn()!;
      expect(wait, greaterThan(Duration.zero));
      expect(set.takeHedges(), isEmpty, reason: 'not late yet');
      now = now.add(wait);
      final hedges = set.takeHedges();
      expect(hedges, [(0, _laptop)]);
      expect(set.inFlightOn(_laptop), 1);
      // Asked twice already: not a third time, no more hedges for it.
      expect(set.takeHedges(), isEmpty);
      expect(set.nextHedgeIn(), isNull);
      // The laptop answers first; the sender's ask is cancelled without
      // blame.
      expect(set.delivered(0, _laptop), isTrue);
      expect(set.hasRequests, isFalse);
      expect(set.striper.isResting(_sender), isFalse);
      expect(set.deliveredBy(_laptop), 1);
    });

    test('one source cannot hedge, and hedging stays within its budget', () {
      var now = DateTime.utc(2026);
      final one = BlockSourceSet(
        primary: _sender,
        blockBytes: _block,
        now: () => now,
      )..begin(0, _sender);
      now = now.add(const Duration(minutes: 5));
      expect(one.takeHedges(), isEmpty);
      expect(one.nextHedgeIn(), isNull);

      // Both measured: a few blocks delivered, then many late at once.
      final two = BlockSourceSet(
        primary: _sender,
        blockBytes: _block,
        now: () => now,
        windowPerSource: 16,
      )..add(_laptop);
      for (var i = 0; i < 4; i++) {
        two.begin(i, _sender);
        two.begin(100 + i, _laptop);
        now = now.add(const Duration(milliseconds: 100));
        two.delivered(i, _sender);
        two.delivered(100 + i, _laptop);
      }
      for (var i = 10; i < 20; i++) {
        two.begin(i, _sender);
      }
      now = now.add(const Duration(minutes: 5));
      final hedges = two.takeHedges();
      expect(hedges.length, lessThanOrEqualTo(2), reason: 'two in flight');
      expect(hedges.length, lessThan(10));
    });

    test('blocks asked and then left out of the caller\'s set are '
        'forgotten without blame', () {
      final set = BlockSourceSet(primary: _sender, blockBytes: _block)
        ..begin(0, _sender)
        ..begin(1, _sender);
      set.reconcile({1});
      expect(set.inFlightOn(_sender), 1);
      expect(set.striper.isResting(_sender), isFalse);
      set.reconcile({});
      expect(set.hasRequests, isFalse);
    });

    test('a block that arrives unasked still counts for its source', () {
      final set = BlockSourceSet(primary: _sender, blockBytes: _block);
      expect(set.delivered(5, _sender), isFalse);
      expect(set.deliveredBy(_sender), 1);
      // From a source that rested after a stall: it works after all.
      set.begin(6, _sender);
      set.timedOut();
      expect(set.striper.isResting(_sender), isTrue);
      expect(set.delivered(6, _sender), isFalse);
      expect(set.striper.isResting(_sender), isFalse);
    });

    test('dropped sources are remembered within a bound', () {
      final set = BlockSourceSet(
        primary: _sender,
        blockBytes: _block,
        maxSources: 100000,
      );
      for (var i = 0; i < 500; i++) {
        final source = BlockSource.peer('d$i');
        set.add(source);
        set.drop(source);
      }
      expect(set.sources, [_sender]);
      // (Bounded: a hostile stream of devices does not grow it.)
      var refused = 0;
      for (var i = 0; i < 500; i++) {
        if (set.wasDropped(BlockSource.peer('d$i'))) refused++;
      }
      expect(refused, lessThanOrEqualTo(64));
    });
  });

  group('OwnDeviceFileIndex', () {
    test('is bounded in files and in devices per file', () {
      final index = OwnDeviceFileIndex(maxFiles: 3, maxDevicesPerFile: 2);
      expect(index.note('a', 'd1'), isTrue);
      expect(index.note('a', 'd1'), isFalse, reason: 'known');
      expect(index.note('a', 'd2'), isTrue);
      expect(index.note('a', 'd3'), isFalse, reason: 'two at most');
      expect(index.devicesWith('a'), {'d1', 'd2'});
      for (final id in ['b', 'c', 'd']) {
        index.note(id, 'd1');
      }
      expect(index.fileCount, 3);
      expect(index.devicesWith('a'), isEmpty, reason: 'the oldest went');
      index.forgetDevice('d1');
      expect(index.devicesWith('b'), isEmpty);
      index.note('b', 'd9');
      index.forgetFile('b');
      expect(index.devicesWith('b'), isEmpty);
    });
  });
}
