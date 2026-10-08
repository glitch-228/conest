import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/meshtastic/protobuf.dart';
import 'package:conest/src/meshtastic/radio.dart';
import 'package:conest/src/radio/byte_link.dart';

/// Meshtastic radios sharing one mesh: a direct message reaches the radio
/// with that node number.
class FakeMesh {
  final Map<int, FakeMeshtasticDevice> _devices = {};

  FakeMeshtasticDevice device(int nodeNum, {bool answers = true}) =>
      _devices[nodeNum] = FakeMeshtasticDevice._(this, nodeNum, answers);

  /// Every packet sent on the mesh, as (from, to, portnum, payload).
  final List<(int, int, int, Uint8List)> sent = [];

  /// Channels of broadcasts sent, in order.
  final List<int> broadcastChannels = [];

  /// A packet from node [from] (an app user's radio, say): to one node, or
  /// to everyone on [channel] when [to] is [MeshtasticRadio.broadcast].
  void inject(
    int from,
    int to,
    int portnum,
    List<int> payload, {
    int channel = 0,
    int id = 4242,
    int? requestId,
    bool pki = true,
  }) => _deliver(
    from,
    to,
    portnum,
    Uint8List.fromList(payload),
    channel: channel,
    id: id,
    requestId: requestId,
    pki: pki,
  );

  void _deliver(
    int from,
    int to,
    int portnum,
    Uint8List payload, {
    int channel = 0,
    int id = 77,
    bool wantAck = false,
    int? requestId,
    bool pki = true,
  }) {
    sent.add((from, to, portnum, payload));
    if (to == MeshtasticRadio.broadcast) {
      broadcastChannels.add(channel);
      for (final device in _devices.values) {
        if (device.nodeNum != from) {
          device._receive(from, to, portnum, payload, channel, id, requestId);
        }
      }
      return;
    }
    final target = _devices[to];
    target?._receive(from, to, portnum, payload, channel, id, requestId, pki);
    // The receiving radio acknowledges what asked for it.
    if (target != null && wantAck) {
      scheduleMicrotask(
        () => _deliver(to, from, 5, Uint8List(0), requestId: id, id: id + 1),
      );
    }
  }
}

/// A Meshtastic radio as its client sees it over serial or TCP.
class FakeMeshtasticDevice implements ByteLink {
  FakeMeshtasticDevice._(this._mesh, this.nodeNum, this._answers);

  final FakeMesh _mesh;
  final int nodeNum;
  final bool _answers;
  final _input = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();
  final MeshtasticDeframer _deframer = MeshtasticDeframer();

  @override
  bool get keepsMessages => false;

  @override
  String get label => 'fake-meshtastic-$nodeNum';

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<Object?> get closed => _closed.future;

  void _fromRadio(ProtoWriter message) {
    if (!_input.isClosed) {
      // Real devices interleave debug text with frames.
      _input.add(Uint8List.fromList('INFO | boot\r\n'.codeUnits));
      _input.add(MeshtasticFraming.frame(message.toBytes()));
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    for (final frame in _deframer.add(bytes)) {
      final fields = ProtoReader.fields(frame);
      if (fields[3] case final int configId) {
        if (!_answers) continue;
        scheduleMicrotask(() {
          _fromRadio(
            ProtoWriter()..message(3, ProtoWriter()..uint(1, nodeNum)),
          );
          _fromRadio(
            ProtoWriter()..message(
              4,
              ProtoWriter()
                ..uint(1, nodeNum)
                ..message(
                  2,
                  ProtoWriter()
                    ..string(2, 'Node $nodeNum')
                    ..bytes(8, List.filled(32, nodeNum & 0xff)),
                ),
            ),
          );
          _fromRadio(ProtoWriter()..uint(7, configId));
        });
      }
      if (fields[1] case final Uint8List packet) {
        final mesh = ProtoReader.fields(packet);
        final data = ProtoReader.fields(mesh[4]! as Uint8List);
        scheduleMicrotask(
          () => _mesh._deliver(
            nodeNum,
            mesh[2]! as int,
            data[1]! as int,
            Uint8List.fromList(data[2]! as Uint8List),
            channel: mesh[3] is int ? mesh[3]! as int : 0,
            id: mesh[6] is int ? mesh[6]! as int : 77,
            wantAck: mesh[10] == 1,
          ),
        );
      }
    }
  }

  void _receive(
    int from,
    int to,
    int portnum,
    Uint8List payload, [
    int channel = 0,
    int id = 77,
    int? requestId,
    bool pki = true,
  ]) {
    final data = ProtoWriter()
      ..uint(1, portnum)
      ..bytes(2, payload);
    if (requestId != null) data.fixed32(6, requestId);
    final packet = ProtoWriter()
      ..fixed32(1, from)
      ..fixed32(2, to);
    if (channel != 0) packet.uint(3, channel);
    packet
      ..message(4, data)
      ..fixed32(6, id)
      ..boolean(17, pki && to != MeshtasticRadio.broadcast);
    _fromRadio(ProtoWriter()..message(2, packet));
  }

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete(null);
    await _input.close();
  }
}
