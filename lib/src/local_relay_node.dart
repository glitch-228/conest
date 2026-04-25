import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

const int _defaultMaxQueuePerMailbox = 512;
const int _defaultMaxFetchLimit = 128;
const int _defaultMaxEnvelopeBytes = 256 * 1024;
const int _defaultMaxLineBytes = 300 * 1024;
const int _defaultMaxRequestsPerMinute = 240;

class LocalRelayNode {
  LocalRelayNode({
    this.ttl = const Duration(days: 7),
    this.maxQueuePerMailbox = _defaultMaxQueuePerMailbox,
    this.maxFetchLimit = _defaultMaxFetchLimit,
    this.maxEnvelopeBytes = _defaultMaxEnvelopeBytes,
    this.maxLineBytes = _defaultMaxLineBytes,
    this.maxRequestsPerMinute = _defaultMaxRequestsPerMinute,
    String? relayId,
    DateTime Function()? nowProvider,
  }) : relayId = relayId ?? 'local-${DateTime.now().microsecondsSinceEpoch}',
       _nowProvider = nowProvider ?? DateTime.now {
    if (maxQueuePerMailbox <= 0) {
      throw ArgumentError('maxQueuePerMailbox must be greater than zero.');
    }
    if (maxFetchLimit <= 0) {
      throw ArgumentError('maxFetchLimit must be greater than zero.');
    }
    if (maxEnvelopeBytes <= 0 || maxLineBytes < maxEnvelopeBytes) {
      throw ArgumentError('maxLineBytes must be at least maxEnvelopeBytes.');
    }
    if (maxRequestsPerMinute <= 0) {
      throw ArgumentError('maxRequestsPerMinute must be greater than zero.');
    }
  }

  final Duration ttl;
  final int maxQueuePerMailbox;
  final int maxFetchLimit;
  final int maxEnvelopeBytes;
  final int maxLineBytes;
  final int maxRequestsPerMinute;
  final String relayId;
  final DateTime Function() _nowProvider;
  void Function(String recipientDeviceId, RelayEnvelope envelope)?
  onEnvelopeStored;
  final Map<String, Queue<_QueueEntry>> _queues = {};
  final Map<String, _RateBucket> _rateBuckets = {};
  ServerSocket? _server;
  RawDatagramSocket? _udpSocket;
  StreamSubscription<RawSocketEvent>? _udpSubscription;
  int? _port;

  bool get isRunning => _server != null || _udpSocket != null;
  int? get port => _port;

  Future<void> start(int port) async {
    if (_server != null && _port == port) {
      return;
    }
    await stop();
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _port = port;
    unawaited(_acceptLoop(_server!));
    _udpSubscription = _udpSocket!.listen(_handleUdpEvent);
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    final udpSocket = _udpSocket;
    final udpSubscription = _udpSubscription;
    _udpSocket = null;
    _udpSubscription = null;
    _port = null;
    if (server != null) {
      await server.close();
    }
    if (udpSubscription != null) {
      await udpSubscription.cancel();
    }
    udpSocket?.close();
  }

  Future<void> _acceptLoop(ServerSocket server) async {
    await for (final socket in server) {
      unawaited(_handleClient(socket));
    }
  }

  Future<void> _handleClient(Socket socket) async {
    var isHttp = false;
    try {
      final wireRequest = await _readWireRequest(socket);
      isHttp = wireRequest.isHttp;
      final response = _handleRequest(
        wireRequest.request,
        peer: socket.remoteAddress.address,
      );
      if (isHttp) {
        _writeHttpResponse(socket, response);
      } else {
        socket.writeln(jsonEncode(response));
      }
      await socket.flush();
    } catch (error) {
      final response = {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': error.toString(),
      };
      if (isHttp) {
        _writeHttpResponse(socket, response, statusCode: 400);
      } else {
        socket.writeln(jsonEncode(response));
      }
      await socket.flush();
    } finally {
      await socket.close();
    }
  }

  Future<_RelayWireRequest> _readWireRequest(Socket socket) {
    final completer = Completer<_RelayWireRequest>();
    final buffer = BytesBuilder(copy: false);
    StreamSubscription<List<int>>? subscription;
    Timer? timer;

    void completeWithError(Object error) {
      if (completer.isCompleted) {
        return;
      }
      timer?.cancel();
      unawaited(subscription?.cancel());
      completer.completeError(error);
    }

    void tryComplete() {
      if (completer.isCompleted) {
        return;
      }
      final bytes = buffer.toBytes();
      final int? completion;
      try {
        completion = _wireRequestCompletion(bytes);
      } catch (error) {
        completeWithError(error);
        return;
      }
      if (completion == null) {
        return;
      }
      try {
        final request = _parseWireRequest(bytes.take(completion).toList());
        timer?.cancel();
        unawaited(subscription?.cancel());
        completer.complete(request);
      } catch (error) {
        completeWithError(error);
      }
    }

    timer = Timer(
      const Duration(seconds: 4),
      () => completeWithError(TimeoutException('Relay request timed out.')),
    );
    subscription = socket.listen(
      (chunk) {
        buffer.add(chunk);
        if (buffer.length > maxLineBytes) {
          completeWithError(
            const FormatException('Relay request exceeded max size.'),
          );
          return;
        }
        tryComplete();
      },
      onError: completeWithError,
      onDone: () {
        if (!completer.isCompleted) {
          tryComplete();
        }
        if (!completer.isCompleted) {
          completeWithError(
            const FormatException('Relay request ended early.'),
          );
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  int? _wireRequestCompletion(List<int> bytes) {
    if (bytes.isEmpty) {
      return null;
    }
    final previewLength = bytes.length < 16 ? bytes.length : 16;
    final preview = latin1.decode(
      bytes.take(previewLength).toList(),
      allowInvalid: true,
    );
    final isHttp =
        preview.startsWith('GET ') ||
        preview.startsWith('POST ') ||
        preview.startsWith('OPTIONS ');
    if (!isHttp) {
      final newline = bytes.indexOf(10);
      if (newline > maxLineBytes) {
        throw const FormatException('Relay request line too large.');
      }
      return newline == -1 ? null : newline + 1;
    }

    final headerEnd = _httpHeaderEnd(bytes);
    if (headerEnd == null) {
      if (bytes.length > maxLineBytes) {
        throw const FormatException('HTTP relay headers too large.');
      }
      return null;
    }
    final headerText = latin1.decode(
      bytes.take(headerEnd.headerBytes).toList(),
      allowInvalid: true,
    );
    final contentLength = _httpContentLength(headerText);
    if (contentLength > maxLineBytes) {
      throw const FormatException('HTTP relay POST body too large.');
    }
    return bytes.length >= headerEnd.totalHeaderBytes + contentLength
        ? headerEnd.totalHeaderBytes + contentLength
        : null;
  }

  _HttpHeaderEnd? _httpHeaderEnd(List<int> bytes) {
    for (var index = 0; index <= bytes.length - 4; index++) {
      if (bytes[index] == 13 &&
          bytes[index + 1] == 10 &&
          bytes[index + 2] == 13 &&
          bytes[index + 3] == 10) {
        return _HttpHeaderEnd(headerBytes: index, totalHeaderBytes: index + 4);
      }
    }
    for (var index = 0; index <= bytes.length - 2; index++) {
      if (bytes[index] == 10 && bytes[index + 1] == 10) {
        return _HttpHeaderEnd(headerBytes: index, totalHeaderBytes: index + 2);
      }
    }
    return null;
  }

  int _httpContentLength(String headerText) {
    for (final line in const LineSplitter().convert(headerText)) {
      final separator = line.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      final name = line.substring(0, separator).trim().toLowerCase();
      if (name != 'content-length') {
        continue;
      }
      final value = int.tryParse(line.substring(separator + 1).trim());
      if (value == null || value < 0) {
        throw const FormatException('Invalid HTTP content-length.');
      }
      return value;
    }
    return 0;
  }

  _RelayWireRequest _parseWireRequest(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('GET ') ||
        text.startsWith('POST ') ||
        text.startsWith('OPTIONS ')) {
      final headerEnd = _httpHeaderEnd(bytes);
      if (headerEnd == null) {
        throw const FormatException('HTTP relay request has no headers.');
      }
      final firstLine = text.split(RegExp(r'\r?\n')).first;
      final parts = firstLine.split(' ');
      final method = parts.isEmpty ? '' : parts.first.toUpperCase();
      if (method == 'GET' || method == 'OPTIONS') {
        return const _RelayWireRequest(
          isHttp: true,
          request: {'action': 'health'},
        );
      }
      if (method != 'POST') {
        throw FormatException('Unsupported HTTP relay method: $method');
      }
      final bodyBytes = bytes.sublist(headerEnd.totalHeaderBytes);
      final request = jsonDecode(utf8.decode(bodyBytes));
      if (request is! Map<String, dynamic>) {
        throw const FormatException('HTTP relay body must be a JSON object.');
      }
      return _RelayWireRequest(isHttp: true, request: request);
    }

    final firstLine = text.split(RegExp(r'\r?\n')).first;
    final request = jsonDecode(firstLine);
    if (request is! Map<String, dynamic>) {
      throw const FormatException('TCP relay line must be a JSON object.');
    }
    return _RelayWireRequest(isHttp: false, request: request);
  }

  void _writeHttpResponse(
    Socket socket,
    Map<String, dynamic> response, {
    int statusCode = 200,
  }) {
    final body = utf8.encode(jsonEncode(response));
    final statusText = statusCode == 200 ? 'OK' : 'Bad Request';
    socket.add(
      utf8.encode(
        'HTTP/1.1 $statusCode $statusText\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${body.length}\r\n'
        'Cache-Control: no-store\r\n'
        'Access-Control-Allow-Origin: *\r\n'
        'Access-Control-Allow-Headers: content-type, bypass-tunnel-reminder, ngrok-skip-browser-warning\r\n'
        'Connection: close\r\n'
        '\r\n',
      ),
    );
    socket.add(body);
  }

  void _handleUdpEvent(RawSocketEvent event) {
    final socket = _udpSocket;
    if (socket == null || event != RawSocketEvent.read) {
      return;
    }
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      final response = _handleUdpDatagram(datagram!);
      socket.send(
        utf8.encode(jsonEncode(response)),
        datagram.address,
        datagram.port,
      );
    }
  }

  Map<String, dynamic> _handleUdpDatagram(Datagram datagram) {
    try {
      if (datagram.data.length > maxLineBytes) {
        throw const FormatException('UDP relay request too large.');
      }
      final request = jsonDecode(utf8.decode(datagram.data));
      if (request is! Map<String, dynamic>) {
        throw const FormatException('UDP relay request must be a JSON object.');
      }
      return _handleRequest(request, peer: datagram.address.address);
    } catch (error) {
      return {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': error.toString(),
      };
    }
  }

  Map<String, dynamic> _handleRequest(
    Map<String, dynamic> request, {
    required String peer,
  }) {
    _cleanup();
    if (!_allowRequest(peer)) {
      return {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': 'rate limit exceeded',
      };
    }
    final action = request['action'] as String?;
    try {
      switch (action) {
        case 'store':
          final recipientDeviceId = request['recipient_device_id'] as String;
          final envelope = RelayEnvelope.fromJson(
            request['envelope'] as Map<String, dynamic>,
          );
          _store(recipientDeviceId, envelope);
          return {'ok': true, 'stored': true, 'messages': const []};
        case 'fetch':
          final recipientDeviceId = request['recipient_device_id'] as String;
          final limit = request['limit'] as int? ?? maxFetchLimit;
          final messages = _fetch(
            recipientDeviceId,
            limit,
          ).map((envelope) => envelope.toJson()).toList(growable: false);
          return {'ok': true, 'stored': false, 'messages': messages};
        case 'health':
          return {
            'ok': true,
            'stored': false,
            'messages': const [],
            'stats': {
              'relay_id': relayId,
              'queue_count': _queues.length,
              'queued_envelope_count': _queues.values.fold<int>(
                0,
                (count, queue) => count + queue.length,
              ),
              'ttl_seconds': ttl.inSeconds,
              'max_queue_per_mailbox': maxQueuePerMailbox,
              'max_fetch_limit': maxFetchLimit,
            },
          };
        default:
          return {
            'ok': false,
            'stored': false,
            'messages': const [],
            'error': 'Unsupported action: $action',
          };
      }
    } catch (error) {
      return {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': error.toString(),
      };
    }
  }

  void _store(String recipientDeviceId, RelayEnvelope envelope) {
    _validateMailboxId(recipientDeviceId);
    final envelopeBytes = utf8.encode(jsonEncode(envelope.toJson()));
    if (envelopeBytes.length > maxEnvelopeBytes) {
      throw StateError(
        'envelope too large: ${envelopeBytes.length} bytes > $maxEnvelopeBytes',
      );
    }
    final queue = _queues.putIfAbsent(recipientDeviceId, Queue.new);
    if (envelope.kind == 'pairing_announcement') {
      final retained = queue
          .where(
            (entry) =>
                entry.envelope.kind != 'pairing_announcement' ||
                entry.envelope.senderDeviceId != envelope.senderDeviceId,
          )
          .toList(growable: false);
      queue
        ..clear()
        ..addAll(retained);
    }
    while (queue.length >= maxQueuePerMailbox) {
      final entries = queue.toList(growable: false);
      final dropIndex = entries.indexWhere(
        (entry) => entry.envelope.kind != 'pairing_announcement',
      );
      if (dropIndex <= 0) {
        queue.removeFirst();
      } else {
        queue
          ..clear()
          ..addAll([
            ...entries.take(dropIndex),
            ...entries.skip(dropIndex + 1),
          ]);
      }
    }
    queue.add(
      _QueueEntry(queuedAt: _nowProvider().toUtc(), envelope: envelope),
    );
    onEnvelopeStored?.call(recipientDeviceId, envelope);
  }

  List<RelayEnvelope> _fetch(String recipientDeviceId, int requestedLimit) {
    _validateMailboxId(recipientDeviceId);
    final limit = requestedLimit.clamp(1, maxFetchLimit);
    final queue = _queues.putIfAbsent(recipientDeviceId, Queue.new);
    final messages = <RelayEnvelope>[];
    final entries = queue.toList(growable: false);
    queue.clear();
    for (final entry in entries) {
      if (messages.length < limit) {
        messages.add(entry.envelope);
        if (entry.envelope.kind == 'pairing_announcement') {
          queue.add(entry);
        }
      } else {
        queue.add(entry);
      }
    }
    return messages;
  }

  bool _allowRequest(String peer) {
    final now = _nowProvider().toUtc();
    _rateBuckets.removeWhere(
      (_, bucket) =>
          now.difference(bucket.windowStarted) >= const Duration(minutes: 2),
    );
    final bucket = _rateBuckets.putIfAbsent(
      peer,
      () => _RateBucket(windowStarted: now),
    );
    if (now.difference(bucket.windowStarted) >= const Duration(minutes: 1)) {
      bucket.windowStarted = now;
      bucket.count = 0;
    }
    if (bucket.count >= maxRequestsPerMinute) {
      return false;
    }
    bucket.count++;
    return true;
  }

  void _validateMailboxId(String value) {
    if (value.isEmpty || value.length > 160) {
      throw ArgumentError('mailbox id must be 1..160 characters');
    }
    for (final codeUnit in value.codeUnits) {
      final isAlphaNumeric =
          (codeUnit >= 48 && codeUnit <= 57) ||
          (codeUnit >= 65 && codeUnit <= 90) ||
          (codeUnit >= 97 && codeUnit <= 122);
      final isAllowedSymbol =
          codeUnit == 45 || codeUnit == 95 || codeUnit == 46 || codeUnit == 58;
      if (!isAlphaNumeric && !isAllowedSymbol) {
        throw ArgumentError('mailbox id contains unsupported characters');
      }
    }
  }

  void _cleanup() {
    final cutoff = _nowProvider().toUtc().subtract(ttl);
    final recipients = _queues.keys.toList(growable: false);
    for (final recipient in recipients) {
      final queue = _queues[recipient];
      if (queue == null) {
        continue;
      }
      while (queue.isNotEmpty && queue.first.queuedAt.isBefore(cutoff)) {
        queue.removeFirst();
      }
      if (queue.isEmpty) {
        _queues.remove(recipient);
      }
    }
  }
}

class _RateBucket {
  _RateBucket({required this.windowStarted});

  DateTime windowStarted;
  int count = 0;
}

class _QueueEntry {
  const _QueueEntry({required this.queuedAt, required this.envelope});

  final DateTime queuedAt;
  final RelayEnvelope envelope;
}

class _RelayWireRequest {
  const _RelayWireRequest({required this.isHttp, required this.request});

  final bool isHttp;
  final Map<String, dynamic> request;
}

class _HttpHeaderEnd {
  const _HttpHeaderEnd({
    required this.headerBytes,
    required this.totalHeaderBytes,
  });

  final int headerBytes;
  final int totalHeaderBytes;
}

Future<List<String>> discoverLanAddresses() async {
  final addresses = <String>{};
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
  } on SocketException {
    return const <String>[];
  } on OSError {
    return const <String>[];
  }
  for (final interface in interfaces) {
    if (isIgnoredLanInterfaceName(interface.name)) {
      continue;
    }
    for (final address in interface.addresses) {
      if (isLanDiscoveryAddress(address.address)) {
        addresses.add(address.address);
      }
    }
  }
  final values = addresses.toList()..sort();
  return values;
}

bool isIgnoredLanInterfaceName(String name) {
  final normalized = name.toLowerCase();
  const ignoredFragments = <String>[
    'br-',
    'bridge',
    'docker',
    'hyper-v',
    'tailscale',
    'tap',
    'tun',
    'vbox',
    'vethernet',
    'virtualbox',
    'vmnet',
    'vmware',
    'vpn',
    'veth',
    'wsl',
    'zerotier',
  ];
  return ignoredFragments.any(normalized.contains);
}

bool isLanDiscoveryAddress(String address) {
  if (address.startsWith('10.') || address.startsWith('192.168.')) {
    return true;
  }
  if (address.startsWith('169.254.')) {
    return true;
  }
  if (address.startsWith('172.')) {
    final parts = address.split('.');
    if (parts.length > 1) {
      final second = int.tryParse(parts[1]);
      if (second != null && second >= 16 && second <= 31) {
        return true;
      }
    }
  }
  return false;
}
