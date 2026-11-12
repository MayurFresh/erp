import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
import 'hr_models.dart';

String payslipFileName(Payslip p) =>
    'payslip-${asString(p.employee['code'])}-${p.month}.pdf'.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');

Future<Uint8List> buildPayslipPdf(Payslip p, Company company, {pw.ThemeData? theme, PdfBrand? brand}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(company.name), theme: theme);
  final doc = kit.document(title: 'Payslip ${monthLabel(p.month)}');
  pw.Widget row(String l, String r, {bool bold = false}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [kit.text(l, size: 10, bold: bold), kit.text(r, size: 10, bold: bold)],
    ),
  );
  pw.Widget block(String title, List<Json> items, String total, double sum) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        kit.text(title, size: 11, bold: true),
        pw.Divider(color: kLine, thickness: 0.6, height: 8),
        for (final i in items) row('${i['name'] ?? i['label'] ?? i['code']}', formatMoney((i['amount'] as num?) ?? 0)),
        pw.Divider(color: kLine, thickness: 0.6, height: 8),
        row(total, formatMoney(sum), bold: true),
      ],
    ),
  );
  final e = p.employee;
  doc.addPage(
    pw.Page(
      pageTheme: kit.pageTheme(format: PdfPageFormat.a4, margin: 36),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          kit.text(company.name, size: 16, bold: true),
          kit.text('Payslip for ${monthLabel(p.month)}', size: 12),
          pw.SizedBox(height: 10),
          row('Employee', '${e['name'] ?? ''} (${e['code'] ?? ''})'),
          row('Designation', '${e['designation'] ?? '-'}'),
          row('Paid days', '${dayText(p.paidDays)} of ${dayText(p.workingDays)}'),
          pw.SizedBox(height: 12),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              block('Earnings', p.earnings, 'Gross pay', p.gross),
              pw.SizedBox(width: 24),
              block('Deductions', p.deductions, 'Total deductions', p.totalDeductions),
            ],
          ),
          pw.SizedBox(height: 12),
          row('Net pay', formatMoney(p.net), bold: true),
          pw.SizedBox(height: 16),
          kit.muted('This is a computer generated payslip.'),
        ],
      ),
    ),
  );
  return doc.save();
}
