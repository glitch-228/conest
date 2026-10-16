import '../app_locales.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import '../connection_map.dart';
import '../messenger_controller.dart';
import '../network_history.dart';

/// How much a report's age fades it: fully seen when fresh, faint after
/// a week (when it is dropped).
double _ageOpacity(DateTime at, DateTime now) {
  final hours = now.difference(at).inMinutes / 60;
  return (1 - hours / (7 * 24)).clamp(0.25, 1.0);
}

String _when(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Settings → Connectivity → Connections (Advanced): who reaches whom —
/// this device's links, and what the devices it knows report of theirs.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key, required this.controller});

  final MessengerController controller;

  static Future<void> show(
    BuildContext context,
    MessengerController controller,
  ) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ConnectionsScreen(controller: controller),
    ),
  );

  static String label(LinkStatus status, [BuildContext? context]) =>
      switch (status) {
        LinkStatus.twoWay => l10nOf(context).connectionsBothWays,
        LinkStatus.inboundOnly => l10nOf(context).connectionsInbound,
        LinkStatus.failing => l10nOf(context).connectionsFailing,
        LinkStatus.unknown => l10nOf(context).connectionsUnknown,
      };

  static Color colorOf(LinkStatus status, ColorScheme scheme) =>
      switch (status) {
        LinkStatus.twoWay => Colors.green,
        LinkStatus.inboundOnly => Colors.orange,
        LinkStatus.failing => scheme.error,
        LinkStatus.unknown => scheme.outline,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10nOf(context).connectionsTitle)),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final map = controller.connectionMap;
          final mine = map.mine.entries.toList()
            ..sort((a, b) => a.value.index.compareTo(b.value.index));
          return ListView(
            key: const ValueKey('connections-list'),
            padding: const EdgeInsets.all(16),
            children: [
              SizedBox(
                height: 280,
                child: CustomPaint(
                  painter: _MapPainter(map, scheme),
                  child: const SizedBox.expand(),
                ),
              ),
              Wrap(
                spacing: 12,
                children: [
                  for (final status in LinkStatus.values)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.circle,
                          size: 10,
                          color: colorOf(status, scheme),
                        ),
                        const SizedBox(width: 4),
                        Text(label(status, context)),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                l10nOf(context).uiThisDeviceFA5A6D,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final MapEntry(key: id, value: status) in mine)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.circle, color: colorOf(status, scheme)),
                  title: Text(map.nameOf(id)),
                  trailing: Text(label(status, context)),
                ),
              for (final MapEntry(key: reporter, value: links)
                  in map.reported.entries)
                if (links.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'As ${map.nameOf(reporter)} sees it',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final MapEntry(key: id, value: link) in links.entries)
                    Opacity(
                      opacity: _ageOpacity(link.at, DateTime.now()),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.circle,
                          color: colorOf(link.status, scheme),
                        ),
                        title: Text(map.nameOf(id)),
                        subtitle: Text(
                          l10nOf(context).connectionsAsOf(_when(link.at)),
                        ),
                        trailing: Text(label(link.status, context)),
                      ),
                    ),
                ],
              _NetworksSection(history: controller.networkHistory),
            ],
          );
        },
      ),
    );
  }
}

/// Every network this device remembers, and how each route fared there.
class _NetworksSection extends StatelessWidget {
  const _NetworksSection({required this.history});

  final NetworkHistory history;

  @override
  Widget build(BuildContext context) {
    final networks = history.networks;
    if (networks.isEmpty) return const SizedBox.shrink();
    final strings = l10nOf(context);
    final scheme = Theme.of(context).colorScheme;
    final current = history.current;
    final blocked = history.blockedHere();
    return Column(
      key: const ValueKey('connections-networks'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(
          strings.connectionsNetworks,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        for (final network in networks)
          ExpansionTile(
            initiallyExpanded: identical(network, current),
            leading: Icon(switch (network.kind) {
              'wifi' => Icons.wifi,
              'ethernet' => Icons.settings_ethernet,
              'mobile' => Icons.signal_cellular_alt,
              'bluetooth' => Icons.bluetooth,
              'vpn' => Icons.vpn_lock,
              _ => Icons.lan_outlined,
            }),
            title: Text(network.label),
            subtitle: Text(
              identical(network, current)
                  ? strings.connectionsNetworkNow
                  : strings.connectionsNetworkLastSeen(_when(network.lastSeen)),
            ),
            children: [
              for (final MapEntry(key: route, value: outcome)
                  in network.routes.entries)
                ListTile(
                  dense: true,
                  title: Text(route),
                  trailing: Text(
                    identical(network, current) && blocked.contains(route)
                        ? strings.connectionsRouteBlocked
                        : outcome.lastWorked != null &&
                              (outcome.lastFailed == null ||
                                  outcome.lastWorked!.isAfter(
                                    outcome.lastFailed!,
                                  ))
                        ? strings.connectionsRouteWorks
                        : strings.connectionsRouteFailing,
                    style: TextStyle(
                      color:
                          identical(network, current) && blocked.contains(route)
                          ? scheme.error
                          : null,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// The devices on a circle around this one, with a line for each link.
class _MapPainter extends CustomPainter {
  _MapPainter(this.map, this.scheme);

  final ConnectionMap map;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final others = map.devices.where((id) => id != map.self).toList()..sort();
    final center = size.center(Offset.zero);
    final radius = min(size.width, size.height) / 2 - 28;
    final at = <String, Offset>{map.self: center};
    for (var i = 0; i < others.length; i++) {
      final angle = 2 * pi * i / max(others.length, 1) - pi / 2;
      at[others[i]] = center + Offset(cos(angle), sin(angle)) * radius;
    }
    void line(
      String from,
      String to,
      LinkStatus status, {
      bool dashed = false,
      double fade = 1,
    }) {
      final a = at[from], b = at[to];
      if (a == null || b == null) return;
      final paint = Paint()
        ..color = ConnectionsScreen.colorOf(
          status,
          scheme,
        ).withValues(alpha: (dashed ? 0.5 : 0.9) * fade)
        ..strokeWidth = dashed ? 1.5 : 3;
      canvas.drawLine(a, b, paint);
    }

    for (final MapEntry(key: reporter, value: links) in map.reported.entries) {
      for (final MapEntry(key: id, value: link) in links.entries) {
        line(
          reporter,
          id,
          link.status,
          dashed: true,
          fade: _ageOpacity(link.at, DateTime.now()),
        );
      }
    }
    for (final MapEntry(key: id, value: status) in map.mine.entries) {
      line(map.self, id, status);
    }
    for (final MapEntry(key: id, value: point) in at.entries) {
      canvas.drawCircle(
        point,
        id == map.self ? 10 : 7,
        Paint()..color = id == map.self ? scheme.primary : scheme.secondary,
      );
      // Too many to name readably: the list below names them.
      if (at.length > 13 && id != map.self) continue;
      final name = map.nameOf(id);
      final text = TextPainter(
        text: TextSpan(
          text: name.length > 14 ? '${name.substring(0, 13)}…' : name,
          style: TextStyle(color: scheme.onSurface, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, point + Offset(-text.width / 2, 10));
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) => old.map != map || old.scheme != scheme;
}
