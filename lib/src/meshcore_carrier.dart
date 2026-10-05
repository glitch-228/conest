import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'carrier.dart';
import 'meshcore/companion.dart';
import 'nostr/secp256k1.dart' show hexDecode, hexEncode;
import 'radio/android_radio_link.dart';
import 'radio/byte_link.dart';
import 'transport_models.dart';

/// Version byte at the start of each Conest payload.
const int _payloadVersion = 1;

/// Base64 text of at most 152 characters fits MeshCore's 160-byte text
/// limit with room to spare: 114 bytes of payload.
const int meshCorePayloadBytes = 114;

/// MeshCore radios have little airtime: envelopes up to 4 KiB.
const CarrierFraming meshCoreFraming = CarrierFraming(
  maxSealedBytes: 4 * 1024,
  chunkBytes: meshCorePayloadBytes - 1 - carrierBinaryFrameHeaderBytes,
);

/// A device's address on MeshCore: the first six bytes of its radio's
/// public key (how messages name their sender) and the whole key.
class MeshCoreAddress {
  const MeshCoreAddress(this.publicKey);

  final Uint8List publicKey;

  Uint8List get prefix => Uint8List.sublistView(publicKey, 0, 6);

  String encode() => '${hexEncode(prefix)}|${hexEncode(publicKey)}';

  static MeshCoreAddress? tryParse(String value) {
    final parts = value.split('|');
    if (parts.length != 2 ||
        parts[0].length != 12 ||
        parts[1].length != 64 ||
        parts.any((part) => part != part.toLowerCase()) ||
        !parts[1].startsWith(parts[0])) {
      return null;
    }
    final key = hexDecode(parts[1]);
    return key == null ? null : MeshCoreAddress(key);
  }
}

bool isValidMeshCoreAddress(String address) =>
    MeshCoreAddress.tryParse(address) != null;

enum MeshCoreLink {
  /// USB serial: a serial port on Linux and macOS, a USB device on Android.
  serial,

  /// Bluetooth LE (Android).
  bluetooth,
}

/// The saved MeshCore carrier: how to reach the companion radio.
class MeshCoreCarrierConfig {
  const MeshCoreCarrierConfig({
    required this.link,
    required this.host,
    this.publicKeyHex,
  });

  final MeshCoreLink link;

  /// Device path or USB device, or the Bluetooth address.
  final String host;

  /// The radio's public key once seen, so the address is known before the
  /// radio connects again.
  final String? publicKeyHex;

  MeshCoreCarrierConfig withPublicKey(String key) =>
      MeshCoreCarrierConfig(link: link, host: host, publicKeyHex: key);

  Map<String, Object?> toJson() => {
    'link': link.name,
    'host': host,
    if (publicKeyHex != null) 'publicKey': publicKeyHex,
  };

  static MeshCoreCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final link = MeshCoreLink.values.asNameMap()[json['link']];
    final host = json['host'];
    final key = json['publicKey'];
    if (link == null || host is! String || host.isEmpty) return null;
    return MeshCoreCarrierConfig(
      link: link,
      host: host,
      publicKeyHex: key is String && hexDecode(key)?.length == 32 ? key : null,
    );
  }
}

typedef MeshCoreConnector =
    Future<ByteLink> Function(MeshCoreCarrierConfig config);

Future<ByteLink> connectMeshCore(MeshCoreCarrierConfig config) async =>
    switch (config.link) {
      MeshCoreLink.serial when Platform.isAndroid =>
        await AndroidRadioLinks.openUsb(config.host),
      MeshCoreLink.serial => await UnixSerialLink.open(config.host),
      // MeshCore's Bluetooth service carries one frame per write and per
      // notification.
      MeshCoreLink.bluetooth => await AndroidRadioLinks.openBle(
        config.host,
        keepsMessages: true,
      ),
    };

enum MeshCoreCarrierState { stopped, connecting, connected, failed }

/// The MeshCore side of the carrier: a companion radio carrying each frame
/// as a direct "command data" message (encrypted by MeshCore with the two
/// radios' keys, and not shown on their screens).
class MeshCoreCarrierChannel
    implements ManagedCarrierChannel, PeerAwareCarrierChannel {
  MeshCoreCarrierChannel({
    required this.config,
    required this.onFrame,
    this.onStatusChanged,
    this.onPublicKey,
    MeshCoreConnector? connector,
    DateTime Function()? now,
  }) : _connector = connector ?? connectMeshCore,
       _now = now ?? DateTime.now,
       _publicKey = config.publicKeyHex == null
           ? null
           : hexDecode(config.publicKeyHex!);

  final MeshCoreCarrierConfig config;
  final MeshCoreConnector _connector;
  final DateTime Function() _now;

  /// A frame from the radio whose key prefix (hex) is [sender].
  final void Function(String sender, Uint8List frame) onFrame;
  final void Function()? onStatusChanged;
  final void Function(String publicKeyHex)? onPublicKey;

  MeshCoreRadio? _radio;
  Uint8List? _publicKey;
  Set<String> _peers = const {};
  final Set<String> _onRadio = {};
  MeshCoreCarrierState _state = MeshCoreCarrierState.stopped;
  String? _lastError;
  bool _started = false;
  int _generation = 0;
  Completer<void>? _wake;

  MeshCoreCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress =>
      _publicKey == null ? null : MeshCoreAddress(_publicKey!).encode();

  @override
  String get routeLabel => config.host;

  @override
  void updatePeers(Set<String> addresses) {
    _peers = {
      for (final address in addresses)
        if (isValidMeshCoreAddress(address)) address,
    };
    final radio = _radio;
    if (radio != null) unawaited(_addPeers(radio).catchError((Object _) {}));
  }

  @override
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_run(++_generation));
  }

  @override
  Future<void> stop() async {
    _started = false;
    _generation++;
    _radio = null;
    _wake?.complete();
    _wake = null;
    _setState(MeshCoreCarrierState.stopped);
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    final radio = _radio;
    if (!_started || radio == null) {
      throw StateError('The MeshCore radio is not connected.');
    }
    final to = MeshCoreAddress.tryParse(address);
    if (to == null) throw ArgumentError('Not a MeshCore address.');
    if (!_onRadio.contains(address)) {
      await radio.ensureContact(to.publicKey, _contactName(to));
      _onRadio.add(address);
    }
    await radio.sendText(
      to.prefix,
      ascii.encode(base64Encode([_payloadVersion, ...frame])),
      timestamp: _now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// A neutral name: other apps on the radio see the contact list, and it
  /// should not say Conest is in use.
  static String _contactName(MeshCoreAddress address) =>
      hexEncode(address.prefix).substring(0, 8);

  /// Puts every peer on the radio. One that fails (a full contact table) is
  /// skipped and tried again on the next update or reconnect.
  Future<void> _addPeers(MeshCoreRadio radio) async {
    for (final address in List.of(_peers)) {
      if (_onRadio.contains(address)) continue;
      final peer = MeshCoreAddress.tryParse(address)!;
      try {
        await radio.ensureContact(peer.publicKey, _contactName(peer));
        _onRadio.add(address);
      } on StateError catch (error) {
        _lastError = 'Could not add a contact to the radio: ${error.message}';
        onStatusChanged?.call();
      }
    }
  }

  Future<void> _run(int generation) async {
    bool current() => _started && generation == _generation;
    var backoff = const Duration(seconds: 2);
    while (current()) {
      MeshCoreRadio? radio;
      DateTime? connectedAt;
      try {
        _setState(MeshCoreCarrierState.connecting);
        final link = await _connector(config);
        if (!current()) {
          await link.close();
          break;
        }
        radio = await MeshCoreRadio.open(link);
        if (!current()) break;
        final subscription = radio.messages.listen(_receive);
        _radio = radio;
        _onRadio.clear();
        final key = radio.publicKey;
        if (_publicKey == null || hexEncode(_publicKey!) != hexEncode(key)) {
          _publicKey = key;
          onPublicKey?.call(hexEncode(key));
        }
        await radio.setTime(_now());
        await _addPeers(radio);
        // Messages that arrived while nothing was connected.
        await radio.syncMessages();
        connectedAt = DateTime.now();
        _lastError = null;
        _setState(MeshCoreCarrierState.connected);
        final wake = Completer<void>();
        _wake = wake;
        await Future.any([radio.closed, wake.future]);
        await subscription.cancel();
        if (current()) throw StateError('The MeshCore radio disconnected.');
      } catch (error) {
        if (current()) {
          _lastError = '$error';
          _setState(MeshCoreCarrierState.failed);
        }
      } finally {
        if (identical(_radio, radio)) _radio = null;
        await radio?.close();
      }
      if (!current()) break;
      if (connectedAt != null &&
          DateTime.now().difference(connectedAt) >
              const Duration(seconds: 30)) {
        backoff = const Duration(seconds: 2);
      }
      final wake = Completer<void>();
      _wake = wake;
      await Future.any([wake.future, Future<void>.delayed(backoff)]);
      backoff = backoff * 2 > const Duration(minutes: 2)
          ? const Duration(minutes: 2)
          : backoff * 2;
    }
  }

  void _receive(MeshCoreMessage message) {
    if (message.textType != MeshCoreCode.textCliData) return;
    final Uint8List payload;
    try {
      payload = base64Decode(ascii.decode(message.text));
    } on FormatException {
      return;
    }
    if (payload.length < 2 || payload[0] != _payloadVersion) return;
    onFrame(hexEncode(message.senderPrefix), Uint8List.sublistView(payload, 1));
  }

  void _setState(MeshCoreCarrierState state) {
    if (_state == state) return;
    _state = state;
    onStatusChanged?.call();
  }
}

/// A MeshCore carrier adapter, paced for LoRa airtime.
CarrierTransportAdapter createMeshCoreCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.meshCore,
  sealer: sealer,
  framing: meshCoreFraming,
  frameSpacing: const Duration(seconds: 3),
  sendAttemptTimeout: const Duration(minutes: 5),
  isValidAddress: isValidMeshCoreAddress,
  now: now,
);
