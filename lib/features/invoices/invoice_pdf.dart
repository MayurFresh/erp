/// A4 GST tax invoice as PDF bytes. Pure Dart (no Flutter), so it can be
/// unit-tested and run anywhere.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/whatsapp.dart';
import '../company/company_model.dart';
import '../parties/party_model.dart';
import 'invoice_model.dart';

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
/// available. The default theme uses the built-in PDF fonts, which only
/// cover Latin-1, so text is transliterated (`₹` → `Rs.`); pass a [theme]
/// with a Unicode font to print other scripts as-is.
Future<Uint8List> buildInvoicePdf(
  Invoice invoice,
  Company company, {
  Party? party,
  pw.ThemeData? theme,
}) {
  final doc = pw.Document(
    title: 'Tax invoice ${invoice.number ?? ''}',
    author: company.name,
    creator: 'Progen ERP',
  );
  final builder = _InvoicePdf(
    invoice,
    company,
    party,
    clean: theme == null ? pdfLatin1 : (s) => s,
  );
  doc.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        theme:
            theme ??
            pw.ThemeData.withFont(
              base: pw.Font.helvetica(),
              bold: pw.Font.helveticaBold(),
            ),
        buildBackground: invoice.isCancelled
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
      footer: (context) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(top: 8),
        child: pw.Text(
          builder.clean(
            '${invoice.number ?? ''} · Page ${context.pageNumber} of '
            '${context.pagesCount}',
          ),
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
        ),
      ),
      build: builder.build,
    ),
  );
  return doc.save();
}

/// Maps common Unicode punctuation to Latin-1 and drops what the built-in
/// fonts cannot draw.
String pdfLatin1(String text) {
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
  };
  final out = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final mapped = replacements[char];
    if (mapped != null) {
      out.write(mapped);
    } else if (rune <= 0xff) {
      out.write(char);
    } else {
      out.write('?');
    }
  }
  return out.toString();
}

class _InvoicePdf {
  _InvoicePdf(this.invoice, this.company, this.party, {required this.clean});

  final Invoice invoice;
  final Company company;
  final Party? party;
  final String Function(String) clean;

  static const _border = PdfColors.grey600;
  static const _shade = PdfColor.fromInt(0xFFEFF1F8);
  static const _small = pw.TextStyle(fontSize: 8);
  static final _smallBold = pw.TextStyle(
    fontSize: 8,
    fontWeight: pw.FontWeight.bold,
  );
  static final _label = pw.TextStyle(fontSize: 8, color: PdfColors.grey700);

  pw.Widget _text(String value, {pw.TextStyle? style, pw.TextAlign? align}) =>
      pw.Text(clean(value), style: style ?? _small, textAlign: align);

  bool _has(String? value) => value != null && value.trim().isNotEmpty;

  String _place(String? code) {
    if (code == null || code.isEmpty) return '';
    final name = stateName(code);
    return name == null ? code : '$name ($code)';
  }

  List<pw.Widget> build(pw.Context context) {
    final lines = invoice.lines ?? const <InvoiceLine>[];
    return [
      _header(),
      pw.SizedBox(height: 10),
      if (invoice.hasActiveIrn) ...[_einvoiceBlock(), pw.SizedBox(height: 10)],
      _parties(),
      pw.SizedBox(height: 10),
      _lineTable(lines),
      pw.SizedBox(height: 10),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(flex: 3, child: _taxBreakup(lines)),
          pw.SizedBox(width: 12),
          pw.Expanded(flex: 2, child: _totals()),
        ],
      ),
      pw.SizedBox(height: 8),
      _amountInWords(),
      pw.SizedBox(height: 12),
      _footerBlock(),
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
    pw.Widget row(String label, String value) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(width: 56, child: _text(label, style: _label)),
          pw.Expanded(child: _text(value, style: _smallBold)),
        ],
      ),
    );
    return pw.Container(
      padding: const pw.EdgeInsets.all(6),
      decoration: pw.BoxDecoration(border: pw.Border.all(color: _border)),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                row('IRN', e.irn),
                row('Ack No', e.ackNo),
                row('Ack Date', _stamp(e.ackDate)),
                if (showBill) ...[
                  row('E-way bill', bill.ewbNo),
                  row('Valid until', _stamp(bill.validUntil)),
                ],
                if (e.sandbox)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 4),
                    child: _text(
                      'SANDBOX — not valid for GST',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.red800,
                      ),
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
    );
  }

  pw.Widget _header() {
    final contact = [
      if (_has(company.phone)) 'Phone: ${company.phone}',
      if (_has(company.email)) 'Email: ${company.email}',
      if (_has(company.website)) company.website!,
    ].join('   ');
    final ids = [
      if (_has(company.gstin)) 'GSTIN: ${company.gstin}',
      if (_has(company.pan)) 'PAN: ${company.pan}',
      'State: ${_place(company.stateCode)}',
    ].join('   ');
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _text(
                company.name,
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (_has(company.legalName) && company.legalName != company.name)
                _text(
                  company.legalName!,
                  style: const pw.TextStyle(fontSize: 9),
                ),
              if (_has(company.address)) _text(company.address!),
              _text(ids),
              if (contact.isNotEmpty) _text(contact),
            ],
          ),
        ),
        pw.SizedBox(width: 12),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            _text(
              'TAX INVOICE',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            _text('Original for recipient', style: _label),
            if (invoice.isCancelled)
              _text(
                'CANCELLED',
                style: pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.red800,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
          ],
        ),
      ],
    );
  }

  pw.Widget _keyValue(String key, String value) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(width: 78, child: _text(key, style: _label)),
        pw.Expanded(child: _text(value, style: _smallBold)),
      ],
    ),
  );

  pw.Widget _box(pw.Widget child) => pw.Container(
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(border: pw.Border.all(color: _border)),
    child: child,
  );

  pw.Widget _parties() {
    final p = party;
    final address = p?.address;
    final state = p?.stateCode ?? invoice.placeOfSupply;
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: _box(
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _text('Bill to', style: _label),
                _text(
                  invoice.partyName,
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                if (_has(address)) _text(address!),
                if (_has(invoice.partyGstin))
                  _text('GSTIN: ${invoice.partyGstin}')
                else
                  _text('Unregistered (no GSTIN)'),
                _text('State: ${_place(state)}'),
                if (_has(p?.phone)) _text('Phone: ${p!.phone}'),
              ],
            ),
          ),
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: _box(
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _keyValue('Invoice no.', invoice.number ?? '-'),
                _keyValue('Invoice date', formatDate(invoice.invoiceDate)),
                if (invoice.dueDate != null)
                  _keyValue('Due date', formatDate(invoice.dueDate)),
                _keyValue('Place of supply', _place(invoice.placeOfSupply)),
                _keyValue(
                  'Supply type',
                  invoice.isInterState
                      ? 'Inter-state (IGST)'
                      : 'Intra-state (CGST + SGST)',
                ),
                if (_has(invoice.locationName))
                  _keyValue('Dispatch from', invoice.locationName),
              ],
            ),
          ),
        ),
      ],
    );
  }

  pw.Widget _cell(
    String value, {
    bool bold = false,
    bool right = false,
    bool header = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
    child: _text(
      value,
      style: bold || header ? _smallBold : _small,
      align: right ? pw.TextAlign.right : pw.TextAlign.left,
    ),
  );

  pw.Widget _lineTable(List<InvoiceLine> lines) {
    const headers = [
      '#',
      'Description',
      'HSN/SAC',
      'Qty',
      'Rate',
      'Disc%',
      'Taxable',
      'GST%',
      'Tax',
      'Total',
    ];
    const rightAligned = {3, 4, 5, 6, 7, 8, 9};
    return pw.Table(
      border: pw.TableBorder.all(color: _border, width: 0.5),
      columnWidths: const {
        0: pw.FixedColumnWidth(18),
        1: pw.FlexColumnWidth(),
        2: pw.FixedColumnWidth(42),
        3: pw.FixedColumnWidth(48),
        4: pw.FixedColumnWidth(50),
        5: pw.FixedColumnWidth(32),
        6: pw.FixedColumnWidth(58),
        7: pw.FixedColumnWidth(32),
        8: pw.FixedColumnWidth(50),
        9: pw.FixedColumnWidth(60),
      },
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _shade),
          children: [
            for (final (i, h) in headers.indexed)
              _cell(h, header: true, right: rightAligned.contains(i)),
          ],
        ),
        for (final (i, line) in lines.indexed)
          pw.TableRow(
            children: [
              _cell('${i + 1}'),
              _cell(line.description),
              _cell(line.hsnCode ?? ''),
              _cell('${formatQty(line.qty)} ${line.unit}', right: true),
              _cell(formatAmount(line.rate), right: true),
              _cell(
                line.discountPct == 0 ? '-' : formatPlain(line.discountPct),
                right: true,
              ),
              _cell(formatAmount(line.taxableValue), right: true),
              _cell(formatPlain(line.gstRate), right: true),
              _cell(formatAmount(line.taxTotal), right: true),
              _cell(formatAmount(line.lineTotal), right: true),
            ],
          ),
      ],
    );
  }

  pw.Widget _taxBreakup(List<InvoiceLine> lines) {
    final inter = invoice.isInterState;
    final byRate = <double, List<double>>{};
    for (final line in lines) {
      final row = byRate.putIfAbsent(line.gstRate, () => [0, 0, 0, 0]);
      row[0] += line.taxableValue;
      row[1] += line.cgst;
      row[2] += line.sgst;
      row[3] += line.igst;
    }
    final rates = byRate.keys.toList()..sort();
    final headers = [
      'GST rate',
      'Taxable',
      if (inter) 'IGST' else ...['CGST', 'SGST'],
      'Total tax',
    ];
    List<String> values(String label, List<double> r) => [
      label,
      formatAmount(r[0]),
      if (inter)
        formatAmount(r[3])
      else ...[
        formatAmount(r[1]),
        formatAmount(r[2]),
      ],
      formatAmount(r[1] + r[2] + r[3]),
    ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _text('Tax breakup', style: _smallBold),
        pw.SizedBox(height: 3),
        pw.Table(
          border: pw.TableBorder.all(color: _border, width: 0.5),
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _shade),
              children: [
                for (final (i, h) in headers.indexed)
                  _cell(h, header: true, right: i > 0),
              ],
            ),
            for (final rate in rates)
              pw.TableRow(
                children: [
                  for (final (i, v) in values(
                    inter
                        ? 'IGST ${formatPlain(rate)}%'
                        : '${formatPlain(rate / 2)}% + ${formatPlain(rate / 2)}%',
                    byRate[rate]!,
                  ).indexed)
                    _cell(v, right: i > 0),
                ],
              ),
            pw.TableRow(
              children: [
                for (final (i, v) in values('Total', [
                  invoice.subtotal,
                  invoice.cgst,
                  invoice.sgst,
                  invoice.igst,
                ]).indexed)
                  _cell(v, bold: true, right: i > 0),
              ],
            ),
          ],
        ),
      ],
    );
  }

  pw.Widget _totalRow(String label, double amount, {bool strong = false}) {
    final style = strong
        ? pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)
        : _small;
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        children: [
          pw.Expanded(child: _text(label, style: style)),
          _text(formatAmount(amount), style: style, align: pw.TextAlign.right),
        ],
      ),
    );
  }

  pw.Widget _totals() {
    final inter = invoice.isInterState;
    return _box(
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _totalRow('Taxable value', invoice.subtotal),
          if (!inter || invoice.cgst != 0) _totalRow('CGST', invoice.cgst),
          if (!inter || invoice.sgst != 0) _totalRow('SGST', invoice.sgst),
          if (inter || invoice.igst != 0) _totalRow('IGST', invoice.igst),
          _totalRow('Round off', invoice.roundOff),
          pw.Divider(color: _border, thickness: 0.5),
          _totalRow('Grand total (₹)', invoice.total, strong: true),
          if (invoice.amountPaid != null && !invoice.isCancelled) ...[
            pw.SizedBox(height: 4),
            _totalRow('Amount paid', invoice.amountPaid!),
            _totalRow('Amount due', invoice.amountDue ?? 0, strong: true),
          ],
        ],
      ),
    );
  }

  pw.Widget _amountInWords() => _box(
    pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _text('Amount in words: ', style: _label),
        pw.Expanded(
          child: _text(amountInWords(invoice.total), style: _smallBold),
        ),
      ],
    ),
  );

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

  pw.Widget _footerBlock() {
    final c = company;
    final bank = [
      if (_has(c.bankName)) ('Bank', c.bankName!),
      if (_has(c.bankAccountNo)) ('A/c no.', c.bankAccountNo!),
      if (_has(c.bankIfsc)) ('IFSC', c.bankIfsc!),
      if (_has(c.upiId)) ('UPI ID', c.upiId!),
    ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (bank.isNotEmpty) ...[
                    _text('Bank details', style: _smallBold),
                    for (final (k, v) in bank) _keyValue(k, v),
                    pw.SizedBox(height: 8),
                  ],
                  if (_has(c.invoiceTerms)) ...[
                    _text('Terms & conditions', style: _smallBold),
                    _text(c.invoiceTerms!),
                    pw.SizedBox(height: 8),
                  ],
                  if (_has(invoice.notes)) ...[
                    _text('Notes', style: _smallBold),
                    _text(invoice.notes!),
                  ],
                ],
              ),
            ),
            pw.SizedBox(width: 16),
            if (_upiLink != null) ...[
              pw.Column(
                children: [
                  pw.BarcodeWidget(
                    barcode: pw.Barcode.qrCode(),
                    data: _upiLink!,
                    width: 80,
                    height: 80,
                    drawText: false,
                  ),
                  pw.SizedBox(height: 2),
                  _text('Scan to pay by UPI', style: _small),
                ],
              ),
              pw.SizedBox(width: 12),
            ],
            pw.Container(
              width: 180,
              height: 80,
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _border, width: 0.5),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  _text(
                    'For ${c.name}',
                    style: _smallBold,
                    align: pw.TextAlign.right,
                  ),
                  _text('Authorised Signatory', style: _small),
                ],
              ),
            ),
          ],
        ),
        if (_has(c.invoiceFooter)) ...[
          pw.SizedBox(height: 10),
          pw.Center(
            child: _text(
              c.invoiceFooter!,
              style: _label,
              align: pw.TextAlign.center,
            ),
          ),
        ],
        pw.SizedBox(height: 6),
        pw.Center(
          child: _text(
            'This is a computer-generated invoice.',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
          ),
        ),
      ],
    );
  }
}
