import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../conest_theme.dart';

/// Visual styles for [SealAvatar]. Each is deterministically derived from a
/// seed (a contact's public key or device id) so the same peer always renders
/// the same mark.
enum SealAvatarStyle { seal, sigil, blockie, monogram }

extension SealAvatarStyleCodec on SealAvatarStyle {
  static SealAvatarStyle fromName(String? value) {
    for (final style in SealAvatarStyle.values) {
      if (style.name == value) {
        return style;
      }
    }
    return SealAvatarStyle.seal;
  }

  String get label => switch (this) {
    SealAvatarStyle.seal => 'Seal (animated rings)',
    SealAvatarStyle.sigil => 'Sigil (rune)',
    SealAvatarStyle.blockie => 'Blockie (pixel hash)',
    SealAvatarStyle.monogram => 'Monogram (initials)',
  };
}

/// FNV-1a 32-bit hash — tiny, deterministic, matches the design's `seals.jsx`
/// so avatars are stable across the prototype and the app.
int fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < input.length; i++) {
    hash ^= input.codeUnitAt(i) & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash >>> 0;
}

/// Deterministic parameters derived from a seed, mirroring `hashToParams`.
class SealParams {
  SealParams._({
    required this.h1,
    required this.hue,
    required this.teeth,
    required this.inner,
    required this.rot,
    required this.counter,
  });

  factory SealParams.fromSeed(String seed) {
    final h = fnv1a(seed);
    return SealParams._(
      h1: h,
      hue: (h % 360).toDouble(),
      teeth: 6 + (h % 7),
      inner: 3 + ((h >> 4) % 5),
      rot: (h % 360) * math.pi / 180,
      counter: (((h >> 8) % 2) == 0) ? 1 : -1,
    );
  }

  final int h1;
  final double hue;
  final int teeth;
  final int inner;
  final double rot;
  final int counter;
}

/// Animated cryptographic seal avatar. Concentric notched rings (counter-
/// rotating glyph cluster within) are the canonical Conest identity mark;
/// [style] selects alternatives. [animate] drives the rotation — keep it off
/// in dense list rows, on in chat headers and the identity strip.
class SealAvatar extends StatefulWidget {
  const SealAvatar({
    super.key,
    required this.seed,
    required this.palette,
    this.size = 44,
    this.style = SealAvatarStyle.seal,
    this.animate = false,
    this.label,
  });

  final String seed;
  final ConestPalette palette;
  final double size;
  final SealAvatarStyle style;
  final bool animate;

  /// Display name, used by the monogram style for initials.
  final String? label;

  @override
  State<SealAvatar> createState() => _SealAvatarState();
}

class _SealAvatarState extends State<SealAvatar>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  bool get _wantsAnimation =>
      widget.animate && widget.style == SealAvatarStyle.seal;

  @override
  void initState() {
    super.initState();
    if (_wantsAnimation) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 18),
      )..repeat();
    }
  }

  @override
  void didUpdateWidget(SealAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wants = _wantsAnimation;
    if (wants && _controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 18),
      )..repeat();
    } else if (!wants && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.style) {
      case SealAvatarStyle.monogram:
        return _MonogramAvatar(
          seed: widget.seed,
          size: widget.size,
          palette: widget.palette,
          label: widget.label,
        );
      case SealAvatarStyle.blockie:
        return _BlockieAvatar(
          seed: widget.seed,
          size: widget.size,
          palette: widget.palette,
        );
      case SealAvatarStyle.sigil:
        return _SigilAvatar(
          seed: widget.seed,
          size: widget.size,
          palette: widget.palette,
        );
      case SealAvatarStyle.seal:
        final params = SealParams.fromSeed(widget.seed);
        final controller = _controller;
        if (controller == null) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _RingsSealPainter(
              params: params,
              palette: widget.palette,
              t: 0,
            ),
          );
        }
        return AnimatedBuilder(
          animation: controller,
          builder: (context, _) => CustomPaint(
            size: Size.square(widget.size),
            painter: _RingsSealPainter(
              params: params,
              palette: widget.palette,
              t: controller.value,
            ),
          ),
        );
    }
  }
}

class _RingsSealPainter extends CustomPainter {
  _RingsSealPainter({
    required this.params,
    required this.palette,
    required this.t,
  });

  final SealParams params;
  final ConestPalette palette;

  /// Animation phase in [0, 1); 0 for the static (list) variant.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final s = size.width;
    final ringColor = palette.primary;
    final innerColor = palette.secondary;

    // Ambient radial halo.
    final haloRect = Rect.fromCircle(center: center, radius: s * 0.5);
    canvas.drawCircle(
      center,
      s * 0.5,
      Paint()
        ..shader = RadialGradient(
          colors: [
            palette.primary.withValues(alpha: 0.18),
            palette.primary.withValues(alpha: 0.04),
            Colors.transparent,
          ],
          stops: const [0.0, 0.6, 1.0],
        ).createShader(haloRect),
    );

    final ringR = s * 0.42;
    final tickR = s * 0.36;
    final spin = t * 2 * math.pi * params.counter;

    // Outer notched ring (rotating).
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(spin);
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.012
      ..color = ringColor.withValues(alpha: 0.9);
    canvas.drawCircle(Offset.zero, ringR, ringPaint);
    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.016
      ..strokeCap = StrokeCap.round
      ..color = ringColor;
    for (var i = 0; i < params.teeth; i++) {
      final a = (i / params.teeth) * 2 * math.pi;
      final c = math.cos(a);
      final sn = math.sin(a);
      canvas.drawLine(
        Offset(c * tickR, sn * tickR),
        Offset(c * (tickR + s * 0.06), sn * (tickR + s * 0.06)),
        tickPaint,
      );
    }
    canvas.restore();

    // Inner counter-rotating glyph cluster.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-spin);
    final glyphPaint = Paint()..color = innerColor;
    for (var i = 0; i < params.inner; i++) {
      final a = (i / params.inner) * 2 * math.pi + params.rot;
      final gx = math.cos(a) * (s * 0.18);
      final gy = math.sin(a) * (s * 0.18);
      if (i.isEven) {
        canvas.drawCircle(Offset(gx, gy), s * 0.026, glyphPaint);
      } else {
        canvas.save();
        canvas.translate(gx, gy);
        canvas.rotate(math.pi / 4);
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: s * 0.04,
            height: s * 0.04,
          ),
          glyphPaint,
        );
        canvas.restore();
      }
    }
    canvas.restore();

    // Center dot.
    canvas.drawCircle(center, s * 0.024, Paint()..color = ringColor);
  }

  @override
  bool shouldRepaint(_RingsSealPainter old) =>
      old.t != t || old.params.h1 != params.h1 || old.palette != palette;
}

class _SigilAvatar extends StatelessWidget {
  const _SigilAvatar({
    required this.seed,
    required this.size,
    required this.palette,
  });

  final String seed;
  final double size;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SigilPainter(seed: seed, palette: palette),
    );
  }
}

class _SigilPainter extends CustomPainter {
  _SigilPainter({required this.seed, required this.palette});

  final String seed;
  final ConestPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final h = fnv1a(seed);
    final bits = List<bool>.generate(8, (i) => ((h >> i) & 1) == 1);
    final u = size.width / 100;
    Offset pt(double x, double y) => Offset(x * u, y * u);

    canvas.drawRect(
      Rect.fromLTWH(3 * u, 3 * u, 94 * u, 94 * u),
      Paint()..color = palette.panel2,
    );
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = u
      ..color = palette.primary;
    canvas.drawRect(Rect.fromLTWH(3 * u, 3 * u, 94 * u, 94 * u), border);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * u
      ..strokeCap = StrokeCap.round
      ..color = palette.primary;
    if (bits[0]) canvas.drawLine(pt(25, 25), pt(75, 25), stroke);
    if (bits[1]) canvas.drawLine(pt(50, 20), pt(50, 80), stroke);
    if (bits[2]) canvas.drawLine(pt(25, 75), pt(75, 75), stroke);
    if (bits[3]) canvas.drawLine(pt(25, 25), pt(75, 75), stroke);
    if (bits[4]) canvas.drawLine(pt(75, 25), pt(25, 75), stroke);
    if (bits[5]) canvas.drawCircle(pt(50, 50), 14 * u, stroke);
    if (bits[6]) canvas.drawLine(pt(20, 50), pt(80, 50), stroke);
    if (bits[7]) {
      canvas.drawCircle(pt(50, 50), 5 * u, Paint()..color = palette.secondary);
    }
  }

  @override
  bool shouldRepaint(_SigilPainter old) =>
      old.seed != seed || old.palette != palette;
}

class _BlockieAvatar extends StatelessWidget {
  const _BlockieAvatar({
    required this.seed,
    required this.size,
    required this.palette,
  });

  final String seed;
  final double size;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ConestPalette.radiusSm),
      child: CustomPaint(
        size: Size.square(size),
        painter: _BlockiePainter(seed: seed, palette: palette),
      ),
    );
  }
}

class _BlockiePainter extends CustomPainter {
  _BlockiePainter({required this.seed, required this.palette});

  final String seed;
  final ConestPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.panel2);
    const grid = 5;
    final cell = size.width / grid;
    var h = fnv1a(seed);
    for (var y = 0; y < grid; y++) {
      for (var x = 0; x < (grid / 2).ceil(); x++) {
        h = (h * 1103515245 + 12345) & 0x7fffffff;
        final on = (h & 7) > 3;
        if (!on) continue;
        final color = (x + y) % 3 == 0 ? palette.secondary : palette.primary;
        final paint = Paint()..color = color;
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
        canvas.drawRect(
          Rect.fromLTWH((grid - 1 - x) * cell, y * cell, cell, cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BlockiePainter old) =>
      old.seed != seed || old.palette != palette;
}

class _MonogramAvatar extends StatelessWidget {
  const _MonogramAvatar({
    required this.seed,
    required this.size,
    required this.palette,
    this.label,
  });

  final String seed;
  final double size;
  final ConestPalette palette;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final source = (label ?? seed).trim();
    final initials = source.isEmpty
        ? '?'
        : source
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty)
              .take(2)
              .map((w) => w.characters.first)
              .join()
              .toUpperCase();
    final params = SealParams.fromSeed(seed);
    final hsl = HSLColor.fromAHSL(1, params.hue, 0.7, 0.3);
    final hsl2 = HSLColor.fromAHSL(1, (params.hue + 60) % 360, 0.7, 0.18);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [hsl.toColor(), hsl2.toColor()],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: palette.primary, width: 1.5),
      ),
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.38,
          fontFamily: ConestPalette.displayFont,
        ),
      ),
    );
  }
}
