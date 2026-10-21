/// Parses BOQ rows pasted from a spreadsheet (Excel / Google Sheets copy is
/// tab separated; CSV files are comma separated with optional quotes).
///
/// Without a header row the columns are, in order:
/// `code, description, unit, qty, rate[, material, labour, other]`.
/// A header row (e.g. `Item No | Description | Unit | Qty | Rate | Amount`)
/// is detected and its columns are mapped by name, in any order; an
/// `Amount` column is ignored (the server computes qty × rate).
///
/// Heading rows with no quantity and no rate (e.g. `2 | EARTHWORK`) are
/// skipped, as are blank rows.
library;

import 'project_models.dart';

/// Most lines accepted in one bulk request.
const int kBoqBulkMax = 500;

enum BoqColumn {
  code,
  description,
  unit,
  qty,
  rate,
  amount,
  materialBudget,
  labourBudget,
  otherBudget,
}

const List<BoqColumn> _defaultOrder = [
  BoqColumn.code,
  BoqColumn.description,
  BoqColumn.unit,
  BoqColumn.qty,
  BoqColumn.rate,
  BoqColumn.materialBudget,
  BoqColumn.labourBudget,
  BoqColumn.otherBudget,
];

class BoqPasteError {
  const BoqPasteError(this.row, this.message);

  /// 1-based row in the pasted text.
  final int row;
  final String message;

  @override
  String toString() => 'Row $row: $message';
}

class BoqPasteResult {
  const BoqPasteResult({
    this.lines = const [],
    this.errors = const [],
    this.skippedHeadings = 0,
    this.hasHeader = false,
    this.columns = _defaultOrder,
  });

  final List<BoqLineInput> lines;
  final List<BoqPasteError> errors;

  /// Section headings (no qty and no rate) that were left out.
  final int skippedHeadings;
  final bool hasHeader;

  /// Column meaning by position (`null` = ignored).
  final List<BoqColumn?> columns;

  bool get isEmpty => lines.isEmpty && errors.isEmpty;
  bool get canImport => lines.isNotEmpty && errors.isEmpty;

  double get totalAmount => lines.fold(0, (sum, l) => sum + l.amount);
}

BoqPasteResult parseBoqPaste(String text) {
  final rawLines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final rows = <(int, List<String>)>[];
  final tab = rawLines.contains('\t');
  for (final (index, line) in rawLines.split('\n').indexed) {
    if (line.trim().isEmpty) continue;
    final cells = tab ? _splitTabs(line) : splitCsvLine(line);
    if (cells.every((c) => c.isEmpty)) continue;
    rows.add((index + 1, cells));
  }
  if (rows.isEmpty) return const BoqPasteResult();

  var columns = <BoqColumn?>[..._defaultOrder];
  var hasHeader = false;
  final header = _headerColumns(rows.first.$2);
  if (header != null) {
    columns = header;
    hasHeader = true;
    rows.removeAt(0);
  }

  final lines = <BoqLineInput>[];
  final errors = <BoqPasteError>[];
  var skipped = 0;
  for (final (rowNo, cells) in rows) {
    String cell(BoqColumn column) {
      final i = columns.indexOf(column);
      return i < 0 || i >= cells.length ? '' : cells[i].trim();
    }

    final code = cell(BoqColumn.code);
    final description = cell(BoqColumn.description);
    final unit = cell(BoqColumn.unit);
    final qtyText = cell(BoqColumn.qty);
    final rateText = cell(BoqColumn.rate);

    if (qtyText.isEmpty && rateText.isEmpty) {
      skipped++;
      continue;
    }

    final problems = <String>[];
    if (code.isEmpty) problems.add('code is missing');
    if (description.isEmpty) problems.add('description is missing');
    if (unit.isEmpty) problems.add('unit is missing');
    final qty = parseSheetNumber(qtyText);
    if (qty == null) {
      problems.add(
        qtyText.isEmpty ? 'qty is missing' : 'qty "$qtyText" is not a number',
      );
    } else if (qty <= 0) {
      problems.add('qty must be more than 0');
    }
    final rate = parseSheetNumber(rateText);
    if (rate == null) {
      problems.add(
        rateText.isEmpty
            ? 'rate is missing'
            : 'rate "$rateText" is not a number',
      );
    } else if (rate < 0) {
      problems.add('rate cannot be negative');
    }

    double? budget(BoqColumn column, String label) {
      final text = cell(column);
      if (text.isEmpty) return null;
      final value = parseSheetNumber(text);
      if (value == null) problems.add('$label "$text" is not a number');
      return value;
    }

    final material = budget(BoqColumn.materialBudget, 'material budget');
    final labour = budget(BoqColumn.labourBudget, 'labour budget');
    final other = budget(BoqColumn.otherBudget, 'other budget');

    if (problems.isNotEmpty) {
      errors.add(BoqPasteError(rowNo, problems.join(', ')));
      continue;
    }
    lines.add(
      BoqLineInput(
        code: code,
        description: description,
        unit: unit,
        qty: _round(qty!, 3),
        rate: _round(rate!, 2),
        materialBudget: material == null ? null : _round(material, 2),
        labourBudget: labour == null ? null : _round(labour, 2),
        otherBudget: other == null ? null : _round(other, 2),
      ),
    );
  }

  if (lines.length > kBoqBulkMax) {
    errors.add(
      BoqPasteError(
        rows.last.$1,
        'at most $kBoqBulkMax lines can be added at once '
        '(${lines.length} found)',
      ),
    );
  }

  return BoqPasteResult(
    lines: lines,
    errors: errors,
    skippedHeadings: skipped,
    hasHeader: hasHeader,
    columns: columns,
  );
}

double _round(double value, int decimals) {
  final factor = decimals == 3 ? 1000 : 100;
  return (value * factor).round() / factor;
}

List<String> _splitTabs(String line) => [
  for (final cell in line.split('\t')) _unquote(cell.trim()),
];

String _unquote(String cell) {
  if (cell.length >= 2 && cell.startsWith('"') && cell.endsWith('"')) {
    return cell.substring(1, cell.length - 1).replaceAll('""', '"');
  }
  return cell;
}

/// One CSV line: commas separate cells; `"…"` may contain commas and `""`.
List<String> splitCsvLine(String line) {
  final cells = <String>[];
  final current = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        current.write(ch);
      }
    } else if (ch == '"' && current.toString().trim().isEmpty) {
      current.clear();
      quoted = true;
    } else if (ch == ',') {
      cells.add(current.toString().trim());
      current.clear();
    } else {
      current.write(ch);
    }
  }
  cells.add(current.toString().trim());
  return cells;
}

/// `₹1,20,000.50`, `Rs. 450`, `1 200` → numbers; `null` if not a number.
double? parseSheetNumber(String text) {
  var t = text.trim();
  if (t.isEmpty) return null;
  t = t.replaceAll(RegExp(r'^(₹|rs\.?|inr)\s*', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'[,\s ]'), '');
  return double.tryParse(t);
}

/// Maps a header row to columns, or `null` if [cells] is not a header (a
/// header has no numbers where qty and rate would be and names a
/// description or qty column).
List<BoqColumn?>? _headerColumns(List<String> cells) {
  final mapped = [for (final cell in cells) _columnFor(cell)];
  final recognised = mapped.whereType<BoqColumn>().toSet();
  final namesQtyOrRate =
      recognised.contains(BoqColumn.qty) || recognised.contains(BoqColumn.rate);
  if (recognised.length < 2 || !namesQtyOrRate) return null;
  if (cells.any((c) => parseSheetNumber(c) != null)) return null;
  // The first match wins if a name repeats.
  final seen = <BoqColumn>{};
  return [
    for (final column in mapped)
      if (column == null || !seen.add(column)) null else column,
  ];
}

BoqColumn? _columnFor(String header) {
  final h = header
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (h.isEmpty) return null;
  bool has(String prefix) => RegExp('\\b$prefix').hasMatch(h);
  bool word(String w) => RegExp('\\b$w\\b').hasMatch(h);
  if (has('material')) return BoqColumn.materialBudget;
  if (has('labour') || has('labor')) return BoqColumn.labourBudget;
  if (has('other')) return BoqColumn.otherBudget;
  if (has('amount') || has('total') || has('value')) return BoqColumn.amount;
  if (has('rate') || has('price')) return BoqColumn.rate;
  if (has('qty') || has('quantit') || has('qnty')) return BoqColumn.qty;
  if (has('unit') || has('uom')) return BoqColumn.unit;
  if (has('desc') || has('particular') || has('work') || has('detail')) {
    return BoqColumn.description;
  }
  if (has('code') ||
      word('no') ||
      word('ref') ||
      word('sl') ||
      word('sr') ||
      word('s') ||
      word('item') ||
      has('boq')) {
    return BoqColumn.code;
  }
  return null;
}
