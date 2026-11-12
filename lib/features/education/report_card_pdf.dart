import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/pdf_kit.dart';
import 'exam_data.dart';

String reportCardFileName(String term, [String? student]) =>
    'report-card-${[term, ?student].join('-').replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// One A4 page per student. A draft card carries a "Draft" badge so it is not
/// mistaken for a published one. Without a [theme] the built-in PDF fonts are
/// used and text is transliterated.
Future<Uint8List> buildReportCardsPdf(
  List<ReportCard> cards, {
  pw.ThemeData? theme,
  PdfBrand? brand,
}) async {
  final first = cards.isEmpty ? null : cards.first;
  final b =
      brand ??
      PdfBrand(
        companyName: first?.schoolName ?? '',
        addressLines: [if (first?.schoolAddress != null) first!.schoolAddress!],
        contactLine: first?.schoolPhone == null
            ? null
            : 'Phone: ${first!.schoolPhone}',
      );
  final kit = PdfKit(brand: b, theme: theme);
  final doc = kit.document(
    title: 'Report card ${first?.termName ?? ''}',
    subject: first?.classLabel,
  );
  for (final c in cards) {
    final r = c.result;
    doc.addPage(
      pw.Page(
        pageTheme: kit.pageTheme(format: PdfPageFormat.a4, margin: 32),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            kit.header(
              title: 'Report card',
              subtitle: '${c.termName}  |  ${c.year}',
              badge: c.draft ? 'Draft' : null,
              badgeColor: kDanger,
            ),
            pw.SizedBox(height: 10),
            kit.box(
              children: [
                kit.twoUp(
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      kit.kv('Student', r.name),
                      kit.kv('Admission no', c.admissionNo),
                      if (c.guardianName != null)
                        kit.kv('Guardian', c.guardianName!),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      kit.kv('Class', c.classLabel),
                      kit.kv('Roll no', r.rollNo ?? '-'),
                      if (c.dob != null)
                        kit.kv('Date of birth', formatDate(c.dob)),
                    ],
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            kit.table(
              columns: const [
                PdfCol('Subject', flex: 3),
                PdfCol('Max marks', width: 62, right: true),
                PdfCol('Marks', width: 62, right: true),
                PdfCol('Grade', width: 50, right: true),
              ],
              rows: [
                for (final s in r.subjects)
                  [
                    s.subject,
                    fmtMarks(s.maxMarks),
                    s.absent ? 'Absent' : fmtMarks(s.marks),
                    s.grade ?? '-',
                  ],
              ],
              totals: [
                'Total',
                fmtMarks(r.maxTotal),
                fmtMarks(r.total),
                r.grade ?? '-',
              ],
              fontSize: 9.5,
            ),
            pw.SizedBox(height: 10),
            kit.twoUp(
              kit.box(
                title: 'Result',
                children: [
                  kit.kv(
                    'Percentage',
                    r.percentage == null
                        ? '-'
                        : '${r.percentage!.toStringAsFixed(2)}%',
                  ),
                  kit.kv('Grade', r.grade ?? '-'),
                  kit.kv(
                    'Rank in class',
                    r.rank == null ? '-' : '${r.rank} of ${c.classSize}',
                  ),
                  kit.kv('Result', switch (r.result) {
                    'pass' => 'Pass',
                    'fail' => 'Needs improvement',
                    _ => 'Not complete',
                  }),
                ],
              ),
              kit.box(
                title: 'Attendance',
                children: [
                  kit.kv(
                    'Days present',
                    c.attMarked == 0
                        ? '-'
                        : '${c.attPresent} of ${c.attMarked}',
                  ),
                  kit.kv(
                    'Percentage',
                    c.attMarked == 0
                        ? '-'
                        : '${(c.attPresent * 100 / c.attMarked).toStringAsFixed(1)}%',
                  ),
                ],
              ),
            ),
            if (r.coScholastic.isNotEmpty) ...[
              pw.SizedBox(height: 10),
              kit.table(
                columns: const [
                  PdfCol('Co-scholastic area', flex: 3),
                  PdfCol('Grade', width: 62, right: true),
                ],
                rows: [
                  for (final a in r.coScholastic) [a.area, a.grade ?? '-'],
                ],
                fontSize: 9.5,
              ),
            ],
            if (r.remark != null) ...[
              pw.SizedBox(height: 10),
              kit.box(
                title: 'Class teacher remarks',
                children: [kit.text(r.remark!, size: 9.5)],
              ),
            ],
            pw.SizedBox(height: 8),
            kit.muted(
              'Grades: ${[for (final g in c.grades) '${g.grade} ${fmtMarks(g.minPct)}%+'].join('   ')}',
            ),
            pw.Spacer(),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                kit.signature(role: 'Class teacher', width: 150),
                kit.signature(role: 'Principal', width: 150),
              ],
            ),
          ],
        ),
      ),
    );
  }
  if (cards.isEmpty) {
    doc.addPage(pw.Page(build: (_) => pw.Text('No report cards')));
  }
  return doc.save();
}
