import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

class LocalRelayNode {
  LocalRelayNode({this.ttl = const Duration(days: 7), String? relayId})
    : relayId = relayId ?? 'local-${DateTime.now().microsecondsSinceEpoch}';

  final Duration ttl;
  final String relayId;
  void Function(String recipientDeviceId, RelayEnvelope envelope)?
  onEnvelopeStored;
  final Map<String, Queue<_QueueEntry>> _queues = {};
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
      final response = _handleRequest(wireRequest.request);
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
      final completion = _wireRequestCompletion(bytes);
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
      return newline == -1 ? null : newline + 1;
    }

    final headerEnd = _httpHeaderEnd(bytes);
    if (headerEnd == null) {
      return null;
    }
    final headerText = latin1.decode(
      bytes.take(headerEnd.headerBytes).toList(),
      allowInvalid: true,
    );
    final contentLength = _httpContentLength(headerText);
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
      return int.tryParse(line.substring(separator + 1).trim()) ?? 0;
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
      final request = jsonDecode(utf8.decode(datagram.data));
      if (request is! Map<String, dynamic>) {
        throw const FormatException('UDP relay request must be a JSON object.');
      }
      return _handleRequest(request);
    } catch (error) {
      return {
        'ok': false,
        'stored': false,
        'messages': const [],
        'error': error.toString(),
      };
    }
  }

  Map<String, dynamic> _handleRequest(Map<String, dynamic> request) {
    _cleanup();
    final action = request['action'] as String?;
    switch (action) {
      case 'store':
        final recipientDeviceId = request['recipient_device_id'] as String;
        final envelope = RelayEnvelope.fromJson(
          request['envelope'] as Map<String, dynamic>,
        );
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
        queue.add(
          _QueueEntry(queuedAt: DateTime.now().toUtc(), envelope: envelope),
        );
        onEnvelopeStored?.call(recipientDeviceId, envelope);
        return {'ok': true, 'stored': true, 'messages': const []};
      case 'fetch':
        final recipientDeviceId = request['recipient_device_id'] as String;
        final limit = request['limit'] as int? ?? 64;
        final queue = _queues.putIfAbsent(recipientDeviceId, Queue.new);
        final messages = <Map<String, dynamic>>[];
        final entries = queue.toList(growable: false);
        queue.clear();
        for (final entry in entries) {
          if (messages.length < limit) {
            messages.add(entry.envelope.toJson());
            if (entry.envelope.kind == 'pairing_announcement') {
              queue.add(entry);
            }
          } else {
            queue.add(entry);
          }
        }
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
  }

  void _cleanup() {
    final cutoff = DateTime.now().toUtc().subtract(ttl);
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
