import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'group_call_models.dart';

typedef GroupCallSign = Future<Uint8List> Function(Uint8List bytes);
typedef GroupCallVerify =
    Future<bool> Function(String sender, Uint8List bytes, Uint8List signature);

class GroupCallFrame {
  const GroupCallFrame(this.sender, this.index, this.sequence, this.payload);
  final String sender;
  final int index;
  final int sequence;
  final Uint8List payload;
}

class _Epoch {
  _Epoch(this.number, this.bytes, this.roster);
  final int number;
  final Uint8List bytes;
  final List<GroupCallParticipant> roster;
  final keys = <String, Future<SecretKey>>{};
  final replay = <String, _Replay>{};
  DateTime? expires;
  void clear() {
    bytes.fillRange(0, bytes.length, 0);
    keys.clear();
    replay.clear();
  }
}

/// Every frame is bound to its call, epoch, sender and sequence. A signature
/// additionally prevents a forwarder (which shares the call key as a listener)
/// from impersonating another speaker. No secret appears in the wire header.
class GroupCallCipher {
  GroupCallCipher({
    required this.groupId,
    required this.callId,
    required this.localDeviceId,
    required this.sign,
    required this.verify,
    required this.now,
  });
  static const marker = 0x36;
  static const maxFrameBytes = 1200;
  static const maxPayloadBytes = 1101;
  static const epochGrace = Duration(milliseconds: 250);
  final String groupId;
  final String callId;
  final String localDeviceId;
  final GroupCallSign sign;
  final GroupCallVerify verify;
  final DateTime Function() now;
  final _cipher = Chacha20.poly1305Aead();
  _Epoch? _current;
  _Epoch? _previous;
  int _sequence = 0;
  Uint8List? _tag;
  bool _closed = false;
  int get epoch => _current?.number ?? 0;

  static Uint8List randomKey() => Uint8List.fromList(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );

  Future<void> install(
    int number,
    Uint8List key,
    List<GroupCallParticipant> roster,
  ) async {
    if (_closed ||
        number <= epoch ||
        number > 0xffffffff ||
        key.length != 32 ||
        roster.isEmpty ||
        roster.length > groupCallMaxParticipants) {
      throw StateError('Invalid call key epoch.');
    }
    _previous?.clear();
    _previous = _current;
    _previous?.expires = now().add(epochGrace);
    _current = _Epoch(number, Uint8List.fromList(key), List.of(roster));
    _sequence = 0;
    _tag ??= Uint8List.fromList(
      (await Sha256().hash(
        utf8.encode(jsonEncode(['conest.group.call.tag.v1', groupId, callId])),
      )).bytes.take(8).toList(),
    );
  }

  Future<SecretKey> _key(_Epoch epoch, String sender) => epoch.keys.putIfAbsent(
    sender,
    () => Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(epoch.bytes),
      nonce: utf8.encode(jsonEncode([groupId, callId, epoch.number])),
      info: utf8.encode(jsonEncode(['conest.group.call.sender.v1', sender])),
    ),
  );

  Uint8List _nonce(int epoch, int index, int sequence) {
    final nonce = ByteData(12)
      ..setUint32(0, epoch, Endian.big)
      ..setUint32(4, index, Endian.big)
      ..setUint32(8, sequence, Endian.big);
    return nonce.buffer.asUint8List();
  }

  Future<Uint8List?> encrypt(Uint8List payload) async {
    final state = _current;
    if (_closed ||
        state == null ||
        payload.isEmpty ||
        payload.length > maxPayloadBytes) {
      return null;
    }
    final me = state.roster
        .where((p) => p.deviceId == localDeviceId)
        .firstOrNull;
    if (me == null || _sequence >= 0xffffffff) return null;
    final sequence = ++_sequence;
    final header = Uint8List(18)
      ..[0] = marker
      ..setRange(1, 9, _tag!)
      ..[13] = me.index;
    final data = ByteData.sublistView(header)
      ..setUint32(9, state.number, Endian.big)
      ..setUint32(14, sequence, Endian.big);
    final box = await _cipher.encrypt(
      payload,
      secretKey: await _key(state, localDeviceId),
      nonce: _nonce(state.number, me.index, sequence),
      aad: header,
    );
    final signed = Uint8List.fromList([
      ...data.buffer.asUint8List(),
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    final signature = await sign(signed);
    if (_closed || !identical(_current, state) || signature.length != 64) {
      return null;
    }
    return Uint8List.fromList([...signed, ...signature]);
  }

  /// Header-only routing hint, never sufficient to play or forward a packet.
  String? claimedSender(Uint8List frame) {
    if (frame.length < 99 ||
        frame.length > maxFrameBytes ||
        frame[0] != marker) {
      return null;
    }
    return _current?.roster
        .where((p) => p.index == frame[13])
        .firstOrNull
        ?.deviceId;
  }

  Future<GroupCallFrame?> decrypt(Uint8List frame) async {
    if (_closed ||
        frame.length < 99 ||
        frame.length > maxFrameBytes ||
        frame[0] != marker ||
        _tag == null) {
      return null;
    }
    for (var i = 0; i < 8; i++) {
      if (frame[i + 1] != _tag![i]) return null;
    }
    final header = ByteData.sublistView(frame, 0, 18);
    final number = header.getUint32(9, Endian.big);
    if (_previous?.expires?.isBefore(now()) == true) {
      _previous?.clear();
      _previous = null;
    }
    final state = _current?.number == number
        ? _current
        : _previous?.number == number
        ? _previous
        : null;
    final sequence = header.getUint32(14, Endian.big);
    final sender = state?.roster.where((p) => p.index == frame[13]).firstOrNull;
    if (state == null ||
        sender == null ||
        _current?.roster.any(
              (p) => p.deviceId == sender.deviceId && p.index == sender.index,
            ) !=
            true) {
      return null;
    }
    final replay = state.replay.putIfAbsent(sender.deviceId, _Replay.new);
    if (!replay.canAccept(sequence)) return null;
    final signedEnd = frame.length - 64;
    final macStart = signedEnd - 16;
    try {
      if (!await verify(
        sender.deviceId,
        Uint8List.sublistView(frame, 0, signedEnd),
        Uint8List.sublistView(frame, signedEnd),
      )) {
        return null;
      }
      final clear = await _cipher.decrypt(
        SecretBox(
          Uint8List.sublistView(frame, 18, macStart),
          nonce: _nonce(number, sender.index, sequence),
          mac: Mac(Uint8List.sublistView(frame, macStart, signedEnd)),
        ),
        secretKey: await _key(state, sender.deviceId),
        aad: Uint8List.sublistView(frame, 0, 18),
      );
      if (_closed ||
          (state != _current &&
              (state != _previous || !now().isBefore(state.expires!))) ||
          _current?.roster.any(
                (p) => p.deviceId == sender.deviceId && p.index == sender.index,
              ) !=
              true ||
          !replay.accept(sequence)) {
        return null;
      }
      return GroupCallFrame(
        sender.deviceId,
        sender.index,
        sequence,
        Uint8List.fromList(clear),
      );
    } catch (_) {
      return null;
    }
  }

  void close() {
    _closed = true;
    _current?.clear();
    _previous?.clear();
    _current = null;
    _previous = null;
  }
}

class _Replay {
  int _highest = 0;
  // BigInt avoids signed 64-bit truncation of a replay bitmap in Dart VM.
  BigInt _bits = BigInt.zero;
  bool canAccept(int n) =>
      n > 0 &&
      (n > _highest ||
          (_highest - n < 64 &&
              (_bits & (BigInt.one << (_highest - n))) == BigInt.zero));
  bool accept(int n) {
    if (!canAccept(n)) return false;
    if (n > _highest) {
      _bits =
          ((_bits << (n - _highest).clamp(0, 64)) | BigInt.one) &
          ((BigInt.one << 64) - BigInt.one);
      _highest = n;
    } else {
      _bits |= BigInt.one << (_highest - n);
    }
    return true;
  }
}
