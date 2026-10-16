import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'desktop_native.dart';
import 'mesh.dart';

export 'desktop_native.dart' show DesktopBleNative;

/// Linux/Windows neighbours, through the same OS stack as USB dongles.
class DesktopBitchatLinks implements BitchatLinkLayer {
  DesktopBitchatLinks._(this._native) {
    _problems = _Feed<String?>(initial: () => _problem);
  }

  static Future<DesktopBitchatLinks> start({
    DesktopBleNative? native,
    Duration pollInterval = const Duration(milliseconds: 100),
  }) async {
    if (pollInterval < const Duration(milliseconds: 20)) {
      throw ArgumentError.value(pollInterval, 'pollInterval');
    }
    final links = DesktopBitchatLinks._(native ?? FfiDesktopBleNative());
    try {
      await links._native.open();
      links._timer = Timer.periodic(pollInterval, (_) => links.pollNow());
      return links;
    } catch (_) {
      await links.close();
      rethrow;
    }
  }

  static final _linkPattern = RegExp(r'^ble:[0-9a-f]{16}$');
  final DesktopBleNative _native;
  final _received = _Feed<(String, Uint8List)>();
  late final _Feed<String?> _problems;
  final _changes = _Feed<void>();
  final Map<String, int> _limits = {};
  Timer? _timer;
  Future<void>? _closing;
  bool _closed = false;
  bool _seenStatus = false;
  String? _problem;
  String? _adapter;
  bool _powered = false;
  bool _peripheral = false;
  int droppedNativeEvents = 0;
  int droppedNativeInput = 0;

  String get adapterSummary => !_seenStatus
      ? 'Checking Bluetooth adapter'
      : !_powered
      ? 'Bluetooth off or unavailable'
      : '${_adapter ?? 'Bluetooth adapter'} · '
            '${_peripheral ? 'advertising and connecting' : 'connecting'} · '
            '${_limits.length} nearby';

  /// Native polls are bounded, nonblocking memory operations. Exposed for
  /// deterministic fake-source tests as well as the timer above.
  void pollNow() {
    if (_closed) return;
    try {
      final poll = _native.poll();
      final oldSummary = adapterSummary;
      final nextLimits = <String, int>{};
      if (poll['links'] case final Map links) {
        for (final entry in links.entries.take(8)) {
          final link = entry.key;
          final limit = entry.value;
          if (link is String &&
              _validLink(link) &&
              limit is int &&
              limit > 0 &&
              limit <= 512) {
            nextLimits[link] = limit;
          }
        }
      }
      final changed =
          nextLimits.length != _limits.length ||
          nextLimits.entries.any((e) => _limits[e.key] != e.value);
      _limits
        ..clear()
        ..addAll(nextLimits);
      if (changed) _changes.add(null);
      if (poll['status'] case final Map status) {
        _seenStatus = true;
        _adapter = switch (status['adapter']) {
          final String name when name.length <= 128 => name,
          _ => null,
        };
        _powered = status['powered'] == true;
        _peripheral = status['peripheral'] == true;
        droppedNativeEvents = _counter(status['droppedEvents']);
        droppedNativeInput = _counter(status['droppedInput']);
        final problem = switch (status['problem']) {
          final String text when text.length <= 512 => text,
          _ => null,
        };
        if (problem != _problem || oldSummary != adapterSummary) {
          _problem = problem;
          _problems.add(problem);
        }
      }
      if (poll['events'] case final List events) {
        for (final event in events.take(32)) {
          if (event is! Map) continue;
          final link = event['link'];
          final data = event['data'];
          if (link is! String ||
              !_limits.containsKey(link) ||
              data is! String ||
              data.length > 5464) {
            continue;
          }
          try {
            final bytes = base64Decode(data);
            if (bytes.isNotEmpty && bytes.length <= 4096) {
              _received.add((link, bytes));
            }
          } on FormatException {
            // Malformed radio events never terminate the polling loop.
          }
        }
      }
    } catch (_) {
      const problem =
          'Bluetooth connection failed. Check the adapter and Bluetooth permissions.';
      if (_problem != problem) {
        _problem = problem;
        _problems.add(problem);
      }
      if (_limits.isNotEmpty) {
        _limits.clear();
        _changes.add(null);
      }
    }
  }

  static int _counter(Object? value) => value is int && value >= 0 ? value : 0;
  static bool _validLink(String value) =>
      value.length == 20 && _linkPattern.hasMatch(value);

  @override
  Map<String, int> get linkLimits => Map.unmodifiable(_limits);
  Set<String> get neighbours => Set.unmodifiable(_limits.keys);
  Stream<void> get neighbourChanges => _changes.stream;
  int get droppedPausedEvents => _received.dropped;

  @override
  Stream<(String, Uint8List)> get received => _received.stream;
  @override
  Stream<String?> get problems => _problems.stream;

  @override
  Future<void> sendTo(String link, Uint8List packet) async {
    final limit = _limits[link];
    if (_closed ||
        !_validLink(link) ||
        limit == null ||
        packet.isEmpty ||
        packet.length > limit ||
        !_native.sendTo(link, packet)) {
      throw StateError(
        'That device is no longer nearby or its Bluetooth queue is full.',
      );
    }
  }

  @override
  Future<void> broadcast(Uint8List packet, {String? except}) async {
    if (_closed) throw StateError('Bluetooth mesh is closed.');
    if (packet.isEmpty ||
        packet.length > 512 ||
        (except != null && !_validLink(except))) {
      throw ArgumentError('Invalid Bluetooth packet or link.');
    }
    final sent = _native.broadcast(packet, except: except);
    if (sent == 0 && except == null) {
      throw StateError('No Bluetooth devices nearby or their queues are full.');
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _timer?.cancel();
    _limits.clear();
    _received.close();
    _changes.close();
    _problems.close();
    await _native.close();
  }
}

/// A paused listener must not turn radio traffic into an unbounded Dart
/// queue. Deliver synchronously to active listeners and drop for paused
/// ones. Each new problem listener receives just the current state.
class _Feed<T> {
  _Feed({this.initial});
  final T Function()? initial;
  final _listeners = <MultiStreamController<T>>{};
  bool _closed = false;
  int dropped = 0;
  late final Stream<T> stream = Stream<T>.multi((controller) {
    if (_closed) {
      controller.closeSync();
      return;
    }
    if (_listeners.length >= 16) {
      controller.addError(StateError('Too many Bluetooth event listeners.'));
      controller.close();
      return;
    }
    _listeners.add(controller);
    controller.onCancel = () {
      _listeners.remove(controller);
    };
    if (initial case final seed?) controller.add(seed());
  }, isBroadcast: true);

  void add(T value) {
    if (_closed) return;
    for (final listener in _listeners.toList(growable: false)) {
      if (listener.isPaused) {
        dropped++;
        continue;
      }
      listener.addSync(value);
    }
  }

  void close() {
    _closed = true;
    for (final listener in _listeners) {
      listener.close();
    }
    _listeners.clear();
  }
}
