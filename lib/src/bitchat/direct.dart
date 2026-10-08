import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
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

/// How long each side waits for a handshake to finish (as bitchat does).
const Duration bitchatInitiatorDeadline = Duration(seconds: 10);
const Duration bitchatResponderDeadline = Duration(seconds: 20);

/// Most messages one mesh chat text goes as: bitchat on iPhones takes 5
/// from a sender at once, then one a second, and drops the rest.
const int bitchatMaxPublicParts = 5;

/// Longest text kept from a message received; the rest is cut.
const int bitchatMaxReceivedChars = 2000;

/// bitchat compresses a payload of this many bytes or more, and signs and
/// checks it compressed, as its own compressor makes it. Conest cannot
/// make the same bytes, so what it signs stays below this: longer mesh
/// chat text goes as several messages, and the announced name is cut.
const int bitchatCompressionThreshold = 100;

/// How far a public message's time may be from ours: the mesh drops
/// anything further (bitchat shows hours of history carried between
/// groups of people; Conest shows only what is current).
const Duration bitchatPublicMaxAge = Duration(minutes: 10);

/// A message to everyone nearby (bitchat's mesh chat), signed by a sender
/// whose announce this device has checked.
class BitchatPublicMessage {
  const BitchatPublicMessage({
    required this.id,
    required this.peerId,
    required this.nickname,
    required this.text,
    required this.sentAt,
  });

  /// The id every bitchat device derives for this message (the wire carries
  /// none): the same on each phone, so copies can be told apart.
  final String id;
  final String peerId;
  final String nickname;
  final String text;
  final DateTime sentAt;
}

/// The id bitchat derives for a public message.
String bitchatPublicMessageId(String senderIdHex, int timestamp, String text) {
  final input = '${senderIdHex.toLowerCase()}|$timestamp|${text.trim()}';
  return hashing.sha256.convert(utf8.encode(input)).toString().substring(0, 32);
}

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
  Uint8List signingKey;
  DateTime lastSeen;

  /// Set once a handshake has proven that the announcer holds the Noise
  /// key.
  bool confirmed = false;
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
  final Map<String, Future<void>> _queues = {};
  final _events = StreamController<BitchatDirectEvent>.broadcast();

  /// Handshakes answered per peer and overall in the current minute.
  int _handshakeMinute = 0;
  int _handshakesThisMinute = 0;
  final Map<String, int> _handshakesByPeer = {};

  static const int _maxPeers = 512;
  static const int _maxSessions = 256;
  static const int _maxWaitingPerPeer = 32;
  static const int _maxHandshakesPerPeerPerMinute = 10;
  static const int _maxHandshakesPerMinute = 30;
  static const int _maxCounter = 0xffffffff;
  static const Duration _announceMaxAge = Duration(seconds: 900);

  String get peerIdHex => _hex(peerId);

  /// The nickname as announced: cut so the announce stays below
  /// [bitchatCompressionThreshold] (its keys and headers take 70 bytes).
  String get announcedNickname =>
      bitchatCutUtf8(nickname, bitchatCompressionThreshold - 1 - 70);
  Stream<BitchatDirectEvent> get events => _events.stream;
  Iterable<BitchatPeer> get peers => _peers.values;
  BitchatPeer? peer(String peerIdHex) => _peers[peerIdHex];

  /// Peers another identity of this device has seen (it was just replaced),
  /// kept unconfirmed: their signing keys are pinned only by a handshake
  /// with this identity.
  void adoptPeers(Iterable<BitchatPeer> peers) {
    for (final peer in peers) {
      if (_peers.length >= _maxPeers) return;
      if (peer.peerId == peerIdHex || _peers.containsKey(peer.peerId)) {
        continue;
      }
      _peers[peer.peerId] = BitchatPeer(
        peerId: peer.peerId,
        nickname: peer.nickname,
        noiseKey: peer.noiseKey,
        signingKey: peer.signingKey,
        lastSeen: peer.lastSeen,
      );
    }
  }

  /// Whether a working session with [peerIdHex] exists.
  bool hasSession(String peerIdHex) => _sessions[peerIdHex]?.ready ?? false;

  /// Runs [work] for one peer at a time, in arrival order.
  Future<T> _serial<T>(String peer, Future<T> Function() work) {
    final previous = _queues[peer] ?? Future<void>.value();
    final result = previous.then((_) => work());
    final settled = result.then<void>((_) {}, onError: (Object _) {});
    _queues[peer] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_queues[peer], settled)) _queues.remove(peer);
      }),
    );
    return result;
  }

  /// A signed announce for this identity, as bitchat expects: signed over
  /// the packet with TTL 0, no signature, and padding.
  Future<BitchatPacket> announce() async {
    final unsigned = BitchatPacket(
      type: BitchatType.announce,
      senderId: peerId,
      timestamp: _now().millisecondsSinceEpoch,
      payload: BitchatAnnouncement(
        nickname: announcedNickname,
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
  /// False only when the signature fails: that copy is not passed on.
  Future<bool> handleAnnounce(BitchatPacket packet) async {
    final payload = packet.expandedPayload();
    if (payload == null) return true;
    final announcement = BitchatAnnouncement.decode(payload);
    final signature = packet.signature;
    if (announcement == null ||
        signature == null ||
        announcement.signingPublicKey.length != 32 ||
        announcement.noisePublicKey.length != 32) {
      return true;
    }
    final id = _hex(bitchatPeerId(announcement.noisePublicKey));
    if (id != _hex(packet.senderId) || id == peerIdHex) return true;
    final age = _now().millisecondsSinceEpoch - packet.timestamp;
    if (age.abs() > _announceMaxAge.inMilliseconds) return true;
    final known = _peers[id];
    // The first signing key checked for an id stays, as bitchat keeps it:
    // someone re-announcing a peer's Noise key with their own signing key
    // cannot write in the mesh chat as that peer (or silence them).
    if (known != null &&
        !_equal(known.signingKey, announcement.signingPublicKey)) {
      return true;
    }
    final sameKey = known != null;
    // Someone announcing every few seconds is checked every ten.
    if (sameKey &&
        _now().difference(known.lastSeen) < const Duration(seconds: 10)) {
      return true;
    }
    if (!_announceBudget.take()) return true;
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
    if (!valid) return false;
    if (known != null) {
      known
        ..nickname = announcement.nickname
        ..lastSeen = _now();
    } else {
      if (_peers.length >= _maxPeers) {
        // Never forget someone a session is open with.
        final evictable = _peers.values
            .where((peer) => !hasSession(peer.peerId))
            .toList();
        if (evictable.isEmpty) return true;
        final oldest = evictable.reduce(
          (a, b) => a.lastSeen.isBefore(b.lastSeen) ? a : b,
        );
        _peers.remove(oldest.peerId);
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
    return true;
  }

  /// Signed messages to everyone nearby, as bitchat sends them: no
  /// recipient, the text as the payload. Text of
  /// [bitchatCompressionThreshold] bytes or more is split at spaces where it
  /// can be, one message per part, a millisecond apart.
  /// Throws [ArgumentError] for text that needs more than
  /// [bitchatMaxPublicParts] messages.
  Future<List<BitchatPacket>> publicMessages(String text) async {
    final start = _now().millisecondsSinceEpoch;
    final parts = bitchatSplitUtf8(text, bitchatCompressionThreshold - 1);
    if (parts.length > bitchatMaxPublicParts) {
      throw ArgumentError(
        'Too long for the mesh chat: bitchat users would get only the start.',
      );
    }
    return [
      for (var index = 0; index < parts.length; index++)
        await _signed(
          BitchatPacket(
            type: BitchatType.message,
            senderId: peerId,
            timestamp: start + index,
            payload: Uint8List.fromList(utf8.encode(parts[index])),
          ),
        ),
    ];
  }

  Future<BitchatPacket> _signed(BitchatPacket unsigned) async {
    final signature = await Ed25519().sign(
      unsigned.bytesToSign(),
      keyPair: _signing,
    );
    return unsigned.copyWith(signature: Uint8List.fromList(signature.bytes));
  }

  /// A public message, when it comes from a peer whose announce was checked
  /// and carries that peer's signature; null otherwise (and for our own
  /// copies relayed back).
  Future<BitchatPublicMessage?> readPublic(BitchatPacket packet) async =>
      (await checkPublic(packet)).$1;

  /// As [readPublic], and whether the packet is forged: its signature
  /// fails against the key the claimed sender announced.
  Future<(BitchatPublicMessage?, bool forged)> checkPublic(
    BitchatPacket packet,
  ) async {
    const unread = (null, false);
    if (packet.type != BitchatType.message || packet.payload.length > 0xffff) {
      return unread;
    }
    final recipient = packet.recipientId;
    if (recipient != null && recipient.any((byte) => byte != 0xff)) {
      return unread;
    }
    final from = _hex(packet.senderId);
    final peer = _peers[from];
    final signature = packet.signature;
    if (from == peerIdHex || peer == null || signature == null) return unread;
    final age = _now().millisecondsSinceEpoch - packet.timestamp;
    if (age.abs() > bitchatPublicMaxAge.inMilliseconds) return unread;
    // Checked as signed: compressed, as carried.
    if (!_messageBudget.take()) return unread;
    final valid = await Ed25519().verify(
      packet.bytesToSign(),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(peer.signingKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) return (null, true);
    final payload = packet.expandedPayload(maxBytes: 0xffff);
    if (payload == null) return unread;
    String text;
    try {
      text = utf8.decode(payload);
    } on FormatException {
      return unread;
    }
    if (text.trim().isEmpty) return unread;
    final id = bitchatPublicMessageId(from, packet.timestamp, text);
    if (text.length > bitchatMaxReceivedChars) {
      text =
          '${String.fromCharCodes(text.runes.take(bitchatMaxReceivedChars))}…';
    }
    return (
      BitchatPublicMessage(
        id: id,
        peerId: from,
        nickname: peer.nickname,
        text: text,
        sentAt: DateTime.fromMillisecondsSinceEpoch(
          packet.timestamp,
          isUtc: true,
        ),
      ),
      false,
    );
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
    final packets = await _serial(
      peerIdHex,
      () => _send(peerIdHex, BitchatPayloadType.privateMessage, body),
    );
    return (packets, messageId);
  }

  /// Tells [peerIdHex] its message [messageId] was read.
  Future<List<BitchatPacket>> sendReadReceipt(
    String peerIdHex,
    String messageId,
  ) => _serial(
    peerIdHex,
    () => _send(
      peerIdHex,
      BitchatPayloadType.readReceipt,
      utf8.encode(messageId),
    ),
  );

  Future<List<BitchatPacket>> _send(
    String peerIdHex,
    int type,
    List<int> body,
  ) async {
    final plaintext = Uint8List.fromList([type, ...body]);
    final session = _sessions[peerIdHex];
    if (session != null && _usable(session)) {
      return [await _encrypt(peerIdHex, session, plaintext)];
    }
    final waiting = _waiting.putIfAbsent(peerIdHex, () => []);
    if (waiting.length >= _maxWaitingPerPeer) waiting.removeAt(0);
    waiting.add(plaintext);
    // A handshake of ours still in time: wait for it.
    if (session != null &&
        !session.ready &&
        session.handshake.initiator &&
        !_expired(session)) {
      return const [];
    }
    return [await _startHandshake(peerIdHex)];
  }

  bool _usable(_Session session) =>
      session.ready &&
      session.sendCounter < _maxCounter &&
      _now().difference(session.startedAt) < bitchatSessionLifetime;

  bool _expired(_Session session) =>
      !session.ready &&
      _now().difference(session.startedAt) >
          (session.handshake.initiator
              ? bitchatInitiatorDeadline
              : bitchatResponderDeadline);

  Future<BitchatPacket> _startHandshake(String peerIdHex) async {
    final handshake = await NoiseXXHandshake.start(
      initiator: true,
      staticSeed: _noiseSeed,
    );
    _install(peerIdHex, _Session(handshake, _now()));
    return _packet(
      BitchatType.noiseHandshake,
      peerIdHex,
      await handshake.writeMessage(),
    );
  }

  /// Puts a new handshake in place; a working session it replaces keeps
  /// decrypting until the new one completes.
  void _install(String peerIdHex, _Session session) {
    final current = _sessions[peerIdHex];
    session.previous = (current?.ready ?? false) ? current : current?.previous;
    if (current == null && _sessions.length >= _maxSessions) {
      final entries = _sessions.entries.toList();
      final waiting = entries.where((entry) => !entry.value.ready).toList();
      final pool = waiting.isEmpty ? entries : waiting;
      final oldest = pool.reduce(
        (a, b) => a.value.startedAt.isBefore(b.value.startedAt) ? a : b,
      );
      _sessions.remove(oldest.key);
    }
    _sessions[peerIdHex] = session;
  }

  /// Gives up on [peerIdHex]'s handshake, going back to the session it
  /// was replacing, if any.
  void _abandon(String peerIdHex) {
    final session = _sessions[peerIdHex];
    if (session == null || session.ready) return;
    final previous = session.previous;
    if (previous != null) {
      _sessions[peerIdHex] = previous;
    } else {
      _sessions.remove(peerIdHex);
    }
  }

  /// Handshakes that ran out of time: abandoned, and started again when
  /// messages are waiting. Call every few seconds.
  Future<List<BitchatPacket>> tick() async {
    final packets = <BitchatPacket>[];
    for (final peer in _sessions.keys.toList()) {
      packets.addAll(
        await _serial(peer, () async {
          final session = _sessions[peer];
          if (session == null || !_expired(session)) {
            return const <BitchatPacket>[];
          }
          _abandon(peer);
          if (!(_waiting[peer]?.isNotEmpty ?? false)) {
            return const <BitchatPacket>[];
          }
          final current = _sessions[peer];
          if (current != null && _usable(current)) return _flush(peer);
          return [await _startHandshake(peer)];
        }),
      );
    }
    return packets;
  }

  /// A Noise packet (handshake or transport) addressed to this identity;
  /// returns the packets to send in answer.
  Future<List<BitchatPacket>> handleNoise(BitchatPacket packet) async {
    final from = _hex(packet.senderId);
    if (packet.recipientId == null ||
        !_equal(packet.recipientId!, peerId) ||
        from == peerIdHex) {
      return const [];
    }
    return _serial(from, () async {
      if (packet.type == BitchatType.noiseHandshake) {
        try {
          return await _handleHandshake(from, packet.payload);
        } on FormatException {
          _abandon(from);
        } on StateError {
          _abandon(from);
        }
        return const <BitchatPacket>[];
      }
      try {
        return await _handleTransport(from, packet.payload);
      } on FormatException {
        return const <BitchatPacket>[];
      }
    });
  }

  /// Signature checks per minute, for announces and for the mesh chat
  /// apart: strangers in range cannot keep the phone busy checking, and a
  /// crowd announcing does not crowd out what is said.
  late final _BitchatBudget _announceBudget = _BitchatBudget(300, _now);
  late final _BitchatBudget _messageBudget = _BitchatBudget(300, _now);

  bool _handshakeAllowed(String from) {
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    if (minute != _handshakeMinute) {
      _handshakeMinute = minute;
      _handshakesThisMinute = 0;
      _handshakesByPeer.clear();
    }
    final byPeer = (_handshakesByPeer[from] ?? 0) + 1;
    if (byPeer > _maxHandshakesPerPeerPerMinute ||
        _handshakesThisMinute >= _maxHandshakesPerMinute) {
      return false;
    }
    _handshakesByPeer[from] = byPeer;
    _handshakesThisMinute++;
    return true;
  }

  Future<List<BitchatPacket>> _handleHandshake(
    String from,
    Uint8List message,
  ) async {
    final session = _sessions[from];
    // A first message from them: answer as responder. When both started
    // at once, the side with the lower id stays the initiator, as long as
    // its own attempt is still in time.
    if (message.length == 32) {
      final ours =
          session != null &&
          !session.ready &&
          session.handshake.initiator &&
          !_expired(session);
      if (ours && peerIdHex.compareTo(from) < 0) return const [];
      if (!_handshakeAllowed(from)) return const [];
      final handshake = await NoiseXXHandshake.start(
        initiator: false,
        staticSeed: _noiseSeed,
      );
      await handshake.readMessage(message);
      _install(from, _Session(handshake, _now()));
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
        _abandon(from);
        return const [];
      }
      session
        ..ready = true
        ..previous = null;
      final known = _peers[from];
      if (known != null && _equal(known.noiseKey, remote)) {
        known.confirmed = true;
      }
      answers.addAll(await _flush(from));
    }
    return answers;
  }

  Future<List<BitchatPacket>> _flush(String peer) async {
    final session = _sessions[peer];
    if (session == null || !_usable(session)) return const [];
    return [
      for (final plaintext in _waiting.remove(peer) ?? const <Uint8List>[])
        await _encrypt(peer, session, plaintext),
    ];
  }

  Future<List<BitchatPacket>> _handleTransport(
    String from,
    Uint8List payload,
  ) async {
    if (payload.length < 4 + 16) return const [];
    final counter = ByteData.sublistView(payload, 0, 4).getUint32(0);
    final current = _sessions[from];
    // The working session, or the one a new handshake is replacing.
    for (final session in [
      if (current != null && current.ready) current,
      ?current?.previous,
    ]) {
      if (!session.window.accept(counter)) continue;
      final Uint8List plaintext;
      try {
        plaintext = await session.handshake.receiveCipher!.decryptAt(
          counter,
          Uint8List.sublistView(payload, 4),
        );
      } on FormatException {
        continue;
      }
      session.window.mark(counter);
      return _deliver(from, session, plaintext);
    }
    return const [];
  }

  Future<List<BitchatPacket>> _deliver(
    String from,
    _Session session,
    Uint8List plaintext,
  ) async {
    if (plaintext.isEmpty) return const [];
    final body = Uint8List.sublistView(plaintext, 1);
    switch (plaintext[0]) {
      case BitchatPayloadType.privateMessage:
        final message = _decodePrivateMessage(body);
        if (message == null) return const [];
        _events.add(BitchatMessageReceived(from, message.$1, message.$2));
        final receipt = Uint8List.fromList([
          BitchatPayloadType.delivered,
          ...utf8.encode(message.$1),
        ]);
        final current = _sessions[from];
        if (current != null && _usable(current)) {
          return [await _encrypt(from, current, receipt)];
        }
        if (_usable(session)) return [await _encrypt(from, session, receipt)];
        return const [];
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

  /// The working session this handshake replaces, still used to decrypt
  /// until this one completes.
  _Session? previous;
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

/// [text] cut to at most [maxBytes] of UTF-8, between characters.
String bitchatCutUtf8(String text, int maxBytes) {
  if (utf8.encode(text).length <= maxBytes) return text;
  final out = StringBuffer();
  var bytes = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final size = utf8.encode(char).length;
    if (bytes + size > maxBytes) break;
    out.write(char);
    bytes += size;
  }
  return out.toString();
}

/// [text] in parts of at most [maxBytes] of UTF-8, split after a space
/// where one is near the end of a part.
List<String> bitchatSplitUtf8(String text, int maxBytes) {
  final parts = <String>[];
  var rest = text.trim();
  while (rest.isNotEmpty) {
    var part = bitchatCutUtf8(rest, maxBytes);
    if (part.length < rest.length) {
      final space = part.lastIndexOf(' ');
      if (space > part.length ~/ 2) part = part.substring(0, space + 1);
    }
    parts.add(part.trim());
    rest = rest.substring(part.length).trimLeft();
  }
  return parts.where((part) => part.isNotEmpty).toList();
}

/// A number of things allowed per minute.
class _BitchatBudget {
  _BitchatBudget(this.perMinute, this._now);

  final int perMinute;
  final DateTime Function() _now;
  int _minute = 0;
  int _used = 0;

  bool take() {
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    if (minute != _minute) {
      _minute = minute;
      _used = 0;
    }
    if (_used >= perMinute) return false;
    _used++;
    return true;
  }
}
