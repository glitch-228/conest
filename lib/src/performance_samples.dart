import 'dart:ui' show FrameTiming;

/// The latest durations of something the app does (in microseconds), kept
/// to a fixed number, for the release gate's percentiles.
class DurationSamples {
  DurationSamples({this.capacity = 512});

  final int capacity;
  final List<int> _micros = <int>[];
  int _next = 0;
  int count = 0;

  void add(int micros) {
    count++;
    if (_micros.length < capacity) {
      _micros.add(micros);
    } else {
      _micros[_next] = micros;
      _next = (_next + 1) % capacity;
    }
  }

  /// The [fraction] percentile in milliseconds (0 when empty).
  double percentileMs(double fraction) {
    if (_micros.isEmpty) return 0;
    final sorted = List<int>.of(_micros)..sort();
    final index = ((sorted.length - 1) * fraction).round();
    return sorted[index] / 1000;
  }

  Map<String, Object> toJson() => {
    'count': count,
    'p50Ms': percentileMs(0.5),
    'p95Ms': percentileMs(0.95),
    'maxMs': percentileMs(1),
  };
}

/// Frame timings from the engine: how many frames, how many took longer
/// than a frame's time to build or to draw, and the slow end of each.
class FrameStats {
  FrameStats({this.budget = const Duration(microseconds: 16667)});

  /// A frame slower than this to build or to draw is slow.
  final Duration budget;
  final DurationSamples build = DurationSamples(capacity: 4096);
  final DurationSamples raster = DurationSamples(capacity: 4096);
  int frames = 0;
  int slow = 0;

  void addAll(List<FrameTiming> timings) {
    for (final timing in timings) {
      frames++;
      final b = timing.buildDuration;
      final r = timing.rasterDuration;
      build.add(b.inMicroseconds);
      raster.add(r.inMicroseconds);
      if (b > budget || r > budget) slow++;
    }
  }

  Map<String, Object> toJson() => {
    'frames': frames,
    'slow': slow,
    'slowShare': frames == 0 ? 0.0 : slow / frames,
    'buildP95Ms': build.percentileMs(0.95),
    'rasterP95Ms': raster.percentileMs(0.95),
  };
}
