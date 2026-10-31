import 'dart:ui' show FrameTiming;

import 'package:conest/src/performance_samples.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming frame({required int buildMicros, required int rasterMicros}) =>
    FrameTiming(
      vsyncStart: 0,
      buildStart: 1000,
      buildFinish: 1000 + buildMicros,
      rasterStart: 1000 + buildMicros,
      rasterFinish: 1000 + buildMicros + rasterMicros,
      rasterFinishWallTime: 1000 + buildMicros + rasterMicros,
    );

void main() {
  test('a frame slower than its time to build or to draw counts as slow', () {
    final stats = FrameStats()
      ..addAll([
        for (var i = 0; i < 97; i++)
          frame(buildMicros: 4000, rasterMicros: 5000),
        frame(buildMicros: 20000, rasterMicros: 5000),
        frame(buildMicros: 4000, rasterMicros: 30000),
        frame(buildMicros: 16000, rasterMicros: 16000),
      ]);
    final json = stats.toJson();
    expect(json['frames'], 100);
    expect(json['slow'], 2);
    expect(json['slowShare'], 0.02);
    expect(json['buildP95Ms'], 4.0);
  });

  test('samples keep the latest ones, and percentiles come from them', () {
    final samples = DurationSamples(capacity: 4);
    for (final micros in [100000, 1000, 2000, 3000, 4000]) {
      samples.add(micros);
    }
    // The first (100 ms) fell out: the slowest kept is 4 ms.
    expect(samples.count, 5);
    expect(samples.percentileMs(1), 4.0);
    expect(samples.percentileMs(0.5), 3.0);
    expect(DurationSamples().percentileMs(0.95), 0);
  });
}
