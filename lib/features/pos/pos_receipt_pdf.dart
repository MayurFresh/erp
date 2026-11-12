import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'pos_models.dart';

String posReceiptFileName(PosSale sale) =>
    'receipt-${sale.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}.pdf';

/// Page format of a thermal roll: 80 mm or 58 mm wide, as tall as the bill.
PdfPageFormat thermalFormat({bool narrow = false}) => PdfPageFormat(
  (narrow ? 58 : 80) * PdfPageFormat.mm,
  double.infinity,
  marginAll: (narrow ? 2 : 3) * PdfPageFormat.mm,
);

/// The counter receipt. Without a [theme] the built-in fonts are used and
/// text is transliterated to Latin-1 (see [PdfKit]).
Future<Uint8List> buildPosReceiptPdf(
  PosSale sale, {
  bool narrow = false,
  PdfBrand? brand,
  pw.ThemeData? theme,
}) async {
  final kit = PdfKit(
    brand: brand ?? PdfBrand.plain(sale.companyName),
    theme: theme,
  );
  final doc = kit.document(
    title: 'Receipt ${sale.number}',
    subject: sale.customerName,
  );
  final size = narrow ? 7.0 : 8.0;
  pw.Widget t(String s, {bool bold = false, pw.TextAlign? align, double? sz}) =>
      kit.text(s, size: sz ?? size, bold: bold, align: align);
  pw.Widget row(String l, String r, {bool bold = false, double? sz}) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      t(l, bold: bold, sz: sz),
      t(r, bold: bold, sz: sz),
    ],
  );
  final rule = pw.Container(
    margin: const pw.EdgeInsets.symmetric(vertical: 3),
    height: 0.5,
    color: PdfColors.grey700,
  );
  final when = sale.createdAt == null
      ? sale.date
      : formatDateTime(sale.createdAt);

  doc.addPage(
    pw.Page(
      pageFormat: thermalFormat(narrow: narrow),
      theme: kit.pageTheme().theme,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          t(
            sale.companyName,
            bold: true,
            align: pw.TextAlign.center,
            sz: size + 2,
          ),
          if (kit.has(sale.companyAddress))
            t(sale.companyAddress!, align: pw.TextAlign.center),
          if (kit.has(sale.companyPhone))
            t('Ph ${sale.companyPhone}', align: pw.TextAlign.center),
          if (kit.has(sale.companyGstin))
            t('GSTIN ${sale.companyGstin}', align: pw.TextAlign.center),
          rule,
          t('TAX INVOICE', bold: true, align: pw.TextAlign.center),
          row('Bill', sale.number, bold: true),
          row('Date', when),
          if (sale.locationName.isNotEmpty) row('Counter', sale.locationName),
          if (sale.cashier.isNotEmpty) row('Cashier', sale.cashier),
          if (!sale.isWalkIn) row('Customer', sale.customerName),
          if (kit.has(sale.customerGstin))
            row('Cust. GSTIN', sale.customerGstin!),
          rule,
          for (final l in sale.lines) ...[
            t(l.description, bold: true),
            row(
              '${formatQty(l.qty)} x ${formatAmount(l.rate)}'
              '${l.discountPct > 0 ? '  -${formatPlain(l.discountPct)}%' : ''}',
              formatAmount(l.taxableValue),
            ),
            pw.SizedBox(height: 2),
          ],
          rule,
          row(
            'Items',
            formatQty(sale.lines.fold<double>(0, (s, l) => s + l.qty)),
          ),
          if (sale.discountTotal > 0)
            row('Discount', '-${formatAmount(sale.discountTotal)}'),
          row('Taxable', formatAmount(sale.subtotal)),
          for (final b in sale.taxSummary) ..._band(b, row),
          if (sale.roundOff != 0) row('Round off', formatAmount(sale.roundOff)),
          rule,
          row('TOTAL', formatMoney(sale.total), bold: true, sz: size + 3),
          rule,
          for (final p in sale.payments)
            row(
              posModeLabel(asString(p['mode'])),
              formatAmount(asDouble(p['amount'])),
            ),
          if (sale.tenderedCash > 0)
            row('Cash given', formatAmount(sale.tenderedCash)),
          if (sale.changeDue > 0)
            row('Change', formatAmount(sale.changeDue), bold: true),
          if (sale.creditAmount > 0)
            row('Balance due', formatAmount(sale.creditAmount), bold: true),
          rule,
          t(
            kit.has(sale.footer) ? sale.footer! : 'Thank you. Visit again.',
            align: pw.TextAlign.center,
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

Iterable<pw.Widget> _band(
  Json b,
  pw.Widget Function(String, String, {bool bold, double? sz}) row,
) sync* {
  final rate = formatPlain(asDouble(b['rate']));
  final cgst = asDouble(b['cgst']);
  final sgst = asDouble(b['sgst']);
  final igst = asDouble(b['igst']);
  if (igst > 0) {
    yield row('IGST $rate%', formatAmount(igst));
  } else {
    final half = formatPlain(asDouble(b['rate']) / 2);
    yield row('CGST $half%', formatAmount(cgst));
    yield row('SGST $half%', formatAmount(sgst));
  }
}

/// The X or Z report on A4.
Future<Uint8List> buildSessionReportPdf(
  SessionReport r, {
  PdfBrand? brand,
  pw.ThemeData? theme,
}) async {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(), theme: theme);
  final doc = kit.document(
    title: '${r.kind} report',
    subject: r.session.locationName,
  );
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(),
      footer: (c) =>
          kit.footer(c, left: '${r.kind} report  |  ${r.session.locationName}'),
      build: (c) => [
        kit.header(
          title: r.kind == 'Z' ? 'Z REPORT (CLOSED)' : 'X REPORT (RUNNING)',
        ),
        pw.SizedBox(height: 10),
        kit.kv('Counter', r.session.locationName),
        kit.kv('Cashier', r.session.userName),
        kit.kv('Opened', formatDateTime(r.session.openedAt)),
        if (r.session.closedAt != null)
          kit.kv('Closed', formatDateTime(r.session.closedAt)),
        kit.kv('Opening cash', formatMoney(r.session.openingFloat)),
        kit.sectionTitle('Sales'),
        kit.kv('Bills', '${r.salesCount}'),
        kit.kv('Items sold', formatQty(r.itemsSold)),
        kit.kv('Discounts', formatMoney(r.discountTotal)),
        kit.kv('Tax collected', formatMoney(r.taxTotal)),
        kit.kv('Sales total', formatMoney(r.salesTotal)),
        kit.kv('Returns (${r.returnsCount})', formatMoney(r.returnsTotal)),
        if (r.creditGiven > 0)
          kit.kv('Given on credit', formatMoney(r.creditGiven)),
        kit.sectionTitle('Money by mode'),
        kit.table(
          columns: const [
            PdfCol('Mode', flex: 2),
            PdfCol('Received', right: true),
            PdfCol('Refunded', right: true),
            PdfCol('Expected', right: true),
            PdfCol('Counted', right: true),
            PdfCol('Difference', right: true),
          ],
          rows: [
            for (final m in posModes)
              [
                posModeLabel(m),
                formatAmount(r.payments[m]),
                formatAmount(r.refunds[m]),
                formatAmount(r.expected[m]),
                r.counted?[m] == null ? '-' : formatAmount(r.counted![m]),
                r.difference?[m] == null ? '-' : formatAmount(r.difference![m]),
              ],
          ],
        ),
        pw.SizedBox(height: 6),
        kit.muted(
          'Expected cash = opening cash + cash received - cash refunded + cash in - cash out.',
        ),
        if (r.cashMoves.isNotEmpty) ...[
          kit.sectionTitle('Cash in and out'),
          for (final m in r.cashMoves)
            kit.kv(
              '${asString(m['kind']) == 'in' ? 'In' : 'Out'}  ${formatAmount(asDouble(m['amount']))}',
              asString(m['reason']),
              keyWidth: 90,
            ),
        ],
      ],
    ),
  );
  return doc.save();
}
