import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'job_models.dart';

String jobPdfName(JobDetail d, String what) =>
    '$what-${d.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}.pdf';

/// Printed on every intake slip. Keep it short and plain.
const List<String> kIntakeTerms = [
  'The estimate is approximate. We will ask you before any work beyond it.',
  'Parts removed from the vehicle or device can be collected on request.',
  'Items left inside the vehicle or device are at the owner\'s risk.',
  'Collect within 7 days of the ready message. Storage may be charged after that.',
  'Please bring this slip when collecting.',
];

pw.Widget _asset(PdfKit kit, JobDetail d) => kit.box(
  title: d.isVehicle ? 'Vehicle' : 'Device',
  children: [
    if (d.isVehicle && kit.has(d.vehicleNo)) kit.kv('Number', d.vehicleNo!),
    if (kit.has(d.make) || kit.has(d.model))
      kit.kv('Make and model', [d.make, d.model].whereType<String>().join(' ')),
    if (d.odometer != null) kit.kv('Odometer', '${d.odometer} km'),
    if (!d.isVehicle && kit.has(d.serialNo))
      kit.kv('Serial / IMEI', d.serialNo!),
  ],
);

pw.Widget _customer(PdfKit kit, JobDetail d) => kit.box(
  title: 'Customer',
  children: [
    kit.kv('Name', d.customerName),
    if (kit.has(d.customerPhone)) kit.kv('Phone', d.customerPhone!),
    if (kit.has(d.promisedDate)) kit.kv('Promised', formatDate(d.promisedDate)),
    if (kit.has(d.technicianName)) kit.kv('Technician', d.technicianName!),
  ],
);

/// The A5 intake slip handed to the customer when a vehicle or device is received.
Future<Uint8List> buildJobIntakePdf(
  JobDetail d, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(), theme: theme);
  final doc = kit.document(
    title: 'Job card ${d.number}',
    subject: d.customerName,
  );
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(format: PdfPageFormat.a5, margin: 26),
      footer: (c) => kit.footer(c, left: d.number),
      build: (c) => [
        kit.header(title: 'Job card', subtitle: d.number),
        pw.SizedBox(height: 8),
        kit.twoUp(_customer(kit, d), _asset(kit, d)),
        pw.SizedBox(height: 8),
        kit.box(
          title: 'Complaint',
          children: [kit.text(d.complaints, size: 9, height: 1.4)],
        ),
        if (kit.has(d.accessories)) ...[
          pw.SizedBox(height: 6),
          kit.box(
            title: 'Received with it',
            children: [kit.text(d.accessories!, size: 9)],
          ),
        ],
        pw.SizedBox(height: 8),
        kit.sectionTitle('Terms'),
        for (final (i, t) in kIntakeTerms.indexed)
          kit.muted('${i + 1}. $t', size: 7.5),
        pw.SizedBox(height: 14),
        pw.Row(
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Container(height: 0.6, color: kInk),
                  kit.muted('Customer signature', size: 7.5),
                ],
              ),
            ),
            pw.SizedBox(width: 30),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Container(height: 0.6, color: kInk),
                  kit.muted('Received by', size: 7.5),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return doc.save();
}

/// The A4 estimate: parts and labour with tax and the total.
Future<Uint8List> buildJobEstimatePdf(
  JobDetail d, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(), theme: theme);
  final doc = kit.document(
    title: 'Estimate ${d.number}',
    subject: d.customerName,
  );
  const cols = [
    PdfCol('#', width: 20),
    PdfCol('Item', flex: 4, bold: true),
    PdfCol('Qty', width: 44, right: true),
    PdfCol('Rate', width: 62, right: true),
    PdfCol('Disc %', width: 40, right: true),
    PdfCol('Amount', width: 70, right: true),
  ];
  List<List<String>> rowsOf(Iterable<JobLine> lines) => [
    for (final (i, l) in lines.indexed)
      [
        '${i + 1}',
        l.description == null || l.description!.isEmpty
            ? l.itemName
            : '${l.itemName} - ${l.description}',
        formatQty(l.qty),
        formatAmount(l.rate),
        l.discountPct > 0 ? formatPlain(l.discountPct) : '',
        formatAmount(l.amount),
      ],
  ];
  final parts = d.lines.where((l) => l.isPart);
  final labour = d.lines.where((l) => !l.isPart);
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(),
      footer: (c) => kit.footer(c, left: 'Estimate ${d.number}'),
      build: (c) => [
        kit.header(
          title: 'Estimate',
          subtitle: d.number,
          badge: d.approvedAt != null ? 'Approved' : null,
        ),
        pw.SizedBox(height: 10),
        kit.twoUp(_customer(kit, d), _asset(kit, d)),
        pw.SizedBox(height: 10),
        kit.box(
          title: 'Complaint',
          children: [kit.text(d.complaints, size: 9, height: 1.4)],
        ),
        pw.SizedBox(height: 10),
        if (parts.isNotEmpty) ...[
          kit.sectionTitle('Parts'),
          kit.table(columns: cols, rows: rowsOf(parts)),
          pw.SizedBox(height: 8),
        ],
        if (labour.isNotEmpty) ...[
          kit.sectionTitle('Labour'),
          kit.table(columns: cols, rows: rowsOf(labour)),
          pw.SizedBox(height: 8),
        ],
        if (d.lines.isEmpty) kit.muted('No lines on the estimate yet.'),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.SizedBox(
            width: 220,
            child: kit.totalsBox([
              kit.totalRow('Parts', formatAmount(d.totals.parts)),
              kit.totalRow('Labour', formatAmount(d.totals.labour)),
              kit.totalRow('Tax', formatAmount(d.totals.tax)),
              if (d.totals.roundOff != 0)
                kit.totalRow('Round off', formatAmount(d.totals.roundOff)),
              kit.totalRow(
                'Estimate total',
                formatAmount(d.totals.total),
                strong: true,
              ),
            ]),
          ),
        ),
        pw.SizedBox(height: 10),
        kit.muted(
          'This is an estimate. Final charges follow the work done, and we will ask you before going beyond it.',
          size: 7.5,
        ),
        if (kit.has(d.approvedBy) || d.approvedAt != null) ...[
          pw.SizedBox(height: 4),
          kit.text(
            'Approved${kit.has(d.approvedBy) ? ' by ${d.approvedBy}' : ''}.',
            size: 8.5,
            bold: true,
          ),
        ],
      ],
    ),
  );
  return doc.save();
}
