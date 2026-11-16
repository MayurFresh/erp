import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/pdf_kit.dart';

String certFileName(String kind, String fy, [String? who]) =>
    'tds-${kind == 'salary' ? 'salary' : 'non-salary'}-certificate-${[fy, ?who].join('-').replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

String _m(Object? v) => pdfLatin1(formatMoney(asDouble(v)));

/// One certificate per page-set. [snapshots] are the `snapshot` objects of
/// `/tds/certificates`: Form 16 / 130 for salary, Form 16A / 131 otherwise.
/// Marked as a working copy: the valid certificate comes from TRACES.
Future<Uint8List> buildCertificatesPdf(
  List<Json> snapshots, {
  pw.ThemeData? theme,
}) async {
  final first = snapshots.isEmpty ? <String, dynamic>{} : snapshots.first;
  final co = asJson(first['deductor']);
  final kit = PdfKit(
    brand: PdfBrand(
      companyName: asString(co['name']),
      addressLines: [if (co['address'] != null) asString(co['address'])],
    ),
    theme: theme,
  );
  final doc = kit.document(title: 'TDS certificates');
  for (final s in snapshots) {
    final salary = s.containsKey('partB');
    doc.addPage(
      pw.MultiPage(
        pageTheme: kit.pageTheme(format: PdfPageFormat.a4, margin: 32),
        build: (ctx) => [
          kit.header(
            title: asString(s['form']),
            subtitle:
                '${asString(s['periodLabel'])}'
                '${salary ? '' : '  |  Quarter ${asString(s['quarter'])}'}',
            badge: 'Working copy',
            badgeColor: kMuted,
          ),
          pw.SizedBox(height: 8),
          ...(salary ? _salary(kit, s) : _nonSalary(kit, s)),
          pw.SizedBox(height: 8),
          kit.muted(asString(s['notice'])),
          if (s['unconfirmed'] == true)
            kit.muted(
              'Form names and section numbers under the Income-tax Act 2025 are unconfirmed.',
            ),
        ],
      ),
    );
  }
  return doc.save();
}

List<pw.Widget> _parties(PdfKit kit, Json s, Json who, String whoLabel) {
  final co = asJson(s['deductor']);
  return [
    kit.twoUp(
      kit.box(
        title: 'Deductor',
        children: [
          kit.kv('Name', asString(co['name'])),
          kit.kv('TAN', asString(co['tan'], '-')),
          kit.kv('PAN', asString(co['pan'], '-')),
        ],
      ),
      kit.box(
        title: whoLabel,
        children: [
          kit.kv('Name', asString(who['name'])),
          kit.kv('PAN', asString(who['pan'], '-')),
        ],
      ),
    ),
  ];
}

List<pw.Widget> _salary(PdfKit kit, Json s) {
  final a = asJson(s['partA']);
  final b = asJson(s['partB']);
  final e = asJson(s['employee']);
  return [
    ..._parties(kit, s, e, 'Employee'),
    kit.sectionTitle('Part A: tax deducted and deposited'),
    kit.table(
      columns: const [
        PdfCol('Quarter', width: 60),
        PdfCol('Deducted', flex: 1, right: true),
        PdfCol('Deposited', flex: 1, right: true),
      ],
      rows: [
        for (final q in asJsonList(a['quarters']))
          ['Q${q['quarter']}', _m(q['deducted']), _m(q['deposited'])],
      ],
      totals: ['Total', _m(a['totalDeducted']), _m(a['totalDeposited'])],
      fontSize: 9,
    ),
    pw.SizedBox(height: 6),
    kit.table(
      columns: const [
        PdfCol('Month', width: 56),
        PdfCol('BSR code', flex: 1),
        PdfCol('Challan serial', flex: 1),
        PdfCol('Deposit date', flex: 1),
        PdfCol('Tax', flex: 1, right: true),
      ],
      rows: [
        for (final d in asJsonList(a['deposits']))
          [
            asString(d['month']),
            asString(d['bsrCode']),
            asString(d['challanSerial']),
            formatDate(asString(d['depositDate'])),
            _m(d['tds']),
          ],
      ],
      fontSize: 9,
    ),
    kit.sectionTitle('Part B: salary and tax'),
    kit.box(
      children: [
        kit.kv('Regime', asString(b['regime']), keyWidth: 150),
        kit.kv('Gross salary', _m(b['grossSalary']), keyWidth: 150),
        kit.kv('Not taxable', _m(b['nonTaxableAllowances']), keyWidth: 150),
        kit.kv('Previous employer', _m(b['previousEmployerIncome']), keyWidth: 150),
        kit.kv('Standard deduction', _m(b['standardDeduction']), keyWidth: 150),
        kit.kv('Professional tax', _m(b['professionalTax']), keyWidth: 150),
        for (final c in asJsonList(b['chapterVIA']))
          kit.kv(asString(c['label']), _m(c['amount']), keyWidth: 150),
        kit.kv('Total income', _m(b['totalIncome']), keyWidth: 150),
        kit.kv('Tax on total income', _m(b['taxOnIncome']), keyWidth: 150),
        kit.kv('Rebate', _m(b['rebate']), keyWidth: 150),
        kit.kv('Surcharge', _m(b['surcharge']), keyWidth: 150),
        kit.kv('Cess', _m(b['cess']), keyWidth: 150),
        kit.kv('Marginal relief', _m(b['marginalRelief']), keyWidth: 150),
        kit.kv('Relief for arrears', _m(b['relief89']), keyWidth: 150),
        kit.kv('Net tax payable', _m(b['netTaxPayable']), keyWidth: 150),
        kit.kv('Tax deducted', _m(b['tdsTotal']), keyWidth: 150),
        kit.kv('Balance', _m(b['balance']), keyWidth: 150),
      ],
    ),
  ];
}

List<pw.Widget> _nonSalary(PdfKit kit, Json s) {
  final d = asJson(s['deductee']);
  return [
    ..._parties(kit, s, d, 'Deductee'),
    kit.sectionTitle('Payments and tax deducted'),
    kit.table(
      columns: const [
        PdfCol('Date', width: 62),
        PdfCol('Section', flex: 2),
        PdfCol('Paid', flex: 1, right: true),
        PdfCol('Rate', width: 38, right: true),
        PdfCol('Tax', flex: 1, right: true),
      ],
      rows: [
        for (final r in asJsonList(s['rows']))
          [
            formatDate(asString(r['date'])),
            asString(r['section']),
            _m(r['amountPaid']),
            '${asString(r['rate'])}%',
            _m(r['tds']),
          ],
      ],
      totals: ['Total', '', '', '', _m(s['totalDeducted'])],
      fontSize: 9,
    ),
    kit.sectionTitle('Deposited with the government'),
    kit.table(
      columns: const [
        PdfCol('Deposit date', flex: 1),
        PdfCol('BSR code', flex: 1),
        PdfCol('Challan serial', flex: 1),
        PdfCol('Tax', flex: 1, right: true),
      ],
      rows: [
        for (final c in asJsonList(s['challans']))
          [
            formatDate(asString(c['depositDate'])),
            asString(c['bsrCode']),
            asString(c['challanSerial']),
            _m(c['tds']),
          ],
      ],
      totals: ['Total', '', '', _m(s['totalDeposited'])],
      fontSize: 9,
    ),
  ];
}
