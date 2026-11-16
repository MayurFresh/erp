import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';

/// The lines of a settlement as (label, amount) pairs, split into earnings and deductions.
({List<(String, num)> earnings, List<(String, num)> deductions}) fnfLines(Json detail) {
  final result = asJson(detail['result']);
  final line = asJson(result['line']);
  final earn = <(String, num)>[], ded = <(String, num)>[];
  if (result['pendingSalaryPaid'] != true) {
    for (final e in asJsonList(line['earnings'])) {
      earn.add(('Pending salary: ${e['name']}', (e['amount'] as num?) ?? 0));
    }
  }
  for (final l in asJsonList(result['oneTimeLines'])) {
    final a = (l['amount'] as num?) ?? 0;
    (l['kind'] == 'deduction' ? ded : earn).add(('${l['label']}', a));
  }
  for (final p in [
    ('Provident fund', line['pfEmployee']),
    ('ESI', line['esiEmployee']),
    ('Professional tax', line['pt']),
    ('Labour welfare fund', line['lwfEmployee']),
    ('Income tax (TDS)', line['tds']),
  ]) {
    final a = (p.$2 as num?) ?? 0;
    if (a > 0) ded.add((p.$1, a));
  }
  return (earnings: earn, deductions: ded);
}

String fnfFileName(Json d) => 'settlement-${d['employeeCode']}-${d['exitDate']}.pdf'.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');

Future<Uint8List> buildFnfPdf(Json d, Company company, {pw.ThemeData? theme, PdfBrand? brand}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(company.name), theme: theme);
  final doc = kit.document(title: 'Full and final settlement ${d['number']}');
  final emp = asJson(asJson(d['result'])['employee']);
  final lines = fnfLines(d);
  pw.Widget row(String l, String r, {bool bold = false}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [pw.Expanded(child: kit.text(l, size: 10, bold: bold)), kit.text(r, size: 10, bold: bold)],
    ),
  );
  pw.Widget block(String title, List<(String, num)> items, String total, num sum) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      kit.text(title, size: 11, bold: true),
      pw.Divider(color: kLine, thickness: 0.6, height: 8),
      if (items.isEmpty) kit.text('None', size: 10),
      for (final i in items) row(i.$1, formatMoney(i.$2)),
      pw.Divider(color: kLine, thickness: 0.6, height: 8),
      row(total, formatMoney(sum), bold: true),
    ],
  );
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(format: PdfPageFormat.a4, margin: 36),
      build: (_) => [
        kit.text(company.name, size: 16, bold: true),
        kit.text('Full and final settlement ${d['number']}', size: 12),
        pw.SizedBox(height: 10),
        row('Employee', '${emp['name'] ?? ''} (${emp['code'] ?? ''})'),
        row('Designation', '${emp['designation'] ?? '-'}'),
        row('Date of joining', formatDate(emp['joiningDate'])),
        row('Last working day', formatDate(d['exitDate'])),
        pw.SizedBox(height: 12),
        block('Payments', lines.earnings, 'Total payments', (d['gross'] as num?) ?? 0),
        pw.SizedBox(height: 12),
        block('Deductions', lines.deductions, 'Total deductions', (d['deductions'] as num?) ?? 0),
        pw.SizedBox(height: 12),
        row('Net amount payable', formatMoney((d['net'] as num?) ?? 0), bold: true),
        pw.SizedBox(height: 24),
        kit.text('The employee confirms receipt of the net amount in full and final settlement of all dues.', size: 9),
        pw.SizedBox(height: 36),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [kit.text('Employee signature', size: 9), kit.text('For ${company.name}', size: 9)],
        ),
      ],
    ),
  );
  return doc.save();
}
