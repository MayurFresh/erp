/// A plain A4 table PDF for any [ReportExport]. Pure Dart (no Flutter).
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import 'report_export.dart';

/// Builds the PDF: company name, title, subtitle, then the table with the
/// totals row in bold. More than six columns switch to landscape. The
/// built-in PDF fonts only cover Latin-1, so `₹`, dashes and the like are
/// transliterated unless a [theme] with a Unicode font is passed.
Future<Uint8List> buildReportPdf(
  ReportExport report, {
  String? companyName,
  DateTime? generatedAt,
  pw.ThemeData? theme,
}) {
  final String Function(String) clean = theme == null ? _latin1 : (s) => s;
  final landscape = report.columns.length > 6;
  final format = landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
  final doc = pw.Document(
    title: clean(report.title),
    author: companyName == null ? null : clean(companyName),
    creator: 'Progen ERP',
  );
  final border = PdfColor.fromHex('#B0B7C3');
  final headerFill = PdfColor.fromHex('#E8EBF2');
  final small = pw.TextStyle(fontSize: report.columns.length > 9 ? 7 : 8);
  final bold = small.copyWith(fontWeight: pw.FontWeight.bold);

  pw.Widget cell(String text, {required bool numeric, pw.TextStyle? style}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: pw.Align(
          alignment: numeric
              ? pw.Alignment.centerRight
              : pw.Alignment.centerLeft,
          child: pw.Text(clean(text), style: style ?? small),
        ),
      );

  pw.TableRow row(
    List<Object?> values, {
    pw.TextStyle? style,
    PdfColor? fill,
  }) => pw.TableRow(
    decoration: fill == null ? null : pw.BoxDecoration(color: fill),
    children: [
      for (var i = 0; i < report.columns.length; i++)
        cell(
          pdfValue(
            i < values.length ? values[i] : null,
            report.columns[i].kind,
          ),
          numeric: report.columns[i].kind.numeric,
          style: style,
        ),
    ],
  );

  final stamp = generatedAt ?? DateTime.now();
  doc.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(24),
        theme:
            theme ??
            pw.ThemeData.withFont(
              base: pw.Font.helvetica(),
              bold: pw.Font.helveticaBold(),
            ),
      ),
      header: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (companyName != null && companyName.isNotEmpty)
            pw.Text(
              clean(companyName),
              style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          pw.Text(
            clean(report.title),
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          if (report.subtitle != null)
            pw.Text(
              clean(report.subtitle!),
              style: const pw.TextStyle(fontSize: 9),
            ),
          pw.SizedBox(height: 8),
        ],
      ),
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            clean('Generated ${formatDateTime(stamp)} · Progen ERP'),
            style: pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
          ),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
          ),
        ],
      ),
      build: (context) => [
        pw.Table(
          border: pw.TableBorder.all(color: border, width: 0.5),
          defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
          children: [
            pw.TableRow(
              repeat: true,
              decoration: pw.BoxDecoration(color: headerFill),
              children: [
                for (final c in report.columns)
                  cell(c.label, numeric: c.kind.numeric, style: bold),
              ],
            ),
            for (final values in report.rows) row(values),
            if (report.totals != null)
              row(report.totals!, style: bold, fill: headerFill),
          ],
        ),
        if (report.rows.isEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 8),
            child: pw.Text('No rows.', style: small),
          ),
      ],
    ),
  );
  return doc.save();
}

/// Text for a PDF cell: Indian grouping for money and quantities.
String pdfValue(Object? value, CellKind kind) {
  if (value == null) return '';
  if (value is num) {
    return switch (kind) {
      CellKind.money => formatAmount(value),
      CellKind.qty => formatQty(value),
      CellKind.rate => formatPercent(value),
      CellKind.count => value.round().toString(),
      CellKind.text => value.toString(),
    };
  }
  return value.toString();
}

String _latin1(String text) {
  const replacements = {
    '₹': 'Rs.',
    '—': '-',
    '–': '-',
    '‘': "'",
    '’': "'",
    '“': '"',
    '”': '"',
    '…': '...',
    '•': '-',
    '·': '-',
    '×': 'x',
    '−': '-',
    '✓': 'OK',
  };
  final out = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final replacement = replacements[char];
    if (replacement != null) {
      out.write(replacement);
    } else if (rune <= 0xFF) {
      out.write(char);
    } else {
      out.write('?');
    }
  }
  return out.toString();
}
