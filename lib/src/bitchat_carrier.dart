import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bitchat/direct.dart';
import 'bitchat/gateway.dart';
import 'bitchat/mesh.dart';
import 'bitchat/packet.dart';
import 'carrier.dart';
import 'nostr/secp256k1.dart' show hexEncode;
import 'transport_models.dart';

/// Bytes of the MAC closing each Conest packet.
const int _macBytes = 8;

/// Frames sized so a bitchat packet never needs fragmenting; envelopes up
/// to 16 KiB.
const CarrierFraming bitchatCarrierFraming = CarrierFraming(
  maxSealedBytes: 16 * 1024,
  chunkBytes: bitchatPayloadBytes - _macBytes - carrierBinaryFrameHeaderBytes,
);

/// How long the ids of a pair of contacts stay the same on the air.
const Duration bitchatIdPeriod = Duration(hours: 1);

const String _addressPrefix = 'bc1:';

/// A device's address on the Bluetooth mesh: a random id, sent only to
/// contacts and never over the air. What goes over the air are ids derived
/// from it and the pair's key, which change every [bitchatIdPeriod].
bool isValidBitchatAddress(String address) =>
    address.length == _addressPrefix.length + 32 &&
    address.startsWith(_addressPrefix) &&
    RegExp(
      r'^[0-9a-f]{32}$',
    ).hasMatch(address.substring(_addressPrefix.length));

/// The saved Bluetooth mesh setup: this device's mesh address, and whether
/// (and as whom) bitchat users can reach it.
class BitchatCarrierConfig {
  const BitchatCarrierConfig({
    required this.address,
    this.visible = false,
    this.nickname = '',
    this.identitySeed,
    this.identityAt,
    this.gateway = false,
  });

  /// A new address, so turning the mesh off and on again unlinks the past.
  factory BitchatCarrierConfig.create() => BitchatCarrierConfig(
    address: '$_addressPrefix${hexEncode(randomBitchatBytes(16))}',
  );

  final String address;

  /// Announces a bitchat identity, so bitchat users nearby see this device
  /// and can write to it. Off: it only relays and reads the mesh chat.
  final bool visible;

  /// The name bitchat users see.
  final String nickname;

  /// 32 random bytes (hex) the bitchat identity's keys come from; replaced
  /// to start a new identity.
  final String? identitySeed;

  /// When [identitySeed] was made.
  final DateTime? identityAt;

  /// Shares this phone's internet with bitchat users nearby for bitchat's
  /// geohash chat, while [visible].
  final bool gateway;

  /// How long one bitchat identity is used before a new one is made, so
  /// bitchat users cannot follow this device for longer.
  static const Duration identityLifetime = Duration(days: 7);

  /// Longest nickname: what fits in an announce bitchat never compresses,
  /// with room for the gateway's capabilities (longer names in other
  /// scripts are cut further when announced).
  static const int maxNicknameLength = 26;

  /// With a fresh identity made now.
  BitchatCarrierConfig withNewIdentity(DateTime now) => BitchatCarrierConfig(
    address: address,
    visible: visible,
    nickname: nickname,
    identitySeed: hexEncode(randomBitchatBytes(32)),
    identityAt: now.toUtc(),
    gateway: gateway,
  );

  BitchatCarrierConfig copyWith({
    bool? visible,
    String? nickname,
    bool? gateway,
  }) => BitchatCarrierConfig(
    address: address,
    visible: visible ?? this.visible,
    nickname: nickname ?? this.nickname,
    identitySeed: identitySeed,
    identityAt: identityAt,
    gateway: gateway ?? this.gateway,
  );

  Map<String, Object?> toJson() => {
    'address': address,
    if (visible) 'visible': true,
    if (nickname.isNotEmpty) 'nickname': nickname,
    if (identitySeed != null) 'identitySeed': identitySeed,
    if (identityAt != null) 'identityAt': identityAt!.toIso8601String(),
    if (gateway) 'gateway': true,
  };

  static BitchatCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final address = json['address'];
    if (address is! String || !isValidBitchatAddress(address)) return null;
    final seed = json['identitySeed'];
    final validSeed =
        seed is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(seed);
    final nickname = json['nickname'];
    return BitchatCarrierConfig(
      address: address,
      visible: json['visible'] == true,
      nickname: nickname is String
          ? nickname.substring(0, min(nickname.length, maxNicknameLength))
          : '',
      identitySeed: validSeed ? seed : null,
      identityAt: validSeed
          ? DateTime.tryParse(json['identityAt'] as String? ?? '')?.toUtc()
          : null,
      gateway: json['gateway'] == true,
    );
  }
}

typedef BitchatConnector = Future<BitchatLinkLayer> Function();

/// The keys contact pairs derive their mesh ids and MACs from, looked up by
/// the contact's mesh address: one per contact with that address (normally
/// one), none for no contact.
typedef BitchatKeyLookup = Future<List<Uint8List>> Function(String address);

enum BitchatCarrierState { stopped, starting, running, failed }

/// The ids and MAC key one contact pair uses on the air. Each pair's ids
/// change at its own minute of the hour, so pairs do not all change
/// together.
class _Pair {
  _Pair(this.address, this.key)
    : offset =
          ByteData.sublistView(
            Uint8List.fromList(
              Hmac(
                sha256,
                key,
              ).convert(utf8.encode('conest.bitchat.offset')).bytes,
            ),
          ).getUint32(0) %
          bitchatIdPeriod.inMilliseconds;

  final String address;
  final Uint8List key;
  final int offset;

  int period(int milliseconds) =>
      (milliseconds + offset) ~/ bitchatIdPeriod.inMilliseconds;
}

/// The Bluetooth mesh side of the carrier: a bitchat mesh node that relays
/// for its neighbours and carries Conest frames to Conest peers.
///
/// Each frame travels as a bitchat private (Noise-type) packet whose sender
/// and recipient ids are derived from the pair's key, this hour and each
/// side's address, followed by a MAC over the ids, time and frame. Relays
/// and bitchat users see unrelated ids that change every hour, which they
/// cannot tell apart from bitchat's own private messages or link to a
/// device; only the contact can recognise and check them.
class BitchatCarrierChannel
    implements ManagedCarrierChannel, PeerAwareCarrierChannel {
  BitchatCarrierChannel({
    required this.config,
    required BitchatConnector connector,
    required BitchatKeyLookup keyFor,
    required this.onFrame,
    this.onStatusChanged,
    this.onPublic,
    DateTime Function()? now,
  }) : _connector = connector,
       _keyFor = keyFor,
       _now = now ?? DateTime.now;

  final BitchatCarrierConfig config;
  final BitchatConnector _connector;
  final BitchatKeyLookup _keyFor;
  final DateTime Function() _now;

  /// A frame from the contact whose mesh address is [sender].
  final void Function(String sender, Uint8List frame) onFrame;
  final void Function()? onStatusChanged;

  /// A public message from a bitchat user nearby.
  final void Function(BitchatPublicMessage message)? onPublic;

  /// The identity bitchat users talk to. It reads announces and public
  /// messages always, but this device announces it (and so can be written
  /// to) only while [_visible].
  BitchatDirect? _direct;
  bool _visible = false;

  /// Shares this phone's internet with bitchat users nearby (geohash chat)
  /// while set and visible.
  BitchatGateway? _gateway;
  final LinkedHashSet<String> _depositsTaken = LinkedHashSet();
  Timer? _announceTimer;
  Timer? _tickTimer;
  Set<String> _knownLinks = const {};
  final Random _jitter = Random();

  /// How often a visible identity announces itself (bitchat: 15 to 30 s
  /// while connected), plus up to [_announceJitter].
  static const Duration _announceEvery = Duration(seconds: 20);
  static const Duration _announceJitter = Duration(seconds: 8);
  static const Duration _tickEvery = Duration(seconds: 5);

  BitchatDirect? get direct => _direct;
  bool get visible => _visible;

  BitchatNode? _node;
  BitchatLinkLayer? _links;
  BitchatCarrierState _state = BitchatCarrierState.stopped;
  String? _lastError;
  int _generation = 0;

  Map<String, List<_Pair>> _pairs = {};
  Set<String> _peerAddresses = const {};
  bool _reloading = false;
  bool _reloadAgain = false;
  StreamSubscription<String?>? _problems;

  /// Recipient id (hex) → the pair it belongs to and its period, for the
  /// periods around the minute [_tableMinute].
  Map<String, (_Pair, int)> _table = const {};
  int? _tableMinute;

  /// MACs of frames already read, so a replay is not read twice even after
  /// relays have forgotten it. Only authentic frames get in, so strangers
  /// cannot flush it.
  final LinkedHashSet<String> _readMacs = LinkedHashSet();
  static const int _maxReadMacs = 16384;

  BitchatCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress => config.address;

  @override
  String get routeLabel => 'nearby phones';

  @override
  void updatePeers(Set<String> addresses) {
    // Settings are saved often: reloads run one at a time, and calls during
    // one only mark that another is needed, which then uses the latest set.
    // Every reload reads keys afresh, so re-keyed contacts are picked up.
    _peerAddresses = {...addresses};
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    _reloading = true;
    unawaited(() async {
      do {
        _reloadAgain = false;
        final wanted = _peerAddresses;
        final next = <String, List<_Pair>>{};
        for (final address in wanted) {
          try {
            final keys = await _keyFor(address);
            if (keys.isNotEmpty) {
              next[address] = [for (final key in keys) _Pair(address, key)];
            }
          } catch (_) {
            // That contact is skipped until the next reload.
          }
        }
        _pairs = next;
        _tableMinute = null;
      } while (_reloadAgain);
      _reloading = false;
    }());
  }

  @override
  void start() {
    if (_state != BitchatCarrierState.stopped &&
        _state != BitchatCarrierState.failed) {
      return;
    }
    final generation = ++_generation;
    _setState(BitchatCarrierState.starting);
    unawaited(() async {
      try {
        final links = await _connector();
        if (generation != _generation) {
          await links.close();
          return;
        }
        _links = links;
        _node = BitchatNode(
          links: links,
          onPrivate: _private,
          onPacket: _packet,
          wantsRecipient: (id) =>
              _isDirectRecipient(id) ||
              _recipients(
                _now().millisecondsSinceEpoch,
              ).containsKey(hexEncode(id)),
          now: _now,
        );
        _problems = links.problems.listen((problem) {
          _lastError = problem;
          onStatusChanged?.call();
        });
        _lastError = null;
        _setState(BitchatCarrierState.running);
        _scheduleDirect();
      } catch (error) {
        if (generation != _generation) return;
        _lastError = '$error';
        _setState(BitchatCarrierState.failed);
      }
    }());
  }

  @override
  Future<void> stop() async {
    _generation++;
    _announceTimer?.cancel();
    _tickTimer?.cancel();
    _announceTimer = null;
    _tickTimer = null;
    final node = _node;
    final links = _links;
    _node = null;
    _links = null;
    await _problems?.cancel();
    _problems = null;
    await node?.stop();
    await links?.close();
    _setState(BitchatCarrierState.stopped);
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    final node = _node;
    if (node == null) throw StateError('The Bluetooth mesh is not running.');
    if (!isValidBitchatAddress(address)) {
      throw ArgumentError('Not a Bluetooth mesh address.');
    }
    if (frame.length + _macBytes > bitchatPayloadBytes) {
      throw ArgumentError('The frame is too large for one bitchat packet.');
    }
    var pairs = _pairs[address];
    if (pairs == null) {
      final keys = await _keyFor(address);
      if (keys.isEmpty) throw StateError('No contact has this mesh address.');
      pairs = [for (final key in keys) _Pair(address, key)];
    }
    final timestamp = _now().millisecondsSinceEpoch;
    // Normally one pair; when contacts share an address, the frame goes to
    // each and only the right one can read it.
    for (final pair in pairs) {
      final period = pair.period(timestamp);
      final sender = _id(pair.key, 's', config.address, period);
      final recipient = _id(pair.key, 'r', address, period);
      await node.send(
        BitchatPacket(
          type: BitchatType.noiseEncrypted,
          senderId: sender,
          recipientId: recipient,
          timestamp: timestamp,
          payload: Uint8List.fromList([
            ...frame,
            ..._mac(pair.key, sender, recipient, timestamp, frame),
          ]),
          // bitchat signs its private packets but nobody checks their
          // signatures; random bytes make these look the same.
          signature: randomBitchatBytes(64),
        ),
      );
    }
  }

  BitchatPrivate _private(BitchatPacket packet, Uint8List payload) {
    if (_isDirectRecipient(packet.recipientId!)) {
      final direct = _direct!;
      unawaited(
        direct
            .handleNoise(
              packet.compressed
                  ? BitchatPacket(
                      type: packet.type,
                      senderId: packet.senderId,
                      recipientId: packet.recipientId,
                      timestamp: packet.timestamp,
                      payload: payload,
                      version: packet.version,
                    )
                  : packet,
            )
            .then((packets) => _sendFor(direct, packets))
            .catchError((Object _) => 0),
      );
      return BitchatPrivate.accepted;
    }
    final now = _now().millisecondsSinceEpoch;
    final entry = _recipients(now)[hexEncode(packet.recipientId!)];
    if (entry == null) return BitchatPrivate.notMine;
    final (pair, period) = entry;
    if (!_equal(packet.senderId, _id(pair.key, 's', pair.address, period)) ||
        payload.length <= _macBytes) {
      // Addressed to this device but not from the contact: not relayed.
      return BitchatPrivate.rejected;
    }
    final frame = Uint8List.sublistView(payload, 0, payload.length - _macBytes);
    final mac = Uint8List.sublistView(payload, payload.length - _macBytes);
    if (_equal(
      mac,
      _mac(
        pair.key,
        packet.senderId,
        packet.recipientId!,
        packet.timestamp,
        frame,
      ),
    )) {
      final key = hexEncode(mac);
      if (!_readMacs.add(key)) return BitchatPrivate.rejected;
      if (_readMacs.length > _maxReadMacs) _readMacs.remove(_readMacs.first);
      onFrame(pair.address, frame);
      return BitchatPrivate.accepted;
    }
    return BitchatPrivate.rejected;
  }

  /// Uses [direct] as the identity bitchat users see, announced while
  /// [visible]; null leaves bitchat chats alone.
  void useDirect(BitchatDirect? direct, {required bool visible}) {
    _direct = direct;
    _visible = direct != null && visible;
    direct?.capabilities = _gateway == null ? 0 : bitchatGatewayCapability;
    _scheduleDirect();
  }

  /// Acts as [gateway] for bitchat users nearby (announced while visible),
  /// or stops.
  void useGateway(BitchatGateway? gateway) {
    _gateway = gateway;
    _direct?.capabilities = gateway == null ? 0 : bitchatGatewayCapability;
    announceNow();
  }

  /// Passes an event from the relays on to everyone nearby: unsigned, as
  /// bitchat sends it (the event carries its author's signature).
  Future<void> broadcastCarrier(Uint8List payload) async {
    final direct = _direct;
    final node = _node;
    if (direct == null || node == null || !_visible) return;
    await node.send(
      BitchatPacket(
        type: bitchatNostrCarrierType,
        senderId: direct.peerId,
        timestamp: _now().millisecondsSinceEpoch,
        payload: payload,
      ),
    );
  }

  /// Sends [text] to everyone nearby (as several messages when long);
  /// returns the parts that went out and how many there were. Fewer went
  /// out when the mesh failed or the person hid meanwhile.
  Future<(List<BitchatPublicMessage>, int)> sendPublic(String text) async {
    final direct = _requireVisible();
    final packets = await direct.publicMessages(text);
    final sent = <BitchatPublicMessage>[];
    for (final packet in packets) {
      try {
        if (await _sendFor(direct, [packet]) == 0) break;
      } catch (_) {
        if (sent.isEmpty) rethrow;
        break;
      }
      final part = utf8.decode(packet.payload);
      sent.add(
        BitchatPublicMessage(
          id: bitchatPublicMessageId(direct.peerIdHex, packet.timestamp, part),
          peerId: direct.peerIdHex,
          nickname: direct.announcedNickname,
          text: part,
          sentAt: DateTime.fromMillisecondsSinceEpoch(
            packet.timestamp,
            isUtc: true,
          ),
        ),
      );
    }
    return (sent, packets.length);
  }

  /// Sends [text] to the bitchat user [peerIdHex]; returns its message id.
  Future<String> sendDirectText(String peerIdHex, String text) async {
    final direct = _requireVisible();
    final (packets, messageId) = await direct.sendText(peerIdHex, text);
    await _sendFor(direct, packets);
    return messageId;
  }

  /// Tells [peerIdHex] that its message [messageId] was read.
  Future<void> sendReadReceipt(String peerIdHex, String messageId) async {
    final direct = _requireVisible();
    await _sendFor(direct, await direct.sendReadReceipt(peerIdHex, messageId));
  }

  BitchatDirect _requireVisible() {
    final direct = _direct;
    if (direct == null || !_visible) {
      throw StateError('Turn on "Reachable by bitchat users" first.');
    }
    if (_node == null) throw StateError('The Bluetooth mesh is not running.');
    return direct;
  }

  bool _isDirectRecipient(Uint8List id) {
    final direct = _direct;
    return direct != null && _visible && _equal(id, direct.peerId);
  }

  /// Sends what [direct] made, unless it is no longer the identity in use
  /// or no longer visible (the person hid meanwhile); returns how many
  /// went out.
  Future<int> _sendFor(
    BitchatDirect direct,
    List<BitchatPacket> packets,
  ) async {
    var sent = 0;
    for (final packet in packets) {
      final node = _node;
      if (node == null || !identical(_direct, direct) || !_visible) break;
      await node.send(packet);
      sent++;
    }
    return sent;
  }

  /// Announces, handshakes and public messages. False for a copy whose
  /// signature fails against a known key: the mesh then neither remembers
  /// nor relays it, so the genuine packet still gets through.
  Future<bool> _packet(BitchatPacket packet) async {
    final direct = _direct;
    if (direct == null) return true;
    switch (packet.type) {
      case BitchatType.announce:
        return direct.handleAnnounce(packet);
      case BitchatType.noiseHandshake:
        if (packet.recipientId != null &&
            _isDirectRecipient(packet.recipientId!)) {
          await _sendFor(direct, await direct.handleNoise(packet));
        }
      case BitchatType.message:
        final (message, forged) = await direct.checkPublic(packet);
        if (forged) return false;
        if (message != null) onPublic?.call(message);
      case bitchatNostrCarrierType:
        return _carrier(direct, packet);
    }
    return true;
  }

  /// An event carried to or from a gateway. One addressed to us must carry
  /// its sender's signature, so deposits are counted per real sender.
  Future<bool> _carrier(BitchatDirect direct, BitchatPacket packet) async {
    final gateway = _gateway;
    if (gateway == null || !_visible) return true;
    final recipient = packet.recipientId;
    final toUs = recipient != null && _isDirectRecipient(recipient);
    // Addressed to someone else: only relayed.
    if (recipient != null && !toUs) return true;
    if (toUs) {
      // A copy of a deposit already taken is not checked again.
      final key = packet.dedupKey;
      if (_depositsTaken.contains(key)) return false;
      final signed = await direct.signedByPeer(packet);
      // For us, so never passed on: unless checked, it is dropped.
      if (signed != true) return false;
      _depositsTaken.add(key);
      if (_depositsTaken.length > 256)
        _depositsTaken.remove(_depositsTaken.first);
    }
    final payload = packet.expandedPayload(
      maxBytes: BitchatNostrCarrier.maxEventJsonBytes + 64,
    );
    if (payload == null) return true;
    unawaited(
      gateway
          .handleCarrier(
            payload,
            from: hexEncode(packet.senderId),
            directedToUs: toUs,
          )
          .catchError((Object _) {}),
    );
    // A deposit for us goes no further, as bitchat keeps its own.
    return !toUs;
  }

  /// Announces a visible identity now and every so often, and retries
  /// handshakes, while the mesh runs.
  void _scheduleDirect() {
    _announceTimer?.cancel();
    _tickTimer?.cancel();
    _announceTimer = null;
    _tickTimer = null;
    final direct = _direct;
    if (direct == null || _node == null) return;
    _knownLinks = {...?_links?.linkLimits.keys};
    _tickTimer = Timer.periodic(_tickEvery, (_) {
      unawaited(
        direct
            .tick()
            .then((packets) => _sendFor(direct, packets))
            .catchError((Object _) => 0),
      );
      // A new neighbour hears us at once, as bitchat does on connecting.
      final links = {...?_links?.linkLimits.keys};
      final joined = links.difference(_knownLinks).isNotEmpty;
      _knownLinks = links;
      if (joined && _visible) announceNow();
    });
    if (_visible) announceNow();
  }

  /// Announces a visible identity now, then again every 20 to 28 seconds.
  void announceNow() {
    final direct = _direct;
    if (direct == null || !_visible || _node == null) return;
    _announceTimer?.cancel();
    unawaited(
      direct
          .announce()
          .then((packet) => _sendFor(direct, [packet]))
          .catchError((Object _) => 0),
    );
    _announceTimer = Timer(
      _announceEvery +
          Duration(
            milliseconds: _jitter.nextInt(_announceJitter.inMilliseconds),
          ),
      announceNow,
    );
  }

  /// Ids this device answers to, for each pair's current period and its
  /// neighbours (clocks differ); rebuilt every minute.
  Map<String, (_Pair, int)> _recipients(int now) {
    final minute = now ~/ 60000;
    if (_tableMinute == minute) return _table;
    _table = {
      for (final pair in _pairs.values.expand((pairs) => pairs))
        for (final candidate in [
          pair.period(now) - 1,
          pair.period(now),
          pair.period(now) + 1,
        ])
          hexEncode(_id(pair.key, 'r', config.address, candidate)): (
            pair,
            candidate,
          ),
    };
    _tableMinute = minute;
    return _table;
  }

  /// An 8-byte id: [role] `s` names the sender with its own [address], `r`
  /// the recipient with its.
  static Uint8List _id(
    List<int> key,
    String role,
    String address,
    int period,
  ) => Uint8List.fromList(
    Hmac(sha256, key)
        .convert(utf8.encode('conest.bitchat.id|$role|$address|$period'))
        .bytes
        .sublist(0, 8),
  );

  static Uint8List _mac(
    List<int> key,
    List<int> sender,
    List<int> recipient,
    int timestamp,
    List<int> frame,
  ) {
    final time = ByteData(8)..setUint64(0, timestamp);
    return Uint8List.fromList(
      Hmac(sha256, key)
          .convert([
            ...utf8.encode('conest.bitchat.mac'),
            ...sender,
            ...recipient,
            ...time.buffer.asUint8List(),
            ...frame,
          ])
          .bytes
          .sublist(0, _macBytes),
    );
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var index = 0; index < a.length; index++) {
      difference |= a[index] ^ b[index];
    }
    return difference == 0;
  }

  void _setState(BitchatCarrierState state) {
    if (_state == state) return;
    _state = state;
    onStatusChanged?.call();
  }
}

/// A Bluetooth mesh carrier adapter.
CarrierTransportAdapter createBitchatCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.bitchat,
  sealer: sealer,
  framing: bitchatCarrierFraming,
  frameSpacing: const Duration(milliseconds: 60),
  sendAttemptTimeout: const Duration(seconds: 90),
  isValidAddress: isValidBitchatAddress,
  now: now,
);
