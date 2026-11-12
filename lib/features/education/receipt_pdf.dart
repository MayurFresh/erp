import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'education_models.dart';

String receiptFileName(ReceiptData d) =>
    'fee-receipt-${d.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}.pdf';

String modeLabel(String mode) => switch (mode) {
  'upi' => 'UPI',
  'bank' => 'Bank transfer',
  'cheque' => 'Cheque',
  'card' => 'Card',
  _ => 'Cash',
};

/// The A5 fee receipt: school header, student and class, the bills paid with
/// their heads, the amount in words and the balance still due. Without a
/// [theme] the built-in PDF fonts are used and text is transliterated.
Future<Uint8List> buildFeeReceiptPdf(
  ReceiptData d, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final b =
      brand ??
      PdfBrand(
        companyName: d.schoolName,
        addressLines: [if (d.schoolAddress != null) d.schoolAddress!],
        contactLine: d.schoolPhone == null ? null : 'Phone: ${d.schoolPhone}',
      );
  final kit = PdfKit(brand: b, theme: theme);
  final doc = kit.document(
    title: 'Fee receipt ${d.number}',
    subject: d.studentName,
  );
  final colour = kit.brand.color;
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(format: PdfPageFormat.a5, margin: 26),
      footer: (c) => kit.footer(c, left: '${d.number}  |  ${d.schoolName}'),
      build: (c) => [
        kit.header(title: 'Fee receipt', subtitle: d.number),
        pw.SizedBox(height: 8),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.kv('Student', d.studentName, keyWidth: 62),
                  kit.kv('Admission no.', d.admissionNo, keyWidth: 62),
                  if (kit.has(d.className))
                    kit.kv(
                      'Class',
                      d.rollNo == null
                          ? d.className!
                          : '${d.className}, roll ${d.rollNo}',
                      keyWidth: 62,
                    ),
                  kit.kv('Parent', d.guardianName, keyWidth: 62),
                ],
              ),
            ),
            pw.SizedBox(width: 10),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.kv('Date', formatDate(d.date), keyWidth: 50),
                  kit.kv('Paid by', modeLabel(d.mode), keyWidth: 50),
                  if (kit.has(d.reference))
                    kit.kv('Reference', d.reference!, keyWidth: 50),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        for (final p in d.paidFor) ...[
          kit.sectionTitle(
            '${p.label ?? 'Fee bill'}  ${p.invoiceNumber}'
            '${p.paid + 0.004 < p.invoiceTotal ? '  (part payment)' : ''}',
          ),
          kit.table(
            columns: const [
              PdfCol('Head', flex: 3),
              PdfCol('Amount', width: 70, right: true),
            ],
            rows: [
              for (final h in p.heads) [h.description, formatAmount(h.amount)],
            ],
            totals: ['Paid now', formatAmount(p.paid)],
          ),
          pw.SizedBox(height: 6),
        ],
        pw.SizedBox(height: 2),
        kit.totalsBox([
          kit.totalRow(
            'Amount received',
            formatAmount(d.amount),
            strong: true,
            color: colour,
          ),
          kit.totalRow(
            'Balance still due',
            formatAmount(d.balance),
            color: d.balance > 0.004 ? kDanger : kInk,
          ),
        ]),
        pw.SizedBox(height: 6),
        kit.wordsStrip(amountInWords(d.amount)),
        pw.SizedBox(height: 14),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: kit.signature(role: 'Received by', width: 150),
        ),
      ],
    ),
  );
  return doc.save();
}
