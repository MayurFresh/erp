import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_doc.dart';
import '../../core/pdf_kit.dart';
import '../accounts/account_model.dart';
import '../company/company_model.dart';
import 'party_model.dart';

String statementFileName(Party party) =>
    'statement-${party.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// Statement of account for a customer or vendor over a period.
Future<Uint8List> buildStatementPdf(
  Party party,
  Ledger ledger,
  Company company, {
  pw.ThemeData? theme,
  PdfBrand? brand,
  List<(String, String)> extraDetails = const [],
}) {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final period = '${formatDate(ledger.from)} to ${formatDate(ledger.to)}';
  final customer = party.isCustomer;
  return buildDocPdf(
    kit,
    DocPdfSpec(
      title: 'Statement of account',
      subtitle: period,
      number: party.name,
      partyTitle: customer ? 'Customer' : 'Vendor',
      parties: [
        party.name,
        if (kit.has(party.address)) party.address!,
        if (kit.has(party.gstin)) 'GSTIN: ${party.gstin}',
        if (kit.has(party.phone)) 'Phone: ${party.phone}',
      ],
      details: [
        ('Period', period),
        ('Opening balance', formatMoney(ledger.openingBalance)),
        ('Closing balance', formatMoney(ledger.closingBalance)),
        ...extraDetails,
      ],
      columns: const [
        PdfCol('Date', width: 58),
        PdfCol('Type', width: 58),
        PdfCol('Number', width: 82),
        PdfCol('Details', flex: 1),
        PdfCol('Debit', width: 58, right: true),
        PdfCol('Credit', width: 58, right: true),
        PdfCol('Balance', width: 64, right: true),
      ],
      rows: [
        [
          formatDate(ledger.from),
          '',
          '',
          'Opening balance',
          '',
          '',
          formatAmount(ledger.openingBalance),
        ],
        for (final l in ledger.lines)
          [
            formatDate(l.date),
            _sentence(l.voucherType.replaceAll('_', ' ')),
            l.number ?? '',
            l.narration ?? '',
            l.debit == 0 ? '' : formatAmount(l.debit),
            l.credit == 0 ? '' : formatAmount(l.credit),
            formatAmount(l.balance),
          ],
      ],
      totalsRow: [
        '',
        '',
        '',
        'Closing balance',
        formatAmount(ledger.totalDebit),
        formatAmount(ledger.totalCredit),
        formatAmount(ledger.closingBalance),
      ],
      totals: [
        PdfTotal('Opening balance', formatAmount(ledger.openingBalance)),
        PdfTotal('Total debit', formatAmount(ledger.totalDebit)),
        PdfTotal('Total credit', formatAmount(ledger.totalCredit)),
        PdfTotal(
          'Closing balance',
          formatMoney(ledger.closingBalance),
          strong: true,
        ),
      ],
      signature: false,
      footerNote: 'Statement',
    ),
  );
}

String _sentence(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
