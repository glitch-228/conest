import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conest/src/tor_carrier.dart';

/// An in-memory Tor network: each device's onion service gets an address
/// kept in its state directory, and frames sent to an address arrive at the
/// device running it.
class FakeTorNetwork {
  final _services = <String, FakeTorApi>{};
  final _addressesByState = <String, String>{};
  final _random = Random(7);

  /// Starts fail while this is set, like a censored network.
  bool blocked = false;

  FakeTorApi device() => FakeTorApi._(this);

  String _addressFor(
    String stateDirectory,
  ) => _addressesByState[stateDirectory] ??=
      '${List.generate(56, (_) => 'abcdefghijklmnopqrstuvwxyz234567'[_random.nextInt(32)]).join()}.onion';
}

class FakeTorApi implements TorApi {
  FakeTorApi._(this._network);

  final FakeTorNetwork _network;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  String? _address;
  int starts = 0;
  List<String> lastBridges = const [];

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<String> start({
    required String stateDirectory,
    required String cacheDirectory,
    required List<String> bridges,
    String? transportPath,
  }) async {
    starts++;
    lastBridges = bridges;
    _events.add({'type': 'bootstrap', 'fraction': 0.5});
    if (_network.blocked) throw StateError('Tor is blocked.');
    final address = _network._addressFor(stateDirectory);
    _address = address;
    _network._services[address] = this;
    _events.add({'type': 'bootstrap', 'fraction': 1.0});
    return address;
  }

  @override
  Future<void> send(String onion, Uint8List frame) async {
    if (_address == null) throw StateError('Tor is not running.');
    final target = _network._services[onion];
    if (target == null) throw StateError('Onion service unreachable.');
    target._events.add({'type': 'frame', 'data': base64Encode(frame)});
  }

  @override
  Future<void> stop() async {
    final address = _address;
    if (address != null && identical(_network._services[address], this)) {
      _network._services.remove(address);
    }
    _address = null;
  }
}
