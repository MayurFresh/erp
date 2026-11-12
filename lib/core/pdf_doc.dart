/// A generic business document (credit note, receipt, order, statement) laid
/// out with the shared PDF kit. Pure Dart (no Flutter).
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_kit.dart';

/// One label and amount in the totals block.
class PdfTotal {
  const PdfTotal(this.label, this.value, {this.strong = false, this.color});

  final String label;
  final String value;
  final bool strong;
  final PdfColor? color;
}

class DocPdfSpec {
  const DocPdfSpec({
    required this.title,
    required this.number,
    required this.parties,
    required this.details,
    this.partyTitle = 'Bill to',
    this.subtitle,
    this.cancelled = false,
    this.columns = const [],
    this.rows = const [],
    this.totalsRow,
    this.totals = const [],
    this.words,
    this.notes,
    this.noteTitle = 'Notes',
    this.intro,
    this.blocks = const [],
    this.signature = true,
    this.footerNote,
    this.fontSize = 8,
  });

  final String title;
  final String? subtitle;

  /// Shown in the footer and on later pages.
  final String number;
  final bool cancelled;

  /// First line is the bold name.
  final List<String> parties;
  final String partyTitle;
  final List<(String, String)> details;
  final String? intro;
  final List<PdfCol> columns;
  final List<List<String>> rows;
  final List<String>? totalsRow;
  final List<PdfTotal> totals;
  final String? words;
  final String? notes;
  final String noteTitle;

  /// Extra blocks placed after the totals.
  final List<pw.Widget> blocks;
  final bool signature;
  final String? footerNote;
  final double fontSize;
}

Future<Uint8List> buildDocPdf(PdfKit kit, DocPdfSpec s) {
  final doc = kit.document(title: '${s.title} ${s.number}');
  final fine = s.parties.where((l) => l.trim().isNotEmpty).toList();
  doc.addPage(
    pw.MultiPage(
      pageTheme: kit.pageTheme(
        background: s.cancelled
            ? (context) => pw.Watermark.text(
                'CANCELLED',
                style: pw.TextStyle(
                  color: PdfColor.fromHex('#F6C6C6'),
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 80,
                ),
              )
            : null,
      ),
      header: (context) => context.pageNumber == 1
          ? pw.SizedBox()
          : kit.compactHeader('${s.title} ${s.number}'),
      footer: (context) => kit.footer(
        context,
        left:
            '${s.number}  |  ${kit.brand.companyName}'
            '${s.footerNote == null ? '' : '  |  ${s.footerNote}'}',
      ),
      build: (context) => [
        kit.header(
          title: s.title.toUpperCase(),
          subtitle: s.subtitle,
          badge: s.cancelled ? 'CANCELLED' : null,
        ),
        pw.SizedBox(height: 12),
        kit.twoUp(
          kit.box(
            title: s.partyTitle,
            children: [
              if (fine.isNotEmpty) kit.text(fine.first, size: 10, bold: true),
              for (final line in fine.skip(1)) kit.text(line, height: 1.5),
            ],
          ),
          kit.box(
            title: 'Details',
            children: [for (final (k, v) in s.details) kit.kv(k, v)],
          ),
        ),
        if (s.intro != null) ...[
          pw.SizedBox(height: 12),
          kit.text(s.intro!, size: 9.5, height: 1.5),
        ],
        if (s.columns.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          kit.table(
            columns: s.columns,
            rows: s.rows,
            totals: s.totalsRow,
            fontSize: s.fontSize,
          ),
          if (s.rows.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 8),
              child: kit.muted('Nothing to show.', size: 9),
            ),
        ],
        if (s.totals.isNotEmpty || s.words != null) ...[
          pw.SizedBox(height: 12),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                flex: 3,
                child: s.words == null
                    ? pw.SizedBox()
                    : kit.wordsStrip(s.words!),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                flex: 2,
                child: s.totals.isEmpty
                    ? pw.SizedBox()
                    : kit.totalsBox([
                        for (final t in s.totals)
                          kit.totalRow(
                            t.label,
                            t.value,
                            strong: t.strong,
                            color: t.color,
                          ),
                      ]),
              ),
            ],
          ),
        ],
        ...s.blocks.expand((b) => [pw.SizedBox(height: 12), b]),
        if (kit.has(s.notes)) ...[
          pw.SizedBox(height: 12),
          kit.sectionTitle(s.noteTitle),
          kit.text(s.notes!, size: 8.5, height: 1.5),
        ],
        if (s.signature) ...[
          pw.SizedBox(height: 18),
          pw.Align(alignment: pw.Alignment.centerRight, child: kit.signature()),
        ],
      ],
    ),
  );
  return doc.save();
}
