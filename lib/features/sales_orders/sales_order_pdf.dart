import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/india_states.dart';
import '../../core/entered_unit.dart';
import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_doc.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
import '../parties/party_model.dart';
import 'sales_order_models.dart';

String salesOrderFileName(SalesOrder order) =>
    '${order.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// A4 sales order; a draft prints as a quotation.
Future<Uint8List> buildSalesOrderPdf(
  SalesOrder order,
  Company company, {
  Party? party,
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final quote = order.isDraft;
  final state = stateName(order.placeOfSupply);
  double amount(SalesOrderLine l) =>
      l.qtyOrdered * l.rate * (1 - l.discountPct / 100);
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: quote ? 'Quotation' : 'Sales order',
      subtitle: quote ? 'Valid until accepted by you' : null,
      number: order.number,
      cancelled: order.status == 'cancelled',
      partyTitle: 'Customer',
      parties: [
        order.partyName,
        if (kit.has(party?.address)) party!.address!,
        if (kit.has(party?.gstin)) 'GSTIN: ${party!.gstin}',
        if (kit.has(party?.phone)) 'Phone: ${party!.phone}',
      ],
      details: [
        ('${quote ? 'Quotation' : 'Order'} no.', order.number),
        ('Date', formatDate(order.orderDate)),
        if (order.expectedDate != null)
          ('Delivery by', formatDate(order.expectedDate)),
        if (kit.has(order.externalRef)) ('Your reference', order.externalRef!),
        if (kit.has(order.locationName)) ('Dispatch from', order.locationName),
        if (state != null) ('Place of supply', state),
      ],
      columns: const [
        PdfCol('#', width: 22),
        PdfCol('Item', flex: 1),
        PdfCol('Qty', width: 54, right: true),
        PdfCol('Rate', width: 56, right: true),
        PdfCol('Disc%', width: 36, right: true),
        PdfCol('GST%', width: 34, right: true),
        PdfCol('Amount', width: 66, right: true),
      ],
      rows: [
        for (final (i, l) in order.lines.indexed)
          [
            '${i + 1}',
            l.description.isEmpty ? l.itemName : l.description,
            lineQtyText(l.qtyOrdered, l.unit, l.entered),
            lineRateText(l.rate, l.entered),
            l.discountPct == 0 ? '-' : formatPlain(l.discountPct),
            formatPlain(l.gstRate),
            formatAmount(amount(l)),
          ],
      ],
      totals: [
        PdfTotal('Amount before tax', formatAmount(order.subtotal)),
        PdfTotal('Tax', formatAmount(order.taxTotal)),
        PdfTotal('Total', formatMoney(order.total), strong: true),
      ],
      words: amountInWords(order.total),
      notes: order.notes,
    ),
  );
}
