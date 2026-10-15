import 'dart:math';

import 'package:flutter/material.dart';

import '../connection_map.dart';
import '../messenger_controller.dart';

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

  static String label(LinkStatus status) => switch (status) {
    LinkStatus.twoWay => 'both ways',
    LinkStatus.inboundOnly => 'only from them',
    LinkStatus.failing => 'failing',
    LinkStatus.unknown => 'no recent word',
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
      appBar: AppBar(title: const Text('Connections')),
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
                        Text(label(status)),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'This device',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final MapEntry(key: id, value: status) in mine)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.circle, color: colorOf(status, scheme)),
                  title: Text(map.nameOf(id)),
                  trailing: Text(label(status)),
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
                    ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.circle,
                        color: colorOf(link.status, scheme),
                      ),
                      title: Text(map.nameOf(id)),
                      trailing: Text(label(link.status)),
                    ),
                ],
            ],
          );
        },
      ),
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
    }) {
      final a = at[from], b = at[to];
      if (a == null || b == null) return;
      final paint = Paint()
        ..color = ConnectionsScreen.colorOf(
          status,
          scheme,
        ).withValues(alpha: dashed ? 0.5 : 0.9)
        ..strokeWidth = dashed ? 1.5 : 3;
      canvas.drawLine(a, b, paint);
    }

    for (final MapEntry(key: reporter, value: links) in map.reported.entries) {
      for (final MapEntry(key: id, value: link) in links.entries) {
        line(reporter, id, link.status, dashed: true);
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
  bool shouldRepaint(_MapPainter old) => true;
}
