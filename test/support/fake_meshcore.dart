import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/meshcore/companion.dart';
import 'package:conest/src/radio/byte_link.dart';

/// MeshCore companion radios on one mesh: a message reaches the radio
/// whose key starts with the prefix, if that radio knows the sender.
class FakeMeshCoreMesh {
  final List<FakeMeshCoreRadio> radios = [];

  FakeMeshCoreRadio radio(int seed, {bool bluetooth = false}) {
    final radio = FakeMeshCoreRadio._(
      this,
      Uint8List.fromList(List.generate(32, (i) => (seed * 31 + i * 7) & 0xff)),
      bluetooth,
    );
    radios.add(radio);
    return radio;
  }

  /// Messages refused because the receiving radio did not know the sender.
  int refused = 0;
}

class FakeMeshCoreRadio implements ByteLink {
  FakeMeshCoreRadio._(this._mesh, this.publicKey, this.keepsMessages);

  final FakeMeshCoreMesh _mesh;
  final Uint8List publicKey;
  final Map<String, Uint8List> contacts = {};
  final List<Uint8List> _offline = [];
  final _input = StreamController<Uint8List>.broadcast();
  final _closed = Completer<Object?>();
  final List<int> _buffer = [];

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Bluetooth: frames without the serial header, one per write.
  @override
  final bool keepsMessages;

  /// Names the radio lists its contacts under.
  final Map<String, String> names = {};

  @override
  String get label => 'fake-meshcore';

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<Object?> get closed => _closed.future;

  void _reply(List<int> frame) {
    if (_input.isClosed) return;
    if (keepsMessages) {
      _input.add(Uint8List.fromList(frame));
      return;
    }
    _input.add(
      Uint8List.fromList([
        MeshCoreFraming.fromRadio,
        frame.length & 0xff,
        frame.length >> 8,
        ...frame,
      ]),
    );
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (keepsMessages) {
      final frame = Uint8List.fromList(bytes);
      scheduleMicrotask(() => _command(frame));
      return;
    }
    _buffer.addAll(bytes);
    while (_buffer.length >= 3 && _buffer[0] == MeshCoreFraming.toRadio) {
      final length = _buffer[1] | (_buffer[2] << 8);
      if (_buffer.length < 3 + length) return;
      final frame = Uint8List.fromList(_buffer.sublist(3, 3 + length));
      _buffer.removeRange(0, 3 + length);
      scheduleMicrotask(() => _command(frame));
    }
  }

  void _command(Uint8List frame) {
    switch (frame[0]) {
      case MeshCoreCode.deviceQuery:
        _reply([MeshCoreCode.deviceInfo, 8, 50, 8]);
      case MeshCoreCode.appStart:
        _reply([MeshCoreCode.selfInfo, 1, 20, 22, ...publicKey, 0, 0, 0, 0]);
      case MeshCoreCode.addUpdateContact:
        final key = frame.sublist(1, 33);
        contacts[_hex(key.sublist(0, 6))] = Uint8List.fromList(key);
        names[_hex(key.sublist(0, 6))] = String.fromCharCodes(
          frame.sublist(36 + 64, 36 + 64 + 32).takeWhile((b) => b != 0),
        );
        _reply([MeshCoreCode.ok]);
      case MeshCoreCode.getContactByKey:
        final known = contacts.containsKey(_hex(frame.sublist(1, 7)));
        _reply(
          known
              ? [MeshCoreCode.contact, ...frame.sublist(1, 33)]
              : [MeshCoreCode.error, 2],
        );
      case MeshCoreCode.setDeviceTime:
        _reply([MeshCoreCode.ok]);
      case MeshCoreCode.sendTextMessage:
        final prefix = frame.sublist(7, 13);
        if (!contacts.containsKey(_hex(prefix))) {
          _reply([MeshCoreCode.error, 2]);
          return;
        }
        final ack = ++_acks;
        _reply([
          MeshCoreCode.sent,
          1,
          ack & 0xff,
          (ack >> 8) & 0xff,
          (ack >> 16) & 0xff,
          (ack >> 24) & 0xff,
          0,
          0,
          0,
          0,
        ]);
        for (final radio in _mesh.radios) {
          if (_hex(radio.publicKey.sublist(0, 6)) == _hex(prefix)) {
            final delivered = radio._deliver(
              publicKey,
              frame[1],
              frame.sublist(3, 7),
              frame.sublist(13),
            );
            // A plain message is acknowledged over the air.
            if (delivered && frame[1] == MeshCoreCode.textPlain) {
              scheduleMicrotask(
                () => _reply([
                  MeshCoreCode.pushSendConfirmed,
                  ack & 0xff,
                  (ack >> 8) & 0xff,
                  (ack >> 16) & 0xff,
                  (ack >> 24) & 0xff,
                  0,
                  0,
                  0,
                  0,
                ]),
              );
            }
          }
        }
      case MeshCoreCode.sendChannelTextMessage:
        _reply([MeshCoreCode.ok]);
        for (final radio in _mesh.radios) {
          if (!identical(radio, this)) {
            radio._channel(frame[2], frame.sublist(3, 7), [
              ...'Radio ${_hex(publicKey.sublist(0, 2))}: '.codeUnits,
              ...frame.sublist(7),
            ]);
          }
        }
        channelSent.add((frame[2], String.fromCharCodes(frame.sublist(7))));
      case MeshCoreCode.getContacts:
        _reply([MeshCoreCode.contactsStart, contacts.length, 0, 0, 0]);
        for (final MapEntry(key: prefix, value: key) in contacts.entries) {
          final name = Uint8List(32)
            ..setRange(
              0,
              (names[prefix] ?? '').length.clamp(0, 31),
              (names[prefix] ?? '').codeUnits,
            );
          _reply([
            MeshCoreCode.contact,
            ...key,
            MeshCoreCode.advertTypeChat,
            0,
            0xff,
            ...List.filled(64, 0),
            ...name,
            0,
            0,
            0,
            0,
          ]);
        }
        _reply([MeshCoreCode.endOfContacts, 0, 0, 0, 0]);
      case MeshCoreCode.syncNextMessage:
        _reply(
          _offline.isEmpty
              ? [MeshCoreCode.noMoreMessages]
              : _offline.removeAt(0),
        );
    }
  }

  int _acks = 0;

  /// Channel messages this radio sent, as (channel, text).
  final List<(int, String)> channelSent = [];

  /// A MeshCore app user on this radio writes [text] to [to].
  void writeAsApp(FakeMeshCoreRadio to, String text) => to._deliver(
    publicKey,
    MeshCoreCode.textPlain,
    [0x10, 0x20, 0x30, 0x40],
    text.codeUnits,
  );

  /// A MeshCore app user on this radio writes on [channel] as [name].
  void broadcastAsApp(int channel, String name, String text) {
    for (final radio in _mesh.radios) {
      if (!identical(radio, this)) {
        radio._channel(channel, [
          0x10,
          0x20,
          0x30,
          0x40,
        ], '$name: $text'.codeUnits);
      }
    }
  }

  void _channel(int channel, List<int> timestamp, List<int> text) {
    _offline.add(
      Uint8List.fromList([
        MeshCoreCode.channelMessageV3,
        12,
        0,
        0,
        channel,
        0xff,
        MeshCoreCode.textPlain,
        ...timestamp,
        ...text,
      ]),
    );
    _reply([MeshCoreCode.pushMessageWaiting]);
  }

  bool _deliver(Uint8List from, int type, List<int> timestamp, List<int> text) {
    if (!contacts.containsKey(_hex(from.sublist(0, 6)))) {
      _mesh.refused++;
      return false;
    }
    _offline.add(
      Uint8List.fromList([
        MeshCoreCode.contactMessageV3,
        12,
        0,
        0,
        ...from.sublist(0, 6),
        0xff,
        type,
        ...timestamp,
        ...text,
      ]),
    );
    _reply([MeshCoreCode.pushMessageWaiting]);
    return true;
  }

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete(null);
    await _input.close();
  }
}
