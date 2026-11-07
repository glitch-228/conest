import '../models.dart';

/// A contact seen on a cable or other link-local network: where it is and
/// whether it proved itself there. Runtime only: never saved, never sent.
class LinkEntry {
  LinkEntry({
    required this.deviceId,
    required this.ifIndex,
    required this.ifName,
    required this.address,
    required this.relayPort,
    required this.seenAt,
    this.confirmedAt,
  });

  final String deviceId;
  final int ifIndex;
  final String ifName;
  final String address;
  int relayPort;

  /// The last sign of life: a beacon, a probe answer or a delivery here.
  DateTime seenAt;

  /// When an authenticated answer to our own probe came from here.
  DateTime? confirmedAt;

  bool get confirmed => confirmedAt != null;

  /// The relay route to this contact over this link.
  PeerEndpoint get route =>
      PeerEndpoint(kind: PeerRouteKind.lan, host: address, port: relayPort);

  PeerEndpoint get udpRoute => PeerEndpoint(
    kind: PeerRouteKind.lan,
    host: address,
    port: relayPort,
    protocol: PeerRouteProtocol.udp,
  );
}

/// Contacts found on cables and link-local networks (169.254, tethering).
///
/// A beacon is not proof: anyone on the segment who knows a device id can
/// send one. So an entry is *unconfirmed* until an authenticated answer to
/// our own probe comes from its address, and only confirmed entries are
/// used for routes, files or Iroh hints. Confirmed entries are pinned: no
/// unconfirmed entry ever pushes one out.
///
/// Bounds: 16 links, 8 entries on each, 2 unconfirmed and 2 confirmed per
/// device and link, one device id per address, unconfirmed entries last 60 s.
class LinkTable {
  LinkTable({
    required DateTime Function() now,
    this.maxLinks = 16,
    this.maxEntriesPerLink = 8,
    this.unconfirmedTtl = const Duration(seconds: 60),
  }) : _now = now;

  final DateTime Function() _now;
  final int maxLinks;
  final int maxEntriesPerLink;
  final Duration unconfirmedTtl;
  static const int _perDeviceAndLink = 2;
  static const int _maxCandidateEntries = 3;

  final List<LinkEntry> _entries = [];

  void _expire() {
    final cutoff = _now().subtract(unconfirmedTtl);
    _entries.removeWhere(
      (entry) => !entry.confirmed && entry.seenAt.isBefore(cutoff),
    );
  }

  /// Nothing known (no clock read, no expiry: cheap enough for a hot path).
  bool get isEmpty => _entries.isEmpty;

  int get linkCount {
    _expire();
    return _entries.map((entry) => entry.ifIndex).toSet().length;
  }

  List<LinkEntry> entriesOnLink(int ifIndex) {
    _expire();
    return [
      for (final entry in _entries)
        if (entry.ifIndex == ifIndex) entry,
    ];
  }

  /// Every entry, for the settings page.
  List<LinkEntry> get all {
    _expire();
    return List.unmodifiable(_entries);
  }

  LinkEntry? _at(String deviceId, String address) {
    for (final entry in _entries) {
      if (entry.deviceId == deviceId && entry.address == address) return entry;
    }
    return null;
  }

  bool _addressTakenByOther(String deviceId, String address) => _entries.any(
    (entry) => entry.address == address && entry.deviceId != deviceId,
  );

  /// Room for a new entry on [ifIndex] (null when the link is new and the
  /// table is full of other links, which cannot happen for [force]).
  bool _makeRoom(int ifIndex, {required bool confirmed}) {
    final onLink = [
      for (final entry in _entries)
        if (entry.ifIndex == ifIndex) entry,
    ];
    if (onLink.isEmpty &&
        _entries.map((entry) => entry.ifIndex).toSet().length >= maxLinks) {
      if (!confirmed) return false;
      // An authenticated answer beats a link nobody has spoken on lately.
      final stale = <int, DateTime>{};
      for (final entry in _entries) {
        final seen = stale[entry.ifIndex];
        if (seen == null || entry.seenAt.isAfter(seen)) {
          stale[entry.ifIndex] = entry.seenAt;
        }
      }
      final oldest = stale.entries.reduce(
        (a, b) => a.value.isBefore(b.value) ? a : b,
      );
      _entries.removeWhere((entry) => entry.ifIndex == oldest.key);
      return true;
    }
    if (onLink.length < maxEntriesPerLink) return true;
    final unconfirmed = onLink.where((entry) => !entry.confirmed).toList()
      ..sort((a, b) => a.seenAt.compareTo(b.seenAt));
    if (unconfirmed.isNotEmpty) {
      _entries.remove(unconfirmed.first);
      return true;
    }
    if (!confirmed) return false;
    final oldest = onLink.reduce((a, b) => a.seenAt.isBefore(b.seenAt) ? a : b);
    _entries.remove(oldest);
    return true;
  }

  /// A beacon or ping from [deviceId] at [address] on a link. Returns its
  /// entry, or null when the table refuses it (the address belongs to
  /// another device, or the link is full of confirmed entries).
  LinkEntry? observe({
    required String deviceId,
    required int ifIndex,
    required String ifName,
    required String address,
    required int relayPort,
  }) {
    _expire();
    final now = _now();
    final existing = _at(deviceId, address);
    if (existing != null) {
      existing.seenAt = now;
      // A confirmed entry keeps the port it proved.
      if (!existing.confirmed) existing.relayPort = relayPort;
      return existing;
    }
    if (_addressTakenByOther(deviceId, address)) return null;
    final sameDevice = [
      for (final entry in _entries)
        if (entry.deviceId == deviceId &&
            entry.ifIndex == ifIndex &&
            !entry.confirmed)
          entry,
    ]..sort((a, b) => a.seenAt.compareTo(b.seenAt));
    while (sameDevice.length >= _perDeviceAndLink) {
      _entries.remove(sameDevice.removeAt(0));
    }
    if (!_makeRoom(ifIndex, confirmed: false)) return null;
    final entry = LinkEntry(
      deviceId: deviceId,
      ifIndex: ifIndex,
      ifName: ifName,
      address: address,
      relayPort: relayPort,
      seenAt: now,
    );
    _entries.add(entry);
    return entry;
  }

  /// An authenticated answer to our probe came from [address]: the entry
  /// is real and pinned. Created if forged beacons pushed it out meanwhile.
  LinkEntry confirm({
    required String deviceId,
    required int ifIndex,
    required String ifName,
    required String address,
    required int relayPort,
  }) {
    _expire();
    final now = _now();
    var entry = _at(deviceId, address);
    if (entry == null) {
      // The answer is proof: another device's older claim on this address
      // (a stale lease) gives way.
      _entries.removeWhere(
        (other) => other.address == address && other.deviceId != deviceId,
      );
      _makeRoom(ifIndex, confirmed: true);
      entry = LinkEntry(
        deviceId: deviceId,
        ifIndex: ifIndex,
        ifName: ifName,
        address: address,
        relayPort: relayPort,
        seenAt: now,
      );
      _entries.add(entry);
    }
    entry
      ..seenAt = now
      ..confirmedAt = now;
    final confirmed = [
      for (final other in _entries)
        if (other.deviceId == deviceId &&
            other.ifIndex == entry.ifIndex &&
            other.confirmed &&
            !identical(other, entry))
          other,
    ]..sort((a, b) => a.seenAt.compareTo(b.seenAt));
    while (confirmed.length >= _perDeviceAndLink) {
      _entries.remove(confirmed.removeAt(0));
    }
    return entry;
  }

  /// A sign of life from a confirmed entry (a delivery over it).
  void touch(String deviceId, String address) {
    final entry = _at(deviceId, address);
    if (entry != null && entry.confirmed) entry.seenAt = _now();
  }

  /// Its route failed: drop it (a beacon and a new probe bring it back).
  LinkEntry? evict(String deviceId, String address) {
    final entry = _at(deviceId, address);
    if (entry != null) _entries.remove(entry);
    return entry;
  }

  /// The entries of links that are not in [present] any more.
  List<LinkEntry> dropMissingLinks(Set<int> present) {
    final removed = [
      for (final entry in _entries)
        if (!present.contains(entry.ifIndex)) entry,
    ];
    _entries.removeWhere((entry) => !present.contains(entry.ifIndex));
    return removed;
  }

  List<LinkEntry> confirmedFor(String deviceId) {
    _expire();
    return [
      for (final entry in _entries)
        if (entry.deviceId == deviceId && entry.confirmed) entry,
    ]..sort((a, b) => b.seenAt.compareTo(a.seenAt));
  }

  List<LinkEntry> unconfirmedFor(String deviceId) {
    _expire();
    return [
      for (final entry in _entries)
        if (entry.deviceId == deviceId && !entry.confirmed) entry,
    ];
  }

  /// Relay routes for delivery: confirmed entries only, newest first, at
  /// most three entries with a TCP and a UDP route each.
  List<PeerEndpoint> candidateRoutes(String deviceId) => [
    for (final entry in confirmedFor(deviceId).take(_maxCandidateEntries)) ...[
      entry.route,
      entry.udpRoute,
    ],
  ];

  /// Where to answer a cable probe from [deviceId]: every entry we hold for
  /// it, because an offline contact has no other route back.
  List<PeerEndpoint> replyRoutes(String deviceId) {
    _expire();
    return [
      for (final entry in _entries)
        if (entry.deviceId == deviceId) entry.route,
    ];
  }

  void clear() => _entries.clear();
}
