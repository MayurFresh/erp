import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_doc.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
import 'rfq_models.dart';

String rfqFileName(Rfq r) =>
    '${r.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// A4 request for quotation, with blank columns for the vendor to fill.
Future<Uint8List> buildRfqPdf(
  Rfq r,
  Company company, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: 'Request for quotation',
      number: r.number,
      partyTitle: 'Vendors',
      parties: [for (final v in r.vendors) v.partyName],
      details: [
        ('RFQ no.', r.number),
        ('Date', formatDate(r.rfqDate)),
        if (r.dueDate != null) ('Reply by', formatDate(r.dueDate)),
        ('Deliver to', r.locationName),
      ],
      columns: const [
        PdfCol('#', width: 22),
        PdfCol('Item', flex: 1),
        PdfCol('Qty', width: 60, right: true),
        PdfCol('Rate', width: 60, right: true),
        PdfCol('GST%', width: 40, right: true),
        PdfCol('Lead days', width: 56, right: true),
      ],
      rows: [
        for (final (i, l) in r.lines.indexed)
          ['${i + 1}', l.itemName, '${formatQty(l.qty)} ${l.unit}', '', '', ''],
      ],
      notes:
          'Please give rate, discount, GST, delivery time, payment terms and '
          'how long the quote is valid.${r.notes == null ? '' : '\n${r.notes}'}',
      noteTitle: 'Terms',
    ),
  );
}
