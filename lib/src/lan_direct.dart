import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// nightly.9 LocalSend-style direct PUT transport. Every chunk delivered via
/// the relay envelope shape still has to round-trip through a third-party
/// store-and-forward; even on a gigabit LAN that dominates wall-clock. This
/// transport keeps the existing crypto (RelayEnvelope already contains a
/// ChaCha20-Poly1305 ciphertext) but ships the envelope over a direct HTTP
/// PUT between peers when their IP + port are known. The control plane
/// (offer / chunk_request / complete) stays on the relay so handshake
/// reliability is preserved.
abstract class LanDirectChannel {
  /// Port the local HTTP server is bound to, or null if not started / the
  /// platform refused to bind. Receivers piggy-back this in their next
  /// `attachment_offer` / `attachment_chunk_request` payload so the peer
  /// learns where to PUT future chunks.
  int? get localPort;

  bool get isRunning;

  /// Best-effort start. Returns the bound port or null if the platform
  /// refused (web sandbox, locked-down CI). The controller treats null as
  /// "fast-path disabled" and uses only the existing relay path.
  Future<int?> start();

  Future<void> stop();

  /// Send an already-encrypted [envelope] directly to [host]:[port]. The
  /// remote peer dispatches it into its existing envelope-processing
  /// pipeline (same code path that handles relay-delivered envelopes).
  /// Returns true on 2xx, false otherwise.
  Future<bool> putEnvelope({
    required String host,
    required int port,
    required RelayEnvelope envelope,
    Duration timeout = const Duration(seconds: 10),
  });

  /// Handler invoked for every PUT the server accepts. The controller
  /// installs a callback that decrypts + dispatches via its existing
  /// `_handleAttachmentEnvelope` path.
  set onEnvelope(Future<void> Function(RelayEnvelope envelope) handler);

  /// nightly.12: cheap TCP-level probe used by the controller before
  /// demoting a peer to relay-only on PUT failure. A single PUT can fail
  /// for many reasons (network jitter, peer briefly busy serving another
  /// chunk, Wi-Fi handoff); the probe distinguishes "peer's HTTP server
  /// is actually unreachable" from a transient blip.
  Future<bool> probeReachable({
    required String host,
    required int port,
    Duration timeout = const Duration(milliseconds: 500),
  });
}

/// Real `dart:io` implementation. Skipped on platforms that can't bind a
/// port (web). Tests inject a fake.
class HttpLanDirectChannel implements LanDirectChannel {
  static const int _maxRequestBytes = 2 * 1024 * 1024;
  static const int _maxConcurrentHandlers = 8;
  static const int _maxRequestsPerMinutePerIp = 120;
  static const int _maxBytesPerMinutePerIp = 64 * 1024 * 1024;
  static const Duration _readTimeout = Duration(seconds: 15);

  HttpServer? _server;
  Future<void> Function(RelayEnvelope envelope)? _handler;
  final Map<String, _LanRateBucket> _rateBuckets = <String, _LanRateBucket>{};
  int _activeHandlers = 0;

  @override
  int? get localPort => _server?.port;

  @override
  bool get isRunning => _server != null;

  @override
  set onEnvelope(Future<void> Function(RelayEnvelope envelope) handler) {
    _handler = handler;
  }

  @override
  Future<int?> start() async {
    if (_server != null) return _server!.port;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server!.listen(_onRequest, onError: (_) {}, cancelOnError: false);
      return _server!.port;
    } catch (_) {
      _server = null;
      return null;
    }
  }

  @override
  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (_activeHandlers >= _maxConcurrentHandlers) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    _activeHandlers++;
    try {
      if (req.method != 'PUT' || req.uri.path != '/v1/chunk') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final declaredLength = req.contentLength;
      if (declaredLength > _maxRequestBytes) {
        req.response.statusCode = HttpStatus.requestEntityTooLarge;
        await req.response.close();
        return;
      }
      final remoteIp = req.connectionInfo?.remoteAddress.address;
      if (remoteIp == null || !_allowRequest(remoteIp, declaredLength)) {
        req.response.statusCode = HttpStatus.tooManyRequests;
        await req.response.close();
        return;
      }
      final body = await _readBodyBounded(req, remoteIp).timeout(_readTimeout);
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map<String, dynamic>) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      RelayEnvelope envelope;
      try {
        envelope = RelayEnvelope.fromJson(decoded);
      } catch (_) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final handler = _handler;
      if (handler == null) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
        return;
      }
      // Crypto failures (unknown sender / MAC mismatch) are absorbed
      // by the handler; an HTTP 200 just means "we received your bytes".
      // The peer learns whether the chunk actually landed via the next
      // attachment_progress / chunk_request retry.
      await handler(envelope);
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
    } on _LanRequestTooLarge {
      try {
        req.response.statusCode = HttpStatus.requestEntityTooLarge;
        await req.response.close();
      } catch (_) {}
    } on _LanRateLimitExceeded {
      try {
        req.response.statusCode = HttpStatus.tooManyRequests;
        await req.response.close();
      } catch (_) {}
    } on TimeoutException {
      try {
        req.response.statusCode = HttpStatus.requestTimeout;
        await req.response.close();
      } catch (_) {}
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    } finally {
      _activeHandlers--;
    }
  }

  bool _allowRequest(String ip, int declaredLength) {
    final now = DateTime.now().toUtc();
    _rateBuckets.removeWhere(
      (_, bucket) =>
          now.difference(bucket.windowStartedAt) > const Duration(minutes: 2),
    );
    if (_rateBuckets.length >= 1024 && !_rateBuckets.containsKey(ip)) {
      return false;
    }
    final bucket = _rateBuckets.putIfAbsent(ip, () => _LanRateBucket(now));
    bucket.resetIfExpired(now);
    if (bucket.requests >= _maxRequestsPerMinutePerIp ||
        (declaredLength >= 0 &&
            bucket.bytes + declaredLength > _maxBytesPerMinutePerIp)) {
      return false;
    }
    bucket.requests++;
    return true;
  }

  Future<Uint8List> _readBodyBounded(HttpRequest request, String ip) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > _maxRequestBytes) {
        throw const _LanRequestTooLarge();
      }
      final bucket = _rateBuckets[ip];
      if (bucket == null ||
          bucket.bytes + chunk.length > _maxBytesPerMinutePerIp) {
        throw const _LanRateLimitExceeded();
      }
      bucket.bytes += chunk.length;
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<bool> probeReachable({
    required String host,
    required int port,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    if (!isValidLanDirectHost(host) || !isValidPeerEndpointPort(port)) {
      return false;
    }
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> putEnvelope({
    required String host,
    required int port,
    required RelayEnvelope envelope,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!isValidLanDirectHost(host) || !isValidPeerEndpointPort(port)) {
      return false;
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 1500);
    try {
      final uri = Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: '/v1/chunk',
      );
      final req = await client.putUrl(uri).timeout(timeout);
      req.headers.contentType = ContentType('application', 'octet-stream');
      final body = utf8.encode(jsonEncode(envelope.toJson()));
      if (body.length > _maxRequestBytes) return false;
      req.contentLength = body.length;
      req.add(body);
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>();
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

bool isValidLanDirectHost(String host) {
  final address = InternetAddress.tryParse(host.trim());
  if (address == null || address.address != host.trim()) return false;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    final a = bytes[0];
    final b = bytes[1];
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254);
  }
  if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
    return (bytes[0] & 0xfe) == 0xfc ||
        (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
  }
  return false;
}

class _LanRateBucket {
  _LanRateBucket(this.windowStartedAt);

  DateTime windowStartedAt;
  int requests = 0;
  int bytes = 0;

  void resetIfExpired(DateTime now) {
    if (now.difference(windowStartedAt) < const Duration(minutes: 1)) return;
    windowStartedAt = now;
    requests = 0;
    bytes = 0;
  }
}

class _LanRequestTooLarge implements Exception {
  const _LanRequestTooLarge();
}

class _LanRateLimitExceeded implements Exception {
  const _LanRateLimitExceeded();
}

/// Cached endpoint for a peer's LAN-direct server. Populated whenever an
/// offer or chunk_request envelope arrives carrying the peer's port.
class LanDirectEndpoint {
  LanDirectEndpoint({
    required this.host,
    required this.port,
    required this.cachedAt,
    this.consecutiveFailures = 0,
    this.demotedUntil,
  });

  final String host;
  final int port;
  final DateTime cachedAt;
  int consecutiveFailures;
  DateTime? demotedUntil;
}
