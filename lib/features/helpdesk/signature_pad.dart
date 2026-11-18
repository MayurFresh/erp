import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Holds the strokes drawn on a [SignaturePad] and turns them into a PNG.
class SignatureController extends ChangeNotifier {
  final List<List<Offset>> _strokes = [];
  Size _size = Size.zero;

  bool get isEmpty => _strokes.isEmpty;

  void _start(Offset p) {
    _strokes.add([p]);
    notifyListeners();
  }

  void _add(Offset p) {
    if (_strokes.isEmpty) return;
    _strokes.last.add(p);
    notifyListeners();
  }

  void clear() {
    _strokes.clear();
    notifyListeners();
  }

  /// A PNG of the signature on white, or null when nothing is drawn.
  Future<Uint8List?> toPng({double scale = 2}) async {
    if (isEmpty || _size.isEmpty) return null;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    canvas.drawRect(
      Offset.zero & _size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    _paintStrokes(canvas, _strokes, const Color(0xFF111111));
    final image = await recorder.endRecording().toImage(
      (_size.width * scale).round(),
      (_size.height * scale).round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }
}

void _paintStrokes(Canvas canvas, List<List<Offset>> strokes, Color color) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = 2.5
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  for (final s in strokes) {
    if (s.length == 1) {
      canvas.drawCircle(s.first, 1.25, paint..style = PaintingStyle.fill);
      paint.style = PaintingStyle.stroke;
      continue;
    }
    final path = Path()..moveTo(s.first.dx, s.first.dy);
    for (final p in s.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }
}

/// A box to sign in with a finger or mouse. Fills the width it is given.
class SignaturePad extends StatelessWidget {
  const SignaturePad({super.key, required this.controller, this.height = 140});

  final SignatureController controller;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Signature box',
      child: Container(
        height: height,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            controller._size = Size(box.maxWidth, box.maxHeight);
            return GestureDetector(
              key: const ValueKey('signature-pad'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) => controller._start(d.localPosition),
              onPanUpdate: (d) => controller._add(d.localPosition),
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => CustomPaint(
                  size: Size.infinite,
                  painter: _PadPainter(controller._strokes, controller),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, Listenable repaint) : super(repaint: repaint);

  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) =>
      _paintStrokes(canvas, strokes, const Color(0xFF111111));

  @override
  bool shouldRepaint(_PadPainter old) => true;
}
