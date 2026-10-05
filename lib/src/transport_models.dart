/// Stable, persisted transport identifiers. New values may be appended, but
/// existing names must not be renamed because they are stored in the vault.
enum TransportKind {
  lan,
  iroh,
  conestRelay,
  optical,

  /// The email carrier (chatmail or any IMAP/SMTP account); named for the
  /// Delta Chat-style design it follows.
  deltaChat,
  reticulum,
  localSend,
  matrix,
  nostr,
  meshtastic,
  meshCore,
  bitchat,
  tor,
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
    TransportKind.deltaChat => 'Email',
    TransportKind.reticulum => 'Reticulum',
    TransportKind.localSend => 'LocalSend',
    TransportKind.matrix => 'Matrix',
    TransportKind.nostr => 'Nostr',
    TransportKind.meshtastic => 'Meshtastic',
    TransportKind.meshCore => 'MeshCore',
    TransportKind.bitchat => 'Bluetooth mesh',
    TransportKind.tor => 'Tor',
  };
}

extension TransportKindTraits on TransportKind {
  /// Needs the internet, so the global and per-contact Online switches
  /// turn it off. Radio and Bluetooth meshes work without it.
  bool get isOnline => switch (this) {
    TransportKind.iroh ||
    TransportKind.conestRelay ||
    TransportKind.deltaChat ||
    TransportKind.matrix ||
    TransportKind.nostr ||
    TransportKind.tor => true,
    _ => false,
  };

  /// Carries sealed envelopes through another network's accounts or nodes,
  /// with this device's address on it sent in the contact exchange.
  bool get isCarrier => switch (this) {
    TransportKind.deltaChat ||
    TransportKind.reticulum ||
    TransportKind.matrix ||
    TransportKind.nostr ||
    TransportKind.meshtastic ||
    TransportKind.meshCore ||
    TransportKind.bitchat ||
    TransportKind.tor => true,
    _ => false,
  };

  /// May carry file chunks and other high-volume traffic.
  bool get carriesBulk => switch (this) {
    TransportKind.lan ||
    TransportKind.iroh ||
    TransportKind.conestRelay ||
    TransportKind.optical ||
    TransportKind.localSend ||
    TransportKind.tor => true,
    _ => false,
  };

  /// Shown in transport policy settings. A kind appears once Conest can
  /// actually use it.
  bool get userVisible => switch (this) {
    TransportKind.lan ||
    TransportKind.iroh ||
    TransportKind.conestRelay ||
    TransportKind.optical ||
    TransportKind.matrix ||
    TransportKind.nostr ||
    TransportKind.deltaChat ||
    TransportKind.reticulum ||
    TransportKind.meshtastic ||
    TransportKind.meshCore ||
    TransportKind.bitchat ||
    TransportKind.tor => true,
    _ => false,
  };

  /// Order among routes with the same policy and path kind: lower first.
  int get routeRank => switch (this) {
    TransportKind.lan => 0,
    TransportKind.localSend => 5,
    TransportKind.iroh => 10,
    TransportKind.conestRelay => 15,
    TransportKind.tor => 20,
    TransportKind.matrix => 30,
    TransportKind.nostr => 31,
    TransportKind.deltaChat => 32,
    TransportKind.bitchat => 40,
    TransportKind.reticulum ||
    TransportKind.meshtastic ||
    TransportKind.meshCore => 50,
    TransportKind.optical => 60,
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

/// Version of saved transport policies. Before version 2, Email
/// ([TransportKind.deltaChat]) and Reticulum were placeholders saved as
/// disabled; their saved values are replaced by the current defaults.
const int currentTransportPolicyVersion = 2;

Map<TransportKind, TransportPolicy> transportPoliciesFromJson(
  Object? value, {
  required Map<TransportKind, TransportPolicy> defaults,
  int version = currentTransportPolicyVersion,
}) {
  final result = Map<TransportKind, TransportPolicy>.from(defaults);
  if (value is! Map<String, dynamic>) return result;
  for (final entry in value.entries) {
    final kind = TransportKind.values
        .where((candidate) => candidate.name == entry.key)
        .firstOrNull;
    if (version < 2 &&
        (kind == TransportKind.deltaChat || kind == TransportKind.reticulum)) {
      continue;
    }
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

/// The policies a new identity or contact starts with. Carriers default to
/// automatic: each one is used only once it is set up and the contact has
/// sent an address for it.
Map<TransportKind, TransportPolicy> defaultTransportPolicies({
  bool lanEnabled = true,
  bool onlineEnabled = true,
}) => {
  for (final kind in TransportKind.values)
    kind: switch (kind) {
      TransportKind.optical => TransportPolicy.askBeforeUse,
      TransportKind.localSend => TransportPolicy.disabled,
      TransportKind.lan when !lanEnabled => TransportPolicy.disabled,
      _ when kind.isOnline && !onlineEnabled => TransportPolicy.disabled,
      _ => TransportPolicy.automatic,
    },
};
