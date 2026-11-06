import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conest/src/net/link_interfaces.dart';

/// The system interface listing with the real Dart behaviour: without
/// `includeLinkLocal` it drops every 169.254 and fe80 address (which hid
/// link-local peers from Conest), and an interface left with no address
/// does not appear. Tests change [interfaces] to plug and unplug cables.
class StrictInterfaceSource {
  StrictInterfaceSource([List<RawInterface> interfaces = const []])
    : interfaces = List.of(interfaces);

  List<RawInterface> interfaces;
  int calls = 0;

  Future<List<RawInterface>> call({required bool includeLinkLocal}) async {
    calls++;
    final listed = <RawInterface>[];
    for (final interface in interfaces) {
      final kept = [
        for (final address in interface.addresses)
          if (includeLinkLocal || !InternetAddress(address).isLinkLocal)
            address,
      ];
      if (kept.isEmpty) continue;
      listed.add(
        RawInterface(
          name: interface.name,
          index: interface.index,
          addresses: kept,
        ),
      );
    }
    return listed;
  }
}

/// A UDP segment with the limits of the real thing that matter here:
/// every bound socket has its own port (a reply goes to the socket that
/// asked, never to port 7668 unless that is where the asker is), a socket
/// bound to an address that no host has fails, sends need a broadcast flag
/// for broadcast addresses, and a datagram is only seen by the sockets on
/// its segment.
class StrictBeaconNetwork {
  final List<StrictHost> hosts = [];
  int _nextPort = 40001;

  StrictHost addHost(
    String address, {
    String segment = 'cable',
    void Function(StrictHost host, Uint8List data, String from, int fromPort)?
    onListenerDatagram,
  }) {
    final host = StrictHost._(this, address, segment)
      ..onListenerDatagram = onListenerDatagram;
    hosts.add(host);
    return host;
  }

  /// Every datagram sent, as `from:port -> to:port`.
  final List<String> log = [];
}

class StrictHost {
  StrictHost._(this._network, this.address, this.segment);

  final StrictBeaconNetwork _network;
  final String address;
  final String segment;

  /// What the long-lived listener on port 7668 gets.
  void Function(StrictHost host, Uint8List data, String from, int fromPort)?
  onListenerDatagram;
  final Map<int, _StrictSocket> _sockets = {};
  int get openSockets => _sockets.length;

  /// A socket bound to this host's [address] on a fresh port (the ping
  /// socket); it listens until closed.
  StrictDatagramSocket bind(String localAddress, {bool broadcast = false}) {
    if (localAddress != address) {
      throw SocketException(
        'Failed to create datagram socket (errno = 22), address = $localAddress',
      );
    }
    final port = _network._nextPort++;
    final socket = _StrictSocket(this, port, broadcast);
    _sockets[port] = socket;
    return socket;
  }

  void _deliver(Uint8List data, String from, int fromPort, int toPort) {
    if (toPort == 7668) {
      onListenerDatagram?.call(this, data, from, fromPort);
      return;
    }
    _sockets[toPort]?._controller.add((data, from, fromPort));
  }
}

/// What a ping socket looks like to the code that uses it.
abstract interface class StrictDatagramSocket {
  int get port;
  Stream<(Uint8List, String, int)> get datagrams;
  void send(List<int> bytes, String address, int port);
  void close();
}

class _StrictSocket implements StrictDatagramSocket {
  _StrictSocket(this._host, this.port, this._broadcast);

  final StrictHost _host;
  final bool _broadcast;
  final _controller = StreamController<(Uint8List, String, int)>.broadcast();

  @override
  final int port;
  bool closed = false;

  @override
  Stream<(Uint8List, String, int)> get datagrams => _controller.stream;

  @override
  void send(List<int> bytes, String address, int toPort) {
    if (closed) throw const SocketException.closed();
    final isBroadcast =
        address == '255.255.255.255' || address.endsWith('.255');
    if (isBroadcast && !_broadcast) {
      throw SocketException(
        'Broadcast is not enabled (errno = 13), address = $address',
      );
    }
    final network = _host._network;
    network.log.add('${_host.address}:$port -> $address:$toPort');
    final data = Uint8List.fromList(bytes);
    for (final other in network.hosts) {
      if (identical(other, _host) || other.segment != _host.segment) continue;
      if (isBroadcast || other.address == address) {
        other._deliver(data, _host.address, port, toPort);
      }
    }
  }

  @override
  void close() {
    closed = true;
    _host._sockets.remove(port);
    unawaited(_controller.close());
  }
}
