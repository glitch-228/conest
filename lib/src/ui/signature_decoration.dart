import 'package:flutter/material.dart';

import '../conest_theme.dart';

/// The Signature ambient overlay — the distilled synthesis of the five design
/// "worlds": a faint grid + scanlines (dark/black only), Sci-Fi corner
/// reticles, a left-edge tick rail, and a small mono status readout. Purely
/// decorative and non-interactive; drop it behind screen content via
/// `Positioned.fill` inside a `Stack`.
///
/// [intensity] follows the prototype's Decoration tweak: 0 = clean, 1 = the
/// subtle default, up to 1.5 = full atmosphere. Light tier skips scanlines and
/// glow-heavy passes (they read as muddy on cream).
class SignatureDecoration extends StatelessWidget {
  const SignatureDecoration({
    super.key,
    required this.palette,
    this.intensity = 1.0,
    this.readout = 'LINK·OK · E2EE ✓',
    this.showReadout = true,
  });

  final ConestPalette palette;
  final double intensity;
  final String readout;
  final bool showReadout;

  @override
  Widget build(BuildContext context) {
    if (intensity <= 0.05) {
      return const SizedBox.shrink();
    }
    final isLight = palette.tier == SignatureBrightness.light;
    final baseI = intensity.clamp(0.0, 1.5);
    final readoutOpacity = (0.55 * baseI).clamp(0.0, 1.0);
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _SignatureDecoPainter(
                palette: palette,
                intensity: baseI,
              ),
            ),
          ),
          if (showReadout)
            Positioned(
              right: 14,
              bottom: 14,
              child: Opacity(
                opacity: readoutOpacity,
                child: Text(
                  readout,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: ConestPalette.monoFont,
                    fontSize: 8,
                    height: 1.4,
                    letterSpacing: 0.5,
                    color: isLight ? palette.textMuted : palette.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SignatureDecoPainter extends CustomPainter {
  _SignatureDecoPainter({required this.palette, required this.intensity});

  final ConestPalette palette;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final tier = palette.tier;
    final isLight = tier == SignatureBrightness.light;
    final isBlack = tier == SignatureBrightness.black;
    final i = intensity;

    // ── faded grid (40px), edges dimmed via a centered radial alpha ──
    final gridOp = (isLight ? 0.04 : (isBlack ? 0.05 : 0.06)) * i;
    if (gridOp > 0.002) {
      final gridColor = (isLight ? Colors.black : palette.primary).withValues(
        alpha: gridOp.clamp(0.0, 1.0),
      );
      final gridPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = gridColor;
      const step = 40.0;
      for (var x = 0.0; x <= size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      }
      for (var y = 0.0; y <= size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      }
    }

    // ── scanlines (dark/black only), 1px line every 3px ──
    if (!isLight) {
      final scanOp = (isBlack ? 0.025 : 0.035) * i;
      if (scanOp > 0.002) {
        final scanPaint = Paint()
          ..strokeWidth = 1
          ..color = palette.primary.withValues(alpha: scanOp.clamp(0.0, 1.0));
        for (var y = 0.0; y < size.height; y += 3) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), scanPaint);
        }
      }
    }

    // ── corner reticles (Sci-Fi L-brackets) ──
    final reticleOp = ((isLight ? 0.55 : 0.75) * i).clamp(0.0, 1.0);
    final reticlePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = palette.primary.withValues(alpha: reticleOp);
    const inset = 8.0;
    const arm = 12.0;
    final tl = Offset(inset, inset);
    final tr = Offset(size.width - inset, inset);
    final bl = Offset(inset, size.height - inset);
    final br = Offset(size.width - inset, size.height - inset);
    canvas.drawPath(
      Path()
        ..moveTo(tl.dx, tl.dy + arm)
        ..lineTo(tl.dx, tl.dy)
        ..lineTo(tl.dx + arm, tl.dy),
      reticlePaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(tr.dx - arm, tr.dy)
        ..lineTo(tr.dx, tr.dy)
        ..lineTo(tr.dx, tr.dy + arm),
      reticlePaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(bl.dx, bl.dy - arm)
        ..lineTo(bl.dx, bl.dy)
        ..lineTo(bl.dx + arm, bl.dy),
      reticlePaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(br.dx - arm, br.dy)
        ..lineTo(br.dx, br.dy)
        ..lineTo(br.dx, br.dy - arm),
      reticlePaint,
    );

    // ── left-edge tick rail (middle 44% of height) ──
    final railOp = (0.55 * i).clamp(0.0, 1.0);
    final railPaint = Paint()
      ..strokeWidth = 1
      ..color = palette.primary.withValues(
        alpha: (railOp * 0.55).clamp(0.0, 1.0),
      );
    final railTop = size.height * 0.28;
    final railBottom = size.height * 0.72;
    for (var y = railTop; y < railBottom; y += 12) {
      canvas.drawLine(Offset(0, y), Offset(10, y), railPaint);
    }
  }

  @override
  bool shouldRepaint(_SignatureDecoPainter old) =>
      old.intensity != intensity || old.palette != palette;
}
