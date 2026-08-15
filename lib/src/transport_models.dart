/// Stable, persisted transport identifiers. New values may be appended, but
/// existing names must not be renamed because they are stored in the vault.
enum TransportKind {
  lan,
  iroh,
  conestRelay,
  optical,
  deltaChat,
  reticulum,
  localSend,
}

enum TransportPolicy { automatic, preferred, disabled, askBeforeUse }

enum TransportPathKind { local, direct, relayed, storeForward, manual }

enum TransportTrustState {
  verifiedContact,
  pinnedTransport,
  externalUnlinked,
  publicUntrusted,
}

enum DeliveryReceiptState {
  acceptedByTransport,
  storedForPeer,
  deliveredToPeer,
  failed,
}

extension TransportKindLabel on TransportKind {
  String get label => switch (this) {
    TransportKind.lan => 'LAN',
    TransportKind.iroh => 'Iroh',
    TransportKind.conestRelay => 'Conest relay',
    TransportKind.optical => 'Optical',
    TransportKind.deltaChat => 'Delta Chat',
    TransportKind.reticulum => 'Reticulum',
    TransportKind.localSend => 'LocalSend',
  };
}

TransportPolicy transportPolicyFromJson(
  Object? value, {
  TransportPolicy fallback = TransportPolicy.automatic,
}) {
  if (value is! String) return fallback;
  return TransportPolicy.values
          .where((entry) => entry.name == value)
          .firstOrNull ??
      fallback;
}

Map<TransportKind, TransportPolicy> transportPoliciesFromJson(
  Object? value, {
  required Map<TransportKind, TransportPolicy> defaults,
}) {
  final result = Map<TransportKind, TransportPolicy>.from(defaults);
  if (value is! Map<String, dynamic>) return result;
  for (final entry in value.entries) {
    final kind = TransportKind.values
        .where((candidate) => candidate.name == entry.key)
        .firstOrNull;
    if (kind != null) {
      result[kind] = transportPolicyFromJson(
        entry.value,
        fallback: result[kind] ?? TransportPolicy.automatic,
      );
    }
  }
  return result;
}

Map<String, String> transportPoliciesToJson(
  Map<TransportKind, TransportPolicy> policies,
) => {for (final entry in policies.entries) entry.key.name: entry.value.name};
