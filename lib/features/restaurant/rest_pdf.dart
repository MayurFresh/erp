import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
import 'rest_models.dart';

/// 80 mm paper with a small margin; the page grows to fit its content.
const double _mm = PdfPageFormat.mm;
final PdfPageFormat kRoll80 = PdfPageFormat(
  80 * _mm,
  double.infinity,
  marginAll: 4 * _mm,
);

String kotFileName(Kot kot) => 'kot-${kot.kotNo}-${kot.station}.pdf'.replaceAll(
  RegExp(r'[^A-Za-z0-9_.-]'),
  '-',
);

String billFileName(RestOrder order) =>
    'bill-${order.number}.pdf'.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');

String _time(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}

/// Kitchen order ticket: big text, table, number and time, items and notes.
/// No prices.
Future<Uint8List> buildKotPdf(Kot kot, {pw.ThemeData? theme}) {
  final kit = PdfKit(theme: theme);
  final doc = kit.document(title: 'KOT ${kot.kotNo}');
  final rule = pw.Divider(color: kInk, thickness: 1, height: 10);
  doc.addPage(
    pw.Page(
      pageTheme: kit.pageTheme(format: kRoll80, margin: 12),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          kit.text(
            'KOT ${kot.kotNo}',
            size: 22,
            bold: true,
            align: pw.TextAlign.center,
          ),
          kit.text(
            kot.station.toUpperCase(),
            size: 14,
            bold: true,
            align: pw.TextAlign.center,
          ),
          rule,
          kit.text(kot.where, size: 22, bold: true),
          pw.SizedBox(height: 2),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              kit.text(_time(kot.createdAt), size: 12, bold: true),
              if (kot.covers != null)
                kit.text('Covers ${kot.covers}', size: 12),
              kit.text(kot.orderNumber, size: 10),
            ],
          ),
          if ((kot.captainName ?? '').isNotEmpty)
            kit.text('Captain: ${kot.captainName}', size: 10),
          rule,
          for (final l in kot.liveLines) ...[
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 34,
                  child: kit.text(
                    '${formatQty(l.qty)} x',
                    size: 15,
                    bold: true,
                  ),
                ),
                pw.Expanded(child: kit.text(l.name, size: 15, bold: true)),
              ],
            ),
            if ((l.note ?? '').isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 34, top: 1),
                child: kit.text('** ${l.note}', size: 12),
              ),
            pw.SizedBox(height: 6),
          ],
          rule,
          kit.text(
            '${kot.liveLines.length} item${kot.liveLines.length == 1 ? '' : 's'}',
            size: 10,
            align: pw.TextAlign.center,
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

/// Customer bill with the GST summary.
Future<Uint8List> buildBillPdf(
  RestOrder order,
  Company company, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(
    brand: brand ?? PdfBrand.plain(company.name),
    theme: theme,
  );
  final doc = kit.document(title: 'Bill ${order.number}');
  final bill = order.bill;
  final rule = pw.Divider(color: kLine, thickness: 0.6, height: 8);
  pw.Widget row(
    String left,
    String right, {
    bool bold = false,
    double size = 9,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        kit.text(left, size: size, bold: bold),
        kit.text(right, size: size, bold: bold),
      ],
    ),
  );
  final created = order.createdAt?.toLocal();
  doc.addPage(
    pw.Page(
      pageTheme: kit.pageTheme(format: kRoll80, margin: 12),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          kit.text(
            company.name,
            size: 13,
            bold: true,
            align: pw.TextAlign.center,
          ),
          if (kit.has(company.address))
            kit.muted(company.address!, size: 8, align: pw.TextAlign.center),
          if (kit.has(company.phone))
            kit.muted(
              'Ph ${company.phone}',
              size: 8,
              align: pw.TextAlign.center,
            ),
          if (kit.has(company.gstin))
            kit.text(
              'GSTIN ${company.gstin}',
              size: 8,
              align: pw.TextAlign.center,
            ),
          rule,
          kit.text('BILL', size: 11, bold: true, align: pw.TextAlign.center),
          row(
            'No. ${order.number}',
            created == null ? '' : formatDate(created.toIso8601String()),
          ),
          row(order.title, _time(created)),
          if (order.covers != null) row('Covers ${order.covers}', ''),
          rule,
          pw.Row(
            children: [
              pw.Expanded(child: kit.text('Item', size: 8, bold: true)),
              pw.SizedBox(
                width: 24,
                child: kit.text(
                  'Qty',
                  size: 8,
                  bold: true,
                  align: pw.TextAlign.right,
                ),
              ),
              pw.SizedBox(
                width: 44,
                child: kit.text(
                  'Amount',
                  size: 8,
                  bold: true,
                  align: pw.TextAlign.right,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 2),
          for (final l in bill.lines)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(child: kit.text(l.name, size: 9)),
                  pw.SizedBox(
                    width: 24,
                    child: kit.text(
                      formatQty(l.qty),
                      size: 9,
                      align: pw.TextAlign.right,
                    ),
                  ),
                  pw.SizedBox(
                    width: 44,
                    child: kit.text(
                      formatAmount(l.amount),
                      size: 9,
                      align: pw.TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
          rule,
          row('Sub total', formatAmount(bill.gross)),
          if (bill.discount > 0)
            row(
              'Discount ${formatPlain(bill.discountPct)}%',
              '-${formatAmount(bill.discount)}',
            ),
          if (bill.serviceCharge > 0)
            row(
              'Service charge ${formatPlain(bill.serviceChargePct)}%',
              formatAmount(bill.serviceCharge),
            ),
          for (final g in bill.gstSummary) ...[
            if (g.cgst > 0 || g.sgst > 0) ...[
              row('CGST ${formatPlain(g.rate / 2)}%', formatAmount(g.cgst)),
              row('SGST ${formatPlain(g.rate / 2)}%', formatAmount(g.sgst)),
            ] else if (g.igst > 0)
              row('IGST ${formatPlain(g.rate)}%', formatAmount(g.igst)),
          ],
          if (bill.roundOff != 0) row('Round off', formatAmount(bill.roundOff)),
          rule,
          row('TOTAL', formatMoney(bill.total), bold: true, size: 12),
          rule,
          kit.muted('GST summary (taxable value)', size: 7.5),
          for (final g in bill.gstSummary)
            row(
              '${formatPlain(g.rate)}%  on ${formatAmount(g.taxable)}',
              formatAmount(g.cgst + g.sgst + g.igst),
              size: 8,
            ),
          pw.SizedBox(height: 8),
          kit.text(
            'Thank you. Visit again.',
            size: 9,
            align: pw.TextAlign.center,
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
