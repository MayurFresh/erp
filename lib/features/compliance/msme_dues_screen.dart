import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../reports/report_widgets.dart'
    show AsOfButton, StatRow, StatTile, tabularFigures;
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';

/// `/msme-dues`: unpaid micro and small supplier bills past 45 days.
class MsmeDuesScreen extends ConsumerStatefulWidget {
  const MsmeDuesScreen({super.key});

  @override
  ConsumerState<MsmeDuesScreen> createState() => _MsmeDuesScreenState();
}

class _MsmeDuesScreenState extends ConsumerState<MsmeDuesScreen> {
  DateTime _asOf = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final key = apiDate(_asOf);
    final value = ref.watch(msmeDuesProvider(key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'MSME dues',
          subtitle: 'Payments to micro and small suppliers (MSMED Act s.15-16)',
        ),
        FilterBar(
          children: [
            AsOfButton(
              value: _asOf,
              onChanged: (d) => setState(() => _asOf = d),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<MsmeDues>(
            value: value,
            onRetry: () => ref.invalidate(msmeDuesProvider(key)),
            data: (d) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (d.bankRate == null)
                  Card(
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: const Icon(Icons.warning_amber_outlined),
                      title: const Text('Bank rate is not set'),
                      subtitle: const Text(
                        'Interest cannot be worked out until you enter the '
                        'RBI bank rate in the company settings.',
                      ),
                      trailing: TextButton(
                        onPressed: () => context.go('/company'),
                        child: const Text('Company settings'),
                      ),
                    ),
                  ),
                WarningsBanner(
                  d.warnings.where((w) => d.bankRate != null).toList(),
                ),
                StatRow(
                  children: [
                    StatTile(
                      label: 'Unpaid to MSMEs',
                      value: formatMoney(d.unpaid),
                    ),
                    StatTile(
                      label: 'Overdue',
                      value: formatMoney(d.overdue),
                      color: d.overdue > 0
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    StatTile(
                      label: 'Interest payable',
                      value: d.bankRate == null ? '—' : formatMoney(d.interest),
                      caption: d.bankRate == null
                          ? null
                          : '3 × bank rate ${formatPercent(d.bankRate)}, monthly',
                    ),
                  ],
                ),
                SectionCard(
                  title: 'Year-end disallowance',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatMoney(d.yearEndDisallowance),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Past-due MSME amount at the last 31 March. Not '
                        'deductible until paid (income-tax s.37(2)(g), '
                        'formerly 43B(h)).',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (d.rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No unpaid MSME bills.')),
                  ),
                for (final r in d.rows)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      onTap: () => context.go('/purchases/${r.purchaseId}'),
                      title: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('${r.number} · ${r.partyName}'),
                          if (r.category.isNotEmpty) Pill(r.category),
                          if (r.daysOverdue > 0)
                            StatusPill(
                              'overdue',
                              label: '${r.daysOverdue} days overdue',
                            )
                          else
                            const StatusPill('ok', label: 'Not due'),
                        ],
                      ),
                      subtitle: Text(
                        'Bill ${formatDate(r.billDate)} · due ${formatDate(r.dueDate)}'
                        '${r.udyamNo == null ? '' : '\n${r.udyamNo}'}',
                      ),
                      trailing: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(formatAmount(r.unpaid), style: tabularFigures),
                          Text(
                            r.interest == null
                                ? 'Interest —'
                                : 'Interest ${formatAmount(r.interest)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
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
