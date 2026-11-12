import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_doc.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
import 'payment_model.dart';

String paymentFileName(Payment p) =>
    '${p.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// A4 payment receipt (money received) or payment voucher (money paid).
Future<Uint8List> buildPaymentPdf(
  Payment p,
  Company company, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final receipt = p.kind == PaymentKind.receipt;
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: receipt ? 'Payment receipt' : 'Payment voucher',
      number: p.number,
      cancelled: p.isCancelled,
      partyTitle: receipt ? 'Received from' : 'Paid to',
      parties: [p.partyName],
      details: [
        ('${receipt ? 'Receipt' : 'Voucher'} no.', p.number),
        ('Date', formatDate(p.date)),
        ('Mode', p.mode.label),
        if (kit.has(p.reference)) ('Reference', p.reference!),
        (receipt ? 'Deposited in' : 'Paid from', p.accountName),
      ],
      intro: receipt
          ? 'Received with thanks ${formatMoney(p.amount)} from ${p.partyName}.'
          : 'Paid ${formatMoney(p.amount)} to ${p.partyName}.',
      columns: const [
        PdfCol('Document', flex: 2),
        PdfCol('Number', flex: 2),
        PdfCol('Date', width: 70),
        PdfCol('Document total', width: 80, right: true),
        PdfCol('Applied', width: 70, right: true),
      ],
      rows: [
        for (final a in p.allocations)
          [
            a.docTypeLabel,
            a.docNumber,
            formatDate(a.docDate),
            formatAmount(a.docTotal),
            formatAmount(a.amount),
          ],
      ],
      totalsRow: p.allocations.isEmpty
          ? null
          : ['', '', '', '', formatAmount(p.allocated)],
      totals: [
        PdfTotal('Amount', formatMoney(p.amount), strong: true),
        if (p.tdsAmount > 0)
          PdfTotal('TDS deducted', formatAmount(p.tdsAmount)),
        PdfTotal('Applied to documents', formatAmount(p.allocated)),
        if (p.unallocated > 0)
          PdfTotal('On account', formatAmount(p.unallocated)),
      ],
      words: amountInWords(p.amount),
      notes: p.notes,
      signature: true,
    ),
  );
}
