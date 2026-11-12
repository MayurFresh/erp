import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'ipd_models.dart';

String dischargeFileName(DischargeSummaryData d) =>
    'discharge-${d.admissionNo.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}.pdf';

/// The A4 discharge summary: hospital header, patient and stay details,
/// diagnosis, treatment given, medicines, condition and advice at discharge.
/// Without a [theme] the built-in PDF fonts are used and text is
/// transliterated to Latin-1.
Future<Uint8List> buildDischargeSummaryPdf(
  DischargeSummaryData d, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(), theme: theme);
  final doc = kit.document(
    title: 'Discharge summary ${d.admissionNo}',
    subject: d.patientName,
  );
  final colour = kit.brand.color;
  pw.Widget section(String title, String? body) => kit.has(body)
      ? pw.Padding(
          padding: const pw.EdgeInsets.only(top: 10),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              kit.text(title, size: 10, bold: true, color: colour),
              pw.SizedBox(height: 2),
              kit.text(body!, size: 9.5, height: 1.4),
            ],
          ),
        )
      : pw.SizedBox();
  final n = d.notes;
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(format: PdfPageFormat.a4, margin: 36),
      footer: (c) =>
          kit.footer(c, left: '${d.admissionNo}  |  ${d.hospitalName}'),
      build: (c) => [
        pw.Container(height: 3, color: colour),
        pw.SizedBox(height: 6),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.text(d.hospitalName, size: 14, bold: true),
                  if (kit.has(d.hospitalAddress))
                    kit.muted(d.hospitalAddress!, size: 8),
                  if (kit.has(d.hospitalPhone))
                    kit.muted('Phone: ${d.hospitalPhone}', size: 8),
                ],
              ),
            ),
            kit.text('DISCHARGE SUMMARY', size: 12, bold: true, color: colour),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Divider(color: kLine, thickness: 0.8, height: 1),
        pw.SizedBox(height: 6),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.text(d.patientName, size: 11, bold: true),
                  kit.muted(
                    [
                      d.uhid,
                      if (kit.has(d.patientLine)) d.patientLine!,
                    ].join('  |  '),
                    size: 8.5,
                  ),
                  if (kit.has(d.allergies))
                    kit.text(
                      'Allergies: ${d.allergies}',
                      size: 8.5,
                      bold: true,
                      color: kDanger,
                    ),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                kit.text('Admission ${d.admissionNo}', size: 9, bold: true),
                kit.muted(
                  'Admitted ${formatDate(d.admitDate)}'
                  '${d.dischargeDate == null ? '' : '  |  Discharged ${formatDate(d.dischargeDate)}'}',
                  size: 8.5,
                ),
                kit.muted(
                  '${d.days} day${d.days == 1 ? '' : 's'}'
                  '${kit.has(d.ward) ? '  |  ${d.ward}${kit.has(d.bed) ? ', bed ${d.bed}' : ''}' : ''}',
                  size: 8.5,
                ),
                kit.muted(
                  'Treating doctor: ${d.doctorName}'
                  '${kit.has(d.registrationNo) ? ' (Reg. ${d.registrationNo})' : ''}',
                  size: 8.5,
                ),
              ],
            ),
          ],
        ),
        section('Provisional diagnosis', d.provisionalDiagnosis),
        section('Final diagnosis', n.diagnosis),
        section('Treatment given', n.treatment),
        if (d.medicines.isNotEmpty)
          section('Medicines given in hospital', d.medicines.join('\n')),
        section('Condition at discharge', n.condition),
        section('Advice', n.advice),
        if (kit.has(n.followupDate))
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 10),
            child: kit.text(
              'Follow-up on ${formatDate(n.followupDate)}',
              size: 10,
              bold: true,
            ),
          ),
        pw.SizedBox(height: 40),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Container(width: 130, height: 0.6, color: kInk),
              pw.SizedBox(height: 2),
              kit.muted(d.doctorName, size: 8),
            ],
          ),
        ),
      ],
    ),
  );
  return doc.save();
}
