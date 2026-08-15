import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'models.dart';

class RelayHealthInfo {
  const RelayHealthInfo({
    required this.ok,
    this.relayInstanceId,
    this.identityPublicKeyBase64,
    this.signatureVerified = false,
    this.pinnedKeyMismatch = false,
  });

  final bool ok;
  final String? relayInstanceId;

  /// Ed25519 identity key announced by the relay in its health response.
  /// Available from v0.3 relays; older relays leave this null. The client
  /// pins this on first contact and warns on mismatch.
  final String? identityPublicKeyBase64;

  /// True when the response carried a signature that verified against
  /// either the caller-supplied pinned key or the self-announced
  /// `identity_public_key` (whichever applied). Useful for surfacing
  /// "this relay is signing its responses" status in the UI.
  final bool signatureVerified;

  /// True when the caller supplied a pinned identity key and the response's
  /// signature did not verify against it (or the announced key differs).
  /// The controller surfaces a banner; we never auto-rotate the pin.
  final bool pinnedKeyMismatch;
}

/// Thrown when a relay response carries a signature that does not verify
/// against the pinned identity key supplied by the caller. The caller
/// catches this to surface a security banner without aborting unrelated
/// operations.
class RelayIdentityMismatchException implements Exception {
  RelayIdentityMismatchException(this.message);
  final String message;

  @override
  String toString() => 'RelayIdentityMismatchException: $message';
}

class _RelayCallResult {
  const _RelayCallResult({
    required this.body,
    this.announcedIdentityPublicKeyBase64,
    this.signatureVerified = false,
  });

  final Map<String, dynamic> body;
  final String? announcedIdentityPublicKeyBase64;
  final bool signatureVerified;
}

class RelayClient {
  const RelayClient();

  static const int _controlResponseLimit = 1024 * 1024;
  static const int _absoluteFetchResponseLimit = 40 * 1024 * 1024;
  static const int _httpHeaderLimit = 64 * 1024;

  Future<Duration> probe({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) async {
    final stopwatch = Stopwatch()..start();
    final info = await inspectHealth(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
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
    String? expectedIdentityPublicKeyBase64,
  }) async {
    final result = await _sendRequest(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      request: {
        'action': 'store',
        'recipient_device_id': recipientDeviceId,
        'envelope': envelope.toJson(),
      },
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
    return result.body['stored'] == true;
  }

  Future<List<RelayEnvelope>> fetchEnvelopes({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    int limit = 64,
    Duration timeout = const Duration(seconds: 4),
    Duration waitFor = Duration.zero,
    String? expectedIdentityPublicKeyBase64,
  }) async {
    // When long-polling, allow the network timeout to outlast the relay's
    // server-side wait window plus a small TCP slack.
    final effectiveTimeout = waitFor > Duration.zero
        ? waitFor + const Duration(seconds: 4)
        : timeout;
    final result = await _sendRequest(
      host: host,
      port: port,
      protocol: protocol,
      timeout: effectiveTimeout,
      request: {
        'action': 'fetch',
        'recipient_device_id': recipientDeviceId,
        'limit': limit,
        if (waitFor > Duration.zero) 'wait_ms': waitFor.inMilliseconds,
      },
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
    final rawMessages = (result.body['messages'] as List<dynamic>? ?? const [])
        .cast<dynamic>();
    final envelopes = <RelayEnvelope>[];
    for (final message in rawMessages) {
      try {
        if (message is Map<String, dynamic>) {
          envelopes.add(RelayEnvelope.fromJson(message));
        } else if (message is Map) {
          envelopes.add(
            RelayEnvelope.fromJson(Map<String, dynamic>.from(message)),
          );
        }
      } catch (_) {
        // A malformed batch item must not hide otherwise valid envelopes.
      }
    }
    return envelopes;
  }

  Future<bool> health({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) async {
    final info = await inspectHealth(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
    return info.ok;
  }

  Future<RelayHealthInfo> inspectHealth({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) async {
    final result = await _sendRequest(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      request: const {'action': 'health'},
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
    final stats = result.body['stats'];
    final relayId = stats is Map<String, dynamic>
        ? stats['relay_id'] as String?
        : result.body['relay_id'] as String?;
    return RelayHealthInfo(
      ok: result.body['ok'] == true,
      relayInstanceId: relayId,
      identityPublicKeyBase64: result.announcedIdentityPublicKeyBase64,
      signatureVerified: result.signatureVerified,
      pinnedKeyMismatch: false,
    );
  }

  Future<_RelayCallResult> _sendRequest({
    required String host,
    required int port,
    required PeerRouteProtocol protocol,
    required Duration timeout,
    required Map<String, dynamic> request,
    String? expectedIdentityPublicKeyBase64,
  }) async {
    final endpoint = _validateEndpoint(host: host, port: port);
    // Per-request nonce binds the signature to this exchange. 16 bytes is
    // enough to make replay-with-different-body collisions infeasible.
    final nonceBytes = _secureRandomBytes(16);
    final nonceBase64 = base64Encode(nonceBytes);
    final action = (request['action'] as String?) ?? '';
    final maxResponseBytes = _responseLimitFor(request);
    final signedRequest = <String, dynamic>{
      ...request,
      'nonce': nonceBase64,
      // v2 relays answer with the detached-signature wrapper — the body
      // travels as the exact signed JSON string, so verification does not
      // depend on this client's JSON encoder reproducing the relay's
      // byte-for-byte. Older relays ignore the unknown field and keep
      // sending inline-signed responses (legacy path below).
      'sig_mode': 'detached',
    };
    final body = await switch (protocol) {
      PeerRouteProtocol.tcp => _sendTcpRequest(
        host: endpoint.host,
        port: endpoint.port,
        timeout: timeout,
        request: signedRequest,
        maxResponseBytes: maxResponseBytes,
      ),
      PeerRouteProtocol.udp => _sendUdpRequest(
        host: endpoint.host,
        port: endpoint.port,
        timeout: timeout,
        request: signedRequest,
        maxResponseBytes: maxResponseBytes,
      ),
      PeerRouteProtocol.http => _sendHttpRequest(
        scheme: 'http',
        host: endpoint.host,
        port: endpoint.port,
        timeout: timeout,
        request: signedRequest,
        maxResponseBytes: maxResponseBytes,
      ),
      PeerRouteProtocol.https => _sendHttpRequest(
        scheme: 'https',
        host: endpoint.host,
        port: endpoint.port,
        timeout: timeout,
        request: signedRequest,
        maxResponseBytes: maxResponseBytes,
      ),
    };
    return _verifyResponseSignature(
      body: body,
      action: action,
      nonceBase64: nonceBase64,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
  }

  /// Validates the relay's signature over the response body. Resolution:
  ///   - If the response carries no `signature`/`nonce_echo`, treat the
  ///     relay as legacy/unsigned. Caller decides what to do.
  ///   - If `nonce_echo` doesn't match the sent nonce, treat as unsigned.
  ///   - If `expectedIdentityPublicKeyBase64` is supplied and verification
  ///     against it fails, throw [RelayIdentityMismatchException] so the
  ///     caller can surface a banner.
  ///   - Otherwise, verify against the response's self-announced
  ///     `identity_public_key` (TOFU). Sets `signatureVerified` to true
  ///     iff verification succeeds.
  Future<_RelayCallResult> _verifyResponseSignature({
    required Map<String, dynamic> body,
    required String action,
    required String nonceBase64,
    required String? expectedIdentityPublicKeyBase64,
  }) async {
    if (body['sig_v'] == 2 && body['body'] is String) {
      return _verifyDetachedResponse(
        wrapper: body,
        action: action,
        nonceBase64: nonceBase64,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      );
    }
    final stats = body['stats'];
    final announcedKey = stats is Map<String, dynamic>
        ? stats['identity_public_key'] as String?
        : null;
    final signatureBase64 = body['signature'] as String?;
    final nonceEcho = body['nonce_echo'] as String?;
    if (signatureBase64 == null || nonceEcho == null) {
      if (_hasExpectedPin(expectedIdentityPublicKeyBase64)) {
        throw RelayIdentityMismatchException(
          'Pinned relay returned an unsigned response.',
        );
      }
      return _RelayCallResult(
        body: body,
        announcedIdentityPublicKeyBase64: announcedKey,
      );
    }
    if (nonceEcho != nonceBase64) {
      if (_hasExpectedPin(expectedIdentityPublicKeyBase64)) {
        throw RelayIdentityMismatchException(
          'Pinned relay response nonce did not match the request.',
        );
      }
      return _RelayCallResult(
        body: body,
        announcedIdentityPublicKeyBase64: announcedKey,
      );
    }
    final signingInput = _signingInput(
      action: action,
      nonceBase64: nonceBase64,
      body: body,
    );
    Future<bool> verifyAgainst(String pubKeyBase64) => _verifyEd25519(
      signingInput: signingInput,
      signatureBase64: signatureBase64,
      publicKeyBase64: pubKeyBase64,
    );

    if (expectedIdentityPublicKeyBase64 != null &&
        expectedIdentityPublicKeyBase64.trim().isNotEmpty) {
      final verified = await verifyAgainst(expectedIdentityPublicKeyBase64);
      if (!verified) {
        throw RelayIdentityMismatchException(
          'Relay response signature did not verify against the pinned identity key.',
        );
      }
      // If the relay also announced a key, it must match the pinned one
      // (otherwise a malicious relay could swap keys mid-conversation).
      if (announcedKey != null &&
          announcedKey != expectedIdentityPublicKeyBase64) {
        throw RelayIdentityMismatchException(
          'Relay announced a different identity than its pinned key.',
        );
      }
      return _RelayCallResult(
        body: body,
        announcedIdentityPublicKeyBase64:
            announcedKey ?? expectedIdentityPublicKeyBase64,
        signatureVerified: true,
      );
    }
    if (announcedKey != null && announcedKey.trim().isNotEmpty) {
      final verified = await verifyAgainst(announcedKey);
      return _RelayCallResult(
        body: body,
        announcedIdentityPublicKeyBase64: announcedKey,
        signatureVerified: verified,
      );
    }
    // Signature present but nothing to verify against.
    return _RelayCallResult(
      body: body,
      announcedIdentityPublicKeyBase64: announcedKey,
    );
  }

  /// Verifies a v2 detached-signature wrapper:
  /// `{"sig_v":2,"body":"<json>","nonce_echo":…,"signature":…}`.
  ///
  /// The signature covers `action || nonce || raw body-string bytes`, so
  /// verification is independent of JSON re-encoding — the legacy inline
  /// scheme below silently degrades to "unsigned" the moment Dart's
  /// `jsonEncode` and the relay's serde output diverge (field order, float
  /// formatting like `1e30` vs `1e+30`, large integers).
  Future<_RelayCallResult> _verifyDetachedResponse({
    required Map<String, dynamic> wrapper,
    required String action,
    required String nonceBase64,
    required String? expectedIdentityPublicKeyBase64,
  }) async {
    final rawBody = wrapper['body'] as String;
    final Object? decoded;
    try {
      decoded = jsonDecode(rawBody);
    } on FormatException {
      throw StateError('Relay returned a malformed detached response body.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Relay detached response body is not a JSON object.');
    }
    final body = decoded;
    if (body['ok'] == false) {
      // Same semantics as `_decodeResponse` on the legacy path: relay-side
      // failures surface as exceptions before signature bookkeeping.
      throw StateError(body['error'] as String? ?? 'Relay request failed.');
    }
    final stats = body['stats'];
    final announcedKey = stats is Map<String, dynamic>
        ? stats['identity_public_key'] as String?
        : null;
    final signatureBase64 = wrapper['signature'] as String?;
    final nonceEcho = wrapper['nonce_echo'] as String?;
    if (signatureBase64 == null ||
        nonceEcho == null ||
        nonceEcho != nonceBase64) {
      if (_hasExpectedPin(expectedIdentityPublicKeyBase64)) {
        throw RelayIdentityMismatchException(
          signatureBase64 == null || nonceEcho == null
              ? 'Pinned relay returned an unsigned detached response.'
              : 'Pinned relay response nonce did not match the request.',
        );
      }
      return _RelayCallResult(
        body: body,
        announcedIdentityPublicKeyBase64: announcedKey,
      );
    }
    final signingInput = <int>[
      ...utf8.encode(action),
      ...base64Decode(nonceBase64),
      ...utf8.encode(rawBody),
    ];
    Future<bool> verifyAgainst(String pubKeyBase64) => _verifyEd25519(
      signingInput: signingInput,
      signatureBase64: signatureBase64,
      publicKeyBase64: pubKeyBase64,
    );

    if (expectedIdentityPublicKeyBase64 != null &&
        expectedIdentityPublicKeyBase64.trim().isNotEmpty) {
      final verified = await verifyAgainst(expectedIdentityPublicKeyBase64);
      if (!verified) {
        throw RelayIdentityMismatchException(
          'Relay response signature did not verify against the pinned identity key.',
        );
      }
      if (announcedKey != null &&
          announcedKey != expectedIdentityPublicKeyBase64) {
        throw RelayIdentityMismatchException(
          'Relay announced a different identity than its pinned key.',
        );
      }
      return _RelayCallResult(
        body: body,
        announcedIdentityPublicKeyBase64:
            announcedKey ?? expectedIdentityPublicKeyBase64,
        signatureVerified: true,
      );
    }
    if (announcedKey != null && announcedKey.trim().isNotEmpty) {
      final verified = await verifyAgainst(announcedKey);
      return _RelayCallResult(
        body: body,
        announcedIdentityPublicKeyBase64: announcedKey,
        signatureVerified: verified,
      );
    }
    return _RelayCallResult(
      body: body,
      announcedIdentityPublicKeyBase64: announcedKey,
    );
  }

  Future<bool> _verifyEd25519({
    required List<int> signingInput,
    required String signatureBase64,
    required String publicKeyBase64,
  }) async {
    final List<int> sig;
    final List<int> pub;
    try {
      sig = base64Decode(signatureBase64);
      pub = base64Decode(publicKeyBase64);
    } on FormatException {
      return false;
    }
    if (sig.length != 64 || pub.length != 32) {
      return false;
    }
    return Ed25519().verify(
      signingInput,
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519),
      ),
    );
  }

  /// Reproduces the relay's canonical signing input: `action || nonce ||
  /// canonical_body`. The canonical body is the JSON-encoded response with
  /// `nonce_echo` and `signature` removed (matching `skip_serializing_if`
  /// behavior on the relay side).
  List<int> _signingInput({
    required String action,
    required String nonceBase64,
    required Map<String, dynamic> body,
  }) {
    final stripped = Map<String, dynamic>.from(body)
      ..remove('nonce_echo')
      ..remove('signature');
    final canonical = utf8.encode(jsonEncode(stripped));
    final actionBytes = utf8.encode(action);
    final nonceBytes = base64Decode(nonceBase64);
    return <int>[...actionBytes, ...nonceBytes, ...canonical];
  }

  List<int> _secureRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  bool _hasExpectedPin(String? value) => value?.trim().isNotEmpty ?? false;

  int _responseLimitFor(Map<String, dynamic> request) {
    if (request['action'] != 'fetch') return _controlResponseLimit;
    final requested = request['limit'] is int ? request['limit'] as int : 64;
    final limit = requested.clamp(1, 128);
    return min(_absoluteFetchResponseLimit, 64 * 1024 + limit * 768 * 1024);
  }

  _ValidatedRelayEndpoint _validateEndpoint({
    required String host,
    required int port,
  }) {
    final normalizedHost =
        host.startsWith('[') && host.endsWith(']') && host.length > 2
        ? host.substring(1, host.length - 1)
        : host;
    validatePeerEndpointHostAndPort(normalizedHost, port);
    return _ValidatedRelayEndpoint(host: normalizedHost, port: port);
  }

  Future<Map<String, dynamic>> _sendTcpRequest({
    required String host,
    required int port,
    required Duration timeout,
    required Map<String, dynamic> request,
    required int maxResponseBytes,
  }) async {
    // Socket.connect's `timeout:` parameter governs the TCP handshake,
    // but Dart's implementation has historically been flaky on Android +
    // some Linux distros — connects to black-hole hosts can sit for
    // 25 s+ (observed in nightly.6 battle tests). Wrap the connect call
    // itself with a hard `.timeout()` so we never sit longer than the
    // caller asked.
    final socket = await Socket.connect(
      host,
      port,
      timeout: timeout,
    ).timeout(timeout);
    try {
      socket.writeln(jsonEncode(request));
      await socket.flush();
      final line = await _readLineBounded(
        socket,
        maxResponseBytes,
      ).timeout(timeout);
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
    required int maxResponseBytes,
  }) async {
    final requestBytes = utf8.encode(jsonEncode(request));
    if (requestBytes.length > 60 * 1024) {
      throw StateError('UDP relay request is too large for a single datagram.');
    }
    final addresses = await InternetAddress.lookup(host).timeout(timeout);
    if (addresses.isEmpty) {
      throw StateError('No address found for UDP relay host $host.');
    }
    // Prefer IPv4 (still the LAN/relay common case today) but fall back to IPv6
    // so dual-stack hosts and IPv6-only LANs (e.g. some mobile hotspots) keep
    // working.
    final orderedAddresses = <InternetAddress>[
      ...addresses.where((a) => a.type == InternetAddressType.IPv4),
      ...addresses.where((a) => a.type == InternetAddressType.IPv6),
    ];
    if (orderedAddresses.isEmpty) {
      throw StateError('No usable address found for UDP relay host $host.');
    }
    final perAttempt = _udpAttemptTimeout(timeout);
    Object? lastError;
    for (final address in orderedAddresses.take(2)) {
      final bindAddress = address.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4;
      final RawDatagramSocket socket;
      try {
        socket = await RawDatagramSocket.bind(bindAddress, 0);
      } catch (error) {
        lastError = error;
        continue;
      }
      final responses = StreamController<Datagram>.broadcast();
      final subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          responses.add(datagram!);
        }
      });
      try {
        for (var attempt = 0; attempt < 3; attempt++) {
          final responseFuture = responses.stream.first.timeout(perAttempt);
          socket.send(requestBytes, address, port);
          try {
            final datagram = await responseFuture;
            if (datagram.data.length > maxResponseBytes) {
              throw StateError('Relay response exceeded the allowed size.');
            }
            return _decodeResponse(utf8.decode(datagram.data));
          } catch (error) {
            lastError = error;
          }
        }
      } finally {
        await subscription.cancel();
        await responses.close();
        socket.close();
      }
    }
    if (lastError is Exception) {
      throw lastError;
    }
    throw TimeoutException('UDP relay did not answer.', timeout);
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

  Future<Map<String, dynamic>> _sendHttpRequest({
    required String scheme,
    required String host,
    required int port,
    required Duration timeout,
    required Map<String, dynamic> request,
    required int maxResponseBytes,
  }) async {
    // Belt-and-suspenders timeout wrap mirrors _sendTcpRequest above —
    // see the comment there for the nightly.6 25 s observation that
    // prompted this hard cap.
    final socket = scheme == 'https'
        ? await SecureSocket.connect(
            host,
            port,
            timeout: timeout,
          ).timeout(timeout)
        : await Socket.connect(host, port, timeout: timeout).timeout(timeout);
    try {
      final requestBody = utf8.encode(jsonEncode(request));
      final hostHeader = _httpHostHeader(host, port);
      final requestHead =
          'POST / HTTP/1.1\r\n'
          'Host: $hostHeader\r\n'
          'Content-Type: application/json\r\n'
          'Accept: application/json\r\n'
          'Content-Length: ${requestBody.length}\r\n'
          'Connection: close\r\n'
          // Harmless on normal relays; useful with some public HTTP tunnels.
          'bypass-tunnel-reminder: true\r\n'
          'ngrok-skip-browser-warning: true\r\n'
          '\r\n';
      socket.add(utf8.encode(requestHead));
      socket.add(requestBody);
      await socket.flush();
      final responseBytes = await _collectBounded(
        socket,
        maxResponseBytes + _httpHeaderLimit,
      ).timeout(timeout);
      final response = _decodeHttpResponse(
        responseBytes,
        maxBodyBytes: maxResponseBytes,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'HTTP relay returned ${response.statusCode}: ${_shortBody(response.body)}',
        );
      }
      return _decodeResponse(response.body);
    } finally {
      await socket.close();
    }
  }

  String _httpHostHeader(String host, int port) {
    final escapedHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return '$escapedHost:$port';
  }

  _HttpRelayResponse _decodeHttpResponse(
    List<int> bytes, {
    required int maxBodyBytes,
  }) {
    final headerEnd = _httpHeaderEnd(bytes);
    if (headerEnd == null) {
      throw const FormatException('HTTP relay response has no headers.');
    }
    if (headerEnd.headerBytes > _httpHeaderLimit) {
      throw const FormatException('HTTP relay response headers are too large.');
    }
    final headerText = latin1.decode(
      bytes.take(headerEnd.headerBytes).toList(),
      allowInvalid: true,
    );
    final statusLine = headerText.split(RegExp(r'\r?\n')).first;
    final statusParts = statusLine.split(' ');
    final statusCode = statusParts.length >= 2
        ? int.tryParse(statusParts[1]) ?? 0
        : 0;
    final bodyBytes = bytes.sublist(headerEnd.totalHeaderBytes);
    if (bodyBytes.length > maxBodyBytes) {
      throw StateError('Relay response exceeded the allowed size.');
    }
    final contentLengthMatch = RegExp(
      r'(?:^|\r?\n)content-length:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(headerText);
    final declaredLength = int.tryParse(contentLengthMatch?.group(1) ?? '');
    if (declaredLength != null &&
        (declaredLength > maxBodyBytes || declaredLength != bodyBytes.length)) {
      throw const FormatException('Invalid HTTP relay Content-Length.');
    }
    final body = utf8.decode(bodyBytes);
    return _HttpRelayResponse(statusCode: statusCode, body: body);
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

  String _shortBody(String body) {
    final normalized = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 160) {
      return normalized;
    }
    return '${normalized.substring(0, 160)}...';
  }

  Map<String, dynamic> _decodeResponse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      // Misbehaving relays / captive portals can answer with HTML or
      // truncated junk; surface a clean route failure instead of an
      // unhandled FormatException.
      throw StateError('Relay returned a malformed (non-JSON) response.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Relay response is not a JSON object.');
    }
    final response = decoded;
    if (response['ok'] == false) {
      throw StateError(response['error'] as String? ?? 'Relay request failed.');
    }
    return response;
  }

  Future<String> _readLineBounded(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      for (final byte in chunk) {
        if (byte == 10) {
          if (bytes.isNotEmpty && bytes.last == 13) bytes.removeLast();
          return utf8.decode(bytes);
        }
        bytes.add(byte);
        if (bytes.length > maxBytes) {
          throw StateError('Relay response exceeded the allowed size.');
        }
      }
    }
    if (bytes.isEmpty) throw StateError('Relay closed without a response.');
    return utf8.decode(bytes);
  }

  Future<List<int>> _collectBounded(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxBytes) {
        throw StateError('Relay response exceeded the allowed size.');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }
}

class _ValidatedRelayEndpoint {
  const _ValidatedRelayEndpoint({required this.host, required this.port});

  final String host;
  final int port;
}

class _HttpRelayResponse {
  const _HttpRelayResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class _HttpHeaderEnd {
  const _HttpHeaderEnd({
    required this.headerBytes,
    required this.totalHeaderBytes,
  });

  final int headerBytes;
  final int totalHeaderBytes;
}
