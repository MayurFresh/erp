import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'gst_compliance_repository.dart';

/// `/einvoice-unreported`: invoices to GST customers with no IRN, with age.
class UnreportedEinvoiceScreen extends ConsumerWidget {
  const UnreportedEinvoiceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(unreportedProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Unreported e-invoices',
          subtitle:
              'With turnover of Rs 10 crore or more, the portal refuses an '
              'IRN more than 30 days after the invoice date.',
        ),
        Expanded(
          child: AsyncValueView<UnreportedView>(
            value: value,
            onRetry: () => ref.invalidate(unreportedProvider),
            data: (v) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (v.band != '10cr_plus')
                  const Card(
                    child: ListTile(
                      title: Text('The 30-day limit is not set for this company'),
                      subtitle: Text(
                        'Choose the turnover band "Rs 10 crore or more" in '
                        'the company settings if it applies to you.',
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${v.blocked} past the limit · ${v.warn} due soon · '
                      '${v.ok} within time',
                    ),
                  ),
                if (v.rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('Every invoice has an IRN.')),
                  ),
                for (final r in v.rows)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      minTileHeight: 56,
                      onTap: () => context.go('/invoices/${r.invoiceId}'),
                      title: Text('${r.number} · ${r.partyName}'),
                      subtitle: Text(
                        '${formatDate(r.date)} · ${r.ageDays} days old'
                        '${v.band == '10cr_plus' ? ' · last day ${formatDate(r.lastDay)}' : ''}',
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(formatMoney(r.total)),
                          if (r.state == 'blocked')
                            const StatusChip('overdue', label: 'Past limit')
                          else if (r.state == 'warn')
                            const StatusChip('pending', label: 'Due soon'),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
