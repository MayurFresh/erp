import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounting/account_picker.dart';
import '../auth/session.dart';
import '../reports/report_widgets.dart';
import 'finance_models.dart';
import 'finance_repository.dart';

List<String> _yearChoices() {
  final now = DateTime.now();
  final cur = now.month >= 4 ? now.year : now.year - 1;
  return [
    for (var y = cur + 1; y >= cur - 3; y--)
      '$y-${((y + 1) % 100).toString().padLeft(2, '0')}',
  ];
}

Color _statusColor(BuildContext context, String status) => switch (status) {
  'over' => Theme.of(context).colorScheme.error,
  'warn' => const Color(0xFF8A5200),
  _ => Theme.of(context).colorScheme.onSurfaceVariant,
};

/// `/budgets`: budget against actual for a month and the year to date.
class BudgetVarianceScreen extends ConsumerStatefulWidget {
  const BudgetVarianceScreen({super.key});

  @override
  ConsumerState<BudgetVarianceScreen> createState() => _VarianceState();
}

class _VarianceState extends ConsumerState<BudgetVarianceScreen> {
  String _fy = fyLabelOf(DateTime.now());
  late String _month = () {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}';
  }();

  @override
  Widget build(BuildContext context) {
    final months = fyMonths(_fy);
    if (!months.contains(_month)) _month = months.first;
    final value = ref.watch(budgetVarianceProvider((fy: _fy, month: _month)));
    final canEdit = ref.watch(permissionsProvider).can(Perm.finreportsManage);
    return ReportPage(
      title: 'Budget against actual',
      subtitle: 'Expense accounts turn amber at 90% and red above 100%',
      export: null,
      extraActions: [
        if (canEdit)
          FilledButton.icon(
            onPressed: () => context.go('/budgets/edit?fy=$_fy'),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit budget'),
          ),
      ],
      controls: [
        SizedBox(
          width: 150,
          child: DropdownButtonFormField<String>(
            initialValue: _fy,
            decoration: const InputDecoration(labelText: 'Financial year'),
            items: [for (final y in _yearChoices()) DropdownMenuItem(value: y, child: Text(y))],
            onChanged: (v) => setState(() => _fy = v ?? _fy),
          ),
        ),
        SizedBox(
          width: 170,
          child: DropdownButtonFormField<String>(
            initialValue: _month,
            decoration: const InputDecoration(labelText: 'Month'),
            items: [for (final m in months) DropdownMenuItem(value: m, child: Text(monthLabel(m)))],
            onChanged: (v) => setState(() => _month = v ?? _month),
          ),
        ),
      ],
      body: ReportBody<BudgetVariance>(
        value: value,
        onRetry: () => ref.invalidate(budgetVarianceProvider((fy: _fy, month: _month))),
        isEmpty: (v) => v.rows.isEmpty,
        emptyMessage: 'No budget for $_fy yet. Use Edit budget to set one.',
        builder: varianceBlocks,
      ),
    );
  }
}

/// Alert lines then one card per budget row; public for tests.
List<Widget> varianceBlocks(BudgetVariance v) => [
  for (final a in v.alerts)
    Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _AlertLine(alert: a),
    ),
  if (v.alerts.isNotEmpty) const SizedBox(height: 6),
  for (final r in v.rows) _VarianceCard(row: r, month: v.month),
];

class _AlertLine extends StatelessWidget {
  const _AlertLine({required this.alert});
  final BudgetAlert alert;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, alert.level);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_outlined, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(alert.text, style: TextStyle(color: color))),
      ],
    );
  }
}

class _VarianceCard extends StatelessWidget {
  const _VarianceCard({required this.row, required this.month});
  final VarianceRow row;
  final String month;

  Widget _figures(BuildContext context, String label, Figures f) {
    final theme = Theme.of(context);
    final color = row.type == 'expense' && f.variance > 0
        ? theme.colorScheme.error
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          Wrap(
            spacing: 16,
            runSpacing: 2,
            children: [
              Text('Budget ${formatMoney(f.budget)}'),
              Text('Actual ${formatMoney(f.actual)}'),
              Text(
                'Variance ${formatMoney(f.variance)}',
                style: TextStyle(color: color),
              ),
              Text(f.percentText),
            ],
          ),
          if (f.percentUsed != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: (f.percentUsed! / 100).clamp(0.0, 1.0),
                minHeight: 6,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = switch (row.status) {
      'over' => 'Over budget',
      'warn' => 'Near the limit',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SectionCard(
        title: '${row.code}  ${row.name}'
            '${row.costCentreName == null ? '' : ' (${row.costCentreName})'}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (label.isNotEmpty)
              Text(label, style: TextStyle(color: _statusColor(context, row.status), fontWeight: FontWeight.w600)),
            _figures(context, monthLabel(month), row.month),
            _figures(context, 'Year to date', row.ytd),
          ],
        ),
      ),
    );
  }
}

/// `/budgets/edit?fy=`: set months per account, or copy last year.
class BudgetEditScreen extends ConsumerStatefulWidget {
  const BudgetEditScreen({super.key, this.fy});
  final String? fy;

  @override
  ConsumerState<BudgetEditScreen> createState() => _EditState();
}

class _EditState extends ConsumerState<BudgetEditScreen> {
  late String _fy = widget.fy ?? fyLabelOf(DateTime.now());

  Future<void> _edit({BudgetRow? row}) async {
    String? accountId = row?.accountId;
    var label = row == null ? '' : '${row.code}  ${row.name}';
    if (row == null) {
      final a = await pickAccount(context, ref);
      if (a == null || !mounted) return;
      if (a.type != 'income' && a.type != 'expense') {
        showInfoSnackBar(context, 'Budgets are for income and expense accounts.');
        return;
      }
      accountId = a.id;
      label = '${a.code}  ${a.name}';
    }
    final months = await showFormDialog<Map<String, double>>(
      context: context,
      builder: (c) => _MonthsDialog(fy: _fy, title: label, initial: row?.months ?? const {}),
    );
    if (months == null || !mounted) return;
    try {
      await ref.read(financeRepositoryProvider).saveBudget(_fy, accountId!, months, costCentreId: row?.costCentreId);
      ref.read(financeRevisionProvider.notifier).bump();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _copy() async {
    final result = await showFormDialog<({String from, double uplift})>(
      context: context,
      builder: (c) => _CopyDialog(toFy: _fy),
    );
    if (result == null || !mounted) return;
    final repo = ref.read(financeRepositoryProvider);
    try {
      try {
        await repo.copyBudget(result.from, _fy, result.uplift, false);
      } catch (_) {
        if (!mounted) return;
        final replace = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Replace the budget for $_fy?'),
            content: const Text('This year already has a budget. Copying replaces it.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Replace')),
            ],
          ),
        );
        if (replace != true) return;
        await repo.copyBudget(result.from, _fy, result.uplift, true);
      }
      ref.read(financeRevisionProvider.notifier).bump();
      if (mounted) showInfoSnackBar(context, 'Budget copied into $_fy.');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(budgetsProvider(_fy));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Edit budget',
          subtitle: 'Monthly amounts per income or expense account',
          actions: [
            OutlinedButton(onPressed: _copy, child: const Text('Copy from another year')),
            FilledButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('Add account'),
            ),
          ],
        ),
        FilterBar(
          children: [
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<String>(
                initialValue: _fy,
                decoration: const InputDecoration(labelText: 'Financial year'),
                items: [for (final y in _yearChoices()) DropdownMenuItem(value: y, child: Text(y))],
                onChanged: (v) => setState(() => _fy = v ?? _fy),
              ),
            ),
          ],
        ),
        Expanded(
          child: ReportBody<List<BudgetRow>>(
            value: value,
            onRetry: () => ref.invalidate(budgetsProvider(_fy)),
            isEmpty: (r) => r.isEmpty,
            emptyMessage: 'No budget for $_fy. Add an account or copy another year.',
            builder: (rows) => [
              for (final r in rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  minTileHeight: 56,
                  title: Text('${r.code}  ${r.name}'),
                  subtitle: Text(
                    '${r.costCentreName == null ? '' : '${r.costCentreName} · '}'
                    'Year ${formatMoney(r.total)}',
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _edit(row: r),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MonthsDialog extends StatefulWidget {
  const _MonthsDialog({required this.fy, required this.title, required this.initial});
  final String fy;
  final String title;
  final Map<String, double> initial;

  @override
  State<_MonthsDialog> createState() => _MonthsDialogState();
}

class _MonthsDialogState extends State<_MonthsDialog> {
  late final Map<String, TextEditingController> _c = {
    for (final m in fyMonths(widget.fy))
      m: TextEditingController(text: widget.initial[m] == null ? '' : formatPlain(widget.initial[m])),
  };
  final _all = TextEditingController();

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _all.dispose();
    super.dispose();
  }

  void _fill() {
    for (final c in _c.values) {
      c.text = _all.text;
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _all,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Same amount every month'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _fill, child: const Text('Fill')),
              ],
            ),
            for (final e in _c.entries)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: e.value,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: monthLabel(e.key)),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          for (final e in _c.entries)
            if ((double.tryParse(e.value.text.trim()) ?? 0) > 0)
              e.key: double.parse(e.value.text.trim()),
        }),
        child: const Text('Save'),
      ),
    ],
  );
}

class _CopyDialog extends StatefulWidget {
  const _CopyDialog({required this.toFy});
  final String toFy;

  @override
  State<_CopyDialog> createState() => _CopyDialogState();
}

class _CopyDialogState extends State<_CopyDialog> {
  late String _from = _yearChoices().firstWhere((y) => y != widget.toFy);
  final _uplift = TextEditingController(text: '0');

  @override
  void dispose() {
    _uplift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Copy into ${widget.toFy}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _from,
          decoration: const InputDecoration(labelText: 'Copy from'),
          items: [
            for (final y in _yearChoices().where((y) => y != widget.toFy))
              DropdownMenuItem(value: y, child: Text(y)),
          ],
          onChanged: (v) => setState(() => _from = v ?? _from),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _uplift,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: const InputDecoration(labelText: 'Increase by percent', helperText: 'Use a minus sign to reduce'),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
      FilledButton(
        onPressed: () => Navigator.pop(context, (from: _from, uplift: double.tryParse(_uplift.text.trim()) ?? 0)),
        child: const Text('Copy'),
      ),
    ],
  );
}
