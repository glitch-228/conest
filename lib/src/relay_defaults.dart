import 'dart:convert';

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
  final List<PeerEndpoint> endpoints;
}

/// Parses + verifies a signed default-relay manifest. Returns null on any
/// failure (missing public key, tampered manifest, malformed JSON). Never
/// throws — a corrupt asset bundle must not be able to brick startup.
///
/// [manifestJson] is the raw UTF-8 contents of `assets/default_relays.json`;
/// [signatureBase64] is the contents of `assets/default_relays.ed25519.sig`;
/// [publicKeyBase64] is the build's pinned Ed25519 public key, typically
/// supplied via `--dart-define=CONEST_DEFAULT_RELAYS_PUBLIC_KEY=...`.
Future<SignedRelayDefaults?> loadSignedDefaultRelays({
  required String manifestJson,
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

  final manifestBytes = utf8.encode(manifestJson);
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

  final endpoints = <PeerEndpoint>[];
  for (final raw in endpointsRaw) {
    if (raw is! Map<String, dynamic>) {
      continue;
    }
    try {
      endpoints.add(PeerEndpoint.fromJson(raw));
    } on ArgumentError {
      // Skip malformed entries; do not poison the whole list.
      continue;
    }
  }

  return SignedRelayDefaults(
    version: version,
    issuedAt: issuedAt,
    endpoints: endpoints,
  );
}
