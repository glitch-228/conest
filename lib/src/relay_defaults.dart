import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'models.dart';

/// A signed bundle of default relay endpoints. The Ed25519 signature must
/// verify against the build's pinned public key before any endpoint is
/// returned. Versioned so the client can skip re-ingestion across launches.
class SignedRelayDefaults {
  const SignedRelayDefaults({
    required this.version,
    required this.issuedAt,
    required this.endpoints,
  });

  final int version;
  final DateTime issuedAt;
  final List<DefaultRelayEndpointSpec> endpoints;
}

/// Endpoint as it appears in a signed manifest. Schema v3 made the
/// `protocol` field optional — when absent, the ingest layer auto-detects
/// TCP/UDP/HTTP/HTTPS and records every transport that answers under one
/// `default relay N` label.
class DefaultRelayEndpointSpec {
  const DefaultRelayEndpointSpec({
    required this.kind,
    required this.host,
    required this.port,
    this.protocol,
  });

  final PeerRouteKind kind;
  final String host;
  final int port;

  /// `null` means the manifest entry was protocol-less and the ingest layer
  /// should fan out via auto-detection. A concrete value pins this entry to
  /// a single transport (schema v1/v2 compatibility).
  final PeerRouteProtocol? protocol;
}

/// Parses + verifies a signed default-relay manifest from raw bytes. Returns
/// null on any failure (missing public key, tampered manifest, malformed
/// JSON). Never throws — a corrupt asset bundle must not be able to brick
/// startup.
Future<SignedRelayDefaults?> loadSignedDefaultRelaysFromBytes({
  required Uint8List manifestBytes,
  required String signatureBase64,
  required String publicKeyBase64,
}) async {
  if (publicKeyBase64.trim().isEmpty) {
    return null;
  }
  final List<int> publicKey;
  final List<int> signature;
  try {
    publicKey = base64Decode(publicKeyBase64.trim());
    signature = base64Decode(signatureBase64.trim());
  } on FormatException {
    return null;
  }
  if (publicKey.length != 32 || signature.length != 64) {
    return null;
  }

  final algorithm = Ed25519();
  final verified = await algorithm.verify(
    manifestBytes,
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    ),
  );
  if (!verified) {
    return null;
  }

  final String manifestJson;
  try {
    manifestJson = utf8.decode(manifestBytes);
  } on FormatException {
    return null;
  }
  return _decodeManifestJson(manifestJson);
}

/// Convenience wrapper for callers that already have the manifest as a
/// String (e.g. the asset-bundle loader). Encodes once with UTF-8 and
/// delegates.
Future<SignedRelayDefaults?> loadSignedDefaultRelays({
  required String manifestJson,
  required String signatureBase64,
  required String publicKeyBase64,
}) {
  return loadSignedDefaultRelaysFromBytes(
    manifestBytes: Uint8List.fromList(utf8.encode(manifestJson)),
    signatureBase64: signatureBase64,
    publicKeyBase64: publicKeyBase64,
  );
}

/// Parses an unsigned relay list (same JSON schema as the signed manifest)
/// for the "custom URL import" flow when the user opts out of cryptographic
/// trust. Returns null on malformed JSON.
SignedRelayDefaults? parseUnsignedRelayList(String json) {
  return _decodeManifestJson(json);
}

SignedRelayDefaults? _decodeManifestJson(String manifestJson) {
  final Map<String, dynamic> manifest;
  try {
    final decoded = jsonDecode(manifestJson);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    manifest = decoded;
  } on FormatException {
    return null;
  }

  final version = (manifest['version'] as num?)?.toInt();
  final issuedAtRaw = manifest['issuedAt'] as String?;
  final endpointsRaw = manifest['endpoints'] as List<dynamic>?;
  if (version == null || issuedAtRaw == null || endpointsRaw == null) {
    return null;
  }
  final issuedAt = DateTime.tryParse(issuedAtRaw);
  if (issuedAt == null) {
    return null;
  }

  final endpoints = <DefaultRelayEndpointSpec>[];
  for (final raw in endpointsRaw) {
    if (raw is! Map<String, dynamic>) {
      continue;
    }
    final kindName = raw['kind'] as String?;
    final host = raw['host'] as String?;
    final port = (raw['port'] as num?)?.toInt();
    if (kindName == null || host == null || port == null) {
      continue;
    }
    final PeerRouteKind kind;
    try {
      kind = PeerRouteKind.values.byName(kindName);
    } on ArgumentError {
      continue;
    }
    if (host.trim().isEmpty || !isValidPeerEndpointHost(host)) {
      continue;
    }
    if (!isValidPeerEndpointPort(port)) {
      continue;
    }
    final protocolRaw = raw['protocol'] as String?;
    PeerRouteProtocol? protocol;
    if (protocolRaw != null && protocolRaw.trim().isNotEmpty) {
      protocol = peerRouteProtocolFromString(protocolRaw);
    }
    endpoints.add(
      DefaultRelayEndpointSpec(
        kind: kind,
        host: host,
        port: port,
        protocol: protocol,
      ),
    );
  }

  return SignedRelayDefaults(
    version: version,
    issuedAt: issuedAt,
    endpoints: endpoints,
  );
}
