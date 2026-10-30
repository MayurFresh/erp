import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/money.dart';
import '../company/company_model.dart';
import '../invoices/invoice_pdf.dart' show pdfLatin1;
import '../parties/party_model.dart';
import 're_models.dart';

String demandFileName(Demand demand) =>
    'demand-${demand.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}.pdf';

/// Builds the demand letter sent to the buyer. Without a [theme] the
/// built-in PDF fonts are used and text is transliterated to Latin-1.
Future<Uint8List> buildDemandPdf(
  Demand demand,
  Company company, {
  Party? party,
  Booking? booking,
  pw.ThemeData? theme,
}) {
  final clean = theme == null ? pdfLatin1 : (String s) => s;
  final doc = pw.Document(
    title: 'Demand ${demand.number}',
    author: company.name,
    creator: 'Progen ERP',
  );
  const grey = PdfColors.grey700;
  pw.Widget text(String s, {pw.TextStyle? style}) =>
      pw.Text(clean(s), style: style);
  final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);
  pw.Widget row(String label, String value, {bool strong = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            text(label, style: strong ? bold : null),
            text(value, style: strong ? bold : null),
          ],
        ),
      );
  doc.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        theme:
            theme ??
            pw.ThemeData.withFont(
              base: pw.Font.helvetica(),
              bold: pw.Font.helveticaBold(),
            ),
        buildBackground: demand.isCancelled
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
      build: (context) => [
        text(
          company.legalName ?? company.name,
          style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
        ),
        if ((company.address ?? '').isNotEmpty)
          text(company.address!, style: const pw.TextStyle(color: grey)),
        if ((company.gstin ?? '').isNotEmpty)
          text(
            'GSTIN ${company.gstin}',
            style: const pw.TextStyle(color: grey),
          ),
        pw.Divider(),
        pw.Center(
          child: text(
            'DEMAND LETTER',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
        ),
        pw.SizedBox(height: 12),
        row('Demand no.', demand.number),
        row('Date', formatDate(demand.date)),
        row('Due date', formatDate(demand.dueDate)),
        row('Booking', demand.bookingNumber),
        row('Unit', demand.unitCode),
        pw.SizedBox(height: 12),
        text('To', style: const pw.TextStyle(color: grey)),
        text(demand.partyName, style: bold),
        if ((party?.address ?? '').isNotEmpty) text(party!.address!),
        if ((party?.gstin ?? '').isNotEmpty) text('GSTIN ${party!.gstin}'),
        pw.SizedBox(height: 16),
        text(
          'Dear ${demand.partyName}, as per the payment plan of your '
          'booking${booking == null ? '' : ' in ${booking.projectName}'}, '
          'the following stages are now due.',
        ),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: [clean('Stage'), clean('%'), clean('Amount')],
          data: [
            for (final s in demand.stages)
              [clean(s.name), formatPlain(s.pct), formatMoney(s.amount)],
          ],
          headerStyle: bold,
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerRight,
            2: pw.Alignment.centerRight,
          },
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
        ),
        pw.SizedBox(height: 8),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.SizedBox(
            width: 240,
            child: pw.Column(
              children: [
                row('Amount', formatMoney(demand.amount)),
                if (demand.cgst > 0) row('CGST', formatMoney(demand.cgst)),
                if (demand.sgst > 0) row('SGST', formatMoney(demand.sgst)),
                pw.Divider(),
                row('Total due', formatMoney(demand.total), strong: true),
                if (demand.amountPaid > 0)
                  row('Received', formatMoney(demand.amountPaid)),
                if (demand.amountPaid > 0)
                  row('Balance', formatMoney(demand.amountDue), strong: true),
              ],
            ),
          ),
        ),
        pw.SizedBox(height: 8),
        text(
          'Amount in words: ${amountInWords(demand.total)}',
          style: const pw.TextStyle(fontSize: 9),
        ),
        pw.SizedBox(height: 16),
        if ((company.bankName ?? '').isNotEmpty ||
            (company.bankAccountNo ?? '').isNotEmpty)
          text(
            'Pay to: ${company.bankName ?? ''} A/c ${company.bankAccountNo ?? ''}'
            '${(company.bankIfsc ?? '').isEmpty ? '' : ' IFSC ${company.bankIfsc}'}',
            style: const pw.TextStyle(fontSize: 9),
          ),
        pw.SizedBox(height: 32),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: text('For ${company.legalName ?? company.name}', style: bold),
        ),
      ],
    ),
  );
  return doc.save();
}
