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
/// Receipts that pile up while a run waits for its turn are sent together
/// by that run's next pass, so a burst of N messages costs a few sends, not
/// N.
library;

import 'dart:async';

class ReceiptSendQueue {
  ReceiptSendQueue({this.maxConcurrent = 3});

  /// Runs at once, at most. Each run is for one contact and conversation,
  /// so one slow carrier never holds the others.
  final int maxConcurrent;

  final Map<String, Future<void> Function()> _waiting = {};
  final Set<String> _running = {};
  final Set<String> _again = {};
  final List<Completer<void>> _idleWaiters = [];

  int get runningCount => _running.length;
  int get waitingCount => _waiting.length;
  bool get isIdle => _running.isEmpty && _waiting.isEmpty;

  /// Asks for [run] to run for [key]. If a run for [key] is going already,
  /// it goes once more when that one is done (it may have read its work
  /// list before this was added). Errors of [run] are the caller's to
  /// handle inside it; any that escape are dropped.
  void schedule(String key, Future<void> Function() run) {
    if (_running.contains(key)) {
      _again.add(key);
      return;
    }
    _waiting[key] = run;
    _pump();
  }

  void _pump() {
    while (_running.length < maxConcurrent && _waiting.isNotEmpty) {
      final key = _waiting.keys.first;
      final run = _waiting.remove(key)!;
      _running.add(key);
      unawaited(_go(key, run));
    }
  }

  Future<void> _go(String key, Future<void> Function() run) async {
    try {
      await run();
    } catch (_) {
      // The obligation stays queued in the vault; the retry loop has it.
    } finally {
      _running.remove(key);
      if (_again.remove(key)) _waiting[key] = run;
      _pump();
      if (isIdle) {
        for (final waiter in _idleWaiters) {
          if (!waiter.isCompleted) waiter.complete();
        }
        _idleWaiters.clear();
      }
    }
  }

  /// Completes when nothing runs or waits (tests).
  Future<void> whenIdle() {
    if (isIdle) return Future<void>.value();
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }
}
