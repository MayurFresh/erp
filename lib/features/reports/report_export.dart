/// Tabular exports (CSV for spreadsheets, a simple PDF table) shared by every
/// report, the ledger and the day book. Pure Dart.
library;

/// How a column's values are written.
enum CellKind {
  text,

  /// Rupees: `1234.5` → `1234.50` in CSV, `1,234.50` in PDF.
  money,

  /// Quantities: up to 3 decimals, no trailing zeros.
  qty,

  /// GST rates and percentages: `18` → `18`, `0.25` → `0.25`.
  rate,

  /// Whole numbers (counts).
  count;

  bool get numeric => this != CellKind.text;
}

class ExportColumn {
  const ExportColumn(this.label, [this.kind = CellKind.text]);

  final String label;
  final CellKind kind;
}

/// A titled table with an optional totals row.
class ReportExport {
  const ReportExport({
    required this.title,
    required this.columns,
    required this.rows,
    this.subtitle,
    this.totals,
    this.fileStem,
  });

  final String title;

  /// Period or "as of" line, e.g. `01 Apr 2026 – 21 Oct 2026`.
  final String? subtitle;
  final List<ExportColumn> columns;

  /// Raw values (String, num or null), one list per row, aligned with
  /// [columns].
  final List<List<Object?>> rows;

  /// Appended after [rows] when present.
  final List<Object?>? totals;

  /// File name without extension; derived from [title] when absent.
  final String? fileStem;

  String get fileName => safeFileName(fileStem ?? title);

  /// The header, every row and the totals row as RFC 4180 CSV.
  String toCsv() => buildCsv([
    [for (final c in columns) c.label],
    for (final row in rows) _formatRow(row),
    if (totals != null) _formatRow(totals!),
  ]);

  List<String> _formatRow(List<Object?> row) => [
    for (var i = 0; i < columns.length; i++)
      csvValue(i < row.length ? row[i] : null, columns[i].kind),
  ];
}

/// `Trial balance — 21 Oct 2026` → `Trial-balance-21-Oct-2026`.
String safeFileName(String text) {
  final cleaned = text
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return cleaned.isEmpty ? 'report' : cleaned;
}

/// Formats [value] for a CSV cell of [kind] (before quoting).
String csvValue(Object? value, CellKind kind) {
  if (value == null) return '';
  if (value is num) {
    return switch (kind) {
      CellKind.money => _fixed(value, 2),
      CellKind.count => value.round().toString(),
      CellKind.qty || CellKind.rate => _trimmed(value, 3),
      CellKind.text => _trimmed(value, 3),
    };
  }
  final text = value.toString();
  // Spreadsheets run cells that start with these as formulas.
  if (kind == CellKind.text && RegExp(r'^[=+\-@\t\r]').hasMatch(text)) {
    return "'$text";
  }
  return text;
}

String _fixed(num value, int decimals) {
  final text = value.toStringAsFixed(decimals);
  // Avoid "-0.00".
  return double.parse(text) == 0 ? (0).toStringAsFixed(decimals) : text;
}

String _trimmed(num value, int maxDecimals) {
  if (value == value.roundToDouble()) return value.round().toString();
  var text = value.toStringAsFixed(maxDecimals);
  text = text.replaceAll(RegExp(r'0+$'), '');
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
}

/// Quotes a cell when it contains a comma, quote, line break or edge spaces.
String csvEscape(String cell) {
  final needsQuotes =
      cell.contains(RegExp(r'[",\r\n]')) ||
      cell.startsWith(' ') ||
      cell.endsWith(' ');
  return needsQuotes ? '"${cell.replaceAll('"', '""')}"' : cell;
}

/// Rows of already-formatted cells → CSV text with CRLF line endings.
String buildCsv(List<List<String>> rows) =>
    rows.map((row) => row.map(csvEscape).join(',')).join('\r\n');
