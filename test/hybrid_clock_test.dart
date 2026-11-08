import 'package:conest/src/sync/hybrid_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a write takes the later of now and one past the last seen', () {
    final fresh = HybridClock.next(nowMilliseconds: 1000, deviceId: 'a');
    expect(fresh, const HybridClock(1000, 'a'));
    // This clock runs slow: the write still comes after what it saw.
    final slow = HybridClock.next(
      nowMilliseconds: 900,
      deviceId: 'a',
      lastSeen: const HybridClock(1000, 'b'),
    );
    expect(slow, const HybridClock(1001, 'a'));
    expect(slow.isAfter(const HybridClock(1000, 'b')), isTrue);
    // A clock that is ahead of what it saw just uses its own time.
    expect(
      HybridClock.next(
        nowMilliseconds: 5000,
        deviceId: 'a',
        lastSeen: const HybridClock(1000, 'b'),
      ).milliseconds,
      5000,
    );
  });

  test('the same millisecond goes to the higher device id', () {
    const a = HybridClock(1000, 'dev-a');
    const b = HybridClock(1000, 'dev-b');
    expect(b.isAfter(a), isTrue);
    expect(a.isAfter(b), isFalse);
    expect(a.isAfter(a), isFalse);
    // Time first, whatever the ids.
    expect(const HybridClock(1001, 'dev-a').isAfter(b), isTrue);
  });

  test('it is written and read back, and nothing else is a clock', () {
    const clock = HybridClock(1234567, 'dev-with|bar');
    expect(HybridClock.parse(clock.encode()), clock);
    for (final bad in [null, 5, '', 'x', '|dev', '12|', 'ab|dev', '-5|dev']) {
      expect(HybridClock.parse(bad), isNull, reason: '$bad');
    }
    expect(HybridClock.parse('1|${'d' * 300}'), isNull);
  });

  test('a clock from another device that is far ahead is refused, not cut', () {
    const now = 1000000;
    final ok = HybridClock.fromPeer(
      milliseconds: now + 4 * 60 * 1000,
      deviceId: 'dev-a',
      nowMilliseconds: now,
    );
    expect(ok, isNotNull);
    expect(
      HybridClock.fromPeer(
        milliseconds: now + 6 * 60 * 1000,
        deviceId: 'dev-a',
        nowMilliseconds: now,
      ),
      isNull,
    );
    expect(
      HybridClock.fromPeer(
        milliseconds: 'soon',
        deviceId: 'dev-a',
        nowMilliseconds: now,
      ),
      isNull,
    );
    expect(
      HybridClock.fromPeer(milliseconds: 5, deviceId: '', nowMilliseconds: now),
      isNull,
    );
  });
}
