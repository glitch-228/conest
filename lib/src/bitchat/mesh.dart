import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'packet.dart';

/// The Bluetooth side of the mesh: every connected neighbour, as links that
/// carry whole bitchat packets.
abstract interface class BitchatLinkLayer {
  /// Packets from neighbours, with the link they came on.
  Stream<(String, Uint8List)> get received;

  /// Sends [packet] to every neighbour except the link [except].
  Future<void> broadcast(Uint8List packet, {String? except});

  Future<void> close();
}

/// Marks the payload of a Conest frame inside a bitchat Noise packet.
const List<int> _conestMagic = [0x43, 0x4e, 0x53, 0x54]; // "CNST"
const int _conestVersion = 1;

/// Largest Conest frame per packet: small enough that bitchat never needs
/// to fragment the packet (512-byte BLE frames with padding).
const int bitchatFrameBytes = 435;

/// This device's bitchat identity: a Noise static key (whose hash is the
/// peer id) and an Ed25519 signing key. Separate from the Conest identity.
class BitchatIdentity {
  BitchatIdentity._(this.noisePublicKey, this._signing, this.signingPublicKey);

  static Future<BitchatIdentity> fromSeeds(
    List<int> noiseSeed,
    List<int> signingSeed,
  ) async {
    final noise = await X25519().newKeyPairFromSeed(noiseSeed);
    final signing = await Ed25519().newKeyPairFromSeed(signingSeed);
    return BitchatIdentity._(
      Uint8List.fromList((await noise.extractPublicKey()).bytes),
      signing,
      Uint8List.fromList((await signing.extractPublicKey()).bytes),
    );
  }

  final Uint8List noisePublicKey;
  final SimpleKeyPair _signing;
  final Uint8List signingPublicKey;

  Uint8List get peerId => bitchatPeerId(noisePublicKey);

  Future<Uint8List> sign(List<int> data) async =>
      Uint8List.fromList((await Ed25519().sign(data, keyPair: _signing)).bytes);
}

/// A bitchat mesh participant: announces itself, relays other peers'
/// packets (bitchat's flooding with TTL), and carries Conest frames as
/// Noise-type packets addressed to a Conest peer, which relays cannot read
/// or tell apart from bitchat's own private messages.
class BitchatNode {
  BitchatNode({
    required this.identity,
    required this.nickname,
    required BitchatLinkLayer links,
    required this.onFrame,
    this.announceInterval = const Duration(minutes: 2),
    this.relay = true,
    DateTime Function()? now,
  }) : _links = links,
       _now = now ?? DateTime.now {
    _subscription = _links.received.listen(
      (event) =>
          unawaited(_handle(event.$1, event.$2).catchError((Object _) {})),
    );
  }

  final BitchatIdentity identity;

  /// What other bitchat users see; neutral by default.
  final String nickname;
  final BitchatLinkLayer _links;
  final DateTime Function() _now;
  final Duration announceInterval;

  /// Relay other peers' packets, as every bitchat device does.
  final bool relay;

  /// A Conest frame from the peer with id (hex) [sender].
  final void Function(String sender, Uint8List frame) onFrame;

  late final StreamSubscription<(String, Uint8List)> _subscription;
  final LinkedHashSet<String> _seen = LinkedHashSet();
  static const int _maxSeen = 8192;
  Timer? _announcer;

  /// Relayed packets per minute, so a flood cannot use the radio forever.
  int _relayedThisMinute = 0;
  int _relayMinute = 0;
  static const int _maxRelaysPerMinute = 600;

  String get peerIdHex => _hex(identity.peerId);

  void start() {
    unawaited(announce().catchError((Object _) {}));
    _announcer ??= Timer.periodic(
      announceInterval,
      (_) => unawaited(announce().catchError((Object _) {})),
    );
  }

  Future<void> stop() async {
    _announcer?.cancel();
    _announcer = null;
    await _subscription.cancel();
  }

  Future<void> announce() async {
    final unsigned = BitchatPacket(
      type: BitchatType.announce,
      senderId: identity.peerId,
      timestamp: _now().millisecondsSinceEpoch,
      payload: BitchatAnnouncement(
        nickname: nickname,
        noisePublicKey: identity.noisePublicKey,
        signingPublicKey: identity.signingPublicKey,
      ).encode(),
    );
    final signed = unsigned.copyWith(
      signature: await identity.sign(unsigned.bytesToSign()),
    );
    _seen.add(signed.dedupKey);
    await _links.broadcast(signed.encode(pad: false));
  }

  /// Sends a Conest frame to the peer with id [recipientHex].
  Future<void> sendFrame(String recipientHex, Uint8List frame) async {
    if (frame.length > bitchatFrameBytes) {
      throw ArgumentError('The frame is too large for one bitchat packet.');
    }
    final packet = BitchatPacket(
      type: BitchatType.noiseEncrypted,
      senderId: identity.peerId,
      recipientId: _unhex(recipientHex),
      timestamp: _now().millisecondsSinceEpoch,
      payload: Uint8List.fromList([..._conestMagic, _conestVersion, ...frame]),
    );
    _remember(packet.dedupKey);
    await _links.broadcast(packet.encode());
  }

  Future<void> _handle(String link, Uint8List raw) async {
    final packet = BitchatPacket.decode(raw);
    if (packet == null) return;
    if (!_remember(packet.dedupKey)) return;
    final mine = identity.peerId;
    if (_equal(packet.senderId, mine)) return;
    final toMe =
        packet.recipientId != null && _equal(packet.recipientId!, mine);
    if (toMe) {
      final payload = packet.payload;
      if (packet.type == BitchatType.noiseEncrypted &&
          !packet.compressed &&
          payload.length > _conestMagic.length + 1 &&
          _startsWithMagic(payload) &&
          payload[_conestMagic.length] == _conestVersion) {
        onFrame(
          _hex(packet.senderId),
          Uint8List.sublistView(payload, _conestMagic.length + 1),
        );
      }
      return;
    }
    if (!relay || packet.ttl == 0 || !_relayAllowed()) return;
    // Relay as received, with one hop less: byte 2 is the TTL.
    final forward = Uint8List.fromList(raw)..[2] = packet.ttl - 1;
    await _links.broadcast(forward, except: link);
  }

  bool _relayAllowed() {
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    if (minute != _relayMinute) {
      _relayMinute = minute;
      _relayedThisMinute = 0;
    }
    return ++_relayedThisMinute <= _maxRelaysPerMinute;
  }

  /// False when [key] was seen before.
  bool _remember(String key) {
    if (_seen.contains(key)) return false;
    _seen.add(key);
    if (_seen.length > _maxSeen) _seen.remove(_seen.first);
    return true;
  }

  static bool _startsWithMagic(Uint8List payload) {
    for (var index = 0; index < _conestMagic.length; index++) {
      if (payload[index] != _conestMagic[index]) return false;
    }
    return true;
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
}

/// Random seeds for a new bitchat identity.
(Uint8List, Uint8List) newBitchatSeeds([Random? random]) {
  final source = random ?? Random.secure();
  Uint8List seed() =>
      Uint8List.fromList(List.generate(32, (_) => source.nextInt(256)));
  return (seed(), seed());
}
