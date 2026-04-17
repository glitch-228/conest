import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

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
    try {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 4));
      final request = jsonDecode(line) as Map<String, dynamic>;
      final response = _handleRequest(request);
      socket.writeln(jsonEncode(response));
      await socket.flush();
    } catch (error) {
      socket.writeln(
        jsonEncode({
          'ok': false,
          'stored': false,
          'messages': const [],
          'error': error.toString(),
        }),
      );
      await socket.flush();
    } finally {
      await socket.close();
    }
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
    if (_isIgnoredLanInterface(interface.name)) {
      continue;
    }
    for (final address in interface.addresses) {
      if (_isLanAddress(address.address)) {
        addresses.add(address.address);
      }
    }
  }
  final values = addresses.toList()..sort();
  return values;
}

bool _isIgnoredLanInterface(String name) {
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

bool _isLanAddress(String address) {
  if (_isLikelyVirtualGatewayAddress(address)) {
    return false;
  }
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

bool _isLikelyVirtualGatewayAddress(String address) {
  final parts = address.split('.');
  if (parts.length != 4) {
    return false;
  }
  final second = int.tryParse(parts[1]);
  final last = int.tryParse(parts[3]);
  return address.startsWith('172.') &&
      second != null &&
      second >= 16 &&
      second <= 31 &&
      last == 1;
}
