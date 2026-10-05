import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/reticulum/endpoint.dart';

/// A shared Reticulum medium in memory, like one LoRa channel: every packet
/// one attached interface sends reaches all the others.
class FakeRnsBus {
  final List<FakeRnsLink> _links = [];

  /// Packets sent on the bus, in order.
  final List<Uint8List> sent = [];

  /// Drops packets while true.
  bool down = false;

  FakeRnsLink attach() {
    final link = FakeRnsLink._(this);
    _links.add(link);
    return link;
  }

  /// Connects any configuration to a new link on this bus.
  Future<RnsInterface> connect(Object? config) async => attach();

  void _send(FakeRnsLink from, Uint8List packet) {
    if (down) return;
    sent.add(packet);
    for (final link in List.of(_links)) {
      if (!identical(link, from)) link._packets.add(packet);
    }
  }
}

class FakeRnsLink implements RnsInterface {
  FakeRnsLink._(this._bus);

  final FakeRnsBus _bus;
  final _packets = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();

  @override
  Stream<Uint8List> get packets => _packets.stream;

  @override
  Future<Object?> get closed => _closed.future;

  @override
  Future<void> send(Uint8List packet) async {
    if (_closed.isCompleted) throw StateError('closed');
    scheduleMicrotask(() => _bus._send(this, packet));
  }

  @override
  Future<void> close() async {
    _bus._links.remove(this);
    if (!_closed.isCompleted) _closed.complete(null);
    await _packets.close();
  }
}
