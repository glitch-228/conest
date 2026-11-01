/// Sends receipts (delivered and read acknowledgements) off the path that
/// processes incoming messages.
///
/// Sending a receipt on a carrier waits for its turn in the account's
/// limiter, up to tens of seconds. Incoming messages are processed one batch
/// at a time, so a receipt awaited by a message handler held every later
/// message behind it. The handler only records the obligation (it is
/// persisted with the vault); this queue sends it, one run per (contact,
/// conversation), at most [maxConcurrent] runs at once.
///
/// A run that takes longer than [stallAfter] (a contact whose routes are
/// dead) stops counting against [maxConcurrent], so it cannot hold up the
/// receipts of everyone else; [hardCap] still bounds all runs together. An
/// urgent run (the answer to a call signal) starts at once, whatever else is
/// running.
///
/// Receipts that pile up while a run waits for its turn are sent together
/// by that run's next pass, so a burst of N messages costs a few sends, not
/// N.
library;

import 'dart:async';

class ReceiptSendQueue {
  ReceiptSendQueue({
    this.maxConcurrent = 3,
    this.stallAfter = const Duration(seconds: 5),
    this.hardCap = 12,
  });

  /// Runs at once, at most. Each run is for one contact and conversation,
  /// so one slow carrier never holds the others.
  final int maxConcurrent;

  /// After this a run no longer counts against [maxConcurrent].
  final Duration stallAfter;

  /// Runs at once, stalled ones included (urgent ones may pass it).
  final int hardCap;

  final Map<String, Future<void> Function()> _waiting = {};
  final Set<String> _urgent = {};
  final Set<String> _running = {};
  final Set<String> _stalled = {};
  final Set<String> _again = {};
  final List<Completer<void>> _idleWaiters = [];
  bool _closed = false;

  int get runningCount => _running.length;
  int get waitingCount => _waiting.length;
  bool get isIdle => _running.isEmpty && _waiting.isEmpty;

  /// Asks for [run] to run for [key]. If a run for [key] is going already,
  /// it goes once more when that one is done (it may have read its work
  /// list before this was added). Errors of [run] are the caller's to
  /// handle inside it; any that escape are dropped.
  void schedule(
    String key,
    Future<void> Function() run, {
    bool urgent = false,
  }) {
    if (_closed) return;
    if (_running.contains(key)) {
      _again.add(key);
      if (urgent) _urgent.add(key);
      return;
    }
    _waiting[key] = run;
    if (urgent) _urgent.add(key);
    _pump();
  }

  /// Drops what waits and refuses more (the app is closing).
  void close() {
    _closed = true;
    _waiting.clear();
    _urgent.clear();
    _again.clear();
    _notifyIdle();
  }

  void _pump() {
    if (_closed) return;
    // Urgent runs first, past the limits (but not without bound).
    for (final key in _waiting.keys.where(_urgent.contains).toList()) {
      if (_running.length >= hardCap * 2) break;
      _start(key);
    }
    while (_running.length - _stalled.length < maxConcurrent &&
        _running.length < hardCap &&
        _waiting.isNotEmpty) {
      _start(_waiting.keys.first);
    }
  }

  void _start(String key) {
    final run = _waiting.remove(key)!;
    _urgent.remove(key);
    _running.add(key);
    unawaited(_go(key, run));
  }

  Future<void> _go(String key, Future<void> Function() run) async {
    final stall = Timer(stallAfter, () {
      if (_running.contains(key) && _stalled.add(key)) _pump();
    });
    try {
      await run();
    } catch (_) {
      // The obligation stays queued in the vault; the retry loop has it.
    } finally {
      stall.cancel();
      _running.remove(key);
      _stalled.remove(key);
      if (_again.remove(key) && !_closed) {
        _waiting[key] = run;
      }
      _pump();
      _notifyIdle();
    }
  }

  void _notifyIdle() {
    if (!isIdle) return;
    for (final waiter in _idleWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _idleWaiters.clear();
  }

  /// Completes when nothing runs or waits (tests).
  Future<void> whenIdle() {
    if (isIdle) return Future<void>.value();
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }
}
