/// A4 GST tax invoice as PDF bytes. Pure Dart (no Flutter), so it can be
/// unit-tested and run anywhere.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_kit.dart';
import '../../core/whatsapp.dart';
import '../company/company_model.dart';
import '../parties/party_model.dart';
import 'invoice_model.dart';

export '../../core/pdf_kit.dart' show pdfLatin1;

/// `INV/26-27/00001` → `INV-26-27-00001.pdf`.
String invoiceFileName(Invoice invoice) =>
    '${(invoice.number ?? 'invoice').replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// Short text for chat apps: number, total and what is due.
String invoiceShareText(Invoice invoice, {required String companyName}) {
  final lines = [
    'Invoice ${invoice.number ?? ''} from $companyName',
    if (invoice.invoiceDate != null) 'Date: ${formatDate(invoice.invoiceDate)}',
    'Total: ${formatMoney(invoice.total)}',
    if (invoice.isCancelled)
      'Status: Cancelled'
    else if (invoice.amountDue != null)
      invoice.amountDue! <= 0
          ? 'Paid in full. Thank you!'
          : 'Amount due: ${formatMoney(invoice.amountDue)}'
                '${invoice.dueDate == null ? '' : ' by ${formatDate(invoice.dueDate)}'}',
  ];
  return lines.join('\n');
}

/// `https://wa.me/?text=…` (the user picks the chat in WhatsApp).
Uri whatsAppShareUri(String text) =>
    Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');

/// Builds the tax invoice. [party] adds the buyer's address and state when
/// available. [brand] adds the logo and brand colour (see `loadPdfBrand`);
/// without it the company name and details come from [company]. The default
/// theme uses the built-in PDF fonts, which only cover Latin-1, so text is
/// transliterated (`₹` becomes `Rs.`); pass a [theme] with a Unicode font to
/// print other scripts as-is.
Future<Uint8List> buildInvoicePdf(
  Invoice invoice,
  Company company, {
  Party? party,
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final doc = kit.document(
    title: 'Tax invoice ${invoice.number ?? ''}',
    subject: invoice.partyName,
  );
  final builder = _InvoicePdf(kit, invoice, company, party);
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(
        background: invoice.isCancelled
            ? (context) => pw.Watermark.text(
                'CANCELLED',
                style: pw.TextStyle(
                  color: PdfColor.fromHex('#F6C6C6'),
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 80,
                ),
              )
            : null,
      ),
      header: (context) => context.pageNumber == 1
          ? pw.SizedBox()
          : kit.compactHeader('Tax invoice ${invoice.number ?? ''}'),
      footer: (context) => kit.footer(
        context,
        left:
            '${invoice.number ?? ''}  |  ${company.name}  |  '
            'Computer-generated invoice',
      ),
      build: builder.build,
    ),
  );
  return doc.save();
}

class _InvoicePdf {
  _InvoicePdf(this.kit, this.invoice, this.company, this.party);

  final PdfKit kit;
  final Invoice invoice;
  final Company company;
  final Party? party;

  bool _has(String? value) => kit.has(value);

  String _place(String? code) {
    if (code == null || code.isEmpty) return '';
    final name = stateName(code);
    return name == null ? code : '$name ($code)';
  }

  List<pw.Widget> build(pw.Context context) {
    final lines = invoice.lines ?? const <InvoiceLine>[];
    return [
      kit.header(
        title: 'TAX INVOICE',
        subtitle: 'Original for recipient',
        badge: invoice.isCancelled ? 'CANCELLED' : null,
      ),
      pw.SizedBox(height: 10),
      if (invoice.hasActiveIrn) ...[_einvoiceBlock(), pw.SizedBox(height: 10)],
      _parties(),
      pw.SizedBox(height: 10),
      _lineTable(lines),
      pw.SizedBox(height: 10),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            flex: 3,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                kit.wordsStrip(amountInWords(invoice.total)),
                pw.SizedBox(height: 8),
                _bankBlock(),
              ],
            ),
          ),
          pw.SizedBox(width: 12),
          pw.Expanded(flex: 2, child: _totals()),
        ],
      ),
      if (lines.isNotEmpty) ...[pw.SizedBox(height: 12), _taxSummary(lines)],
      pw.SizedBox(height: 12),
      _closing(),
    ];
  }

  String _stamp(DateTime? value) => value == null
      ? ''
      : '${formatDate(value.toIso8601String().substring(0, 10))} '
            '${value.hour.toString().padLeft(2, '0')}:'
            '${value.minute.toString().padLeft(2, '0')}';

  /// IRN, acknowledgement, QR of the signed code and the e-way bill.
  pw.Widget _einvoiceBlock() {
    final e = invoice.einvoice!;
    final bill = invoice.ewaybill;
    final showBill = bill != null && bill.isActive;
    return kit.box(
      title: 'E-invoice',
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.kv('IRN', e.irn, keyWidth: 56),
                  kit.kv('Ack no.', e.ackNo, keyWidth: 56),
                  kit.kv('Ack date', _stamp(e.ackDate), keyWidth: 56),
                  if (showBill) ...[
                    kit.kv('E-way bill', bill.ewbNo, keyWidth: 56),
                    kit.kv(
                      'Valid until',
                      _stamp(bill.validUntil),
                      keyWidth: 56,
                    ),
                  ],
                  if (e.sandbox)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(top: 4),
                      child: kit.text(
                        'SANDBOX: not valid for GST',
                        size: 10,
                        bold: true,
                        color: kDanger,
                      ),
                    ),
                ],
              ),
            ),
            if (e.signedQrCode.isNotEmpty) ...[
              pw.SizedBox(width: 10),
              pw.BarcodeWidget(
                barcode: pw.Barcode.qrCode(),
                data: e.signedQrCode,
                width: 80,
                height: 80,
                drawText: false,
              ),
            ],
          ],
        ),
      ],
    );
  }

  pw.Widget _partyBlock(String title, List<pw.Widget> children) =>
      kit.box(title: title, children: children);

  pw.Widget _parties() {
    final p = party;
    final address = p?.address;
    final state = p?.stateCode ?? invoice.placeOfSupply;
    final seller = company;
    final buyer = [
      kit.text(invoice.partyName, size: 10, bold: true),
      pw.SizedBox(height: 2),
      if (_has(address)) kit.text(address!, height: 1.5),
      if (_has(p?.pincode)) kit.text('PIN ${p!.pincode}'),
      if (_has(invoice.partyGstin))
        kit.text('GSTIN: ${invoice.partyGstin}')
      else
        kit.muted('Unregistered (no GSTIN)'),
      kit.text('State: ${_place(state)}'),
      if (_has(p?.phone)) kit.text('Phone: ${p!.phone}'),
    ];
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          flex: 10,
          child: _partyBlock('Seller', [
            kit.text(seller.name, size: 10, bold: true),
            pw.SizedBox(height: 2),
            if (_has(seller.address)) kit.text(seller.address!, height: 1.5),
            if (_has(seller.gstin)) kit.text('GSTIN: ${seller.gstin}'),
            kit.text('State: ${_place(seller.stateCode)}'),
            if (_has(invoice.locationName))
              kit.muted('Dispatch from: ${invoice.locationName}'),
          ]),
        ),
        pw.SizedBox(width: 8),
        pw.Expanded(flex: 10, child: _partyBlock('Bill to', buyer)),
        pw.SizedBox(width: 8),
        pw.Expanded(
          flex: 10,
          child: _partyBlock('Ship to', [
            kit.text(invoice.partyName, size: 10, bold: true),
            pw.SizedBox(height: 2),
            if (_has(address))
              kit.text(address!, height: 1.5)
            else
              kit.muted('Same as billing address'),
            kit.text('Place of supply: ${_place(invoice.placeOfSupply)}'),
          ]),
        ),
        pw.SizedBox(width: 8),
        pw.Expanded(
          flex: 14,
          child: _partyBlock('Invoice details', [
            kit.kv('Invoice no.', invoice.number ?? '-', keyWidth: 52),
            kit.kv('Date', formatDate(invoice.invoiceDate), keyWidth: 52),
            if (invoice.dueDate != null)
              kit.kv('Due date', formatDate(invoice.dueDate), keyWidth: 52),
            kit.kv(
              'Supply',
              invoice.isInterState
                  ? 'Inter-state (IGST)'
                  : 'Intra-state (CGST + SGST)',
              keyWidth: 52,
            ),
          ]),
        ),
      ],
    );
  }

  pw.Widget _lineTable(List<InvoiceLine> lines) {
    return kit.table(
      fontSize: 7.5,
      columns: const [
        PdfCol('#', width: 22),
        PdfCol('Description', flex: 1),
        PdfCol('HSN/SAC', width: 42),
        PdfCol('Qty', width: 44, right: true),
        PdfCol('Rate', width: 48, right: true),
        PdfCol('Disc%', width: 34, right: true),
        PdfCol('Taxable', width: 52, right: true),
        PdfCol('GST%', width: 32, right: true),
        PdfCol('Tax', width: 46, right: true),
        PdfCol('Total', width: 56, right: true),
      ],
      rows: [
        for (final (i, line) in lines.indexed)
          [
            '${i + 1}',
            line.description,
            line.hsnCode ?? '',
            '${formatQty(line.qty)} ${line.unit}',
            formatAmount(line.rate),
            line.discountPct == 0 ? '-' : formatPlain(line.discountPct),
            formatAmount(line.taxableValue),
            formatPlain(line.gstRate),
            formatAmount(line.taxTotal),
            formatAmount(line.lineTotal),
          ],
      ],
      totals: lines.isEmpty
          ? null
          : [
              '',
              'Total',
              '',
              '',
              '',
              '',
              formatAmount(invoice.subtotal),
              '',
              formatAmount(invoice.taxTotal),
              formatAmount(lines.fold<double>(0, (a, l) => a + l.lineTotal)),
            ],
    );
  }

  /// Tax summary grouped by HSN/SAC and rate.
  pw.Widget _taxSummary(List<InvoiceLine> lines) {
    final inter = invoice.isInterState;
    final groups = <String, List<double>>{};
    final keys = <String, (String, double)>{};
    for (final line in lines) {
      final hsn = (line.hsnCode ?? '').trim();
      final key = '$hsn|${line.gstRate}';
      keys[key] = (hsn, line.gstRate);
      final row = groups.putIfAbsent(key, () => [0, 0, 0, 0]);
      row[0] += line.taxableValue;
      row[1] += line.cgst;
      row[2] += line.sgst;
      row[3] += line.igst;
    }
    final order = groups.keys.toList()
      ..sort((a, b) {
        final c = keys[a]!.$1.compareTo(keys[b]!.$1);
        return c != 0 ? c : keys[a]!.$2.compareTo(keys[b]!.$2);
      });
    List<String> values(String hsn, String rate, List<double> r) => [
      hsn,
      formatAmount(r[0]),
      rate,
      if (inter)
        formatAmount(r[3])
      else ...[
        formatAmount(r[1]),
        formatAmount(r[2]),
      ],
      formatAmount(r[1] + r[2] + r[3]),
    ];
    final sum = [0.0, 0.0, 0.0, 0.0];
    for (final r in groups.values) {
      for (var i = 0; i < 4; i++) {
        sum[i] += r[i];
      }
    }
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        kit.sectionTitle('HSN / SAC and tax summary'),
        kit.table(
          fontSize: 7.5,
          columns: [
            const PdfCol('HSN/SAC', flex: 2),
            const PdfCol('Taxable value', flex: 2, right: true),
            const PdfCol('Rate', flex: 1, right: true),
            if (inter)
              const PdfCol('IGST', flex: 2, right: true)
            else ...const [
              PdfCol('CGST', flex: 2, right: true),
              PdfCol('SGST', flex: 2, right: true),
            ],
            const PdfCol('Total tax', flex: 2, right: true),
          ],
          rows: [
            for (final k in order)
              values(
                keys[k]!.$1.isEmpty ? '-' : keys[k]!.$1,
                '${formatPlain(keys[k]!.$2)}%',
                groups[k]!,
              ),
          ],
          totals: values('Total', '', sum),
        ),
      ],
    );
  }

  pw.Widget _totals() {
    final inter = invoice.isInterState;
    return kit.totalsBox([
      kit.totalRow('Taxable value', formatAmount(invoice.subtotal)),
      if (!inter || invoice.cgst != 0)
        kit.totalRow('CGST', formatAmount(invoice.cgst)),
      if (!inter || invoice.sgst != 0)
        kit.totalRow('SGST', formatAmount(invoice.sgst)),
      if (inter || invoice.igst != 0)
        kit.totalRow('IGST', formatAmount(invoice.igst)),
      if (invoice.roundOff != 0)
        kit.totalRow('Round off', formatAmount(invoice.roundOff)),
      pw.Divider(color: kLine, thickness: 0.6, height: 8),
      kit.totalRow('Grand total', formatMoney(invoice.total), strong: true),
      if (invoice.reverseCharge) ...[
        pw.SizedBox(height: 4),
        kit.totalRow('Tax payable on reverse charge: Yes', formatAmount(invoice.rcmTax)),
      ],
      if (invoice.amountPaid != null && !invoice.isCancelled) ...[
        pw.SizedBox(height: 4),
        kit.totalRow('Amount paid', formatAmount(invoice.amountPaid!)),
        kit.totalRow(
          'Amount due',
          formatMoney(invoice.amountDue ?? 0),
          strong: true,
          color: (invoice.amountDue ?? 0) > 0 ? kDanger : kGood,
        ),
      ],
    ]);
  }

  /// UPI payment link for the QR code; null when the company has no UPI ID
  /// or nothing is left to pay.
  String? get _upiLink {
    final due = invoice.amountDue;
    if (!_has(company.upiId) || invoice.isCancelled) return null;
    if (due == null || due <= 0) return null;
    return buildUpiUri(
      upiId: company.upiId!,
      payeeName: company.name,
      amount: due,
      note: invoice.number ?? 'Invoice',
    );
  }

  pw.Widget _bankBlock() {
    final c = company;
    final bank = [
      if (_has(c.bankName)) ('Bank', c.bankName!),
      if (_has(c.bankAccountNo)) ('A/c no.', c.bankAccountNo!),
      if (_has(c.bankIfsc)) ('IFSC', c.bankIfsc!),
      if (_has(c.upiId)) ('UPI ID', c.upiId!),
    ];
    final upi = _upiLink;
    if (bank.isEmpty && upi == null) return pw.SizedBox();
    return kit.box(
      title: 'Bank details',
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                children: [
                  for (final (k, v) in bank) kit.kv(k, v, keyWidth: 46),
                ],
              ),
            ),
            if (upi != null) ...[
              pw.SizedBox(width: 8),
              pw.Column(
                children: [
                  pw.BarcodeWidget(
                    barcode: pw.Barcode.qrCode(),
                    data: upi,
                    width: 70,
                    height: 70,
                    drawText: false,
                  ),
                  pw.SizedBox(height: 2),
                  kit.muted('Scan to pay by UPI', size: 7),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }

  pw.Widget _closing() {
    final c = company;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (_has(c.invoiceTerms)) ...[
                    kit.sectionTitle('Terms and conditions'),
                    kit.text(c.invoiceTerms!, size: 8, height: 1.5),
                    pw.SizedBox(height: 8),
                  ],
                  if (_has(invoice.notes)) ...[
                    kit.sectionTitle('Notes'),
                    kit.text(invoice.notes!, size: 8, height: 1.5),
                  ],
                ],
              ),
            ),
            pw.SizedBox(width: 16),
            kit.signature(),
          ],
        ),
        if (_has(c.invoiceFooter)) ...[
          pw.SizedBox(height: 10),
          pw.Center(
            child: kit.muted(c.invoiceFooter!, align: pw.TextAlign.center),
          ),
        ],
      ],
    );
  }
}
