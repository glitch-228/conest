import 'dart:async';
import 'dart:typed_data';

import '../radio/byte_link.dart';
import 'endpoint.dart';
import 'framing.dart';

/// Radio settings of an RNode; they must match the Reticulum network it
/// joins.
class RnodeConfig {
  const RnodeConfig({
    required this.frequency,
    required this.bandwidth,
    required this.txPower,
    required this.spreadingFactor,
    required this.codingRate,
    this.shortTermAirtimeLimit,
    this.longTermAirtimeLimit,
  });

  /// Hz.
  final int frequency;

  /// Hz.
  final int bandwidth;

  /// dBm.
  final int txPower;
  final int spreadingFactor;
  final int codingRate;

  /// Percent of airtime the radio may use over a short (15 s) and long
  /// (1 h) window, for regions with duty-cycle rules.
  final double? shortTermAirtimeLimit;
  final double? longTermAirtimeLimit;

  /// EU 869.525 MHz (the 10% duty-cycle sub-band), 125 kHz, SF 8, CR 4/5.
  static const eu869 = RnodeConfig(
    frequency: 869525000,
    bandwidth: 125000,
    txPower: 14,
    spreadingFactor: 8,
    codingRate: 5,
    longTermAirtimeLimit: 10,
  );

  /// US 914.875 MHz, 125 kHz, SF 8, CR 4/5.
  static const us915 = RnodeConfig(
    frequency: 914875000,
    bandwidth: 125000,
    txPower: 17,
    spreadingFactor: 8,
    codingRate: 5,
  );

  String? get problem {
    if (frequency < 137000000 || frequency > 3000000000) {
      return 'Frequency is outside what RNodes support.';
    }
    if (!const [
      7800, 10400, 15600, 20800, 31250, 41700, 62500, 125000, 250000, 500000, //
      203125, 406250, 812500, 1625000,
    ].contains(bandwidth)) {
      return 'Unsupported bandwidth.';
    }
    if (txPower < 0 || txPower > 37) return 'TX power must be 0–37 dBm.';
    if (spreadingFactor < 5 || spreadingFactor > 12) {
      return 'Spreading factor must be 5–12.';
    }
    if (codingRate < 5 || codingRate > 8) return 'Coding rate must be 5–8.';
    return null;
  }

  Map<String, Object?> toJson() => {
    'frequency': frequency,
    'bandwidth': bandwidth,
    'txPower': txPower,
    'spreadingFactor': spreadingFactor,
    'codingRate': codingRate,
    if (shortTermAirtimeLimit != null) 'stAlock': shortTermAirtimeLimit,
    if (longTermAirtimeLimit != null) 'ltAlock': longTermAirtimeLimit,
  };

  static RnodeConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final values = [
      json['frequency'],
      json['bandwidth'],
      json['txPower'],
      json['spreadingFactor'],
      json['codingRate'],
    ];
    if (values.any((value) => value is! int)) return null;
    final st = json['stAlock'];
    final lt = json['ltAlock'];
    final config = RnodeConfig(
      frequency: values[0] as int,
      bandwidth: values[1] as int,
      txPower: values[2] as int,
      spreadingFactor: values[3] as int,
      codingRate: values[4] as int,
      shortTermAirtimeLimit: st is num ? st.toDouble() : null,
      longTermAirtimeLimit: lt is num ? lt.toDouble() : null,
    );
    return config.problem == null ? config : null;
  }
}

/// RNode host protocol (KISS commands), from Reticulum's RNodeInterface.
abstract final class RnodeCommand {
  static const int data = 0x00;
  static const int frequency = 0x01;
  static const int bandwidth = 0x02;
  static const int txPower = 0x03;
  static const int spreadingFactor = 0x04;
  static const int codingRate = 0x05;
  static const int radioState = 0x06;
  static const int detect = 0x08;
  static const int shortTermAirtimeLock = 0x0b;
  static const int longTermAirtimeLock = 0x0c;
  static const int ready = 0x0f;
  static const int firmwareVersion = 0x50;
  static const int platform = 0x48;
  static const int mcu = 0x49;
  static const int error = 0x90;

  static const int detectRequest = 0x73;
  static const int detectResponse = 0x46;
  static const int radioOn = 0x01;
  static const int radioOff = 0x00;
}

/// Reticulum over an RNode radio attached by [ByteLink]: detects the
/// device, configures the radio, then carries packets as KISS data frames.
class RnodeInterface implements RnsInterface {
  RnodeInterface._(this._link, this.config) {
    _subscription = _link.input.listen((bytes) {
      for (final (command, data) in _deframer.add(bytes)) {
        _handle(command, data);
      }
    });
    unawaited(_link.closed.then(_finish));
  }

  /// Opens the radio on [link] and configures it; throws when no RNode
  /// answers or it does not take the settings.
  static Future<RnodeInterface> open(
    ByteLink link,
    RnodeConfig config, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final problem = config.problem;
    if (problem != null) throw ArgumentError(problem);
    final rnode = RnodeInterface._(link, config);
    try {
      await rnode._detect(timeout);
      await rnode._configure(timeout);
      return rnode;
    } catch (_) {
      await rnode.close();
      rethrow;
    }
  }

  final ByteLink _link;
  final RnodeConfig config;
  final KissDeframer _deframer = KissDeframer(maxFrame: 1024);
  late final StreamSubscription<Uint8List> _subscription;
  final _packets = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();
  final Map<int, Uint8List> _reported = {};
  final _reports = StreamController<int>.broadcast();
  bool _detected = false;
  int? _lastError;

  String get label => _link.label;

  /// The firmware version the radio reported, such as `1.82`.
  String? get firmwareVersion {
    final version = _reported[RnodeCommand.firmwareVersion];
    return version == null || version.length < 2
        ? null
        : '${version[0]}.${version[1].toString().padLeft(2, '0')}';
  }

  int? get lastError => _lastError;

  @override
  Stream<Uint8List> get packets => _packets.stream;

  @override
  Future<Object?> get closed => _closed.future;

  @override
  Future<void> send(Uint8List packet) async {
    if (_closed.isCompleted) throw StateError('The RNode is disconnected.');
    await _link.write(KissFraming.frame(RnodeCommand.data, packet));
  }

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) {
      try {
        await _link.write(
          KissFraming.frame(RnodeCommand.radioState, [RnodeCommand.radioOff]),
        );
      } catch (_) {}
    }
    await _subscription.cancel();
    await _link.close();
    _finish(null);
  }

  Future<void> _detect(Duration timeout) async {
    await _link.write([
      ...KissFraming.frame(RnodeCommand.detect, [RnodeCommand.detectRequest]),
      ...KissFraming.frame(RnodeCommand.firmwareVersion, [0]),
      ...KissFraming.frame(RnodeCommand.platform, [0]),
      ...KissFraming.frame(RnodeCommand.mcu, [0]),
    ]);
    await _waitFor(() => _detected, timeout, 'No RNode answered on $label.');
  }

  Future<void> _configure(Duration timeout) async {
    List<int> be(int value, int bytes) => [
      for (var shift = (bytes - 1) * 8; shift >= 0; shift -= 8)
        (value >> shift) & 0xff,
    ];
    final commands = <List<int>>[
      KissFraming.frame(RnodeCommand.frequency, be(config.frequency, 4)),
      KissFraming.frame(RnodeCommand.bandwidth, be(config.bandwidth, 4)),
      KissFraming.frame(RnodeCommand.txPower, [config.txPower]),
      KissFraming.frame(RnodeCommand.spreadingFactor, [config.spreadingFactor]),
      KissFraming.frame(RnodeCommand.codingRate, [config.codingRate]),
      if (config.shortTermAirtimeLimit case final limit?)
        KissFraming.frame(
          RnodeCommand.shortTermAirtimeLock,
          be((limit * 100).round(), 2),
        ),
      if (config.longTermAirtimeLimit case final limit?)
        KissFraming.frame(
          RnodeCommand.longTermAirtimeLock,
          be((limit * 100).round(), 2),
        ),
      KissFraming.frame(RnodeCommand.radioState, [RnodeCommand.radioOn]),
    ];
    for (final command in commands) {
      await _link.write(command);
    }
    await _waitFor(
      _configured,
      timeout,
      'The RNode on $label did not take the radio settings.',
    );
  }

  bool _configured() {
    int? value(int command) {
      final data = _reported[command];
      if (data == null || data.isEmpty) return null;
      var result = 0;
      for (final byte in data) {
        result = (result << 8) | byte;
      }
      return result;
    }

    final frequency = value(RnodeCommand.frequency);
    return frequency != null &&
        (frequency - config.frequency).abs() <= 100 &&
        value(RnodeCommand.bandwidth) == config.bandwidth &&
        value(RnodeCommand.txPower) == config.txPower &&
        value(RnodeCommand.spreadingFactor) == config.spreadingFactor &&
        value(RnodeCommand.radioState) == RnodeCommand.radioOn;
  }

  Future<void> _waitFor(
    bool Function() done,
    Duration timeout,
    String failure,
  ) async {
    if (done()) return;
    final deadline = DateTime.now().add(timeout);
    final subscription = _reports.stream.listen((_) {});
    try {
      while (!done()) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) throw StateError(failure);
        await _reports.stream.first.timeout(left, onTimeout: () => -1);
      }
    } finally {
      await subscription.cancel();
    }
  }

  void _handle(int command, Uint8List data) {
    switch (command) {
      case RnodeCommand.data:
        if (data.isNotEmpty) _packets.add(data);
      case RnodeCommand.detect:
        _detected = data.isNotEmpty && data[0] == RnodeCommand.detectResponse;
      case RnodeCommand.error:
        if (data.isNotEmpty) _lastError = data[0];
      default:
        _reported[command] = data;
    }
    if (!_reports.isClosed) _reports.add(command);
  }

  void _finish(Object? error) {
    if (_closed.isCompleted) return;
    _closed.complete(error);
    unawaited(_packets.close());
    unawaited(_reports.close());
  }
}
