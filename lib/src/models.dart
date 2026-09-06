import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'transport_models.dart';

export 'transport_models.dart';

enum ConversationKind { direct, group, lanLobby }

enum GroupMemberRole {
  owner('Owner'),
  admin('Admin'),
  moderator('Moderator'),
  member('Member');

  const GroupMemberRole(this.label);

  final String label;
}

enum DeliveryState {
  pending(Icons.schedule, 'Waiting for a reachable path'),
  local(Icons.lan_outlined, 'Sent over LAN; waiting for delivery receipt'),
  relayed(
    Icons.cloud_upload_outlined,
    'Queued on a relay; waiting for delivery receipt',
  ),
  delivered(Icons.done, 'Delivered'),
  read(Icons.done_all, 'Read'),
  canceled(Icons.cancel_outlined, 'Canceled'),
  failed(Icons.error_outline, 'Failed');

  const DeliveryState(this.icon, this.label);

  final IconData icon;
  final String label;

  bool get awaitsRecipientAck => switch (this) {
    DeliveryState.pending ||
    DeliveryState.local ||
    DeliveryState.relayed => true,
    DeliveryState.read ||
    DeliveryState.delivered ||
    DeliveryState.canceled ||
    DeliveryState.failed => false,
  };
}

enum ContactReachabilityState {
  online('online', Icons.radio_button_checked),
  seenRecently('seen recently', Icons.schedule_outlined),
  known('known', Icons.history_toggle_off),
  unknown('unknown', Icons.help_outline);

  const ContactReachabilityState(this.label, this.icon);

  final String label;
  final IconData icon;
}

enum PeerRouteKind { lan, directInternet, relay }

enum PeerRouteProtocol { tcp, udp, http, https }

class PeerEndpoint {
  const PeerEndpoint({
    required this.kind,
    required this.host,
    required this.port,
    this.protocol = PeerRouteProtocol.tcp,
  });

  factory PeerEndpoint.normalized({
    required PeerRouteKind kind,
    required String host,
    required int port,
    PeerRouteProtocol protocol = PeerRouteProtocol.tcp,
  }) {
    final parsed = parsePeerEndpointInput(
      host: host,
      fallbackPort: port,
      defaultProtocol: protocol,
    );
    validatePeerEndpointHostAndPort(parsed.host, parsed.port);
    return PeerEndpoint(
      kind: kind,
      host: parsed.host,
      port: parsed.port,
      protocol: parsed.protocol,
    );
  }

  final PeerRouteKind kind;
  final String host;
  final int port;
  final PeerRouteProtocol protocol;

  String get routeKey => '${kind.name}:${protocol.name}:$host:$port';
  String get label => '${protocol.name}://$host:$port';

  Map<String, dynamic> toJson() {
    return {
      'kind': kind.name,
      'host': host,
      'port': port,
      'protocol': protocol.name,
    };
  }

  factory PeerEndpoint.fromJson(Map<String, dynamic> json) {
    return PeerEndpoint.normalized(
      kind: PeerRouteKind.values.byName(json['kind'] as String),
      host: json['host'] as String,
      port: json['port'] as int,
      protocol: peerRouteProtocolFromString(json['protocol'] as String?),
    );
  }
}

void validatePeerEndpointHostAndPort(String host, int port) {
  if (!isValidPeerEndpointPort(port)) {
    throw ArgumentError('Relay port must be between 1 and 65535.');
  }
  if (!isValidPeerEndpointHost(host)) {
    throw ArgumentError('Relay host contains unsupported characters.');
  }
}

bool isValidPeerEndpointPort(int port) => port >= 1 && port <= 65535;

bool isValidPeerEndpointHost(String host) {
  if (host.isEmpty || host.trim() != host) {
    return false;
  }
  for (final codeUnit in host.codeUnits) {
    if (codeUnit <= 32 || codeUnit == 127) {
      return false;
    }
    if (codeUnit == 47 || codeUnit == 92 || codeUnit == 35 || codeUnit == 63) {
      return false;
    }
  }
  return true;
}

class ParsedPeerEndpointInput {
  const ParsedPeerEndpointInput({
    required this.host,
    required this.port,
    required this.protocol,
    required this.hasExplicitProtocol,
    required this.hasExplicitPort,
  });

  final String host;
  final int port;
  final PeerRouteProtocol protocol;
  final bool hasExplicitProtocol;
  final bool hasExplicitPort;
}

PeerRouteProtocol peerRouteProtocolFromString(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'udp' || 'conest+udp' => PeerRouteProtocol.udp,
    'http' || 'conest+http' => PeerRouteProtocol.http,
    'https' || 'conest+https' => PeerRouteProtocol.https,
    _ => PeerRouteProtocol.tcp,
  };
}

ParsedPeerEndpointInput parsePeerEndpointInput({
  required String host,
  required int fallbackPort,
  PeerRouteProtocol defaultProtocol = PeerRouteProtocol.tcp,
}) {
  var value = host.trim();
  var parsedHost = value;
  var parsedPort = fallbackPort;
  var parsedProtocol = defaultProtocol;
  var hasExplicitProtocol = false;
  var hasExplicitPort = false;

  final schemeIndex = value.indexOf('://');
  if (schemeIndex > 0) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.host.isNotEmpty) {
      hasExplicitProtocol = _isExplicitRouteProtocolScheme(uri.scheme);
      parsedProtocol = hasExplicitProtocol
          ? peerRouteProtocolFromString(uri.scheme)
          : defaultProtocol;
      parsedHost = uri.host;
      if (uri.hasPort) {
        parsedPort = uri.port;
        hasExplicitPort = true;
      } else if (hasExplicitProtocol) {
        parsedPort = _defaultPortForProtocol(parsedProtocol) ?? fallbackPort;
      }
    } else {
      value = value.substring(schemeIndex + 3);
      parsedHost = value;
    }
  } else {
    final colonCount = ':'.allMatches(value).length;
    final lastColon = value.lastIndexOf(':');
    if (colonCount == 1 && lastColon > 0 && lastColon < value.length - 1) {
      final maybePort = int.tryParse(value.substring(lastColon + 1));
      if (maybePort != null) {
        parsedHost = value.substring(0, lastColon);
        parsedPort = maybePort;
        hasExplicitPort = true;
      }
    }
  }

  parsedHost = parsedHost.trim();
  while (parsedHost.endsWith('/')) {
    parsedHost = parsedHost.substring(0, parsedHost.length - 1);
  }
  if (parsedHost.startsWith('[') && parsedHost.endsWith(']')) {
    parsedHost = parsedHost.substring(1, parsedHost.length - 1);
  }
  return ParsedPeerEndpointInput(
    host: parsedHost,
    port: parsedPort,
    protocol: parsedProtocol,
    hasExplicitProtocol: hasExplicitProtocol,
    hasExplicitPort: hasExplicitPort,
  );
}

bool _isExplicitRouteProtocolScheme(String scheme) {
  return switch (scheme.trim().toLowerCase()) {
    'tcp' ||
    'udp' ||
    'http' ||
    'https' ||
    'conest+tcp' ||
    'conest+udp' ||
    'conest+http' ||
    'conest+https' => true,
    _ => false,
  };
}

int? _defaultPortForProtocol(PeerRouteProtocol protocol) {
  return switch (protocol) {
    PeerRouteProtocol.http => 80,
    PeerRouteProtocol.https => 443,
    PeerRouteProtocol.tcp || PeerRouteProtocol.udp => null,
  };
}

class PeerRouteHealth {
  const PeerRouteHealth({
    required this.route,
    required this.available,
    required this.latency,
    required this.checkedAt,
    this.relayInstanceId,
    this.error,
  });

  final PeerEndpoint route;
  final bool available;
  final Duration? latency;
  final DateTime checkedAt;
  final String? relayInstanceId;
  final String? error;

  String get summary {
    if (!available) {
      return '${route.label} unavailable';
    }
    final latencyValue = latency;
    if (latencyValue == null) {
      return '${route.label} available';
    }
    return '${route.label} ${latencyValue.inMilliseconds}ms';
  }
}

/// Per-endpoint relay health summary, persisted into the vault. Tracks a
/// sliding window of the most recent attempts (capped at [windowSize]) plus
/// a rolling median of recent observed latencies, so route ranking can
/// down-rank relays that fail consistently or have high tail latency.
class RelayHealthScore {
  RelayHealthScore({
    required this.endpointKey,
    List<RelayAttemptSample> recentSamples = const <RelayAttemptSample>[],
    this.lastSuccessAt,
    this.lastFailureAt,
  }) : recentSamples = List<RelayAttemptSample>.unmodifiable(recentSamples);

  /// Sliding window cap. Keep small so the score reacts to recent reality.
  static const int windowSize = 50;

  /// Number of samples used for the rolling median latency.
  static const int latencyWindowSize = 11;

  final String endpointKey;
  final List<RelayAttemptSample> recentSamples;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;

  int get recentAttempts => recentSamples.length;
  int get recentSuccesses =>
      recentSamples.where((sample) => sample.succeeded).length;

  double get successRate =>
      recentAttempts == 0 ? 0.0 : recentSuccesses / recentAttempts;

  Duration? get recentMedianLatency {
    final latencies =
        recentSamples.reversed
            .take(latencyWindowSize)
            .map((sample) => sample.latency)
            .whereType<Duration>()
            .map((d) => d.inMicroseconds)
            .toList()
          ..sort();
    if (latencies.isEmpty) {
      return null;
    }
    final mid = latencies.length ~/ 2;
    if (latencies.length.isOdd) {
      return Duration(microseconds: latencies[mid]);
    }
    return Duration(microseconds: (latencies[mid - 1] + latencies[mid]) ~/ 2);
  }

  RelayHealthScore recordAttempt({
    required bool success,
    Duration? latency,
    required DateTime at,
  }) {
    final next = <RelayAttemptSample>[
      ...recentSamples,
      RelayAttemptSample(at: at, succeeded: success, latency: latency),
    ];
    while (next.length > windowSize) {
      next.removeAt(0);
    }
    return RelayHealthScore(
      endpointKey: endpointKey,
      recentSamples: next,
      lastSuccessAt: success ? at : lastSuccessAt,
      lastFailureAt: success ? lastFailureAt : at,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'endpointKey': endpointKey,
      'recentSamples': recentSamples.map((sample) => sample.toJson()).toList(),
      'lastSuccessAt': lastSuccessAt?.toIso8601String(),
      'lastFailureAt': lastFailureAt?.toIso8601String(),
    };
  }

  factory RelayHealthScore.fromJson(Map<String, dynamic> json) {
    final samples = (json['recentSamples'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RelayAttemptSample.fromJson)
        .toList();
    return RelayHealthScore(
      endpointKey: json['endpointKey'] as String? ?? '',
      recentSamples: samples,
      lastSuccessAt: DateTime.tryParse(json['lastSuccessAt'] as String? ?? ''),
      lastFailureAt: DateTime.tryParse(json['lastFailureAt'] as String? ?? ''),
    );
  }
}

class RelayAttemptSample {
  const RelayAttemptSample({
    required this.at,
    required this.succeeded,
    this.latency,
  });

  final DateTime at;
  final bool succeeded;
  final Duration? latency;

  Map<String, dynamic> toJson() {
    return {
      'at': at.toIso8601String(),
      'succeeded': succeeded,
      if (latency != null) 'latencyMicros': latency!.inMicroseconds,
    };
  }

  factory RelayAttemptSample.fromJson(Map<String, dynamic> json) {
    final micros = json['latencyMicros'];
    return RelayAttemptSample(
      at:
          DateTime.tryParse(json['at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      succeeded: json['succeeded'] as bool? ?? false,
      latency: micros is int ? Duration(microseconds: micros) : null,
    );
  }
}

/// Derives the stable key used to store a [RelayHealthScore] for a given
/// endpoint. Host + port + protocol uniquely identifies a relay route.
String relayHealthEndpointKey(PeerEndpoint endpoint) =>
    '${endpoint.host}:${endpoint.port}:${endpoint.protocol.name}';

List<PeerEndpoint> dedupePeerEndpoints(Iterable<PeerEndpoint> routes) {
  final seen = <String>{};
  final deduped = <PeerEndpoint>[];
  for (final route in routes) {
    if (seen.add(route.routeKey)) {
      deduped.add(route);
    }
  }
  return deduped;
}

List<PeerEndpoint> prunePeerEndpointsByKind(
  Iterable<PeerEndpoint> routes, {
  int maxLan = 6,
  int maxDirectInternet = 4,
  int maxRelay = 4,
}) {
  final deduped = dedupePeerEndpoints(routes);
  final pruned = <PeerEndpoint>[];
  var lanCount = 0;
  var directInternetCount = 0;
  var relayCount = 0;
  for (final route in deduped) {
    switch (route.kind) {
      case PeerRouteKind.lan:
        if (lanCount >= maxLan) {
          continue;
        }
        lanCount++;
      case PeerRouteKind.directInternet:
        if (directInternetCount >= maxDirectInternet) {
          continue;
        }
        directInternetCount++;
      case PeerRouteKind.relay:
        if (relayCount >= maxRelay) {
          continue;
        }
        relayCount++;
    }
    pruned.add(route);
  }
  return pruned;
}

List<PeerEndpoint> _peerEndpointsFromJsonList(
  List<dynamic> values, {
  required bool expandMissingProtocol,
}) {
  final routes = <PeerEndpoint>[];
  for (final value in values) {
    if (value is! Map<String, dynamic>) {
      debugPrint('Skipping malformed persisted route (not an object): $value');
      continue;
    }
    final PeerEndpoint route;
    try {
      route = PeerEndpoint.fromJson(value);
    } on Object catch (error) {
      // A silently-vanishing route makes "my contact lost its relay" bugs
      // undiagnosable — keep the skip (one bad route must not take down
      // the whole contact) but leave a trace.
      debugPrint(
        'Skipping malformed persisted route '
        '${value['host']}:${value['port']}: $error',
      );
      continue;
    }
    routes.add(route);
    if (expandMissingProtocol && !value.containsKey('protocol')) {
      routes.add(
        PeerEndpoint(
          kind: route.kind,
          host: route.host,
          port: route.port,
          protocol: PeerRouteProtocol.udp,
        ),
      );
    }
  }
  return dedupePeerEndpoints(routes);
}

enum RoutingPreference { lan, online }

enum EffectiveRoutingMode {
  lanFirst,
  lanOnly,
  onlineFirst,
  onlineOnly,
  offline,
}

List<String> normalizeIrohRelayUrls(
  Iterable<String> values, {
  bool rejectInvalid = true,
}) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    final uri = Uri.tryParse(value);
    final valid =
        value.isNotEmpty &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
    if (!valid) {
      if (rejectInvalid) {
        throw ArgumentError.value(
          raw,
          'irohRelayUrls',
          'Invalid HTTPS relay URL.',
        );
      }
      continue;
    }
    final canonical = uri.toString();
    if (!seen.add(canonical)) continue;
    if (result.length == 8) {
      if (rejectInvalid) {
        throw ArgumentError(
          'At most eight custom Iroh relay URLs are allowed.',
        );
      }
      break;
    }
    result.add(canonical);
  }
  return List.unmodifiable(result);
}

enum AutoDownloadPreset { low, medium, high, custom }

enum NetworkCostClass { unmetered, metered, roaming, offline }

enum DownloadMediaKind { photo, video, audio, document }

extension AutoDownloadPresetPolicy on AutoDownloadPreset {
  bool allows({
    required String mimeType,
    required int sizeBytes,
    required NetworkCostClass network,
    required bool verifiedContact,
  }) {
    if (!verifiedContact ||
        sizeBytes <= 0 ||
        network == NetworkCostClass.offline) {
      return false;
    }
    final kind = mimeType.startsWith('image/')
        ? DownloadMediaKind.photo
        : mimeType.startsWith('video/')
        ? DownloadMediaKind.video
        : mimeType.startsWith('audio/')
        ? DownloadMediaKind.audio
        : DownloadMediaKind.document;
    const mib = 1024 * 1024;
    final limitMiB = switch ((this, network, kind)) {
      (
        AutoDownloadPreset.low,
        NetworkCostClass.unmetered,
        DownloadMediaKind.photo || DownloadMediaKind.audio,
      ) =>
        2,
      (
        AutoDownloadPreset.low,
        NetworkCostClass.unmetered,
        DownloadMediaKind.document,
      ) =>
        1,
      (
        AutoDownloadPreset.medium,
        NetworkCostClass.unmetered,
        DownloadMediaKind.photo || DownloadMediaKind.audio,
      ) =>
        10,
      (
        AutoDownloadPreset.medium,
        NetworkCostClass.unmetered,
        DownloadMediaKind.video,
      ) =>
        20,
      (
        AutoDownloadPreset.medium,
        NetworkCostClass.unmetered,
        DownloadMediaKind.document,
      ) =>
        5,
      (
        AutoDownloadPreset.medium,
        NetworkCostClass.metered,
        DownloadMediaKind.photo,
      ) =>
        2,
      (
        AutoDownloadPreset.medium,
        NetworkCostClass.metered,
        DownloadMediaKind.video || DownloadMediaKind.audio,
      ) =>
        5,
      (
        AutoDownloadPreset.medium,
        NetworkCostClass.metered,
        DownloadMediaKind.document,
      ) =>
        1,
      (
        AutoDownloadPreset.high,
        NetworkCostClass.unmetered,
        DownloadMediaKind.photo ||
            DownloadMediaKind.audio ||
            DownloadMediaKind.document,
      ) =>
        50,
      (
        AutoDownloadPreset.high,
        NetworkCostClass.unmetered,
        DownloadMediaKind.video,
      ) =>
        100,
      (
        AutoDownloadPreset.high,
        NetworkCostClass.metered,
        DownloadMediaKind.photo || DownloadMediaKind.document,
      ) =>
        10,
      (
        AutoDownloadPreset.high,
        NetworkCostClass.metered,
        DownloadMediaKind.video || DownloadMediaKind.audio,
      ) =>
        20,
      (
        AutoDownloadPreset.high,
        NetworkCostClass.roaming,
        DownloadMediaKind.photo,
      ) =>
        1,
      _ => 0,
    };
    return limitMiB > 0 && sizeBytes <= limitMiB * mib;
  }
}

class GlobalConnectivityPreferences {
  const GlobalConnectivityPreferences({
    this.lanEnabled = true,
    this.onlineEnabled = true,
    this.irohRelayEnabled = true,
    this.irohRelayUrls = const [],
    this.irohCustomRelaysBulkCapable = false,
    this.autoDownloadPreset = AutoDownloadPreset.medium,
    this.storageReserveEnabled = true,
    this.transportPolicies = const {
      TransportKind.lan: TransportPolicy.automatic,
      TransportKind.iroh: TransportPolicy.automatic,
      TransportKind.conestRelay: TransportPolicy.automatic,
      TransportKind.optical: TransportPolicy.askBeforeUse,
      TransportKind.deltaChat: TransportPolicy.disabled,
      TransportKind.reticulum: TransportPolicy.disabled,
      TransportKind.localSend: TransportPolicy.disabled,
    },
  });

  final bool lanEnabled;
  final bool onlineEnabled;
  final bool irohRelayEnabled;

  /// Empty uses Iroh's standard N0 relay set. A non-empty list replaces it.
  final List<String> irohRelayUrls;

  /// The user has explicitly confirmed that every configured custom relay
  /// permits bulk attachment traffic. Public/default relays never inherit
  /// this setting implicitly.
  final bool irohCustomRelaysBulkCapable;
  final AutoDownloadPreset autoDownloadPreset;
  final bool storageReserveEnabled;
  final Map<TransportKind, TransportPolicy> transportPolicies;

  bool get anyEnabled => lanEnabled || onlineEnabled;

  TransportPolicy policyFor(TransportKind kind) {
    if (kind == TransportKind.lan && !lanEnabled) {
      return TransportPolicy.disabled;
    }
    if ((kind == TransportKind.iroh ||
            kind == TransportKind.conestRelay ||
            kind == TransportKind.deltaChat ||
            kind == TransportKind.reticulum) &&
        !onlineEnabled) {
      return TransportPolicy.disabled;
    }
    return transportPolicies[kind] ?? TransportPolicy.disabled;
  }

  GlobalConnectivityPreferences copyWith({
    bool? lanEnabled,
    bool? onlineEnabled,
    bool? irohRelayEnabled,
    List<String>? irohRelayUrls,
    bool? irohCustomRelaysBulkCapable,
    AutoDownloadPreset? autoDownloadPreset,
    bool? storageReserveEnabled,
    Map<TransportKind, TransportPolicy>? transportPolicies,
  }) {
    return GlobalConnectivityPreferences(
      lanEnabled: lanEnabled ?? this.lanEnabled,
      onlineEnabled: onlineEnabled ?? this.onlineEnabled,
      irohRelayEnabled: irohRelayEnabled ?? this.irohRelayEnabled,
      irohRelayUrls: irohRelayUrls ?? this.irohRelayUrls,
      irohCustomRelaysBulkCapable:
          irohCustomRelaysBulkCapable ?? this.irohCustomRelaysBulkCapable,
      autoDownloadPreset: autoDownloadPreset ?? this.autoDownloadPreset,
      storageReserveEnabled:
          storageReserveEnabled ?? this.storageReserveEnabled,
      transportPolicies: transportPolicies ?? this.transportPolicies,
    );
  }

  Map<String, dynamic> toJson() => {
    'lanEnabled': lanEnabled,
    'onlineEnabled': onlineEnabled,
    'irohRelayEnabled': irohRelayEnabled,
    'irohRelayUrls': irohRelayUrls,
    'irohCustomRelaysBulkCapable': irohCustomRelaysBulkCapable,
    'autoDownloadPreset': autoDownloadPreset.name,
    'storageReserveEnabled': storageReserveEnabled,
    'transportPolicies': transportPoliciesToJson(transportPolicies),
  };

  factory GlobalConnectivityPreferences.fromJson(Map<String, dynamic> json) {
    final lanEnabled = json['lanEnabled'] as bool? ?? true;
    final onlineEnabled = json['onlineEnabled'] as bool? ?? true;
    final defaults = <TransportKind, TransportPolicy>{
      TransportKind.lan: lanEnabled
          ? TransportPolicy.automatic
          : TransportPolicy.disabled,
      TransportKind.iroh: onlineEnabled
          ? TransportPolicy.automatic
          : TransportPolicy.disabled,
      TransportKind.conestRelay: onlineEnabled
          ? TransportPolicy.automatic
          : TransportPolicy.disabled,
      TransportKind.optical: TransportPolicy.askBeforeUse,
      TransportKind.deltaChat: TransportPolicy.disabled,
      TransportKind.reticulum: TransportPolicy.disabled,
      TransportKind.localSend: TransportPolicy.disabled,
    };
    return GlobalConnectivityPreferences(
      lanEnabled: lanEnabled,
      onlineEnabled: onlineEnabled,
      storageReserveEnabled: json['storageReserveEnabled'] as bool? ?? true,
      irohRelayEnabled: json['irohRelayEnabled'] as bool? ?? true,
      irohRelayUrls: normalizeIrohRelayUrls(
        (json['irohRelayUrls'] as List<dynamic>? ?? const [])
            .whereType<String>(),
        rejectInvalid: false,
      ),
      irohCustomRelaysBulkCapable:
          json['irohCustomRelaysBulkCapable'] as bool? ?? false,
      autoDownloadPreset:
          AutoDownloadPreset.values
              .where((value) => value.name == json['autoDownloadPreset'])
              .firstOrNull ??
          AutoDownloadPreset.medium,
      transportPolicies: transportPoliciesFromJson(
        json['transportPolicies'],
        defaults: defaults,
      ),
    );
  }
}

class ContactRoutingPreferences {
  const ContactRoutingPreferences({
    this.lanEnabled = true,
    this.onlineEnabled = true,
    this.preferred = RoutingPreference.lan,
    this.irohRelayEnabled = true,
    this.transportPolicies = const {
      TransportKind.lan: TransportPolicy.automatic,
      TransportKind.iroh: TransportPolicy.automatic,
      TransportKind.conestRelay: TransportPolicy.automatic,
      TransportKind.optical: TransportPolicy.askBeforeUse,
      TransportKind.deltaChat: TransportPolicy.disabled,
      TransportKind.reticulum: TransportPolicy.disabled,
      TransportKind.localSend: TransportPolicy.disabled,
    },
  });

  final bool lanEnabled;
  final bool onlineEnabled;
  final RoutingPreference preferred;
  final bool irohRelayEnabled;
  final Map<TransportKind, TransportPolicy> transportPolicies;

  TransportPolicy policyFor(TransportKind kind) {
    if (kind == TransportKind.lan && !lanEnabled) {
      return TransportPolicy.disabled;
    }
    if ((kind == TransportKind.iroh ||
            kind == TransportKind.conestRelay ||
            kind == TransportKind.deltaChat ||
            kind == TransportKind.reticulum) &&
        !onlineEnabled) {
      return TransportPolicy.disabled;
    }
    return transportPolicies[kind] ?? TransportPolicy.disabled;
  }

  TransportPolicy effectivePolicy(
    TransportKind kind,
    GlobalConnectivityPreferences global,
  ) {
    final globalPolicy = global.policyFor(kind);
    final contactPolicy = policyFor(kind);
    if (globalPolicy == TransportPolicy.disabled ||
        contactPolicy == TransportPolicy.disabled) {
      return TransportPolicy.disabled;
    }
    if (globalPolicy == TransportPolicy.askBeforeUse ||
        contactPolicy == TransportPolicy.askBeforeUse) {
      return TransportPolicy.askBeforeUse;
    }
    if (globalPolicy == TransportPolicy.preferred ||
        contactPolicy == TransportPolicy.preferred) {
      return TransportPolicy.preferred;
    }
    return TransportPolicy.automatic;
  }

  ContactRoutingPreferences copyWith({
    bool? lanEnabled,
    bool? onlineEnabled,
    RoutingPreference? preferred,
    bool? irohRelayEnabled,
    Map<TransportKind, TransportPolicy>? transportPolicies,
  }) {
    return ContactRoutingPreferences(
      lanEnabled: lanEnabled ?? this.lanEnabled,
      onlineEnabled: onlineEnabled ?? this.onlineEnabled,
      preferred: preferred ?? this.preferred,
      irohRelayEnabled: irohRelayEnabled ?? this.irohRelayEnabled,
      transportPolicies: transportPolicies ?? this.transportPolicies,
    );
  }

  /// Resolved routing mode after intersecting with the global kill-switch.
  EffectiveRoutingMode effectiveMode(GlobalConnectivityPreferences global) {
    final lan = global.lanEnabled && lanEnabled;
    final online = global.onlineEnabled && onlineEnabled;
    if (!lan && !online) return EffectiveRoutingMode.offline;
    if (lan && !online) return EffectiveRoutingMode.lanOnly;
    if (!lan && online) return EffectiveRoutingMode.onlineOnly;
    return preferred == RoutingPreference.online
        ? EffectiveRoutingMode.onlineFirst
        : EffectiveRoutingMode.lanFirst;
  }

  Map<String, dynamic> toJson() => {
    'lanEnabled': lanEnabled,
    'onlineEnabled': onlineEnabled,
    'preferred': preferred.name,
    'irohRelayEnabled': irohRelayEnabled,
    'transportPolicies': transportPoliciesToJson(transportPolicies),
  };

  factory ContactRoutingPreferences.fromJson(Map<String, dynamic> json) {
    final preferredRaw = json['preferred'] as String?;
    final preferred = RoutingPreference.values
        .where((p) => p.name == preferredRaw)
        .firstOrNull;
    final lanEnabled = json['lanEnabled'] as bool? ?? true;
    final onlineEnabled = json['onlineEnabled'] as bool? ?? true;
    final defaults = <TransportKind, TransportPolicy>{
      TransportKind.lan: lanEnabled
          ? TransportPolicy.automatic
          : TransportPolicy.disabled,
      TransportKind.iroh: onlineEnabled
          ? TransportPolicy.automatic
          : TransportPolicy.disabled,
      TransportKind.conestRelay: onlineEnabled
          ? TransportPolicy.automatic
          : TransportPolicy.disabled,
      TransportKind.optical: TransportPolicy.askBeforeUse,
      TransportKind.deltaChat: TransportPolicy.disabled,
      TransportKind.reticulum: TransportPolicy.disabled,
      TransportKind.localSend: TransportPolicy.disabled,
    };
    return ContactRoutingPreferences(
      lanEnabled: lanEnabled,
      onlineEnabled: onlineEnabled,
      preferred: preferred ?? RoutingPreference.lan,
      irohRelayEnabled: json['irohRelayEnabled'] as bool? ?? true,
      transportPolicies: transportPoliciesFromJson(
        json['transportPolicies'],
        defaults: defaults,
      ),
    );
  }
}

class IdentityRecord {
  IdentityRecord({
    required this.accountId,
    required this.deviceId,
    required this.displayName,
    required this.bio,
    required this.pairingNonce,
    required this.pairingEpochMs,
    required this.publicKeyBase64,
    required this.privateKeyBase64,
    required this.configuredRelays,
    required this.localRelayPort,
    required this.relayModeEnabled,
    required this.autoUseContactRelays,
    required this.notificationsEnabled,
    required this.androidBackgroundRuntimeEnabled,
    required this.suppressReadReceipts,
    this.connectivity = const GlobalConnectivityPreferences(),
    required this.lanAddresses,
    required this.safetyNumber,
    required this.createdAt,
    this.signingPublicKeyBase64,
    this.signingPrivateKeyBase64,
    this.irohEndpointId,
  });

  final String accountId;
  final String deviceId;
  final String displayName;
  final String bio;
  final String pairingNonce;
  final int pairingEpochMs;
  final String publicKeyBase64;
  final String privateKeyBase64;
  final List<PeerEndpoint> configuredRelays;
  final int localRelayPort;
  final bool relayModeEnabled;
  final bool autoUseContactRelays;
  final bool notificationsEnabled;
  final bool androidBackgroundRuntimeEnabled;
  final bool suppressReadReceipts;
  final GlobalConnectivityPreferences connectivity;
  final List<String> lanAddresses;
  final String safetyNumber;
  final DateTime createdAt;
  final String? signingPublicKeyBase64;
  final String? signingPrivateKeyBase64;
  final String? irohEndpointId;

  String get deviceIdShort => deviceId.substring(0, 8);
  String get shortSafetyNumber => _truncateSafetyNumber(safetyNumber);
  bool get hasInternetRelay => configuredRelays.isNotEmpty;
  bool get hasTransportIdentity =>
      signingPublicKeyBase64?.isNotEmpty == true &&
      signingPrivateKeyBase64?.isNotEmpty == true;
  PeerEndpoint? get primaryRelayRoute =>
      hasInternetRelay ? configuredRelays.first : null;
  String? get internetRelayHost => primaryRelayRoute?.host;
  int? get internetRelayPort => primaryRelayRoute?.port;

  List<PeerEndpoint> get advertisedRouteHints {
    final routes = <PeerEndpoint>[];
    for (final host in lanAddresses) {
      routes.add(
        PeerEndpoint(kind: PeerRouteKind.lan, host: host, port: localRelayPort),
      );
      routes.add(
        PeerEndpoint(
          kind: PeerRouteKind.lan,
          host: host,
          port: localRelayPort,
          protocol: PeerRouteProtocol.udp,
        ),
      );
    }
    routes.addAll(configuredRelays);
    return dedupePeerEndpoints(routes);
  }

  IdentityRecord copyWith({
    String? displayName,
    String? bio,
    String? pairingNonce,
    int? pairingEpochMs,
    List<PeerEndpoint>? configuredRelays,
    int? localRelayPort,
    bool? relayModeEnabled,
    bool? autoUseContactRelays,
    bool? notificationsEnabled,
    bool? androidBackgroundRuntimeEnabled,
    bool? suppressReadReceipts,
    GlobalConnectivityPreferences? connectivity,
    List<String>? lanAddresses,
    String? signingPublicKeyBase64,
    String? signingPrivateKeyBase64,
    String? irohEndpointId,
  }) {
    return IdentityRecord(
      accountId: accountId,
      deviceId: deviceId,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      pairingNonce: pairingNonce ?? this.pairingNonce,
      pairingEpochMs: pairingEpochMs ?? this.pairingEpochMs,
      publicKeyBase64: publicKeyBase64,
      privateKeyBase64: privateKeyBase64,
      configuredRelays: configuredRelays ?? this.configuredRelays,
      localRelayPort: localRelayPort ?? this.localRelayPort,
      relayModeEnabled: relayModeEnabled ?? this.relayModeEnabled,
      autoUseContactRelays: autoUseContactRelays ?? this.autoUseContactRelays,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      androidBackgroundRuntimeEnabled:
          androidBackgroundRuntimeEnabled ??
          this.androidBackgroundRuntimeEnabled,
      suppressReadReceipts: suppressReadReceipts ?? this.suppressReadReceipts,
      connectivity: connectivity ?? this.connectivity,
      lanAddresses: lanAddresses ?? this.lanAddresses,
      safetyNumber: safetyNumber,
      createdAt: createdAt,
      signingPublicKeyBase64:
          signingPublicKeyBase64 ?? this.signingPublicKeyBase64,
      signingPrivateKeyBase64:
          signingPrivateKeyBase64 ?? this.signingPrivateKeyBase64,
      irohEndpointId: irohEndpointId ?? this.irohEndpointId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accountId': accountId,
      'deviceId': deviceId,
      'displayName': displayName,
      'bio': bio,
      'pairingNonce': pairingNonce,
      'pairingEpochMs': pairingEpochMs,
      'publicKeyBase64': publicKeyBase64,
      'privateKeyBase64': privateKeyBase64,
      'configuredRelays': configuredRelays
          .map((route) => route.toJson())
          .toList(),
      'localRelayPort': localRelayPort,
      'relayModeEnabled': relayModeEnabled,
      'autoUseContactRelays': autoUseContactRelays,
      'notificationsEnabled': notificationsEnabled,
      'androidBackgroundRuntimeEnabled': androidBackgroundRuntimeEnabled,
      'suppressReadReceipts': suppressReadReceipts,
      'connectivity': connectivity.toJson(),
      'lanAddresses': lanAddresses,
      'safetyNumber': safetyNumber,
      'createdAt': createdAt.toIso8601String(),
      if (signingPublicKeyBase64 != null)
        'signingPublicKeyBase64': signingPublicKeyBase64,
      if (signingPrivateKeyBase64 != null)
        'signingPrivateKeyBase64': signingPrivateKeyBase64,
      if (irohEndpointId != null) 'irohEndpointId': irohEndpointId,
    };
  }

  factory IdentityRecord.fromJson(Map<String, dynamic> json) {
    final legacyRelayHost = json['relayHost'] as String?;
    final legacyRelayPort = json['relayPort'] as int?;
    final configuredRelays = _peerEndpointsFromJsonList(
      json['configuredRelays'] as List<dynamic>? ?? const [],
      expandMissingProtocol: true,
    ).where((route) => route.kind == PeerRouteKind.relay).toList();
    final legacyInternetRelayHost = json['internetRelayHost'] as String?;
    final legacyInternetRelayPort = json['internetRelayPort'] as int?;
    if (configuredRelays.isEmpty) {
      final host = legacyInternetRelayHost ?? legacyRelayHost;
      final port = legacyInternetRelayPort ?? legacyRelayPort;
      if (host != null && host.isNotEmpty && port != null) {
        configuredRelays.add(
          PeerEndpoint.normalized(
            kind: PeerRouteKind.relay,
            host: host,
            port: port,
          ),
        );
        configuredRelays.add(
          PeerEndpoint.normalized(
            kind: PeerRouteKind.relay,
            host: host,
            port: port,
            protocol: PeerRouteProtocol.udp,
          ),
        );
      }
    }
    final createdAt = DateTime.parse(json['createdAt'] as String);
    return IdentityRecord(
      accountId: json['accountId'] as String,
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      bio: json['bio'] as String? ?? '',
      pairingNonce: json['pairingNonce'] as String? ?? 'legacy',
      pairingEpochMs:
          json['pairingEpochMs'] as int? ?? createdAt.millisecondsSinceEpoch,
      publicKeyBase64: json['publicKeyBase64'] as String,
      privateKeyBase64: json['privateKeyBase64'] as String,
      configuredRelays: dedupePeerEndpoints(configuredRelays),
      localRelayPort:
          json['localRelayPort'] as int? ?? legacyRelayPort ?? defaultRelayPort,
      relayModeEnabled: json['relayModeEnabled'] as bool? ?? true,
      autoUseContactRelays: json['autoUseContactRelays'] as bool? ?? true,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      androidBackgroundRuntimeEnabled:
          json['androidBackgroundRuntimeEnabled'] as bool? ?? false,
      suppressReadReceipts: json['suppressReadReceipts'] as bool? ?? false,
      connectivity: json['connectivity'] is Map<String, dynamic>
          ? GlobalConnectivityPreferences.fromJson(
              json['connectivity'] as Map<String, dynamic>,
            )
          : const GlobalConnectivityPreferences(),
      lanAddresses: (json['lanAddresses'] as List<dynamic>? ?? const [])
          .cast<String>(),
      safetyNumber: json['safetyNumber'] as String,
      createdAt: createdAt,
      signingPublicKeyBase64: json['signingPublicKeyBase64'] as String?,
      signingPrivateKeyBase64: json['signingPrivateKeyBase64'] as String?,
      irohEndpointId: json['irohEndpointId'] as String?,
    );
  }
}

class ContactInvite {
  ContactInvite({
    required this.version,
    required this.accountId,
    required this.deviceId,
    required this.displayName,
    required this.bio,
    required this.pairingNonce,
    required this.pairingEpochMs,
    required this.relayCapable,
    required this.publicKeyBase64,
    required this.routeHints,
    this.signingPublicKeyBase64,
    this.irohEndpointId,
    this.capabilities = const <TransportKind>[],
    this.signatureBase64,
  });

  final int version;
  final String accountId;
  final String deviceId;
  final String displayName;
  final String bio;
  final String pairingNonce;
  final int pairingEpochMs;
  final bool relayCapable;
  final String publicKeyBase64;
  final List<PeerEndpoint> routeHints;
  final String? signingPublicKeyBase64;
  final String? irohEndpointId;
  final List<TransportKind> capabilities;
  final String? signatureBase64;

  bool get usesSignedFormat =>
      version >= 6 && signingPublicKeyBase64?.isNotEmpty == true;

  ContactInvite copyWithSignature(String signature) => ContactInvite(
    version: version,
    accountId: accountId,
    deviceId: deviceId,
    displayName: displayName,
    bio: bio,
    pairingNonce: pairingNonce,
    pairingEpochMs: pairingEpochMs,
    relayCapable: relayCapable,
    publicKeyBase64: publicKeyBase64,
    routeHints: routeHints,
    signingPublicKeyBase64: signingPublicKeyBase64,
    irohEndpointId: irohEndpointId,
    capabilities: capabilities,
    signatureBase64: signature,
  );

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'accountId': accountId,
      'deviceId': deviceId,
      'displayName': displayName,
      'bio': bio,
      'pairingNonce': pairingNonce,
      'pairingEpochMs': pairingEpochMs,
      'relayCapable': relayCapable,
      'publicKeyBase64': publicKeyBase64,
      'routeHints': routeHints.map((route) => route.toJson()).toList(),
      if (signingPublicKeyBase64 != null)
        'signingPublicKeyBase64': signingPublicKeyBase64,
      if (irohEndpointId != null) 'irohEndpointId': irohEndpointId,
      if (capabilities.isNotEmpty)
        'capabilities': capabilities.map((entry) => entry.name).toList(),
      if (signatureBase64 != null) 'signatureBase64': signatureBase64,
    };
  }

  String encodePayload() {
    return usesSignedFormat
        ? _encodeSignedCompactPayload()
        : _encodeCompactPayload();
  }

  /// Canonical text covered by the ci6 Ed25519 signature.
  String signingPayload() {
    if (!usesSignedFormat) {
      throw StateError('Only ci6 invites have a signing payload.');
    }
    return _encodeSignedCompactPayload(includeSignature: false);
  }

  String encodeLegacyPayload() {
    return base64Url.encode(utf8.encode(jsonEncode(toJson())));
  }

  String _encodeCompactPayload() {
    final routes = routeHints.map(_encodeCompactRoute).join(';');
    return [
      'ci5',
      version.toString(),
      accountId,
      deviceId,
      Uri.encodeComponent(displayName),
      Uri.encodeComponent(bio),
      pairingNonce,
      pairingEpochMs.toRadixString(36),
      relayCapable ? '1' : '0',
      publicKeyBase64,
      routes,
    ].join('|');
  }

  String _encodeSignedCompactPayload({bool includeSignature = true}) {
    final routes = routeHints.map(_encodeCompactRoute).join(';');
    final values = <String>[
      'ci6',
      version.toString(),
      accountId,
      deviceId,
      Uri.encodeComponent(displayName),
      Uri.encodeComponent(bio),
      pairingNonce,
      pairingEpochMs.toRadixString(36),
      relayCapable ? '1' : '0',
      publicKeyBase64,
      signingPublicKeyBase64 ?? '',
      Uri.encodeComponent(irohEndpointId ?? ''),
      capabilities.map((entry) => entry.name).join(','),
      routes,
    ];
    if (includeSignature) values.add(signatureBase64 ?? '');
    return values.join('|');
  }

  factory ContactInvite.fromJson(Map<String, dynamic> json) {
    final routeHints = _peerEndpointsFromJsonList(
      json['routeHints'] as List<dynamic>? ?? const [],
      expandMissingProtocol: true,
    );
    final legacyRelayHost = json['relayHost'] as String?;
    final legacyRelayPort = json['relayPort'] as int?;
    if (routeHints.isEmpty &&
        legacyRelayHost != null &&
        legacyRelayHost.isNotEmpty &&
        legacyRelayPort != null) {
      routeHints.add(
        PeerEndpoint.normalized(
          kind: PeerRouteKind.relay,
          host: legacyRelayHost,
          port: legacyRelayPort,
        ),
      );
      routeHints.add(
        PeerEndpoint.normalized(
          kind: PeerRouteKind.relay,
          host: legacyRelayHost,
          port: legacyRelayPort,
          protocol: PeerRouteProtocol.udp,
        ),
      );
    }
    return _validatedContactInvite(
      ContactInvite(
        version: json['version'] as int? ?? 1,
        accountId: json['accountId'] as String,
        deviceId: json['deviceId'] as String,
        displayName: json['displayName'] as String,
        bio: json['bio'] as String? ?? '',
        pairingNonce: json['pairingNonce'] as String? ?? '',
        pairingEpochMs: json['pairingEpochMs'] as int? ?? 0,
        relayCapable: json['relayCapable'] as bool? ?? true,
        publicKeyBase64: json['publicKeyBase64'] as String,
        routeHints: routeHints,
        signingPublicKeyBase64: json['signingPublicKeyBase64'] as String?,
        irohEndpointId: json['irohEndpointId'] as String?,
        capabilities: (json['capabilities'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .map(
              (name) => TransportKind.values
                  .where((entry) => entry.name == name)
                  .firstOrNull,
            )
            .nonNulls
            .toList(growable: false),
        signatureBase64: json['signatureBase64'] as String?,
      ),
    );
  }

  factory ContactInvite.decodePayload(String payload) {
    final normalized = payload.trim();
    if (normalized.startsWith('ci6|')) {
      return _decodeSignedCompactPayload(normalized);
    }
    if (normalized.startsWith('ci5|')) {
      return _decodeCompactPayload(normalized);
    }
    final decoded = utf8.decode(
      base64Url.decode(base64Url.normalize(normalized)),
    );
    final json = jsonDecode(decoded) as Map<String, dynamic>;
    return ContactInvite.fromJson(json);
  }

  static ContactInvite? tryDecodePayload(String payload) {
    try {
      return ContactInvite.decodePayload(payload);
    } catch (_) {
      return null;
    }
  }

  static ContactInvite _decodeCompactPayload(String payload) {
    final parts = payload.split('|');
    if (parts.length < 10 || parts.first != 'ci5') {
      throw const FormatException('Invalid compact invite payload.');
    }
    final routes = parts.length > 10 ? parts.sublist(10).join('|') : '';
    return _validatedContactInvite(
      ContactInvite(
        version: int.tryParse(parts[1]) ?? 5,
        accountId: parts[2],
        deviceId: parts[3],
        displayName: Uri.decodeComponent(parts[4]),
        bio: Uri.decodeComponent(parts[5]),
        pairingNonce: parts[6],
        pairingEpochMs: int.tryParse(parts[7], radix: 36) ?? 0,
        relayCapable: parts[8] == '1',
        publicKeyBase64: parts[9],
        routeHints: dedupePeerEndpoints(
          routes.isEmpty
              ? const <PeerEndpoint>[]
              : routes
                    .split(';')
                    .map(_decodeCompactRoute)
                    .nonNulls
                    .toList(growable: false),
        ),
      ),
    );
  }

  static ContactInvite _decodeSignedCompactPayload(String payload) {
    final parts = payload.split('|');
    if (parts.length != 15 || parts.first != 'ci6') {
      throw const FormatException('Invalid signed compact invite payload.');
    }
    final capabilities = parts[12]
        .split(',')
        .where((value) => value.isNotEmpty)
        .map(
          (name) => TransportKind.values
              .where((entry) => entry.name == name)
              .firstOrNull,
        )
        .nonNulls
        .toList(growable: false);
    return _validatedContactInvite(
      ContactInvite(
        version: int.tryParse(parts[1]) ?? 6,
        accountId: parts[2],
        deviceId: parts[3],
        displayName: Uri.decodeComponent(parts[4]),
        bio: Uri.decodeComponent(parts[5]),
        pairingNonce: parts[6],
        pairingEpochMs: int.tryParse(parts[7], radix: 36) ?? 0,
        relayCapable: parts[8] == '1',
        publicKeyBase64: parts[9],
        signingPublicKeyBase64: parts[10],
        irohEndpointId: Uri.decodeComponent(parts[11]),
        capabilities: capabilities,
        routeHints: dedupePeerEndpoints(
          parts[13].isEmpty
              ? const <PeerEndpoint>[]
              : parts[13]
                    .split(';')
                    .map(_decodeCompactRoute)
                    .nonNulls
                    .toList(growable: false),
        ),
        signatureBase64: parts[14],
      ),
    );
  }
}

ContactInvite _validatedContactInvite(ContactInvite invite) {
  bool safeIdentifier(String value) =>
      value.isNotEmpty &&
      value.length <= 128 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
  if (invite.version < 1 || invite.version > 16) {
    throw const FormatException('Unsupported contact invite version.');
  }
  if (!safeIdentifier(invite.accountId) ||
      !safeIdentifier(invite.deviceId) ||
      invite.displayName.trim().isEmpty ||
      invite.displayName.length > 80 ||
      invite.bio.length > 512 ||
      invite.pairingNonce.length > 128 ||
      invite.pairingEpochMs < 0 ||
      invite.routeHints.length > 8) {
    throw const FormatException('Contact invite fields are out of range.');
  }
  final keyBytes = base64Decode(invite.publicKeyBase64);
  if (keyBytes.length != 32) {
    throw const FormatException('Contact invite public key must be 32 bytes.');
  }
  if (invite.version >= 6) {
    final signingKey = base64Decode(invite.signingPublicKeyBase64 ?? '');
    final signature = base64Decode(invite.signatureBase64 ?? '');
    if (signingKey.length != 32 || signature.length != 64) {
      throw const FormatException(
        'Signed contact invite has an invalid identity key or signature.',
      );
    }
    final endpointId = invite.irohEndpointId ?? '';
    if (endpointId.isEmpty || endpointId.length > 256) {
      throw const FormatException(
        'Signed contact invite has no Iroh identity.',
      );
    }
    if (invite.capabilities.length > TransportKind.values.length) {
      throw const FormatException('Contact invite has too many capabilities.');
    }
  }
  for (final route in invite.routeHints) {
    if (!isValidPeerEndpointHost(route.host) ||
        !isValidPeerEndpointPort(route.port) ||
        route.host.length > 253) {
      throw const FormatException('Contact invite contains an invalid route.');
    }
  }
  return invite;
}

String _encodeCompactRoute(PeerEndpoint route) {
  final kind = switch (route.kind) {
    PeerRouteKind.lan => 'l',
    PeerRouteKind.directInternet => 'd',
    PeerRouteKind.relay => 'r',
  };
  final protocol = switch (route.protocol) {
    PeerRouteProtocol.tcp => 't',
    PeerRouteProtocol.udp => 'u',
    PeerRouteProtocol.http => 'h',
    PeerRouteProtocol.https => 's',
  };
  return '$kind$protocol${route.port.toRadixString(36)}:${Uri.encodeComponent(route.host)}';
}

PeerEndpoint? _decodeCompactRoute(String value) {
  if (value.length < 4) {
    return null;
  }
  final separator = value.indexOf(':', 2);
  if (separator == -1) {
    return null;
  }
  final kind = switch (value[0]) {
    'l' => PeerRouteKind.lan,
    'd' => PeerRouteKind.directInternet,
    'r' => PeerRouteKind.relay,
    _ => null,
  };
  final protocol = switch (value[1]) {
    't' => PeerRouteProtocol.tcp,
    'u' => PeerRouteProtocol.udp,
    'h' => PeerRouteProtocol.http,
    's' => PeerRouteProtocol.https,
    _ => null,
  };
  final port = int.tryParse(value.substring(2, separator), radix: 36);
  if (kind == null || protocol == null || port == null) {
    return null;
  }
  final host = Uri.decodeComponent(value.substring(separator + 1));
  if (!isValidPeerEndpointHost(host) || !isValidPeerEndpointPort(port)) {
    return null;
  }
  return PeerEndpoint(kind: kind, host: host, port: port, protocol: protocol);
}

class ContactRecord {
  ContactRecord({
    required this.accountId,
    required this.deviceId,
    required this.alias,
    required this.displayName,
    required this.bio,
    required this.relayCapable,
    required this.publicKeyBase64,
    required this.routeHints,
    required this.safetyNumber,
    required this.trustedAt,
    this.pendingVerification = false,
    this.replacesDeviceId,
    this.replacedByDeviceId,
    this.unverifiedPublicKeyBase64,
    this.remoteRemovedAt,
    this.routing = const ContactRoutingPreferences(),
    this.signingPublicKeyBase64,
    this.irohEndpointId,
    this.capabilities = const <TransportKind>[],
    this.transportIdentityVerifiedAt,
  });

  final String accountId;
  final String deviceId;
  final String alias;
  final String displayName;
  final String bio;
  final bool relayCapable;
  final String publicKeyBase64;
  final List<PeerEndpoint> routeHints;
  final String safetyNumber;
  final DateTime trustedAt;
  final ContactRoutingPreferences routing;
  final String? signingPublicKeyBase64;
  final String? irohEndpointId;
  final List<TransportKind> capabilities;
  final DateTime? transportIdentityVerifiedAt;

  /// True when this contact arrived with a `displayName` matching an existing
  /// trusted contact AND a different identity public key — i.e. possibly a
  /// reinstall of an existing contact, but also possibly an impersonation
  /// attempt against a leaked codephrase. The user must explicitly confirm
  /// or reject via [`confirmContactReplacement`]/[`rejectContactReplacement`]
  /// before any envelopes flow in either direction.
  final bool pendingVerification;

  /// When [pendingVerification] is true, the `deviceId` of the existing
  /// trusted contact we believe this contact is replacing. Surfaces the
  /// predecessor's display name in the verification banner.
  final String? replacesDeviceId;

  /// When the user has confirmed that some _other_ contact has replaced this
  /// one, [`replacedByDeviceId`] points at that successor and outbound
  /// delivery is refused. History stays visible read-only.
  final String? replacedByDeviceId;

  /// Public key carried by the inbound invite when this contact landed in
  /// `pendingVerification`. Promoted to [publicKeyBase64] on
  /// `confirmContactReplacement`; discarded on `rejectContactReplacement`.
  /// While set, [publicKeyBase64] is empty so the pairwise key derivation in
  /// the controller (X25519 + HKDF) literally cannot produce a shared secret
  /// — outbound encrypts and inbound decrypts both fail at the crypto layer
  /// regardless of which call site triggered them. The pending state IS the
  /// absence of usable cryptographic material; no controller-level policy
  /// check is required for correctness.
  final String? unverifiedPublicKeyBase64;

  /// When the peer authenticated a contact-removal request. Remote peers are
  /// never allowed to erase local history; this flag only archives the
  /// contact and disables further outbound traffic until the user removes or
  /// re-adds it locally.
  final DateTime? remoteRemovedAt;

  String get shortSafetyNumber => _truncateSafetyNumber(safetyNumber);

  bool get isArchived => replacedByDeviceId != null || remoteRemovedAt != null;
  bool get canSendOutbound => !pendingVerification && !isArchived;
  bool get hasPinnedIrohIdentity =>
      irohEndpointId?.isNotEmpty == true &&
      signingPublicKeyBase64?.isNotEmpty == true;

  ContactRecord copyWith({
    String? alias,
    String? displayName,
    String? bio,
    bool? relayCapable,
    String? publicKeyBase64,
    List<PeerEndpoint>? routeHints,
    bool? pendingVerification,
    String? replacesDeviceId,
    bool clearReplacesDeviceId = false,
    String? replacedByDeviceId,
    bool clearReplacedByDeviceId = false,
    String? unverifiedPublicKeyBase64,
    bool clearUnverifiedPublicKey = false,
    DateTime? remoteRemovedAt,
    bool clearRemoteRemovedAt = false,
    ContactRoutingPreferences? routing,
    String? signingPublicKeyBase64,
    String? irohEndpointId,
    List<TransportKind>? capabilities,
    DateTime? transportIdentityVerifiedAt,
  }) {
    return ContactRecord(
      accountId: accountId,
      deviceId: deviceId,
      alias: alias ?? this.alias,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      relayCapable: relayCapable ?? this.relayCapable,
      publicKeyBase64: publicKeyBase64 ?? this.publicKeyBase64,
      routeHints: prunePeerEndpointsByKind(routeHints ?? this.routeHints),
      safetyNumber: safetyNumber,
      trustedAt: trustedAt,
      pendingVerification: pendingVerification ?? this.pendingVerification,
      replacesDeviceId: clearReplacesDeviceId
          ? null
          : (replacesDeviceId ?? this.replacesDeviceId),
      replacedByDeviceId: clearReplacedByDeviceId
          ? null
          : (replacedByDeviceId ?? this.replacedByDeviceId),
      unverifiedPublicKeyBase64: clearUnverifiedPublicKey
          ? null
          : (unverifiedPublicKeyBase64 ?? this.unverifiedPublicKeyBase64),
      remoteRemovedAt: clearRemoteRemovedAt
          ? null
          : (remoteRemovedAt ?? this.remoteRemovedAt),
      routing: routing ?? this.routing,
      signingPublicKeyBase64:
          signingPublicKeyBase64 ?? this.signingPublicKeyBase64,
      irohEndpointId: irohEndpointId ?? this.irohEndpointId,
      capabilities: capabilities ?? this.capabilities,
      transportIdentityVerifiedAt:
          transportIdentityVerifiedAt ?? this.transportIdentityVerifiedAt,
    );
  }

  List<PeerEndpoint> get lanRouteHints => routeHints
      .where((route) => route.kind == PeerRouteKind.lan)
      .toList(growable: false);

  List<PeerEndpoint> get directInternetRouteHints => routeHints
      .where((route) => route.kind == PeerRouteKind.directInternet)
      .toList(growable: false);

  List<PeerEndpoint> get relayRouteHints => routeHints
      .where((route) => route.kind == PeerRouteKind.relay)
      .toList(growable: false);

  List<PeerEndpoint> get prioritizedRouteHints {
    final seen = <String>{};
    final prioritized = <PeerEndpoint>[
      ...lanRouteHints,
      ...directInternetRouteHints,
      ...relayRouteHints,
    ];
    return prioritized.where((route) => seen.add(route.routeKey)).toList();
  }

  PeerEndpoint? get primaryRelayRoute {
    for (final route in routeHints) {
      if (route.kind == PeerRouteKind.relay) {
        return route;
      }
    }
    return null;
  }

  String get relayHost => primaryRelayRoute?.host ?? 'none';
  int get relayPort => primaryRelayRoute?.port ?? 0;

  String get routeSummary {
    final parts = <String>[];
    if (lanRouteHints.isNotEmpty) {
      final hosts = lanRouteHints.take(2).map((route) => route.host).join(', ');
      parts.add('LAN $hosts');
    }
    if (directInternetRouteHints.isNotEmpty) {
      final hosts = directInternetRouteHints
          .take(2)
          .map((route) => route.host)
          .join(', ');
      parts.add('direct $hosts');
    }
    final relay = primaryRelayRoute;
    if (relay != null) {
      parts.add('relay ${relay.host}:${relay.port}');
    }
    if (parts.isEmpty) {
      return 'no routes advertised';
    }
    final summary = parts.join(' • ');
    return relayCapable ? '$summary • relay-capable' : summary;
  }

  Map<String, dynamic> toJson() {
    return {
      'accountId': accountId,
      'deviceId': deviceId,
      'alias': alias,
      'displayName': displayName,
      'bio': bio,
      'relayCapable': relayCapable,
      'publicKeyBase64': publicKeyBase64,
      'routeHints': routeHints.map((route) => route.toJson()).toList(),
      'safetyNumber': safetyNumber,
      'trustedAt': trustedAt.toIso8601String(),
      'pendingVerification': pendingVerification,
      if (replacesDeviceId != null) 'replacesDeviceId': replacesDeviceId,
      if (replacedByDeviceId != null) 'replacedByDeviceId': replacedByDeviceId,
      if (unverifiedPublicKeyBase64 != null)
        'unverifiedPublicKeyBase64': unverifiedPublicKeyBase64,
      if (remoteRemovedAt != null)
        'remoteRemovedAt': remoteRemovedAt!.toUtc().toIso8601String(),
      'routing': routing.toJson(),
      if (signingPublicKeyBase64 != null)
        'signingPublicKeyBase64': signingPublicKeyBase64,
      if (irohEndpointId != null) 'irohEndpointId': irohEndpointId,
      if (capabilities.isNotEmpty)
        'capabilities': capabilities.map((entry) => entry.name).toList(),
      if (transportIdentityVerifiedAt != null)
        'transportIdentityVerifiedAt': transportIdentityVerifiedAt!
            .toUtc()
            .toIso8601String(),
    };
  }

  factory ContactRecord.fromJson(Map<String, dynamic> json) {
    final routeHints = _peerEndpointsFromJsonList(
      json['routeHints'] as List<dynamic>? ?? const [],
      expandMissingProtocol: true,
    );
    final legacyRelayHost = json['relayHost'] as String?;
    final legacyRelayPort = json['relayPort'] as int?;
    if (routeHints.isEmpty &&
        legacyRelayHost != null &&
        legacyRelayHost.isNotEmpty &&
        legacyRelayPort != null) {
      routeHints.add(
        PeerEndpoint.normalized(
          kind: PeerRouteKind.relay,
          host: legacyRelayHost,
          port: legacyRelayPort,
        ),
      );
      routeHints.add(
        PeerEndpoint.normalized(
          kind: PeerRouteKind.relay,
          host: legacyRelayHost,
          port: legacyRelayPort,
          protocol: PeerRouteProtocol.udp,
        ),
      );
    }
    final pending = json['pendingVerification'] as bool? ?? false;
    var activePublicKey = json['publicKeyBase64'] as String;
    var unverifiedKey = json['unverifiedPublicKeyBase64'] as String?;
    // Legacy migration from v0.3.1-nightly.2: those vaults persisted the
    // real key on `publicKeyBase64` even while pending. Move it to the
    // unverified slot so the crypto layer can't derive a shared secret
    // until the user confirms.
    if (pending && activePublicKey.isNotEmpty && unverifiedKey == null) {
      unverifiedKey = activePublicKey;
      activePublicKey = '';
    }
    return ContactRecord(
      accountId: json['accountId'] as String,
      deviceId: json['deviceId'] as String,
      alias: json['alias'] as String,
      displayName: json['displayName'] as String,
      bio: json['bio'] as String? ?? '',
      relayCapable: json['relayCapable'] as bool? ?? true,
      publicKeyBase64: activePublicKey,
      routeHints: prunePeerEndpointsByKind(routeHints),
      safetyNumber: json['safetyNumber'] as String,
      trustedAt: DateTime.parse(json['trustedAt'] as String),
      pendingVerification: pending,
      replacesDeviceId: json['replacesDeviceId'] as String?,
      replacedByDeviceId: json['replacedByDeviceId'] as String?,
      unverifiedPublicKeyBase64: unverifiedKey,
      remoteRemovedAt: DateTime.tryParse(
        json['remoteRemovedAt'] as String? ?? '',
      )?.toUtc(),
      routing: json['routing'] is Map<String, dynamic>
          ? ContactRoutingPreferences.fromJson(
              json['routing'] as Map<String, dynamic>,
            )
          : const ContactRoutingPreferences(),
      signingPublicKeyBase64: json['signingPublicKeyBase64'] as String?,
      irohEndpointId: json['irohEndpointId'] as String?,
      capabilities: (json['capabilities'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .map(
            (name) => TransportKind.values
                .where((entry) => entry.name == name)
                .firstOrNull,
          )
          .nonNulls
          .toList(growable: false),
      transportIdentityVerifiedAt: DateTime.tryParse(
        json['transportIdentityVerifiedAt'] as String? ?? '',
      )?.toUtc(),
    );
  }
}

class ContactReachabilityRecord {
  const ContactReachabilityRecord({
    required this.deviceId,
    this.lastTwoWaySuccessAt,
    this.lastHeartbeatAttemptAt,
    this.lastHeartbeatReplyAt,
    this.lastAvailablePathAt,
    this.lastAnySignalAt,
    this.lastFailureAt,
  });

  final String deviceId;
  final DateTime? lastTwoWaySuccessAt;
  final DateTime? lastHeartbeatAttemptAt;
  final DateTime? lastHeartbeatReplyAt;
  final DateTime? lastAvailablePathAt;
  final DateTime? lastAnySignalAt;
  final DateTime? lastFailureAt;

  ContactReachabilityRecord copyWith({
    DateTime? lastTwoWaySuccessAt,
    DateTime? lastHeartbeatAttemptAt,
    DateTime? lastHeartbeatReplyAt,
    DateTime? lastAvailablePathAt,
    DateTime? lastAnySignalAt,
    DateTime? lastFailureAt,
  }) {
    return ContactReachabilityRecord(
      deviceId: deviceId,
      lastTwoWaySuccessAt: lastTwoWaySuccessAt ?? this.lastTwoWaySuccessAt,
      lastHeartbeatAttemptAt:
          lastHeartbeatAttemptAt ?? this.lastHeartbeatAttemptAt,
      lastHeartbeatReplyAt: lastHeartbeatReplyAt ?? this.lastHeartbeatReplyAt,
      lastAvailablePathAt: lastAvailablePathAt ?? this.lastAvailablePathAt,
      lastAnySignalAt: lastAnySignalAt ?? this.lastAnySignalAt,
      lastFailureAt: lastFailureAt ?? this.lastFailureAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'lastTwoWaySuccessAt': lastTwoWaySuccessAt?.toIso8601String(),
      'lastHeartbeatAttemptAt': lastHeartbeatAttemptAt?.toIso8601String(),
      'lastHeartbeatReplyAt': lastHeartbeatReplyAt?.toIso8601String(),
      'lastAvailablePathAt': lastAvailablePathAt?.toIso8601String(),
      'lastAnySignalAt': lastAnySignalAt?.toIso8601String(),
      'lastFailureAt': lastFailureAt?.toIso8601String(),
    };
  }

  factory ContactReachabilityRecord.fromJson(Map<String, dynamic> json) {
    DateTime? parse(String key) {
      final value = json[key] as String?;
      if (value == null || value.isEmpty) {
        return null;
      }
      return DateTime.tryParse(value);
    }

    return ContactReachabilityRecord(
      deviceId: json['deviceId'] as String,
      lastTwoWaySuccessAt: parse('lastTwoWaySuccessAt'),
      lastHeartbeatAttemptAt: parse('lastHeartbeatAttemptAt'),
      lastHeartbeatReplyAt: parse('lastHeartbeatReplyAt'),
      lastAvailablePathAt: parse('lastAvailablePathAt'),
      lastAnySignalAt: parse('lastAnySignalAt'),
      lastFailureAt: parse('lastFailureAt'),
    );
  }
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.body,
    required this.outbound,
    required this.state,
    required this.createdAt,
    this.senderDisplayName,
    this.untrusted = false,
    this.editedAt,
    this.replyToMessageId,
    this.replySnippet,
    this.replySenderDeviceId,
    this.replySenderDisplayName,
    this.attachment,
    this.albumId,
    this.transportKind,
    this.transportPath,
    this.transportDetail,
    Map<String, DeliveryState>? recipientStates,
  }) : recipientStates = Map.unmodifiable(
         recipientStates ?? const <String, DeliveryState>{},
       );

  final String id;
  final String conversationId;
  final String senderDeviceId;
  final String recipientDeviceId;
  final String body;
  final bool outbound;
  final DeliveryState state;
  final DateTime createdAt;
  final String? senderDisplayName;
  final bool untrusted;
  final DateTime? editedAt;
  final String? replyToMessageId;
  final String? replySnippet;
  final String? replySenderDeviceId;
  final String? replySenderDisplayName;

  /// Non-null on v0.3.2+ messages that carry a file or image attachment.
  /// `body` may still hold a short caption alongside the attachment.
  final AttachmentDescriptor? attachment;

  /// Telegram-style media-group id. Consecutive same-sender messages that
  /// share an `albumId` render as a single album bubble in the UI; null
  /// for standalone messages (text-only OR singleton captioned image).
  final String? albumId;
  final TransportKind? transportKind;
  final TransportPathKind? transportPath;
  final String? transportDetail;

  final Map<String, DeliveryState> recipientStates;

  String get bodyPreview => body.replaceAll('\n', ' ');
  bool get isEdited => editedAt != null;
  bool get hasRecipientStates => recipientStates.isNotEmpty;
  bool get hasAttachment => attachment != null;
  bool get hasReplyPreview =>
      replyToMessageId != null &&
      replyToMessageId!.isNotEmpty &&
      replySnippet != null &&
      replySnippet!.trim().isNotEmpty;

  ChatMessage copyWith({
    String? body,
    DeliveryState? state,
    DateTime? editedAt,
    String? replyToMessageId,
    String? replySnippet,
    String? replySenderDeviceId,
    String? replySenderDisplayName,
    AttachmentDescriptor? attachment,
    bool clearAttachment = false,
    String? albumId,
    TransportKind? transportKind,
    TransportPathKind? transportPath,
    String? transportDetail,
    Map<String, DeliveryState>? recipientStates,
  }) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      body: body ?? this.body,
      outbound: outbound,
      state: state ?? this.state,
      createdAt: createdAt,
      senderDisplayName: senderDisplayName,
      untrusted: untrusted,
      editedAt: editedAt ?? this.editedAt,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replySnippet: replySnippet ?? this.replySnippet,
      replySenderDeviceId: replySenderDeviceId ?? this.replySenderDeviceId,
      replySenderDisplayName:
          replySenderDisplayName ?? this.replySenderDisplayName,
      attachment: clearAttachment ? null : (attachment ?? this.attachment),
      albumId: albumId ?? this.albumId,
      transportKind: transportKind ?? this.transportKind,
      transportPath: transportPath ?? this.transportPath,
      transportDetail: transportDetail ?? this.transportDetail,
      recipientStates: recipientStates ?? this.recipientStates,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'senderDeviceId': senderDeviceId,
      'recipientDeviceId': recipientDeviceId,
      'body': body,
      'outbound': outbound,
      'state': state.name,
      'createdAt': createdAt.toIso8601String(),
      'senderDisplayName': senderDisplayName,
      'untrusted': untrusted,
      'editedAt': editedAt?.toIso8601String(),
      'replyToMessageId': replyToMessageId,
      'replySnippet': replySnippet,
      'replySenderDeviceId': replySenderDeviceId,
      'replySenderDisplayName': replySenderDisplayName,
      if (attachment != null) 'attachment': attachment!.toJson(),
      if (albumId != null) 'albumId': albumId,
      if (transportKind != null) 'transportKind': transportKind!.name,
      if (transportPath != null) 'transportPath': transportPath!.name,
      if (transportDetail != null) 'transportDetail': transportDetail,
      'recipientStates': recipientStates.map(
        (deviceId, state) => MapEntry(deviceId, state.name),
      ),
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawRecipientStates =
        json['recipientStates'] as Map<String, dynamic>? ?? const {};
    return ChatMessage(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      senderDeviceId: json['senderDeviceId'] as String,
      recipientDeviceId: json['recipientDeviceId'] as String,
      body: json['body'] as String,
      outbound: json['outbound'] as bool,
      state: DeliveryState.values.byName(json['state'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      senderDisplayName: json['senderDisplayName'] as String?,
      untrusted: json['untrusted'] as bool? ?? false,
      editedAt: json['editedAt'] == null
          ? null
          : DateTime.parse(json['editedAt'] as String),
      replyToMessageId: json['replyToMessageId'] as String?,
      replySnippet: json['replySnippet'] as String?,
      replySenderDeviceId: json['replySenderDeviceId'] as String?,
      replySenderDisplayName: json['replySenderDisplayName'] as String?,
      attachment: json['attachment'] is Map<String, dynamic>
          ? AttachmentDescriptor.fromJson(
              json['attachment'] as Map<String, dynamic>,
            )
          : null,
      albumId: json['albumId'] as String?,
      transportKind: TransportKind.values
          .where((entry) => entry.name == json['transportKind'])
          .firstOrNull,
      transportPath: TransportPathKind.values
          .where((entry) => entry.name == json['transportPath'])
          .firstOrNull,
      transportDetail: json['transportDetail'] as String?,
      recipientStates: rawRecipientStates.map(
        (deviceId, value) =>
            MapEntry(deviceId, DeliveryState.values.byName(value as String)),
      ),
    );
  }
}

class GroupMemberProfile {
  GroupMemberProfile({
    required this.accountId,
    required this.deviceId,
    required this.displayName,
    required this.bio,
    required this.relayCapable,
    required this.publicKeyBase64,
    required List<PeerEndpoint> routeHints,
  }) : routeHints = prunePeerEndpointsByKind(routeHints);

  final String accountId;
  final String deviceId;
  final String displayName;
  final String bio;
  final bool relayCapable;
  final String publicKeyBase64;
  final List<PeerEndpoint> routeHints;

  GroupMemberProfile copyWith({
    String? displayName,
    String? bio,
    bool? relayCapable,
    List<PeerEndpoint>? routeHints,
  }) {
    return GroupMemberProfile(
      accountId: accountId,
      deviceId: deviceId,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      relayCapable: relayCapable ?? this.relayCapable,
      publicKeyBase64: publicKeyBase64,
      routeHints: routeHints ?? this.routeHints,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accountId': accountId,
      'deviceId': deviceId,
      'displayName': displayName,
      'bio': bio,
      'relayCapable': relayCapable,
      'publicKeyBase64': publicKeyBase64,
      'routeHints': routeHints.map((route) => route.toJson()).toList(),
    };
  }

  factory GroupMemberProfile.fromJson(Map<String, dynamic> json) {
    return GroupMemberProfile(
      accountId: json['accountId'] as String,
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      bio: json['bio'] as String? ?? '',
      relayCapable: json['relayCapable'] as bool? ?? true,
      publicKeyBase64: json['publicKeyBase64'] as String,
      routeHints: _peerEndpointsFromJsonList(
        json['routeHints'] as List<dynamic>? ?? const [],
        expandMissingProtocol: true,
      ),
    );
  }
}

class GroupRecord {
  GroupRecord({
    required this.groupId,
    required this.title,
    required this.ownerDeviceId,
    required List<String> adminDeviceIds,
    List<String> moderatorDeviceIds = const <String>[],
    required List<String> memberDeviceIds,
    required List<String> removedDeviceIds,
    List<GroupMemberProfile> memberProfiles = const <GroupMemberProfile>[],
    required this.membershipVersion,
    required this.createdAt,
    required this.updatedAt,
    this.localRemovedAt,
    this.dissolvedAt,
  }) : adminDeviceIds = _normalizedGroupRoleIds(
         ownerDeviceId: ownerDeviceId,
         memberDeviceIds: memberDeviceIds,
         removedDeviceIds: removedDeviceIds,
         roleDeviceIds: adminDeviceIds,
       ),
       moderatorDeviceIds = _normalizedGroupRoleIds(
         ownerDeviceId: ownerDeviceId,
         memberDeviceIds: memberDeviceIds,
         removedDeviceIds: removedDeviceIds,
         roleDeviceIds: moderatorDeviceIds,
         excludedRoleDeviceIds: _normalizedGroupRoleIds(
           ownerDeviceId: ownerDeviceId,
           memberDeviceIds: memberDeviceIds,
           removedDeviceIds: removedDeviceIds,
           roleDeviceIds: adminDeviceIds,
         ),
       ),
       memberDeviceIds = _dedupeIds([ownerDeviceId, ...memberDeviceIds]),
       removedDeviceIds = _dedupeIds(
         removedDeviceIds,
       ).where((deviceId) => deviceId != ownerDeviceId).toList(),
       memberProfiles = _dedupeMemberProfiles(memberProfiles);

  final String groupId;
  final String title;
  final String ownerDeviceId;
  final List<String> adminDeviceIds;
  final List<String> moderatorDeviceIds;
  final List<String> memberDeviceIds;
  final List<String> removedDeviceIds;
  final List<GroupMemberProfile> memberProfiles;
  final int membershipVersion;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Set when the local user explicitly removes a group they have already
  /// left (or were removed from) from their visible groups list. Local-only:
  /// never sent on the wire; never read by other devices' membership logic.
  /// Null means the group should still appear in the UI.
  final DateTime? localRemovedAt;

  /// Set when the owner has dissolved the group for everyone. Once a group
  /// is dissolved it has no active members, no roles, and no future state
  /// transitions — every recipient drops to the "you left" UX. Carried on
  /// the wire so an inbound dissolve envelope propagates the state.
  final DateTime? dissolvedAt;

  bool get isDissolved => dissolvedAt != null;

  List<String> get activeMemberDeviceIds => isDissolved
      ? const <String>[]
      : memberDeviceIds
            .where((deviceId) => !removedDeviceIds.contains(deviceId))
            .toList(growable: false);

  bool hasActiveMember(String deviceId) =>
      activeMemberDeviceIds.contains(deviceId);

  GroupMemberRole? roleFor(String deviceId) {
    if (!hasActiveMember(deviceId)) {
      return null;
    }
    if (deviceId == ownerDeviceId) {
      return GroupMemberRole.owner;
    }
    if (adminDeviceIds.contains(deviceId)) {
      return GroupMemberRole.admin;
    }
    if (moderatorDeviceIds.contains(deviceId)) {
      return GroupMemberRole.moderator;
    }
    return GroupMemberRole.member;
  }

  bool canAssignRoles(String actorDeviceId) =>
      roleFor(actorDeviceId) == GroupMemberRole.owner;

  bool canAddMembers(String actorDeviceId) {
    final role = roleFor(actorDeviceId);
    return role == GroupMemberRole.owner || role == GroupMemberRole.admin;
  }

  bool canRemoveMember({
    required String actorDeviceId,
    required String memberDeviceId,
  }) {
    final actorRole = roleFor(actorDeviceId);
    final memberRole = roleFor(memberDeviceId);
    if (actorRole == null || memberRole == null) {
      return false;
    }
    if (memberRole == GroupMemberRole.owner) {
      return false;
    }
    if (actorRole == GroupMemberRole.owner) {
      return true;
    }
    if (actorRole == GroupMemberRole.admin) {
      return memberRole == GroupMemberRole.member ||
          memberRole == GroupMemberRole.moderator;
    }
    return false;
  }

  GroupMemberProfile? memberProfileFor(String deviceId) {
    for (final profile in memberProfiles) {
      if (profile.deviceId == deviceId) {
        return profile;
      }
    }
    return null;
  }

  GroupRecord copyWith({
    String? title,
    String? ownerDeviceId,
    List<String>? adminDeviceIds,
    List<String>? moderatorDeviceIds,
    List<String>? memberDeviceIds,
    List<String>? removedDeviceIds,
    List<GroupMemberProfile>? memberProfiles,
    int? membershipVersion,
    DateTime? updatedAt,
    DateTime? localRemovedAt,
    DateTime? dissolvedAt,
    bool clearLocalRemovedAt = false,
  }) {
    return GroupRecord(
      groupId: groupId,
      title: title ?? this.title,
      ownerDeviceId: ownerDeviceId ?? this.ownerDeviceId,
      adminDeviceIds: adminDeviceIds ?? this.adminDeviceIds,
      moderatorDeviceIds: moderatorDeviceIds ?? this.moderatorDeviceIds,
      memberDeviceIds: memberDeviceIds ?? this.memberDeviceIds,
      removedDeviceIds: removedDeviceIds ?? this.removedDeviceIds,
      memberProfiles: memberProfiles ?? this.memberProfiles,
      membershipVersion: membershipVersion ?? this.membershipVersion,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      localRemovedAt: clearLocalRemovedAt
          ? null
          : (localRemovedAt ?? this.localRemovedAt),
      dissolvedAt: dissolvedAt ?? this.dissolvedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'groupId': groupId,
      'title': title,
      'ownerDeviceId': ownerDeviceId,
      'adminDeviceIds': adminDeviceIds,
      'moderatorDeviceIds': moderatorDeviceIds,
      'memberDeviceIds': memberDeviceIds,
      'removedDeviceIds': removedDeviceIds,
      'memberProfiles': memberProfiles
          .map((profile) => profile.toJson())
          .toList(),
      'membershipVersion': membershipVersion,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'localRemovedAt': localRemovedAt?.toIso8601String(),
      'dissolvedAt': dissolvedAt?.toIso8601String(),
    };
  }

  factory GroupRecord.fromJson(Map<String, dynamic> json) {
    final createdAt = DateTime.parse(json['createdAt'] as String);
    return GroupRecord(
      groupId: json['groupId'] as String,
      title: json['title'] as String,
      ownerDeviceId: json['ownerDeviceId'] as String,
      adminDeviceIds: (json['adminDeviceIds'] as List<dynamic>? ?? const [])
          .cast<String>(),
      moderatorDeviceIds:
          (json['moderatorDeviceIds'] as List<dynamic>? ?? const [])
              .cast<String>(),
      memberDeviceIds: (json['memberDeviceIds'] as List<dynamic>? ?? const [])
          .cast<String>(),
      removedDeviceIds: (json['removedDeviceIds'] as List<dynamic>? ?? const [])
          .cast<String>(),
      memberProfiles: (json['memberProfiles'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(GroupMemberProfile.fromJson)
          .toList(),
      membershipVersion: json['membershipVersion'] as int? ?? 1,
      createdAt: createdAt,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? createdAt,
      localRemovedAt: DateTime.tryParse(
        json['localRemovedAt'] as String? ?? '',
      ),
      dissolvedAt: DateTime.tryParse(json['dissolvedAt'] as String? ?? ''),
    );
  }
}

List<GroupMemberProfile> _dedupeMemberProfiles(
  Iterable<GroupMemberProfile> profiles,
) {
  final seen = <String>{};
  final result = <GroupMemberProfile>[];
  for (final profile in profiles) {
    if (profile.deviceId.trim().isEmpty || !seen.add(profile.deviceId)) {
      continue;
    }
    result.add(profile);
  }
  return result;
}

List<String> _normalizedGroupRoleIds({
  required String ownerDeviceId,
  required Iterable<String> memberDeviceIds,
  required Iterable<String> removedDeviceIds,
  required Iterable<String> roleDeviceIds,
  Iterable<String> excludedRoleDeviceIds = const <String>[],
}) {
  final removed = _dedupeIds(removedDeviceIds).toSet();
  final activeMembers = _dedupeIds([
    ownerDeviceId,
    ...memberDeviceIds,
  ]).where((deviceId) => !removed.contains(deviceId)).toSet();
  final excluded = _dedupeIds(excludedRoleDeviceIds).toSet();
  return _dedupeIds(roleDeviceIds)
      .where(
        (deviceId) =>
            deviceId != ownerDeviceId &&
            activeMembers.contains(deviceId) &&
            !removed.contains(deviceId) &&
            !excluded.contains(deviceId),
      )
      .toList(growable: false);
}

List<String> _dedupeIds(Iterable<String> ids) {
  final seen = <String>{};
  final result = <String>[];
  for (final id in ids) {
    final trimmed = id.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) {
      continue;
    }
    result.add(trimmed);
  }
  return result;
}

class ConversationRecord {
  ConversationRecord({
    required this.id,
    required this.kind,
    required this.peerDeviceId,
    required this.messages,
    this.lastReadAt,
  });

  final String id;
  final ConversationKind kind;
  final String peerDeviceId;
  final List<ChatMessage> messages;
  final DateTime? lastReadAt;

  ConversationRecord copyWith({
    List<ChatMessage>? messages,
    DateTime? lastReadAt,
  }) {
    return ConversationRecord(
      id: id,
      kind: kind,
      peerDeviceId: peerDeviceId,
      messages: messages ?? this.messages,
      lastReadAt: lastReadAt ?? this.lastReadAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kind': kind.name,
      'peerDeviceId': peerDeviceId,
      'messages': messages.map((message) => message.toJson()).toList(),
      'lastReadAt': lastReadAt?.toIso8601String(),
    };
  }

  factory ConversationRecord.fromJson(Map<String, dynamic> json) {
    final messages = (json['messages'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();
    final lastReadAtValue = json['lastReadAt'] as String?;
    final inferredLastReadAt = lastReadAtValue == null
        ? (messages.isEmpty
              ? null
              : messages
                    .map((message) => message.createdAt)
                    .reduce(
                      (left, right) => left.isAfter(right) ? left : right,
                    ))
        : DateTime.tryParse(lastReadAtValue);
    return ConversationRecord(
      id: json['id'] as String,
      kind: ConversationKind.values.byName(json['kind'] as String),
      peerDeviceId: json['peerDeviceId'] as String,
      messages: messages,
      lastReadAt: inferredLastReadAt,
    );
  }
}

class RelayEnvelope {
  RelayEnvelope({
    this.protocolVersion = 2,
    required this.kind,
    required this.messageId,
    required this.conversationId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.createdAt,
    this.nonceBase64,
    this.ciphertextBase64,
    this.macBase64,
    this.acknowledgedMessageId,
    this.payloadBase64,
  });

  final int protocolVersion;
  final String kind;
  final String messageId;
  final String conversationId;
  final String senderAccountId;
  final String senderDeviceId;
  final String recipientDeviceId;
  final DateTime createdAt;
  final String? nonceBase64;
  final String? ciphertextBase64;
  final String? macBase64;
  final String? acknowledgedMessageId;
  final String? payloadBase64;

  /// Stable v2 AEAD associated-data representation. Map insertion order is
  /// intentional and covered by crypto tests; null acknowledgement targets
  /// remain present so both peers authenticate the same field set.
  List<int> authenticatedHeaderBytes() => utf8.encode(
    jsonEncode(<String, dynamic>{
      'protocolVersion': protocolVersion,
      'kind': kind,
      'messageId': messageId,
      'conversationId': conversationId,
      'senderAccountId': senderAccountId,
      'senderDeviceId': senderDeviceId,
      'recipientDeviceId': recipientDeviceId,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'acknowledgedMessageId': acknowledgedMessageId,
    }),
  );

  Map<String, dynamic> toJson() {
    return {
      'protocolVersion': protocolVersion,
      'kind': kind,
      'messageId': messageId,
      'conversationId': conversationId,
      'senderAccountId': senderAccountId,
      'senderDeviceId': senderDeviceId,
      'recipientDeviceId': recipientDeviceId,
      'createdAt': createdAt.toIso8601String(),
      'nonceBase64': nonceBase64,
      'ciphertextBase64': ciphertextBase64,
      'macBase64': macBase64,
      'acknowledgedMessageId': acknowledgedMessageId,
      'payloadBase64': payloadBase64,
    };
  }

  factory RelayEnvelope.fromJson(Map<String, dynamic> json) {
    return RelayEnvelope(
      protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
      kind: json['kind'] as String,
      messageId: json['messageId'] as String,
      conversationId: json['conversationId'] as String,
      senderAccountId: json['senderAccountId'] as String,
      senderDeviceId: json['senderDeviceId'] as String,
      recipientDeviceId: json['recipientDeviceId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      nonceBase64: json['nonceBase64'] as String?,
      ciphertextBase64: json['ciphertextBase64'] as String?,
      macBase64: json['macBase64'] as String?,
      acknowledgedMessageId: json['acknowledgedMessageId'] as String?,
      payloadBase64: json['payloadBase64'] as String?,
    );
  }
}

class ChunkHash {
  const ChunkHash({required this.index, required this.hashBase64});

  final int index;
  final String hashBase64;

  Map<String, dynamic> toJson() {
    return {'index': index, 'hashBase64': hashBase64};
  }

  factory ChunkHash.fromJson(Map<String, dynamic> json) {
    return ChunkHash(
      index: json['index'] as int,
      hashBase64: json['hashBase64'] as String,
    );
  }
}

class AttachmentDescriptor {
  const AttachmentDescriptor({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.chunkSize,
    required this.chunkHashes,
    required this.encryptionKeyBase64,
    required this.createdAt,
    this.chunkCount = 0,
    this.fileHashBase64 = '',
    this.protocolVersion = 2,
    this.noncePrefixBase64 = '',
    this.presentation = AttachmentPresentation.media,
    this.thumbnailBase64,
  });

  final String id;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int chunkSize;
  final List<ChunkHash> chunkHashes;
  final String encryptionKeyBase64;
  final DateTime createdAt;
  final int chunkCount;
  final String fileHashBase64;

  /// Attachment wire protocol. Missing values decode as v1 so the startup
  /// migration can safely cancel incomplete legacy transfers.
  final int protocolVersion;
  final String noncePrefixBase64;
  final AttachmentPresentation presentation;
  final String? thumbnailBase64;

  int get effectiveChunkCount =>
      chunkCount > 0 ? chunkCount : chunkHashes.length;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fileName': fileName,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'chunkSize': chunkSize,
      'chunkHashes': chunkHashes.map((hash) => hash.toJson()).toList(),
      'chunkCount': effectiveChunkCount,
      if (fileHashBase64.isNotEmpty) 'fileHashBase64': fileHashBase64,
      'protocolVersion': protocolVersion,
      if (noncePrefixBase64.isNotEmpty) 'noncePrefixBase64': noncePrefixBase64,
      'presentation': presentation.name,
      if (thumbnailBase64 != null) 'thumbnailBase64': thumbnailBase64,
      'encryptionKeyBase64': encryptionKeyBase64,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory AttachmentDescriptor.fromJson(Map<String, dynamic> json) {
    return AttachmentDescriptor(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      mimeType: json['mimeType'] as String,
      sizeBytes: json['sizeBytes'] as int,
      chunkSize: json['chunkSize'] as int,
      chunkHashes: (json['chunkHashes'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(ChunkHash.fromJson)
          .toList(),
      chunkCount: (json['chunkCount'] as num?)?.toInt() ?? 0,
      fileHashBase64: json['fileHashBase64'] as String? ?? '',
      protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
      noncePrefixBase64: json['noncePrefixBase64'] as String? ?? '',
      presentation:
          AttachmentPresentation.values
              .where((value) => value.name == json['presentation'])
              .firstOrNull ??
          AttachmentPresentation.media,
      thumbnailBase64: json['thumbnailBase64'] as String?,
      encryptionKeyBase64: json['encryptionKeyBase64'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

enum AttachmentPresentation { media, file }

/// Persistent reference metadata for one message attachment backed by the
/// content-addressed managed cache. The bytes may be absent after eviction;
/// the immutable attachment manifest remains in message history so the user
/// can explicitly request them again.
class AttachmentCacheReference {
  const AttachmentCacheReference({
    required this.attachmentId,
    required this.fileHashBase64,
    required this.lastAccessedAt,
    this.keepOffline = false,
    this.explicitlySaved = false,
  });

  final String attachmentId;
  final String fileHashBase64;
  final DateTime lastAccessedAt;
  final bool keepOffline;
  final bool explicitlySaved;

  AttachmentCacheReference copyWith({
    DateTime? lastAccessedAt,
    bool? keepOffline,
    bool? explicitlySaved,
  }) => AttachmentCacheReference(
    attachmentId: attachmentId,
    fileHashBase64: fileHashBase64,
    lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    keepOffline: keepOffline ?? this.keepOffline,
    explicitlySaved: explicitlySaved ?? this.explicitlySaved,
  );

  Map<String, dynamic> toJson() => {
    'attachmentId': attachmentId,
    'fileHashBase64': fileHashBase64,
    'lastAccessedAt': lastAccessedAt.toUtc().toIso8601String(),
    'keepOffline': keepOffline,
    'explicitlySaved': explicitlySaved,
  };

  factory AttachmentCacheReference.fromJson(Map<String, dynamic> json) =>
      AttachmentCacheReference(
        attachmentId: json['attachmentId'] as String,
        fileHashBase64: json['fileHashBase64'] as String? ?? '',
        lastAccessedAt:
            DateTime.tryParse(
              json['lastAccessedAt'] as String? ?? '',
            )?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        keepOffline: json['keepOffline'] as bool? ?? false,
        explicitlySaved: json['explicitlySaved'] as bool? ?? false,
      );
}

class AttachmentChunk {
  const AttachmentChunk({
    required this.attachmentId,
    required this.index,
    required this.ciphertextBase64,
    required this.hashBase64,
  });

  final String attachmentId;
  final int index;
  final String ciphertextBase64;
  final String hashBase64;

  Map<String, dynamic> toJson() {
    return {
      'attachmentId': attachmentId,
      'index': index,
      'ciphertextBase64': ciphertextBase64,
      'hashBase64': hashBase64,
    };
  }

  factory AttachmentChunk.fromJson(Map<String, dynamic> json) {
    return AttachmentChunk(
      attachmentId: json['attachmentId'] as String,
      index: json['index'] as int,
      ciphertextBase64: json['ciphertextBase64'] as String,
      hashBase64: json['hashBase64'] as String,
    );
  }
}

enum TransferState {
  preparing,
  queued,
  pending,
  transferring,
  reconnecting,
  paused,
  completed,
  failed,
  canceled,
  waitingForLan,
  waitingForStorage,
}

/// User-facing transfer phases are deliberately independent from message
/// delivery state. A sent offer is not the same thing as a delivered file.
enum TransferPhase {
  preparing,
  queued,
  awaitingApproval,
  waitingForPeer,
  transferring,
  reconnecting,
  paused,
  verifying,
  completed,
  failed,
  canceled,
  unavailable,
}

extension TransferPhaseX on TransferPhase {
  bool get isActive => switch (this) {
    TransferPhase.preparing ||
    TransferPhase.queued ||
    TransferPhase.waitingForPeer ||
    TransferPhase.transferring ||
    TransferPhase.reconnecting ||
    TransferPhase.verifying => true,
    _ => false,
  };
}

class TransferSnapshot {
  const TransferSnapshot({
    required this.id,
    required this.phase,
    required this.direction,
    required this.bytesTransferred,
    required this.totalBytes,
    this.bytesPerSecond,
    this.eta,
    this.queuePriority = 0,
    this.transport,
    this.path,
    this.routeLabel,
    this.pausedByMe = false,
    this.pausedByPeer = false,
    this.retryAt,
    this.error,
  });

  final String id;
  final TransferPhase phase;
  final TransferDirection direction;
  final int bytesTransferred;
  final int totalBytes;
  final double? bytesPerSecond;
  final Duration? eta;
  final int queuePriority;
  final TransportKind? transport;
  final TransportPathKind? path;
  final String? routeLabel;
  final bool pausedByMe;
  final bool pausedByPeer;
  final DateTime? retryAt;
  final String? error;

  double get progress =>
      totalBytes <= 0 ? 0 : (bytesTransferred / totalBytes).clamp(0.0, 1.0);
}

enum TransferDirection { outbound, inbound }

enum TransferSourceKind { privateSpool, originalPath, partialFile }

class TransferSession {
  const TransferSession({
    required this.id,
    required this.attachment,
    required this.peerDeviceIds,
    required this.state,
    required this.completedChunks,
    required this.createdAt,
    required this.updatedAt,
    this.direction = TransferDirection.outbound,
    this.messageId = '',
    this.relativePath = '',
    this.sourceKind = TransferSourceKind.privateSpool,
    this.sourcePath,
    this.sourceSizeBytes,
    this.sourceModifiedAt,
    this.requiresLan = false,
    this.lanOnly = false,
    this.allowIrohRelay = false,
    this.bytesTransferred = 0,
    this.pausedByMe = false,
    this.pausedByPeer = false,
    this.lastError,
    this.storageReserveBlocked = false,
  });

  final String id;
  final AttachmentDescriptor attachment;
  final List<String> peerDeviceIds;
  final TransferState state;
  final List<int> completedChunks;
  final DateTime createdAt;
  final DateTime updatedAt;
  final TransferDirection direction;
  final String messageId;
  final String relativePath;
  final TransferSourceKind sourceKind;
  final String? sourcePath;
  final int? sourceSizeBytes;
  final DateTime? sourceModifiedAt;
  final bool requiresLan;
  final bool lanOnly;
  final bool allowIrohRelay;
  final int bytesTransferred;
  final bool pausedByMe;
  final bool pausedByPeer;
  final String? lastError;
  final bool storageReserveBlocked;

  TransferSession copyWith({
    TransferState? state,
    List<int>? completedChunks,
    DateTime? updatedAt,
    String? relativePath,
    bool? allowIrohRelay,
    int? bytesTransferred,
    bool? pausedByMe,
    bool? pausedByPeer,
    String? lastError,
    bool clearLastError = false,
    bool? storageReserveBlocked,
  }) {
    return TransferSession(
      id: id,
      attachment: attachment,
      peerDeviceIds: peerDeviceIds,
      state: state ?? this.state,
      completedChunks: completedChunks ?? this.completedChunks,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      direction: direction,
      messageId: messageId,
      relativePath: relativePath ?? this.relativePath,
      sourceKind: sourceKind,
      sourcePath: sourcePath,
      sourceSizeBytes: sourceSizeBytes,
      sourceModifiedAt: sourceModifiedAt,
      requiresLan: requiresLan,
      lanOnly: lanOnly,
      allowIrohRelay: allowIrohRelay ?? this.allowIrohRelay,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      pausedByMe: pausedByMe ?? this.pausedByMe,
      pausedByPeer: pausedByPeer ?? this.pausedByPeer,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      storageReserveBlocked: clearLastError
          ? false
          : (storageReserveBlocked ?? this.storageReserveBlocked),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'attachment': attachment.toJson(),
      'peerDeviceIds': peerDeviceIds,
      'state': state.name,
      'completedRanges': _encodeChunkRanges(completedChunks),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'direction': direction.name,
      'messageId': messageId,
      'relativePath': relativePath,
      'sourceKind': sourceKind.name,
      if (sourcePath != null) 'sourcePath': sourcePath,
      if (sourceSizeBytes != null) 'sourceSizeBytes': sourceSizeBytes,
      if (sourceModifiedAt != null)
        'sourceModifiedAt': sourceModifiedAt!.toUtc().toIso8601String(),
      'requiresLan': requiresLan,
      if (lanOnly) 'lanOnly': true,
      'allowIrohRelay': allowIrohRelay,
      'bytesTransferred': bytesTransferred,
      'pausedByMe': pausedByMe,
      'pausedByPeer': pausedByPeer,
      if (lastError != null) 'lastError': lastError,
      if (storageReserveBlocked) 'storageReserveBlocked': true,
    };
  }

  factory TransferSession.fromJson(Map<String, dynamic> json) {
    return TransferSession(
      id: json['id'] as String,
      attachment: AttachmentDescriptor.fromJson(
        json['attachment'] as Map<String, dynamic>,
      ),
      peerDeviceIds: (json['peerDeviceIds'] as List<dynamic>? ?? const [])
          .cast<String>(),
      state: TransferState.values.byName(json['state'] as String),
      completedChunks: json['completedRanges'] is List<dynamic>
          ? _decodeChunkRanges(json['completedRanges'] as List<dynamic>)
          : (json['completedChunks'] as List<dynamic>? ?? const [])
                .whereType<num>()
                .map((value) => value.toInt())
                .toList(growable: false),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      direction: TransferDirection.values.byName(
        json['direction'] as String? ?? TransferDirection.outbound.name,
      ),
      messageId: json['messageId'] as String? ?? '',
      relativePath: json['relativePath'] as String? ?? '',
      sourceKind: TransferSourceKind.values.byName(
        json['sourceKind'] as String? ?? TransferSourceKind.privateSpool.name,
      ),
      sourcePath: json['sourcePath'] as String?,
      sourceSizeBytes: (json['sourceSizeBytes'] as num?)?.toInt(),
      sourceModifiedAt: DateTime.tryParse(
        json['sourceModifiedAt'] as String? ?? '',
      )?.toUtc(),
      requiresLan: json['requiresLan'] as bool? ?? false,
      lanOnly: json['lanOnly'] as bool? ?? false,
      allowIrohRelay: json['allowIrohRelay'] as bool? ?? false,
      bytesTransferred: (json['bytesTransferred'] as num?)?.toInt() ?? 0,
      pausedByMe: json['pausedByMe'] as bool? ?? false,
      pausedByPeer: json['pausedByPeer'] as bool? ?? false,
      lastError: json['lastError'] as String?,
      storageReserveBlocked: json['storageReserveBlocked'] as bool? ?? false,
    );
  }
}

List<List<int>> _encodeChunkRanges(List<int> chunks) {
  if (chunks.isEmpty) return const <List<int>>[];
  final sorted = chunks.toSet().toList()..sort();
  final ranges = <List<int>>[];
  var start = sorted.first;
  var end = start;
  for (final value in sorted.skip(1)) {
    if (value == end + 1) {
      end = value;
      continue;
    }
    ranges.add(<int>[start, end]);
    start = value;
    end = value;
  }
  ranges.add(<int>[start, end]);
  return ranges;
}

List<int> _decodeChunkRanges(List<dynamic> raw) {
  final values = <int>[];
  for (final item in raw) {
    if (item is! List<dynamic> || item.length != 2) continue;
    final start = (item[0] as num?)?.toInt();
    final end = (item[1] as num?)?.toInt();
    if (start == null || end == null || start < 0 || end < start) continue;
    if (end - start > 8192) {
      throw const FormatException('Transfer chunk range is too large.');
    }
    for (var value = start; value <= end; value++) {
      values.add(value);
    }
  }
  return values;
}

class PendingGroupMembershipDelivery {
  const PendingGroupMembershipDelivery({
    required this.groupId,
    required this.targetDeviceId,
    required this.membershipVersion,
    required this.originalMessageId,
    required this.reason,
    required this.lastAttemptedAt,
    required this.attempts,
  });

  /// Group whose membership snapshot is still pending delivery.
  final String groupId;

  /// Recipient device that hasn't acknowledged the latest membership update.
  /// `(groupId, targetDeviceId)` is the natural key for the queue.
  final String targetDeviceId;

  /// `GroupRecord.membershipVersion` of the snapshot being delivered. A
  /// newer pending version supersedes any older queued entry for the same
  /// target — no need to keep retrying a stale state once a fresher one
  /// has been computed.
  final int membershipVersion;

  /// `messageId` of the original `group_membership` envelope. Used to
  /// correlate an inbound `group_membership_ack` with the queued entry.
  final String originalMessageId;

  /// Wire reason of the original envelope (`create`, `add_members`, etc.).
  /// Captured for diagnostics; not used for delivery decisions.
  final String reason;

  /// Last time delivery was attempted. Drives the retry backoff window.
  final DateTime lastAttemptedAt;

  /// Number of completed retry passes. Capped at a sane upper bound by the
  /// retry loop to avoid burning relay quota on a permanently unreachable
  /// peer.
  final int attempts;

  PendingGroupMembershipDelivery copyWith({
    int? membershipVersion,
    String? originalMessageId,
    String? reason,
    DateTime? lastAttemptedAt,
    int? attempts,
  }) {
    return PendingGroupMembershipDelivery(
      groupId: groupId,
      targetDeviceId: targetDeviceId,
      membershipVersion: membershipVersion ?? this.membershipVersion,
      originalMessageId: originalMessageId ?? this.originalMessageId,
      reason: reason ?? this.reason,
      lastAttemptedAt: lastAttemptedAt ?? this.lastAttemptedAt,
      attempts: attempts ?? this.attempts,
    );
  }

  Map<String, dynamic> toJson() => {
    'groupId': groupId,
    'targetDeviceId': targetDeviceId,
    'membershipVersion': membershipVersion,
    'originalMessageId': originalMessageId,
    'reason': reason,
    'lastAttemptedAt': lastAttemptedAt.toIso8601String(),
    'attempts': attempts,
  };

  factory PendingGroupMembershipDelivery.fromJson(Map<String, dynamic> json) {
    return PendingGroupMembershipDelivery(
      groupId: json['groupId'] as String,
      targetDeviceId: json['targetDeviceId'] as String,
      membershipVersion: (json['membershipVersion'] as num?)?.toInt() ?? 1,
      originalMessageId: json['originalMessageId'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      lastAttemptedAt:
          DateTime.tryParse(json['lastAttemptedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    );
  }
}

enum PendingAckKind {
  // Pre-nightly.12: receipts that the receiver implicitly acks by their
  // existence. Cleared from the queue once the first send completes.
  delivered,
  read,
  // nightly.12 additions: at-least-once delivery of CONTROL envelopes.
  // These don't wait for a peer ACK; they piggy-back the same retry
  // queue because we want the same persistence + backoff + drain-on-poll
  // behaviour as `delivered`/`read`. The envelope payload itself is
  // carried via `PendingAckDelivery.envelopeJson` so the retry loop can
  // re-push without re-encrypting.
  messageDelete,
  messageEdit,
  attachmentCancel,
  debugProbe,
  debugProbeAck,
  debugTwoWayMessage,
  debugTwoWayReply;

  String get wireValue => name;

  /// nightly.12: kinds that carry their full encrypted envelope in
  /// `PendingAckDelivery.envelopeJson` (rather than being rebuilt from
  /// scratch by the retry loop). The retry loop forwards the stored
  /// envelope verbatim instead of calling the per-kind builder.
  bool get carriesEnvelope =>
      this != PendingAckKind.delivered && this != PendingAckKind.read;

  static PendingAckKind? tryParse(String? value) {
    if (value == null) return null;
    for (final kind in PendingAckKind.values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// An outgoing ack (delivery or read receipt) that hasn't been confirmed
/// landed on its target yet. Unlike [PendingGroupMembershipDelivery],
/// there's no second round-trip to confirm success; instead, the entry is
/// cleared as soon as the first delivery attempt completes without
/// throwing. Entries persist so transient route failures can be retried
/// across restarts.
class PendingAckDelivery {
  const PendingAckDelivery({
    required this.targetDeviceId,
    required this.acknowledgedMessageId,
    required this.conversationId,
    required this.kind,
    required this.lastAttemptedAt,
    required this.attempts,
    this.envelopeJson,
    this.requiresPeerUpdate = false,
  });

  final String targetDeviceId;
  final String acknowledgedMessageId;
  final String conversationId;
  final PendingAckKind kind;
  final DateTime lastAttemptedAt;
  final int attempts;

  /// nightly.12: for `kind.carriesEnvelope == true` entries, the full
  /// encrypted `RelayEnvelope` JSON ready to re-push verbatim. Null for
  /// pre-nightly.12 `delivered`/`read` entries which the retry loop
  /// rebuilds via the per-kind builder.
  final Map<String, dynamic>? envelopeJson;
  final bool requiresPeerUpdate;

  PendingAckDelivery copyWith({
    DateTime? lastAttemptedAt,
    int? attempts,
    bool? requiresPeerUpdate,
  }) {
    return PendingAckDelivery(
      targetDeviceId: targetDeviceId,
      acknowledgedMessageId: acknowledgedMessageId,
      conversationId: conversationId,
      kind: kind,
      lastAttemptedAt: lastAttemptedAt ?? this.lastAttemptedAt,
      attempts: attempts ?? this.attempts,
      envelopeJson: envelopeJson,
      requiresPeerUpdate: requiresPeerUpdate ?? this.requiresPeerUpdate,
    );
  }

  Map<String, dynamic> toJson() => {
    'targetDeviceId': targetDeviceId,
    'acknowledgedMessageId': acknowledgedMessageId,
    'conversationId': conversationId,
    'kind': kind.wireValue,
    'lastAttemptedAt': lastAttemptedAt.toIso8601String(),
    'attempts': attempts,
    if (envelopeJson != null) 'envelopeJson': envelopeJson,
    if (requiresPeerUpdate) 'requiresPeerUpdate': true,
  };

  factory PendingAckDelivery.fromJson(Map<String, dynamic> json) {
    return PendingAckDelivery(
      targetDeviceId: json['targetDeviceId'] as String,
      acknowledgedMessageId: json['acknowledgedMessageId'] as String,
      conversationId: json['conversationId'] as String? ?? '',
      kind:
          PendingAckKind.tryParse(json['kind'] as String?) ??
          PendingAckKind.delivered,
      lastAttemptedAt:
          DateTime.tryParse(json['lastAttemptedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      envelopeJson: json['envelopeJson'] as Map<String, dynamic>?,
      requiresPeerUpdate: json['requiresPeerUpdate'] as bool? ?? false,
    );
  }
}

/// An inbound envelope held in quarantine because the sender is a contact in
/// `pendingVerification` state. Drained into the matching conversation when
/// the user confirms the contact replacement; deleted on reject.
class HeldEnvelope {
  const HeldEnvelope({
    required this.senderDeviceId,
    required this.conversationId,
    required this.envelopeJson,
    required this.receivedAt,
  });

  final String senderDeviceId;
  final String conversationId;
  final String envelopeJson;
  final DateTime receivedAt;

  Map<String, dynamic> toJson() => {
    'senderDeviceId': senderDeviceId,
    'conversationId': conversationId,
    'envelopeJson': envelopeJson,
    'receivedAt': receivedAt.toIso8601String(),
  };

  factory HeldEnvelope.fromJson(Map<String, dynamic> json) => HeldEnvelope(
    senderDeviceId: json['senderDeviceId'] as String,
    conversationId: json['conversationId'] as String? ?? '',
    envelopeJson: json['envelopeJson'] as String,
    receivedAt:
        DateTime.tryParse(json['receivedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// Unauthenticated bootstrap request received from an unknown device. The
/// invite is deliberately quarantined instead of becoming a trusted contact;
/// only an explicit approve action may pass it to the normal trust flow.
class PendingContactRequest {
  const PendingContactRequest({
    required this.id,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.invitePayload,
    required this.receivedAt,
  });

  final String id;
  final String senderAccountId;
  final String senderDeviceId;
  final String invitePayload;
  final DateTime receivedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderAccountId': senderAccountId,
    'senderDeviceId': senderDeviceId,
    'invitePayload': invitePayload,
    'receivedAt': receivedAt.toUtc().toIso8601String(),
  };

  factory PendingContactRequest.fromJson(Map<String, dynamic> json) {
    return PendingContactRequest(
      id: json['id'] as String,
      senderAccountId: json['senderAccountId'] as String,
      senderDeviceId: json['senderDeviceId'] as String,
      invitePayload: json['invitePayload'] as String,
      receivedAt:
          DateTime.tryParse(json['receivedAt'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// A user-imported relay list, fetched from an arbitrary URL. Unlike the
/// signed default-relay manifest these are NOT marked as defaults in the UI;
/// the UI still shows them by host:port. Imported endpoints can be removed
/// as a group via [`removeCustomRelaySource`].
class CustomRelaySource {
  const CustomRelaySource({
    required this.id,
    required this.url,
    required this.publicKeyBase64,
    required this.lastVersion,
    required this.lastFetchedAt,
    required this.routeKeys,
  });

  final String id;
  final String url;

  /// Operator's Ed25519 verification key when the import was signed. When
  /// null, the import was unsigned (untrusted); the pre-flight probe still
  /// gates use but no cryptographic trust applies to the list itself.
  final String? publicKeyBase64;

  final int? lastVersion;
  final DateTime lastFetchedAt;

  /// `routeKey`s contributed by this source. Used by remove + refresh to
  /// scope changes.
  final Set<String> routeKeys;

  bool get isSigned => publicKeyBase64 != null;

  CustomRelaySource copyWith({
    int? lastVersion,
    DateTime? lastFetchedAt,
    Set<String>? routeKeys,
  }) {
    return CustomRelaySource(
      id: id,
      url: url,
      publicKeyBase64: publicKeyBase64,
      lastVersion: lastVersion ?? this.lastVersion,
      lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
      routeKeys: routeKeys ?? this.routeKeys,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    if (publicKeyBase64 != null) 'publicKeyBase64': publicKeyBase64,
    if (lastVersion != null) 'lastVersion': lastVersion,
    'lastFetchedAt': lastFetchedAt.toIso8601String(),
    'routeKeys': routeKeys.toList(),
  };

  factory CustomRelaySource.fromJson(Map<String, dynamic> json) =>
      CustomRelaySource(
        id: json['id'] as String,
        url: json['url'] as String,
        publicKeyBase64: json['publicKeyBase64'] as String?,
        lastVersion: (json['lastVersion'] as num?)?.toInt(),
        lastFetchedAt:
            DateTime.tryParse(json['lastFetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        routeKeys: <String>{
          for (final value in (json['routeKeys'] as List<dynamic>? ?? const []))
            if (value is String) value,
        },
      );
}

class VaultSnapshot {
  VaultSnapshot({
    required this.identity,
    required this.contacts,
    required this.reachabilityRecords,
    required this.conversations,
    required this.groups,
    required this.seenEnvelopeIds,
    this.relayHealthScores = const <String, RelayHealthScore>{},
    this.defaultRelayDefaultsVersion = 0,
    this.pendingGroupMembershipDeliveries =
        const <PendingGroupMembershipDelivery>[],
    this.pinnedRelayIdentityKeys = const <String, String>{},
    this.pendingAckDeliveries = const <PendingAckDelivery>[],
    this.defaultRelayRouteKeys = const <String>{},
    this.defaultRelayHosts = const <String>{},
    this.defaultRelaysLastFetchedAt,
    this.customRelaySources = const <CustomRelaySource>[],
    this.heldUnverifiedEnvelopes = const <HeldEnvelope>[],
    this.pendingContactRequests = const <PendingContactRequest>[],
    this.transferSessions = const <TransferSession>[],
    this.attachmentCacheReferences = const <AttachmentCacheReference>[],
  });

  final IdentityRecord? identity;
  final List<ContactRecord> contacts;
  final List<ContactReachabilityRecord> reachabilityRecords;
  final List<ConversationRecord> conversations;
  final List<GroupRecord> groups;
  final List<String> seenEnvelopeIds;

  /// Keyed by [relayHealthEndpointKey]. Legacy vaults load with an empty
  /// map; the controller refills the map as new relay attempts complete.
  final Map<String, RelayHealthScore> relayHealthScores;

  /// Tracks the `version` of the most recently ingested signed default
  /// relay manifest. The controller skips re-ingestion when the bundled
  /// asset's version is `<=` this value. Legacy vaults load as 0.
  final int defaultRelayDefaultsVersion;

  /// Membership envelopes that left the sender but haven't been
  /// acknowledged by the targeted recipient yet. The controller's retry
  /// loop drains this queue with exponential-ish backoff; entries are
  /// cleared when an inbound `group_membership_ack` from the matching
  /// target arrives. Persisted so retries survive process restarts.
  final List<PendingGroupMembershipDelivery> pendingGroupMembershipDeliveries;

  /// First-use-pinned Ed25519 identity keys per `relay_id`. Once a relay
  /// has been seen advertising a given pubkey, subsequent responses that
  /// don't verify against the pin are flagged as mismatches. The user
  /// (or the operator) decides whether to rotate via an explicit action.
  final Map<String, String> pinnedRelayIdentityKeys;

  /// Outgoing delivery/read receipts that haven't successfully landed on
  /// their target yet. Drained by the controller's periodic retry loop
  /// with backoff; persisted so retries survive process restarts.
  final List<PendingAckDelivery> pendingAckDeliveries;

  /// `PeerEndpoint.routeKey` values for relays that were ingested from
  /// the signed default-relay manifest. The UI shows these as
  /// "default relay N" instead of host:port so users aren't pinned to
  /// operator addresses that may rotate. Manually-added relays are not
  /// included and display normally.
  final Set<String> defaultRelayRouteKeys;

  /// `host:port` strings for default-relay endpoints. Any derived route
  /// sharing one of these host:port pairs (regardless of protocol) is
  /// rendered as "default relay N" so multi-protocol fan-out (TCP+UDP+HTTP)
  /// collapses to a single user-facing label per operator address.
  final Set<String> defaultRelayHosts;

  /// Wall-clock time of the most recent successful default-relays fetch
  /// from the GitHub `main`-branch raw URL. Null when the user has never
  /// tapped the "Update default relays" button (or when only the bundled
  /// asset has been ingested).
  final DateTime? defaultRelaysLastFetchedAt;

  /// Relay lists imported from arbitrary URLs (signed or unsigned).
  /// Imported endpoints are added to `identity.configuredRelays` but are
  /// NOT marked as defaults — the UI shows them with their actual
  /// `host:port` label. Removing a source removes all of its routes.
  final List<CustomRelaySource> customRelaySources;

  /// Inbound envelopes from `pendingVerification` contacts held in
  /// quarantine until the user confirms or rejects the contact
  /// replacement. Drains into the conversation on confirm; deleted on
  /// reject.
  final List<HeldEnvelope> heldUnverifiedEnvelopes;

  /// Bootstrap contact exchanges from unknown devices awaiting an explicit
  /// local approval decision.
  final List<PendingContactRequest> pendingContactRequests;
  final List<TransferSession> transferSessions;
  final List<AttachmentCacheReference> attachmentCacheReferences;

  factory VaultSnapshot.empty() {
    return VaultSnapshot(
      identity: null,
      contacts: const [],
      reachabilityRecords: const [],
      conversations: const [],
      groups: const [],
      seenEnvelopeIds: const [],
      relayHealthScores: const <String, RelayHealthScore>{},
      defaultRelayDefaultsVersion: 0,
      pendingGroupMembershipDeliveries:
          const <PendingGroupMembershipDelivery>[],
      pinnedRelayIdentityKeys: const <String, String>{},
      pendingAckDeliveries: const <PendingAckDelivery>[],
      defaultRelayRouteKeys: const <String>{},
      defaultRelayHosts: const <String>{},
      defaultRelaysLastFetchedAt: null,
      customRelaySources: const <CustomRelaySource>[],
      heldUnverifiedEnvelopes: const <HeldEnvelope>[],
      pendingContactRequests: const <PendingContactRequest>[],
      transferSessions: const <TransferSession>[],
      attachmentCacheReferences: const <AttachmentCacheReference>[],
    );
  }

  VaultSnapshot copyWith({
    IdentityRecord? identity,
    List<ContactRecord>? contacts,
    List<ContactReachabilityRecord>? reachabilityRecords,
    List<ConversationRecord>? conversations,
    List<GroupRecord>? groups,
    List<String>? seenEnvelopeIds,
    Map<String, RelayHealthScore>? relayHealthScores,
    int? defaultRelayDefaultsVersion,
    List<PendingGroupMembershipDelivery>? pendingGroupMembershipDeliveries,
    Map<String, String>? pinnedRelayIdentityKeys,
    List<PendingAckDelivery>? pendingAckDeliveries,
    Set<String>? defaultRelayRouteKeys,
    Set<String>? defaultRelayHosts,
    DateTime? defaultRelaysLastFetchedAt,
    bool clearDefaultRelaysLastFetchedAt = false,
    List<CustomRelaySource>? customRelaySources,
    List<HeldEnvelope>? heldUnverifiedEnvelopes,
    List<PendingContactRequest>? pendingContactRequests,
    List<TransferSession>? transferSessions,
    List<AttachmentCacheReference>? attachmentCacheReferences,
    bool clearIdentity = false,
  }) {
    return VaultSnapshot(
      identity: clearIdentity ? null : identity ?? this.identity,
      contacts: contacts ?? this.contacts,
      reachabilityRecords: reachabilityRecords ?? this.reachabilityRecords,
      conversations: conversations ?? this.conversations,
      groups: groups ?? this.groups,
      seenEnvelopeIds: seenEnvelopeIds ?? this.seenEnvelopeIds,
      relayHealthScores: relayHealthScores ?? this.relayHealthScores,
      defaultRelayDefaultsVersion:
          defaultRelayDefaultsVersion ?? this.defaultRelayDefaultsVersion,
      pendingGroupMembershipDeliveries:
          pendingGroupMembershipDeliveries ??
          this.pendingGroupMembershipDeliveries,
      pinnedRelayIdentityKeys:
          pinnedRelayIdentityKeys ?? this.pinnedRelayIdentityKeys,
      pendingAckDeliveries: pendingAckDeliveries ?? this.pendingAckDeliveries,
      defaultRelayRouteKeys:
          defaultRelayRouteKeys ?? this.defaultRelayRouteKeys,
      defaultRelayHosts: defaultRelayHosts ?? this.defaultRelayHosts,
      defaultRelaysLastFetchedAt: clearDefaultRelaysLastFetchedAt
          ? null
          : (defaultRelaysLastFetchedAt ?? this.defaultRelaysLastFetchedAt),
      customRelaySources: customRelaySources ?? this.customRelaySources,
      heldUnverifiedEnvelopes:
          heldUnverifiedEnvelopes ?? this.heldUnverifiedEnvelopes,
      pendingContactRequests:
          pendingContactRequests ?? this.pendingContactRequests,
      transferSessions: transferSessions ?? this.transferSessions,
      attachmentCacheReferences:
          attachmentCacheReferences ?? this.attachmentCacheReferences,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'identity': identity?.toJson(),
      'contacts': contacts.map((contact) => contact.toJson()).toList(),
      'reachabilityRecords': reachabilityRecords
          .map((record) => record.toJson())
          .toList(),
      'conversations': conversations
          .map((conversation) => conversation.toJson())
          .toList(),
      'groups': groups.map((group) => group.toJson()).toList(),
      'seenEnvelopeIds': seenEnvelopeIds,
      'relayHealthScores': relayHealthScores.map(
        (key, score) => MapEntry(key, score.toJson()),
      ),
      'defaultRelayDefaultsVersion': defaultRelayDefaultsVersion,
      'pendingGroupMembershipDeliveries': pendingGroupMembershipDeliveries
          .map((entry) => entry.toJson())
          .toList(),
      'pendingAckDeliveries': pendingAckDeliveries
          .map((entry) => entry.toJson())
          .toList(),
      'defaultRelayRouteKeys': defaultRelayRouteKeys.toList(),
      'defaultRelayHosts': defaultRelayHosts.toList(),
      if (defaultRelaysLastFetchedAt != null)
        'defaultRelaysLastFetchedAt': defaultRelaysLastFetchedAt!
            .toIso8601String(),
      'customRelaySources': customRelaySources
          .map((source) => source.toJson())
          .toList(),
      'heldUnverifiedEnvelopes': heldUnverifiedEnvelopes
          .map((entry) => entry.toJson())
          .toList(),
      'pendingContactRequests': pendingContactRequests
          .map((entry) => entry.toJson())
          .toList(),
      'transferSessions': transferSessions
          .map((entry) => entry.toJson())
          .toList(),
      'attachmentCacheReferences': attachmentCacheReferences
          .map((entry) => entry.toJson())
          .toList(),
      'pinnedRelayIdentityKeys': pinnedRelayIdentityKeys,
    };
  }

  factory VaultSnapshot.fromJson(Map<String, dynamic> json) {
    final relayHealthRaw =
        json['relayHealthScores'] as Map<String, dynamic>? ?? const {};
    final relayHealthScores = <String, RelayHealthScore>{};
    relayHealthRaw.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        relayHealthScores[key] = RelayHealthScore.fromJson(value);
      }
    });
    return VaultSnapshot(
      identity: json['identity'] == null
          ? null
          : IdentityRecord.fromJson(json['identity'] as Map<String, dynamic>),
      contacts: (json['contacts'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(ContactRecord.fromJson)
          .toList(),
      reachabilityRecords:
          (json['reachabilityRecords'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>()
              .map(ContactReachabilityRecord.fromJson)
              .toList(),
      conversations: (json['conversations'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(ConversationRecord.fromJson)
          .toList(),
      groups: (json['groups'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(GroupRecord.fromJson)
          .toList(),
      seenEnvelopeIds: (json['seenEnvelopeIds'] as List<dynamic>? ?? const [])
          .cast<String>(),
      relayHealthScores: relayHealthScores,
      defaultRelayDefaultsVersion:
          (json['defaultRelayDefaultsVersion'] as num?)?.toInt() ?? 0,
      pendingGroupMembershipDeliveries:
          (json['pendingGroupMembershipDeliveries'] as List<dynamic>? ??
                  const [])
              .cast<Map<String, dynamic>>()
              .map(PendingGroupMembershipDelivery.fromJson)
              .toList(),
      pinnedRelayIdentityKeys: <String, String>{
        for (final entry
            in (json['pinnedRelayIdentityKeys'] as Map<String, dynamic>? ??
                    const <String, dynamic>{})
                .entries)
          if (entry.value is String) entry.key: entry.value as String,
      },
      pendingAckDeliveries:
          (json['pendingAckDeliveries'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>()
              .map(PendingAckDelivery.fromJson)
              .toList(),
      defaultRelayRouteKeys: <String>{
        for (final value
            in (json['defaultRelayRouteKeys'] as List<dynamic>? ?? const []))
          if (value is String) value,
      },
      defaultRelayHosts: <String>{
        for (final value
            in (json['defaultRelayHosts'] as List<dynamic>? ?? const []))
          if (value is String) value,
      },
      defaultRelaysLastFetchedAt: DateTime.tryParse(
        json['defaultRelaysLastFetchedAt'] as String? ?? '',
      ),
      customRelaySources:
          (json['customRelaySources'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>()
              .map(CustomRelaySource.fromJson)
              .toList(),
      heldUnverifiedEnvelopes:
          (json['heldUnverifiedEnvelopes'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>()
              .map(HeldEnvelope.fromJson)
              .toList(),
      pendingContactRequests:
          (json['pendingContactRequests'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>()
              .map(PendingContactRequest.fromJson)
              .toList(),
      transferSessions: (json['transferSessions'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TransferSession.fromJson)
          .toList(),
      attachmentCacheReferences:
          (json['attachmentCacheReferences'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(AttachmentCacheReference.fromJson)
              .toList(),
    );
  }
}

class PairingCodeSnapshot {
  const PairingCodeSnapshot({
    required this.codephrase,
    required this.secondsRemaining,
  });

  final String codephrase;
  final int secondsRemaining;
}

enum ContactExchangeStatus { automatic, manualActionRequired }

class ContactAdditionResult {
  const ContactAdditionResult({
    required this.contact,
    required this.exchangeStatus,
  });

  final ContactRecord contact;
  final ContactExchangeStatus exchangeStatus;
}

class RelayCapabilityReport {
  const RelayCapabilityReport({
    required this.canUseAsRelay,
    required this.summary,
    required this.notes,
  });

  final bool canUseAsRelay;
  final String summary;
  final List<String> notes;
}

enum DebugCheckStatus {
  pass(Icons.check_circle_outline),
  warn(Icons.warning_amber_outlined),
  fail(Icons.error_outline),
  skip(Icons.block);

  const DebugCheckStatus(this.icon);

  final IconData icon;
}

class DebugCheckResult {
  const DebugCheckResult({
    required this.name,
    required this.status,
    required this.detail,
  });

  final String name;
  final DebugCheckStatus status;
  final String detail;
}

class DebugPeerReport {
  const DebugPeerReport({
    required this.alias,
    required this.deviceId,
    required this.reachability,
    required this.availablePathCount,
    required this.totalPathCount,
    required this.lanPathAvailable,
    required this.directInternetPathAvailable,
    required this.bestPathSummary,
    required this.expectedBestDeliveryState,
    required this.routeSummary,
    required this.heartbeatAttempted,
    required this.heartbeatReplyReceived,
    required this.probeAccepted,
    required this.probeAcknowledged,
    required this.twoWayAccepted,
    required this.twoWayReplyReceived,
    required this.relayProbeAccepted,
    required this.relayPathAvailable,
    required this.lastTwoWaySuccessAt,
    required this.lastHeartbeatReplyAt,
    required this.lastAvailablePathAt,
  });

  final String alias;
  final String deviceId;
  final ContactReachabilityState reachability;
  final int availablePathCount;
  final int totalPathCount;
  final bool lanPathAvailable;
  final bool directInternetPathAvailable;
  final String bestPathSummary;
  final String expectedBestDeliveryState;
  final String routeSummary;
  final bool heartbeatAttempted;
  final bool heartbeatReplyReceived;
  final bool probeAccepted;
  final bool probeAcknowledged;
  final bool twoWayAccepted;
  final bool twoWayReplyReceived;
  final bool relayProbeAccepted;
  final bool relayPathAvailable;
  final DateTime? lastTwoWaySuccessAt;
  final DateTime? lastHeartbeatReplyAt;
  final DateTime? lastAvailablePathAt;
}

class DebugRunReport {
  const DebugRunReport({
    required this.startedAt,
    required this.completedAt,
    required this.deviceCount,
    required this.results,
    this.peerReports = const [],
    this.notes = const [],
  });

  final DateTime startedAt;
  final DateTime completedAt;
  final int deviceCount;
  final List<DebugCheckResult> results;
  final List<DebugPeerReport> peerReports;
  final List<String> notes;

  int get passed =>
      results.where((result) => result.status == DebugCheckStatus.pass).length;
  int get warned =>
      results.where((result) => result.status == DebugCheckStatus.warn).length;
  int get failed =>
      results.where((result) => result.status == DebugCheckStatus.fail).length;
  int get skipped =>
      results.where((result) => result.status == DebugCheckStatus.skip).length;

  int get peersWithAvailablePaths =>
      peerReports.where((peer) => peer.availablePathCount > 0).length;
  int get peersWithProbeAck =>
      peerReports.where((peer) => peer.probeAcknowledged).length;
  int get peersWithTwoWayReply =>
      peerReports.where((peer) => peer.twoWayReplyReceived).length;
  int get peersWithRelayProbe =>
      peerReports.where((peer) => peer.relayProbeAccepted).length;
}

const int defaultRelayPort = 7667;
const Duration pairingCodeWindow = Duration(seconds: 120);

const List<String> codephraseWords = [
  'amber',
  'anchor',
  'birch',
  'cedar',
  'cipher',
  'comet',
  'ember',
  'fable',
  'harbor',
  'ivory',
  'linen',
  'lumen',
  'meadow',
  'morrow',
  'north',
  'orbit',
  'pepper',
  'quartz',
  'raven',
  'signal',
  'spruce',
  'sundial',
  'tidal',
  'vector',
  'velvet',
  'willow',
  'winter',
  'yonder',
];

// HMAC-SHA-256 with a fixed domain-separation key. The key is intentionally
// public; HMAC is used here for preimage resistance and avalanche, not as a
// shared secret. Bumping the suffix invalidates all previously-derived
// codephrases and pairing mailboxes, so old and new clients will no longer
// discover each other through codephrases.
final _codephraseHmac = Hmac(sha256, utf8.encode('conest.codephrase.v2'));

String deriveCodephrase(String seed) {
  final digest = _codephraseHmac.convert(utf8.encode(seed)).bytes;
  final segments = <String>[];
  for (var index = 0; index < 3; index++) {
    final base = index * 3;
    final wordIndex =
        ((digest[base] << 8) | digest[base + 1]) % codephraseWords.length;
    final number = (digest[base + 2] + 11).toString().padLeft(3, '0');
    segments
      ..add(codephraseWords[wordIndex])
      ..add(number);
  }
  return segments.join('-');
}

PairingCodeSnapshot currentPairingCodeSnapshotForPayload(
  String payload, {
  DateTime? now,
}) {
  final slotState = _pairingSlotState(payload, now: now);
  final secondsRemaining =
      ((slotState.slot + 1) * slotState.slotMs - slotState.elapsedMs) ~/ 1000;
  return PairingCodeSnapshot(
    codephrase: deriveCodephrase('$payload:${slotState.slot}'),
    secondsRemaining: secondsRemaining.clamp(0, pairingCodeWindow.inSeconds),
  );
}

List<String> pairingCodephrasesForPayload(
  String payload, {
  DateTime? now,
  Iterable<int> slotOffsets = const [-1, 0, 1],
}) {
  final slotState = _pairingSlotState(payload, now: now);
  final phrases = <String>[];
  final seen = <String>{};
  for (final offset in slotOffsets) {
    final slot = slotState.slot + offset;
    if (slot < 0) {
      continue;
    }
    final phrase = deriveCodephrase('$payload:$slot');
    if (seen.add(phrase)) {
      phrases.add(phrase);
    }
  }
  return phrases;
}

bool matchesDynamicCodephraseForPayload(
  String payload,
  String codephrase, {
  DateTime? now,
}) {
  final candidate = _normalizeCodephrase(codephrase);
  if (candidate.isEmpty) {
    return false;
  }
  final timestamp = (now ?? DateTime.now()).toUtc();
  final epochMs = _pairingEpochMsForPayload(payload);
  final elapsedMs = (timestamp.millisecondsSinceEpoch - epochMs)
      .clamp(0, 1 << 62)
      .toInt();
  final slot = elapsedMs ~/ pairingCodeWindow.inMilliseconds;
  for (final offset in const [-1, 0, 1]) {
    final candidateSlot = slot + offset;
    if (candidateSlot < 0) {
      continue;
    }
    if (_normalizeCodephrase(deriveCodephrase('$payload:$candidateSlot')) ==
        candidate) {
      return true;
    }
  }
  return false;
}

String pairingMailboxIdForCodephrase(String codephrase) {
  final normalized = _normalizeCodephrase(codephrase);
  if (normalized.isEmpty) {
    throw ArgumentError('Codephrase is required.');
  }
  return 'pair-$normalized';
}

int _pairingEpochMsForPayload(String payload) {
  try {
    return ContactInvite.decodePayload(payload).pairingEpochMs;
  } catch (_) {
    return 0;
  }
}

_PairingSlotState _pairingSlotState(String payload, {DateTime? now}) {
  final timestamp = (now ?? DateTime.now()).toUtc();
  final slotMs = pairingCodeWindow.inMilliseconds;
  final nowMs = timestamp.millisecondsSinceEpoch;
  final epochMs = _pairingEpochMsForPayload(payload);
  final elapsedMs = (nowMs - epochMs).clamp(0, 1 << 62).toInt();
  return _PairingSlotState(
    slot: elapsedMs ~/ slotMs,
    elapsedMs: elapsedMs,
    slotMs: slotMs,
  );
}

class _PairingSlotState {
  const _PairingSlotState({
    required this.slot,
    required this.elapsedMs,
    required this.slotMs,
  });

  final int slot;
  final int elapsedMs;
  final int slotMs;
}

String _normalizeCodephrase(String value) {
  return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

String _truncateSafetyNumber(String value) {
  final compact = value.replaceAll(' ', '');
  if (compact.length <= 12) {
    return compact;
  }
  return compact.substring(0, 12);
}
