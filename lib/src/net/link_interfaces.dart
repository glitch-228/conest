import 'dart:io';

import '../local_relay_node.dart'
    show isIgnoredLanInterfaceName, isLanDiscoveryAddress;
import 'link_scope.dart';

export 'link_scope.dart';

/// What a network interface is, judged by its name only. It decides labels
/// and which links get a ping; [isIgnoredLanInterfaceName] stays the only
/// filter that keeps an interface out.
enum LinkKind { cable, wifi, other }

/// One interface as the system lists it (a seam for tests: the real
/// listing is [systemInterfaceSource]).
class RawInterface {
  const RawInterface({
    required this.name,
    required this.index,
    required this.addresses,
  });

  final String name;
  final int index;
  final List<String> addresses;
}

/// The system's interface listing. Like `NetworkInterface.list`, it leaves
/// out link-local addresses (169.254/16, fe80::/10) unless asked, and an
/// interface with no address left does not appear.
typedef RawInterfaceSource =
    Future<List<RawInterface>> Function({required bool includeLinkLocal});

/// An interface a LAN peer can be on: up, not virtual or a VPN, with at
/// least one private or link-local IPv4 address.
class LinkInterface {
  const LinkInterface({
    required this.name,
    required this.index,
    required this.kind,
    required this.v4,
  });

  final String name;
  final int index;
  final LinkKind kind;

  /// Its private and link-local IPv4 addresses, sorted.
  final List<String> v4;

  /// Whether a peer found here is worth a ping and a link entry: a wired or
  /// USB interface, or any interface that only has link-local addresses to
  /// offer (no DHCP).
  bool get pingable =>
      kind == LinkKind.cable || v4.any((a) => isLinkScopedHost(a));
}

/// The kind of an interface from its name (Linux, Windows and Android
/// names): `usb0`, `rndis0`, `ncm0`, `enx<mac>`, `enp0s20f0u2`, `eth0`,
/// `Ethernet 3`, `Remote NDIS based Internet Sharing Device` are cables;
/// `wlan0`, `wlp3s0`, `swlan0`, `ap0`, `Wi-Fi` are Wi-Fi.
LinkKind classifyLinkInterface(String name) {
  final n = name.toLowerCase();
  if (RegExp(r'^(wl|swlan|ap\d|wi-?fi|wireless)').hasMatch(n)) {
    return LinkKind.wifi;
  }
  if (RegExp(
    r'^(usb|rndis|ncm|eth\d|en[a-z0-9]|ethernet|local area connection|remote ndis)',
  ).hasMatch(n)) {
    return LinkKind.cable;
  }
  return LinkKind.other;
}

/// The real interface listing: IPv4 only for now.
Future<List<RawInterface>> systemInterfaceSource({
  required bool includeLinkLocal,
}) async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: includeLinkLocal,
      type: InternetAddressType.IPv4,
    );
    return [
      for (final interface in interfaces)
        RawInterface(
          name: interface.name,
          index: interface.index,
          addresses: [for (final a in interface.addresses) a.address],
        ),
    ];
  } on SocketException {
    return const <RawInterface>[];
  } on OSError {
    return const <RawInterface>[];
  }
}

/// The interfaces a peer can be on, link-local addresses included.
Future<List<LinkInterface>> listLinkInterfaces({
  RawInterfaceSource source = systemInterfaceSource,
}) async {
  final raw = await source(includeLinkLocal: true);
  final links = <LinkInterface>[];
  for (final interface in raw) {
    if (isIgnoredLanInterfaceName(interface.name)) continue;
    final v4 = <String>{
      for (final a in interface.addresses)
        if (InternetAddress.tryParse(a)?.type == InternetAddressType.IPv4 &&
            isLanDiscoveryAddress(a))
          a,
    }.toList()..sort();
    if (v4.isEmpty) continue;
    links.add(
      LinkInterface(
        name: interface.name,
        index: interface.index,
        kind: classifyLinkInterface(interface.name),
        v4: v4,
      ),
    );
  }
  links.sort((a, b) => a.index.compareTo(b.index));
  return links;
}
