import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'carrier.dart';
import 'meshtastic/protobuf.dart';
import 'meshtastic/radio.dart';
import 'radio/android_radio_link.dart';
import 'radio/byte_link.dart';
import 'transport_models.dart';

/// The private application port Conest's frames use (256–511 are private).
const int meshtasticConestPort = 300;

/// Default TCP port of Meshtastic's network API.
const int defaultMeshtasticPort = 4403;

/// Version byte at the start of each Conest payload.
const int _payloadVersion = 1;

/// Payload Conest puts in one Meshtastic packet: comfortably under the
/// firmware's limit once a direct message is encrypted with node keys.
const int meshtasticPayloadBytes = 200;

/// Meshtastic radios have little airtime: envelopes up to 4 KiB.
const CarrierFraming meshtasticFraming = CarrierFraming(
  maxSealedBytes: 4 * 1024,
  chunkBytes: meshtasticPayloadBytes - 1 - carrierBinaryFrameHeaderBytes,
);

/// A device's address on Meshtastic: its node number, as 8 hex digits.
String meshtasticAddress(int nodeNum) =>
    nodeNum.toRadixString(16).padLeft(8, '0');

int? parseMeshtasticAddress(String address) {
  if (!RegExp(r'^[0-9a-f]{8}$').hasMatch(address)) return null;
  final num = int.parse(address, radix: 16);
  // 0 and the broadcast address are not nodes.
  return num == 0 || num == 0xffffffff ? null : num;
}

bool isValidMeshtasticAddress(String address) =>
    parseMeshtasticAddress(address) != null;

/// How the carrier reaches the Meshtastic radio.
enum MeshtasticLink {
  /// USB serial: a serial port on Linux and macOS, a USB device on Android.
  serial,

  /// The radio's network API (Wi-Fi or Ethernet radios, meshtasticd).
  tcp,
}

/// The saved Meshtastic carrier: how to reach the radio.
class MeshtasticCarrierConfig {
  const MeshtasticCarrierConfig({
    required this.link,
    required this.host,
    this.port = defaultMeshtasticPort,
    this.nodeNum,
    this.appMessages = false,
  });

  final MeshtasticLink link;

  /// The radio's node number once it has been seen, so the address is
  /// known before the radio connects again.
  final int? nodeNum;

  /// Reads and writes the Meshtastic apps' own text messages (direct ones
  /// and the radio's channels), besides carrying Conest's.
  final bool appMessages;

  MeshtasticCarrierConfig withNodeNum(int nodeNum) => MeshtasticCarrierConfig(
    link: link,
    host: host,
    port: port,
    nodeNum: nodeNum,
    appMessages: appMessages,
  );

  MeshtasticCarrierConfig withAppMessages(bool enabled) =>
      MeshtasticCarrierConfig(
        link: link,
        host: host,
        port: port,
        nodeNum: nodeNum,
        appMessages: enabled,
      );

  /// Device path or USB device for [MeshtasticLink.serial], else the host.
  final String host;
  final int port;

  String get label => link == MeshtasticLink.serial ? host : '$host:$port';

  Map<String, Object?> toJson() => {
    'link': link.name,
    'host': host,
    'port': port,
    if (nodeNum != null) 'nodeNum': nodeNum,
    if (appMessages) 'appMessages': true,
  };

  static MeshtasticCarrierConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final link = MeshtasticLink.values.asNameMap()[json['link']];
    final host = json['host'];
    final port = json['port'];
    if (link == null ||
        host is! String ||
        host.isEmpty ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      return null;
    }
    final nodeNum = json['nodeNum'];
    return MeshtasticCarrierConfig(
      link: link,
      host: host,
      port: port,
      nodeNum: nodeNum is int ? nodeNum : null,
      appMessages: json['appMessages'] == true,
    );
  }
}

typedef MeshtasticConnector =
    Future<ByteLink> Function(MeshtasticCarrierConfig config);

Future<ByteLink> connectMeshtastic(MeshtasticCarrierConfig config) async =>
    switch (config.link) {
      MeshtasticLink.serial when Platform.isAndroid =>
        await AndroidRadioLinks.openUsb(config.host),
      MeshtasticLink.serial => await UnixSerialLink.open(config.host),
      MeshtasticLink.tcp => await TcpByteLink.connect(config.host, config.port),
    };

enum MeshtasticCarrierState { stopped, connecting, connected, failed }

/// The Meshtastic apps' text messages.
const int meshtasticTextPort = 1;

/// Acknowledgements (and routing errors).
const int meshtasticRoutingPort = 5;

/// Longest text the apps send in one message.
const int meshtasticMaxTextBytes = 200;

/// A text message from a Meshtastic app user.
class MeshtasticText {
  const MeshtasticText({
    required this.from,
    required this.direct,
    required this.channel,
    required this.text,
    required this.id,
    this.pki = false,
  });

  final int from;

  /// Encrypted with the two radios' keys: it is from [from]. Otherwise
  /// (the channel key) anyone on the channel could have written it.
  final bool pki;

  /// To this radio alone; otherwise to everyone on [channel].
  final bool direct;
  final int channel;
  final String text;
  final int id;
}

/// The Meshtastic side of the carrier: a radio driven through its client
/// API, carrying each frame as a direct message on Conest's private port.
class MeshtasticCarrierChannel implements ManagedCarrierChannel {
  MeshtasticCarrierChannel({
    required this.config,
    required this.onFrame,
    this.onStatusChanged,
    this.onNodeNum,
    this.onText,
    this.onAck,
    MeshtasticConnector? connector,
  }) : _connector = connector ?? connectMeshtastic,
       _nodeNum = config.nodeNum;

  /// A text message from a Meshtastic app user (port 1), when
  /// [MeshtasticCarrierConfig.appMessages] is on.
  final void Function(MeshtasticText text)? onText;

  /// The radio [from] answered our packet [requestId]: received ([ok]), or
  /// refused (it could not read it, for example without our key yet).
  final void Function(int from, int requestId, {required bool ok})? onAck;

  final MeshtasticCarrierConfig config;
  final MeshtasticConnector _connector;

  /// A frame from the node whose number (8 hex digits) is [sender].
  final void Function(String sender, Uint8List frame) onFrame;
  final void Function()? onStatusChanged;

  /// The radio told its node number (which may differ from the saved one
  /// when another radio is attached).
  final void Function(int nodeNum)? onNodeNum;

  MeshtasticRadio? _radio;
  int? _nodeNum;
  MeshtasticCarrierState _state = MeshtasticCarrierState.stopped;
  String? _lastError;
  bool _started = false;
  int _generation = 0;
  Completer<void>? _wake;

  MeshtasticCarrierState get state => _state;
  String? get lastError => _lastError;

  /// The radio's node number, known once it has connected.
  int? get nodeNum => _nodeNum;

  @override
  String? get localAddress =>
      _nodeNum == null ? null : meshtasticAddress(_nodeNum!);

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
    _radio = null;
    _wake?.complete();
    _wake = null;
    _setState(MeshtasticCarrierState.stopped);
  }

  /// Whether the apps' text messages are read (set from the config, and
  /// changed without reconnecting).
  late bool appMessages = config.appMessages;

  /// Nodes in the radio's database.
  Iterable<int> get knownNodes => _radio?.nodes.keys ?? const <int>[];

  /// The name a node gave itself, if the radio knows it.
  String? nodeName(int node) => _radio?.nodes[node]?.longName;

  /// Sends [text] to node [to], or to everyone on [channel] when [to] is
  /// null; returns the packet id.
  Future<int> sendText(String text, {int? to, int channel = 0}) async {
    final radio = _radio;
    if (!_started || radio == null) {
      throw StateError('The Meshtastic radio is not connected.');
    }
    final bytes = utf8.encode(text);
    if (bytes.length > meshtasticMaxTextBytes) {
      throw ArgumentError(
        'Too long for one Meshtastic message ($meshtasticMaxTextBytes '
        'bytes at most).',
      );
    }
    return radio.send(
      to: to ?? MeshtasticRadio.broadcast,
      portnum: meshtasticTextPort,
      payload: bytes,
      wantAck: to != null,
      channel: channel,
    );
  }

  @override
  Future<void> sendFrame(String address, Uint8List frame) async {
    final radio = _radio;
    if (!_started || radio == null) {
      throw StateError('The Meshtastic radio is not connected.');
    }
    final to = parseMeshtasticAddress(address);
    if (to == null) throw ArgumentError('Not a Meshtastic node address.');
    await radio.send(
      to: to,
      portnum: meshtasticConestPort,
      payload: [_payloadVersion, ...frame],
    );
  }

  Future<void> _run(int generation) async {
    bool current() => _started && generation == _generation;
    var backoff = const Duration(seconds: 2);
    while (current()) {
      MeshtasticRadio? radio;
      DateTime? connectedAt;
      try {
        _setState(MeshtasticCarrierState.connecting);
        final link = await _connector(config);
        if (!current()) {
          await link.close();
          break;
        }
        radio = await MeshtasticRadio.open(link);
        if (!current()) break;
        final subscription = radio.packets.listen(_receive);
        _radio = radio;
        final nodeNum = radio.myNodeNum!;
        if (nodeNum != _nodeNum) {
          _nodeNum = nodeNum;
          onNodeNum?.call(nodeNum);
        }
        connectedAt = DateTime.now();
        _lastError = null;
        _setState(MeshtasticCarrierState.connected);
        final wake = Completer<void>();
        _wake = wake;
        await Future.any([radio.closed, wake.future]);
        await subscription.cancel();
        if (current()) throw StateError('The Meshtastic radio disconnected.');
      } catch (error) {
        if (current()) {
          _lastError = '$error';
          _setState(MeshtasticCarrierState.failed);
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

  void _receive(MeshtasticPacket packet) {
    if (packet.portnum == meshtasticRoutingPort && packet.requestId != null) {
      // Routing { error_reason = 3 }: none (0, often left out) is an
      // acknowledgement; anything else is a refusal.
      final Object? reason;
      try {
        reason = ProtoReader.fields(packet.payload)[3];
      } catch (_) {
        return;
      }
      onAck?.call(
        packet.from,
        packet.requestId!,
        ok: reason == null || reason == 0,
      );
      return;
    }
    if (packet.portnum == meshtasticTextPort) {
      if (!appMessages || packet.from == _nodeNum) return;
      final String text;
      try {
        text = utf8.decode(packet.payload);
      } on FormatException {
        return;
      }
      if (text.trim().isEmpty) return;
      onText?.call(
        MeshtasticText(
          from: packet.from,
          direct: packet.to == _nodeNum,
          channel: packet.channel,
          text: text,
          id: packet.id,
          pki: packet.pkiEncrypted,
        ),
      );
      return;
    }
    if (packet.portnum != meshtasticConestPort ||
        packet.payload.length < 2 ||
        packet.payload[0] != _payloadVersion) {
      return;
    }
    onFrame(
      meshtasticAddress(packet.from),
      Uint8List.sublistView(packet.payload, 1),
    );
  }

  void _setState(MeshtasticCarrierState state) {
    if (_state == state) return;
    _state = state;
    onStatusChanged?.call();
  }
}

/// A Meshtastic carrier adapter, paced for LoRa airtime.
CarrierTransportAdapter createMeshtasticCarrierAdapter({
  required CarrierSealer sealer,
  DateTime Function()? now,
}) => CarrierTransportAdapter(
  kind: TransportKind.meshtastic,
  sealer: sealer,
  framing: meshtasticFraming,
  frameSpacing: const Duration(seconds: 3),
  sendAttemptTimeout: const Duration(minutes: 3),
  isValidAddress: isValidMeshtasticAddress,
  now: now,
);
