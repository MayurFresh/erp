import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/file_save.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_form.dart';
import 'hr_models.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';

/// `/payroll`: one row per month.
class PayrollScreen extends ConsumerWidget {
  const PayrollScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [Perm.payrollView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Payroll',
            actions: [
              if (perms.can(Perm.payrollRun))
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('New run'),
                  onPressed: () async {
                    String? id;
                    final ok = await showHrForm(
                      context,
                      title: 'New payroll run',
                      action: 'Start',
                      fields: [
                        HrField('month', 'Month (YYYY-MM)', required: true, initial: monthOf(DateTime.now())),
                      ],
                      onSubmit: (v) async {
                        id = (await ref.read(hrRepositoryProvider).createRun('${v['month']}')).id;
                      },
                    );
                    if (ok && id != null && context.mounted) {
                      ref.bumpHr();
                      context.go('/payroll/$id');
                    }
                  },
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(runsProvider),
              onRetry: () => ref.invalidate(runsProvider),
              data: (runs) => runs.isEmpty
                  ? const EmptyView(icon: Icons.payments_outlined, message: 'No payroll runs yet.')
                  : ListView(
                      padding: EdgeInsets.all(pageGutter(context)),
                      children: [
                        for (final r in runs)
                          HrCard(
                            onTap: () => context.go('/payroll/${r.id}'),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(monthLabel(r.month), style: Theme.of(context).textTheme.titleSmall),
                                      Text('${r.employeeCount} employees, net ${formatMoney(r.net)}'),
                                    ],
                                  ),
                                ),
                                StatusChip(r.status, label: r.status == 'posted' ? 'Paid' : null),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `/payroll/:id`
class PayrollRunScreen extends ConsumerWidget {
  const PayrollRunScreen({super.key, required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final repo = ref.read(hrRepositoryProvider);
    return CGate(
      anyOf: const [Perm.payrollView],
      child: AsyncValueView(
        value: ref.watch(runProvider(runId)),
        onRetry: () => ref.invalidate(runProvider(runId)),
        data: (run) {
          Future<void> act(String action, {Json? body, String? confirm}) async {
            if (confirm != null && !await hrConfirm(context, '${action[0].toUpperCase()}${action.substring(1)}', confirm, 'Yes, $action')) {
              return;
            }
            try {
              await repo.runAction(run.id, action, body: body);
              ref.bumpHr();
            } catch (e) {
              if (context.mounted) showErrorSnackBar(context, e);
            }
          }

          final canRun = perms.can(Perm.payrollRun);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHeader(
                title: 'Payroll ${monthLabel(run.month)}',
                actions: [
                  if (canRun && run.editable)
                    OutlinedButton(onPressed: () => act('compute'), child: Text(run.status == 'draft' ? 'Work out pay' : 'Work out again')),
                  if (perms.can(Perm.payrollApprove) && run.status == 'computed')
                    FilledButton(
                      onPressed: run.canApprove
                          ? () => act('approve', confirm: 'Approve ${run.employeeCount} payslips and post the wages entry?')
                          : null,
                      child: const Text('Approve'),
                    ),
                  if (perms.can(Perm.payrollApprove) && run.status == 'approved')
                    FilledButton(
                      onPressed: () async {
                        final ok = await showHrForm(
                          context,
                          title: 'Pay salaries',
                          action: 'Pay',
                          fields: const [HrField('payDate', 'Pay date', kind: HrFieldKind.date)],
                          onSubmit: (v) => repo.runAction(run.id, 'pay', body: v),
                        );
                        if (ok) ref.bumpHr();
                      },
                      child: const Text('Mark paid'),
                    ),
                  if (canRun && run.editable)
                    TextButton(
                      onPressed: () => act('cancel', confirm: 'Cancel this run?'),
                      child: const Text('Cancel run'),
                    ),
                ],
              ),
              Expanded(
                child: HrPad(
                  children: [
                    Row(children: [StatusChip(run.status, label: run.status == 'posted' ? 'Paid' : null)]),
                    const SizedBox(height: Space.sm),
                    HrCard(
                      child: Column(
                        children: [
                          HrAmountRow('Employees', null, text: '${run.employeeCount}'),
                          HrAmountRow('Gross pay', run.gross),
                          HrAmountRow('Deductions', run.deductions),
                          HrAmountRow('Net pay', run.net, bold: true),
                          HrAmountRow('Cost to company', run.employerCost),
                        ],
                      ),
                    ),
                    if (run.status == 'computed' && !run.canApprove && perms.can(Perm.payrollApprove))
                      const Text('Someone else has to approve this run, because you prepared it.'),
                    if (run.skipped.isNotEmpty) ...[
                      const HrSection('Left out'),
                      for (final s in run.skipped) Text('${s['name'] ?? s['code'] ?? s['employeeId']}: no salary set.'),
                    ],
                    HrSection(
                      'Pay lines',
                      trailing: run.lines.isEmpty
                          ? null
                          : Wrap(
                              spacing: 4,
                              children: [
                                TextButton(onPressed: () => showStatutory(context, ref, run.id), child: const Text('PF, ESI, tax')),
                                if (run.status == 'approved' || run.status == 'posted')
                                  TextButton(onPressed: () => _files(context, ref, run), child: const Text('Files')),
                              ],
                            ),
                    ),
                    if (run.lines.isEmpty)
                      const Text('Work out pay to see the lines.')
                    else
                      _Lines(run: run, canEdit: canRun && run.editable),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Lines extends ConsumerWidget {
  const _Lines({required this.run, required this.canEdit});

  final PayrollRun run;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 720) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              showCheckboxColumn: false,
              columns: const [
                DataColumn(label: Text('Code')),
                DataColumn(label: Text('Name')),
                DataColumn(label: Text('Paid days'), numeric: true),
                DataColumn(label: Text('Gross'), numeric: true),
                DataColumn(label: Text('Deductions'), numeric: true),
                DataColumn(label: Text('Net'), numeric: true),
              ],
              rows: [
                for (final l in run.lines)
                  DataRow(
                    onSelectChanged: (_) => _open(context, ref, l),
                    cells: [
                      DataCell(Text(l.code)),
                      DataCell(Text(l.name + (l.warnings.isEmpty ? '' : ' !'))),
                      DataCell(Text(dayText(l.paidDays))),
                      DataCell(Text(formatMoney(l.gross))),
                      DataCell(Text(formatMoney(l.deductions))),
                      DataCell(Text(formatMoney(l.net))),
                    ],
                  ),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final l in run.lines)
              HrCard(
                onTap: () => _open(context, ref, l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${l.name} (${l.code})', style: Theme.of(context).textTheme.titleSmall),
                    HrAmountRow('Paid days', null, text: '${dayText(l.paidDays)} of ${dayText(l.workingDays)}'),
                    HrAmountRow('Gross', l.gross),
                    HrAmountRow('Deductions', l.deductions),
                    HrAmountRow('Net', l.net, bold: true),
                    for (final w in l.warnings) Text(w, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref, PayrollLine l) async {
    final repo = ref.read(hrRepositoryProvider);
    Future<void> adjust() async {
      final ok = await showHrForm(
        context,
        title: 'Add to ${l.name}',
        fields: const [
          HrField('kind', 'Kind', kind: HrFieldKind.choice, required: true, initial: 'earning',
              options: [('earning', 'Arrears or bonus (adds)'), ('deduction', 'Advance recovery (deducts)')]),
          HrField('label', 'Label', required: true),
          HrField('amount', 'Amount', kind: HrFieldKind.number, required: true),
          HrField('taxable', 'Taxable', kind: HrFieldKind.toggle, initial: true),
          HrField('reason', 'Reason', kind: HrFieldKind.multiline),
        ],
        onSubmit: (v) => repo.addAdjustment(run.id, {...v, 'employeeId': l.employeeId}),
      );
      if (ok) ref.bumpHr();
    }

    Future<void> override() async {
      final ok = await showHrForm(
        context,
        title: 'Change a figure for ${l.name}',
        fields: const [
          HrField('field', 'Figure', kind: HrFieldKind.choice, required: true, options: [
            ('lop_days', 'Loss of pay days'),
            ('pf_employee', 'PF (employee)'),
            ('esi_employee', 'ESI (employee)'),
            ('pt', 'Professional tax'),
            ('lwf_employee', 'Labour welfare fund'),
            ('tds', 'Income tax (TDS)'),
          ]),
          HrField('value', 'New value', kind: HrFieldKind.number, required: true),
          HrField('reason', 'Reason', required: true),
        ],
        onSubmit: (v) => repo.addOverride(run.id, {...v, 'employeeId': l.employeeId}),
      );
      if (ok) ref.bumpHr();
    }

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.name),
        scrollable: true,
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HrAmountRow('Paid days', null, text: '${dayText(l.paidDays)} of ${dayText(l.workingDays)} (loss of pay ${dayText(l.lopDays)})'),
              for (final e in l.earnings) HrAmountRow('${e['name'] ?? e['code']}', (e['amount'] as num?) ?? 0),
              HrAmountRow('Gross', l.gross, bold: true),
              HrAmountRow('PF', l.pfEmployee),
              HrAmountRow('ESI', l.esiEmployee),
              HrAmountRow('Professional tax', l.pt),
              HrAmountRow('Labour welfare fund', l.lwfEmployee),
              HrAmountRow('Income tax', l.tds),
              HrAmountRow('Other deductions', l.otherDeductions),
              HrAmountRow('Net', l.net, bold: true),
              for (final o in l.overrides) Text('Changed by hand: ${o['field']} = ${o['value']} (${o['reason']})'),
              for (final w in l.warnings) Text(w),
            ],
          ),
        ),
        actions: [
          if (canEdit) ...[
            TextButton(onPressed: () { Navigator.of(c).pop(); adjust(); }, child: const Text('Add arrears or recovery')),
            TextButton(onPressed: () { Navigator.of(c).pop(); override(); }, child: const Text('Change a figure')),
          ],
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Close')),
        ],
      ),
    );
  }
}

String _title(String key) {
  final s = key.replaceAllMapped(RegExp('[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}').replaceAll('_', ' ');
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

List<Widget> _statRows(Object? v, {int depth = 0}) {
  if (v is Map) {
    return [
      for (final e in v.entries)
        if (e.value is Map || e.value is List) ...[
          Padding(
            padding: EdgeInsets.only(top: depth == 0 ? Space.md : 4),
            child: Text(_title('${e.key}'), style: TextStyle(fontWeight: depth == 0 ? FontWeight.w700 : FontWeight.w600)),
          ),
          ..._statRows(e.value, depth: depth + 1),
        ] else
          HrAmountRow(_title('${e.key}'), null,
              text: e.value is num && !RegExp('members|count|^n').hasMatch('${e.key}') ? formatMoney(e.value as num) : '${e.value ?? '-'}'),
    ];
  }
  if (v is List) {
    return [
      for (final item in v) ...[
        if (item is Map) ..._statRows(item, depth: depth + 1) else Text('$item'),
        const Divider(height: 8),
      ],
    ];
  }
  return const [];
}

Future<void> showStatutory(BuildContext context, WidgetRef ref, String runId) async {
  try {
    final j = await ref.read(hrRepositoryProvider).statutory(runId);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('PF, ESI, tax totals'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _statRows(j)),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Close'))],
      ),
    );
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

Future<void> _files(BuildContext context, WidgetRef ref, PayrollRun run) async {
  const kinds = [
    ('bank', 'Bank transfer file'),
    ('ecr', 'PF return file (ECR)'),
    ('esi', 'ESI file'),
    ('pt', 'Professional tax file'),
  ];
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Files'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final k in kinds)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(k.$2),
              trailing: const Icon(Icons.download_outlined),
              onTap: () async {
                try {
                  final text = await ref.read(hrRepositoryProvider).file(run.id, k.$1);
                  await saveTextFile(_fileName(run, k.$1), text);
                  if (c.mounted) {
                    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('${k.$2} saved.')));
                  }
                } catch (e) {
                  if (c.mounted) showErrorSnackBar(c, e);
                }
              },
            ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Close'))],
    ),
  );
}

String _fileName(PayrollRun run, String kind) {
  final base = run.number.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-');
  return '$base-$kind.${kind == 'ecr' ? 'txt' : 'csv'}';
}
