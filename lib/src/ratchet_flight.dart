/// Keeps the order of session-encrypted envelopes close to the order they
/// are sent in.
///
/// Olm keeps only 40 skipped message keys per chain. An envelope that waits
/// between encryption and the network (a limiter's turn, a queue, a route
/// resting after failures) while many newer ones go out ahead of it arrives
/// too late to be read, and both ends reset their session over it. This
/// gate lets an envelope be encrypted only while the oldest one encrypted
/// for the same peer and not yet handed to a transport is less than
/// [window] places behind and on the same chain: every change of direction
/// starts a new chain, the first message of a chain must reach the peer
/// before the first message of the next (the peer cannot take the ratchet
/// step otherwise), and a session keeps only its last 5 receiving chains.
/// Newer ones wait for it (at most [holdMax]: one
/// that never gets handed over must not stop the peer for good).
library;

import 'dart:async';

class RatchetFlightGate {
  RatchetFlightGate({
    this.window = 30,
    this.maxTurns = 1,
    this.holdMax = const Duration(seconds: 20),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How many envelopes may be encrypted after the oldest unsent one.
  final int window;

  /// How many changes of direction may come after the oldest unsent one.
  final int maxTurns;

  /// How long an unsent envelope holds the others back.
  final Duration holdMax;
  final DateTime Function() _now;

  final Map<String, _Peer> _peers = {};

  /// Envelopes encrypted for [peer] so far (retries older than a few of
  /// these are encrypted again).
  int sequenceOf(String peer) => _peers[peer]?.next ?? 0;

  /// Changes of direction for [peer] so far: sending after receiving.
  int turnsOf(String peer) => _peers[peer]?.turns ?? 0;

  /// Something from [peer] was decrypted: the next envelope sent to it
  /// starts a new chain.
  void noteReceived(String peer) {
    _peers.putIfAbsent(peer, _Peer.new).receivedSince = true;
  }

  /// Envelopes encrypted and not yet handed over, for [peer].
  int outstanding(String peer) => _peers[peer]?.sent.length ?? 0;

  /// Completes when an envelope for [peer] may be encrypted. Callers pair
  /// it with [leave] when the envelope has been handed to a transport (or
  /// the encryption failed).
  Future<void> enter(String peer, String messageId) {
    final state = _peers.putIfAbsent(peer, _Peer.new);
    // The same message encrypted again takes the place of its old copy.
    state.sent.remove(messageId);
    final waiter = _Waiter(messageId);
    state.waiting.add(waiter);
    _pump(peer, state);
    return waiter.done.future;
  }

  void leave(String peer, String messageId) {
    final state = _peers[peer];
    if (state == null) return;
    state.sent.remove(messageId);
    _pump(peer, state);
  }

  void _pump(String peer, _Peer state) {
    state.timer?.cancel();
    state.timer = null;
    final now = _now();
    state.sent.removeWhere((_, entry) => now.difference(entry.at) >= holdMax);
    while (state.waiting.isNotEmpty) {
      final oldest = state.sent.values.isEmpty ? null : state.sent.values.first;
      final turnAfter = state.turns + (state.receivedSince ? 1 : 0);
      if (oldest != null &&
          (state.next - oldest.seq >= window ||
              turnAfter - oldest.turn >= maxTurns)) {
        break;
      }
      final waiter = state.waiting.removeAt(0);
      state.turns = turnAfter;
      state.receivedSince = false;
      state.sent[waiter.messageId] = (
        seq: state.next++,
        turn: state.turns,
        at: now,
      );
      waiter.done.complete();
    }
    if (state.waiting.isNotEmpty && state.sent.isNotEmpty) {
      // The oldest stops holding the rest back after [holdMax].
      final left = holdMax - now.difference(state.sent.values.first.at);
      state.timer = Timer(
        left.isNegative
            ? Duration.zero
            : left + const Duration(milliseconds: 1),
        () => _pump(peer, state),
      );
    }
  }

  void close() {
    for (final state in _peers.values) {
      state.timer?.cancel();
      for (final waiter in state.waiting) {
        if (!waiter.done.isCompleted) waiter.done.complete();
      }
      state.waiting.clear();
    }
    _peers.clear();
  }
}

class _Peer {
  int next = 0;
  int turns = 0;
  bool receivedSince = false;
  final Map<String, ({int seq, int turn, DateTime at})> sent = {};
  final List<_Waiter> waiting = [];
  Timer? timer;
}

class _Waiter {
  _Waiter(this.messageId);
  final String messageId;
  final Completer<void> done = Completer<void>();
}
