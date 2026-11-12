import 'package:flutter/material.dart';

import '../core/app_colors.dart';

enum IllustrationKind {
  documents,
  stock,
  parties,
  site,
  search,
  ledger,
  calendar,
  sales,
}

/// Original line drawings (no raster assets). Strokes use the theme's muted
/// text colour; one accent stroke uses the brand colour.
class Illustration extends StatelessWidget {
  const Illustration(this.kind, {super.key, this.width = 168});

  final IllustrationKind kind;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(width, width * 0.72),
        painter: IllustrationPainter(
          kind,
          line: scheme.outline,
          accent: scheme.primary,
          fill: context.colors.neutralContainer,
        ),
      ),
    );
  }
}

class IllustrationPainter extends CustomPainter {
  IllustrationPainter(
    this.kind, {
    required this.line,
    required this.accent,
    required this.fill,
  });

  final IllustrationKind kind;
  final Color line;
  final Color accent;
  final Color fill;

  // Drawn on a 200 x 144 grid.
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 200, size.height / 144);
    final l = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final a = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final f = Paint()..color = fill;
    // Ground line shared by all drawings.
    canvas.drawLine(const Offset(16, 128), const Offset(184, 128), l);

    RRect box(double x, double y, double w, double h, [double r = 4]) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r));

    void rules(double x, double y, double w, int n, [double gap = 10]) {
      for (var i = 0; i < n; i++) {
        canvas.drawLine(
          Offset(x, y + i * gap),
          Offset(x + (i == n - 1 ? w * 0.6 : w), y + i * gap),
          l,
        );
      }
    }

    switch (kind) {
      case IllustrationKind.documents:
        canvas.drawRRect(box(52, 22, 80, 100), f);
        canvas.drawRRect(box(52, 22, 80, 100), l);
        canvas.drawRRect(box(68, 14, 80, 100), l);
        rules(80, 36, 56, 5);
        canvas.drawLine(const Offset(80, 90), const Offset(100, 90), a);
        canvas.drawLine(const Offset(80, 100), const Offset(136, 100), a);
      case IllustrationKind.sales:
        canvas.drawRRect(box(40, 30, 100, 92), f);
        canvas.drawRRect(box(40, 30, 100, 92), l);
        canvas.drawLine(const Offset(40, 52), const Offset(140, 52), l);
        rules(54, 66, 72, 4);
        canvas.drawPath(
          Path()
            ..moveTo(110, 108)
            ..lineTo(126, 90)
            ..lineTo(138, 98)
            ..lineTo(162, 66),
          a,
        );
        canvas.drawLine(const Offset(154, 66), const Offset(162, 66), a);
        canvas.drawLine(const Offset(162, 66), const Offset(162, 74), a);
      case IllustrationKind.stock:
        canvas.drawRRect(box(34, 80, 52, 48), f);
        canvas.drawRRect(box(34, 80, 52, 48), l);
        canvas.drawLine(const Offset(60, 80), const Offset(60, 96), l);
        canvas.drawRRect(box(92, 80, 52, 48), l);
        canvas.drawLine(const Offset(118, 80), const Offset(118, 96), l);
        canvas.drawRRect(box(62, 32, 52, 48), f);
        canvas.drawRRect(box(62, 32, 52, 48), a);
        canvas.drawLine(const Offset(88, 32), const Offset(88, 48), a);
        canvas.drawLine(const Offset(150, 128), const Offset(150, 100), l);
        canvas.drawLine(const Offset(150, 100), const Offset(172, 100), l);
        canvas.drawLine(const Offset(172, 100), const Offset(172, 128), l);
      case IllustrationKind.parties:
        for (final x in [72.0, 128.0]) {
          final c = x == 72.0 ? l : a;
          canvas.drawCircle(Offset(x, 56), 14, c);
          canvas.drawPath(
            Path()
              ..moveTo(x - 28, 122)
              ..quadraticBezierTo(x - 28, 84, x, 84)
              ..quadraticBezierTo(x + 28, 84, x + 28, 122),
            c,
          );
        }
      case IllustrationKind.site:
        canvas.drawRRect(box(40, 70, 56, 58, 2), f);
        canvas.drawRRect(box(40, 70, 56, 58, 2), l);
        for (var r = 0; r < 3; r++) {
          for (var c = 0; c < 2; c++) {
            canvas.drawRect(Rect.fromLTWH(50 + c * 24, 80 + r * 16, 10, 8), l);
          }
        }
        canvas.drawLine(const Offset(130, 128), const Offset(130, 24), a);
        canvas.drawLine(const Offset(130, 24), const Offset(172, 24), a);
        canvas.drawLine(const Offset(130, 24), const Offset(112, 24), a);
        canvas.drawLine(const Offset(160, 24), const Offset(160, 56), l);
        canvas.drawRect(const Rect.fromLTWH(152, 56, 16, 10), l);
        canvas.drawLine(const Offset(124, 128), const Offset(136, 128), a);
      case IllustrationKind.search:
        canvas.drawRRect(box(40, 22, 100, 100), f);
        canvas.drawRRect(box(40, 22, 100, 100), l);
        rules(54, 40, 72, 3, 12);
        canvas.drawCircle(const Offset(112, 88), 22, a);
        canvas.drawLine(const Offset(128, 104), const Offset(150, 126), a);
      case IllustrationKind.ledger:
        canvas.drawRRect(box(36, 24, 128, 98), f);
        canvas.drawRRect(box(36, 24, 128, 98), l);
        canvas.drawLine(const Offset(36, 46), const Offset(164, 46), l);
        canvas.drawLine(const Offset(100, 24), const Offset(100, 122), l);
        for (var i = 0; i < 4; i++) {
          canvas.drawLine(Offset(36, 66 + i * 18), Offset(164, 66 + i * 18), l);
        }
        canvas.drawLine(const Offset(110, 84), const Offset(150, 84), a);
      case IllustrationKind.calendar:
        canvas.drawRRect(box(44, 28, 112, 94), f);
        canvas.drawRRect(box(44, 28, 112, 94), l);
        canvas.drawLine(const Offset(44, 52), const Offset(156, 52), l);
        canvas.drawLine(const Offset(72, 20), const Offset(72, 36), l);
        canvas.drawLine(const Offset(128, 20), const Offset(128, 36), l);
        for (var r = 0; r < 3; r++) {
          for (var c = 0; c < 5; c++) {
            final rect = Rect.fromLTWH(56 + c * 20, 62 + r * 18, 8, 8);
            canvas.drawRect(rect, r == 1 && c == 2 ? a : l);
          }
        }
    }
  }

  @override
  bool shouldRepaint(IllustrationPainter old) =>
      old.kind != kind ||
      old.line != line ||
      old.accent != accent ||
      old.fill != fill;
}
