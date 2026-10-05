import 'dart:async';
import 'dart:typed_data';

import 'bitchat/mesh.dart';
import 'bitchat/packet.dart';
import 'carrier.dart';
import 'nostr/secp256k1.dart' show hexDecode, hexEncode;
import 'transport_models.dart';

/// Frames sized so a bitchat packet never needs fragmenting; envelopes up
/// to 16 KiB.
const CarrierFraming bitchatCarrierFraming = CarrierFraming(
  maxSealedBytes: 16 * 1024,
  chunkBytes: bitchatFrameBytes - carrierBinaryFrameHeaderBytes,
);

/// A device's address on the Bluetooth mesh: its bitchat peer id and the
/// Noise static key the id is the hash of.
class BitchatAddress {
  const BitchatAddress({required this.peerId, required this.noisePublicKey});

  final Uint8List peerId;
  final Uint8List noisePublicKey;

  String encode() => '${hexEncode(peerId)}|${hexEncode(noisePublicKey)}';

  static BitchatAddress? tryParse(String value) {
    final parts = value.split('|');
    if (parts.length != 2 ||
        parts[0].length != 16 ||
        parts[1].length != 64 ||
        parts.any((part) => part != part.toLowerCase())) {
      return null;
    }
    final peerId = hexDecode(parts[0]);
    final key = hexDecode(parts[1]);
    if (peerId == null || key == null) return null;
    if (hexEncode(bitchatPeerId(key)) != parts[0]) return null;
    return BitchatAddress(peerId: peerId, noisePublicKey: key);
  }
}

bool isValidBitchatAddress(String address) =>
    BitchatAddress.tryParse(address) != null;

/// The saved Bluetooth mesh identity: separate from the Conest identity,
/// with a neutral nickname that bitchat users nearby see.
class BitchatCarrierConfig {
  const BitchatCarrierConfig({
    required this.noiseSeedHex,
    required this.signingSeedHex,
    required this.nickname,
  });

  factory BitchatCarrierConfig.create() {
    final (noise, signing) = newBitchatSeeds();
    return BitchatCarrierConfig(
      noiseSeedHex: hexEncode(noise),
      signingSeedHex: hexEncode(signing),
      nickname: 'anon${hexEncode(noise.sublist(0, 2))}',
    );
  }

  final String noiseSeedHex;
  final String signingSeedHex;
  final String nickname;

  Map<String, Object?> toJson() => {
    'noiseSeed': noiseSeedHex,
    'signingSeed': signingSeedHex,
    'nickname': nickname,
  };

  static BitchatCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final noise = json['noiseSeed'];
    final signing = json['signingSeed'];
    final nickname = json['nickname'];
    if (noise is! String ||
        hexDecode(noise)?.length != 32 ||
        signing is! String ||
        hexDecode(signing)?.length != 32 ||
        nickname is! String) {
      return null;
    }
    return BitchatCarrierConfig(
      noiseSeedHex: noise,
      signingSeedHex: signing,
      nickname: nickname,
    );
  }
}

typedef BitchatConnector = Future<BitchatLinkLayer> Function();

enum BitchatCarrierState { stopped, starting, running, failed }

/// The Bluetooth mesh side of the carrier: a bitchat mesh node that relays
/// for its neighbours and carries Conest frames to Conest peers.
class BitchatCarrierChannel implements ManagedCarrierChannel {
  BitchatCarrierChannel._({
    required this.config,
    required BitchatIdentity identity,
    required BitchatConnector connector,
    required this.onFrame,
    this.onStatusChanged,
  }) : _identity = identity,
       _connector = connector;

  static Future<BitchatCarrierChannel> create({
    required BitchatCarrierConfig config,
    required BitchatConnector connector,
    required void Function(String sender, Uint8List frame) onFrame,
    void Function()? onStatusChanged,
  }) async => BitchatCarrierChannel._(
    config: config,
    identity: await BitchatIdentity.fromSeeds(
      hexDecode(config.noiseSeedHex)!,
      hexDecode(config.signingSeedHex)!,
    ),
    connector: connector,
    onFrame: onFrame,
    onStatusChanged: onStatusChanged,
  );

  final BitchatCarrierConfig config;
  final BitchatIdentity _identity;
  final BitchatConnector _connector;

  /// A frame from the bitchat peer whose id (hex) is [sender].
  final void Function(String sender, Uint8List frame) onFrame;
  final void Function()? onStatusChanged;

  BitchatNode? _node;
  BitchatLinkLayer? _links;
  BitchatCarrierState _state = BitchatCarrierState.stopped;
  String? _lastError;
  int _generation = 0;

  BitchatCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress => BitchatAddress(
    peerId: _identity.peerId,
    noisePublicKey: _identity.noisePublicKey,
  ).encode();

  @override
  String get routeLabel => 'nearby phones';

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
        final node = BitchatNode(
          identity: _identity,
          nickname: config.nickname,
          links: links,
          onFrame: onFrame,
        )..start();
        _links = links;
        _node = node;
        _lastError = null;
        _setState(BitchatCarrierState.running);
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
    final node = _node;
    final links = _links;
    _node = null;
    _links = null;
    await node?.stop();
    await links?.close();
    _setState(BitchatCarrierState.stopped);
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    final node = _node;
    if (node == null) throw StateError('The Bluetooth mesh is not running.');
    final to = BitchatAddress.tryParse(address);
    if (to == null) throw ArgumentError('Not a Bluetooth mesh address.');
    await node.sendFrame(hexEncode(to.peerId), frame);
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
