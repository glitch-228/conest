import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'transport.dart';
import 'transport_models.dart';

const int compactEnvelopeMaximumPayloadBytes = 1024 * 1024;

/// Compact, transport-independent wrapper for already encrypted Conest data.
/// Couriers see routing identifiers and expiry only; [payload] remains the
/// application envelope ciphertext produced by the existing crypto layer.
class CompactStoreForwardEnvelope {
  const CompactStoreForwardEnvelope({
    required this.messageId,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.createdAt,
    required this.expiresAt,
    required this.payload,
    this.hopCount = 0,
    this.maximumHops = 2,
    this.receiptRequested = true,
  });

  static const List<int> _magic = [0x43, 0x53, 0x46, 0x31]; // CSF1

  final String messageId;
  final String senderDeviceId;
  final String recipientDeviceId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final Uint8List payload;
  final int hopCount;
  final int maximumHops;
  final bool receiptRequested;

  bool isExpiredAt(DateTime now) => !expiresAt.isAfter(now.toUtc());
  bool get canForward => hopCount < maximumHops;

  CompactStoreForwardEnvelope forwarded() {
    if (!canForward) throw StateError('Compact envelope hop limit reached.');
    return CompactStoreForwardEnvelope(
      messageId: messageId,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      payload: Uint8List.fromList(payload),
      hopCount: hopCount + 1,
      maximumHops: maximumHops,
      receiptRequested: receiptRequested,
    );
  }

  Uint8List encode() {
    final id = utf8.encode(messageId);
    final sender = utf8.encode(senderDeviceId);
    final recipient = utf8.encode(recipientDeviceId);
    if (id.isEmpty ||
        id.length > 255 ||
        sender.isEmpty ||
        sender.length > 255 ||
        recipient.isEmpty ||
        recipient.length > 255 ||
        payload.isEmpty ||
        payload.length > compactEnvelopeMaximumPayloadBytes ||
        hopCount < 0 ||
        hopCount > 255 ||
        maximumHops < 0 ||
        maximumHops > 255 ||
        hopCount > maximumHops ||
        !expiresAt.isAfter(createdAt)) {
      throw ArgumentError('Compact envelope fields are out of range.');
    }
    const fixedLength = 32;
    final bytes = Uint8List(
      fixedLength +
          id.length +
          sender.length +
          recipient.length +
          payload.length,
    );
    bytes.setRange(0, 4, _magic);
    final data = ByteData.sublistView(bytes);
    data.setUint8(4, 1);
    data.setUint8(5, receiptRequested ? 1 : 0);
    data.setUint8(6, hopCount);
    data.setUint8(7, maximumHops);
    data.setUint64(8, createdAt.toUtc().millisecondsSinceEpoch, Endian.big);
    data.setUint64(16, expiresAt.toUtc().millisecondsSinceEpoch, Endian.big);
    data.setUint8(24, id.length);
    data.setUint8(25, sender.length);
    data.setUint8(26, recipient.length);
    data.setUint8(27, 0);
    data.setUint32(28, payload.length, Endian.big);
    var offset = fixedLength;
    bytes.setRange(offset, offset + id.length, id);
    offset += id.length;
    bytes.setRange(offset, offset + sender.length, sender);
    offset += sender.length;
    bytes.setRange(offset, offset + recipient.length, recipient);
    offset += recipient.length;
    bytes.setRange(offset, bytes.length, payload);
    final withCrc = Uint8List(bytes.length + 4)
      ..setRange(0, bytes.length, bytes);
    ByteData.sublistView(
      withCrc,
    ).setUint32(bytes.length, _crc32c(bytes), Endian.big);
    return withCrc;
  }

  factory CompactStoreForwardEnvelope.decode(Uint8List bytes) {
    const fixedLength = 32;
    if (bytes.length < fixedLength + 4 ||
        !_constantListEquals(bytes.sublist(0, 4), _magic)) {
      throw const FormatException('Compact envelope header is invalid.');
    }
    final contentLength = bytes.length - 4;
    final expectedCrc = ByteData.sublistView(
      bytes,
    ).getUint32(contentLength, Endian.big);
    if (_crc32c(Uint8List.sublistView(bytes, 0, contentLength)) !=
        expectedCrc) {
      throw const FormatException('Compact envelope CRC32C mismatch.');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(4) != 1) {
      throw const FormatException('Unsupported compact envelope version.');
    }
    final idLength = data.getUint8(24);
    final senderLength = data.getUint8(25);
    final recipientLength = data.getUint8(26);
    final payloadLength = data.getUint32(28, Endian.big);
    final expectedLength =
        fixedLength + idLength + senderLength + recipientLength + payloadLength;
    if (idLength == 0 ||
        senderLength == 0 ||
        recipientLength == 0 ||
        payloadLength == 0 ||
        payloadLength > compactEnvelopeMaximumPayloadBytes ||
        expectedLength != contentLength) {
      throw const FormatException('Compact envelope dimensions are invalid.');
    }
    var offset = fixedLength;
    String readString(int length) {
      final value = utf8.decode(bytes.sublist(offset, offset + length));
      offset += length;
      return value;
    }

    final messageId = readString(idLength);
    final sender = readString(senderLength);
    final recipient = readString(recipientLength);
    final payload = Uint8List.fromList(
      bytes.sublist(offset, offset + payloadLength),
    );
    final hopCount = data.getUint8(6);
    final maximumHops = data.getUint8(7);
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      data.getUint64(8, Endian.big),
      isUtc: true,
    );
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      data.getUint64(16, Endian.big),
      isUtc: true,
    );
    if (messageId.isEmpty ||
        sender.isEmpty ||
        recipient.isEmpty ||
        hopCount > maximumHops ||
        !expiresAt.isAfter(createdAt)) {
      throw const FormatException('Compact envelope fields are invalid.');
    }
    return CompactStoreForwardEnvelope(
      messageId: messageId,
      senderDeviceId: sender,
      recipientDeviceId: recipient,
      createdAt: createdAt,
      expiresAt: expiresAt,
      payload: payload,
      hopCount: hopCount,
      maximumHops: maximumHops,
      receiptRequested: data.getUint8(5) & 1 == 1,
    );
  }
}

class CompactReplayWindow {
  CompactReplayWindow({this.maximumEntries = 4096});

  final int maximumEntries;
  final Map<String, DateTime> _seen = {};

  bool register(CompactStoreForwardEnvelope envelope, DateTime now) {
    final normalizedNow = now.toUtc();
    _seen.removeWhere((_, expiry) => !expiry.isAfter(normalizedNow));
    if (envelope.isExpiredAt(normalizedNow) ||
        _seen.containsKey(envelope.messageId)) {
      return false;
    }
    if (_seen.length >= maximumEntries) {
      final oldest = _seen.entries.reduce(
        (left, right) => left.value.isBefore(right.value) ? left : right,
      );
      _seen.remove(oldest.key);
    }
    _seen[envelope.messageId] = envelope.expiresAt.toUtc();
    return true;
  }
}

class CourierQueueItem {
  const CourierQueueItem({
    required this.envelope,
    required this.sourcePeerDeviceId,
    required this.queuedAt,
  });

  final CompactStoreForwardEnvelope envelope;
  final String sourcePeerDeviceId;
  final DateTime queuedAt;

  Map<String, dynamic> toJson() => {
    'envelopeBase64': base64Encode(envelope.encode()),
    'sourcePeerDeviceId': sourcePeerDeviceId,
    'queuedAt': queuedAt.toUtc().toIso8601String(),
  };

  factory CourierQueueItem.fromJson(Map<String, dynamic> json) =>
      CourierQueueItem(
        envelope: CompactStoreForwardEnvelope.decode(
          Uint8List.fromList(base64Decode(json['envelopeBase64'] as String)),
        ),
        sourcePeerDeviceId: json['sourcePeerDeviceId'] as String,
        queuedAt: DateTime.parse(json['queuedAt'] as String).toUtc(),
      );
}

/// Explicitly trusted, bounded courier storage. Disabled by default.
class BoundedCourierQueue {
  BoundedCourierQueue({
    this.enabled = false,
    this.maximumItems = 256,
    this.maximumBytes = 8 * 1024 * 1024,
    Set<String> trustedPeerDeviceIds = const {},
    Iterable<CourierQueueItem> initialItems = const [],
  }) : trustedPeerDeviceIds = Set.of(trustedPeerDeviceIds),
       _items = List.of(initialItems);

  bool enabled;
  final int maximumItems;
  final int maximumBytes;
  final Set<String> trustedPeerDeviceIds;
  final List<CourierQueueItem> _items;

  List<CourierQueueItem> get items => List.unmodifiable(_items);
  int get usedBytes =>
      _items.fold(0, (total, item) => total + item.envelope.encode().length);

  void enqueue({
    required CompactStoreForwardEnvelope envelope,
    required String sourcePeerDeviceId,
    required DateTime now,
    bool sourceIsLocal = false,
  }) {
    prune(now);
    if (!enabled) throw StateError('Courier mode is disabled.');
    if ((!sourceIsLocal &&
            !trustedPeerDeviceIds.contains(sourcePeerDeviceId)) ||
        !trustedPeerDeviceIds.contains(envelope.recipientDeviceId)) {
      throw StateError(
        'Courier forwarding is restricted to explicitly trusted peers.',
      );
    }
    if (envelope.isExpiredAt(now) || !envelope.canForward) {
      throw StateError('Envelope is expired or has reached its hop limit.');
    }
    if (_items.any((item) => item.envelope.messageId == envelope.messageId)) {
      return;
    }
    final encodedLength = envelope.encode().length;
    if (_items.length >= maximumItems ||
        usedBytes + encodedLength > maximumBytes) {
      throw StateError('Courier queue quota exceeded.');
    }
    _items.add(
      CourierQueueItem(
        envelope: envelope.forwarded(),
        sourcePeerDeviceId: sourcePeerDeviceId,
        queuedAt: now.toUtc(),
      ),
    );
  }

  List<CourierQueueItem> forRecipient(String recipientDeviceId, DateTime now) {
    prune(now);
    return _items
        .where((item) => item.envelope.recipientDeviceId == recipientDeviceId)
        .toList(growable: false);
  }

  void markDelivered(String messageId) {
    _items.removeWhere((item) => item.envelope.messageId == messageId);
  }

  void cancel(String messageId) => markDelivered(messageId);

  void prune(DateTime now) {
    _items.removeWhere((item) => item.envelope.isExpiredAt(now));
  }

  List<Map<String, dynamic>> toJson() => [
    for (final item in _items) item.toJson(),
  ];
}

/// Native Conest compact/store-forward mode. This is not an LXMF claim; an
/// official Reticulum connector can feed this adapter later over authenticated
/// local IPC without weakening the core identity model.
class CompactStoreForwardAdapter implements TransportAdapter {
  CompactStoreForwardAdapter({
    required this.localDeviceId,
    required this.queue,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String localDeviceId;
  final BoundedCourierQueue queue;
  final DateTime Function() _now;
  final CompactReplayWindow _replay = CompactReplayWindow();
  final StreamController<TransportInboundEnvelope> _inbound =
      StreamController<TransportInboundEnvelope>.broadcast();
  final StreamController<RouteCandidate> _paths =
      StreamController<RouteCandidate>.broadcast();

  @override
  TransportKind get kind => TransportKind.reticulum;

  @override
  TransportCapabilities get capabilities => const TransportCapabilities(
    requiresPeerOnline: false,
    supportsStoreForward: true,
    duplex: true,
    requiresUserAction: false,
    supportsAttachmentStreaming: true,
    reportsPath: true,
    maximumPayloadBytes: compactEnvelopeMaximumPayloadBytes,
  );

  @override
  Stream<TransportInboundEnvelope> get inboundEnvelopes => _inbound.stream;

  @override
  Stream<RouteCandidate> get pathChanges => _paths.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    await _inbound.close();
    await _paths.close();
  }

  @override
  Future<List<RouteCandidate>> discoverRoutes(TransportPeer peer) async {
    if (!queue.enabled ||
        !peer.identityPinned ||
        !queue.trustedPeerDeviceIds.contains(peer.deviceId)) {
      return const [];
    }
    return [
      RouteCandidate(
        transport: kind,
        path: TransportPathKind.storeForward,
        routeId: 'compact-courier:${peer.deviceId}',
        label: 'Conest courier',
        trust: TransportTrustState.verifiedContact,
        maximumPayloadBytes: compactEnvelopeMaximumPayloadBytes,
        detail: 'Opaque, expiry-bounded trusted-peer courier queue',
      ),
    ];
  }

  @override
  Future<DeliveryReceipt> sendEnvelope({
    required TransportPeer peer,
    required RouteCandidate route,
    required TransportEnvelope envelope,
  }) async {
    final expiry =
        envelope.expiresAt ?? envelope.createdAt.add(const Duration(days: 7));
    queue.enqueue(
      envelope: CompactStoreForwardEnvelope(
        messageId: envelope.id,
        senderDeviceId: localDeviceId,
        recipientDeviceId: peer.deviceId,
        createdAt: envelope.createdAt,
        expiresAt: expiry,
        payload: envelope.bytes,
      ),
      sourcePeerDeviceId: localDeviceId,
      sourceIsLocal: true,
      now: _now(),
    );
    return DeliveryReceipt(
      state: DeliveryReceiptState.storedForPeer,
      route: route,
      at: _now().toUtc(),
      detail: 'Stored in bounded opaque courier queue.',
    );
  }

  @override
  Future<DeliveryReceipt> sendAttachmentRange({
    required TransportPeer peer,
    required RouteCandidate route,
    required AttachmentRange range,
  }) => sendEnvelope(
    peer: peer,
    route: route,
    envelope: TransportEnvelope(
      id: '${range.attachmentId}:${range.offset}',
      recipientDeviceId: peer.deviceId,
      bytes: range.bytes,
      createdAt: _now().toUtc(),
    ),
  );

  void receiveFromCourier({
    required String courierDeviceId,
    required Uint8List encodedEnvelope,
  }) {
    if (!queue.enabled ||
        !queue.trustedPeerDeviceIds.contains(courierDeviceId)) {
      throw StateError('Courier peer is not explicitly trusted.');
    }
    final envelope = CompactStoreForwardEnvelope.decode(encodedEnvelope);
    if (envelope.recipientDeviceId != localDeviceId ||
        !_replay.register(envelope, _now())) {
      throw StateError('Compact envelope is not eligible for local delivery.');
    }
    _inbound.add(
      TransportInboundEnvelope(
        transport: kind,
        path: TransportPathKind.storeForward,
        senderTransportIdentity: envelope.senderDeviceId,
        bytes: envelope.payload,
        receivedAt: _now().toUtc(),
      ),
    );
  }

  @override
  Future<void> cancel(String operationId) async => queue.cancel(operationId);
}

bool _constantListEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

int _crc32c(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = _crc32cTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final List<int> _crc32cTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = value & 1 == 1 ? (value >>> 1) ^ 0x82f63b78 : value >>> 1;
  }
  return value & 0xffffffff;
}, growable: false);
