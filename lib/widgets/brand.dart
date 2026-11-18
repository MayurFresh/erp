import 'package:flutter/material.dart';

/// The OneMatrix mark: a rounded square holding a 3 by 3 grid with the
/// diagonal filled, the identity matrix ("ones on the diagonal"). Drawn in
/// code so it scales and follows the theme.
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
    // Grid of 3 cells, 17 units each with 6 unit gaps, centred: 63 units.
    const cell = 17.0, gap = 6.0, start = (100 - (cell * 3 + gap * 2)) / 2;
    final on = Paint()..color = foreground;
    final off = Paint()..color = foreground.withValues(alpha: foreground.a * 0.3);
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        final r = Rect.fromLTWH(
          tile.left + (start + col * (cell + gap)) * u,
          tile.top + (start + row * (cell + gap)) * u,
          cell * u,
          cell * u,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, Radius.circular(3 * u)),
          row == col ? on : off,
        );
      }
    }
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
      label: 'OneMatrix',
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

/// Mark plus the word "OneMatrix".
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
          'OneMatrix',
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
