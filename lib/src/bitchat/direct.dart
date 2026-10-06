import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'noise.dart';
import 'packet.dart';

/// bitchat's payload types inside a decrypted private (Noise) packet.
abstract final class BitchatPayloadType {
  static const int privateMessage = 0x01;
  static const int readReceipt = 0x02;
  static const int delivered = 0x03;
}

/// How long a Noise session is used before a fresh handshake.
const Duration bitchatSessionLifetime = Duration(hours: 24);

/// A peer seen through a verified announce.
class BitchatPeer {
  BitchatPeer({
    required this.peerId,
    required this.nickname,
    required this.noiseKey,
    required this.signingKey,
    required this.lastSeen,
  });

  final String peerId;
  String nickname;
  final Uint8List noiseKey;
  final Uint8List signingKey;
  DateTime lastSeen;
}

/// Something that happened in direct messaging with bitchat users.
sealed class BitchatDirectEvent {
  const BitchatDirectEvent(this.peerId);
  final String peerId;
}

class BitchatMessageReceived extends BitchatDirectEvent {
  const BitchatMessageReceived(super.peerId, this.messageId, this.text);
  final String messageId;
  final String text;
}

class BitchatReceiptReceived extends BitchatDirectEvent {
  const BitchatReceiptReceived(
    super.peerId,
    this.messageId, {
    required this.read,
  });
  final String messageId;
  final bool read;
}

class BitchatPeerSeen extends BitchatDirectEvent {
  const BitchatPeerSeen(super.peerId);
}

/// A bitchat identity that announces itself and talks to bitchat users:
/// signed announces, Noise XX sessions per peer and private messages with
/// receipts, as the bitchat apps do. Only used when the person chose to be
/// reachable by bitchat users.
class BitchatDirect {
  BitchatDirect._({
    required this.nickname,
    required List<int> noiseSeed,
    required SimpleKeyPair signing,
    required this.noisePublicKey,
    required this.signingPublicKey,
    DateTime Function()? now,
  }) : _noiseSeed = List.unmodifiable(noiseSeed),
       _signing = signing,
       _now = now ?? DateTime.now,
       peerId = bitchatPeerId(noisePublicKey);

  static Future<BitchatDirect> create({
    required String nickname,
    required List<int> noiseSeed,
    required List<int> signingSeed,
    DateTime Function()? now,
  }) async {
    final noise = await X25519().newKeyPairFromSeed(noiseSeed);
    final signing = await Ed25519().newKeyPairFromSeed(signingSeed);
    return BitchatDirect._(
      nickname: nickname,
      noiseSeed: noiseSeed,
      signing: signing,
      noisePublicKey: Uint8List.fromList(
        (await noise.extractPublicKey()).bytes,
      ),
      signingPublicKey: Uint8List.fromList(
        (await signing.extractPublicKey()).bytes,
      ),
      now: now,
    );
  }

  final String nickname;
  final List<int> _noiseSeed;
  final SimpleKeyPair _signing;
  final Uint8List noisePublicKey;
  final Uint8List signingPublicKey;
  final Uint8List peerId;
  final DateTime Function() _now;

  final Map<String, BitchatPeer> _peers = {};
  final Map<String, _Session> _sessions = {};
  final Map<String, List<Uint8List>> _waiting = {};
  final _events = StreamController<BitchatDirectEvent>.broadcast();

  static const int _maxPeers = 512;
  static const int _maxWaitingPerPeer = 32;
  static const Duration _announceMaxAge = Duration(seconds: 900);

  String get peerIdHex => _hex(peerId);
  Stream<BitchatDirectEvent> get events => _events.stream;
  Iterable<BitchatPeer> get peers => _peers.values;
  BitchatPeer? peer(String peerIdHex) => _peers[peerIdHex];

  /// A signed announce for this identity, as bitchat expects: signed over
  /// the packet with TTL 0, no signature, and padding.
  Future<BitchatPacket> announce() async {
    final unsigned = BitchatPacket(
      type: BitchatType.announce,
      senderId: peerId,
      timestamp: _now().millisecondsSinceEpoch,
      payload: BitchatAnnouncement(
        nickname: nickname,
        noisePublicKey: noisePublicKey,
        signingPublicKey: signingPublicKey,
      ).encode(),
    );
    final signature = await Ed25519().sign(
      unsigned.bytesToSign(),
      keyPair: _signing,
    );
    return unsigned.copyWith(signature: Uint8List.fromList(signature.bytes));
  }

  /// A peer's announce: kept when its signature, id and age check out.
  Future<void> handleAnnounce(BitchatPacket packet) async {
    final announcement = BitchatAnnouncement.decode(packet.payload);
    final signature = packet.signature;
    if (announcement == null ||
        signature == null ||
        announcement.signingPublicKey.length != 32 ||
        announcement.noisePublicKey.length != 32) {
      return;
    }
    final id = _hex(bitchatPeerId(announcement.noisePublicKey));
    if (id != _hex(packet.senderId) || id == peerIdHex) return;
    final age = _now().millisecondsSinceEpoch - packet.timestamp;
    if (age.abs() > _announceMaxAge.inMilliseconds) return;
    final known = _peers[id];
    // The signing key is pinned on first sight, as bitchat does.
    if (known != null &&
        !_equal(known.signingKey, announcement.signingPublicKey)) {
      return;
    }
    final valid = await Ed25519().verify(
      packet.bytesToSign(),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          announcement.signingPublicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) return;
    if (known != null) {
      known
        ..nickname = announcement.nickname
        ..lastSeen = _now();
    } else {
      if (_peers.length >= _maxPeers) {
        final oldest = _peers.values.reduce(
          (a, b) => a.lastSeen.isBefore(b.lastSeen) ? a : b,
        );
        _peers.remove(oldest.peerId);
        _sessions.remove(oldest.peerId);
      }
      _peers[id] = BitchatPeer(
        peerId: id,
        nickname: announcement.nickname,
        noiseKey: announcement.noisePublicKey,
        signingKey: announcement.signingPublicKey,
        lastSeen: _now(),
      );
    }
    _events.add(BitchatPeerSeen(id));
  }

  /// Sends [text] to [peerIdHex]; returns the packets to send now and the
  /// message id. Without a session the message waits for the handshake
  /// this starts.
  Future<(List<BitchatPacket>, String)> sendText(
    String peerIdHex,
    String text,
  ) async {
    final messageId = _uuid();
    final body = _privateMessage(messageId, text);
    return (
      await _send(peerIdHex, BitchatPayloadType.privateMessage, body),
      messageId,
    );
  }

  /// Tells [peerIdHex] its message [messageId] was read.
  Future<List<BitchatPacket>> sendReadReceipt(
    String peerIdHex,
    String messageId,
  ) => _send(peerIdHex, BitchatPayloadType.readReceipt, utf8.encode(messageId));

  Future<List<BitchatPacket>> _send(
    String peerIdHex,
    int type,
    List<int> body,
  ) async {
    final plaintext = Uint8List.fromList([type, ...body]);
    final session = _sessions[peerIdHex];
    if (session != null &&
        session.ready &&
        _now().difference(session.startedAt) < bitchatSessionLifetime) {
      return [await _encrypt(peerIdHex, session, plaintext)];
    }
    final waiting = _waiting.putIfAbsent(peerIdHex, () => []);
    if (waiting.length >= _maxWaitingPerPeer) waiting.removeAt(0);
    waiting.add(plaintext);
    if (session != null && !session.ready && session.handshake.initiator) {
      return const [];
    }
    return [await _startHandshake(peerIdHex)];
  }

  Future<BitchatPacket> _startHandshake(String peerIdHex) async {
    final handshake = await NoiseXXHandshake.start(
      initiator: true,
      staticSeed: _noiseSeed,
    );
    _sessions[peerIdHex] = _Session(handshake, _now());
    return _packet(
      BitchatType.noiseHandshake,
      peerIdHex,
      await handshake.writeMessage(),
    );
  }

  /// A Noise packet (handshake or transport) addressed to this identity;
  /// returns the packets to send in answer.
  Future<List<BitchatPacket>> handleNoise(BitchatPacket packet) async {
    final from = _hex(packet.senderId);
    if (packet.recipientId == null || !_equal(packet.recipientId!, peerId)) {
      return const [];
    }
    try {
      return packet.type == BitchatType.noiseHandshake
          ? await _handleHandshake(from, packet.payload)
          : await _handleTransport(from, packet.payload);
    } on FormatException {
      return const [];
    } on StateError {
      return const [];
    }
  }

  Future<List<BitchatPacket>> _handleHandshake(
    String from,
    Uint8List message,
  ) async {
    var session = _sessions[from];
    final starting =
        session == null || session.ready || !session.handshake.initiator
        ? false
        : true;
    // A first message from them: answer as responder, unless both started
    // at once and this side has the lower id (it stays the initiator).
    if (message.length == 32) {
      if (starting && peerIdHex.compareTo(from) < 0) return const [];
      final handshake = await NoiseXXHandshake.start(
        initiator: false,
        staticSeed: _noiseSeed,
      );
      session = _Session(handshake, _now());
      _sessions[from] = session;
      await handshake.readMessage(message);
      return [
        _packet(
          BitchatType.noiseHandshake,
          from,
          await handshake.writeMessage(),
        ),
      ];
    }
    if (session == null || session.ready) return const [];
    final handshake = session.handshake;
    await handshake.readMessage(message);
    final answers = <BitchatPacket>[];
    if (handshake.writesNext) {
      answers.add(
        _packet(
          BitchatType.noiseHandshake,
          from,
          await handshake.writeMessage(),
        ),
      );
    }
    if (handshake.complete) {
      // The key they proved must be the one their id is the hash of.
      final remote = handshake.remoteStaticKey!;
      if (_hex(bitchatPeerId(remote)) != from) {
        _sessions.remove(from);
        return const [];
      }
      session.ready = true;
      for (final plaintext in _waiting.remove(from) ?? const <Uint8List>[]) {
        answers.add(await _encrypt(from, session, plaintext));
      }
    }
    return answers;
  }

  Future<List<BitchatPacket>> _handleTransport(
    String from,
    Uint8List payload,
  ) async {
    final session = _sessions[from];
    if (session == null || !session.ready || payload.length < 4 + 16) {
      return const [];
    }
    final counter = ByteData.sublistView(payload, 0, 4).getUint32(0);
    if (!session.window.accept(counter)) return const [];
    final plaintext = await session.handshake.receiveCipher!.decryptAt(
      counter,
      Uint8List.sublistView(payload, 4),
    );
    session.window.mark(counter);
    if (plaintext.isEmpty) return const [];
    final body = Uint8List.sublistView(plaintext, 1);
    switch (plaintext[0]) {
      case BitchatPayloadType.privateMessage:
        final message = _decodePrivateMessage(body);
        if (message == null) return const [];
        _events.add(BitchatMessageReceived(from, message.$1, message.$2));
        return [
          await _encrypt(
            from,
            session,
            Uint8List.fromList([
              BitchatPayloadType.delivered,
              ...utf8.encode(message.$1),
            ]),
          ),
        ];
      case BitchatPayloadType.delivered || BitchatPayloadType.readReceipt:
        _events.add(
          BitchatReceiptReceived(
            from,
            utf8.decode(body, allowMalformed: true),
            read: plaintext[0] == BitchatPayloadType.readReceipt,
          ),
        );
    }
    return const [];
  }

  Future<BitchatPacket> _encrypt(
    String peerIdHex,
    _Session session,
    Uint8List plaintext,
  ) async {
    final counter = session.sendCounter++;
    final ciphertext = await session.handshake.sendCipher!.encryptAt(
      counter,
      plaintext,
    );
    final header = ByteData(4)..setUint32(0, counter);
    return _packet(BitchatType.noiseEncrypted, peerIdHex, [
      ...header.buffer.asUint8List(),
      ...ciphertext,
    ]);
  }

  BitchatPacket _packet(int type, String recipientHex, List<int> payload) =>
      BitchatPacket(
        type: type,
        senderId: peerId,
        recipientId: _unhex(recipientHex),
        timestamp: _now().millisecondsSinceEpoch,
        payload: Uint8List.fromList(payload),
      );

  /// TLVs: 0x00 message id, 0x01 content (each up to 255 bytes).
  static Uint8List _privateMessage(String messageId, String text) {
    final id = utf8.encode(messageId);
    var content = utf8.encode(text);
    if (content.length > 255) {
      content = utf8.encode(
        utf8.decode(content.sublist(0, 255), allowMalformed: true),
      );
      if (content.length > 255) content = content.sublist(0, 255);
    }
    return Uint8List.fromList([
      0x00, id.length, ...id, //
      0x01, content.length, ...content,
    ]);
  }

  static (String, String)? _decodePrivateMessage(Uint8List data) {
    String? id;
    String? content;
    var offset = 0;
    while (offset + 2 <= data.length) {
      final type = data[offset];
      final length = data[offset + 1];
      offset += 2;
      if (offset + length > data.length) return null;
      final value = utf8.decode(
        data.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      switch (type) {
        case 0x00:
          id = value;
        case 0x01:
          content = value;
        default:
          return null;
      }
    }
    return id == null || content == null ? null : (id, content);
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = _hex(bytes).toUpperCase();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var index = 0; index + 1 < hex.length; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ]);

  Future<void> close() => _events.close();
}

class _Session {
  _Session(this.handshake, this.startedAt);
  final NoiseXXHandshake handshake;
  final DateTime startedAt;
  bool ready = false;
  int sendCounter = 0;
  final window = _ReplayWindow();
}

/// Accepts each transport counter once, within the last 1024.
class _ReplayWindow {
  static const int _size = 1024;
  int _highest = -1;
  final Set<int> _seen = {};

  bool accept(int counter) =>
      counter > _highest - _size && !_seen.contains(counter);

  void mark(int counter) {
    _seen.add(counter);
    if (counter > _highest) {
      _highest = counter;
      _seen.removeWhere((value) => value <= _highest - _size);
    }
  }
}
