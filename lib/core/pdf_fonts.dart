import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

pw.ThemeData? _cached;

/// The PDF theme with bundled Noto Sans, so invoices and reports print `₹`
/// and other non-Latin-1 text. Returns `null` if the fonts can't be loaded;
/// the PDF builders then fall back to the built-in fonts (`₹` → `Rs.`).
Future<pw.ThemeData?> pdfTheme() async {
  if (_cached != null) return _cached;
  try {
    final base = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
    return _cached = pw.ThemeData.withFont(
      base: pw.Font.ttf(base),
      bold: pw.Font.ttf(bold),
    );
  } catch (_) {
    return null;
  }
}
