import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../parties/party_reminder.dart';
import 'report_exports.dart';
import 'report_models.dart';
import 'report_period.dart';
import 'report_widgets.dart';
import 'reports_hub_screen.dart' show LocationFilter, locationName;
import 'reports_repository.dart';

/// `/reports/stock-valuation` (needs `items.view_cost` as well).
class StockValuationScreen extends ConsumerStatefulWidget {
  const StockValuationScreen({super.key});

  @override
  ConsumerState<StockValuationScreen> createState() => _ValuationState();
}

class _ValuationState extends ConsumerState<StockValuationScreen> {
  String? _locationId;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(permissionsProvider).can(Perm.itemsViewCost)) {
      return const EmptyView(
        icon: Icons.lock_outline,
        message: 'Stock valuation needs permission to see cost prices.',
      );
    }
    final value = ref.watch(stockValuationProvider(_locationId));
    return ReportPage(
      title: 'Stock valuation',
      subtitle: 'Weighted-average cost, as of today',
      export: value.value == null
          ? null
          : stockValuationExport(
              value.value!,
              location: locationName(ref, _locationId),
            ),
      controls: [
        LocationFilter(
          value: _locationId,
          onChanged: (v) => setState(() => _locationId = v),
        ),
      ],
      body: ReportBody<StockValuation>(
        value: value,
        onRetry: () => ref.invalidate(stockValuationProvider(_locationId)),
        isEmpty: (v) => v.rows.isEmpty,
        emptyMessage: 'No stock on hand.',
        emptyIcon: Icons.inventory_2_outlined,
        builder: (v) => [
          StatRow(
            children: [
              StatTile(label: 'Stock value', value: formatMoney(v.totalValue)),
              StatTile(label: 'Items', value: '${v.rows.length}'),
            ],
          ),
          ReportTable<StockValuationRow>(
            rows: v.rows,
            columns: [
              ReportColumn('Item', (r) => r.name, flex: true, maxWidth: 300),
              ReportColumn('SKU', (r) => r.sku ?? '—'),
              ReportColumn(
                'Qty',
                (r) => '${formatQty(r.qty)} ${r.unit}',
                numeric: true,
              ),
              ReportColumn(
                'Avg cost',
                (r) => formatMoney(r.avgCost),
                numeric: true,
              ),
              ReportColumn('Value', (r) => formatMoney(r.value), numeric: true),
            ],
            totals: ['Total', '', '', '', formatMoney(v.totalValue)],
            cardBuilder: (context, r) => ReportRowCard(
              title: r.name,
              subtitle: r.sku,
              trailing: formatMoney(r.value),
              pairs: [
                ('Qty', '${formatQty(r.qty)} ${r.unit}'),
                ('Avg cost', formatMoney(r.avgCost)),
              ],
            ),
            totalsCard: ReportRowCard(
              title: 'Total stock value',
              trailing: formatMoney(v.totalValue),
              highlight: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// `/reports/receivables-ageing` and `/reports/payables-ageing`.
class AgeingReportScreen extends ConsumerStatefulWidget {
  const AgeingReportScreen({super.key, required this.type});

  final AgeingType type;

  @override
  ConsumerState<AgeingReportScreen> createState() => _AgeingState();
}

class _AgeingState extends ConsumerState<AgeingReportScreen> {
  DateTime _asOf = dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    final key = (type: type, asOf: apiDate(_asOf));
    final value = ref.watch(ageingProvider(key));
    final canOpen = ref.watch(permissionsProvider).can(Perm.partiesView);
    void open(AgeingRow r) => context.push('/parties/${r.partyId}');
    final remind = type == AgeingType.receivables;
    Future<void> actions(AgeingRow r) async {
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(r.partyName)),
              if (canOpen)
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('Open party'),
                  onTap: () => Navigator.pop(ctx, 'open'),
                ),
              ListTile(
                leading: const Icon(Icons.chat_outlined),
                title: const Text('Send reminder on WhatsApp'),
                onTap: () => Navigator.pop(ctx, 'remind'),
              ),
            ],
          ),
        ),
      );
      if (!context.mounted) return;
      if (choice == 'open') {
        open(r);
      } else if (choice == 'remind') {
        await sendPartyReminder(
          context,
          ref,
          partyId: r.partyId,
          partyName: r.partyName,
          amountDue: r.buckets.total,
        );
      }
    }

    return ReportPage(
      title: type.title,
      subtitle: type.description,
      export: value.value == null ? null : ageingExport(value.value!, type),
      controls: [
        AsOfButton(value: _asOf, onChanged: (d) => setState(() => _asOf = d)),
      ],
      body: ReportBody<Ageing>(
        value: value,
        onRetry: () => ref.invalidate(ageingProvider(key)),
        isEmpty: (a) => a.rows.isEmpty,
        emptyMessage: type == AgeingType.receivables
            ? 'No customer dues as of ${formatDate(_asOf)}.'
            : 'No vendor dues as of ${formatDate(_asOf)}.',
        builder: (a) => [
          AgeingSummary(totals: a.totals),
          ReportTable<AgeingRow>(
            rows: a.rows,
            onTap: remind ? actions : (canOpen ? open : null),
            columns: [
              ReportColumn(
                type == AgeingType.receivables ? 'Customer' : 'Vendor',
                (r) => r.partyName,
                flex: true,
                maxWidth: 260,
              ),
              for (final (i, label) in ageingBucketLabels.indexed)
                ReportColumn(
                  label,
                  (r) => formatOptionalMoney(r.buckets.values[i]),
                  numeric: true,
                ),
              ReportColumn(
                'Total',
                (r) => formatMoney(r.buckets.total),
                numeric: true,
              ),
            ],
            totals: [
              'Total',
              for (final v in a.totals.values) formatMoney(v),
              formatMoney(a.totals.total),
            ],
            cardBuilder: (context, r) => ReportRowCard(
              title: r.partyName,
              trailing: formatMoney(r.buckets.total),
              subtitle: r.buckets.overdue > kMoneyEpsilon
                  ? 'Overdue ${formatMoney(r.buckets.overdue)}'
                  : 'Nothing overdue',
              pairs: [
                for (final (i, label) in ageingBucketLabels.indexed)
                  if (!isZeroAmount(r.buckets.values[i]))
                    (label, formatMoney(r.buckets.values[i])),
              ],
              onTap: remind
                  ? () => actions(r)
                  : (canOpen ? () => open(r) : null),
            ),
            totalsCard: ReportRowCard(
              title: 'Total outstanding',
              trailing: formatMoney(a.totals.total),
              highlight: true,
              pairs: [
                for (final (i, label) in ageingBucketLabels.indexed)
                  (label, formatMoney(a.totals.values[i])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bucket totals as tiles with their share, plus a stacked bar.
class AgeingSummary extends StatelessWidget {
  const AgeingSummary({super.key, required this.totals});

  final AgeingBuckets totals;

  static List<Color> colors(ColorScheme scheme) => [
    Colors.green.shade600,
    Colors.amber.shade700,
    Colors.orange.shade700,
    Colors.deepOrange.shade700,
    scheme.error,
  ];

  @override
  Widget build(BuildContext context) {
    final palette = colors(Theme.of(context).colorScheme);
    final shares = totals.shares;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (totals.total.abs() > kMoneyEpsilon)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 10,
                child: Row(
                  children: [
                    for (final (i, share) in shares.indexed)
                      if (share > 0)
                        Expanded(
                          flex: (share * 1000).round().clamp(1, 1000),
                          child: ColoredBox(color: palette[i]),
                        ),
                  ],
                ),
              ),
            ),
          ),
        StatRow(
          children: [
            for (final (i, label) in ageingBucketLabels.indexed)
              StatTile(
                label: label,
                value: formatMoney(totals.values[i]),
                caption: formatShare(shares[i]),
                color: i == 0 || isZeroAmount(totals.values[i])
                    ? null
                    : palette[i],
                width: 170,
              ),
          ],
        ),
      ],
    );
  }
}
