/// CSV / PDF tables for each report. Pure Dart so they can be unit-tested.
library;

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../accounting/accounting_models.dart' show accountTypeLabel;
import 'report_export.dart';
import 'report_models.dart';

const _money = CellKind.money;

String _asOf(String? asOf) => 'As of ${formatDate(asOf)}';

String _period(String? from, String? to, [String? fallback]) =>
    from == null || to == null
    ? (fallback ?? '')
    : '${formatDate(from)} – ${formatDate(to)}';

ReportExport trialBalanceExport(TrialBalance tb) => ReportExport(
  title: 'Trial balance',
  subtitle: _asOf(tb.asOf),
  fileStem: 'Trial-balance-${tb.asOf ?? ''}',
  columns: const [
    ExportColumn('Code'),
    ExportColumn('Account'),
    ExportColumn('Type'),
    ExportColumn('Debit', _money),
    ExportColumn('Credit', _money),
  ],
  rows: [
    for (final r in tb.rows)
      [
        r.code,
        r.name,
        accountTypeLabel(r.type),
        r.debit == 0 ? null : r.debit,
        r.credit == 0 ? null : r.credit,
      ],
  ],
  totals: [null, 'Total', null, tb.totalDebit, tb.totalCredit],
);

/// Section, code, account, amount — with the computed lines (gross profit,
/// net profit) as their own rows.
ReportExport profitLossExport(ProfitLoss pl, {String? period}) {
  List<List<Object?>> section(String name, StatementSection s) => [
    for (final r in s.rows) [name, r.code, r.name, r.amount],
    [name, null, 'Total $name', s.total],
  ];
  return ReportExport(
    title: 'Profit & loss',
    subtitle: _period(pl.from, pl.to, period),
    fileStem: 'Profit-and-loss-${pl.from ?? ''}-${pl.to ?? ''}',
    columns: const [
      ExportColumn('Section'),
      ExportColumn('Code'),
      ExportColumn('Account'),
      ExportColumn('Amount', _money),
    ],
    rows: [
      ...section('Revenue', pl.revenue),
      ...section('Cost of goods sold', pl.cogs),
      ['Gross profit', null, 'Gross profit', pl.grossProfit],
      ...section('Other income', pl.otherIncome),
      ...section('Expenses', pl.expenses),
    ],
    totals: [
      'Net profit',
      null,
      pl.netProfit < 0 ? 'Net loss' : 'Net profit',
      pl.netProfit,
    ],
  );
}

ReportExport balanceSheetExport(BalanceSheet bs) {
  List<List<Object?>> section(String name, StatementSection s) => [
    for (final r in s.rows) [name, r.code, r.name, r.amount],
    [name, null, 'Total $name', s.total],
  ];
  return ReportExport(
    title: 'Balance sheet',
    subtitle: _asOf(bs.asOf),
    fileStem: 'Balance-sheet-${bs.asOf ?? ''}',
    columns: const [
      ExportColumn('Section'),
      ExportColumn('Code'),
      ExportColumn('Account'),
      ExportColumn('Amount', _money),
    ],
    rows: [
      ...section('Assets', bs.assets),
      ['Assets', null, 'Total assets', bs.totalAssets],
      ...section('Liabilities', bs.liabilities),
      ...section('Equity', bs.equity),
    ],
    totals: [
      'Liabilities & equity',
      null,
      'Total liabilities & equity',
      bs.totalLiabilitiesAndEquity,
    ],
  );
}

/// Sales or purchase register; cancelled documents keep their row but are
/// zero in the totals (as the server computes them).
ReportExport registerExport(
  Register register, {
  required bool purchase,
  required String period,
  String? location,
}) => ReportExport(
  title: purchase ? 'Purchase register' : 'Sales register',
  subtitle: [period, ?location].join(' · '),
  fileStem: '${purchase ? 'Purchase' : 'Sales'}-register-$period',
  columns: [
    const ExportColumn('Number'),
    if (purchase) const ExportColumn('Supplier invoice'),
    const ExportColumn('Date'),
    ExportColumn(purchase ? 'Vendor' : 'Customer'),
    const ExportColumn('GSTIN'),
    const ExportColumn('Place of supply'),
    const ExportColumn('Taxable', _money),
    const ExportColumn('CGST', _money),
    const ExportColumn('SGST', _money),
    const ExportColumn('IGST', _money),
    const ExportColumn('Total', _money),
    const ExportColumn('Status'),
  ],
  rows: [
    for (final r in register.rows)
      [
        r.number,
        if (purchase) r.supplierInvoiceNo,
        formatDate(r.date),
        r.partyName,
        r.partyGstin,
        stateLabel(r.placeOfSupply),
        r.taxable,
        r.cgst,
        r.sgst,
        r.igst,
        r.total,
        r.isCancelled ? 'Cancelled' : 'Posted',
      ],
  ],
  totals: [
    'Total',
    if (purchase) null,
    null,
    '${register.postedCount} posted',
    null,
    null,
    register.totals.taxable,
    register.totals.cgst,
    register.totals.sgst,
    register.totals.igst,
    register.totals.total,
    null,
  ],
);

/// Every GST section stacked, with a "Section" column; the totals row is
/// the net payable.
ReportExport gstSummaryExport(GstSummary g, {String? period}) {
  List<Object?> rate(String section, String label, GstRateRow r) => [
    section,
    label,
    null,
    r.taxable,
    r.cgst,
    r.sgst,
    r.igst,
    r.tax,
  ];
  String rateLabel(GstRateRow r) =>
      r.gstRate == null ? '' : 'GST ${formatPercent(r.gstRate)}';
  return ReportExport(
    title: 'GST summary',
    subtitle: _period(g.from, g.to, period),
    fileStem: 'GST-summary-${g.from ?? ''}-${g.to ?? ''}',
    columns: const [
      ExportColumn('Section'),
      ExportColumn('Line'),
      ExportColumn('Qty / count', CellKind.qty),
      ExportColumn('Taxable', _money),
      ExportColumn('CGST', _money),
      ExportColumn('SGST', _money),
      ExportColumn('IGST', _money),
      ExportColumn('Total tax', _money),
    ],
    rows: [
      for (final r in g.outward.byRate) rate('Outward', rateLabel(r), r),
      [
        'Outward',
        'B2B (registered)',
        g.outward.b2b.count,
        g.outward.b2b.taxable,
        null,
        null,
        null,
        g.outward.b2b.tax,
      ],
      [
        'Outward',
        'B2C (unregistered)',
        g.outward.b2c.count,
        g.outward.b2c.taxable,
        null,
        null,
        null,
        g.outward.b2c.tax,
      ],
      rate('Outward', 'Less: credit notes', g.outward.creditNotes),
      rate('Outward', 'Net outward', g.outward.net),
      for (final r in g.inward.byRate) rate('Inward', rateLabel(r), r),
      rate('Inward', 'Expenses', g.inward.expenses),
      rate('Inward', 'Total input tax', g.inward.total),
      for (final h in g.hsn)
        [
          'HSN',
          '${h.hsnCode ?? 'No HSN'}${h.unit == null ? '' : ' (${h.unit})'}',
          h.qty,
          h.taxable,
          h.cgst,
          h.sgst,
          h.igst,
          h.tax,
        ],
    ],
    totals: [
      'Net payable',
      g.netPayable.total < 0 ? 'Credit carried forward' : 'Payable',
      null,
      null,
      g.netPayable.cgst,
      g.netPayable.sgst,
      g.netPayable.igst,
      g.netPayable.total,
    ],
  );
}

ReportExport stockValuationExport(StockValuation v, {String? location}) =>
    ReportExport(
      title: 'Stock valuation',
      subtitle: [
        'As of ${formatDate(DateTime.now())}',
        location ?? 'All locations',
      ].join(' · '),
      fileStem: 'Stock-valuation-${apiDate(DateTime.now())}',
      columns: const [
        ExportColumn('Item'),
        ExportColumn('SKU'),
        ExportColumn('Unit'),
        ExportColumn('Qty', CellKind.qty),
        ExportColumn('Avg cost', _money),
        ExportColumn('Value', _money),
      ],
      rows: [
        for (final r in v.rows)
          [r.name, r.sku, r.unit, r.qty, r.avgCost, r.value],
      ],
      totals: ['Total', null, null, null, null, v.totalValue],
    );

ReportExport ageingExport(Ageing a, AgeingType type) => ReportExport(
  title: type.title,
  subtitle: _asOf(a.asOf),
  fileStem: '${type.title}-${a.asOf ?? ''}',
  columns: [
    ExportColumn(type.partyLabel.substring(0, type.partyLabel.length - 1)),
    for (final label in ageingBucketLabels) ExportColumn(label, _money),
    const ExportColumn('Total', _money),
  ],
  rows: [
    for (final r in a.rows) [r.partyName, ...r.buckets.values, r.buckets.total],
  ],
  totals: ['Total', ...a.totals.values, a.totals.total],
);
