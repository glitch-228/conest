import 'dart:async';

import 'package:conest/src/matrix_carrier.dart';
import 'package:conest/src/matrix_client.dart';

/// A clock the test moves by hand; timers fire as it passes them.
class StepClock {
  DateTime now = DateTime.utc(2026, 11, 4, 19);
  final List<_StepTimer> _timers = [];

  Timer timer(Duration after, void Function() callback) {
    final timer = _StepTimer(now.add(after), callback);
    _timers.add(timer);
    return timer;
  }

  Future<void> advance(Duration by) async {
    final end = now.add(by);
    while (true) {
      final due =
          _timers.where((t) => t.isActive && !t.at.isAfter(end)).toList()
            ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final next = due.first;
      if (next.at.isAfter(now)) now = next.at;
      next.fire();
      _timers.remove(next);
      await _settle();
    }
    now = end;
    await _settle();
  }

  Future<void> _settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

class _StepTimer implements Timer {
  _StepTimer(this.at, this._callback);

  final DateTime at;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// A homeserver for the Matrix carrier that is as strict as the real one
/// where the carrier depends on it:
/// - it stores every to-device frame for the target device until that
///   device syncs (store and forward), in arrival order, with the time it
///   came;
/// - it can limit the account's sends the way a server with a rate limit
///   does (a token bucket; over it, `M_LIMIT_EXCEEDED` with a
///   `retry_after`), and never takes a frame it refused;
/// - a repeated transaction id is a retry, not a second frame.
///
/// Synapse itself (checked in its source, November 2026) applies no rate
/// limit to to-device messages of its own types, so by default there is
/// none ([perSecond] null).
class StrictMatrixServer implements MatrixCarrierChannel {
  StrictMatrixServer(this._clock, {this.perSecond, this.burst = 10});

  final StepClock _clock;

  /// Frames per second one account may send; null: no limit.
  final double? perSecond;
  final int burst;

  double _tokens = 0;
  DateTime? _refilledAt;
  final Set<String> _transactions = {};

  /// Every frame the server took: when, for whom.
  final List<({DateTime at, MatrixAddress to})> stored = [];

  /// How many sends it refused with a rate limit.
  int refusals = 0;

  /// Sends that came before the wait a refusal named was over.
  int earlyRetries = 0;
  DateTime? _notBefore;
  DateTime? _refusedAt;

  @override
  Future<void> sendFrame(
    MatrixAddress to,
    Map<String, Object?> frame,
    String transactionId,
  ) async {
    final limit = perSecond;
    if (limit != null) {
      final now = _clock.now;
      // Sends released in the same instant as the refusal were on their way
      // already; after that instant the wait has to be kept.
      if (_notBefore case final until?
          when now.isBefore(until) && now.isAfter(_refusedAt!)) {
        earlyRetries++;
      }
      final last = _refilledAt;
      _tokens = last == null
          ? burst.toDouble()
          : (_tokens + now.difference(last).inMicroseconds / 1e6 * limit).clamp(
              0,
              burst.toDouble(),
            );
      _refilledAt = now;
      if (_tokens < 1) {
        refusals++;
        final wait = Duration(
          milliseconds: ((1 - _tokens) / limit * 1000).ceil(),
        );
        _refusedAt = now;
        _notBefore = now.add(wait);
        throw MatrixException(
          'Too many requests',
          status: 429,
          errcode: 'M_LIMIT_EXCEEDED',
          retryAfter: wait,
        );
      }
      _tokens -= 1;
    }
    if (_transactions.add(transactionId)) {
      stored.add((at: _clock.now, to: to));
    }
  }
}
