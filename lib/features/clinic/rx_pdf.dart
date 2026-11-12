import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'clinic_models.dart';

String rxFileName(PrescriptionData d) =>
    'prescription-${d.patient.uhid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}-${d.date}.pdf';

String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// One line such as "BP 130/85  Pulse 78  Temp 37.3 C".
String vitalsLine(Vitals v) => [
  if (v.bpSys != null && v.bpDia != null)
    'BP ${_num(v.bpSys!)}/${_num(v.bpDia!)}',
  if (v.pulse != null) 'Pulse ${_num(v.pulse!)}',
  if (v.tempC != null) 'Temp ${_num(v.tempC!)} C',
  if (v.spo2 != null) 'SpO2 ${_num(v.spo2!)}%',
  if (v.weightKg != null) 'Wt ${_num(v.weightKg!)} kg',
  if (v.heightCm != null) 'Ht ${_num(v.heightCm!)} cm',
].join('   ');

/// The A5 prescription: clinic header, doctor and registration number,
/// patient details, Rx lines, advice and follow-up. Without a [theme] the
/// built-in PDF fonts are used and text is transliterated to Latin-1.
Future<Uint8List> buildPrescriptionPdf(
  PrescriptionData d, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(), theme: theme);
  final doc = kit.document(
    title: 'Prescription ${d.patient.uhid}',
    subject: d.patient.name,
  );
  final colour = kit.brand.color;
  final clinicLines = [
    if (kit.has(d.clinicAddress)) d.clinicAddress!,
    if (kit.has(d.clinicPhone)) 'Phone: ${d.clinicPhone}',
  ];
  final vitals = vitalsLine(d.vitals);
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(format: PdfPageFormat.a5, margin: 26),
      footer: (c) =>
          kit.footer(c, left: '${d.patient.uhid}  |  ${d.clinicName}'),
      build: (c) => [
        pw.Container(height: 3, color: colour),
        pw.SizedBox(height: 6),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (kit.brand.logo != null) ...[
              pw.Container(
                width: 36,
                height: 36,
                child: pw.Image(kit.brand.logo!, fit: pw.BoxFit.contain),
              ),
              pw.SizedBox(width: 8),
            ],
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.text(d.clinicName, size: 13, bold: true),
                  for (final l in clinicLines) kit.muted(l, size: 7.5),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                kit.text(d.doctorName, size: 10, bold: true, color: colour),
                if (kit.has(d.speciality)) kit.muted(d.speciality!, size: 7.5),
                if (kit.has(d.registrationNo))
                  kit.muted('Reg. no. ${d.registrationNo}', size: 7.5),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Divider(color: kLine, thickness: 0.8, height: 1),
        pw.SizedBox(height: 5),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.text(d.patient.name, size: 10, bold: true),
                  kit.muted(
                    [
                      d.patient.uhid,
                      if (d.patient.ageYears != null) '${d.patient.ageYears} y',
                      sexLabel(d.patient.sex),
                      if (kit.has(d.bloodGroup)) d.bloodGroup!,
                    ].join('  |  '),
                    size: 8,
                  ),
                  if (kit.has(d.patient.phone))
                    kit.muted(d.patient.phone, size: 8),
                ],
              ),
            ),
            kit.text('Date: ${formatDate(d.date)}', size: 8.5),
          ],
        ),
        if (kit.has(d.allergies)) ...[
          pw.SizedBox(height: 3),
          kit.text(
            'Allergies: ${d.allergies}',
            size: 8,
            bold: true,
            color: kDanger,
          ),
        ],
        if (vitals.isNotEmpty) ...[pw.SizedBox(height: 4), kit.muted(vitals)],
        if (kit.has(d.complaints)) ...[
          pw.SizedBox(height: 6),
          kit.text('Complaints: ${d.complaints}', size: 8.5),
        ],
        if (kit.has(d.diagnosis)) ...[
          pw.SizedBox(height: 3),
          kit.text('Diagnosis: ${d.diagnosis}', size: 8.5, bold: true),
        ],
        pw.SizedBox(height: 8),
        kit.text('Rx', size: 14, bold: true, color: colour),
        pw.SizedBox(height: 3),
        if (d.rx.isEmpty)
          kit.muted('No medicines prescribed.')
        else
          kit.table(
            columns: const [
              PdfCol('#', width: 16),
              PdfCol('Medicine', flex: 3, bold: true),
              PdfCol('Dose', flex: 1.2),
              PdfCol('When', flex: 1.6),
              PdfCol('Days', width: 28, right: true),
            ],
            rows: [
              for (final (i, r) in d.rx.indexed)
                [
                  '${i + 1}',
                  r.medicine,
                  r.dose ?? '',
                  [
                    if (kit.has(r.frequency)) r.frequency!,
                    if (kit.has(r.instructions)) r.instructions!,
                  ].join(', '),
                  r.days == null ? '' : '${r.days}',
                ],
            ],
          ),
        if (kit.has(d.testsAdvised)) ...[
          pw.SizedBox(height: 8),
          kit.text('Tests advised: ${d.testsAdvised}', size: 8.5),
        ],
        if (kit.has(d.advice)) ...[
          pw.SizedBox(height: 6),
          kit.text('Advice: ${d.advice}', size: 8.5, height: 1.4),
        ],
        if (kit.has(d.followupDate)) ...[
          pw.SizedBox(height: 8),
          kit.text(
            'Follow-up on ${formatDate(d.followupDate)}',
            size: 9,
            bold: true,
          ),
        ],
        pw.SizedBox(height: 26),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Container(width: 110, height: 0.6, color: kInk),
              pw.SizedBox(height: 2),
              kit.muted(d.doctorName, size: 7.5),
            ],
          ),
        ),
      ],
    ),
  );
  return doc.save();
}
