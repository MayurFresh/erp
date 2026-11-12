import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/charts/charts.dart';
import '../reports/report_export.dart';
import '../reports/report_period.dart';
import 'analytics_models.dart';

/// Periods offered on the dashboard and Insights.
const List<RangePreset> kAnalyticsPresets = [
  RangePreset.thisMonth,
  RangePreset.lastMonth,
  RangePreset.thisQuarter,
  RangePreset.fyToDate,
  RangePreset.lastFy,
];

/// A row of choice chips; scrolls sideways on narrow screens.
class PeriodChips extends StatelessWidget {
  const PeriodChips({super.key, required this.value, required this.onChanged});

  final RangePreset value;
  final ValueChanged<RangePreset> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final p in kAnalyticsPresets)
            Padding(
              padding: const EdgeInsets.only(right: Space.sm),
              child: ChoiceChip(
                label: Text(p.label),
                selected: p == value,
                onSelected: (_) => onChanged(p),
              ),
            ),
        ],
      ),
    );
  }
}

int tileColumns(double width) =>
    width >= 1100 ? 4 : (width >= 700 ? 3 : (width >= 340 ? 2 : 1));
int chartColumns(double width) => width >= 1100 ? 3 : (width >= 700 ? 2 : 1);

/// Shares [export] as a CSV file (downloads on the web).
Future<void> shareCsv(ReportExport export) => Printing.sharePdf(
  bytes: utf8.encode(export.toCsv()),
  filename: '${export.fileName}.csv',
);

/// Stat tiles for the figures the user's role can see.
List<Widget> statTiles(
  BuildContext context,
  Analytics a,
  PermissionSet perms,
  void Function(String path) open,
) {
  final c = a.current, p = a.previous;
  void Function()? go(bool ok, String path) => ok ? () => open(path) : null;
  Widget tile(
    String label,
    double? cur,
    double? prev, {
    bool upIsGood = true,
    List<double>? spark,
    Color? sparkColor,
    String? hint,
    VoidCallback? onTap,
  }) => StatTile(
    label: label,
    value: formatCompact(cur),
    deltaPercent: percentChange(cur, prev),
    upIsGood: upIsGood,
    spark: spark,
    sparkColor: sparkColor,
    hint: hint,
    onTap: onTap,
  );
  return [
    tile(
      'Sales',
      c.sales,
      p.sales,
      spark: a.salesSpark,
      onTap: go(perms.can(Perm.invoicesView), '/invoices'),
    ),
    tile(
      'Purchases',
      c.purchases,
      p.purchases,
      upIsGood: false,
      spark: a.purchasesSpark,
      sparkColor: ChartPalette.of(context).at(1),
      onTap: go(perms.can(Perm.purchasesView), '/purchases'),
    ),
    if (c.netProfit != null)
      tile(
        'Net profit',
        c.netProfit,
        p.netProfit,
        onTap: go(perms.can(Perm.accountsView), '/financials/profit-loss'),
      ),
    if (c.receivables != null)
      tile(
        'Receivables',
        c.receivables,
        p.receivables,
        upIsGood: false,
        hint: 'Owed to you',
        onTap: go(perms.can(Perm.reportsView), '/reports/receivables-ageing'),
      ),
    if (c.payables != null)
      tile(
        'Payables',
        c.payables,
        p.payables,
        upIsGood: false,
        hint: 'You owe suppliers',
        onTap: go(perms.can(Perm.reportsView), '/reports/payables-ageing'),
      ),
    if (c.cashAndBank != null)
      tile('Cash and bank', c.cashAndBank, p.cashAndBank, hint: 'Book balance'),
  ];
}

String _months(String m) => monthLabel(m);

/// A line needs three points to read as a trend; fewer are drawn as bars.
const int _minLinePoints = 3;

// ----------------------------------------------------------------- chart cards

Widget salesPurchasesCard(
  Analytics a, {
  VoidCallback? onTap,
  bool export = true,
}) {
  final labels = [for (final t in a.trend) _months(t.month)];
  List<ChartSeries> series(Color second) => [
    ChartSeries('Sales', [for (final t in a.trend) t.sales]),
    ChartSeries('Purchases', [
      for (final t in a.trend) t.purchases,
    ], color: second),
  ];
  final multiYear =
      a.trend.isNotEmpty &&
      a.trend.first.month.substring(0, 4) != a.trend.last.month.substring(0, 4);
  final shown = multiYear
      ? [for (final t in a.trend) monthLabel(t.month, withYear: true)]
      : labels;
  return Builder(
    builder: (context) => ChartCard(
      title: 'Sales and purchases by month',
      subtitle: 'Before tax, ${formatDate(a.from)} to ${formatDate(a.to)}',
      isEmpty: a.trend.every((t) => t.sales == 0 && t.purchases == 0),
      onTap: onTap,
      onExport: export
          ? () => shareCsv(
              ReportExport(
                title: 'Sales and purchases by month',
                columns: const [
                  ExportColumn('Month'),
                  ExportColumn('Sales', CellKind.money),
                  ExportColumn('Purchases', CellKind.money),
                  ExportColumn('Expenses', CellKind.money),
                ],
                rows: [
                  for (final t in a.trend)
                    [t.month, t.sales, t.purchases, t.expenses],
                ],
              ),
            )
          : null,
      child: a.trend.length < _minLinePoints
          ? GroupedBarChart(
              labels: shown,
              series: series(ChartPalette.of(context).at(1)),
            )
          : TrendChart(
              labels: shown,
              series: series(ChartPalette.of(context).at(1)),
            ),
    ),
  );
}

Widget cashCard(Analytics a, {VoidCallback? onTap, bool export = true}) {
  final cash = a.cashFlow ?? const <CashPoint>[];
  return Builder(
    builder: (context) {
      final pal = ChartPalette.of(context);
      return ChartCard(
        title: 'Cash in and cash out by month',
        subtitle: 'Receipts and payments',
        isEmpty: cash.every((t) => t.cashIn == 0 && t.cashOut == 0),
        onTap: onTap,
        onExport: export
            ? () => shareCsv(
                ReportExport(
                  title: 'Cash in and cash out by month',
                  columns: const [
                    ExportColumn('Month'),
                    ExportColumn('Cash in', CellKind.money),
                    ExportColumn('Cash out', CellKind.money),
                  ],
                  rows: [
                    for (final t in cash) [t.month, t.cashIn, t.cashOut],
                  ],
                ),
              )
            : null,
        child: GroupedBarChart(
          labels: [for (final t in cash) _months(t.month)],
          series: [
            ChartSeries('Cash in', [
              for (final t in cash) t.cashIn,
            ], color: pal.good),
            ChartSeries('Cash out', [
              for (final t in cash) t.cashOut,
            ], color: pal.at(1)),
          ],
        ),
      );
    },
  );
}

Widget ageingCard(
  String title,
  AgeingBuckets b, {
  String document = 'invoice',
  VoidCallback? onTap,
  bool export = true,
}) {
  return Builder(
    builder: (context) {
      final pal = ChartPalette.of(context);
      final warn = context.colors.warning;
      final bad = context.colors.danger;
      final slices = <DonutSlice>[];
      final all = b.labelled;
      for (var i = 0; i < all.length; i++) {
        final color = i == 0 ? pal.good : Color.lerp(warn, bad, (i - 1) / 3)!;
        slices.add(DonutSlice(all[i].$1, all[i].$2, color: color));
      }
      return ChartCard(
        title: title,
        subtitle: 'By how late each $document is',
        isEmpty: b.total <= 0,
        emptyText: 'Nothing is outstanding.',
        onTap: onTap,
        onExport: export
            ? () => shareCsv(
                ReportExport(
                  title: title,
                  columns: const [
                    ExportColumn('Age'),
                    ExportColumn('Amount', CellKind.money),
                  ],
                  rows: [
                    for (final s in all) [s.$1, s.$2],
                  ],
                  totals: ['Total', b.total],
                ),
              )
            : null,
        child: DonutChart(slices: slices, centerLabel: 'Total'),
      );
    },
  );
}

Widget rankedCard(
  String title,
  List<RankedRow> rows, {
  String? subtitle,
  String Function(RankedRow r)? caption,
  int maxRows = 5,
  VoidCallback? onTap,
  bool export = true,
  String emptyText = 'No sales in this period.',
}) {
  return ChartCard(
    title: title,
    subtitle: subtitle,
    isEmpty: rows.isEmpty,
    emptyText: emptyText,
    onTap: onTap,
    onExport: export
        ? () => shareCsv(
            ReportExport(
              title: title,
              columns: const [
                ExportColumn('Name'),
                ExportColumn('Amount', CellKind.money),
              ],
              rows: [
                for (final r in rows) [r.name, r.amount],
              ],
            ),
          )
        : null,
    child: RankedBarChart(
      maxRows: maxRows,
      bars: [
        for (final r in rows)
          RankedBar(r.name, r.amount, caption: caption?.call(r), id: r.id),
      ],
    ),
  );
}

String shareCaption(RankedRow r) =>
    r.share == null ? '' : '${r.share!.round()}%';
