/// How often something that has to be polled (the native Iroh endpoint hands
/// over what arrived only when asked) is asked: quickly while traffic is
/// moving, and slowly when nothing has happened for a while, so an idle app
/// does not wake 25 times a second for nothing.
library;

class AdaptivePoll {
  AdaptivePoll({
    this.active = const Duration(milliseconds: 40),
    this.idle = const Duration(milliseconds: 250),
    this.activeFor = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The wait between polls while traffic moves.
  final Duration active;

  /// The wait between polls once nothing moved for [activeFor].
  final Duration idle;

  /// How long after the last traffic polling stays quick.
  final Duration activeFor;
  final DateTime Function() _now;
  DateTime? _lastActivity;

  /// Something was sent or arrived.
  void noteActivity() => _lastActivity = _now();

  /// Whether traffic moved lately.
  bool get isActive {
    final last = _lastActivity;
    return last != null && _now().difference(last) < activeFor;
  }

  /// The wait before the next poll.
  Duration get next => isActive ? active : idle;
}
