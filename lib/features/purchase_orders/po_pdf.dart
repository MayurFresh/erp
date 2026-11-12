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
import 'po_models.dart';

String poFileName(PurchaseOrder po) =>
    '${(po.number ?? 'purchase-order').replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// A4 purchase order to send to the vendor.
Future<Uint8List> buildPurchaseOrderPdf(
  PurchaseOrder po,
  Company company, {
  Party? vendor,
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final inter = po.isInterState;
  final lines = po.lines ?? const <PoLine>[];
  final state = stateName(po.placeOfSupply);
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: 'Purchase order',
      number: po.number ?? '',
      cancelled: po.isCancelled,
      partyTitle: 'Vendor',
      parties: [
        po.partyName,
        if (kit.has(vendor?.address)) vendor!.address!,
        if (kit.has(po.partyGstin)) 'GSTIN: ${po.partyGstin}',
        if (kit.has(vendor?.phone)) 'Phone: ${vendor!.phone}',
      ],
      details: [
        ('PO no.', po.number ?? '-'),
        ('Date', formatDate(po.orderDate)),
        if (po.expectedDate != null)
          ('Expected by', formatDate(po.expectedDate)),
        ('Deliver to', po.locationName),
        ('Place of supply', state ?? po.placeOfSupply),
      ],
      columns: const [
        PdfCol('#', width: 22),
        PdfCol('Item', flex: 1),
        PdfCol('HSN/SAC', width: 46),
        PdfCol('Qty', width: 50, right: true),
        PdfCol('Rate', width: 54, right: true),
        PdfCol('Disc%', width: 34, right: true),
        PdfCol('GST%', width: 32, right: true),
        PdfCol('Amount', width: 62, right: true),
      ],
      rows: [
        for (final (i, l) in lines.indexed)
          [
            '${i + 1}',
            l.description.isEmpty ? l.itemName : l.description,
            l.hsnCode ?? '',
            '${formatQty(l.qty)} ${l.unit}',
            formatAmount(l.rate),
            l.discountPct == 0 ? '-' : formatPlain(l.discountPct),
            formatPlain(l.gstRate),
            formatAmount(l.lineTotal),
          ],
      ],
      totals: [
        PdfTotal('Taxable value', formatAmount(po.subtotal)),
        if (!inter || po.cgst != 0) PdfTotal('CGST', formatAmount(po.cgst)),
        if (!inter || po.sgst != 0) PdfTotal('SGST', formatAmount(po.sgst)),
        if (inter || po.igst != 0) PdfTotal('IGST', formatAmount(po.igst)),
        if (po.roundOff != 0) PdfTotal('Round off', formatAmount(po.roundOff)),
        PdfTotal('Order total', formatMoney(po.total), strong: true),
      ],
      words: amountInWords(po.total),
      notes: po.notes,
      noteTitle: 'Notes and delivery terms',
    ),
  );
}
