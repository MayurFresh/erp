import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../core/permissions.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/project_models.dart';

/// Budget vs actual (material, labour, expenses) and material per BOQ line.
class CostsTab extends ConsumerWidget {
  const CostsTab({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canSeeCost = ref.watch(permissionsProvider).can(Perm.itemsViewCost);
    return AsyncValueView(
      value: ref.watch(projectCostsProvider(projectId)),
      onRetry: () => ref.invalidate(projectCostsProvider(projectId)),
      data: (c) => RefreshIndicator(
        onRefresh: () => ref.refresh(projectCostsProvider(projectId).future),
        child: CPage(
          children: [
            SectionCard(
              title: 'Budget vs actual',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (c.from != null || c.to != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Actuals ${formatDate(c.from)} – ${formatDate(c.to)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  BudgetBar(
                    label: 'Material',
                    budget: c.budget.material,
                    actual: c.actual.material,
                  ),
                  const SizedBox(height: 16),
                  BudgetBar(
                    label: 'Labour',
                    budget: c.budget.labour,
                    actual: c.actual.labour,
                  ),
                  const SizedBox(height: 16),
                  BudgetBar(
                    label: 'Other / expenses',
                    budget: c.budget.other,
                    actual: c.actual.other,
                  ),
                  const SizedBox(height: 16),
                  _SubcontractRow(amount: c.actual.subcontract),
                  const Divider(height: 32),
                  BudgetBar(
                    label: 'Total',
                    budget: c.budget.total,
                    actual: c.actual.total,
                  ),
                  if (!canSeeCost)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Material values need permission to see cost prices, '
                        'so they show as ₹0.00.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
            SectionCard(
              title: 'Material by BOQ line',
              child: c.byBoqLine.isEmpty
                  ? const Text('No BOQ lines yet.')
                  : _ByLine(rows: c.byBoqLine),
            ),
          ],
        ),
      ),
    );
  }
}

/// Approved RA bills (subcontract work) have no budget line, so only the
/// actual is shown.
class _SubcontractRow extends StatelessWidget {
  const _SubcontractRow({required this.amount});

  final double amount;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          'Subcontract (approved RA bills)',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      Text(
        formatMoney(amount),
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );
}

class _ByLine extends StatelessWidget {
  const _ByLine({required this.rows});

  final List<BoqCostRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 680) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                columnSpacing: 20,
                horizontalMargin: 8,
                columns: const [
                  DataColumn(label: Text('Code')),
                  DataColumn(label: Text('Description')),
                  DataColumn(label: Text('Progress')),
                  DataColumn(label: Text('Budget'), numeric: true),
                  DataColumn(label: Text('Actual'), numeric: true),
                  DataColumn(label: Text('Variance'), numeric: true),
                ],
                rows: [
                  for (final r in rows)
                    DataRow(
                      cells: [
                        DataCell(Text(r.code)),
                        DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: Text(
                              r.description,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        DataCell(
                          SizedBox(width: 110, child: PctBar(r.progressPct)),
                        ),
                        DataCell(Text(formatMoney(r.materialBudget))),
                        DataCell(Text(formatMoney(r.materialActual))),
                        DataCell(
                          Text(
                            formatMoney(r.materialVariance),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: r.materialVariance < 0
                                  ? theme.colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) const Divider(height: 24),
              BudgetBar(
                label: '${r.code} · ${r.description}',
                budget: r.materialBudget,
                actual: r.materialActual,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('Work done', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 8),
                  Expanded(child: PctBar(r.progressPct, height: 6)),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
