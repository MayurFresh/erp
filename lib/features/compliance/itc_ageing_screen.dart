import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../reports/report_widgets.dart' show StatRow, StatTile, tabularFigures;
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';

/// `/itc-ageing`: unpaid purchases against the 180-day ITC rule.
class ItcAgeingScreen extends ConsumerWidget {
  const ItcAgeingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(itcAgeingProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'ITC ageing',
          subtitle: 'Input tax on bills unpaid for 180 days must be reversed',
        ),
        Expanded(
          child: AsyncValueView<ItcAgeing>(
            value: value,
            onRetry: () => ref.invalidate(itcAgeingProvider),
            data: (a) => a.rows.isEmpty
                ? const EmptyView(
                    message: 'No unpaid purchases carrying input tax.',
                    icon: Icons.verified_outlined,
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      StatRow(
                        children: [
                          StatTile(
                            label: 'Unpaid',
                            value: formatMoney(a.unpaid),
                          ),
                          StatTile(
                            label: 'ITC claimed',
                            value: formatMoney(a.itc),
                          ),
                          StatTile(
                            label: 'ITC to reverse',
                            value: formatMoney(a.reversal),
                            caption: 'as of ${formatDate(a.asOf)}',
                          ),
                        ],
                      ),
                      for (final r in a.rows) _ItcCard(row: r),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _ItcCard extends StatelessWidget {
  const _ItcCard({required this.row});

  final ItcRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (row.status) {
      'due' => 'Reverse now',
      'warn' => '${row.daysLeft} days left',
      _ => '${row.daysLeft} days left',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => context.go('/purchases/${row.purchaseId}'),
        title: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${row.number} · ${row.partyName}'),
            StatusPill(row.status, label: label),
          ],
        ),
        subtitle: Text(
          'Bill ${formatDate(row.billDate)} · 180th day ${formatDate(row.day180)}\n'
          'Unpaid ${formatAmount(row.unpaid)} of ${formatAmount(row.total)}',
        ),
        isThreeLine: true,
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('ITC ${formatAmount(row.itc)}', style: tabularFigures),
            Text(
              'Reverse ${formatAmount(row.reversal)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: row.status == 'ok'
                    ? null
                    : statusColor(context, row.status),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
