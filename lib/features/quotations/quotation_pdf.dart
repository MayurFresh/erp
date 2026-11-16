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
import 'quotation_models.dart';

String quotationFileName(Quotation q) =>
    '${q.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// A4 quotation or proforma invoice with a valid-until line and a terms
/// block.
Future<Uint8List> buildQuotationPdf(
  Quotation q,
  Company company, {
  Party? party,
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final state = stateName(q.placeOfSupply);
  final label = kindLabel(q.kind);
  final tax = q.taxSplit;
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: label,
      subtitle: q.validUntil == null
          ? null
          : 'Valid until ${formatDate(q.validUntil)}',
      number: q.number,
      cancelled: q.status == 'cancelled',
      partyTitle: 'Customer',
      parties: [
        q.partyName,
        if (kit.has(party?.address)) party!.address!,
        if (kit.has(party?.gstin)) 'GSTIN: ${party!.gstin}',
        if (kit.has(party?.phone)) 'Phone: ${party!.phone}',
      ],
      details: [
        ('$label no.', q.number),
        ('Date', formatDate(q.quoteDate)),
        if (q.validUntil != null) ('Valid until', formatDate(q.validUntil)),
        if (kit.has(q.locationName)) ('Issued from', q.locationName),
        if (state != null) ('Place of supply', state),
      ],
      columns: const [
        PdfCol('#', width: 22),
        PdfCol('Item', flex: 1),
        PdfCol('Qty', width: 54, right: true),
        PdfCol('Rate', width: 56, right: true),
        PdfCol('Disc', width: 44, right: true),
        PdfCol('GST%', width: 34, right: true),
        PdfCol('Amount', width: 66, right: true),
      ],
      rows: [
        for (final (i, l) in q.lines.indexed)
          [
            '${i + 1}',
            l.description.isEmpty ? l.itemName : l.description,
            '${formatQty(l.qty)} ${l.unit}',
            formatAmount(l.rate),
            l.discountAmount > 0
                ? formatAmount(l.discountAmount)
                : l.discountPct > 0
                ? '${formatPlain(l.discountPct)}%'
                : '-',
            formatPlain(l.gstRate),
            formatAmount(l.taxable),
          ],
      ],
      totals: [
        PdfTotal('Amount before tax', formatAmount(q.subtotal)),
        if (tax.igst > 0)
          PdfTotal('IGST', formatAmount(tax.igst))
        else ...[
          if (tax.cgst > 0) PdfTotal('CGST', formatAmount(tax.cgst)),
          if (tax.sgst > 0) PdfTotal('SGST', formatAmount(tax.sgst)),
        ],
        if (tax.igst + tax.cgst + tax.sgst == 0 && q.taxTotal > 0)
          PdfTotal('Tax', formatAmount(q.taxTotal)),
        PdfTotal('Total', formatMoney(q.total), strong: true),
      ],
      words: amountInWords(q.total),
      notes: q.notes,
      blocks: [
        if (kit.has(q.terms))
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [kit.sectionTitle('Terms'), kit.text(q.terms!)],
          ),
      ],
    ),
  );
}
