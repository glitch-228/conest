import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

class RelayHealthInfo {
  const RelayHealthInfo({required this.ok, this.relayInstanceId});

  final bool ok;
  final String? relayInstanceId;
}

class RelayClient {
  const RelayClient();

  Future<Duration> probe({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final stopwatch = Stopwatch()..start();
    final info = await inspectHealth(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
    );
    stopwatch.stop();
    if (!info.ok) {
      throw StateError('Relay health check failed.');
    }
    return stopwatch.elapsed;
  }

  Future<bool> storeEnvelope({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    required RelayEnvelope envelope,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final response = await _sendRequest(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      request: {
        'action': 'store',
        'recipient_device_id': recipientDeviceId,
        'envelope': envelope.toJson(),
      },
    );
    return response['stored'] == true;
  }

  Future<List<RelayEnvelope>> fetchEnvelopes({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    int limit = 64,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final response = await _sendRequest(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      request: {
        'action': 'fetch',
        'recipient_device_id': recipientDeviceId,
        'limit': limit,
      },
    );
    final rawMessages = (response['messages'] as List<dynamic>? ?? const [])
        .cast<dynamic>();
    return rawMessages
        .map(
          (message) => RelayEnvelope.fromJson(message as Map<String, dynamic>),
        )
        .toList();
  }

  Future<bool> health({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final info = await inspectHealth(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
    );
    return info.ok;
  }

  Future<RelayHealthInfo> inspectHealth({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final response = await _sendRequest(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      request: const {'action': 'health'},
    );
    final stats = response['stats'];
    final relayId = stats is Map<String, dynamic>
        ? stats['relay_id'] as String?
        : response['relay_id'] as String?;
    return RelayHealthInfo(
      ok: response['ok'] == true,
      relayInstanceId: relayId,
    );
  }

  Future<Map<String, dynamic>> _sendRequest({
    required String host,
    required int port,
    required PeerRouteProtocol protocol,
    required Duration timeout,
    required Map<String, dynamic> request,
  }) async {
    return switch (protocol) {
      PeerRouteProtocol.tcp => _sendTcpRequest(
        host: host,
        port: port,
        timeout: timeout,
        request: request,
      ),
      PeerRouteProtocol.udp => _sendUdpRequest(
        host: host,
        port: port,
        timeout: timeout,
        request: request,
      ),
    };
  }

  Future<Map<String, dynamic>> _sendTcpRequest({
    required String host,
    required int port,
    required Duration timeout,
    required Map<String, dynamic> request,
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    try {
      socket.writeln(jsonEncode(request));
      await socket.flush();
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(timeout);
      return _decodeResponse(line);
    } finally {
      await socket.close();
    }
  }

  Future<Map<String, dynamic>> _sendUdpRequest({
    required String host,
    required int port,
    required Duration timeout,
    required Map<String, dynamic> request,
  }) async {
    final requestBytes = utf8.encode(jsonEncode(request));
    if (requestBytes.length > 60 * 1024) {
      throw StateError('UDP relay request is too large for a single datagram.');
    }
    final addresses = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(timeout);
    if (addresses.isEmpty) {
      throw StateError('No address found for UDP relay host $host.');
    }
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final responses = StreamController<Datagram>.broadcast();
    late final StreamSubscription<RawSocketEvent> subscription;
    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        responses.add(datagram!);
      }
    });

    final perAttempt = _udpAttemptTimeout(timeout);
    try {
      for (final address in addresses.take(2)) {
        for (var attempt = 0; attempt < 3; attempt++) {
          final responseFuture = responses.stream.first.timeout(perAttempt);
          socket.send(requestBytes, address, port);
          try {
            final datagram = await responseFuture;
            return _decodeResponse(utf8.decode(datagram.data));
          } catch (_) {
            // Retry below.
          }
        }
      }
      throw TimeoutException('UDP relay did not answer.', timeout);
    } finally {
      await subscription.cancel();
      await responses.close();
      socket.close();
    }
  }

  Duration _udpAttemptTimeout(Duration timeout) {
    final milliseconds = timeout.inMilliseconds;
    if (milliseconds <= 0) {
      return const Duration(seconds: 1);
    }
    return Duration(
      milliseconds: (milliseconds / 3).ceil().clamp(300, milliseconds),
    );
  }

  Map<String, dynamic> _decodeResponse(String line) {
    final response = jsonDecode(line) as Map<String, dynamic>;
    if (response['ok'] == false) {
      throw StateError(response['error'] as String? ?? 'Relay request failed.');
    }
    return response;
  }
}
