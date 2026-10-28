import 'dart:async';
import 'circumvention/circumvention.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'models.dart';
import 'native_ed25519.dart';
import 'relay_v2/borrowed_tls.dart';
import 'relay_v2/noise_nk.dart';
import 'relay_v2/session.dart';
import 'relay_v2/udp_seal.dart';
import 'relay_v2/websocket_channel.dart';

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

class RelayFetchBatch {
  const RelayFetchBatch({required this.envelopes, this.leaseId});

  final List<RelayEnvelope> envelopes;
  final String? leaseId;
  bool get requiresAcknowledgement => leaseId?.isNotEmpty ?? false;
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

/// What a relay's health said about v2 sessions, checked against the
/// identity it is pinned to.
class RelayV2Info {
  const RelayV2Info({
    required this.identityPublicKeyBase64,
    required this.noiseKey,
    required this.learnedAt,
    this.mailboxAuth = false,
    this.tier1,
    this.registration,
    this.hiddenAddress,
    this.udpSealed = false,
    this.borrowed,
  });

  final String identityPublicKeyBase64;

  /// The relay's X25519 session key (null: the relay has no sessions).
  final List<int>? noiseKey;
  final DateTime learnedAt;

  /// Whether the relay keeps mailbox owners (fetches need the owner's
  /// proof once claimed).
  final bool mailboxAuth;

  /// Who may leave messages: `open`, `registered` or `off` (null: not
  /// said).
  final String? tier1;

  /// How accounts register: `open`, `invite`, `password` or `closed`.
  final String? registration;

  /// The relay's hidden address (`wss://…`), told inside a session only.
  final String? hiddenAddress;

  /// Whether the relay opens UDP datagrams sealed under its session key.
  final bool udpSealed;

  /// The relay's borrowed-handshake address (M38-D), told inside a session.
  final ({String host, int port, String sni})? borrowed;

  bool get sessions => noiseKey != null;
}

/// What the relay's identity signs to vouch for its session key.
final List<int> relayV2BindingLabel = utf8.encode('conest-relay-noise-key-v1');

class RelayClient {
  const RelayClient();

  /// Sessions shared by every client (tests may swap it).
  static RelayV2Pool v2Pool = RelayV2Pool.shared;

  /// What each relay (by host and port) said about sessions, learned from
  /// its health answers.
  static final Map<String, RelayV2Info> _v2Known = {};
  static final Set<String> _v2Learning = {};

  /// How long a relay without sessions is not asked again.
  static const Duration _v2RecheckAfter = Duration(minutes: 30);

  /// The secret each of this app's mailboxes derives its owner keys from
  /// (by mailbox: several identities can share a process in tests).
  static final Map<String, List<int>> _mailboxSecrets = {};
  static final Map<String, SimpleKeyPair> _authKeys = {};

  /// Requests that read or acknowledge a mailbox (its owner's to make).
  static const Set<String> _ownedActions = {
    'fetch',
    'fetch_leased',
    'ack_lease',
  };

  /// Lets this app prove it owns [mailbox] (its device id) on relays that
  /// keep owners: per relay, an Ed25519 key derived from [secret] (the
  /// device's private signing key), so relays cannot link the keys and no
  /// new key needs storing.
  static void registerMailboxSecret(String mailbox, List<int> secret) {
    final known = _mailboxSecrets[mailbox];
    if (known != null && _sameBytes(known, secret)) return;
    if (_mailboxSecrets.length >= 16 && known == null) {
      _mailboxSecrets.remove(_mailboxSecrets.keys.first);
    }
    _mailboxSecrets[mailbox] = List<int>.unmodifiable(secret);
    _authKeys.removeWhere((key, _) => key.endsWith('|$mailbox'));
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  /// The owner key for [mailbox] at the relay [relayIdentity], or null when
  /// this app does not own [mailbox].
  static Future<SimpleKeyPair?> mailboxAuthKey(
    String mailbox,
    String relayIdentity,
  ) async {
    final secret = _mailboxSecrets[mailbox];
    if (secret == null) return null;
    final cacheKey = '$relayIdentity|$mailbox';
    final cached = _authKeys[cacheKey];
    if (cached != null) return cached;
    final seed = await Hmac.sha256().calculateMac(
      utf8.encode('conest-relay-mailbox-auth-v1|$relayIdentity|$mailbox'),
      secretKey: SecretKey(secret),
    );
    final pair = await Ed25519().newKeyPairFromSeed(seed.bytes);
    if (_authKeys.length >= 64) _authKeys.remove(_authKeys.keys.first);
    return _authKeys[cacheKey] = pair;
  }

  /// A v1 proof of owning [mailbox] for this request ([nonceBase64] is
  /// its nonce).
  /// What a v1 proof signs besides the action, mailbox, time and nonce: the
  /// request's lease and limit parameters (empty where it has none), so a
  /// captured proof cannot be reused with others. Mirrors the relay's
  /// `v1_auth_extra`.
  @visibleForTesting
  static String v1ProofExtra(String action, Map<String, dynamic> request) {
    String field(String name) => '${request[name] ?? ''}';
    return switch (action) {
      'fetch' => '|${field('limit')}|${field('wait_ms')}|',
      'fetch_leased' =>
        '|${field('limit')}|${field('wait_ms')}|${field('lease_ms')}',
      'ack_lease' => '${field('lease_id')}|||',
      _ => '',
    };
  }

  static Future<Map<String, dynamic>> _v1MailboxProof(
    SimpleKeyPair key,
    String action,
    String mailbox,
    String nonceBase64,
    Map<String, dynamic> request,
  ) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final extra = v1ProofExtra(action, request);
    final signature = await Ed25519().sign(
      utf8.encode(
        'conest-mailbox-auth-v1|$action|$mailbox|$ts|$nonceBase64|$extra',
      ),
      keyPair: key,
    );
    return {
      'key': base64Encode((await key.extractPublicKey()).bytes),
      'ts': ts,
      'sig': base64Encode(signature.bytes),
    };
  }

  /// Proves on [session] that this app owns [mailbox] (once per session;
  /// claims it on a relay where nobody has).
  static Future<void> _proveMailbox(
    RelayV2Session session,
    String mailbox,
    String relayIdentity,
    Duration timeout,
  ) async {
    if (session.provedMailboxes.contains(mailbox)) return;
    final key = await mailboxAuthKey(mailbox, relayIdentity);
    if (key == null) return;
    final signature = await Ed25519().sign([
      ...utf8.encode('conest-mailbox-auth-v2'),
      ...session.handshakeHash,
      ...utf8.encode(mailbox),
    ], keyPair: key);
    final answer = await session.request({
      'action': 'mailbox_auth',
      'mailbox': mailbox,
      'auth_key': base64Encode((await key.extractPublicKey()).bytes),
      'signature': base64Encode(signature.bytes),
    }, timeout: timeout);
    if (answer['ok'] != true) {
      throw StateError(answer['error'] as String? ?? 'Mailbox proof refused.');
    }
    session.provedMailboxes.add(mailbox);
  }

  static String? _hiddenAddressIn(Object? v2) {
    if (v2 is! Map<String, dynamic>) return null;
    final hidden = v2['hidden'];
    if (hidden is! String || hidden.length > 300) return null;
    final uri = Uri.tryParse(hidden);
    if (uri == null ||
        uri.scheme != 'wss' ||
        uri.host.isEmpty ||
        !isValidRelaySecretPath(uri.path)) {
      return null;
    }
    return hidden;
  }

  static ({String host, int port, String sni})? _borrowedIn(Object? v2) {
    if (v2 is! Map<String, dynamic>) return null;
    final borrowed = v2['borrowed'];
    if (borrowed is! Map<String, dynamic>) return null;
    final host = borrowed['host'];
    final port = borrowed['port'];
    final sni = borrowed['sni'];
    if (host is! String ||
        port is! int ||
        sni is! String ||
        !isValidPeerEndpointHost(host) ||
        !isValidPeerEndpointPort(port) ||
        !isValidBorrowedSni(sni)) {
      return null;
    }
    return (host: host, port: port, sni: sni);
  }

  static Future<void> _recordTlsCert(Object? v2, String identity) async {
    if (v2 is! Map<String, dynamic>) return;
    final cert = v2['tls_cert'];
    if (cert is! Map<String, dynamic>) return;
    try {
      final hash = base64Decode(cert['sha256'] as String);
      final signature = base64Decode(cert['sig'] as String);
      if (hash.length != 32) return;
      if (await verifyEd25519Signature(
        publicKey: base64Decode(identity),
        message: [...utf8.encode('conest-relay-tls-cert-v1'), ...hash],
        signature: signature,
      )) {
        if (_tlsCerts.length >= 64 && !_tlsCerts.containsKey(identity)) {
          _tlsCerts.remove(_tlsCerts.keys.first);
        }
        _tlsCerts[identity] = hash;
      }
    } on Object {
      // Not a certificate hash we can use.
    }
  }

  static String? _policyWord(Object? v2, String name, Set<String> allowed) {
    if (v2 is! Map<String, dynamic>) return null;
    final policy = v2['policy'];
    if (policy is! Map<String, dynamic>) return null;
    final value = policy[name];
    return value is String && allowed.contains(value) ? value : null;
  }

  /// Registration tokens, by relay identity (from the vault).
  static final Map<String, String> _tokens = {};

  /// Sets the tokens stores carry (inside sessions only, never in the
  /// clear) to relays that take messages from registered accounts only.
  static void setRelayTokens(Map<String, String> tokens) {
    _tokens
      ..clear()
      ..addAll(tokens);
  }

  /// When [token] (`v1.account.scope.quota.expiry.mac`) runs out.
  static DateTime? tokenExpiry(String token) {
    final parts = token.split('.');
    if (parts.length != 6) return null;
    final millis = int.tryParse(parts[4]);
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  /// Registers this app on the relay at [host]:[port] (pinned to
  /// [expectedIdentityPublicKeyBase64]) with an account key derived from
  /// [accountSecret], giving [invite] or [password] when its policy asks.
  /// Registering again refreshes the token. Returns the token.
  Future<String> register({
    required String host,
    required int port,
    required String expectedIdentityPublicKeyBase64,
    required List<int> accountSecret,
    String? invite,
    String? password,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final endpoint = _validateEndpoint(host: host, port: port);
    var known = _knownSessions(
      endpoint.host,
      endpoint.port,
      expectedIdentityPublicKeyBase64,
    );
    if (known == null) {
      await inspectHealth(
        host: host,
        port: port,
        timeout: timeout,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      );
      known = _knownSessions(
        endpoint.host,
        endpoint.port,
        expectedIdentityPublicKeyBase64,
      );
    }
    if (known == null) {
      throw StateError('This relay does not take registrations.');
    }
    final session = await _sessionFor(
      endpoint.host,
      endpoint.port,
      known,
      timeout,
    );
    final seed = await Hmac.sha256().calculateMac(
      utf8.encode('conest-relay-account-v1|$expectedIdentityPublicKeyBase64'),
      secretKey: SecretKey(accountSecret),
    );
    final account = await Ed25519().newKeyPairFromSeed(seed.bytes);
    final accountPublic = (await account.extractPublicKey()).bytes;
    final signature = await Ed25519().sign([
      ...utf8.encode('conest-relay-register-v1'),
      ...session.handshakeHash,
      ...accountPublic,
    ], keyPair: account);
    final answer = await session.request({
      'action': 'register',
      'account_key': base64Encode(accountPublic),
      'signature': base64Encode(signature.bytes),
      if (invite != null && invite.trim().isNotEmpty) 'invite': invite.trim(),
      if (password != null && password.isNotEmpty) 'password': password,
    }, timeout: timeout);
    final token = answer['token'];
    if (answer['ok'] != true || token is! String || token.length > 256) {
      throw StateError(answer['error'] as String? ?? 'Registration failed.');
    }
    _tokens[expectedIdentityPublicKeyBase64] = token;
    return token;
  }

  /// Forgets what relays said about sessions and closes them (tests).
  static Future<void> resetSessionsForTesting() async {
    _v2Known.clear();
    _v2Learning.clear();
    _mailboxSecrets.clear();
    _authKeys.clear();
    _tokens.clear();
    _wssPaths.clear();
    _borrowedSites.clear();
    _tlsCerts.clear();
    await v2Pool.closeAll();
  }

  /// What is known about [host]:[port]'s sessions (tests, diagnostics).
  static RelayV2Info? sessionInfoFor(String host, int port) =>
      _v2Known['$host:$port'];

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
    return _decodeEnvelopes(result.body);
  }

  /// Durable relay fetch. Unlike the legacy destructive fetch, returned
  /// envelopes remain queued until [acknowledgeLease] succeeds. Callers must
  /// process and persist the entire batch before acknowledging it.
  Future<RelayFetchBatch> fetchLeasedEnvelopes({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    int limit = 64,
    Duration timeout = const Duration(seconds: 4),
    Duration waitFor = Duration.zero,
    Duration leaseFor = const Duration(seconds: 60),
    String? expectedIdentityPublicKeyBase64,
  }) async {
    // A long poll may take its wait plus [timeout] for the reply (a slow
    // link needs more than the usual 4 s).
    final effectiveTimeout = waitFor > Duration.zero
        ? waitFor + timeout
        : timeout;
    final _RelayCallResult result;
    try {
      result = await _sendRequest(
        host: host,
        port: port,
        protocol: protocol,
        timeout: effectiveTimeout,
        request: {
          'action': 'fetch_leased',
          'recipient_device_id': recipientDeviceId,
          'limit': limit,
          if (waitFor > Duration.zero) 'wait_ms': waitFor.inMilliseconds,
          'lease_ms': leaseFor.inMilliseconds,
        },
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      );
    } on StateError catch (error) {
      final detail = error.message.toString().toLowerCase();
      final unsupported =
          detail.contains('unknown variant') ||
          detail.contains('unknown action') ||
          detail.contains('invalid request');
      if (!unsupported) rethrow;
      return RelayFetchBatch(
        envelopes: await fetchEnvelopes(
          host: host,
          port: port,
          protocol: protocol,
          recipientDeviceId: recipientDeviceId,
          limit: limit,
          timeout: timeout,
          waitFor: waitFor,
          expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
        ),
      );
    }
    return RelayFetchBatch(
      envelopes: _decodeEnvelopes(result.body),
      leaseId: result.body['lease_id'] as String?,
    );
  }

  Future<void> acknowledgeLease({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    required String leaseId,
    Duration timeout = const Duration(seconds: 4),
    String? expectedIdentityPublicKeyBase64,
  }) async {
    if (leaseId.length < 16 || leaseId.length > 128) {
      throw ArgumentError('Relay lease id is invalid.');
    }
    await _sendRequest(
      host: host,
      port: port,
      protocol: protocol,
      timeout: timeout,
      request: {
        'action': 'ack_lease',
        'recipient_device_id': recipientDeviceId,
        'lease_id': leaseId,
      },
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
  }

  List<RelayEnvelope> _decodeEnvelopes(Map<String, dynamic> body) {
    final rawMessages = (body['messages'] as List<dynamic>? ?? const [])
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
    final vouched = result.signatureVerified
        ? result.announcedIdentityPublicKeyBase64
        : null;
    if (stats is Map<String, dynamic> && vouched != null) {
      final endpoint = _validateEndpoint(host: host, port: port);
      await _recordSessionInfo(
        host: endpoint.host,
        port: endpoint.port,
        stats: stats,
        identityPublicKeyBase64: vouched,
      );
    }
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
    if (protocol == PeerRouteProtocol.udp &&
        action != 'health' &&
        _hasExpectedPin(expectedIdentityPublicKeyBase64)) {
      // Whether this relay seals UDP is learned from a health answer over
      // TCP, in the background (this datagram goes in the old form).
      final hostPort = '${endpoint.host}:${endpoint.port}';
      final known = _v2Known[hostPort];
      if ((known == null ||
              known.identityPublicKeyBase64 !=
                  expectedIdentityPublicKeyBase64) &&
          _v2Learning.add(hostPort)) {
        unawaited(
          inspectHealth(
                host: endpoint.host,
                port: endpoint.port,
                timeout: timeout,
                expectedIdentityPublicKeyBase64:
                    expectedIdentityPublicKeyBase64,
              )
              .then<void>((_) {}, onError: (Object _) {})
              .whenComplete(() => _v2Learning.remove(hostPort)),
        );
      }
    }
    if ((protocol == PeerRouteProtocol.tcp ||
            isHiddenRouteProtocol(protocol)) &&
        _hasExpectedPin(expectedIdentityPublicKeyBase64)) {
      final viaSession = await _trySession(
        host: endpoint.host,
        port: endpoint.port,
        protocol: protocol,
        timeout: timeout,
        request: request,
        expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64!,
        maxResponseBytes: maxResponseBytes,
      );
      if (viaSession != null) return viaSession;
    }
    final mailbox = request['recipient_device_id'];
    if (_ownedActions.contains(action) &&
        mailbox is String &&
        _hasExpectedPin(expectedIdentityPublicKeyBase64)) {
      final key = await mailboxAuthKey(
        mailbox,
        expectedIdentityPublicKeyBase64!,
      );
      if (key != null) {
        signedRequest['auth'] = await _v1MailboxProof(
          key,
          action,
          mailbox,
          nonceBase64,
          signedRequest,
        );
      }
    }
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
        sealTo: _udpSealKey(
          endpoint.host,
          endpoint.port,
          expectedIdentityPublicKeyBase64,
        ),
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
      PeerRouteProtocol.wss || PeerRouteProtocol.borrowed => _sendWssLine(
        host: endpoint.host,
        port: endpoint.port,
        timeout: timeout,
        request: signedRequest,
        maxResponseBytes: maxResponseBytes,
        pinned: _hasExpectedPin(expectedIdentityPublicKeyBase64),
        identity: expectedIdentityPublicKeyBase64,
      ),
    };
    return _verifyResponseSignature(
      body: body,
      action: action,
      nonceBase64: nonceBase64,
      expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
    );
  }

  /// Whether [host]:[port] (over [protocol], pinned to
  /// [expectedIdentityPublicKeyBase64]) is known to take subscriptions:
  /// it offered v2 sessions in a health answer signed by that identity.
  bool supportsSubscribe({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    String? expectedIdentityPublicKeyBase64,
  }) {
    if ((protocol != PeerRouteProtocol.tcp &&
            !isHiddenRouteProtocol(protocol)) ||
        !_hasExpectedPin(expectedIdentityPublicKeyBase64)) {
      return false;
    }
    final _ValidatedRelayEndpoint endpoint;
    try {
      endpoint = _validateEndpoint(host: host, port: port);
    } on ArgumentError {
      return false;
    }
    final known = _knownSessions(
      endpoint.host,
      endpoint.port,
      expectedIdentityPublicKeyBase64!,
    );
    return known != null &&
        !v2Pool.inBackoff(_sessionKey(endpoint.host, endpoint.port, known));
  }

  /// Envelopes for [recipientDeviceId] as the relay pushes them, over a
  /// v2 session: a batch per push (acknowledge its lease with
  /// [acknowledgeLease]), an empty batch once the subscription is in place
  /// and every [heartbeat] after. Ends (or fails) with the session; the
  /// caller subscribes again. Only for relays [supportsSubscribe] accepts.
  Stream<RelayFetchBatch> subscribeEnvelopes({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required String recipientDeviceId,
    int limit = 64,
    Duration leaseFor = const Duration(seconds: 60),
    Duration timeout = const Duration(seconds: 8),
    Duration heartbeat = const Duration(seconds: 30),
    String? expectedIdentityPublicKeyBase64,
  }) {
    late final StreamController<RelayFetchBatch> controller;
    StreamSubscription<Map<String, dynamic>>? inner;
    Timer? beat;
    controller = StreamController<RelayFetchBatch>(
      onListen: () async {
        try {
          if (!supportsSubscribe(
            host: host,
            port: port,
            protocol: protocol,
            expectedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
          )) {
            throw StateError('Relay does not take subscriptions.');
          }
          final endpoint = _validateEndpoint(host: host, port: port);
          final known = _knownSessions(
            endpoint.host,
            endpoint.port,
            expectedIdentityPublicKeyBase64!,
          )!;
          final session = await _sessionFor(
            endpoint.host,
            endpoint.port,
            known,
            timeout,
          );
          if (known.mailboxAuth) {
            await _proveMailbox(
              session,
              recipientDeviceId,
              expectedIdentityPublicKeyBase64,
              timeout,
            );
          }
          if (controller.isClosed) return;
          inner = session
              .subscribe({
                'action': 'subscribe',
                'mailboxes': [recipientDeviceId],
                'limit': limit.clamp(1, 128),
                'lease_ms': leaseFor.inMilliseconds,
              })
              .listen(
                (event) {
                  if (event['subscribed'] != null) {
                    controller.add(const RelayFetchBatch(envelopes: []));
                    return;
                  }
                  controller.add(
                    RelayFetchBatch(
                      envelopes: _decodeEnvelopes(event),
                      leaseId: event['lease_id'] as String?,
                    ),
                  );
                },
                onError: controller.addError,
                onDone: () {
                  beat?.cancel();
                  unawaited(controller.close());
                },
              );
          beat = Timer.periodic(heartbeat, (_) {
            if (!controller.isClosed) {
              controller.add(const RelayFetchBatch(envelopes: []));
            }
          });
        } catch (error) {
          if (!controller.isClosed) {
            controller.addError(error);
            unawaited(controller.close());
          }
        }
      },
      onCancel: () async {
        beat?.cancel();
        await inner?.cancel();
      },
    );
    return controller.stream;
  }

  RelayV2Info? _knownSessions(String host, int port, String identity) {
    final known = _v2Known['$host:$port'];
    if (known == null || known.identityPublicKeyBase64 != identity) {
      return null;
    }
    return known.sessions ? known : null;
  }

  String _sessionKey(String host, int port, RelayV2Info known) =>
      '${_wssPaths.containsKey('$host:$port')
          ? 'wss'
          : _borrowedSites.containsKey('$host:$port')
          ? 'borrowed'
          : 'tcp'}:$host:$port:'
      '${base64Encode(known.noiseKey!)}';

  /// The TLS certificate hashes relays' identities signed (learned inside
  /// sessions), by identity key: the only self-signed certificates a hidden
  /// address is trusted with.
  static final Map<String, List<int>> _tlsCerts = {};

  /// Teaches the client a certificate hash for [identity] (tests; the
  /// client learns it from a trusted session's health answer).
  @visibleForTesting
  static void debugRegisterTlsCert(String identity, List<int> sha256) =>
      _tlsCerts[identity] = sha256;

  /// Borrowed-handshake relay addresses: the site they play, by host and
  /// port (M38-D).
  static final Map<String, String> _borrowedSites = {};

  /// Tells the client that [host]:[port] plays the handshake of [sni].
  static void registerBorrowedSite(String host, int port, String sni) {
    final key = '$host:$port';
    if (_borrowedSites[key] == sni) return;
    if (_borrowedSites.length >= 64 && !_borrowedSites.containsKey(key)) {
      _borrowedSites.remove(_borrowedSites.keys.first);
    }
    _borrowedSites[key] = sni;
  }

  /// Hidden (wss) relay addresses: their secret paths, by host and port.
  static final Map<String, String> _wssPaths = {};

  /// Tells the client the secret path of the wss relay at [host]:[port]
  /// (the controller does, from its configured routes).
  static void registerWssPath(String host, int port, String path) {
    final key = '$host:$port';
    if (_wssPaths[key] == path) return;
    if (_wssPaths.length >= 64 && !_wssPaths.containsKey(key)) {
      _wssPaths.remove(_wssPaths.keys.first);
    }
    _wssPaths[key] = path;
  }

  /// The byte channel to [host]:[port]: TLS and a WebSocket for a hidden
  /// address, otherwise plain TCP. [pinned]: the relay's identity is
  /// pinned, so its certificate need not be a WebPKI one (every answer is
  /// checked against the identity; see [WebSocketRelayChannel.connect]).
  Future<RelayByteChannel> _channelTo(
    String host,
    int port,
    Duration timeout, {
    required bool pinned,
    String? identity,
  }) async {
    final path = _wssPaths['$host:$port'];
    final site = _borrowedSites['$host:$port'];
    if (path == null && site != null) {
      if (identity == null) {
        throw StateError(
          'A borrowed-handshake relay needs its pinned identity.',
        );
      }
      // The site's own certificate is checked as for any website.
      return BorrowedTlsChannel.connect(
        host: host,
        port: port,
        sni: site,
        relayIdentity: base64Decode(identity),
        timeout: timeout,
      );
    }
    if (path == null) {
      return SocketRelayChannel.connect(host, port, timeout: timeout);
    }
    return WebSocketRelayChannel.connect(
      host: host,
      port: port,
      path: path,
      pinnedCertSha256: identity == null ? null : _tlsCerts[identity],
      timeout: timeout,
    );
  }

  Future<RelayV2Session> _sessionFor(
    String host,
    int port,
    RelayV2Info known,
    Duration timeout,
  ) {
    return v2Pool.session(
      _sessionKey(host, port, known),
      () async => RelayV2Session.connect(
        // Sessions are only used with a pinned identity.
        channel: await _channelTo(
          host,
          port,
          timeout,
          pinned: true,
          identity: known.identityPublicKeyBase64,
        ),
        relayNoiseKey: known.noiseKey!,
        timeout: timeout,
      ),
    );
  }

  /// A v1 request over a hidden address: one line in, one line out, as
  /// over TCP.
  Future<Map<String, dynamic>> _sendWssLine({
    required String host,
    required int port,
    required Duration timeout,
    required Map<String, dynamic> request,
    required int maxResponseBytes,
    required bool pinned,
    String? identity,
  }) async {
    if (!_wssPaths.containsKey('$host:$port') &&
        !_borrowedSites.containsKey('$host:$port')) {
      throw StateError('The hidden relay address has no path.');
    }
    final channel = await _channelTo(
      host,
      port,
      timeout,
      pinned: pinned,
      identity: identity,
    );
    try {
      channel.add(utf8.encode('${jsonEncode(request)}\n'));
      await channel.flush();
      final line = await _readLineBounded(
        channel.input,
        maxResponseBytes,
      ).timeout(timeout);
      return _decodeResponse(line);
    } finally {
      channel.destroy();
    }
  }

  /// Sends [request] over the relay's v2 session when it has one; null to
  /// use v1 instead (no sessions known yet, or none to be had now). Once a
  /// relay is known to have sessions, an action on an owned mailbox is not
  /// repeated in cleartext v1 over plain TCP when the session fails (that
  /// would show the mailbox id and a proof to the network): the request
  /// fails and the caller tries another route. Over a hidden (TLS) address
  /// the fallback stays, since v1 is then inside TLS.
  Future<_RelayCallResult?> _trySession({
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
    required Duration timeout,
    required Map<String, dynamic> request,
    required String expectedIdentityPublicKeyBase64,
    required int maxResponseBytes,
  }) async {
    final hostPort = '$host:$port';
    final known = _v2Known[hostPort];
    final stale =
        known == null ||
        known.identityPublicKeyBase64 != expectedIdentityPublicKeyBase64 ||
        (!known.sessions &&
            DateTime.now().difference(known.learnedAt) > _v2RecheckAfter);
    if (stale) {
      // Learned in the background from a health answer; this request goes
      // over v1.
      if (request['action'] != 'health' && _v2Learning.add(hostPort)) {
        unawaited(
          inspectHealth(
                host: host,
                port: port,
                protocol: protocol,
                timeout: timeout,
                expectedIdentityPublicKeyBase64:
                    expectedIdentityPublicKeyBase64,
              )
              .then<void>(
                (_) {},
                onError: (Object _) {
                  // A relay that cannot answer now is asked again later.
                  _v2Known[hostPort] = RelayV2Info(
                    identityPublicKeyBase64: expectedIdentityPublicKeyBase64,
                    noiseKey: null,
                    learnedAt: DateTime.now().subtract(
                      _v2RecheckAfter - const Duration(minutes: 1),
                    ),
                  );
                },
              )
              .whenComplete(() => _v2Learning.remove(hostPort)),
        );
      }
      return null;
    }
    if (!known.sessions) return null;
    final mustStayPrivate =
        _ownedActions.contains(request['action']) &&
        !isHiddenRouteProtocol(protocol);
    _RelayCallResult? fallback(String why) {
      if (mustStayPrivate) {
        throw StateError(
          'Relay session unavailable ($why); not falling back to cleartext.',
        );
      }
      return null;
    }

    if (v2Pool.inBackoff(_sessionKey(host, port, known))) {
      return fallback('backing off');
    }
    final RelayV2Session session;
    try {
      session = await _sessionFor(host, port, known, timeout);
    } on Object {
      return fallback('connect failed');
    }
    final owned = request['recipient_device_id'];
    if (known.mailboxAuth &&
        _ownedActions.contains(request['action']) &&
        owned is String) {
      try {
        await _proveMailbox(
          session,
          owned,
          expectedIdentityPublicKeyBase64,
          timeout,
        );
      } on RelayV2Unavailable {
        return fallback('proof refused');
      } on SocketException {
        return fallback('proof failed');
      } on TimeoutException {
        return fallback('proof timed out');
      } on StateError {
        return fallback('proof failed');
      }
    }
    final token = _tokens[expectedIdentityPublicKeyBase64];
    // The token goes with stores (tier 1) and with health (so the relay can
    // tell a registered user from a passer-by before it says its hidden
    // addresses).
    final outgoing =
        (request['action'] == 'store' || request['action'] == 'health') &&
            token != null
        ? {...request, 'token': token}
        : request;
    final Map<String, dynamic> body;
    try {
      body = await session.request(
        outgoing,
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      );
    } on RelayV2Unavailable {
      return fallback('unavailable');
    } on SocketException {
      // The session broke under this request: a store is deduplicated by
      // its message id, so it may go once more over v1; an owned action
      // may not (see above).
      return fallback('broke');
    } on TimeoutException {
      return fallback('timed out');
    }
    if (body['ok'] == false) {
      throw StateError(body['error'] as String? ?? 'Relay request failed.');
    }
    if (request['action'] == 'health' &&
        body['stats'] is Map<String, dynamic>) {
      await _recordSessionInfo(
        host: host,
        port: port,
        stats: body['stats'] as Map<String, dynamic>,
        identityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      );
    }
    // The session is authenticated by a key the pinned identity signed:
    // as good as a verified signature.
    return _RelayCallResult(
      body: body,
      announcedIdentityPublicKeyBase64: expectedIdentityPublicKeyBase64,
      signatureVerified: true,
    );
  }

  /// Keeps what [stats] (from a health answer vouched for by
  /// [identityPublicKeyBase64]) says about sessions, once the identity's
  /// signature over the session key checks out.
  Future<void> _recordSessionInfo({
    required String host,
    required int port,
    required Map<String, dynamic> stats,
    required String identityPublicKeyBase64,
  }) async {
    final key = '$host:$port';
    List<int>? noiseKey;
    final v2 = stats['v2'];
    await _recordTlsCert(v2, identityPublicKeyBase64);
    if (v2 is Map<String, dynamic> &&
        v2['sessions'] == 1 &&
        v2['noise'] == relayV2NoiseProtocol &&
        v2['noise_key'] is String &&
        v2['noise_key_sig'] is String) {
      try {
        final candidate = base64Decode(v2['noise_key'] as String);
        final signature = base64Decode(v2['noise_key_sig'] as String);
        final identity = base64Decode(identityPublicKeyBase64);
        if (candidate.length == 32 &&
            await verifyEd25519Signature(
              publicKey: identity,
              message: [...relayV2BindingLabel, ...candidate],
              signature: signature,
            )) {
          noiseKey = candidate;
        }
      } on FormatException {
        noiseKey = null;
      }
    }
    if (_v2Known.length >= 256 && !_v2Known.containsKey(key)) {
      _v2Known.remove(_v2Known.keys.first);
    }
    _v2Known[key] = RelayV2Info(
      identityPublicKeyBase64: identityPublicKeyBase64,
      noiseKey: noiseKey,
      learnedAt: DateTime.now(),
      mailboxAuth: v2 is Map<String, dynamic> && v2['mailbox_auth'] == 1,
      udpSealed:
          noiseKey != null &&
          v2 is Map<String, dynamic> &&
          v2['udp_sealed'] == 1,
      tier1: _policyWord(v2, 'tier1', const {'open', 'registered', 'off'}),
      hiddenAddress: _hiddenAddressIn(v2),
      borrowed: _borrowedIn(v2),
      registration: _policyWord(v2, 'registration', const {
        'open',
        'invite',
        'password',
        'closed',
      }),
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
    return verifyEd25519Signature(
      publicKey: pub,
      message: signingInput,
      signature: sig,
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
    if (request['action'] != 'fetch' && request['action'] != 'fetch_leased') {
      return _controlResponseLimit;
    }
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
    final socket = await Circumvention.instance
        .connect(host, port, timeout: timeout)
        .timeout(timeout);
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

  /// Cookies UDP relays gave (by host:port): over UDP a relay answers at
  /// length only a request carrying the cookie it sent to that address,
  /// so a forged source cannot aim its answers at someone.
  static final Map<String, String> _udpCookies = <String, String>{};

  /// The session key to seal UDP datagrams to [host]:[port] under (M38-C):
  /// known only for a relay whose pinned identity signed it and that said
  /// it opens sealed datagrams. Null: send the cleartext form.
  List<int>? _udpSealKey(String host, int port, String? pinnedIdentity) {
    if (pinnedIdentity == null || pinnedIdentity.isEmpty) return null;
    final known = _v2Known['$host:$port'];
    if (known == null ||
        known.identityPublicKeyBase64 != pinnedIdentity ||
        !known.udpSealed) {
      return null;
    }
    return known.noiseKey;
  }

  Future<Map<String, dynamic>> _sendUdpRequest({
    required String host,
    required int port,
    required Duration timeout,
    required Map<String, dynamic> request,
    required int maxResponseBytes,
    List<int>? sealTo,
  }) async {
    final key = '$host:$port';
    Future<Map<String, dynamic>> send(String? cookie) => _sendUdpOnce(
      host: host,
      port: port,
      timeout: timeout,
      request: {
        ...request,
        'cookie': ?cookie,
        // Without a cookie the relay answers (with one) only a request at
        // least as long as its answer (sealed ones are padded inside).
        if (cookie == null && sealTo == null) 'pad': ''.padRight(128, 'x'),
      },
      maxResponseBytes: maxResponseBytes,
      sealTo: sealTo,
      cookieRequest: cookie == null,
    );
    try {
      return await send(_udpCookies[key]);
    } on _UdpCookieRequired catch (asked) {
      if (_udpCookies.length >= 64) _udpCookies.remove(_udpCookies.keys.first);
      _udpCookies[key] = asked.cookie;
      return send(asked.cookie);
    }
  }

  Future<Map<String, dynamic>> _sendUdpOnce({
    required String host,
    required int port,
    required Duration timeout,
    required Map<String, dynamic> request,
    required int maxResponseBytes,
    List<int>? sealTo,
    bool cookieRequest = false,
  }) async {
    var requestBytes = utf8.encode(jsonEncode(request));
    if (requestBytes.length > 60 * 1024) {
      throw StateError('UDP relay request is too large for a single datagram.');
    }
    UdpSeal? sealedReply;
    if (sealTo != null) {
      final (datagram, reply) = await UdpSeal.seal(
        relayPublic: sealTo,
        request: requestBytes,
        padding: UdpSeal.paddingFor(
          requestBytes.length,
          cookieRequest: cookieRequest,
        ),
      );
      requestBytes = datagram;
      sealedReply = reply;
    }
    final addresses = await Circumvention.instance
        .resolve(host)
        .timeout(timeout);
    if (addresses.isEmpty) {
      throw StateError('No address found for UDP relay host $host.');
    }
    // Prefer IPv4 (still the LAN/relay common case today) but fall back to IPv6
    // so dual-stack hosts and IPv6-only LANs (e.g. some mobile hotspots) keep
    // working.
    // 0.0.0.0 and :: are what DNS filters answer for names they block:
    // nothing to send to (Android refuses, "Operation not permitted").
    bool sendable(InternetAddress a) => a.rawAddress.any((byte) => byte != 0);
    final orderedAddresses = <InternetAddress>[
      ...addresses.where(
        (a) => a.type == InternetAddressType.IPv4 && sendable(a),
      ),
      ...addresses.where(
        (a) => a.type == InternetAddressType.IPv6 && sendable(a),
      ),
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
          try {
            socket.send(requestBytes, address, port);
          } catch (error) {
            // Unreachable from here (no route, a refused address): the next
            // address, not an error escaping the request.
            responseFuture.ignore();
            lastError = error;
            break;
          }
          try {
            final datagram = await responseFuture;
            if (datagram.data.length > maxResponseBytes) {
              throw StateError('Relay response exceeded the allowed size.');
            }
            var answer = datagram.data;
            if (sealedReply != null) {
              // Only an answer sealed for this very exchange counts.
              final opened = await sealedReply.open(answer);
              if (opened == null) {
                throw StateError('UDP relay answer did not open.');
              }
              answer = Uint8List.fromList(opened);
            }
            final text = utf8.decode(answer);
            if (_udpCookieAsked(text) case final cookie?) {
              throw _UdpCookieRequired(cookie);
            }
            return _decodeResponse(text);
          } on _UdpCookieRequired {
            rethrow;
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
        ? await Circumvention.instance
              .secureConnect(host, port, timeout: timeout)
              .timeout(timeout)
        : await Circumvention.instance
              .connect(host, port, timeout: timeout)
              .timeout(timeout);
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
          '${_tunnelHeaders(host)}'
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

  /// The headers some public HTTP tunnels need to skip their warning page,
  /// sent only to a tunnel (they are a telltale on any other relay; M38-C).
  @visibleForTesting
  static String tunnelHeadersFor(String host) {
    final lower = host.toLowerCase();
    const tunnels = <String>[
      '.ngrok.io',
      '.ngrok-free.app',
      '.ngrok.app',
      '.ngrok.dev',
      '.loca.lt',
      '.localtunnel.me',
    ];
    if (!tunnels.any(lower.endsWith)) return '';
    return 'bypass-tunnel-reminder: true\r\n'
        'ngrok-skip-browser-warning: true\r\n';
  }

  String _tunnelHeaders(String host) => tunnelHeadersFor(host);

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

  /// The cookie a UDP relay asks to be sent back, if [text] is that.
  static String? _udpCookieAsked(String text) {
    if (!text.contains('udp cookie required')) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['error'] == 'udp cookie required') {
        final cookie = decoded['cookie'];
        if (cookie is String && cookie.isNotEmpty && cookie.length <= 64) {
          return cookie;
        }
      }
    } on FormatException {
      return null;
    }
    return null;
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

/// A UDP relay asks for its cookie before answering at length.
class _UdpCookieRequired implements Exception {
  const _UdpCookieRequired(this.cookie);

  final String cookie;
}
