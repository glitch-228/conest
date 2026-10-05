import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'carrier.dart';
import 'native_queue.dart';
import 'transport_models.dart';

/// Version byte at the start of each frame Conest sends between onion
/// services.
const int _frameVersion = 1;

/// Length of a v3 onion host, `<56 base32>.onion`.
const int _onionHostLength = 62;

/// Over Tor, envelopes up to 4 MiB in frames just under the native 1 MiB
/// stream frame limit.
const CarrierFraming torFraming = CarrierFraming(
  maxSealedBytes: 4 * 1024 * 1024,
  chunkBytes: 1024 * 1024 - 128,
);

/// A v3 onion host, `<56 base32 characters>.onion`.
bool isValidTorAddress(String address) =>
    RegExp(r'^[a-z2-7]{56}\.onion$').hasMatch(address);

/// A bridge line as Tor takes it (without a leading "Bridge"), or null when
/// it cannot be one.
String? normalizeBridgeLine(String line) {
  var parts = line.trim().split(RegExp(r'\s+'));
  if (parts.isNotEmpty && parts.first.toLowerCase() == 'bridge') {
    parts = parts.sublist(1);
  }
  final normalized = parts.join(' ');
  if (parts.length < 2 ||
      normalized.length > 2048 ||
      !RegExp(r'^[\x21-\x7e ]+$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

/// Whether a bridge needs a pluggable transport: plain bridges start with
/// their address, others with the transport's name.
bool bridgeNeedsTransport(String line) => !RegExp(r'^[0-9\[]').hasMatch(line);

/// The pluggable transport client (lyrebird) bundled next to the app, if
/// this build ships it.
String? bundledPluggableTransportPath() {
  if (Platform.isAndroid || Platform.isIOS) return null;
  final name = Platform.isWindows ? 'lyrebird.exe' : 'lyrebird';
  final path = p.join(p.dirname(Platform.resolvedExecutable), name);
  return File(path).existsSync() ? path : null;
}

/// The saved Tor carrier: bridges to reach Tor where it is blocked, and
/// the onion address once known.
class TorCarrierConfig {
  const TorCarrierConfig({
    this.bridges = const [],
    this.pluggableTransports = false,
    this.address,
  });

  /// Bridge lines, as Tor Browser shows them (with or without "Bridge").
  final List<String> bridges;

  /// Use the bundled pluggable transports (obfs4, webtunnel, snowflake)
  /// for bridges that need them.
  final bool pluggableTransports;

  /// This device's onion address; its keys stay in the Tor state directory.
  final String? address;

  TorCarrierConfig copyWith({String? address}) => TorCarrierConfig(
    bridges: bridges,
    pluggableTransports: pluggableTransports,
    address: address ?? this.address,
  );

  Map<String, Object?> toJson() => {
    'bridges': bridges,
    if (pluggableTransports) 'pluggableTransports': true,
    'address': ?address,
  };

  static TorCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final bridges = json['bridges'];
    return TorCarrierConfig(
      bridges: [
        if (bridges is List)
          for (final line in bridges)
            if (line is String && line.trim().isNotEmpty) line.trim(),
      ],
      pluggableTransports: json['pluggableTransports'] == true,
      address: switch (json['address']) {
        final String address when isValidTorAddress(address) => address,
        _ => null,
      },
    );
  }
}

/// What the carrier needs from Tor; the native Arti module implements it.
abstract interface class TorApi {
  /// Bootstraps Tor and launches this device's onion service; returns its
  /// host. The service's keys persist in [stateDirectory].
  Future<String> start({
    required String stateDirectory,
    required String cacheDirectory,
    required List<String> bridges,
    String? transportPath,
  });

  Future<void> send(String onion, Uint8List frame);
  Future<void> stop();

  /// `frame` events (base64 `data`) and `bootstrap` progress.
  Stream<Map<String, dynamic>> get events;
}

/// Tor through Arti in `conest_native` (`native/conest_native/src/tor.rs`).
class NativeTorApi implements TorApi {
  NativeTorApi._(this._queue);

  static NativeTorApi? tryCreate() {
    final queue = NativeCommandQueue.tryOpen('tor');
    return queue == null ? null : NativeTorApi._(queue);
  }

  final NativeCommandQueue _queue;

  @override
  Stream<Map<String, dynamic>> get events => _queue.events;

  @override
  Future<String> start({
    required String stateDirectory,
    required String cacheDirectory,
    required List<String> bridges,
    String? transportPath,
  }) async {
    final value = await _queue.request(
      'start',
      {
        'stateDir': stateDirectory,
        'cacheDir': cacheDirectory,
        'bridges': bridges,
        'transportPath': ?transportPath,
        'nickname': 'conest',
      },
      // A first bootstrap through bridges can take minutes.
      const Duration(minutes: 5),
    );
    final address = value is Map ? value['address'] : null;
    if (address is! String) {
      throw const NativeQueueException('No onion address.');
    }
    return address;
  }

  @override
  Future<void> send(String onion, Uint8List frame) => _queue.request('send', {
    'onion': onion,
    'data': base64Encode(frame),
  }, const Duration(minutes: 2));

  @override
  Future<void> stop() => _queue.request('stop');
}

enum TorCarrierState { stopped, connecting, connected, failed }

/// The Tor side of the carrier: this device's onion service receives
/// frames, and frames to a contact go to its onion service. Onion services
/// hide both ends' network locations from each other and from the network.
class TorCarrierChannel implements ManagedCarrierChannel {
  TorCarrierChannel({
    required this.config,
    required TorApi api,
    required this.stateDirectory,
    required this.cacheDirectory,
    required this.onFrame,
    this.transportPath,
    this.onStatusChanged,
    this.onAddress,
    String? knownAddress,
  }) : _api = api,
       _address = knownAddress;

  final TorCarrierConfig config;
  final TorApi _api;
  final String stateDirectory;
  final String cacheDirectory;
  final String? transportPath;

  /// A frame from the onion service [sender].
  final void Function(String sender, Uint8List frame) onFrame;
  final void Function()? onStatusChanged;

  /// The onion address became known or changed.
  final void Function(String address)? onAddress;

  String? _address;
  TorCarrierState _state = TorCarrierState.stopped;
  String? _lastError;
  double _progress = 0;
  bool _started = false;
  int _generation = 0;
  StreamSubscription<Map<String, dynamic>>? _events;

  TorCarrierState get state => _state;
  String? get lastError => _lastError;

  /// Bootstrap progress, 0 to 1.
  double get progress => _progress;

  @override
  String? get localAddress => _address;

  @override
  String get routeLabel => config.bridges.isEmpty ? 'Tor' : 'Tor bridges';

  @override
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_run(++_generation));
  }

  @override
  Future<void> stop() async {
    _started = false;
    _generation++;
    await _events?.cancel();
    _events = null;
    try {
      await _api.stop();
    } catch (_) {}
    _setState(TorCarrierState.stopped);
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    final me = _address;
    if (!_started || _state != TorCarrierState.connected || me == null) {
      throw StateError('Tor is not connected.');
    }
    if (!isValidTorAddress(address)) {
      throw ArgumentError('Not an onion address.');
    }
    await _api.send(
      address,
      Uint8List.fromList([_frameVersion, ...ascii.encode(me), ...frame]),
    );
  }

  Future<void> _run(int generation) async {
    bool current() => _started && generation == _generation;
    var backoff = const Duration(seconds: 5);
    _events ??= _api.events.listen(_event);
    while (current()) {
      try {
        _setState(TorCarrierState.connecting);
        final address = await _api.start(
          stateDirectory: stateDirectory,
          cacheDirectory: cacheDirectory,
          bridges: config.bridges,
          transportPath: config.pluggableTransports ? transportPath : null,
        );
        if (!current()) return;
        if (address != _address) {
          _address = address;
          onAddress?.call(address);
        }
        _lastError = null;
        _setState(TorCarrierState.connected);
        return;
      } catch (error) {
        if (!current()) return;
        _lastError = '$error';
        _setState(TorCarrierState.failed);
        await Future<void>.delayed(backoff);
        backoff = backoff * 2 > const Duration(minutes: 5)
            ? const Duration(minutes: 5)
            : backoff * 2;
      }
    }
  }

  void _event(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'bootstrap':
        final fraction = event['fraction'];
        if (fraction is num) {
          _progress = fraction.toDouble().clamp(0, 1);
          onStatusChanged?.call();
        }
      case 'frame':
        final data = event['data'];
        if (data is! String) return;
        final Uint8List bytes;
        try {
          bytes = base64Decode(data);
        } on FormatException {
          return;
        }
        if (bytes.length <= 1 + _onionHostLength || bytes[0] != _frameVersion) {
          return;
        }
        final sender = ascii.decode(
          bytes.sublist(1, 1 + _onionHostLength),
          allowInvalid: true,
        );
        if (!isValidTorAddress(sender)) return;
        onFrame(sender, Uint8List.sublistView(bytes, 1 + _onionHostLength));
    }
  }

  void _setState(TorCarrierState state) {
    if (_state == state) return;
    _state = state;
    onStatusChanged?.call();
  }
}

/// A Tor carrier adapter: big envelopes are fine over Tor.
CarrierTransportAdapter createTorCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.tor,
  sealer: sealer,
  framing: torFraming,
  path: TransportPathKind.direct,
  sendAttemptTimeout: const Duration(minutes: 2),
  isValidAddress: isValidTorAddress,
  now: now,
);
