// Redraws every app icon from LogoMarkPainter. Skipped in normal runs:
//   RENDER_ICONS=1 flutter test test/tool/render_icons_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/widgets/brand.dart';

const _brand = Color(0xFF0B6157);
const _white = Color(0xFFFFFFFF);

/// [fill]: paint the whole canvas (square, no transparency) before the mark.
Future<Uint8List> _render(
  int px, {
  double inset = 0,
  bool fill = false,
  bool tile = true,
}) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final size = Size.square(px.toDouble());
  if (fill) canvas.drawRect(Offset.zero & size, Paint()..color = _brand);
  LogoMarkPainter(
    background: tile ? _brand : const Color(0x00000000),
    foreground: _white,
    inset: inset,
  ).paint(canvas, size);
  final img = await rec.endRecording().toImage(px, px);
  final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return _png(data!.buffer.asUint8List(), px, rgb: fill);
}

/// Minimal PNG writer, so iOS icons can be saved without an alpha channel.
Uint8List _png(Uint8List rgba, int px, {required bool rgb}) {
  final bpp = rgb ? 3 : 4;
  final raw = BytesBuilder();
  for (var y = 0; y < px; y++) {
    raw.addByte(0);
    for (var x = 0; x < px; x++) {
      final i = (y * px + x) * 4;
      raw.add(rgba.sublist(i, i + bpp));
    }
  }
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> body) {
    final t = type.codeUnits;
    out.add(_u32(body.length));
    out.add(t);
    out.add(body);
    out.add(_u32(_crc([...t, ...body])));
  }

  chunk('IHDR', [..._u32(px), ..._u32(px), 8, rgb ? 2 : 6, 0, 0, 0]);
  chunk('IDAT', ZLibCodec(level: 9).encode(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

List<int> _u32(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255];

int _crc(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

Future<void> _write(String path, Future<Uint8List> bytes) async {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(await bytes);
}

void main() {
  test(
    'render icons',
    skip: Platform.environment['RENDER_ICONS'] != '1',
    () async {
      // Web: rounded tile, maskable has a full-bleed background with the
      // grid inside the 80% safe zone.
      await _write('web/favicon.png', _render(64));
      for (final px in [192, 512]) {
        await _write('web/icons/Icon-$px.png', _render(px));
        await _write(
          'web/icons/Icon-maskable-$px.png',
          _render(px, inset: 0.1, fill: true, tile: false),
        );
      }
      // Android: legacy icon plus an adaptive foreground (108 dp canvas,
      // grid inside the 66 dp safe zone).
      const dpi = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
      for (final e in dpi.entries) {
        final dir = 'android/app/src/main/res/mipmap-${e.key}';
        await _write('$dir/ic_launcher.png', _render((48 * e.value).round(), inset: 0.04));
        await _write(
          '$dir/ic_launcher_foreground.png',
          _render((108 * e.value).round(), inset: 0.15, tile: false),
        );
      }
      // iOS: square and opaque; the system rounds the corners.
      final ios = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
      final name = RegExp(r'Icon-App-([\d.]+)x[\d.]+@(\d)x\.png$');
      for (final f in ios.listSync().whereType<File>()) {
        final m = name.firstMatch(f.path);
        if (m == null) continue;
        final px = (double.parse(m[1]!) * int.parse(m[2]!)).round();
        await _write(f.path, _render(px, inset: 0.06, fill: true, tile: false));
      }
      // macOS: rounded tile on the standard 1024 grid (824 px body).
      for (final px in [16, 32, 64, 128, 256, 512, 1024]) {
        await _write(
          'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$px.png',
          _render(px, inset: 0.098),
        );
      }
    },
  );
}
