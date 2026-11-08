import 'performance_samples.dart';

/// How long the app spends on each kind of incoming envelope, for the
/// release gate's report. The batch total (`envelopeHandling`) says that a
/// handler was slow; this says which one (device lab, build 312 onwards:
/// Linux batches of 4 to 35 s with a median of 16 ms).
///
/// One slice is the time from the start of an envelope's processing to the
/// start of the next one, so the awaits of its handler count and nothing
/// else does. At most [maxKinds] kinds are kept (a peer chooses the kind
/// string); the rest count as `other`.
class EnvelopeKindTimings {
  EnvelopeKindTimings({this.maxKinds = 48, Stopwatch Function()? stopwatch})
    : _stopwatch = stopwatch ?? Stopwatch.new;

  final int maxKinds;
  final Stopwatch Function() _stopwatch;
  final Map<String, DurationSamples> _byKind = {};

  /// The longest single envelope seen, with its kind.
  int slowestMicros = 0;
  String? slowestKind;

  /// Starts timing envelopes of one batch. Call [EnvelopeSlices.next] at the
  /// start of each envelope and [EnvelopeSlices.finish] after the last.
  EnvelopeSlices slices() => EnvelopeSlices._(this);

  void _add(String kind, int micros) {
    final name = kind.length > 40 ? kind.substring(0, 40) : kind;
    final key = _byKind.containsKey(name) || _byKind.length < maxKinds
        ? name
        : 'other';
    _byKind.putIfAbsent(key, () => DurationSamples(capacity: 256)).add(micros);
    if (micros > slowestMicros) {
      slowestMicros = micros;
      slowestKind = key;
    }
  }

  /// The kinds with the longest envelope first, at most [top].
  Map<String, Object> toJson({int top = 8}) {
    final kinds = _byKind.entries.toList()
      ..sort(
        (a, b) => b.value.percentileMs(1).compareTo(a.value.percentileMs(1)),
      );
    return {
      for (final entry in kinds.take(top)) entry.key: entry.value.toJson(),
    };
  }
}

/// The slices of one batch (see [EnvelopeKindTimings]).
class EnvelopeSlices {
  EnvelopeSlices._(this._timings);

  final EnvelopeKindTimings _timings;
  Stopwatch? _running;
  String? _kind;

  /// The previous envelope is done; [kind] begins.
  void next(String kind) {
    finish();
    _kind = kind;
    _running = _timings._stopwatch()..start();
  }

  /// The batch is done (also after an error).
  void finish() {
    final running = _running;
    final kind = _kind;
    if (running == null || kind == null) return;
    _timings._add(kind, running.elapsedMicroseconds);
    _running = null;
    _kind = null;
  }
}
