import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_brand.dart';
import '../../core/pdf_kit.dart';
import '../company/company_model.dart';
import 'legal_models.dart';

String matterPdfName(Matter m) =>
    'matter-status-${m.matterNo.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}.pdf';

/// One-page status note for the client: case details, last hearings, the next
/// date and fees. Internal notes, time entries and the team are left out.
Future<Uint8List> buildMatterStatusPdf(
  Matter m,
  Company company, {
  Bills? bills,
  pw.ThemeData? theme,
  PdfBrand? brand,
}) async {
  final kit = PdfKit(brand: brand ?? pdfBrandFor(company), theme: theme);
  final doc = kit.document(
    title: 'Matter status ${m.matterNo}',
    subject: m.clientName,
  );
  final held = [
    for (final h in m.hearings)
      if (h.held) h,
  ].take(5).toList();
  final upcoming = [
    for (final h in m.hearings)
      if (!h.held) h,
  ]..sort((a, b) => a.date.compareTo(b.date));
  final next = upcoming.isEmpty ? null : upcoming.first;
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(),
      footer: (context) =>
          kit.footer(context, left: '${m.matterNo}  |  ${company.name}'),
      build: (context) => [
        kit.header(title: 'MATTER STATUS'),
        pw.SizedBox(height: 12),
        kit.twoUp(
          kit.box(
            title: 'Client',
            children: [
              kit.text(m.clientName, size: 10, bold: true),
              kit.text('Status: ${matterStatuses[m.status] ?? m.status}'),
              kit.text('Date: ${formatDate(DateTime.now())}'),
            ],
          ),
          kit.box(
            title: 'Matter',
            children: [
              kit.kv('Matter no.', m.matterNo),
              kit.kv('Case', m.caseRef),
              kit.kv('Type', m.caseType ?? ''),
              kit.kv('Court', m.court ?? ''),
              kit.kv('Against', m.opposingParty ?? ''),
              kit.kv('Stage', m.stage ?? ''),
            ],
          ),
        ),
        pw.SizedBox(height: 12),
        kit.sectionTitle('Next hearing'),
        kit.text(
          next == null
              ? 'No date is fixed yet. We will inform you as soon as it is.'
              : '${formatDate(next.date)}${next.purpose == null ? '' : ', ${next.purpose}'}'
                    '${next.court == null ? '' : ' (${next.court})'}',
          size: 10,
          bold: next != null,
        ),
        pw.SizedBox(height: 12),
        kit.sectionTitle('Recent hearings'),
        if (held.isEmpty)
          kit.text('No hearings recorded yet.')
        else
          kit.table(
            columns: const [
              PdfCol('Date', width: 70),
              PdfCol('Purpose', width: 110),
              PdfCol('What happened', flex: 1),
            ],
            rows: [
              for (final h in held)
                [formatDate(h.date), h.purpose ?? '', h.outcome ?? ''],
            ],
          ),
        pw.SizedBox(height: 12),
        kit.sectionTitle('Fees'),
        kit.box(
          children: [
            kit.kv(
              'Arrangement',
              feeTypes[m.feeType] ?? m.feeType,
              keyWidth: 110,
            ),
            if (m.agreedFee > 0)
              kit.kv('Agreed fee', formatMoney(m.agreedFee), keyWidth: 110),
            kit.kv('Billed so far', formatMoney(m.billedTotal), keyWidth: 110),
            kit.kv(
              'Received on bills',
              formatMoney(m.billedPaid),
              keyWidth: 110,
            ),
            if (m.advanceReceived > 0)
              kit.kv(
                'Advance received',
                formatMoney(m.advanceReceived),
                keyWidth: 110,
              ),
            kit.kv(
              'Balance on bills',
              formatMoney(m.billedTotal - m.billedPaid),
              keyWidth: 110,
            ),
          ],
        ),
        pw.SizedBox(height: 18),
        kit.muted(
          'This note shows the position as on the date above. It is not a '
          'legal opinion.',
          size: 8,
        ),
      ],
    ),
  );
  return doc.save();
}
