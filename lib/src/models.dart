import 'dart:convert';

import 'package:flutter/material.dart';

enum ConversationKind { direct, group, lanLobby }

enum DeliveryState {
  pending(Icons.schedule, 'Waiting for a reachable path'),
  local(Icons.lan_outlined, 'Sent over LAN; waiting for delivery receipt'),
  relayed(
    Icons.cloud_upload_outlined,
    'Queued on a relay; waiting for delivery receipt',
  ),
  delivered(Icons.done_all, 'Delivered'),
  canceled(Icons.cancel_outlined, 'Canceled'),
  failed(Icons.error_outline, 'Failed');

  const DeliveryState(this.icon, this.label);

  final IconData icon;
  final String label;

  bool get awaitsRecipientAck => switch (this) {
    DeliveryState.pending ||
    DeliveryState.local ||
    DeliveryState.relayed => true,
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

List<PeerEndpoint> _peerEndpointsFromJsonList(
  List<dynamic> values, {
  required bool expandMissingProtocol,
}) {
  final routes = <PeerEndpoint>[];
  for (final value in values) {
    if (value is! Map<String, dynamic>) {
      continue;
    }
    final route = PeerEndpoint.fromJson(value);
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
    required this.lanAddresses,
    required this.safetyNumber,
    required this.createdAt,
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
  final List<String> lanAddresses;
  final String safetyNumber;
  final DateTime createdAt;

  String get deviceIdShort => deviceId.substring(0, 8);
  String get shortSafetyNumber => _truncateSafetyNumber(safetyNumber);
  bool get hasInternetRelay => configuredRelays.isNotEmpty;
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
    List<String>? lanAddresses,
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
      lanAddresses: lanAddresses ?? this.lanAddresses,
      safetyNumber: safetyNumber,
      createdAt: createdAt,
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
      'lanAddresses': lanAddresses,
      'safetyNumber': safetyNumber,
      'createdAt': createdAt.toIso8601String(),
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
      lanAddresses: (json['lanAddresses'] as List<dynamic>? ?? const [])
          .cast<String>(),
      safetyNumber: json['safetyNumber'] as String,
      createdAt: createdAt,
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
    };
  }

  String encodePayload() {
    return _encodeCompactPayload();
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
    return ContactInvite(
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
    );
  }

  factory ContactInvite.decodePayload(String payload) {
    final normalized = payload.trim();
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
    return ContactInvite(
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
    );
  }
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
  return PeerEndpoint(
    kind: kind,
    host: Uri.decodeComponent(value.substring(separator + 1)),
    port: port,
    protocol: protocol,
  );
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

  String get shortSafetyNumber => _truncateSafetyNumber(safetyNumber);

  ContactRecord copyWith({
    String? alias,
    String? displayName,
    String? bio,
    bool? relayCapable,
    List<PeerEndpoint>? routeHints,
  }) {
    return ContactRecord(
      accountId: accountId,
      deviceId: deviceId,
      alias: alias ?? this.alias,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      relayCapable: relayCapable ?? this.relayCapable,
      publicKeyBase64: publicKeyBase64,
      routeHints: routeHints ?? this.routeHints,
      safetyNumber: safetyNumber,
      trustedAt: trustedAt,
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
    return ContactRecord(
      accountId: json['accountId'] as String,
      deviceId: json['deviceId'] as String,
      alias: json['alias'] as String,
      displayName: json['displayName'] as String,
      bio: json['bio'] as String? ?? '',
      relayCapable: json['relayCapable'] as bool? ?? true,
      publicKeyBase64: json['publicKeyBase64'] as String,
      routeHints: routeHints,
      safetyNumber: json['safetyNumber'] as String,
      trustedAt: DateTime.parse(json['trustedAt'] as String),
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
  });

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

  String get bodyPreview => body.replaceAll('\n', ' ');
  bool get isEdited => editedAt != null;
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
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
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
    );
  }
}

class ConversationRecord {
  ConversationRecord({
    required this.id,
    required this.kind,
    required this.peerDeviceId,
    required this.messages,
  });

  final String id;
  final ConversationKind kind;
  final String peerDeviceId;
  final List<ChatMessage> messages;

  ConversationRecord copyWith({List<ChatMessage>? messages}) {
    return ConversationRecord(
      id: id,
      kind: kind,
      peerDeviceId: peerDeviceId,
      messages: messages ?? this.messages,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kind': kind.name,
      'peerDeviceId': peerDeviceId,
      'messages': messages.map((message) => message.toJson()).toList(),
    };
  }

  factory ConversationRecord.fromJson(Map<String, dynamic> json) {
    return ConversationRecord(
      id: json['id'] as String,
      kind: ConversationKind.values.byName(json['kind'] as String),
      peerDeviceId: json['peerDeviceId'] as String,
      messages: (json['messages'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList(),
    );
  }
}

class RelayEnvelope {
  RelayEnvelope({
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

  Map<String, dynamic> toJson() {
    return {
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
  });

  final String id;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int chunkSize;
  final List<ChunkHash> chunkHashes;
  final String encryptionKeyBase64;
  final DateTime createdAt;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fileName': fileName,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'chunkSize': chunkSize,
      'chunkHashes': chunkHashes.map((hash) => hash.toJson()).toList(),
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
      encryptionKeyBase64: json['encryptionKeyBase64'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
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
  pending,
  transferring,
  paused,
  completed,
  failed,
  canceled,
}

class TransferSession {
  const TransferSession({
    required this.id,
    required this.attachment,
    required this.peerDeviceIds,
    required this.state,
    required this.completedChunks,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final AttachmentDescriptor attachment;
  final List<String> peerDeviceIds;
  final TransferState state;
  final List<int> completedChunks;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'attachment': attachment.toJson(),
      'peerDeviceIds': peerDeviceIds,
      'state': state.name,
      'completedChunks': completedChunks,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
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
      completedChunks: (json['completedChunks'] as List<dynamic>? ?? const [])
          .cast<int>(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

class VaultSnapshot {
  VaultSnapshot({
    required this.identity,
    required this.contacts,
    required this.reachabilityRecords,
    required this.conversations,
    required this.seenEnvelopeIds,
  });

  final IdentityRecord? identity;
  final List<ContactRecord> contacts;
  final List<ContactReachabilityRecord> reachabilityRecords;
  final List<ConversationRecord> conversations;
  final List<String> seenEnvelopeIds;

  factory VaultSnapshot.empty() {
    return VaultSnapshot(
      identity: null,
      contacts: const [],
      reachabilityRecords: const [],
      conversations: const [],
      seenEnvelopeIds: const [],
    );
  }

  VaultSnapshot copyWith({
    IdentityRecord? identity,
    List<ContactRecord>? contacts,
    List<ContactReachabilityRecord>? reachabilityRecords,
    List<ConversationRecord>? conversations,
    List<String>? seenEnvelopeIds,
    bool clearIdentity = false,
  }) {
    return VaultSnapshot(
      identity: clearIdentity ? null : identity ?? this.identity,
      contacts: contacts ?? this.contacts,
      reachabilityRecords: reachabilityRecords ?? this.reachabilityRecords,
      conversations: conversations ?? this.conversations,
      seenEnvelopeIds: seenEnvelopeIds ?? this.seenEnvelopeIds,
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
      'seenEnvelopeIds': seenEnvelopeIds,
    };
  }

  factory VaultSnapshot.fromJson(Map<String, dynamic> json) {
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
      seenEnvelopeIds: (json['seenEnvelopeIds'] as List<dynamic>? ?? const [])
          .cast<String>(),
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

String deriveCodephrase(String seed) {
  var accumulator = 0x811C9DC5;
  for (final codeUnit in seed.codeUnits) {
    accumulator ^= codeUnit;
    accumulator = (accumulator * 16777619) & 0xFFFFFFFF;
  }
  final segments = <String>[];
  for (var index = 0; index < 3; index++) {
    final word =
        codephraseWords[(accumulator >> (index * 5)) % codephraseWords.length];
    final number = (((accumulator >> (index * 7)) & 0xFF) + 11)
        .toString()
        .padLeft(3, '0');
    segments
      ..add(word)
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
