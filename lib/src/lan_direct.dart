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
}

/// Real `dart:io` implementation. Skipped on platforms that can't bind a
/// port (web). Tests inject a fake.
class HttpLanDirectChannel implements LanDirectChannel {
  HttpServer? _server;
  Future<void> Function(RelayEnvelope envelope)? _handler;

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
    try {
      if (req.method != 'PUT' || req.uri.path != '/v1/chunk') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final builder = BytesBuilder(copy: false);
      var total = 0;
      // 32 MB hard cap — a single relay envelope ciphertext should never
      // exceed a few hundred KB. Anything larger is malicious or broken.
      const maxBytes = 32 * 1024 * 1024;
      await for (final chunk in req) {
        total += chunk.length;
        if (total > maxBytes) {
          req.response.statusCode = HttpStatus.requestEntityTooLarge;
          await req.response.close();
          return;
        }
        builder.add(chunk);
      }
      final body = builder.takeBytes();
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
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  @override
  Future<bool> putEnvelope({
    required String host,
    required int port,
    required RelayEnvelope envelope,
    Duration timeout = const Duration(seconds: 10),
  }) async {
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
