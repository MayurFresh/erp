import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
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
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final doc = kit.document(
    title: 'Demand ${demand.number}',
    subject: demand.partyName,
  );
  final hasBank = kit.has(company.bankName) || kit.has(company.bankAccountNo);
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(
        background: demand.isCancelled
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
      header: (context) => context.pageNumber == 1
          ? pw.SizedBox()
          : kit.compactHeader('Demand ${demand.number}'),
      footer: (context) =>
          kit.footer(context, left: '${demand.number}  |  ${company.name}'),
      build: (context) => [
        kit.header(
          title: 'DEMAND LETTER',
          badge: demand.isCancelled ? 'CANCELLED' : null,
        ),
        pw.SizedBox(height: 12),
        kit.twoUp(
          kit.box(
            title: 'To',
            children: [
              kit.text(demand.partyName, size: 10, bold: true),
              if (kit.has(party?.address)) kit.text(party!.address!),
              if (kit.has(party?.gstin)) kit.text('GSTIN: ${party!.gstin}'),
            ],
          ),
          kit.box(
            title: 'Demand details',
            children: [
              kit.kv('Demand no.', demand.number),
              kit.kv('Date', formatDate(demand.date)),
              kit.kv('Due date', formatDate(demand.dueDate)),
              kit.kv('Booking', demand.bookingNumber),
              kit.kv('Unit', demand.unitCode),
            ],
          ),
        ),
        pw.SizedBox(height: 14),
        kit.text(
          'Dear ${demand.partyName}, as per the payment plan of your '
          'booking${booking == null ? '' : ' in ${booking.projectName}'}, '
          'the following stages are now due.',
          size: 9.5,
          height: 1.5,
        ),
        pw.SizedBox(height: 10),
        kit.table(
          columns: const [
            PdfCol('Stage', flex: 1),
            PdfCol('%', width: 60, right: true),
            PdfCol('Amount', width: 110, right: true),
          ],
          rows: [
            for (final s in demand.stages)
              [s.name, formatPlain(s.pct), formatMoney(s.amount)],
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 3,
              child: kit.wordsStrip(amountInWords(demand.total)),
            ),
            pw.SizedBox(width: 12),
            pw.Expanded(
              flex: 2,
              child: kit.totalsBox([
                kit.totalRow('Amount', formatMoney(demand.amount)),
                if (demand.cgst > 0)
                  kit.totalRow('CGST', formatMoney(demand.cgst)),
                if (demand.sgst > 0)
                  kit.totalRow('SGST', formatMoney(demand.sgst)),
                pw.Divider(color: kLine, thickness: 0.6, height: 8),
                kit.totalRow(
                  'Total due',
                  formatMoney(demand.total),
                  strong: true,
                ),
                if (demand.amountPaid > 0) ...[
                  kit.totalRow('Received', formatMoney(demand.amountPaid)),
                  kit.totalRow(
                    'Balance',
                    formatMoney(demand.amountDue),
                    strong: true,
                    color: kDanger,
                  ),
                ],
              ]),
            ),
          ],
        ),
        pw.SizedBox(height: 14),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child: hasBank
                  ? kit.box(
                      title: 'Pay to',
                      children: [
                        if (kit.has(company.bankName))
                          kit.kv('Bank', company.bankName!, keyWidth: 46),
                        if (kit.has(company.bankAccountNo))
                          kit.kv(
                            'A/c no.',
                            company.bankAccountNo!,
                            keyWidth: 46,
                          ),
                        if (kit.has(company.bankIfsc))
                          kit.kv('IFSC', company.bankIfsc!, keyWidth: 46),
                      ],
                    )
                  : pw.SizedBox(),
            ),
            pw.SizedBox(width: 16),
            kit.signature(),
          ],
        ),
      ],
    ),
  );
  return doc.save();
}
