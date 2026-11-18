import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Where labels go: a sticker sheet on A4 or a thermal roll.
class LabelLayout {
  const LabelLayout({
    required this.id,
    required this.name,
    required this.cols,
    required this.rows,
    required this.widthMm,
    required this.heightMm,
    this.thermal = false,
  });

  final String id;
  final String name;
  final int cols;
  final int rows;

  /// Size of one label.
  final double widthMm;
  final double heightMm;

  /// One label per page on a roll.
  final bool thermal;

  int get perPage => cols * rows;
}

const labelLayouts = <LabelLayout>[
  LabelLayout(id: 'a4_24', name: 'A4 sheet, 24 labels (70 x 37 mm)', cols: 3, rows: 8, widthMm: 70, heightMm: 37),
  LabelLayout(id: 'a4_40', name: 'A4 sheet, 40 labels (52.5 x 29.7 mm)', cols: 4, rows: 10, widthMm: 52.5, heightMm: 29.7),
  LabelLayout(id: 'a4_65', name: 'A4 sheet, 65 labels (38.1 x 21.2 mm)', cols: 5, rows: 13, widthMm: 38.1, heightMm: 21.2),
  LabelLayout(id: 'roll_50x25', name: 'Thermal roll, 50 x 25 mm', cols: 1, rows: 1, widthMm: 50, heightMm: 25, thermal: true),
];

LabelLayout labelLayoutById(String id) =>
    labelLayouts.firstWhere((l) => l.id == id, orElse: () => labelLayouts.first);

/// One kind of label and how many to print.
class LabelEntry {
  const LabelEntry({
    required this.name,
    required this.price,
    required this.code,
    required this.copies,
    this.mrp,
  });

  final String name;
  final double price;

  /// Item barcode, or the SKU when there is none.
  final String code;
  final int copies;

  /// Printed as "MRP Rs x (incl. of all taxes)" when set.
  final double? mrp;
}

/// EAN-13 for 12 or 13 digits with a good check digit; Code 128 for anything else.
pw.Barcode barcodeFor(String code) {
  if (RegExp(r'^\d{13}$').hasMatch(code) && pw.Barcode.ean13().isValid(code)) {
    return pw.Barcode.ean13();
  }
  if (RegExp(r'^\d{12}$').hasMatch(code)) return pw.Barcode.ean13();
  return pw.Barcode.code128();
}

/// The labels in print order: each entry repeated by its copies.
List<LabelEntry> expandLabels(List<LabelEntry> entries) => [
  for (final e in entries)
    for (var i = 0; i < e.copies; i++) e,
];

/// Number of pages for [count] labels on [layout].
int labelPages(LabelLayout layout, int count) =>
    count == 0 ? 0 : (count / layout.perPage).ceil();

String _price(double v, bool rupeeSign) {
  final text = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  return rupeeSign ? '₹$text' : 'Rs $text';
}

/// The legal-metrology line under the barcode.
String mrpLine(double mrp, bool rupeeSign) => 'MRP ${_price(mrp, rupeeSign)} (incl. of all taxes)';

pw.Widget _label(LabelEntry e, LabelLayout l, bool rupeeSign) {
  final small = l.heightMm < 25;
  final nameSize = small ? 5.5 : 7.5;
  final priceSize = small ? 7.0 : 10.0;
  return pw.Container(
    width: l.widthMm * PdfPageFormat.mm,
    height: l.heightMm * PdfPageFormat.mm,
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    child: pw.Column(
      mainAxisAlignment: pw.MainAxisAlignment.center,
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          e.name,
          maxLines: 1,
          overflow: pw.TextOverflow.clip,
          style: pw.TextStyle(fontSize: nameSize, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 1),
        pw.Expanded(
          child: pw.BarcodeWidget(
            barcode: barcodeFor(e.code),
            data: e.code,
            drawText: false,
            padding: const pw.EdgeInsets.symmetric(vertical: 1),
          ),
        ),
        if (e.mrp != null)
          pw.Text(
            mrpLine(e.mrp!, rupeeSign),
            maxLines: 1,
            overflow: pw.TextOverflow.clip,
            style: pw.TextStyle(fontSize: small ? 4.5 : 6),
          ),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(e.code, style: pw.TextStyle(fontSize: small ? 4.5 : 6)),
            pw.Text(
              _price(e.price, rupeeSign),
              style: pw.TextStyle(fontSize: priceSize, fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
      ],
    ),
  );
}

/// The label PDF. Pass [theme] with a Unicode font to print the rupee sign; without it prices read "Rs 99".
Future<Uint8List> buildLabelsPdf(
  List<LabelEntry> entries,
  LabelLayout layout, {
  pw.ThemeData? theme,
}) async {
  final labels = expandLabels(entries);
  final doc = pw.Document(theme: theme, title: 'Labels');
  final sign = theme != null;
  if (layout.thermal) {
    final format = PdfPageFormat(
      layout.widthMm * PdfPageFormat.mm,
      layout.heightMm * PdfPageFormat.mm,
    );
    for (final e in labels) {
      doc.addPage(pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.zero,
        build: (_) => _label(e, layout, sign),
      ));
    }
  } else {
    for (var start = 0; start < labels.length; start += layout.perPage) {
      final page = labels.skip(start).take(layout.perPage).toList();
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.symmetric(
          horizontal: (210 - layout.cols * layout.widthMm) / 2 * PdfPageFormat.mm,
          vertical: (297 - layout.rows * layout.heightMm) / 2 * PdfPageFormat.mm,
        ),
        build: (_) => pw.Column(
          children: [
            for (var r = 0; r < layout.rows; r++)
              pw.Row(
                children: [
                  for (var c = 0; c < layout.cols; c++)
                    if (r * layout.cols + c < page.length)
                      _label(page[r * layout.cols + c], layout, sign)
                    else
                      pw.SizedBox(
                        width: layout.widthMm * PdfPageFormat.mm,
                        height: layout.heightMm * PdfPageFormat.mm,
                      ),
                ],
              ),
          ],
        ),
      ));
    }
  }
  return doc.save();
}
