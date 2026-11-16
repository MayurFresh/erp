import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_doc.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
import 'export_models.dart';

String challanFileName(Challan c) =>
    '${c.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// Delivery challan for goods moving without a sale (CGST rule 55). Taxable
/// value always shows; tax shows for information. Quantities that are not
/// known are marked provisional. The rule asks for three copies, so the
/// printout names the copy.
Future<Uint8List> buildChallanPdf(
  Challan c,
  Company company, {
  PdfBrand? brand,
  pw.ThemeData? theme,
  String copy = 'ORIGINAL FOR CONSIGNEE',
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final state = stateName(c.consigneeState);
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: 'Delivery challan',
      subtitle: copy,
      number: c.number,
      cancelled: c.status == 'cancelled',
      partyTitle: 'Consignee',
      parties: [
        c.consigneeName,
        if (kit.has(c.consigneeAddress)) c.consigneeAddress!,
        if (kit.has(c.consigneeGstin)) 'GSTIN: ${c.consigneeGstin}',
        if (state != null) 'State: $state',
      ],
      details: [
        ('Challan no.', c.number),
        ('Date', formatDate(c.date)),
        ('Reason', challanReasons[c.reason] ?? c.reason),
        if (kit.has(c.reasonNote)) ('Note', c.reasonNote!),
        ('Consignor', c.consignorName),
        if (kit.has(c.consignorGstin)) ('Consignor GSTIN', c.consignorGstin!),
        ('Dispatched from', c.locationName),
        if (kit.has(c.toLocationName)) ('Delivered to', c.toLocationName!),
        if (kit.has(c.vehicleNo)) ('Vehicle no.', c.vehicleNo!),
        if (kit.has(c.transporter)) ('Transporter', c.transporter!),
        if (kit.has(c.ewbNo)) ('E-way bill', c.ewbNo!),
      ],
      columns: const [
        PdfCol('#', width: 22),
        PdfCol('Description', flex: 1),
        PdfCol('HSN', width: 46),
        PdfCol('Qty', width: 58, right: true),
        PdfCol('Taxable value', width: 70, right: true),
        PdfCol('GST%', width: 34, right: true),
        PdfCol('Tax', width: 56, right: true),
      ],
      rows: [
        for (final (i, l) in c.lines.indexed)
          [
            '${i + 1}',
            l.description,
            l.hsnCode ?? '',
            '${formatQty(l.qty)} ${l.unit}${l.provisional ? ' (provisional)' : ''}',
            formatAmount(l.taxableValue),
            formatPlain(l.gstRate),
            formatAmount(l.tax),
          ],
      ],
      totals: [
        PdfTotal('Taxable value', formatAmount(c.taxableTotal)),
        PdfTotal('Tax (for information)', formatAmount(c.taxTotal)),
      ],
      notes: c.notes,
      footerNote:
          'Goods are sent without a sale. Not an invoice. Prepared in triplicate: '
          'consignee, transporter, consignor.',
    ),
  );
}
