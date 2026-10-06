import 'dart:async';
import 'dart:typed_data';

import 'package:conest/src/bitchat/mesh.dart';

/// Phones in Bluetooth range of each other: each node's link layer reaches
/// only the nodes it is [connect]ed to.
class FakeBleNeighbourhood {
  final Map<String, FakeBleLinks> _nodes = {};

  /// Packets that crossed any link, in order.
  final List<Uint8List> airtime = [];

  FakeBleLinks node(String name) =>
      _nodes.putIfAbsent(name, () => FakeBleLinks._(this, name));

  void connect(String a, String b) {
    node(a)._neighbours.add(b);
    node(b)._neighbours.add(a);
  }

  /// Makes the link from [a] to [b] carry at most [bytes] per write, like
  /// an iPhone's smaller Bluetooth packets.
  void limit(String a, String b, int bytes) => node(a)._limits[b] = bytes;
}

class FakeBleLinks implements BitchatLinkLayer {
  FakeBleLinks._(this._area, this.name);

  final FakeBleNeighbourhood _area;
  final String name;
  final Set<String> _neighbours = {};
  final Map<String, int> _limits = {};
  final _received = StreamController<(String, Uint8List)>.broadcast();

  @override
  Stream<(String, Uint8List)> get received => _received.stream;

  /// Problems to report, such as Bluetooth turning off.
  final problemReports = StreamController<String?>.broadcast();

  @override
  Stream<String?> get problems => problemReports.stream;

  @override
  Future<void> broadcast(Uint8List packet, {String? except}) async {
    if (except == null && _neighbours.isEmpty) {
      throw StateError('No phones nearby.');
    }
    for (final neighbour in _neighbours) {
      if (neighbour == except) continue;
      if (packet.length > (_limits[neighbour] ?? packet.length)) {
        throw StateError('Packet too large for the link to $neighbour.');
      }
      _area.airtime.add(packet);
      final target = _area._nodes[neighbour]!;
      scheduleMicrotask(
        () => target._received.add((name, Uint8List.fromList(packet))),
      );
    }
  }

  @override
  Map<String, int> get linkLimits => {
    for (final neighbour in _neighbours) neighbour: _limits[neighbour] ?? 512,
  };

  @override
  Future<void> sendTo(String link, Uint8List packet) async {
    if (!_neighbours.contains(link)) throw StateError('No such neighbour.');
    final limit = _limits[link] ?? packet.length;
    if (packet.length > limit) {
      throw StateError('${packet.length} bytes do not fit a $limit-byte link.');
    }
    _area.airtime.add(packet);
    final target = _area._nodes[link]!;
    scheduleMicrotask(
      () => target._received.add((name, Uint8List.fromList(packet))),
    );
  }

  @override
  Future<void> close() => _received.close();
}
