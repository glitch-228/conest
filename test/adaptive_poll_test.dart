import 'package:conest/src/adaptive_poll.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('polls quickly while traffic moves and slowly when idle', () {
    var now = DateTime.utc(2026, 11, 1, 12);
    final poll = AdaptivePoll(now: () => now);
    // Nothing yet: idle.
    expect(poll.next, const Duration(milliseconds: 250));
    poll.noteActivity();
    expect(poll.next, const Duration(milliseconds: 40));
    now = now.add(const Duration(seconds: 14));
    expect(poll.next, const Duration(milliseconds: 40));
    now = now.add(const Duration(seconds: 2));
    expect(poll.next, const Duration(milliseconds: 250));
    expect(poll.isActive, isFalse);
    // New traffic speeds it up again.
    poll.noteActivity();
    expect(poll.isActive, isTrue);
    expect(poll.next, const Duration(milliseconds: 40));
  });
}
