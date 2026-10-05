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
}

class FakeBleLinks implements BitchatLinkLayer {
  FakeBleLinks._(this._area, this.name);

  final FakeBleNeighbourhood _area;
  final String name;
  final Set<String> _neighbours = {};
  final _received = StreamController<(String, Uint8List)>.broadcast();

  @override
  Stream<(String, Uint8List)> get received => _received.stream;

  @override
  Future<void> broadcast(Uint8List packet, {String? except}) async {
    for (final neighbour in _neighbours) {
      if (neighbour == except) continue;
      _area.airtime.add(packet);
      final target = _area._nodes[neighbour]!;
      scheduleMicrotask(
        () => target._received.add((name, Uint8List.fromList(packet))),
      );
    }
  }

  @override
  Future<void> close() => _received.close();
}
