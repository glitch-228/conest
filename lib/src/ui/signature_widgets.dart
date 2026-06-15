import 'package:flutter/material.dart';

import '../conest_theme.dart';

/// The kinds of trust/route signal a [TrustChip] can render.
enum TrustChipKind { e2ee, lan, relay, queued, verified }

extension _TrustChipKindData on TrustChipKind {
  String get glyph => switch (this) {
    TrustChipKind.e2ee => '\u{1F512}', // 🔒
    TrustChipKind.lan => '◐', // ◐
    TrustChipKind.relay => '◑', // ◑
    TrustChipKind.queued => '◌', // ◌
    TrustChipKind.verified => '✓', // ✓
  };

  String get text => switch (this) {
    TrustChipKind.e2ee => 'E2EE',
    TrustChipKind.lan => 'LAN',
    TrustChipKind.relay => 'RELAY',
    TrustChipKind.queued => 'QUEUED',
    TrustChipKind.verified => 'VERIFIED',
  };

  Color color(ConestPalette p) => switch (this) {
    TrustChipKind.e2ee => p.primary,
    TrustChipKind.lan => p.primary,
    TrustChipKind.relay => p.secondary,
    TrustChipKind.queued => p.warning,
    TrustChipKind.verified => p.primary,
  };
}

/// Small inline trust/route indicator. [subtle] renders just the colored
/// glyph (the default app-wide); the loud variant draws the bordered mono
/// pill with a dot + label.
class TrustChip extends StatelessWidget {
  const TrustChip({
    super.key,
    required this.palette,
    required this.kind,
    this.subtle = true,
    this.label,
  });

  final ConestPalette palette;
  final TrustChipKind kind;
  final bool subtle;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = kind.color(palette);
    if (subtle) {
      return Text(
        kind.glyph,
        semanticsLabel: kind.text,
        style: TextStyle(
          color: color,
          fontFamily: ConestPalette.monoFont,
          fontSize: 11,
          height: 1,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.33)),
        borderRadius: BorderRadius.circular(ConestPalette.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            label ?? kind.text,
            style: TextStyle(
              color: color,
              fontFamily: ConestPalette.monoFont,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// `// SECTION LABEL` — the mono uppercase section header used throughout
/// settings and panels.
class MonoSectionLabel extends StatelessWidget {
  const MonoSectionLabel({
    super.key,
    required this.palette,
    required this.label,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 6),
  });

  final ConestPalette palette;
  final String label;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        '// ${label.toUpperCase()}',
        style: TextStyle(
          fontFamily: ConestPalette.monoFont,
          fontSize: 10,
          color: palette.textMuted,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

/// A bordered mono route/endpoint badge (e.g. `lan://192.168.4.21:7667`).
/// [tone] picks the accent: ok→mint, warn→amber, bad→danger.
enum RouteBadgeTone { ok, warn, bad, neutral }

class RouteBadge extends StatelessWidget {
  const RouteBadge({
    super.key,
    required this.palette,
    required this.label,
    this.tone = RouteBadgeTone.ok,
  });

  final ConestPalette palette;
  final String label;
  final RouteBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      RouteBadgeTone.ok => palette.primary,
      RouteBadgeTone.warn => palette.warning,
      RouteBadgeTone.bad => palette.danger,
      RouteBadgeTone.neutral => palette.textMuted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(ConestPalette.radiusSm),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: ConestPalette.monoFont,
          fontSize: 10,
          color: color,
        ),
      ),
    );
  }
}

/// Tiny inline trend sparkline (relay RTT / queue history). Pure CustomPaint,
/// no axes — a glanceable shape.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.data,
    required this.color,
    this.width = 48,
    this.height = 18,
    this.strokeWidth = 1.5,
  });

  final List<double> data;
  final Color color;
  final double width;
  final double height;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _SparklinePainter(
        data: data,
        color: color,
        strokeWidth: strokeWidth,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.data,
    required this.color,
    required this.strokeWidth,
  });

  final List<double> data;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final maxV = data.reduce((a, b) => a > b ? a : b);
    final denom = maxV <= 0 ? 1.0 : maxV;
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - (data[i] / denom) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.data != data || old.color != color;
}

/// The node-status strip shown atop the home screen: a glowing dot, a mono
/// `NODE · ONLINE` label, a free-form status line, and a trailing tag.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.palette,
    required this.title,
    required this.detail,
    this.dotColor,
    this.trailing = 'E2EE',
    this.margin = const EdgeInsets.fromLTRB(14, 0, 14, 10),
  });

  final ConestPalette palette;
  final String title;
  final String detail;
  final Color? dotColor;
  final String trailing;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final dot = dotColor ?? palette.primary;
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.panel2,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(ConestPalette.radius),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dot,
              shape: BoxShape.circle,
              boxShadow: palette.glow
                  ? [BoxShadow(color: dot, blurRadius: 6)]
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
                  title.toUpperCase(),
                  style: TextStyle(
                    fontFamily: ConestPalette.monoFont,
                    fontSize: 10,
                    color: palette.textMuted,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: ConestPalette.displayFont,
                    fontSize: 12,
                    color: palette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            trailing,
            style: TextStyle(
              fontFamily: ConestPalette.monoFont,
              fontSize: 10,
              color: palette.primary,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}
