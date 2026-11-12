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
import 'credit_note_model.dart';

String creditNoteFileName(CreditNote note) =>
    '${(note.number ?? 'credit-note').replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// A4 credit note (GST sales return) for the customer.
Future<Uint8List> buildCreditNotePdf(
  CreditNote note,
  Company company, {
  Party? party,
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final inter = note.isInterState;
  final lines = note.lines ?? const [];
  final state = stateName(note.placeOfSupply);
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: 'Credit note',
      subtitle: 'Against invoice ${note.invoiceNumber}',
      number: note.number ?? '',
      cancelled: note.isCancelled,
      partyTitle: 'Credit to',
      parties: [
        note.partyName,
        if (kit.has(party?.address)) party!.address!,
        if (kit.has(party?.gstin)) 'GSTIN: ${party!.gstin}',
        'Place of supply: ${state ?? note.placeOfSupply}',
      ],
      details: [
        ('Credit note no.', note.number ?? '-'),
        ('Date', formatDate(note.noteDate)),
        ('Invoice', note.invoiceNumber),
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
            '${formatQty(l.qty)} ${l.unit}',
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
        PdfTotal('Credit total', formatMoney(note.total), strong: true),
      ],
      words: amountInWords(note.total),
      notes: note.restock
          ? 'The returned goods were added back to stock.'
          : null,
      noteTitle: 'Stock',
    ),
  );
}
