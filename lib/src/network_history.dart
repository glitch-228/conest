/// What each network this device has been on let through: every route
/// tried there, when it last worked or failed and how (M42 follow-up). It
/// is kept within limits and forgets networks not seen for a while; the
/// connection map shows it, and route choice puts what a network blocks
/// last.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'models.dart';

/// How a route failed, as far as the error tells.
enum RouteFailureKind { dns, refused, unreachable, reset, timeout, tls, other }

/// Sorts an error (as text, as route errors are kept) into a kind.
RouteFailureKind routeFailureKindOf(String? error) {
  final text = (error ?? '').toLowerCase();
  if (text.contains('host lookup') ||
      text.contains('name resolution') ||
      text.contains('nodename')) {
    return RouteFailureKind.dns;
  }
  if (text.contains('handshake') ||
      text.contains('certificate') ||
      text.contains('tls')) {
    return RouteFailureKind.tls;
  }
  if (text.contains('refused')) return RouteFailureKind.refused;
  if (text.contains('no route') || text.contains('unreachable')) {
    return RouteFailureKind.unreachable;
  }
  if (text.contains('reset') ||
      text.contains('abort') ||
      text.contains('closed') ||
      text.contains('broken pipe')) {
    return RouteFailureKind.reset;
  }
  if (text.contains('timed out') || text.contains('timeout')) {
    return RouteFailureKind.timeout;
  }
  return RouteFailureKind.other;
}

/// One recent failure of a route. [peer] is a short digest of the contact
/// it was for; null when the failure was not for one contact (a relay or
/// account of this device's own).
class RouteFailure {
  const RouteFailure(this.at, this.kind, [this.peer]);

  final DateTime at;
  final RouteFailureKind kind;
  final String? peer;
}

class RouteOutcome {
  RouteOutcome({
    this.lastWorked,
    this.lastFailed,
    this.ok = 0,
    this.fail = 0,
    Map<RouteFailureKind, int>? failures,
    List<RouteFailure>? recent,
  }) : failures = failures ?? {},
       recent = recent ?? [];

  DateTime? lastWorked;
  DateTime? lastFailed;
  int ok;
  int fail;
  final Map<RouteFailureKind, int> failures;

  /// The latest failures, oldest first (at most [maxRecent]): what the
  /// verdict "blocked here" is judged on, over a recent window.
  final List<RouteFailure> recent;
  static const maxRecent = 24;

  /// The most recent thing that happened on this route.
  DateTime? get lastUsed => switch ((lastWorked, lastFailed)) {
    (null, final failed) => failed,
    (final worked, null) => worked,
    (final worked?, final failed?) => worked.isAfter(failed) ? worked : failed,
  };

  Map<String, Object?> toJson() => {
    if (lastWorked != null) 'w': lastWorked!.toUtc().toIso8601String(),
    if (lastFailed != null) 'f': lastFailed!.toUtc().toIso8601String(),
    'ok': ok,
    'fail': fail,
    if (failures.isNotEmpty)
      'kinds': {for (final e in failures.entries) e.key.name: e.value},
    if (recent.isNotEmpty)
      'recent': [
        for (final failure in recent)
          [
            failure.at.toUtc().millisecondsSinceEpoch,
            failure.kind.index,
            if (failure.peer != null) failure.peer,
          ],
      ],
  };

  static RouteOutcome fromJson(Map<String, dynamic> json) => RouteOutcome(
    lastWorked: DateTime.tryParse(json['w'] as String? ?? ''),
    lastFailed: DateTime.tryParse(json['f'] as String? ?? ''),
    ok: (json['ok'] as num?)?.toInt().clamp(0, 1 << 30) ?? 0,
    fail: (json['fail'] as num?)?.toInt().clamp(0, 1 << 30) ?? 0,
    failures: {
      for (final MapEntry(:key, :value)
          in (json['kinds'] as Map<String, dynamic>? ?? {}).entries)
        for (final kind in RouteFailureKind.values)
          if (kind.name == key && value is num) kind: value.toInt(),
    },
    recent: [
      for (final entry in (json['recent'] as List? ?? const []).take(maxRecent))
        if (entry is List &&
            entry.length >= 2 &&
            entry[0] is num &&
            entry[1] is num &&
            (entry[1] as num).toInt() >= 0 &&
            (entry[1] as num).toInt() < RouteFailureKind.values.length)
          RouteFailure(
            DateTime.fromMillisecondsSinceEpoch(
              (entry[0] as num).toInt(),
              isUtc: true,
            ),
            RouteFailureKind.values[(entry[1] as num).toInt()],
            entry.length > 2 && entry[2] is String
                ? (entry[2] as String).characters(16)
                : null,
          ),
    ],
  );
}

class NetworkRecord {
  NetworkRecord({
    required this.id,
    required this.label,
    required this.kind,
    required this.vpn,
    required this.cost,
    required this.firstSeen,
    required this.lastSeen,
    this.seenCount = 1,
    Map<String, RouteOutcome>? routes,
  }) : routes = routes ?? {};

  /// A digest of what tells this network apart (never shown).
  final String id;

  /// "Wi-Fi 192.168.3.x", "Mobile", …
  String label;

  /// wifi, ethernet, mobile, vpn, bluetooth or other.
  String kind;
  bool vpn;
  NetworkCostClass cost;
  final DateTime firstSeen;
  DateTime lastSeen;
  int seenCount;

  /// Route ("lan", "relay:host:port", "iroh", "nostr", …) → what came of it.
  final Map<String, RouteOutcome> routes;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'kind': kind,
    'vpn': vpn,
    'cost': cost.name,
    'first': firstSeen.toUtc().toIso8601String(),
    'last': lastSeen.toUtc().toIso8601String(),
    'seen': seenCount,
    'routes': {for (final e in routes.entries) e.key: e.value.toJson()},
  };

  static NetworkRecord? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final first = DateTime.tryParse(json['first'] as String? ?? '');
    final last = DateTime.tryParse(json['last'] as String? ?? '');
    if (id is! String || id.isEmpty || first == null || last == null) {
      return null;
    }
    return NetworkRecord(
      id: id,
      label: (json['label'] as String? ?? '').characters(80),
      kind: (json['kind'] as String? ?? 'other').characters(16),
      vpn: json['vpn'] == true,
      cost: NetworkCostClass.values.firstWhere(
        (cost) => cost.name == json['cost'],
        orElse: () => NetworkCostClass.unmetered,
      ),
      firstSeen: first,
      lastSeen: last,
      seenCount: (json['seen'] as num?)?.toInt().clamp(1, 1 << 30) ?? 1,
      routes: {
        for (final MapEntry(:key, :value)
            in (json['routes'] as Map<String, dynamic>? ?? {}).entries.take(
              NetworkHistory.maxRoutes,
            ))
          if (value is Map<String, dynamic>)
            key.characters(160): RouteOutcome.fromJson(value),
      },
    );
  }
}

extension on String {
  String characters(int max) => length <= max ? this : substring(0, max);
}

class NetworkHistory {
  NetworkHistory([Iterable<NetworkRecord> records = const []]) {
    for (final record in records) {
      _records[record.id] = record;
    }
  }

  static const maxNetworks = 64;
  static const maxRoutes = 32;

  /// Networks (and routes) not seen for this long are forgotten.
  static const keepFor = Duration(days: 30);

  /// Failures that say a network is in the way (rather than a server down
  /// or a person away).
  static const _blockingKinds = {
    RouteFailureKind.dns,
    RouteFailureKind.reset,
    RouteFailureKind.tls,
    RouteFailureKind.timeout,
  };

  final Map<String, NetworkRecord> _records = {};
  String? _currentId;

  NetworkRecord? get current => _records[_currentId];

  List<NetworkRecord> get networks =>
      _records.values.toList()
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  /// The network now in use, recognised by what tells it apart:
  /// [kind] and the device's [lanSubnets] (no SSID: that needs location
  /// permission on Android).
  NetworkRecord enter({
    required String kind,
    required List<String> lanSubnets,
    required bool vpn,
    required NetworkCostClass cost,
    required DateTime now,
  }) {
    final subnets = lanSubnets.toSet().toList()..sort();
    final id = crypto.sha256
        .convert(utf8.encode('$kind|$vpn|${subnets.join(',')}'))
        .toString()
        .substring(0, 24);
    final label = [
      switch (kind) {
        'wifi' => 'Wi-Fi',
        'ethernet' => 'Ethernet',
        'mobile' => 'Mobile data',
        'bluetooth' => 'Bluetooth tethering',
        'vpn' => 'VPN',
        _ => 'Network',
      },
      if (subnets.isNotEmpty) subnets.map((s) => '$s.x').join(', '),
      if (vpn && kind != 'vpn') '(VPN)',
    ].join(' ');
    final existing = _records[id];
    if (existing != null) {
      if (_currentId != id) existing.seenCount++;
      existing
        ..lastSeen = now
        ..label = label
        ..cost = cost;
    } else {
      _records[id] = NetworkRecord(
        id: id,
        label: label,
        kind: kind,
        vpn: vpn,
        cost: cost,
        firstSeen: now,
        lastSeen: now,
      );
    }
    _currentId = id;
    expire(now);
    return _records[id]!;
  }

  void worked(String route, DateTime now) {
    final outcome = _outcome(route, now);
    if (outcome == null) return;
    outcome
      ..ok += 1
      ..lastWorked = now;
  }

  /// [peer] is the contact the route was tried for, when there is one: a
  /// route to one contact failing says little about the network.
  void failed(
    String route,
    RouteFailureKind kind,
    DateTime now, {
    String? peer,
  }) {
    final outcome = _outcome(route, now);
    if (outcome == null) return;
    outcome
      ..fail += 1
      ..lastFailed = now
      ..failures[kind] = (outcome.failures[kind] ?? 0) + 1
      ..recent.add(
        RouteFailure(
          now,
          kind,
          peer == null || peer.isEmpty
              ? null
              : crypto.sha256
                    .convert(utf8.encode('peer|$peer'))
                    .toString()
                    .substring(0, 8),
        ),
      );
    while (outcome.recent.length > RouteOutcome.maxRecent) {
      outcome.recent.removeAt(0);
    }
  }

  RouteOutcome? _outcome(String route, DateTime now) {
    final network = current;
    if (network == null || route.isEmpty) return null;
    network.lastSeen = now;
    final routes = network.routes;
    if (!routes.containsKey(route) && routes.length >= maxRoutes) {
      final oldest = routes.entries.reduce(
        (a, b) =>
            (a.value.lastUsed ?? network.firstSeen).isBefore(
              b.value.lastUsed ?? network.firstSeen,
            )
            ? a
            : b,
      );
      routes.remove(oldest.key);
    }
    return routes.putIfAbsent(route.characters(160), RouteOutcome.new);
  }

  /// Routes judged over this long: older failures and successes say
  /// nothing about the network as it is now.
  static const judgeWindow = Duration(hours: 24);

  /// Routes between two devices (an offline contact fails them the same
  /// way a block does): failures count against the network only when they
  /// are for at least this many different contacts, or not for a contact
  /// at all (the route's own infrastructure, such as Iroh's relay).
  static const perPeerRoutes = {'iroh', 'tor', 'direct'};
  static const _blockingFailuresNeeded = 3;
  static const _peersNeeded = 2;

  bool _workedWithin(RouteOutcome outcome, DateTime cutoff) =>
      outcome.lastWorked != null && !outcome.lastWorked!.isBefore(cutoff);

  /// Failures a network could have caused, in the window, enough of them
  /// and spread over enough contacts to blame it.
  bool _failsLikeABlock(String route, RouteOutcome outcome, DateTime cutoff) {
    final recent = outcome.recent.where((f) => !f.at.isBefore(cutoff));
    final blocking = recent.where((f) => _blockingKinds.contains(f.kind));
    final count = blocking.length;
    if (count < _blockingFailuresNeeded) return false;
    if (count * 2 < recent.length) return false;
    if (!perPeerRoutes.contains(route)) return true;
    return blocking.any((f) => f.peer == null) ||
        blocking.map((f) => f.peer).toSet().length >= _peersNeeded;
  }

  /// Internet routes this network seems to block: failing again and again
  /// in ways a network causes over the last [judgeWindow], with no success
  /// in it, while something else does work here. LAN is never judged
  /// blocked (a person away looks the same), and a route to individual
  /// contacts (Iroh) needs failures for several of them: one offline contact
  /// is not a block. [now] defaults to the last time anything happened here.
  Set<String> blockedHere({DateTime? now}) {
    final network = current;
    if (network == null) return const {};
    final cutoff = (now ?? network.lastSeen).subtract(judgeWindow);
    if (!network.routes.values.any((o) => _workedWithin(o, cutoff))) {
      return const {};
    }
    return {
      for (final MapEntry(key: route, value: outcome) in network.routes.entries)
        if (route != 'lan' &&
            !_workedWithin(outcome, cutoff) &&
            _failsLikeABlock(route, outcome, cutoff))
          route,
    };
  }

  /// Routes that work here some of the time and fail like a block at
  /// others: not blocked, but not to be relied on.
  Set<String> unreliableHere({DateTime? now}) {
    final network = current;
    if (network == null) return const {};
    final cutoff = (now ?? network.lastSeen).subtract(judgeWindow);
    return {
      for (final MapEntry(key: route, value: outcome) in network.routes.entries)
        if (route != 'lan' &&
            _workedWithin(outcome, cutoff) &&
            _failsLikeABlock(route, outcome, cutoff))
          route,
    };
  }

  /// Forgets networks and routes not seen within [keepFor], and the oldest
  /// networks beyond [maxNetworks].
  void expire(DateTime now) {
    final cutoff = now.subtract(keepFor);
    _records.removeWhere(
      (id, record) => id != _currentId && record.lastSeen.isBefore(cutoff),
    );
    for (final record in _records.values) {
      record.routes.removeWhere(
        (_, outcome) => (outcome.lastUsed ?? record.firstSeen).isBefore(cutoff),
      );
    }
    while (_records.length > maxNetworks) {
      final oldest = _records.values
          .where((record) => record.id != _currentId)
          .reduce((a, b) => a.lastSeen.isBefore(b.lastSeen) ? a : b);
      _records.remove(oldest.id);
    }
  }

  List<Map<String, Object?>> toJson() => [
    for (final record in networks) record.toJson(),
  ];

  static NetworkHistory fromJson(Object? json) => NetworkHistory([
    if (json is List)
      for (final entry in json.take(maxNetworks))
        ?NetworkRecord.tryParse(entry),
  ]);
}
