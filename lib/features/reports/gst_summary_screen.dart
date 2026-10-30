import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import 'report_exports.dart';
import 'report_models.dart';
import 'report_period.dart';
import 'report_widgets.dart';
import 'reports_repository.dart';

/// `/reports/gst-summary`: outward supplies by rate with B2B / B2C and
/// credit notes, inward supplies and expenses, the HSN summary and the net
/// tax payable (negative = credit carried forward).
class GstSummaryScreen extends ConsumerStatefulWidget {
  const GstSummaryScreen({super.key});

  @override
  ConsumerState<GstSummaryScreen> createState() => _GstSummaryState();
}

class _GstSummaryState extends ConsumerState<GstSummaryScreen> {
  DateRange _range = RangePreset.thisMonth.resolve();

  @override
  Widget build(BuildContext context) {
    final key = (from: _range.apiFrom, to: _range.apiTo, locationId: null);
    final value = ref.watch(gstSummaryProvider(key));
    return ReportPage(
      title: 'GST summary',
      subtitle: '${_range.label} · posted documents only',
      export: value.value == null
          ? null
          : gstSummaryExport(value.value!, period: _range.label),
      controls: [
        PeriodButton(
          value: _range,
          onChanged: (r) => setState(() => _range = r),
        ),
      ],
      body: ReportBody<GstSummary>(
        value: value,
        onRetry: () => ref.invalidate(gstSummaryProvider(key)),
        isEmpty: (g) => g.isEmpty,
        emptyMessage: 'No GST transactions in this period.',
        builder: (g) => [
          NetPayableCard(net: g.netPayable),
          const ReportSectionTitle('Outward supplies (sales)'),
          StatRow(
            children: [
              StatTile(
                label: 'B2B · ${g.outward.b2b.count} invoices',
                value: formatMoney(g.outward.b2b.taxable),
                caption: 'Tax ${formatMoney(g.outward.b2b.tax)}',
              ),
              StatTile(
                label: 'B2C · ${g.outward.b2c.count} invoices',
                value: formatMoney(g.outward.b2c.taxable),
                caption: 'Tax ${formatMoney(g.outward.b2c.tax)}',
              ),
            ],
          ),
          _RateTable(
            rows: [
              for (final r in g.outward.byRate)
                ('GST ${formatPercent(r.gstRate)}', r, false),
              ('Less: credit notes', g.outward.creditNotes, false),
              ('Net outward', g.outward.net, true),
            ],
          ),
          const ReportSectionTitle('Inward supplies (input tax credit)'),
          _RateTable(
            rows: [
              for (final r in g.inward.byRate)
                ('GST ${formatPercent(r.gstRate)}', r, false),
              ('Expenses', g.inward.expenses, false),
              ('Total input tax', g.inward.total, true),
            ],
          ),
          const ReportSectionTitle('HSN summary (outward)'),
          ReportTable<HsnRow>(
            rows: g.hsn,
            emptyText: 'No HSN-wise sales.',
            columns: [
              ReportColumn('HSN', (h) => h.hsnCode ?? '—'),
              ReportColumn('Unit', (h) => h.unit ?? ''),
              ReportColumn('Qty', (h) => formatQty(h.qty), numeric: true),
              ReportColumn(
                'Taxable',
                (h) => formatMoney(h.taxable),
                numeric: true,
                flex: true,
              ),
              ReportColumn('CGST', (h) => formatMoney(h.cgst), numeric: true),
              ReportColumn('SGST', (h) => formatMoney(h.sgst), numeric: true),
              ReportColumn('IGST', (h) => formatMoney(h.igst), numeric: true),
            ],
            totals: [
              'Total',
              '',
              '',
              formatMoney(g.hsn.fold<double>(0, (s, h) => s + h.taxable)),
              formatMoney(g.hsn.fold<double>(0, (s, h) => s + h.cgst)),
              formatMoney(g.hsn.fold<double>(0, (s, h) => s + h.sgst)),
              formatMoney(g.hsn.fold<double>(0, (s, h) => s + h.igst)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Rate-wise rows; the last flagged row is the bold total.
class _RateTable extends StatelessWidget {
  const _RateTable({required this.rows});

  final List<(String, GstRateRow, bool)> rows;

  @override
  Widget build(BuildContext context) {
    final body = rows.where((r) => !r.$3).toList();
    final total = rows.where((r) => r.$3).firstOrNull;
    String m(double v) => formatMoney(v);
    return ReportTable<(String, GstRateRow, bool)>(
      rows: body,
      columns: [
        ReportColumn('Rate', (r) => r.$1, flex: true),
        ReportColumn('Taxable', (r) => m(r.$2.taxable), numeric: true),
        ReportColumn('CGST', (r) => m(r.$2.cgst), numeric: true),
        ReportColumn('SGST', (r) => m(r.$2.sgst), numeric: true),
        ReportColumn('IGST', (r) => m(r.$2.igst), numeric: true),
        ReportColumn('Total tax', (r) => m(r.$2.tax), numeric: true),
      ],
      totals: total == null
          ? null
          : [
              total.$1,
              m(total.$2.taxable),
              m(total.$2.cgst),
              m(total.$2.sgst),
              m(total.$2.igst),
              m(total.$2.tax),
            ],
    );
  }
}

/// The highlighted result: tax payable per head, or credit carried
/// forward when negative.
class NetPayableCard extends StatelessWidget {
  const NetPayableCard({super.key, required this.net});

  final GstNetPayable net;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credit = net.total < -kMoneyEpsilon;
    final bg = credit
        ? Colors.green.withValues(alpha: 0.12)
        : theme.colorScheme.primaryContainer;
    final fg = credit
        ? Colors.green.shade800
        : theme.colorScheme.onPrimaryContainer;
    Widget head(String label, double v) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: theme.textTheme.labelMedium?.copyWith(color: fg)),
        Text(
          formatNetTax(v),
          style: theme.textTheme.bodyLarge
              ?.merge(tabularFigures)
              .copyWith(color: fg, fontWeight: FontWeight.w600),
        ),
      ],
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              credit ? 'Net GST — credit carried forward' : 'Net GST payable',
              style: theme.textTheme.titleSmall?.copyWith(color: fg),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatMoney(net.total.abs()),
                style: theme.textTheme.headlineMedium
                    ?.merge(tabularFigures)
                    .copyWith(color: fg, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 32,
              runSpacing: 12,
              children: [
                head('CGST', net.cgst),
                head('SGST', net.sgst),
                head('IGST', net.igst),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Output tax on sales (after credit notes) less input tax on '
              'purchases and expenses. Negative heads are credit carried '
              'forward.',
              style: theme.textTheme.bodySmall?.copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
