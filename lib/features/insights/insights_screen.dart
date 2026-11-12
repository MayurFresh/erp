import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/charts/charts.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../reports/report_export.dart';
import '../reports/report_period.dart';
import 'analytics_models.dart';
import 'analytics_repository.dart';
import 'analytics_widgets.dart';
import 'insights_rules.dart';

/// `/insights`: the dashboard's data with more depth, a free date range,
/// comparison with the previous period and plain-language takeaways.
class InsightsScreen extends ConsumerStatefulWidget {
  const InsightsScreen({super.key});

  @override
  ConsumerState<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends ConsumerState<InsightsScreen> {
  RangePreset? _preset = RangePreset.fyToDate;
  DateRange _range = RangePreset.fyToDate.resolve();

  Future<void> _pick() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
      initialDateRange: DateTimeRange(start: _range.from, end: _range.to),
    );
    if (picked == null) return;
    setState(() {
      _preset = null;
      _range = DateRange(picked.start, picked.end);
    });
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final value = ref.watch(analyticsProvider(_range));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Insights',
          subtitle: _range.label,
          actions: [
            FilledButton.icon(
              onPressed: () => context.go('/reports/client-report'),
              icon: const Icon(Icons.slideshow_outlined),
              label: const Text('Client report'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final p in kAnalyticsPresets)
                        Padding(
                          padding: const EdgeInsets.only(right: Space.sm),
                          child: ChoiceChip(
                            label: Text(p.label),
                            selected: p == _preset,
                            onSelected: (_) => setState(() {
                              _preset = p;
                              _range = p.resolve();
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                label: const Text('Custom'),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.sm),
        Expanded(
          child: AsyncValueView(
            value: value,
            onRetry: () => ref.invalidate(analyticsProvider(_range)),
            data: (a) => RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(analyticsProvider(_range));
                await ref.read(analyticsProvider(_range).future);
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  0,
                  Space.lg,
                  Space.xl,
                ),
                children: [_Content(a: a, perms: perms)],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.a, required this.perms});

  final Analytics a;
  final PermissionSet perms;

  @override
  Widget build(BuildContext context) {
    final takeaways = buildTakeaways(a);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Layout.contentMaxWidth),
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            void open(String path) => context.go(path);
            VoidCallback? link(bool ok, String path) =>
                ok ? () => open(path) : null;
            final cols = chartColumns(w);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TakeawayCard(takeaways: takeaways, a: a),
                const SizedBox(height: Space.md),
                FlowGrid(
                  equalHeight: true,
                  columns: tileColumns(w),
                  children: [
                    for (final t in statTiles(context, a, perms, open)) (1, t),
                  ],
                ),
                const SizedBox(height: Space.md),
                FlowGrid(
                  columns: cols,
                  children: [
                    (
                      2,
                      salesPurchasesCard(
                        a,
                        onTap: link(perms.can(Perm.invoicesView), '/invoices'),
                      ),
                    ),
                    if (a.cashFlow != null)
                      (
                        1,
                        cashCard(
                          a,
                          onTap: link(
                            perms.can(Perm.paymentsView),
                            '/receipts',
                          ),
                        ),
                      ),
                    (
                      1,
                      ageingCard(
                        'Receivables ageing',
                        a.receivableAgeing,
                        onTap: () => open('/reports/receivables-ageing'),
                      ),
                    ),
                    (
                      1,
                      ageingCard(
                        'Payables ageing',
                        a.payableAgeing,
                        document: 'bill',
                        onTap: () => open('/reports/payables-ageing'),
                      ),
                    ),
                    (
                      1,
                      rankedCard(
                        'Top customers',
                        a.topCustomers,
                        subtitle: 'Share of sales in this period',
                        caption: shareCaption,
                        maxRows: 10,
                        onTap: link(perms.can(Perm.partiesView), '/parties'),
                      ),
                    ),
                    (
                      1,
                      rankedCard(
                        'Top items',
                        a.topItems,
                        subtitle: 'By sales value',
                        maxRows: 10,
                        onTap: link(perms.can(Perm.itemsView), '/items'),
                      ),
                    ),
                    if (a.salesByLocation.length > 1)
                      (
                        1,
                        rankedCard(
                          'Sales by location',
                          a.salesByLocation,
                          maxRows: 8,
                        ),
                      ),
                    if (a.expensesByCategory.isNotEmpty) (1, _expensesCard(a)),
                  ],
                ),
                const SizedBox(height: Space.md),
                _CompareTable(a: a),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _expensesCard(Analytics a) {
    final rows = [...a.expensesByCategory]
      ..sort((x, y) => y.amount.compareTo(x.amount));
    final top = rows.take(5).toList();
    final rest = rows.skip(5).fold<double>(0, (s, r) => s + r.amount);
    return ChartCard(
      title: 'Where expenses went',
      subtitle: 'By category',
      onExport: () => shareCsv(
        ReportExport(
          title: 'Expenses by category',
          columns: const [
            ExportColumn('Category'),
            ExportColumn('Amount', CellKind.money),
          ],
          rows: [
            for (final r in rows) [r.name, r.amount],
          ],
        ),
      ),
      child: DonutChart(
        centerLabel: 'Total',
        slices: [
          for (final r in top) DonutSlice(r.name, r.amount),
          if (rest > 0) DonutSlice('Other', rest),
        ],
      ),
    );
  }
}

class _TakeawayCard extends StatelessWidget {
  const _TakeawayCard({required this.takeaways, required this.a});

  final List<Takeaway> takeaways;
  final Analytics a;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = ChartPalette.of(context);
    return ChartCard(
      title: 'What stands out',
      subtitle:
          'Compared with ${formatDate(a.previousFrom)} to ${formatDate(a.previousTo)}',
      isEmpty: takeaways.isEmpty,
      emptyText: 'Nothing to report for this period yet.',
      child: Column(
        children: [
          for (final t in takeaways)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 10),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: switch (t.tone) {
                          TakeawayTone.good => pal.good,
                          TakeawayTone.warning => pal.bad,
                          TakeawayTone.neutral => pal.label,
                        },
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(t.text, style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CompareTable extends StatelessWidget {
  const _CompareTable({required this.a});

  final Analytics a;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = ChartPalette.of(context);
    final rows = <(String, double?, double?, bool)>[
      ('Sales', a.current.sales, a.previous.sales, true),
      ('Purchases', a.current.purchases, a.previous.purchases, false),
      ('Expenses', a.current.expenses, a.previous.expenses, false),
      ('Collections', a.current.collections, a.previous.collections, true),
      ('Payments made', a.current.payments, a.previous.payments, false),
      ('Gross profit', a.current.grossProfit, a.previous.grossProfit, true),
      ('Net profit', a.current.netProfit, a.previous.netProfit, true),
      ('Receivables', a.current.receivables, a.previous.receivables, false),
      ('Payables', a.current.payables, a.previous.payables, false),
      ('Cash and bank', a.current.cashAndBank, a.previous.cashAndBank, true),
      ('Stock value', a.current.stockValue, a.previous.stockValue, true),
    ].where((r) => r.$2 != null).toList();
    final export = ReportExport(
      title: 'Period comparison',
      subtitle: a.from,
      columns: const [
        ExportColumn('Figure'),
        ExportColumn('This period', CellKind.money),
        ExportColumn('Previous period', CellKind.money),
        ExportColumn('Change %', CellKind.rate),
      ],
      rows: [
        for (final r in rows)
          [r.$1, r.$2, r.$3, percentChange(r.$2, r.$3)?.roundToDouble()],
      ],
    );
    return ChartCard(
      title: 'This period against the previous one',
      subtitle:
          '${formatDate(a.from)} to ${formatDate(a.to)} against '
          '${formatDate(a.previousFrom)} to ${formatDate(a.previousTo)}',
      onExport: () => shareCsv(export),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text('', style: theme.textTheme.labelSmall),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  'This period',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(color: pal.label),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  'Previous',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(color: pal.label),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  'Change',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(color: pal.label),
                ),
              ),
            ],
          ),
          const Divider(height: 12),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(r.$1, style: theme.textTheme.bodySmall),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      formatCompact(r.$2),
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      formatCompact(r.$3),
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Expanded(flex: 2, child: _change(context, r.$2, r.$3, r.$4)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _change(
    BuildContext context,
    double? cur,
    double? prev,
    bool upIsGood,
  ) {
    final pal = ChartPalette.of(context);
    final d = percentChange(cur, prev);
    final style = Theme.of(context).textTheme.bodySmall;
    if (d == null) {
      return Text(
        'n/a',
        textAlign: TextAlign.right,
        style: style?.copyWith(color: pal.label),
      );
    }
    final flat = d.abs() < 0.5;
    final color = flat ? pal.label : ((d > 0) == upIsGood ? pal.good : pal.bad);
    return Text(
      formatDeltaPercent(d),
      textAlign: TextAlign.right,
      style: style?.copyWith(color: color, fontWeight: FontWeight.w700),
    );
  }
}
