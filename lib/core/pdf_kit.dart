/// Shared building blocks for every PDF the app prints: branded header,
/// footer with page x of y, tables and boxes. Pure Dart (no Flutter), so it
/// can be unit-tested and run anywhere.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Company identity used by the PDF header and accents.
class PdfBrand {
  PdfBrand({
    required this.companyName,
    String? colorHex,
    Uint8List? logoBytes,
    this.legalName,
    this.addressLines = const [],
    this.idLine,
    this.contactLine,
  }) : color = _parse(colorHex),
       logo = _image(logoBytes);

  /// Fallback brand when nothing is known about the company.
  factory PdfBrand.plain([String name = '']) => PdfBrand(companyName: name);

  static const defaultHex = '#0B6157';

  final String companyName;
  final String? legalName;
  final List<String> addressLines;

  /// `GSTIN: … PAN: …`
  final String? idLine;

  /// `Phone: … Email: …`
  final String? contactLine;
  final PdfColor color;
  final pw.MemoryImage? logo;

  static PdfColor _parse(String? hex) {
    final value = hex?.trim() ?? '';
    if (RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value)) {
      return PdfColor.fromHex(value);
    }
    return PdfColor.fromHex(defaultHex);
  }

  static pw.MemoryImage? _image(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return pw.MemoryImage(bytes);
    } catch (_) {
      return null; // not an image the pdf package can decode
    }
  }

  /// A very light tint of the brand colour for fills.
  PdfColor get tint => PdfColor(
    1 - (1 - color.red) * 0.08,
    1 - (1 - color.green) * 0.08,
    1 - (1 - color.blue) * 0.08,
  );

  /// Black or white, whichever reads better on [color].
  PdfColor get onColor => color.luminance > 0.5 ? kInk : PdfColors.white;
}

const kInk = PdfColor.fromInt(0xFF1F2937);
const kMuted = PdfColor.fromInt(0xFF6B7280);
const kLine = PdfColor.fromInt(0xFFD5DAE1);
const kStripe = PdfColor.fromInt(0xFFF7F8FA);
const kDanger = PdfColor.fromInt(0xFFB42318);
const kGood = PdfColor.fromInt(0xFF1A7F4B);

/// One table column.
class PdfCol {
  const PdfCol(
    this.title, {
    this.width,
    this.flex = 0,
    this.right = false,
    this.bold = false,
  });

  final String title;

  /// Fixed width in points; when null the column flexes by [flex] (min 1).
  final double? width;
  final double flex;
  final bool right;
  final bool bold;

  pw.TableColumnWidth get columnWidth => width != null
      ? pw.FixedColumnWidth(width!)
      : pw.FlexColumnWidth(flex <= 0 ? 1 : flex);
}

class PdfKit {
  PdfKit({PdfBrand? brand, this.theme}) : brand = brand ?? PdfBrand.plain();

  final PdfBrand brand;

  /// A Unicode theme (see `pdfTheme()`); when null the built-in Latin-1
  /// fonts are used and text is transliterated (`₹` becomes `Rs.`).
  final pw.ThemeData? theme;

  String clean(String s) => theme == null ? pdfLatin1(s) : s;

  pw.ThemeData get _theme =>
      theme ??
      pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
      );

  pw.Document document({String? title, String? subject}) => pw.Document(
    title: title == null ? null : clean(title),
    subject: subject == null ? null : clean(subject),
    author: clean(brand.companyName),
    creator: 'Progen ERP',
  );

  pw.PageTheme pageTheme({
    PdfPageFormat format = PdfPageFormat.a4,
    double margin = 32,
    pw.BuildCallback? background,
  }) => pw.PageTheme(
    pageFormat: format,
    // A full-bleed page (margin 0) must not pick up negative insets.
    margin: margin <= 0
        ? pw.EdgeInsets.zero
        : pw.EdgeInsets.fromLTRB(margin, margin - 8, margin, margin - 6),
    theme: _theme,
    buildBackground: background,
  );

  // ---- text ---------------------------------------------------------------

  pw.Widget text(
    String value, {
    double size = 8.5,
    bool bold = false,
    PdfColor color = kInk,
    pw.TextAlign? align,
    double? height,
  }) => pw.Text(
    clean(value),
    textAlign: align,
    style: pw.TextStyle(
      fontSize: size,
      color: color,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      lineSpacing: height,
    ),
  );

  pw.Widget muted(String value, {double size = 8, pw.TextAlign? align}) =>
      text(value, size: size, color: kMuted, align: align);

  bool has(String? v) => v != null && v.trim().isNotEmpty;

  // ---- header and footer ----------------------------------------------------

  /// Full header: brand bar, logo, company block on the left, the document
  /// [title] with optional [meta] lines on the right.
  pw.Widget header({
    required String title,
    String? subtitle,
    PdfColor? badgeColor,
    String? badge,
  }) {
    final b = brand;
    final lines = <String>[
      if (has(b.legalName) && b.legalName != b.companyName) b.legalName!,
      ...b.addressLines.where(has),
      if (has(b.idLine)) b.idLine!,
      if (has(b.contactLine)) b.contactLine!,
    ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(height: 4, color: b.color),
        pw.SizedBox(height: 10),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (b.logo != null) ...[
              pw.Container(
                width: 50,
                height: 50,
                alignment: pw.Alignment.center,
                child: pw.Image(b.logo!, fit: pw.BoxFit.contain),
              ),
              pw.SizedBox(width: 10),
            ],
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  text(b.companyName, size: 15, bold: true),
                  pw.SizedBox(height: 2),
                  for (final line in lines)
                    text(line, size: 8, color: kMuted, height: 1.5),
                ],
              ),
            ),
            pw.SizedBox(width: 12),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                text(title, size: 17, bold: true, color: b.color),
                if (subtitle != null) ...[
                  pw.SizedBox(height: 2),
                  muted(subtitle),
                ],
                if (badge != null) ...[
                  pw.SizedBox(height: 4),
                  text(
                    badge,
                    size: 9,
                    bold: true,
                    color: badgeColor ?? kDanger,
                  ),
                ],
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Divider(color: kLine, thickness: 0.8, height: 1),
      ],
    );
  }

  /// Slim header for pages after the first.
  pw.Widget compactHeader(String title) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Container(height: 3, color: brand.color),
      pw.SizedBox(height: 5),
      pw.Row(
        children: [
          pw.Expanded(child: text(brand.companyName, size: 9, bold: true)),
          text(title, size: 9, color: kMuted),
        ],
      ),
      pw.SizedBox(height: 5),
      pw.Divider(color: kLine, thickness: 0.6, height: 1),
      pw.SizedBox(height: 8),
    ],
  );

  /// Footer with [left] text and `Page x of y` on the right.
  pw.Widget footer(pw.Context context, {String? left}) => pw.Container(
    margin: const pw.EdgeInsets.only(top: 10),
    padding: const pw.EdgeInsets.only(top: 5),
    decoration: const pw.BoxDecoration(
      border: pw.Border(top: pw.BorderSide(color: kLine, width: 0.6)),
    ),
    child: pw.Row(
      children: [
        pw.Expanded(child: muted(left ?? brand.companyName, size: 7)),
        muted('Page ${context.pageNumber} of ${context.pagesCount}', size: 7),
      ],
    ),
  );

  // ---- blocks -------------------------------------------------------------

  /// Small caps-style heading above a block.
  pw.Widget sectionTitle(String title) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 4),
    child: text(title.toUpperCase(), size: 7.5, bold: true, color: brand.color),
  );

  /// Label and value on one row.
  pw.Widget kv(String key, String value, {double keyWidth = 74}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(width: keyWidth, child: muted(key)),
        pw.Expanded(child: text(value, bold: true)),
      ],
    ),
  );

  /// Outlined block with an optional small [title].
  pw.Widget box({String? title, required List<pw.Widget> children}) =>
      pw.Container(
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: kLine, width: 0.8),
          borderRadius: pw.BorderRadius.circular(3),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [if (title != null) sectionTitle(title), ...children],
        ),
      );

  /// A table with a brand-coloured header that repeats on every page, light
  /// zebra rows and an optional bold [totals] row.
  pw.Widget table({
    required List<PdfCol> columns,
    required List<List<String>> rows,
    List<String>? totals,
    double fontSize = 8,
  }) {
    pw.Widget cell(
      String value,
      PdfCol col, {
      bool bold = false,
      PdfColor color = kInk,
    }) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3.5),
      child: text(
        value,
        size: fontSize,
        bold: bold || col.bold,
        color: color,
        align: col.right ? pw.TextAlign.right : pw.TextAlign.left,
      ),
    );

    return pw.Table(
      columnWidths: {for (final (i, c) in columns.indexed) i: c.columnWidth},
      border: const pw.TableBorder(
        bottom: pw.BorderSide(color: kLine, width: 0.6),
        horizontalInside: pw.BorderSide(color: kLine, width: 0.4),
      ),
      children: [
        pw.TableRow(
          repeat: true,
          decoration: pw.BoxDecoration(color: brand.color),
          children: [
            for (final c in columns)
              cell(c.title, c, bold: true, color: brand.onColor),
          ],
        ),
        for (final (r, row) in rows.indexed)
          pw.TableRow(
            decoration: r.isOdd ? const pw.BoxDecoration(color: kStripe) : null,
            children: [
              for (final (i, c) in columns.indexed)
                cell(i < row.length ? row[i] : '', c),
            ],
          ),
        if (totals != null)
          pw.TableRow(
            decoration: pw.BoxDecoration(color: brand.tint),
            children: [
              for (final (i, c) in columns.indexed)
                cell(i < totals.length ? totals[i] : '', c, bold: true),
            ],
          ),
      ],
    );
  }

  /// One row of a totals list: label left, amount right.
  pw.Widget totalRow(
    String label,
    String value, {
    bool strong = false,
    PdfColor? color,
  }) => pw.Padding(
    padding: pw.EdgeInsets.symmetric(vertical: strong ? 3 : 2),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: text(
            label,
            size: strong ? 10 : 8.5,
            bold: strong,
            color: color ?? kInk,
          ),
        ),
        text(
          value,
          size: strong ? 10 : 8.5,
          bold: strong,
          color: color ?? kInk,
          align: pw.TextAlign.right,
        ),
      ],
    ),
  );

  /// Totals block with a brand-tinted grand total.
  pw.Widget totalsBox(List<pw.Widget> rows) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: pw.BoxDecoration(
      color: brand.tint,
      border: pw.Border.all(color: kLine, width: 0.8),
      borderRadius: pw.BorderRadius.circular(3),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: rows,
    ),
  );

  /// "For Company" with a space to sign above "Authorised signatory".
  pw.Widget signature({
    String role = 'Authorised signatory',
    double width = 170,
  }) => pw.Container(
    width: width,
    height: 70,
    padding: const pw.EdgeInsets.all(6),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: kLine, width: 0.8),
      borderRadius: pw.BorderRadius.circular(3),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        text('For ${brand.companyName}', bold: true, align: pw.TextAlign.right),
        muted(role),
      ],
    ),
  );

  /// Amount in words strip.
  pw.Widget wordsStrip(String words) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: pw.BoxDecoration(
      color: brand.tint,
      borderRadius: pw.BorderRadius.circular(3),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        muted('Amount in words  '),
        pw.Expanded(child: text(words, bold: true)),
      ],
    ),
  );

  /// Two blocks side by side that share the page width.
  pw.Widget twoUp(pw.Widget left, pw.Widget right, {int leftFlex = 1}) =>
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(flex: leftFlex, child: left),
          pw.SizedBox(width: 10),
          pw.Expanded(child: right),
        ],
      );
}

/// Maps common Unicode punctuation to Latin-1 and drops what the built-in
/// fonts cannot draw.
String pdfLatin1(String text) {
  const replacements = {
    '₹': 'Rs.',
    '—': '-',
    '–': '-',
    '‘': "'",
    '’': "'",
    '“': '"',
    '”': '"',
    '…': '...',
    '•': '-',
    '·': '-',
    '×': 'x',
    '−': '-',
  };
  final out = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final mapped = replacements[char];
    if (mapped != null) {
      out.write(mapped);
    } else if (rune <= 0xff) {
      out.write(char);
    } else {
      out.write('?');
    }
  }
  return out.toString();
}
