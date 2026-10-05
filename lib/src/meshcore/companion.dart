import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../radio/byte_link.dart';

/// MeshCore companion radio protocol (examples/companion_radio): frames
/// of at most 176 bytes, `<` + little-endian length to the radio and `>`
/// + length from it.
abstract final class MeshCoreFraming {
  static const int toRadio = 0x3c; // '<'
  static const int fromRadio = 0x3e; // '>'
  static const int maxFrame = 176;

  static Uint8List frame(List<int> payload) {
    if (payload.isEmpty || payload.length > maxFrame) {
      throw ArgumentError('MeshCore frame size is out of range.');
    }
    return Uint8List.fromList([
      toRadio,
      payload.length & 0xff,
      payload.length >> 8,
      ...payload,
    ]);
  }
}

/// Splits the radio's output into frames.
class MeshCoreDeframer {
  final List<int> _buffer = [];

  List<Uint8List> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final frames = <Uint8List>[];
    while (true) {
      final start = _buffer.indexOf(MeshCoreFraming.fromRadio);
      if (start < 0) {
        _buffer.clear();
        return frames;
      }
      if (start > 0) _buffer.removeRange(0, start);
      if (_buffer.length < 3) return frames;
      final length = _buffer[1] | (_buffer[2] << 8);
      if (length == 0 || length > MeshCoreFraming.maxFrame) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < 3 + length) return frames;
      frames.add(Uint8List.fromList(_buffer.sublist(3, 3 + length)));
      _buffer.removeRange(0, 3 + length);
    }
  }
}

/// Commands, responses and pushes Conest uses.
abstract final class MeshCoreCode {
  static const int appStart = 1;
  static const int sendTextMessage = 2;
  static const int setDeviceTime = 6;
  static const int addUpdateContact = 9;
  static const int getContactByKey = 30;
  static const int syncNextMessage = 10;
  static const int deviceQuery = 22;

  static const int ok = 0;
  static const int error = 1;
  static const int contact = 3;
  static const int selfInfo = 5;
  static const int sent = 6;
  static const int contactMessage = 7;
  static const int noMoreMessages = 10;
  static const int deviceInfo = 13;
  static const int contactMessageV3 = 16;

  static const int pushMessageWaiting = 0x83;

  static const int textPlain = 0;

  /// Command data: delivered to the app, not shown on the radio's screen,
  /// and not acknowledged over the air.
  static const int textCliData = 1;

  static const int advertTypeChat = 1;
  static const int pathUnknown = 0xff;
}

/// A text message the radio received from a contact.
class MeshCoreMessage {
  const MeshCoreMessage({
    required this.senderPrefix,
    required this.textType,
    required this.timestamp,
    required this.text,
  });

  /// The first six bytes of the sender's public key.
  final Uint8List senderPrefix;
  final int textType;
  final int timestamp;
  final Uint8List text;
}

/// A MeshCore companion radio on a serial or Bluetooth link.
class MeshCoreRadio {
  MeshCoreRadio._(this._link) {
    _subscription = _link.input.listen((bytes) {
      // Over Bluetooth each notification is one frame, without the serial
      // header.
      final frames = _link.keepsMessages ? [bytes] : _deframer.add(bytes);
      for (final frame in frames) {
        _handle(frame);
      }
    });
    unawaited(_link.closed.then((_) => _finish()));
  }

  /// Opens the radio, asks for protocol version 3 frames and reads its
  /// public key; throws when no MeshCore companion answers.
  static Future<MeshCoreRadio> open(
    ByteLink link, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final radio = MeshCoreRadio._(link);
    try {
      await radio._request(
        [MeshCoreCode.deviceQuery, 3],
        {MeshCoreCode.deviceInfo},
        timeout,
      );
      final self = await radio._request(
        [MeshCoreCode.appStart, 1, 0, 0, 0, 0, 0, 0, ...ascii.encode('Conest')],
        {MeshCoreCode.selfInfo},
        timeout,
      );
      if (self.length < 4 + 32) {
        throw StateError('The MeshCore radio sent no public key.');
      }
      radio.publicKey = Uint8List.fromList(self.sublist(4, 36));
      return radio;
    } catch (error) {
      await radio.close();
      if (error is TimeoutException) {
        throw StateError(
          'No MeshCore companion radio answered on ${link.label}.',
        );
      }
      rethrow;
    }
  }

  final ByteLink _link;
  final MeshCoreDeframer _deframer = MeshCoreDeframer();
  final WriteQueue _queue = WriteQueue();
  late final StreamSubscription<Uint8List> _subscription;
  final _messages = StreamController<MeshCoreMessage>.broadcast();
  final _closed = Completer<void>();

  /// One command at a time: responses carry no request id.
  Future<void> _commands = Future<void>.value();
  Completer<Uint8List>? _pending;
  Set<int> _pendingCodes = const {};
  bool _syncing = false;

  late final Uint8List publicKey;

  String get label => _link.label;
  Stream<MeshCoreMessage> get messages => _messages.stream;
  Future<void> get closed => _closed.future;

  /// Adds or updates a contact so the radio can send to it and accept its
  /// messages; with an unknown path it floods.
  /// Whether the radio already lists the contact with [publicKey].
  Future<bool> hasContact(List<int> publicKey) async {
    final reply = await _request(
      [MeshCoreCode.getContactByKey, ...publicKey],
      {MeshCoreCode.contact, MeshCoreCode.error},
    );
    return reply[0] == MeshCoreCode.contact;
  }

  /// Sets the radio's clock (it stamps the messages it sends).
  Future<void> setTime(DateTime time) {
    final seconds = time.millisecondsSinceEpoch ~/ 1000;
    return _request(
      [
        MeshCoreCode.setDeviceTime,
        seconds & 0xff,
        (seconds >> 8) & 0xff,
        (seconds >> 16) & 0xff,
        (seconds >> 24) & 0xff,
      ],
      {MeshCoreCode.ok, MeshCoreCode.error},
    );
  }

  /// Adds the contact unless the radio already lists it, so a route it has
  /// learned and a name the user gave are kept.
  Future<void> ensureContact(List<int> publicKey, String name) async {
    if (await hasContact(publicKey)) return;
    await addContact(publicKey, name);
  }

  Future<void> addContact(List<int> publicKey, String name) async {
    if (publicKey.length != 32) throw ArgumentError('Keys are 32 bytes.');
    final nameBytes = Uint8List(32)
      ..setRange(
        0,
        name.length.clamp(0, 31),
        ascii.encode(name.length > 31 ? name.substring(0, 31) : name),
      );
    await _request(
      [
        MeshCoreCode.addUpdateContact,
        ...publicKey,
        MeshCoreCode.advertTypeChat,
        0, // flags
        MeshCoreCode.pathUnknown,
        ...List.filled(64, 0), // path
        ...nameBytes,
        0, 0, 0, 0, // last advert
      ],
      {MeshCoreCode.ok},
    );
  }

  /// Sends [text] to the contact whose key starts with [prefix] (6 bytes).
  Future<void> sendText(
    List<int> prefix,
    List<int> text, {
    int type = MeshCoreCode.textCliData,
    required int timestamp,
  }) async {
    if (prefix.length != 6) throw ArgumentError('Prefixes are 6 bytes.');
    await _request(
      [
        MeshCoreCode.sendTextMessage,
        type,
        0, // attempt
        timestamp & 0xff,
        (timestamp >> 8) & 0xff,
        (timestamp >> 16) & 0xff,
        (timestamp >> 24) & 0xff,
        ...prefix,
        ...text,
      ],
      {MeshCoreCode.sent},
    );
  }

  /// Fetches every message the radio holds.
  Future<void> syncMessages() async {
    if (_syncing) return;
    _syncing = true;
    try {
      for (var count = 0; count < 256; count++) {
        final reply = await _request(
          [MeshCoreCode.syncNextMessage],
          {
            MeshCoreCode.contactMessageV3,
            MeshCoreCode.contactMessage,
            MeshCoreCode.noMoreMessages,
            // Channel messages are answered too; they are not Conest's.
            8,
            17,
            27,
          },
        );
        if (reply[0] == MeshCoreCode.noMoreMessages) return;
        final message = _parseMessage(reply);
        if (message != null) _messages.add(message);
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _link.close();
    _finish();
  }

  Future<Uint8List> _request(
    List<int> command,
    Set<int> answers, [
    Duration timeout = const Duration(seconds: 10),
  ]) {
    final result = _commands.then((_) async {
      if (_closed.isCompleted) throw StateError('The MeshCore radio is gone.');
      final pending = _pending = Completer<Uint8List>();
      _pendingCodes = {...answers, MeshCoreCode.error};
      await _queue.run(
        () => _link.write(
          _link.keepsMessages ? command : MeshCoreFraming.frame(command),
        ),
      );
      try {
        final Uint8List reply;
        try {
          reply = await pending.future.timeout(timeout);
        } on TimeoutException {
          // Replies carry no request id: a late one could be taken for the
          // next command's. Drop the link; the carrier reconnects.
          unawaited(close());
          rethrow;
        }
        if (reply[0] == MeshCoreCode.error &&
            !answers.contains(MeshCoreCode.error)) {
          throw StateError(
            'The MeshCore radio refused the command '
            '(error ${reply.length > 1 ? reply[1] : '?'}).',
          );
        }
        return reply;
      } finally {
        if (identical(_pending, pending)) _pending = null;
      }
    });
    _commands = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  void _handle(Uint8List frame) {
    if (frame.isEmpty) return;
    if (frame[0] == MeshCoreCode.pushMessageWaiting) {
      unawaited(syncMessages().catchError((Object _) {}));
      return;
    }
    final pending = _pending;
    if (pending != null &&
        !pending.isCompleted &&
        _pendingCodes.contains(frame[0])) {
      pending.complete(frame);
    }
  }

  static MeshCoreMessage? _parseMessage(Uint8List frame) {
    // V3: code, snr, 2 reserved; older: code only. Then prefix (6), path
    // length, text type, timestamp (4, little-endian), text.
    final offset = switch (frame[0]) {
      MeshCoreCode.contactMessageV3 => 4,
      MeshCoreCode.contactMessage => 1,
      _ => -1,
    };
    if (offset < 0 || frame.length < offset + 6 + 1 + 1 + 4) return null;
    final prefix = Uint8List.fromList(frame.sublist(offset, offset + 6));
    final type = frame[offset + 7];
    final timestamp = ByteData.sublistView(
      frame,
      offset + 8,
      offset + 12,
    ).getUint32(0, Endian.little);
    return MeshCoreMessage(
      senderPrefix: prefix,
      textType: type,
      timestamp: timestamp,
      text: Uint8List.fromList(frame.sublist(offset + 12)),
    );
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _closed.complete();
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('The MeshCore radio disconnected.'));
    }
    unawaited(_messages.close());
  }
}
