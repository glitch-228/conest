import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'carrier.dart';
import 'nostr/secp256k1.dart' show hexDecode, hexEncode;
import 'radio/android_radio_link.dart';
import 'radio/byte_link.dart';
import 'reticulum/endpoint.dart';
import 'reticulum/identity.dart';
import 'reticulum/packet.dart';
import 'reticulum/rnode_interface.dart';
import 'reticulum/tcp_interface.dart';
import 'transport_models.dart';

/// Default TCP port of rnsd's TCP server interface.
const int defaultReticulumPort = 4242;

/// Version byte at the start of carrier packet data.
const int _dataVersion = 1;

/// Frame payload of one encrypted Reticulum packet: the data holds a
/// version byte and the sender's destination hash before the frame.
const int _reticulumChunkBytes =
    rnsEncryptedMdu - 1 - rnsTruncatedHashBytes - carrierBinaryFrameHeaderBytes;

/// Over a Reticulum node (TCP): envelopes up to 32 KiB.
const CarrierFraming reticulumFraming = CarrierFraming(
  maxSealedBytes: 32 * 1024,
  chunkBytes: _reticulumChunkBytes,
);

/// Straight over a radio, airtime is scarce: envelopes up to 4 KiB (about
/// a dozen packets), so files and long histories stay off LoRa.
const CarrierFraming reticulumRadioFraming = CarrierFraming(
  maxSealedBytes: 4 * 1024,
  chunkBytes: _reticulumChunkBytes,
);

/// A device's address on Reticulum: its carrier destination, the identity
/// public key it belongs to (so senders can encrypt without waiting for an
/// announce), and the destination's name hash. The name is random per
/// device, so announces do not show that Conest is in use.
class ReticulumAddress {
  const ReticulumAddress({
    required this.destination,
    required this.identity,
    required this.nameHash,
  });

  final Uint8List destination;
  final RnsIdentity identity;
  final Uint8List nameHash;

  String encode() =>
      '${hexEncode(destination)}|${hexEncode(identity.publicKey)}|'
      '${hexEncode(nameHash)}';

  static ReticulumAddress? tryParse(String value) {
    final parts = value.split('|');
    if (parts.length != 3 ||
        parts[0].length != 2 * rnsTruncatedHashBytes ||
        parts[1].length != 128 ||
        parts[2].length != 2 * rnsNameHashBytes ||
        parts.any((part) => part != part.toLowerCase())) {
      return null;
    }
    final destination = hexDecode(parts[0]);
    final publicKey = hexDecode(parts[1]);
    final nameHash = hexDecode(parts[2]);
    if (destination == null || publicKey == null || nameHash == null) {
      return null;
    }
    final identity = RnsIdentity.fromPublicKey(publicKey)!;
    if (hexEncode(rnsDestinationHash(nameHash, identity.hash)) != parts[0]) {
      return null;
    }
    return ReticulumAddress(
      destination: destination,
      identity: identity,
      nameHash: nameHash,
    );
  }
}

bool isValidReticulumAddress(String address) =>
    ReticulumAddress.tryParse(address) != null;

/// How the carrier reaches the Reticulum network.
enum ReticulumLink {
  /// A node running rnsd, over its TCP server interface.
  rnsd,

  /// An RNode radio on USB: a serial port on Linux and macOS, a USB
  /// device on Android.
  rnodeSerial,

  /// An RNode radio offering its serial protocol over Wi-Fi (TCP).
  rnodeTcp,

  /// An RNode radio over Bluetooth LE (Android).
  rnodeBluetooth,
}

/// The saved Reticulum carrier: its identity, destination name and how it
/// connects.
class ReticulumCarrierConfig {
  const ReticulumCarrierConfig({
    required this.identityKeyHex,
    required this.nameHashHex,
    required this.host,
    required this.port,
    this.link = ReticulumLink.rnsd,
    this.radio,
  });

  /// A random destination name hash.
  static String newNameHashHex([Random? random]) {
    final source = random ?? Random.secure();
    return hexEncode(
      List.generate(rnsNameHashBytes, (_) => source.nextInt(256)),
    );
  }

  final String identityKeyHex;
  final String nameHashHex;
  final ReticulumLink link;

  /// The node or radio host, or for [ReticulumLink.rnodeSerial] the device
  /// path such as `/dev/ttyACM0`.
  final String host;
  final int port;

  /// Radio settings for an RNode link.
  final RnodeConfig? radio;

  bool get isRadio => link != ReticulumLink.rnsd;

  String get label =>
      link == ReticulumLink.rnodeSerial || link == ReticulumLink.rnodeBluetooth
      ? host
      : '$host:$port';

  /// Whether reaching [host] needs the internet: anything but a radio
  /// attached here, this machine or a private network. Such links obey the
  /// Online switch.
  bool get usesInternet =>
      (link == ReticulumLink.rnsd || link == ReticulumLink.rnodeTcp) &&
      !isLocalNetworkHost(host);

  Map<String, Object?> toJson() => {
    'identityKey': identityKeyHex,
    'nameHash': nameHashHex,
    'link': link.name,
    'host': host,
    'port': port,
    if (radio != null) 'radio': radio!.toJson(),
  };

  static ReticulumCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final key = json['identityKey'];
    final nameHash = json['nameHash'];
    final host = json['host'];
    final port = json['port'];
    final link =
        ReticulumLink.values.asNameMap()[json['link']] ?? ReticulumLink.rnsd;
    final radio = RnodeConfig.fromJson(json['radio']);
    if (key is! String ||
        hexDecode(key)?.length != 64 ||
        nameHash is! String ||
        hexDecode(nameHash)?.length != rnsNameHashBytes ||
        host is! String ||
        host.isEmpty ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        (link != ReticulumLink.rnsd && radio == null)) {
      return null;
    }
    return ReticulumCarrierConfig(
      identityKeyHex: key,
      nameHashHex: nameHash,
      host: host,
      port: port,
      link: link,
      radio: radio,
    );
  }

  @override
  String toString() => 'ReticulumCarrierConfig(${link.name} $label)';
}

/// This machine, a private (RFC 1918 / ULA / link-local) address, or a
/// `.local` name.
bool isLocalNetworkHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower.endsWith('.local')) return true;
  final address = InternetAddress.tryParse(
    lower.replaceAll(RegExp(r'[\[\]]'), ''),
  );
  if (address == null) return false;
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  return (bytes[0] & 0xfe) == 0xfc;
}

/// Opens the link a config describes.
typedef RnsConnector =
    Future<RnsInterface> Function(ReticulumCarrierConfig config);

Future<RnsInterface> connectReticulum(ReticulumCarrierConfig config) async {
  switch (config.link) {
    case ReticulumLink.rnsd:
      return RnsTcpInterface.connect(config.host, config.port);
    case ReticulumLink.rnodeSerial:
      return RnodeInterface.open(
        Platform.isAndroid
            ? await AndroidRadioLinks.openUsb(config.host)
            : await UnixSerialLink.open(config.host),
        config.radio!,
      );
    case ReticulumLink.rnodeBluetooth:
      return RnodeInterface.open(
        await AndroidRadioLinks.openBle(config.host),
        config.radio!,
        // Bluetooth radios answer slower than serial ones.
        timeout: const Duration(seconds: 10),
      );
    case ReticulumLink.rnodeTcp:
      return RnodeInterface.open(
        await TcpByteLink.connect(config.host, config.port),
        config.radio!,
      );
  }
}

enum ReticulumCarrierState { stopped, connecting, connected, failed }

/// The Reticulum side of the carrier: a link to a Reticulum network (rnsd
/// or an RNode), an endpoint for the device's carrier destination, and one
/// encrypted packet per frame.
class ReticulumCarrierChannel implements ManagedCarrierChannel {
  ReticulumCarrierChannel._({
    required RnsIdentity identity,
    required this.config,
    required this.onFrame,
    this.onStatusChanged,
    RnsConnector? connector,
    this.announceInterval = const Duration(minutes: 30),
    this.pathTimeout = const Duration(seconds: 15),
  }) : _identity = identity,
       _connector = connector ?? connectReticulum,
       _nameHash = hexDecode(config.nameHashHex)!,
       _destination = rnsDestinationHash(
         hexDecode(config.nameHashHex)!,
         identity.hash,
       );

  static Future<ReticulumCarrierChannel> create({
    required ReticulumCarrierConfig config,
    required void Function(String sender, Uint8List frame) onFrame,
    void Function()? onStatusChanged,
    RnsConnector? connector,
    Duration announceInterval = const Duration(minutes: 30),
    Duration pathTimeout = const Duration(seconds: 15),
  }) async => ReticulumCarrierChannel._(
    identity: await RnsIdentity.fromPrivateKey(
      hexDecode(config.identityKeyHex)!,
    ),
    config: config,
    onFrame: onFrame,
    onStatusChanged: onStatusChanged,
    connector: connector,
    announceInterval: announceInterval,
    pathTimeout: pathTimeout,
  );

  final RnsIdentity _identity;
  final ReticulumCarrierConfig config;
  final RnsConnector _connector;
  final Uint8List _nameHash;
  final Uint8List _destination;
  final Duration announceInterval;
  final Duration pathTimeout;

  /// A frame from the contact whose destination hash (hex) is [sender].
  final void Function(String sender, Uint8List frame) onFrame;
  final void Function()? onStatusChanged;

  RnsEndpoint? _endpoint;
  final Map<String, DateTime> _pathAsked = {};
  ReticulumCarrierState _state = ReticulumCarrierState.stopped;
  String? _lastError;
  bool _started = false;
  int _generation = 0;
  Completer<void>? _wake;

  ReticulumCarrierState get state => _state;
  String? get lastError => _lastError;

  @override
  String? get localAddress => ReticulumAddress(
    destination: _destination,
    identity: _identity,
    nameHash: _nameHash,
  ).encode();

  @override
  String get routeLabel => config.label;

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
    _endpoint = null;
    // The run loop wakes, sees it is no longer current and closes its link.
    _wake?.complete();
    _wake = null;
    _setState(ReticulumCarrierState.stopped);
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    final endpoint = _endpoint;
    if (!_started || endpoint == null) {
      throw StateError('Reticulum is not connected.');
    }
    final to = ReticulumAddress.tryParse(address);
    if (to == null) throw ArgumentError('Not a Reticulum carrier address.');
    endpoint.watch(to.destination);
    final key = to.encode();
    final asked = _pathAsked[key];
    final now = DateTime.now();
    if (endpoint.pathTo(to.destination) == null &&
        (asked == null || now.difference(asked) > const Duration(minutes: 1))) {
      // Without a path a transport node would not forward the packet. Ask
      // once a minute; meanwhile packets go to direct neighbours.
      _pathAsked[key] = now;
      if (_pathAsked.length > 1024) _pathAsked.remove(_pathAsked.keys.first);
      await endpoint.requestPath(to.destination, timeout: pathTimeout);
    }
    await endpoint.sendTo(
      to.identity,
      Uint8List.fromList([_dataVersion, ..._destination, ...frame]),
      recipientNameHash: to.nameHash,
    );
  }

  Future<void> _run(int generation) async {
    bool current() => _started && generation == _generation;
    var backoff = const Duration(seconds: 2);
    while (current()) {
      RnsInterface? link;
      RnsEndpoint? endpoint;
      DateTime? connectedAt;
      try {
        _setState(ReticulumCarrierState.connecting);
        link = await _connector(config);
        if (!current()) break;
        endpoint = RnsEndpoint(
          identity: _identity,
          nameHash: _nameHash,
          interface: link,
          onData: _receive,
        );
        _endpoint = endpoint;
        // A new link knows no paths yet: ask again at once.
        _pathAsked.clear();
        connectedAt = DateTime.now();
        _lastError = null;
        _setState(ReticulumCarrierState.connected);
        final closed = link.closed;
        while (current()) {
          await endpoint.announce();
          final wake = Completer<void>();
          _wake = wake;
          final ended = await Future.any<bool>([
            closed.then((_) => true),
            wake.future.then((_) => false),
            Future<void>.delayed(announceInterval).then((_) => false),
          ]);
          if (ended) throw StateError('The Reticulum link closed.');
        }
      } catch (error) {
        if (current()) {
          _lastError = '$error';
          _setState(ReticulumCarrierState.failed);
        }
      } finally {
        // This run's own link, never a newer run's.
        if (identical(_endpoint, endpoint)) _endpoint = null;
        await endpoint?.close();
        await link?.close();
      }
      if (!current()) break;
      // Only a connection that held for a while resets the backoff, so a
      // node that accepts and drops at once is not hammered.
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

  void _receive(Uint8List data) {
    if (data.length <= 1 + rnsTruncatedHashBytes || data[0] != _dataVersion) {
      return;
    }
    onFrame(
      hexEncode(Uint8List.sublistView(data, 1, 1 + rnsTruncatedHashBytes)),
      Uint8List.sublistView(data, 1 + rnsTruncatedHashBytes),
    );
  }

  void _setState(ReticulumCarrierState state) {
    if (_state == state) return;
    _state = state;
    onStatusChanged?.call();
  }
}

/// A Reticulum carrier adapter; [radio] links send smaller envelopes,
/// paced for airtime.
CarrierTransportAdapter createReticulumCarrierAdapter({
  required CarrierSealer sealer,
  bool radio = false,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.reticulum,
  sealer: sealer,
  framing: radio ? reticulumRadioFraming : reticulumFraming,
  frameSpacing: radio
      ? const Duration(milliseconds: 1500)
      : const Duration(milliseconds: 20),
  sendAttemptTimeout: radio
      ? const Duration(minutes: 3)
      : const Duration(seconds: 120),
  isValidAddress: isValidReticulumAddress,
  now: now,
);
