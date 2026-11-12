/// A branded A4 table PDF for any [ReportExport]. Pure Dart (no Flutter).
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'report_export.dart';

/// Builds the PDF: branded header, title, period line, then the table with
/// the totals row in bold and the header repeated on every page. More than
/// six columns switch to landscape. The built-in PDF fonts only cover
/// Latin-1, so `₹`, dashes and the like are transliterated unless a [theme]
/// with a Unicode font is passed. [brand] adds the logo and brand colour.
Future<Uint8List> buildReportPdf(
  ReportExport report, {
  String? companyName,
  DateTime? generatedAt,
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(
    brand: brand ?? PdfBrand.plain(companyName ?? ''),
    theme: theme,
  );
  final landscape = report.columns.length > 6;
  final format = landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
  final doc = kit.document(title: report.title);
  final stamp = generatedAt ?? DateTime.now();
  final dense = report.columns.length > 9;

  final columns = [
    for (final c in report.columns)
      PdfCol(c.label, flex: c.kind.numeric ? 1.4 : 3, right: c.kind.numeric),
  ];
  List<String> format0(List<Object?> values) => [
    for (var i = 0; i < report.columns.length; i++)
      pdfValue(i < values.length ? values[i] : null, report.columns[i].kind),
  ];

  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(format: format, margin: 28),
      header: (context) => context.pageNumber == 1
          ? pw.SizedBox()
          : kit.compactHeader(report.title),
      footer: (context) => kit.footer(
        context,
        left: 'Generated ${formatDateTime(stamp)}  |  Progen ERP',
      ),
      build: (context) => [
        if (kit.brand.companyName.isNotEmpty)
          kit.header(title: report.title, subtitle: report.subtitle)
        else ...[
          kit.text(report.title, size: 16, bold: true, color: kit.brand.color),
          if (report.subtitle != null) kit.muted(report.subtitle!),
        ],
        pw.SizedBox(height: 10),
        kit.table(
          columns: columns,
          rows: [for (final values in report.rows) format0(values)],
          totals: report.totals == null ? null : format0(report.totals!),
          fontSize: dense ? 7 : 8,
        ),
        if (report.rows.isEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 10),
            child: kit.muted('No rows for this period.', size: 9),
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
