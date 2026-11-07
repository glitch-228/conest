import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import '../models.dart';
import 'iroh_hint_book.dart';
import 'link_interfaces.dart';
import 'link_table.dart';
import 'link_watcher.dart';

/// A datagram a ping socket received: bytes, source address, source port.
typedef PingDatagram = (Uint8List data, String address, int port);

/// The short-lived socket a cable ping is sent from. It is bound to the
/// interface's own IPv4 address (so a broadcast leaves on that link) and
/// to a port of its own: the answers go to that port, not to 7668.
abstract interface class PingSocket {
  Stream<PingDatagram> get datagrams;
  set broadcastEnabled(bool value);
  void send(List<int> bytes, String address, int port);
  void close();
}

typedef PingSocketFactory = Future<PingSocket> Function(String localAddress);

/// The real ping socket, over `RawDatagramSocket`.
class RawPingSocket implements PingSocket {
  RawPingSocket._(this._socket) {
    _socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = _socket.receive()) != null) {
          _controller.add((
            datagram!.data,
            datagram.address.address,
            datagram.port,
          ));
        }
      },
      onError: (_) {},
      onDone: () => unawaited(_controller.close()),
      cancelOnError: false,
    );
  }

  static Future<PingSocket> bind(String localAddress) async => RawPingSocket._(
    await RawDatagramSocket.bind(InternetAddress(localAddress), 0),
  );

  final RawDatagramSocket _socket;
  final _controller = StreamController<PingDatagram>.broadcast();

  @override
  Stream<PingDatagram> get datagrams => _controller.stream;

  @override
  set broadcastEnabled(bool value) => _socket.broadcastEnabled = value;

  @override
  void send(List<int> bytes, String address, int port) {
    _socket.send(bytes, InternetAddress(address), port);
  }

  @override
  void close() => _socket.close();
}

/// What the settings page shows for one link.
class CableLinkView {
  const CableLinkView({
    required this.name,
    required this.kind,
    required this.addresses,
    required this.contactDeviceIds,
    required this.pingable,
  });

  final String name;
  final LinkKind kind;
  final List<String> addresses;

  /// Contacts that proved themselves on this link.
  final List<String> contactDeviceIds;

  /// Whether Conest looks for contacts here.
  final bool pingable;
}

/// What a controller needs to run cable links for real; tests give their
/// own sockets and interface listing.
class CableLinkEnvironment {
  const CableLinkEnvironment({
    this.interfaceSource = systemInterfaceSource,
    this.pingSockets = RawPingSocket.bind,
    this.androidFallback = false,
    this.pingListens = const Duration(seconds: 5),
  });

  final RawInterfaceSource interfaceSource;
  final PingSocketFactory pingSockets;

  /// Android only: the bounded fallback look while the page is open.
  final bool androidFallback;

  /// How long a ping socket listens for answers.
  final Duration pingListens;
}

class _PendingProbe {
  _PendingProbe(this.entry, this.at);
  final LinkEntry entry;
  final DateTime at;
}

/// Finding contacts on cables and tethering links, with no router and no
/// internet.
///
/// A new cable link gets a ping on its own interface; a contact's answer is
/// only a candidate until it answers an authenticated probe sent to that
/// address alone (see [LinkTable]). Confirmed entries give the LAN transport
/// extra routes, LAN-direct file endpoints and fresh Iroh hints. Nothing here
/// is saved or sent to a contact.
class CableLinks {
  CableLinks({
    required DateTime Function() now,
    required RawInterfaceSource interfaceSource,
    required PingSocketFactory pingSockets,
    required Future<List<Uint8List>> Function() buildPing,
    required bool Function(String deviceId) isKnownDevice,
    required void Function(Datagram datagram, int ifIndex) feedBeacon,
    required Future<bool> Function(LinkEntry entry, String probeId) sendProbe,
    required String Function() newProbeId,
    bool Function()? enabled,
    this.onConfirmed,
    this.onDropped,
    this.networkChanged,
    this.log,
    bool androidFallback = false,
    Duration pingListens = const Duration(seconds: 5),
  }) : _now = now,
       _pingListens = pingListens,
       _source = interfaceSource,
       _pingSockets = pingSockets,
       _buildPing = buildPing,
       _isKnownDevice = isKnownDevice,
       _feedBeacon = feedBeacon,
       _sendProbe = sendProbe,
       _newProbeId = newProbeId,
       _enabled = enabled ?? (() => true),
       table = LinkTable(now: now),
       hints = IrohHintBook(now: now) {
    watcher = LinkWatcher(
      onChanged: onLinksChanged,
      androidFallback: androidFallback,
      onError: (error) => log?.call('Link change not handled: $error'),
    );
  }

  final DateTime Function() _now;

  /// How long a ping socket stays open for the answers.
  final Duration _pingListens;
  final RawInterfaceSource _source;
  final PingSocketFactory _pingSockets;
  final Future<List<Uint8List>> Function() _buildPing;
  final bool Function(String deviceId) _isKnownDevice;
  final void Function(Datagram datagram, int ifIndex) _feedBeacon;
  final Future<bool> Function(LinkEntry entry, String probeId) _sendProbe;
  final String Function() _newProbeId;

  /// Whether cable links are on (the setting, LAN on, not asleep). Checked
  /// at every entry point, so nothing is sent while it is false.
  final bool Function() _enabled;

  /// A contact proved itself on a link (an entry was confirmed).
  final void Function(LinkEntry entry)? onConfirmed;

  /// Entries went with their link.
  final void Function(List<LinkEntry> removed)? onDropped;

  /// A link that mattered vanished: Iroh should look at its paths again.
  final Future<void> Function()? networkChanged;
  final void Function(String message)? log;

  final LinkTable table;
  final IrohHintBook hints;
  late final LinkWatcher watcher;

  /// Counts up whenever what the page shows may have changed.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const int _beaconPort = 7668;
  static const Duration _pingNowGap = Duration(seconds: 10);
  static const Duration _relistGap = Duration(seconds: 10);
  static const Duration _probeGap = Duration(seconds: 30);
  static const Duration _probeLife = Duration(seconds: 60);
  static const Duration _freshFor = Duration(minutes: 10);
  static const int _maxProbes = 4;

  Map<int, LinkInterface> _links = {};
  final Map<int, String> _pingedAddresses = {};
  final Map<int, PingSocket> _openPings = {};
  final Map<int, StreamSubscription<PingDatagram>> _pingSubscriptions = {};
  final Map<int, Timer> _pingTimers = {};
  final Map<String, _PendingProbe> _pending = {};
  final Map<String, DateTime> _probedAt = {};
  DateTime? _lastPingNowAt;
  DateTime? _lastRelistAt;
  bool _disposed = false;

  @visibleForTesting
  List<String> get pendingProbeIdsForTesting => _pending.keys.toList();

  int get probesInFlight {
    _expirePending();
    return _pending.length;
  }

  List<LinkInterface> get links => List.unmodifiable(_links.values);

  /// What the settings page lists.
  List<CableLinkView> get views => [
    for (final link in _links.values)
      CableLinkView(
        name: link.name,
        kind: link.kind,
        addresses: link.v4,
        contactDeviceIds: [
          for (final entry in table.entriesOnLink(link.index))
            if (entry.confirmed) entry.deviceId,
        ],
        pingable: link.pingable,
      ),
  ];

  /// Something about the links may have changed (a platform event).
  void note(LinkEventSource source) => watcher.note(source);

  /// Lists the links again: pings the new ones, forgets those that went.
  Future<void> onLinksChanged() async {
    if (_disposed || !_enabled()) return;
    final listed = await listLinkInterfaces(source: _source);
    if (_disposed) return;
    final previous = _links;
    _links = {for (final link in listed) link.index: link};
    final vanished = previous.values.any(
      (link) => link.pingable && !_links.containsKey(link.index),
    );
    final removed = table.dropMissingLinks(_links.keys.toSet());
    _pingedAddresses.removeWhere((index, _) => !_links.containsKey(index));
    if (removed.isNotEmpty) onDropped?.call(removed);
    if (vanished || removed.isNotEmpty) {
      log?.call('A cable link went; its contacts are no longer reached there.');
      try {
        await networkChanged?.call();
      } catch (error) {
        log?.call('Network change not applied: $error');
      }
    }
    for (final link in listed.where((link) => link.pingable)) {
      final addresses = link.v4.join(',');
      if (_pingedAddresses[link.index] == addresses) continue;
      _pingedAddresses[link.index] = addresses;
      unawaited(_ping(link));
    }
    revision.value++;
  }

  /// A contact or group member was just added: ping the cable links that
  /// are already up (at most once in 10 s).
  Future<void> pingNow() async {
    if (_disposed || !_enabled()) return;
    final now = _now();
    final last = _lastPingNowAt;
    if (last != null && now.difference(last) < _pingNowGap) return;
    _lastPingNowAt = now;
    if (_links.isEmpty) {
      await onLinksChanged();
      return;
    }
    for (final link in _links.values.where((link) => link.pingable)) {
      unawaited(_ping(link));
    }
  }

  Future<void> _ping(LinkInterface link) async {
    if (_disposed || _openPings.containsKey(link.index)) return;
    final PingSocket socket;
    try {
      socket = await _pingSockets(link.v4.first);
    } catch (error) {
      log?.call('Ping on ${link.name} not sent: $error');
      return;
    }
    if (_disposed || _openPings.containsKey(link.index)) {
      socket.close();
      return;
    }
    _openPings[link.index] = socket;
    _pingSubscriptions[link.index] = socket.datagrams.listen((datagram) {
      if (_disposed) return;
      try {
        _feedBeacon(
          Datagram(datagram.$1, InternetAddress(datagram.$2), datagram.$3),
          link.index,
        );
      } catch (_) {
        // A datagram that cannot be read is dropped like any beacon junk.
      }
    }, onError: (_) {});
    _pingTimers[link.index] = Timer(_pingListens, () => _closePing(link.index));
    try {
      socket.broadcastEnabled = true;
      final payloads = await _buildPing();
      for (final target in _broadcastTargets(link)) {
        for (final bytes in payloads) {
          try {
            socket.send(bytes, target, _beaconPort);
          } catch (_) {
            // Best effort, like every beacon.
          }
        }
      }
    } catch (error) {
      log?.call('Ping on ${link.name} not sent: $error');
    }
  }

  void _closePing(int ifIndex) {
    _pingTimers.remove(ifIndex)?.cancel();
    unawaited(_pingSubscriptions.remove(ifIndex)?.cancel());
    _openPings.remove(ifIndex)?.close();
  }

  List<String> _broadcastTargets(LinkInterface link) {
    final targets = <String>['255.255.255.255'];
    for (final address in link.v4) {
      final target = isLinkScopedHost(address)
          ? '169.254.255.255'
          : '${address.substring(0, address.lastIndexOf('.'))}.255';
      if (!targets.contains(target)) targets.add(target);
    }
    return targets;
  }

  LinkInterface? _linkFor(String address) {
    final prefix = address.substring(0, address.lastIndexOf('.'));
    for (final link in _links.values) {
      for (final own in link.v4) {
        if (isLinkScopedHost(address) && isLinkScopedHost(own)) return link;
        if (own.substring(0, own.lastIndexOf('.')) == prefix) return link;
      }
    }
    return null;
  }

  /// A beacon or ping said [deviceId] is at [address] with its relay on
  /// [relayPort]. [ifIndex] is the link of the socket that heard it (a ping
  /// socket knows; the long-lived listener does not). Only contacts and
  /// group members count, and only on a cable or with a link-local address:
  /// other LAN beacons keep the path they always had. Returns whether an
  /// entry was noted.
  bool observeBeacon({
    required String deviceId,
    required String address,
    required int relayPort,
    int? ifIndex,
  }) {
    if (_disposed || !_enabled() || !_isKnownDevice(deviceId)) return false;
    if (relayPort < 1 || relayPort > 65535) return false;
    if (InternetAddress.tryParse(address)?.type != InternetAddressType.IPv4) {
      return false;
    }
    final link =
        (ifIndex == null ? null : _links[ifIndex]) ?? _linkFor(address);
    if (link == null) {
      _requestRelist();
      return false;
    }
    if (link.v4.contains(address)) return false;
    if (link.kind != LinkKind.cable && !isLinkScopedHost(address)) return false;
    final entry = table.observe(
      deviceId: deviceId,
      ifIndex: link.index,
      ifName: link.name,
      address: address,
      relayPort: relayPort,
    );
    if (entry == null) return false;
    if (!entry.confirmed) _probe(entry);
    revision.value++;
    return true;
  }

  /// The IPv4 addresses of this device on the listed links.
  List<String> get ownV4Addresses => [
    for (final link in _links.values) ...link.v4,
  ];

  /// Whether [address] is a confirmed address of [deviceId].
  bool isConfirmedAddress(String deviceId, String address) => table
      .confirmedFor(deviceId)
      .any((entry) => entry.address == address);

  List<LinkEntry> get confirmedEntries => [
    for (final entry in table.all)
      if (entry.confirmed) entry,
  ];

  /// Asks every confirmed entry again (one probe each, at most one in 30 s
  /// per entry): after a change of network their route health is gone.
  void reprobeConfirmed() {
    if (_disposed || !_enabled()) return;
    for (final entry in confirmedEntries) {
      _probe(entry);
    }
  }

  /// Whether [address] is one of this device's own on a listed link.
  bool ownsAddress(String address) =>
      _links.values.any((link) => link.v4.contains(address));

  /// Asks for a new listing (at most one in 10 s).
  void requestRelist() => _requestRelist();

  void _requestRelist() {
    final now = _now();
    final last = _lastRelistAt;
    if (last != null && now.difference(last) < _relistGap) return;
    _lastRelistAt = now;
    watcher.note(LinkEventSource.manual);
  }

  void _expirePending() {
    final now = _now();
    _pending.removeWhere((_, probe) => now.difference(probe.at) > _probeLife);
  }

  void _probe(LinkEntry entry) {
    final now = _now();
    _expirePending();
    final key = '${entry.deviceId}|${entry.address}';
    final last = _probedAt[key];
    if (last != null && now.difference(last) < _probeGap) return;
    if (_pending.length >= _maxProbes) return;
    _probedAt[key] = now;
    if (_probedAt.length > 64) {
      _probedAt.removeWhere((_, at) => now.difference(at) > _probeLife);
    }
    final id = _newProbeId();
    _pending[id] = _PendingProbe(entry, now);
    unawaited(
      _sendProbe(entry, id).then(
        (sent) {
          if (!sent) _pending.remove(id);
        },
        onError: (Object _) {
          _pending.remove(id);
        },
      ),
    );
  }

  /// The authenticated answer to probe [probeId] came from [deviceId]:
  /// the entry it was sent to is real. False for an unknown probe or
  /// another sender.
  bool onProbeReply(String probeId, String deviceId) {
    if (_disposed) return false;
    _expirePending();
    final pending = _pending[probeId];
    if (pending == null || pending.entry.deviceId != deviceId) return false;
    _pending.remove(probeId);
    final entry = table.confirm(
      deviceId: deviceId,
      ifIndex: pending.entry.ifIndex,
      ifName: pending.entry.ifName,
      address: pending.entry.address,
      relayPort: pending.entry.relayPort,
    );
    onConfirmed?.call(entry);
    revision.value++;
    return true;
  }

  /// Relay routes to [deviceId] over confirmed links (never unconfirmed).
  List<PeerEndpoint> candidateRoutes(String deviceId) =>
      table.candidateRoutes(deviceId);

  /// Where to answer a cable probe: every entry held for [deviceId].
  List<PeerEndpoint> replyRoutes(String deviceId) =>
      table.replyRoutes(deviceId);

  /// Confirmed hosts with a sign of life in the last 10 minutes: a beacon, a
  /// delivery over them, or [healthyAt] (when the route last answered a
  /// health check).
  List<FreshHost> freshHostsFor(
    String deviceId, {
    DateTime? Function(PeerEndpoint route)? healthyAt,
  }) {
    final now = _now();
    final fresh = <FreshHost>[];
    for (final entry in table.confirmedFor(deviceId)) {
      var at = entry.seenAt;
      final healthy = healthyAt?.call(entry.route);
      if (healthy != null && healthy.isAfter(at)) at = healthy;
      if (now.difference(at) <= _freshFor) {
        fresh.add(FreshHost(entry.address, at));
      }
    }
    return fresh;
  }

  void touch(String deviceId, String address) => table.touch(deviceId, address);

  final Map<String, int> _failures = {};
  final Map<int, DateTime> _evictedPingAt = {};

  /// How a delivery or health check over [route] went. A confirmed entry
  /// whose route fails three times in a row is dropped (a beacon or a new
  /// ping brings it back) and its link is pinged again, at most every 30 s.
  void noteRouteOutcome(PeerEndpoint route, bool ok) {
    // Every route outcome of the app comes through here: most have no link.
    if (_disposed || route.kind != PeerRouteKind.lan || table.isEmpty) return;
    final entries = [
      for (final entry in table.all)
        if (entry.confirmed &&
            entry.address == route.host &&
            entry.relayPort == route.port)
          entry,
    ];
    if (entries.isEmpty) return;
    final key = '${route.host}:${route.port}';
    if (ok) {
      _failures.remove(key);
      return;
    }
    final count = (_failures[key] ?? 0) + 1;
    if (count < 3) {
      _failures[key] = count;
      return;
    }
    _failures.remove(key);
    final removed = <LinkEntry>[];
    for (final entry in entries) {
      final gone = table.evict(entry.deviceId, entry.address);
      if (gone != null) removed.add(gone);
    }
    if (removed.isEmpty) return;
    onDropped?.call(removed);
    final now = _now();
    for (final ifIndex in removed.map((entry) => entry.ifIndex).toSet()) {
      final link = _links[ifIndex];
      final last = _evictedPingAt[ifIndex];
      if (link == null || !link.pingable) continue;
      if (last != null && now.difference(last) < const Duration(seconds: 30)) {
        continue;
      }
      _evictedPingAt[ifIndex] = now;
      unawaited(_ping(link));
    }
    revision.value++;
  }

  /// Hints for one Iroh dial to [deviceId]: [stored] are the direct hints
  /// the contact record holds, [lanHints] its LAN routes, and [healthOf]
  /// when a route last answered. See [IrohHintBook.hintsFor].
  List<String> irohHints({
    required String deviceId,
    required List<PeerEndpoint> stored,
    required List<PeerEndpoint> lanHints,
    required PeerRouteHealth? Function(PeerEndpoint route) healthOf,
  }) {
    final now = _now();
    final fresh = <FreshHost>[
      ...freshHostsFor(
        deviceId,
        healthyAt: (route) {
          final health = healthOf(route);
          return health != null && health.available ? health.checkedAt : null;
        },
      ),
    ];
    for (final route in lanHints) {
      final health = healthOf(route);
      if (health == null ||
          !health.available ||
          now.difference(health.checkedAt) > _freshFor) {
        continue;
      }
      fresh.add(FreshHost(route.host, health.checkedAt));
    }
    return hints.hintsFor(
      deviceId: deviceId,
      storedDirect: stored,
      fresh: fresh,
    );
  }

  /// The ports a contact told us in an encrypted route update.
  void notePorts(String deviceId, Object? json) {
    final ports = LinkPorts.tryParse(json);
    if (ports != null) hints.notePorts(deviceId, ports);
  }

  /// Forgets everything learned (a vault reset), and keeps working.
  void reset() {
    for (final index in _openPings.keys.toList()) {
      _closePing(index);
    }
    table.clear();
    hints.clear();
    _pending.clear();
    _probedAt.clear();
    _failures.clear();
    _evictedPingAt.clear();
    _pingedAddresses.clear();
    _lastPingNowAt = null;
    _lastRelistAt = null;
    revision.value++;
  }

  void dispose() {
    _disposed = true;
    watcher.dispose();
    for (final index in _openPings.keys.toList()) {
      _closePing(index);
    }
    table.clear();
    hints.clear();
    _pending.clear();
    _probedAt.clear();
    revision.dispose();
  }
}
