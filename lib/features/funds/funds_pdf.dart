import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'funds_models.dart';

String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');

String ucFileName(UcData d) =>
    'utilisation-certificate-${_safe(d.fundName)}-${d.from}-to-${d.to}.pdf';
String receiptFileName(ReceiptData d) =>
    'donation-receipt-${_safe(d.donation.receiptNo)}.pdf';

/// Utilisation certificate: opening balance, grants received, spending by head,
/// closing balance and a signature block. Without a [theme] the built-in
/// fonts are used and text is transliterated to Latin-1.
Future<Uint8List> buildUcPdf(UcData d, {pw.ThemeData? theme, PdfBrand? brand}) {
  final kit = PdfKit(
    brand: brand ?? PdfBrand.plain(d.companyName),
    theme: theme,
  );
  final doc = kit.document(
    title: 'Utilisation certificate ${d.fundName}',
    subject: '${d.from} to ${d.to}',
  );
  pw.Widget money(String label, double v, {bool bold = false}) =>
      kit.totalRow(label, formatAmount(v), strong: bold);
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(),
      footer: (c) =>
          kit.footer(c, left: 'Utilisation certificate  |  ${d.fundName}'),
      header: (c) => c.pageNumber == 1
          ? kit.header(
              title: 'Utilisation Certificate',
              subtitle: '${formatDate(d.from)} to ${formatDate(d.to)}',
            )
          : kit.compactHeader('Utilisation Certificate'),
      build: (c) => [
        pw.SizedBox(height: 10),
        kit.box(
          title: 'Fund',
          children: [
            kit.kv('Fund or scheme', d.fundName, keyWidth: 100),
            if (kit.has(d.sponsor))
              kit.kv('Sponsor', d.sponsor!, keyWidth: 100),
            if (kit.has(d.sanctionNo))
              kit.kv(
                'Sanction order',
                '${d.sanctionNo}${kit.has(d.sanctionDate) ? ' dated ${formatDate(d.sanctionDate)}' : ''}',
                keyWidth: 100,
              ),
            if (d.sanctionedAmount > 0)
              kit.kv(
                'Sanctioned amount',
                formatAmount(d.sanctionedAmount),
                keyWidth: 100,
              ),
            kit.kv(
              'Period',
              '${formatDate(d.from)} to ${formatDate(d.to)}',
              keyWidth: 100,
            ),
          ],
        ),
        pw.SizedBox(height: 12),
        kit.sectionTitle('Funds received in the period'),
        if (d.receipts.isEmpty)
          kit.muted('No receipts in this period.')
        else
          kit.table(
            columns: const [
              PdfCol('Date', width: 70),
              PdfCol('Receipt', flex: 3),
              PdfCol('Amount', width: 90, right: true),
            ],
            rows: [
              for (final r in d.receipts)
                [formatDate(r.code), r.name, formatAmount(r.amount)],
            ],
            totals: ['', 'Total received', formatAmount(d.received)],
          ),
        pw.SizedBox(height: 12),
        kit.sectionTitle('Expenditure by head'),
        if (d.spentByHead.isEmpty)
          kit.muted('No spending in this period.')
        else
          kit.table(
            columns: const [
              PdfCol('Head', width: 90),
              PdfCol('Description', flex: 3),
              PdfCol('Amount', width: 90, right: true),
            ],
            rows: [
              for (final r in d.spentByHead)
                [r.code, r.name, formatAmount(r.amount)],
            ],
            totals: ['', 'Total expenditure', formatAmount(d.spent)],
          ),
        pw.SizedBox(height: 12),
        kit.totalsBox([
          money('Opening balance', d.opening),
          money('Add: received in the period', d.received),
          money('Less: spent in the period', d.spent),
          money('Closing balance', d.closing, bold: true),
        ]),
        if (d.returnUnspent) ...[
          pw.SizedBox(height: 6),
          kit.text(
            d.refundDue > 0
                ? 'Unspent balance of ${formatAmount(d.refundDue)} is to be returned to the sponsor.'
                : 'No unspent balance to return.',
            size: 8.5,
            bold: true,
          ),
        ],
        pw.SizedBox(height: 14),
        kit.text(
          'Certified that out of the funds received for the purpose above, the amounts shown have been spent for the purpose '
          'for which they were sanctioned, and that the closing balance is as stated. Records are available for audit.',
          size: 8.5,
          height: 1.4,
        ),
        pw.SizedBox(height: 28),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            kit.signature(role: 'Prepared by (Accounts)', width: 150),
            kit.signature(
              role: 'Drawing and Disbursing Officer / Treasurer',
              width: 170,
            ),
            kit.signature(role: 'Head of Office / Secretary', width: 150),
          ],
        ),
        pw.SizedBox(height: 6),
        kit.muted('Place: ____________    Date: ____________'),
      ],
    ),
  );
  return doc.save();
}

/// Donation receipt with the trust's 80G details, donor PAN and amount in words.
Future<Uint8List> buildReceiptPdf(
  ReceiptData d, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(d.trustName), theme: theme);
  final n = d.donation;
  final doc = kit.document(
    title: 'Donation receipt ${n.receiptNo}',
    subject: d.donorName,
  );
  final regLine = kit.has(d.reg80gNo)
      ? 'Registered under section 80G of the Income Tax Act, 1961. Registration no. ${d.reg80gNo}'
            '${kit.has(d.reg80gFrom) || kit.has(d.reg80gTo) ? ', valid ${kit.has(d.reg80gFrom) ? 'from ${formatDate(d.reg80gFrom)} ' : ''}${kit.has(d.reg80gTo) ? 'to ${formatDate(d.reg80gTo)}' : ''}' : ''}.'
      : null;
  doc.addPage(
    pw.Page(
      pageTheme: kit.pageTheme(format: PdfPageFormat.a5.landscape, margin: 26),
      build: (c) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          kit.header(
            title: 'Donation Receipt',
            subtitle: 'No. ${n.receiptNo}',
            badge: n.cancelled ? 'CANCELLED' : null,
          ),
          pw.SizedBox(height: 8),
          if (kit.has(d.trustPan)) kit.muted('Trust PAN: ${d.trustPan}'),
          if (regLine != null) kit.text(regLine, size: 8, bold: true),
          pw.SizedBox(height: 8),
          kit.twoUp(
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                kit.kv('Received from', d.donorName, keyWidth: 78),
                if (kit.has(d.donorPan))
                  kit.kv('PAN', d.donorPan!, keyWidth: 78),
                if (kit.has(d.donorAadhaar))
                  kit.kv('Aadhaar', d.donorAadhaar!, keyWidth: 78),
                if (kit.has(d.donorAddress))
                  kit.kv('Address', d.donorAddress!, keyWidth: 78),
              ],
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                kit.kv('Date', formatDate(n.date), keyWidth: 70),
                kit.kv('Mode', donationModes[n.mode] ?? n.mode, keyWidth: 70),
                if (kit.has(d.reference))
                  kit.kv('Reference', d.reference!, keyWidth: 70),
                if (kit.has(n.purpose))
                  kit.kv('Purpose', n.purpose!, keyWidth: 70),
                if (n.isCorpus) kit.kv('Towards', 'Corpus fund', keyWidth: 70),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          kit.box(
            children: [
              pw.Row(
                children: [
                  pw.Expanded(
                    child: kit.text('Amount received', size: 10, bold: true),
                  ),
                  kit.text(
                    formatAmount(n.amount),
                    size: 16,
                    bold: true,
                    color: kit.brand.color,
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 6),
          kit.wordsStrip(amountInWords(n.amount)),
          pw.SizedBox(height: 6),
          if (n.tax80g && n.deductionEligible)
            kit.text(
              'This donation is eligible for deduction under section 80G, subject to the limits of the Act.',
              size: 8,
            )
          else if (n.tax80g)
            kit.text(
              'No deduction under section 80G can be claimed for this donation: cash donations above Rs 2,000 are not eligible.',
              size: 8,
              bold: true,
              color: kDanger,
            ),
          if (kit.has(d.footer)) ...[
            pw.SizedBox(height: 4),
            kit.muted(d.footer!),
          ],
          pw.Spacer(),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: kit.signature(width: 190),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
