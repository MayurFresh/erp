/// CSV and PDF tables for cash flow and ratio analysis. Pure Dart, so they can
/// be unit-tested; the screens hand them to the shared report export button.
library;

import '../../core/money.dart';
import '../reports/report_export.dart';
import 'finance_models.dart';

String _period(String from, String to) =>
    '${formatDate(from)} – ${formatDate(to)}';

/// Section, line and amount, with a column for last year when it was loaded,
/// a total per section and the cash reconciliation at the end.
ReportExport cashFlowExport(CashFlowReport r) {
  final c = r.current;
  final prev = r.previous;
  List<ExportColumn> columns() => [
    const ExportColumn('Section'),
    const ExportColumn('Line'),
    const ExportColumn('Amount', CellKind.money),
    if (prev != null) const ExportColumn('Last year', CellKind.money),
  ];
  List<Object?> row(String section, String line, double amount, double? last) =>
      [section, line, amount, if (prev != null) last];

  final rows = <List<Object?>>[
    row('Cash flow', 'Net profit', c.netProfit, prev?.netProfit),
    for (final s in c.sections) ...[
      for (final l in s.lines)
        row(s.title, l.label, l.amount, r.previousLine(s.key, l.key)),
      row(s.title, 'Total ${s.title}', s.total, prev?.section(s.key)?.total),
    ],
    row('Cash and bank', 'Opening', c.openingCash, prev?.openingCash),
    row('Cash and bank', 'Net change', c.netChange, prev?.netChange),
    row('Cash and bank', 'Closing', c.closingCash, prev?.closingCash),
    row('Check', 'Difference from the books', c.difference, prev?.difference),
  ];
  return ReportExport(
    title: 'Cash flow',
    subtitle: _period(c.from, c.to),
    fileStem: 'Cash-flow-${c.from}-${c.to}',
    columns: columns(),
    rows: rows,
  );
}

/// Group, ratio, value, formula; last year's value when it was loaded. Values
/// are written as shown on screen (`4.63 times`, `40%`).
ReportExport ratiosExport(RatioReport r) {
  final c = r.current;
  final prev = r.previous;
  return ReportExport(
    title: 'Ratio analysis',
    subtitle: _period(c.from, c.to),
    fileStem: 'Ratios-${c.from}-${c.to}',
    columns: [
      const ExportColumn('Group'),
      const ExportColumn('Ratio'),
      const ExportColumn('Value'),
      if (prev != null) const ExportColumn('Last year'),
      const ExportColumn('Formula'),
    ],
    rows: [
      for (final x in c.ratios)
        [
          ratioGroupLabels[x.group] ?? x.group,
          x.label,
          x.text,
          if (prev != null) prev.byKey(x.key)?.text ?? 'Not available',
          x.formula,
        ],
    ],
  );
}
