import 'dart:async';
import 'dart:collection';
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

/// Optional high-throughput extension implemented by the production LAN
/// channel. Attachment blocks are already XChaCha20-Poly1305 encrypted with
/// manifest-bound associated data, so wrapping them in another encrypted
/// JSON/base64 RelayEnvelope on a trusted direct socket only wastes CPU and
/// bandwidth. Control envelopes continue through [LanDirectChannel].
abstract class BinaryLanDirectChannel {
  set onAttachmentBlock(
    Future<void> Function(LanAttachmentBlock block) handler,
  );

  Future<bool> putAttachmentBlock({
    required String host,
    required int port,
    required LanAttachmentBlock block,
    Duration timeout = const Duration(seconds: 10),
  });
}

class LanAttachmentBlock {
  const LanAttachmentBlock({
    required this.attachmentId,
    required this.index,
    required this.hash,
    required this.ciphertext,
  });

  final String attachmentId;
  final int index;
  final Uint8List hash;
  final Uint8List ciphertext;
}

/// Real `dart:io` implementation. Skipped on platforms that can't bind a
/// port (web). Tests inject a fake.
class HttpLanDirectChannel implements LanDirectChannel, BinaryLanDirectChannel {
  static const int _maxRequestBytes = 5 * 1024 * 1024;
  static const int _maxConcurrentHandlers = 32;
  static const int _maxConcurrentEnvelopeHandlers = 8;
  static const int _maxQueuedEnvelopes = 64;

  // A v2 attachment uses one request per independently verified block.
  // The old 120 request / 64 MiB limits therefore throttled every real LAN
  // transfer after roughly 15 MiB and made it look as if the route had died.
  // Body and concurrency bounds remain the primary LAN DoS controls; these
  // generous per-minute ceilings accommodate the supported 2 GiB payload.
  static const int _maxRequestsPerMinutePerIp = 20 * 1024;
  static const int _maxBytesPerMinutePerIp = 4 * 1024 * 1024 * 1024;
  static const Duration _readTimeout = Duration(seconds: 15);

  HttpServer? _server;
  HttpClient? _outboundClient;
  Future<void> Function(RelayEnvelope envelope)? _handler;
  Future<void> Function(LanAttachmentBlock block)? _blockHandler;
  final Map<String, _LanRateBucket> _rateBuckets = <String, _LanRateBucket>{};
  final Queue<_QueuedLanEnvelope> _pendingEnvelopes =
      Queue<_QueuedLanEnvelope>();
  final Queue<_QueuedLanBlock> _pendingBlocks = Queue<_QueuedLanBlock>();
  int _activeHandlers = 0;
  int _activeEnvelopeHandlers = 0;
  int _acceptedEnvelopeCount = 0;
  int _acceptedAttachmentChunkCount = 0;
  int _successfulAttachmentChunkPutCount = 0;

  /// Lifetime counters used by the nightly diagnostics and real-socket
  /// integration tests. They contain no peer or payload data.
  int get acceptedEnvelopeCount => _acceptedEnvelopeCount;
  int get acceptedAttachmentChunkCount => _acceptedAttachmentChunkCount;
  int get successfulAttachmentChunkPutCount =>
      _successfulAttachmentChunkPutCount;

  @override
  int? get localPort => _server?.port;

  @override
  bool get isRunning => _server != null;

  @override
  set onEnvelope(Future<void> Function(RelayEnvelope envelope) handler) {
    _handler = handler;
  }

  @override
  set onAttachmentBlock(
    Future<void> Function(LanAttachmentBlock block) handler,
  ) {
    _blockHandler = handler;
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
    _pendingEnvelopes.clear();
    _pendingBlocks.clear();
    _outboundClient?.close(force: true);
    _outboundClient = null;
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
      final isEnvelope = req.uri.path == '/v1/chunk';
      final isBinaryBlock = req.uri.path == '/v2/block';
      if (req.method != 'PUT' || (!isEnvelope && !isBinaryBlock)) {
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
      if (_pendingEnvelopes.length + _pendingBlocks.length >=
          _maxQueuedEnvelopes) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
        return;
      }
      if (isEnvelope) {
        final decoded = jsonDecode(utf8.decode(body));
        if (decoded is! Map<String, dynamic>) {
          req.response.statusCode = HttpStatus.badRequest;
          await req.response.close();
          return;
        }
        final RelayEnvelope envelope;
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
        _pendingEnvelopes.add(_QueuedLanEnvelope(envelope, handler));
        _acceptedEnvelopeCount++;
        if (envelope.kind == 'attachment_chunk') {
          _acceptedAttachmentChunkCount++;
        }
      } else {
        final LanAttachmentBlock block;
        try {
          block = _decodeAttachmentBlock(body);
        } catch (_) {
          req.response.statusCode = HttpStatus.badRequest;
          await req.response.close();
          return;
        }
        final handler = _blockHandler;
        if (handler == null) {
          req.response.statusCode = HttpStatus.serviceUnavailable;
          await req.response.close();
          return;
        }
        _pendingBlocks.add(_QueuedLanBlock(block, handler));
        _acceptedAttachmentChunkCount++;
      }
      // A request handler may synchronously send a response envelope back to
      // the caller. Awaiting it here occupied every HTTP handler and caused a
      // nested PUT deadlock (especially with the 32-block large-file window).
      // A 202 means the bounded processing queue accepted the encrypted
      // envelope; protocol progress/retry confirms its eventual application.
      req.response.statusCode = HttpStatus.accepted;
      await req.response.close();
      _drainEnvelopeQueue();
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

  void _drainEnvelopeQueue() {
    while (_server != null &&
        _activeEnvelopeHandlers < _maxConcurrentEnvelopeHandlers &&
        (_pendingEnvelopes.isNotEmpty || _pendingBlocks.isNotEmpty)) {
      final Future<void> Function() work;
      if (_pendingBlocks.isNotEmpty) {
        final queued = _pendingBlocks.removeFirst();
        work = () => queued.handler(queued.block);
      } else {
        final queued = _pendingEnvelopes.removeFirst();
        work = () => queued.handler(queued.envelope);
      }
      _activeEnvelopeHandlers++;
      unawaited(
        Future<void>.sync(work).catchError((_) {}).whenComplete(() {
          _activeEnvelopeHandlers--;
          _drainEnvelopeQueue();
        }),
      );
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

  String? lastPutFailure;

  Future<bool> _put({
    required String host,
    required int port,
    required String path,
    required List<List<int>> segments,
    required Duration timeout,
  }) async {
    if (!isValidLanDirectHost(host) || !isValidPeerEndpointPort(port)) {
      return false;
    }
    final length = segments.fold<int>(0, (sum, bytes) => sum + bytes.length);
    if (length > _maxRequestBytes) return false;
    final client = _outboundClient ??= HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1500)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 16;
    HttpClientRequest? request;
    var expired = false;
    var finished = false;
    try {
      final accepted = await (() async {
        final opened = await client.putUrl(
          Uri(scheme: 'http', host: host, port: port, path: path),
        );
        request = opened;
        // Future.timeout does not cancel putUrl while it waits for a pooled
        // connection. Abort late arrivals as well as the current upload.
        if (expired) {
          opened.abort();
          return false;
        }
        opened.headers.contentType = ContentType('application', 'octet-stream');
        opened.contentLength = length;
        for (final segment in segments) {
          opened.add(segment);
        }
        final response = await opened.close();
        await response.drain<void>();
        finished = true;
        final ok = response.statusCode >= 200 && response.statusCode < 300;
        if (!ok) {
          lastPutFailure = '$host:$port$path HTTP ${response.statusCode}';
        }
        return ok;
      })().timeout(timeout);
      if (accepted) lastPutFailure = null;
      return accepted;
    } catch (error) {
      lastPutFailure = '$host:$port$path: $error';
      return false;
    } finally {
      expired = true;
      if (!finished) request?.abort();
    }
  }

  @override
  Future<bool> putEnvelope({
    required String host,
    required int port,
    required RelayEnvelope envelope,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final accepted = await _put(
      host: host,
      port: port,
      path: '/v1/chunk',
      segments: [utf8.encode(jsonEncode(envelope.toJson()))],
      timeout: timeout,
    );
    if (accepted && envelope.kind == 'attachment_chunk') {
      _successfulAttachmentChunkPutCount++;
    }
    return accepted;
  }

  @override
  Future<bool> putAttachmentBlock({
    required String host,
    required int port,
    required LanAttachmentBlock block,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final accepted = await _put(
      host: host,
      port: port,
      path: '/v2/block',
      segments: [_encodeAttachmentBlockHeader(block), block.ciphertext],
      timeout: timeout,
    );
    if (accepted) _successfulAttachmentChunkPutCount++;
    return accepted;
  }
}

const List<int> _binaryBlockMagic = <int>[0x43, 0x42, 0x32, 0x00];
const int _binaryBlockHeaderBytes = 4 + 1 + 2 + 4 + 4 + 32;

Uint8List _encodeAttachmentBlockHeader(LanAttachmentBlock block) {
  final id = utf8.encode(block.attachmentId);
  if (id.isEmpty ||
      id.length > 160 ||
      block.index < 0 ||
      block.hash.length != 32) {
    throw const FormatException('Invalid binary attachment block.');
  }
  final result = Uint8List(_binaryBlockHeaderBytes + id.length);
  result.setRange(0, 4, _binaryBlockMagic);
  final data = ByteData.sublistView(result);
  data.setUint8(4, 1);
  data.setUint16(5, id.length, Endian.big);
  data.setUint32(7, block.index, Endian.big);
  data.setUint32(11, block.ciphertext.length, Endian.big);
  result.setRange(15, 47, block.hash);
  result.setRange(47, 47 + id.length, id);
  return result;
}

LanAttachmentBlock _decodeAttachmentBlock(Uint8List bytes) {
  if (bytes.length < _binaryBlockHeaderBytes ||
      bytes[0] != _binaryBlockMagic[0] ||
      bytes[1] != _binaryBlockMagic[1] ||
      bytes[2] != _binaryBlockMagic[2] ||
      bytes[3] != _binaryBlockMagic[3]) {
    throw const FormatException('Invalid binary attachment block header.');
  }
  final data = ByteData.sublistView(bytes);
  if (data.getUint8(4) != 1) {
    throw const FormatException('Unsupported binary attachment block.');
  }
  final idLength = data.getUint16(5, Endian.big);
  final index = data.getUint32(7, Endian.big);
  final ciphertextLength = data.getUint32(11, Endian.big);
  final expectedLength = _binaryBlockHeaderBytes + idLength + ciphertextLength;
  if (idLength <= 0 || idLength > 160 || expectedLength != bytes.length) {
    throw const FormatException('Invalid binary attachment block length.');
  }
  final attachmentId = utf8.decode(bytes.sublist(47, 47 + idLength));
  return LanAttachmentBlock(
    attachmentId: attachmentId,
    index: index,
    hash: Uint8List.sublistView(bytes, 15, 47),
    ciphertext: Uint8List.sublistView(bytes, 47 + idLength),
  );
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

class _QueuedLanEnvelope {
  const _QueuedLanEnvelope(this.envelope, this.handler);

  final RelayEnvelope envelope;
  final Future<void> Function(RelayEnvelope envelope) handler;
}

class _QueuedLanBlock {
  const _QueuedLanBlock(this.block, this.handler);

  final LanAttachmentBlock block;
  final Future<void> Function(LanAttachmentBlock block) handler;
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
    this.binaryBlockVersion = 0,
    this.alternateHosts = const [],
  });

  final String host;
  final int port;
  DateTime cachedAt;
  int consecutiveFailures;
  DateTime? demotedUntil;
  int binaryBlockVersion;
  List<String> alternateHosts;
}
