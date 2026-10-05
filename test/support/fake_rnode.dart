import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/radio/byte_link.dart';
import 'package:conest/src/reticulum/framing.dart';
import 'package:conest/src/reticulum/rnode_interface.dart';

/// Radios in the air: packets reach every other radio that is on and set
/// to the same frequency, bandwidth and spreading factor.
class FakeAir {
  final List<FakeRnode> radios = [];

  FakeRnode radio({bool answersDetect = true, bool acceptsSettings = true}) {
    final radio = FakeRnode._(this, answersDetect, acceptsSettings);
    radios.add(radio);
    return radio;
  }
}

/// An RNode as its host sees it over serial: KISS commands in, reports and
/// received packets out.
class FakeRnode implements ByteLink {
  FakeRnode._(this._air, this.answersDetect, this.acceptsSettings);

  final FakeAir _air;
  final bool answersDetect;
  final bool acceptsSettings;
  final _input = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();
  final KissDeframer _deframer = KissDeframer();
  final Map<int, List<int>> settings = {};
  final List<Uint8List> transmitted = [];

  bool get on => settings[RnodeCommand.radioState]?.first == 1;

  String _channel() => [
    settings[RnodeCommand.frequency],
    settings[RnodeCommand.bandwidth],
    settings[RnodeCommand.spreadingFactor],
  ].join();

  @override
  bool get keepsMessages => false;

  @override
  String get label => 'fake-rnode';

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<Object?> get closed => _closed.future;

  @override
  Future<void> write(List<int> bytes) async {
    for (final (command, data) in _deframer.add(bytes)) {
      scheduleMicrotask(() => _command(command, data));
    }
  }

  void _reply(int command, List<int> data) {
    if (!_input.isClosed) _input.add(KissFraming.frame(command, data));
  }

  void _command(int command, Uint8List data) {
    switch (command) {
      case RnodeCommand.detect:
        if (answersDetect) {
          _reply(RnodeCommand.detect, [RnodeCommand.detectResponse]);
        }
      case RnodeCommand.firmwareVersion:
        _reply(RnodeCommand.firmwareVersion, [1, 82]);
      case RnodeCommand.data:
        if (!on) return;
        transmitted.add(data);
        for (final radio in _air.radios) {
          if (!identical(radio, this) &&
              radio.on &&
              radio._channel() == _channel()) {
            radio._reply(RnodeCommand.data, data);
          }
        }
      default:
        if (!acceptsSettings) return;
        settings[command] = data;
        _reply(command, data);
    }
  }

  @override
  Future<void> close() async {
    _air.radios.remove(this);
    if (!_closed.isCompleted) _closed.complete(null);
    await _input.close();
  }
}
