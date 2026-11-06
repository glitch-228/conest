import 'dart:collection';
import 'dart:io';

import '../models.dart';

/// The ports a contact told us in an encrypted route update: the two ports
/// of its Iroh endpoint (one per address family; both change at every
/// start), the port of its LAN-direct file server and the version of its
/// binary file blocks. They are only taken from authenticated payloads.
class LinkPorts {
  const LinkPorts({this.iroh4, this.iroh6, this.direct, this.binary});

  final int? iroh4;
  final int? iroh6;
  final int? direct;
  final int? binary;

  bool get isEmpty =>
      iroh4 == null && iroh6 == null && direct == null && binary == null;

  /// The `linkPorts` object of a route update, or null if it holds nothing
  /// usable.
  static LinkPorts? tryParse(Object? json) {
    if (json is! Map) return null;
    int? port(Object? value) =>
        value is int && value >= 1 && value <= 65535 ? value : null;
    final binary = json['binary'];
    final ports = LinkPorts(
      iroh4: port(json['iroh4']),
      iroh6: port(json['iroh6']),
      direct: port(json['direct']),
      binary: binary is int && binary >= 0 && binary <= 1 ? binary : null,
    );
    return ports.isEmpty ? null : ports;
  }

  Map<String, Object> toJson() => {
    'iroh4': ?iroh4,
    'iroh6': ?iroh6,
    'direct': ?direct,
    'binary': ?binary,
  };
}

/// A host seen recently on this device's links, and when.
class FreshHost {
  const FreshHost(this.host, this.at);

  final String host;
  final DateTime at;
}

/// What Iroh is told to dial. Offline there is no relay and no discovery,
/// so hints are its only way in; the ones that came with an invite or an
/// old route update are stale after a restart (its ports are random). This
/// puts the addresses seen on a cable or a working LAN just now in front.
class IrohHintBook {
  IrohHintBook({required DateTime Function() now}) : _now = now;

  final DateTime Function() _now;

  static const int maxHints = 8;
  static const int maxStored = 4;
  static const int maxPeers = 64;
  static const Duration portsTtl = Duration(hours: 1);

  /// Per peer, in order of last news (oldest first).
  final LinkedHashMap<String, (LinkPorts, DateTime)> _ports =
      LinkedHashMap<String, (LinkPorts, DateTime)>();

  int get peerCount => _ports.length;

  void notePorts(String deviceId, LinkPorts ports) {
    _ports.remove(deviceId);
    _ports[deviceId] = (ports, _now());
    while (_ports.length > maxPeers) {
      _ports.remove(_ports.keys.first);
    }
  }

  LinkPorts? portsFor(String deviceId) {
    final entry = _ports[deviceId];
    if (entry == null) return null;
    if (_now().difference(entry.$2) > portsTtl) {
      _ports.remove(deviceId);
      return null;
    }
    return entry.$1;
  }

  void clear() => _ports.clear();

  /// At most 8 `host:port` strings for one dial: the fresh hosts (newest
  /// first, with the peer's port for the host's family) in front, then up
  /// to 4 stored direct hints. Anything that cannot be written the way
  /// Rust reads it is left out here, because one bad hint fails the whole
  /// send. With nothing fresh this is exactly the stored hints.
  List<String> hintsFor({
    required String deviceId,
    required List<PeerEndpoint> storedDirect,
    required Iterable<FreshHost> fresh,
  }) {
    final stored = <String>[];
    int? storedPort4;
    int? storedPort6;
    for (final route in storedDirect) {
      if (route.protocol != PeerRouteProtocol.udp) continue;
      final text = formatIrohSocketAddress(route.host, route.port);
      if (text == null) continue;
      if (stored.contains(text)) continue;
      if (stored.length < maxStored) stored.add(text);
      final family = InternetAddress.tryParse(
        route.host.split('%').first,
      )?.type;
      if (family == InternetAddressType.IPv4) storedPort4 ??= route.port;
      if (family == InternetAddressType.IPv6) storedPort6 ??= route.port;
    }
    final ports = portsFor(deviceId);
    final ordered = fresh.toList()..sort((a, b) => b.at.compareTo(a.at));
    final room = maxHints - stored.length;
    final freshHints = <String>[];
    for (final host in ordered) {
      if (freshHints.length >= room) break;
      final family = InternetAddress.tryParse(host.host.split('%').first)?.type;
      final port = switch (family) {
        InternetAddressType.IPv4 => ports?.iroh4 ?? storedPort4,
        InternetAddressType.IPv6 => ports?.iroh6 ?? storedPort6,
        _ => null,
      };
      if (port == null) continue;
      final text = formatIrohSocketAddress(host.host, port);
      if (text == null || stored.contains(text) || freshHints.contains(text)) {
        continue;
      }
      freshHints.add(text);
    }
    return [...freshHints, ...stored];
  }
}

/// A socket address the way Rust's `SocketAddr` parses it: `1.2.3.4:5`,
/// `[::1]:5`, and for a link-local one a numeric zone (`[fe80::1%3]:5`,
/// never a zone name). Null for anything else.
String? formatIrohSocketAddress(String host, int port) {
  if (port < 1 || port > 65535) return null;
  final value = host.trim();
  final percent = value.indexOf('%');
  if (percent >= 0) {
    final zone = value.substring(percent + 1);
    if (zone.isEmpty || !RegExp(r'^\d+$').hasMatch(zone)) return null;
  }
  final address = InternetAddress.tryParse(value);
  if (address == null) return null;
  return address.type == InternetAddressType.IPv6
      ? '[${address.address}]:$port'
      : '${address.address}:$port';
}
