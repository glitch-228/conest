import 'package:conest/src/ui/read_sweep.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rebuilds cannot put a pending sweep off', (tester) async {
    final sweep = ReadSweepTimer();
    var runs = 0;
    sweep.schedule(() => runs++);
    // A rebuild every 100 ms, for longer than the delay.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      sweep.schedule(() => runs++);
    }
    expect(runs, greaterThanOrEqualTo(1));
    sweep.cancel();
  });

  testWidgets('scrolling pushes the sweep out, but only a few times', (
    tester,
  ) async {
    final sweep = ReadSweepTimer(maxRestarts: 3);
    var runs = 0;
    sweep.schedule(() => runs++);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      sweep.schedule(() => runs++, restart: true);
    }
    expect(runs, 0, reason: 'each scroll pushed it out');
    await tester.pump(const Duration(milliseconds: 500));
    sweep.schedule(() => runs++, restart: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(runs, 1, reason: 'the fourth scroll may not push it further');
    sweep.cancel();
  });
}
