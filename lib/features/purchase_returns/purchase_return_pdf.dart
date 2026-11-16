import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_doc.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
import '../parties/party_model.dart';
import 'purchase_return_model.dart';

String purchaseReturnFileName(PurchaseReturn r) =>
    '${(r.number.isEmpty ? 'debit-note' : r.number).replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// A4 debit note sent to the vendor for goods returned or a price reduction.
Future<Uint8List> buildPurchaseReturnPdf(
  PurchaseReturn note,
  Company company, {
  Party? party,
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final inter = note.isInterState;
  final lines = note.taxLines;
  final state = stateName(note.placeOfSupply);
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: 'Debit note',
      subtitle: 'Against bill ${note.purchaseNumber}',
      number: note.number,
      cancelled: note.isCancelled,
      partyTitle: 'Debit to',
      parties: [
        note.partyName,
        if (kit.has(party?.address)) party!.address!,
        if (kit.has(note.partyGstin)) 'GSTIN: ${note.partyGstin}',
        'Place of supply: ${state ?? note.placeOfSupply}',
      ],
      details: [
        ('Debit note no.', note.number),
        ('Date', formatDate(note.returnDate)),
        ('Bill', note.purchaseNumber),
        if (kit.has(note.supplierInvoiceNo))
          ('Your invoice', note.supplierInvoiceNo!),
        ('Reason', note.reason),
        ('Supply', inter ? 'Inter-state (IGST)' : 'Intra-state (CGST + SGST)'),
      ],
      columns: const [
        PdfCol('#', width: 22),
        PdfCol('Description', flex: 1),
        PdfCol('HSN/SAC', width: 46),
        PdfCol('Qty', width: 48, right: true),
        PdfCol('Rate', width: 52, right: true),
        PdfCol('Taxable', width: 56, right: true),
        PdfCol('GST%', width: 32, right: true),
        PdfCol('Total', width: 60, right: true),
      ],
      rows: [
        for (final (i, l) in lines.indexed)
          [
            '${i + 1}',
            l.description,
            l.hsnCode ?? '',
            note.isGoods ? '${formatQty(l.qty)} ${l.unit}' : '',
            formatAmount(l.rate),
            formatAmount(l.taxableValue),
            formatPlain(l.gstRate),
            formatAmount(l.lineTotal),
          ],
      ],
      totals: [
        PdfTotal('Taxable value', formatAmount(note.subtotal)),
        if (!inter || note.cgst != 0) PdfTotal('CGST', formatAmount(note.cgst)),
        if (!inter || note.sgst != 0) PdfTotal('SGST', formatAmount(note.sgst)),
        if (inter || note.igst != 0) PdfTotal('IGST', formatAmount(note.igst)),
        if (note.roundOff != 0)
          PdfTotal('Round off', formatAmount(note.roundOff)),
        PdfTotal('Debit total', formatMoney(note.total), strong: true),
      ],
      words: amountInWords(note.total),
      notes: note.reverseCharge
          ? 'The bill was under reverse charge, so no GST is charged by you on this note.'
          : null,
      noteTitle: 'Tax',
    ),
  );
}
