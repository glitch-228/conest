import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../conest_theme.dart';
import 'signature_widgets.dart';

/// Circular countdown for the rotating pairing codephrase. A mint progress
/// arc drains over the rotation window with tick marks every 1/12 turn; the
/// codephrase and a mono "ROTATES IN Ns" sit in the center.
class CodephraseRing extends StatelessWidget {
  const CodephraseRing({
    super.key,
    required this.palette,
    required this.codephrase,
    required this.secondsRemaining,
    this.totalSeconds = 120,
    this.size = 220,
  });

  final ConestPalette palette;
  final String codephrase;
  final int secondsRemaining;
  final int totalSeconds;
  final double size;

  @override
  Widget build(BuildContext context) {
    final pct = totalSeconds <= 0
        ? 0.0
        : (secondsRemaining / totalSeconds).clamp(0.0, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _CodephraseRingPainter(palette: palette, fraction: pct),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: size * 0.16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'CODEPHRASE',
                  style: TextStyle(
                    fontFamily: ConestPalette.monoFont,
                    fontSize: 10,
                    letterSpacing: 2,
                    color: palette.textMuted,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  codephrase,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: ConestPalette.displayFont,
                    fontSize: size * 0.085,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'ROTATES IN ${secondsRemaining}s',
                  style: TextStyle(
                    fontFamily: ConestPalette.monoFont,
                    fontSize: 11,
                    letterSpacing: 1,
                    color: palette.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CodephraseRingPainter extends CustomPainter {
  _CodephraseRingPainter({required this.palette, required this.fraction});

  final ConestPalette palette;
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = (size.width - 14) / 2;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = palette.border,
    );
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = palette.primary;
    if (palette.glow) {
      arc.maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      arc,
    );
    final tick = Paint()
      ..strokeWidth = 1
      ..color = palette.textMuted.withValues(alpha: 0.4);
    for (var i = 0; i < 12; i++) {
      final a = (i / 12) * 2 * math.pi;
      final c = math.cos(a);
      final s = math.sin(a);
      canvas.drawLine(
        center + Offset(c * (r - 6), s * (r - 6)),
        center + Offset(c * (r + 1), s * (r + 1)),
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(_CodephraseRingPainter old) =>
      old.fraction != fraction || old.palette != palette;
}

/// A reachability route the inspector can draw. `active` highlights the path
/// currently carrying traffic; null [rtt] means the route is unverified/down.
class RouteInspectorPath {
  const RouteInspectorPath({
    required this.label,
    required this.detail,
    required this.color,
    required this.active,
    this.available = true,
  });

  final String label;
  final String detail;
  final Color color;
  final bool active;
  final bool available;
}

/// LAN-vs-relay path visualization between YOU and a PEER. Static (no
/// animation) so it's cheap to drop into a chat header; the active path is
/// solid + colored, inactive paths are dashed/dim.
class RouteInspector extends StatelessWidget {
  const RouteInspector({
    super.key,
    required this.palette,
    required this.paths,
    this.note,
  });

  final ConestPalette palette;
  final List<RouteInspectorPath> paths;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.panel2,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(ConestPalette.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'ROUTE INSPECTOR',
                style: TextStyle(
                  fontFamily: ConestPalette.monoFont,
                  fontSize: 11,
                  letterSpacing: 1.5,
                  color: palette.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                '● LIVE',
                style: TextStyle(
                  fontFamily: ConestPalette.monoFont,
                  fontSize: 10,
                  color: palette.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 92,
            width: double.infinity,
            child: CustomPaint(
              painter: _RouteInspectorPainter(palette: palette, paths: paths),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final p in paths) ...[
                _RouteChip(palette: palette, path: p),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              if (note != null)
                Text(
                  note!,
                  style: TextStyle(
                    fontFamily: ConestPalette.monoFont,
                    fontSize: 10,
                    color: palette.textMuted,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RouteChip extends StatelessWidget {
  const _RouteChip({required this.palette, required this.path});

  final ConestPalette palette;
  final RouteInspectorPath path;

  @override
  Widget build(BuildContext context) {
    final color = path.active ? path.color : palette.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: path.active
            ? path.color.withValues(alpha: 0.13)
            : Colors.transparent,
        border: Border.all(color: path.active ? path.color : palette.border),
        borderRadius: BorderRadius.circular(ConestPalette.radiusSm),
      ),
      child: Text(
        path.label,
        style: TextStyle(
          fontFamily: ConestPalette.monoFont,
          fontSize: 10,
          letterSpacing: 1,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _RouteInspectorPainter extends CustomPainter {
  _RouteInspectorPainter({required this.palette, required this.paths});

  final ConestPalette palette;
  final List<RouteInspectorPath> paths;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final midY = size.height / 2;
    final youCenter = Offset(28, midY);
    final peerCenter = Offset(w - 28, midY);

    // Distribute paths vertically as curved arcs between the two nodes.
    final count = paths.length;
    for (var i = 0; i < count; i++) {
      final p = paths[i];
      final t = count == 1 ? 0.5 : i / (count - 1);
      // peak offset from -34..34 around the midline
      final peak = (t - 0.5) * 68;
      final ctrl = Offset(w / 2, midY + peak);
      final path = Path()
        ..moveTo(youCenter.dx + 16, midY)
        ..quadraticBezierTo(
          ctrl.dx,
          midY + peak * 1.6,
          peerCenter.dx - 16,
          midY,
        );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = p.active ? 2.5 : 1.5
        ..color = p.active
            ? p.color
            : (p.available ? palette.border : palette.border);
      if (p.active && palette.glow) {
        paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      }
      if (!p.active) {
        // dashed for inactive
        _drawDashed(canvas, path, paint);
      } else {
        canvas.drawPath(path, paint);
      }
      // label above/below the arc peak
      final tp = TextPainter(
        text: TextSpan(
          text: '${p.label} · ${p.detail}',
          style: TextStyle(
            fontFamily: ConestPalette.monoFont,
            fontSize: 9,
            color: p.active ? p.color : palette.textMuted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: w - 40);
      final labelY = peak <= 0 ? midY + peak * 1.6 - 14 : midY + peak * 1.6 + 4;
      tp.paint(canvas, Offset((w - tp.width) / 2, labelY));
    }

    // nodes
    _node(canvas, youCenter, 'YOU', palette.primary);
    _node(canvas, peerCenter, 'PEER', palette.secondary);
  }

  void _node(Canvas canvas, Offset center, String label, Color ring) {
    canvas.drawCircle(center, 14, Paint()..color = palette.panel3);
    canvas.drawCircle(
      center,
      14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ring,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontFamily: ConestPalette.monoFont,
          fontSize: 9,
          color: palette.textPrimary,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawDashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + 4;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + 3;
      }
    }
  }

  @override
  bool shouldRepaint(_RouteInspectorPainter old) =>
      old.paths != paths || old.palette != palette;
}

/// Health row for one relay: status dot, host, mono detail line, and a trend
/// [Sparkline]. Pair with [RelayStat] tiles for the aggregate strip.
class RelayHealthRow extends StatelessWidget {
  const RelayHealthRow({
    super.key,
    required this.palette,
    required this.host,
    required this.detail,
    required this.statusColor,
    required this.spark,
  });

  final ConestPalette palette;
  final String host;
  final String detail;
  final Color statusColor;
  final List<double> spark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: palette.glow
                  ? [BoxShadow(color: statusColor, blurRadius: 8)]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: ConestPalette.displayFont,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: ConestPalette.monoFont,
                    fontSize: 10,
                    color: palette.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (spark.length >= 2)
            Sparkline(data: spark, color: statusColor, width: 48, height: 18),
        ],
      ),
    );
  }
}

/// One big-number tile in the relay aggregate strip (OK / WARN / DOWN / RTT).
class RelayStat extends StatelessWidget {
  const RelayStat({
    super.key,
    required this.palette,
    required this.label,
    required this.value,
    required this.color,
  });

  final ConestPalette palette;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontFamily: ConestPalette.displayFont,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontFamily: ConestPalette.monoFont,
            fontSize: 9,
            letterSpacing: 1,
            color: palette.textMuted,
          ),
        ),
      ],
    );
  }
}

/// A node in the group [TrustMap].
class TrustMapNode {
  const TrustMapNode({required this.label, required this.trusted});

  final String label;
  final bool trusted;
}

/// Group fanout visualization: YOU at the center, members on a ring, mint
/// edges to trusted members and a faint pink hull between adjacent trusted
/// members. Untrusted/pending members are dim + dashed.
class TrustMap extends StatelessWidget {
  const TrustMap({
    super.key,
    required this.palette,
    required this.members,
    this.size = 240,
  });

  final ConestPalette palette;
  final List<TrustMapNode> members;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TrustMapPainter(palette: palette, members: members),
      ),
    );
  }
}

class _TrustMapPainter extends CustomPainter {
  _TrustMapPainter({required this.palette, required this.members});

  final ConestPalette palette;
  final List<TrustMapNode> members;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width * 0.34;
    final n = members.length;
    if (n == 0) {
      _node(canvas, center, 'YOU', palette.primary, filled: false);
      return;
    }
    final positions = <Offset>[];
    for (var i = 0; i < n; i++) {
      final a = (i / n) * 2 * math.pi - math.pi / 2;
      positions.add(center + Offset(math.cos(a) * r, math.sin(a) * r));
    }
    // edges: center → each member
    for (var i = 0; i < n; i++) {
      final trusted = members[i].trusted;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = trusted ? 1.4 : 1
        ..color = (trusted ? palette.primary : palette.border).withValues(
          alpha: trusted ? 0.9 : 0.5,
        );
      if (trusted) {
        canvas.drawLine(center, positions[i], paint);
      } else {
        _dashedLine(canvas, center, positions[i], paint);
      }
    }
    // faint hull between adjacent trusted members
    final hull = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = palette.secondary.withValues(alpha: 0.4);
    for (var i = 0; i < n; i++) {
      final a = members[i];
      final b = members[(i + 1) % n];
      if (a.trusted && b.trusted) {
        canvas.drawLine(positions[i], positions[(i + 1) % n], hull);
      }
    }
    // member nodes
    for (var i = 0; i < n; i++) {
      final m = members[i];
      _memberNode(canvas, positions[i], m, palette);
    }
    // center YOU node on top
    _node(canvas, center, 'YOU', palette.primary, filled: false);
  }

  void _node(
    Canvas canvas,
    Offset center,
    String label,
    Color ring, {
    required bool filled,
  }) {
    canvas.drawCircle(center, 14, Paint()..color = palette.panel3);
    canvas.drawCircle(
      center,
      14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ring,
    );
    _label(canvas, center, label, palette.textPrimary);
  }

  void _memberNode(
    Canvas canvas,
    Offset center,
    TrustMapNode m,
    ConestPalette p,
  ) {
    canvas.drawCircle(
      center,
      10,
      Paint()..color = m.trusted ? p.primary : p.panel3,
    );
    canvas.drawCircle(
      center,
      10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = m.trusted ? p.primary : p.borderStrong,
    );
    _label(
      canvas,
      center,
      m.label,
      m.trusted ? p.onPrimary : p.textPrimary,
      size: 8,
    );
  }

  void _label(
    Canvas canvas,
    Offset center,
    String text,
    Color color, {
    double size = 9,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: ConestPalette.monoFont,
          fontSize: size,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    final total = (b - a).distance;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final start = a + dir * d;
      final end = a + dir * math.min(d + 4, total);
      canvas.drawLine(start, end, paint);
      d += 7;
    }
  }

  @override
  bool shouldRepaint(_TrustMapPainter old) =>
      old.members != members || old.palette != palette;
}
