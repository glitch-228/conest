import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../radio/byte_link.dart';
import 'protobuf.dart';

/// Meshtastic's stream framing (serial and TCP): 0x94 0xC3, a big-endian
/// 16-bit length, then a protobuf ToRadio or FromRadio.
abstract final class MeshtasticFraming {
  static const int start1 = 0x94;
  static const int start2 = 0xc3;
  static const int maxPayload = 512;

  static Uint8List frame(List<int> payload) {
    if (payload.length > maxPayload) {
      throw ArgumentError('Meshtastic frame is too large.');
    }
    return Uint8List.fromList([
      start1,
      start2,
      payload.length >> 8,
      payload.length & 0xff,
      ...payload,
    ]);
  }
}

/// Splits a Meshtastic stream into payloads; anything between frames (the
/// device's debug log) is skipped.
class MeshtasticDeframer {
  final List<int> _buffer = [];

  List<Uint8List> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final frames = <Uint8List>[];
    while (true) {
      final start = _indexOfStart();
      if (start < 0) {
        // Keep a trailing start byte; drop the rest (log text).
        final keep =
            _buffer.isNotEmpty && _buffer.last == MeshtasticFraming.start1;
        _buffer.clear();
        if (keep) _buffer.add(MeshtasticFraming.start1);
        return frames;
      }
      if (start > 0) _buffer.removeRange(0, start);
      if (_buffer.length < 4) return frames;
      final length = (_buffer[2] << 8) | _buffer[3];
      if (length > MeshtasticFraming.maxPayload) {
        // Not a real header: skip this start byte and look again.
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < 4 + length) return frames;
      frames.add(Uint8List.fromList(_buffer.sublist(4, 4 + length)));
      _buffer.removeRange(0, 4 + length);
    }
  }

  int _indexOfStart() {
    for (var index = 0; index + 1 < _buffer.length; index++) {
      if (_buffer[index] == MeshtasticFraming.start1 &&
          _buffer[index + 1] == MeshtasticFraming.start2) {
        return index;
      }
    }
    return -1;
  }
}

/// A node from the radio's node database.
class MeshtasticNode {
  const MeshtasticNode({required this.num, this.longName, this.publicKey});

  final int num;
  final String? longName;
  final Uint8List? publicKey;
}

/// An application packet the radio received.
class MeshtasticPacket {
  const MeshtasticPacket({
    required this.from,
    required this.to,
    required this.portnum,
    required this.payload,
    required this.id,
    this.pkiEncrypted = false,
    this.channel = 0,
    this.requestId,
  });

  final int from;
  final int to;
  final int portnum;
  final Uint8List payload;
  final int id;

  /// The channel's index on the radio (0 is the primary channel).
  final int channel;

  /// For an acknowledgement: the id of the packet it answers.
  final int? requestId;

  /// Encrypted with the nodes' public keys (a direct message), not only
  /// the channel key.
  final bool pkiEncrypted;
}

/// Field numbers from meshtastic/mesh.proto.
abstract final class _Field {
  // ToRadio
  static const toRadioPacket = 1;
  static const wantConfigId = 3;
  static const heartbeat = 7;
  // FromRadio
  static const fromRadioPacket = 2;
  static const myInfo = 3;
  static const nodeInfo = 4;
  static const configCompleteId = 7;
  static const rebooted = 8;
  // MeshPacket
  static const from = 1;
  static const to = 2;
  static const channel = 3;
  static const decoded = 4;
  static const id = 6;
  static const hopLimit = 9;
  static const wantAck = 10;
  static const pkiEncrypted = 17;
  // Data
  static const portnum = 1;
  static const payload = 2;
  static const requestId = 6;
  // MyNodeInfo
  static const myNodeNum = 1;
  // NodeInfo
  static const num = 1;
  static const user = 2;
  // User
  static const longName = 2;
  static const publicKey = 8;
}

/// A Meshtastic radio on a serial, TCP or Bluetooth stream link, driven
/// through its client API (ToRadio/FromRadio).
class MeshtasticRadio {
  MeshtasticRadio._(this._link) {
    _subscription = _link.input.listen((bytes) {
      for (final frame in _deframer.add(bytes)) {
        try {
          _handle(frame);
        } catch (_) {
          // A garbled or unexpected message is dropped.
        }
      }
    });
    unawaited(_link.closed.then((_) => _finish()));
    // The firmware drops an API client it has not heard from for a while
    // (and then sends nothing): keep the connection alive.
    _heartbeat = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(
        _sendToRadio(
          ProtoWriter()..emptyMessage(_Field.heartbeat),
        ).catchError((Object _) {}),
      ),
    );
  }

  late final Timer _heartbeat;

  /// Most nodes kept from the radio's database.
  static const int _maxNodes = 512;

  /// Opens the radio on [link] and reads its configuration: its own node
  /// number and node database. Throws when no Meshtastic radio answers.
  static Future<MeshtasticRadio> open(
    ByteLink link, {
    Duration timeout = const Duration(seconds: 15),
    Random? random,
  }) async {
    final radio = MeshtasticRadio._(link);
    try {
      // Wake the device's serial API, then ask for the configuration.
      await link.write(List.filled(32, MeshtasticFraming.start2));
      await radio._askConfig(random);
      await radio._configured.future.timeout(timeout);
      if (radio.myNodeNum == null) {
        throw StateError('The Meshtastic radio did not say who it is.');
      }
      return radio;
    } catch (error) {
      await radio.close();
      if (error is TimeoutException) {
        throw StateError('No Meshtastic radio answered on ${link.label}.');
      }
      rethrow;
    }
  }

  final ByteLink _link;
  final MeshtasticDeframer _deframer = MeshtasticDeframer();
  final WriteQueue _queue = WriteQueue();
  late final StreamSubscription<Uint8List> _subscription;
  final _packets = StreamController<MeshtasticPacket>.broadcast();
  final _configured = Completer<void>();
  final _closed = Completer<void>();
  final Map<int, MeshtasticNode> nodes = {};
  int? _configId;
  int? myNodeNum;

  String get label => _link.label;
  Stream<MeshtasticPacket> get packets => _packets.stream;
  Future<void> get closed => _closed.future;

  /// This radio's own public key, if the firmware has one (2.5 and later).
  Uint8List? get myPublicKey => nodes[myNodeNum]?.publicKey;

  /// Everyone on a channel, as a packet's destination.
  static const int broadcast = 0xffffffff;

  /// Sends [payload] on application port [portnum] to node [to] (a direct
  /// message, which current firmware encrypts with the nodes' keys), or to
  /// everyone on [channel] ([broadcast]); returns the packet's id.
  Future<int> send({
    required int to,
    required int portnum,
    required List<int> payload,
    bool wantAck = true,
    int hopLimit = 3,
    int channel = 0,
    Random? random,
  }) async {
    if (_closed.isCompleted) throw StateError('The Meshtastic radio is gone.');
    final id = 1 + (random ?? Random.secure()).nextInt(0x7ffffffe);
    final data = ProtoWriter()
      ..uint(_Field.portnum, portnum)
      ..bytes(_Field.payload, payload);
    final packet = ProtoWriter()..fixed32(_Field.to, to);
    if (channel != 0) packet.uint(_Field.channel, channel);
    packet
      ..message(_Field.decoded, data)
      ..fixed32(_Field.id, id)
      ..uint(_Field.hopLimit, hopLimit)
      ..boolean(_Field.wantAck, wantAck);
    await _sendToRadio(ProtoWriter()..message(_Field.toRadioPacket, packet));
    return id;
  }

  Future<void> _askConfig([Random? random]) {
    final configId = 1 + (random ?? Random.secure()).nextInt(0x7ffffffe);
    _configId = configId;
    return _sendToRadio(ProtoWriter()..uint(_Field.wantConfigId, configId));
  }

  Future<void> close() async {
    _heartbeat.cancel();
    await _subscription.cancel();
    await _link.close();
    _finish();
  }

  Future<void> _sendToRadio(ProtoWriter message) =>
      _queue.run(() => _link.write(MeshtasticFraming.frame(message.toBytes())));

  void _handle(Uint8List frame) {
    final fields = ProtoReader.fields(frame);
    if (fields[_Field.rebooted] == 1) {
      // After a reboot the radio waits for a client to ask again.
      unawaited(_askConfig().catchError((Object _) {}));
    }
    if (fields[_Field.myInfo] case final Uint8List info) {
      final num = ProtoReader.fields(info)[_Field.myNodeNum];
      if (num is int) myNodeNum = num;
    }
    if (fields[_Field.nodeInfo] case final Uint8List info) {
      final node = ProtoReader.fields(info);
      final num = node[_Field.num];
      if (num is int && (nodes.containsKey(num) || nodes.length < _maxNodes)) {
        final user = node[_Field.user] is Uint8List
            ? ProtoReader.fields(node[_Field.user]! as Uint8List)
            : const <int, Object>{};
        final key = user[_Field.publicKey];
        final name = user[_Field.longName];
        nodes[num] = MeshtasticNode(
          num: num,
          longName: name is Uint8List
              ? utf8.decode(name, allowMalformed: true)
              : null,
          publicKey: key is Uint8List && key.length == 32
              ? Uint8List.fromList(key)
              : null,
        );
      }
    }
    if (fields[_Field.configCompleteId] == _configId &&
        !_configured.isCompleted) {
      _configured.complete();
    }
    if (fields[_Field.fromRadioPacket] case final Uint8List raw) {
      final packet = ProtoReader.fields(raw);
      final decoded = packet[_Field.decoded];
      final from = packet[_Field.from];
      if (decoded is! Uint8List || from is! int) return;
      final data = ProtoReader.fields(decoded);
      final portnum = data[_Field.portnum];
      final payload = data[_Field.payload];
      if (portnum is! int || payload is! Uint8List) return;
      _packets.add(
        MeshtasticPacket(
          from: from,
          to: packet[_Field.to] is int ? packet[_Field.to]! as int : 0,
          portnum: portnum,
          payload: Uint8List.fromList(payload),
          id: packet[_Field.id] is int ? packet[_Field.id]! as int : 0,
          pkiEncrypted: packet[_Field.pkiEncrypted] == 1,
          channel: packet[_Field.channel] is int
              ? packet[_Field.channel]! as int
              : 0,
          requestId: data[_Field.requestId] is int
              ? data[_Field.requestId]! as int
              : null,
        ),
      );
    }
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _closed.complete();
    unawaited(_packets.close());
  }
}
