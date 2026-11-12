import 'package:flutter/material.dart';

/// The Progen mark: a rounded square holding a "P" built from a stem and a
/// bowl, with a short ledger rule under the bowl. Drawn in code so it scales
/// and follows the theme.
class LogoMarkPainter extends CustomPainter {
  const LogoMarkPainter({
    required this.background,
    required this.foreground,
    this.inset = 0,
    this.cornerRatio = 0.22,
  });

  final Color background;
  final Color foreground;

  /// Fraction of the canvas left empty around the mark (for maskable icons,
  /// where the platform crops the outside).
  final double inset;
  final double cornerRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final side = s * (1 - inset * 2);
    final tile = Rect.fromLTWH(s * inset, s * inset, side, side);
    if (background.a > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(tile, Radius.circular(side * cornerRatio)),
        Paint()..color = background,
      );
    }
    final u = side / 100;
    final o = tile.topLeft;
    Offset p(double x, double y) => o + Offset(x * u, y * u);
    final stroke = Paint()
      ..color = foreground
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11 * u
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter;
    // Stem.
    canvas.drawLine(p(35, 24), p(35, 78), stroke);
    // Bowl.
    final bowl = Path()
      ..moveTo(p(29.5, 29.5).dx, p(29.5, 29.5).dy)
      ..lineTo(p(54, 29.5).dx, p(54, 29.5).dy)
      ..arcToPoint(
        p(54, 55),
        radius: Radius.circular(12.75 * u),
        clockwise: true,
      )
      ..lineTo(p(35, 55).dx, p(35, 55).dy);
    canvas.drawPath(bowl, stroke);
    // Ledger rule.
    canvas.drawRect(
      Rect.fromPoints(p(50, 71), p(72, 78)),
      Paint()..color = foreground,
    );
  }

  @override
  bool shouldRepaint(LogoMarkPainter old) =>
      old.background != background ||
      old.foreground != foreground ||
      old.inset != inset;
}

class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 32, this.background, this.foreground});

  final double size;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Progen',
      child: CustomPaint(
        size: Size.square(size),
        painter: LogoMarkPainter(
          background: background ?? scheme.primary,
          foreground: foreground ?? scheme.onPrimary,
        ),
      ),
    );
  }
}

/// Mark plus the word "Progen".
class Wordmark extends StatelessWidget {
  const Wordmark({
    super.key,
    this.size = 28,
    this.color,
    this.markBackground,
    this.markForeground,
  });

  final double size;
  final Color? color;
  final Color? markBackground;
  final Color? markForeground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LogoMark(
          size: size,
          background: markBackground,
          foreground: markForeground,
        ),
        SizedBox(width: size * 0.32),
        Text(
          'Progen',
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: size * 0.68,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: color ?? theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
