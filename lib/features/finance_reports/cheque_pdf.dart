import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_in_words.dart';
import '../../core/money.dart';
import '../../core/pdf_kit.dart' show pdfLatin1;
import 'finance_models.dart';

/// `2000` → `**2,000.00/-`.
String chequeAmountText(double amount) => '**${formatAmount(amount)}/-';

/// A one-page PDF the size of the cheque leaf with each field at its
/// layout position (millimetres from the top left).
Future<Uint8List> buildChequePdf(ChequePrint data) async {
  final l = data.layout;
  const mm = PdfPageFormat.mm;
  final doc = pw.Document();
  final base = pw.TextStyle(fontSize: 11);

  pw.Widget at(String field, pw.Widget child) {
    final p = l.fields[field]!;
    return pw.Positioned(left: p.$1 * mm, top: p.$2 * mm, child: child);
  }

  final words = pdfLatin1(amountInWords(data.amount));
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(l.widthMm * mm, l.heightMm * mm, marginAll: 0),
      build: (context) => pw.Stack(
        children: [
          // One digit per box of the printed date.
          for (var i = 0; i < data.dateText.length; i++)
            pw.Positioned(
              left: (l.fields['date']!.$1 + i * l.dateGap) * mm,
              top: l.fields['date']!.$2 * mm,
              child: pw.Text(data.dateText[i], style: base),
            ),
          at('payee', pw.Text(pdfLatin1(data.payee), style: base)),
          at(
            'words',
            pw.SizedBox(
              width: l.wordsMaxWidth * mm,
              child: pw.Text(words, style: base),
            ),
          ),
          at('amount', pw.Text(chequeAmountText(data.amount), style: base)),
          at(
            'acPayee',
            pw.Text('A/C PAYEE ONLY', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
