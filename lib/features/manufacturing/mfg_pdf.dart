import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_fonts.dart';
import '../../core/pdf_kit.dart';
import '../../core/providers.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../company/company_model.dart';
import '../company/company_repository.dart';
import 'mfg_models.dart';

String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');

String jobSheetFileName(MfgOrder o) => _safe('job-sheet-${o.number}.pdf');

String challanFileName(Challan c) => _safe('challan-${c.number}.pdf');

/// Shop-floor job sheet: what to make, material to draw, routing, with blank
/// columns to fill by hand. No costs.
Future<Uint8List> buildJobSheetPdf(MfgOrder o, Company company, {pw.ThemeData? theme, PdfBrand? brand}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(company.name), theme: theme);
  final doc = kit.document(title: 'Job sheet ${o.number}');
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(),
      header: (_) => kit.header(title: 'Job sheet', subtitle: o.number),
      footer: (c) => kit.footer(c),
      build: (_) => [
        pw.SizedBox(height: 8),
        kit.box(
          children: [
            kit.kv('Make', '${o.itemName}  (BOM version ${o.bomVersion})'),
            kit.kv('Quantity', qtyText(o.qty, o.unit)),
            kit.kv('Store at', o.locationName),
            if (o.plannedStart != null) kit.kv('Start', formatDate(o.plannedStart)),
            if (o.plannedEnd != null) kit.kv('Due', formatDate(o.plannedEnd)),
            if (o.salesOrderNumber != null) kit.kv('Sales order', o.salesOrderNumber!),
            if ((o.notes ?? '').isNotEmpty) kit.kv('Notes', o.notes!),
          ],
        ),
        kit.sectionTitle('Material'),
        kit.table(
          columns: const [
            PdfCol('Item', flex: 4),
            PdfCol('To use', width: 70, right: true),
            PdfCol('Issued', width: 60, right: true),
            PdfCol('Returned', width: 60, right: true),
          ],
          rows: [
            for (final m in o.materials)
              [m.name, qtyText(m.plannedQty, m.unit), qtyText(m.issuedQty, m.unit), qtyText(m.returnedQty, m.unit)],
          ],
        ),
        if (o.steps.isNotEmpty) ...[
          kit.sectionTitle('Operations'),
          kit.table(
            columns: const [
              PdfCol('Operation', flex: 3),
              PdfCol('Work centre', flex: 2),
              PdfCol('Minutes', width: 55, right: true),
              PdfCol('Done by', width: 80),
              PdfCol('Time taken', width: 60),
            ],
            rows: [
              for (final s in o.steps) [s.operation, s.workCentre, formatQty(s.plannedMinutes), '', ''],
            ],
          ),
        ],
        kit.sectionTitle('Output'),
        kit.table(
          columns: const [
            PdfCol('Date', width: 80),
            PdfCol('Good', width: 80, right: true),
            PdfCol('Rejected', width: 80, right: true),
            PdfCol('Checked by', flex: 2),
          ],
          rows: [
            for (var i = 0; i < 4; i++) ['', '', '', ''],
          ],
        ),
        pw.SizedBox(height: 16),
        pw.Row(children: [kit.signature(role: 'Supervisor'), pw.SizedBox(width: 16), kit.signature(role: 'Quality check')]),
      ],
    ),
  );
  return doc.save();
}

String qtyText(num qty, String unit) => '${formatQty(qty)} $unit'.trim();

/// Delivery challan for goods sent to a job worker.
Future<Uint8List> buildChallanPdf(Challan c, Company company, {pw.ThemeData? theme, PdfBrand? brand}) {
  final kit = PdfKit(brand: brand ?? PdfBrand.plain(company.name), theme: theme);
  final doc = kit.document(title: 'Challan ${c.number}');
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(),
      header: (_) => kit.header(title: 'Job work challan', subtitle: c.number),
      footer: (x) => kit.footer(x),
      build: (_) => [
        pw.SizedBox(height: 8),
        kit.twoUp(
          kit.box(title: 'Job worker', children: [
            kit.text(c.partyName, bold: true),
            if ((c.partyGstin ?? '').isNotEmpty) kit.text('GSTIN ${c.partyGstin}'),
          ]),
          kit.box(title: 'Challan', children: [
            kit.kv('Date', formatDate(c.challanDate)),
            kit.kv('Process', c.process),
            if (c.expectedReturn != null) kit.kv('Return by', formatDate(c.expectedReturn)),
            if ((c.vehicleNo ?? '').isNotEmpty) kit.kv('Vehicle', c.vehicleNo!),
            kit.kv('From', c.locationName),
          ]),
        ),
        kit.sectionTitle('Goods sent'),
        kit.table(
          columns: const [
            PdfCol('Item', flex: 3),
            PdfCol('HSN', width: 60),
            PdfCol('Quantity', width: 70, right: true),
            PdfCol('Comes back as', flex: 2),
          ],
          rows: [
            for (final l in c.lines) [l.name, l.hsnCode ?? '', qtyText(l.qtySent, l.unit), l.returnName],
          ],
        ),
        pw.SizedBox(height: 8),
        kit.muted('Goods sent for job work under the GST rules. Not for sale. Check the challan details before use.'),
        pw.SizedBox(height: 16),
        kit.signature(),
      ],
    ),
  );
  return doc.save();
}

Future<Company> _company(WidgetRef ref) async {
  Company? company;
  try {
    company = await ref.read(companyRepositoryProvider).get();
  } catch (_) {
    company = ref.read(sessionProvider).value?.company;
  }
  return company ?? const Company(id: '', name: 'Company', stateCode: '');
}

Future<void> printJobSheet(BuildContext context, WidgetRef ref, MfgOrder o) async {
  try {
    final co = await _company(ref);
    final bytes = await buildJobSheetPdf(
      o,
      co,
      brand: await loadPdfBrand(ref.read(apiClientProvider), co),
      theme: await pdfTheme(),
    );
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: jobSheetFileName(o));
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

Future<void> printChallan(BuildContext context, WidgetRef ref, Challan c) async {
  try {
    final co = await _company(ref);
    final bytes = await buildChallanPdf(
      c,
      co,
      brand: await loadPdfBrand(ref.read(apiClientProvider), co),
      theme: await pdfTheme(),
    );
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: challanFileName(c));
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}
