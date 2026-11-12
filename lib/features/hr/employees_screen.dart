import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
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

List<HrField> employeeFields(Employee? e) => [
  HrField('name', 'Name', required: true, initial: e?.name),
  HrField('joiningDate', 'Joining date', kind: HrFieldKind.date, required: true, initial: e?.joiningDate),
  HrField('department', 'Department', initial: e?.department),
  HrField('designation', 'Designation', initial: e?.designation),
  HrField('phone', 'Phone', initial: e?.field('phone')),
  HrField('email', 'Email', initial: e?.field('email')),
  HrField('dob', 'Date of birth', kind: HrFieldKind.date, initial: e?.field('dob')),
  HrField('sex', 'Sex', kind: HrFieldKind.choice, initial: e?.field('sex'),
      options: const [('M', 'Male'), ('F', 'Female'), ('O', 'Other')]),
  HrField('pan', 'PAN', initial: e?.field('pan')),
  HrField('aadhaar', 'Aadhaar (12 digits)'),
  HrField('uan', 'UAN', initial: e?.field('uan')),
  HrField('esiNumber', 'ESI number', initial: e?.field('esiNumber')),
  HrField('bankName', 'Bank', initial: e?.field('bankName')),
  HrField('bankAccount', 'Bank account'),
  HrField('bankIfsc', 'IFSC', initial: e?.field('bankIfsc')),
  HrField('pfApplicable', 'PF applies', kind: HrFieldKind.toggle, initial: e == null ? true : e.raw['pfApplicable'] == true),
  HrField('esiApplicable', 'ESI applies', kind: HrFieldKind.toggle, initial: e == null ? true : e.raw['esiApplicable'] == true),
  if (e != null)
    HrField('status', 'Status', kind: HrFieldKind.choice, initial: e.status,
        options: const [('active', 'Active'), ('on_notice', 'On notice'), ('left', 'Left')]),
  if (e != null)
    HrField('leavingDate', 'Leaving date', kind: HrFieldKind.date, initial: e.leavingDate),
];

/// `/hr/employees`
class EmployeesScreen extends ConsumerStatefulWidget {
  const EmployeesScreen({super.key});

  @override
  ConsumerState<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends ConsumerState<EmployeesScreen> {
  String _q = '';
  String? _status = 'active';

  Future<void> _add() async {
    final ok = await showHrForm(
      context,
      title: 'Add employee',
      fields: employeeFields(null),
      onSubmit: (v) => ref.read(hrRepositoryProvider).saveEmployee(null, v),
    );
    if (ok) ref.bumpHr();
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(employeesProvider((q: _q, status: _status)));
    final canPay = ref.watch(permissionsProvider).can(Perm.payrollView);
    final theme = Theme.of(context);
    return CGate(
      anyOf: const [Perm.payrollEmployees, Perm.payrollView, Perm.payrollRun],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Employees',
            actions: [
              if (ref.watch(permissionsProvider).can(Perm.payrollEmployees))
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add employee'),
                ),
            ],
          ),
          FilterBar(
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search name or code',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onSubmitted: (v) => setState(() => _q = v.trim()),
                ),
              ),
              SegmentedButton<String?>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'active', label: Text('Active')),
                  ButtonSegment(value: null, label: Text('All')),
                ],
                selected: {_status},
                onSelectionChanged: (s) => setState(() => _status = s.first),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView(
              value: list,
              onRetry: () => ref.invalidate(employeesProvider),
              data: (rows) {
                if (rows.isEmpty) {
                  return const EmptyView(
                    icon: Icons.badge_outlined,
                    message: 'No employees yet. Add the first one.',
                  );
                }
                return ListView.separated(
                  padding: EdgeInsets.all(pageGutter(context)),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
                  itemBuilder: (_, i) {
                    final e = rows[i];
                    return HrCard(
                      onTap: () => context.go('/hr/employees/${e.id}'),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${e.name} (${e.code})',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall),
                                if (e.subtitle.isNotEmpty) Text(e.subtitle),
                              ],
                            ),
                          ),
                          if (canPay && e.monthlyGross != null)
                            Padding(
                              padding: const EdgeInsets.only(right: Space.sm),
                              child: Text(formatMoney(e.monthlyGross)),
                            ),
                          StatusChip(e.status),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// `/hr/employees/:id`
class EmployeeFileScreen extends ConsumerWidget {
  const EmployeeFileScreen({super.key, required this.employeeId});

  final String employeeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final emp = ref.watch(employeeProvider(employeeId));
    return CGate(
      anyOf: const [Perm.payrollEmployees, Perm.payrollView, Perm.payrollRun, Perm.payrollSelf],
      child: AsyncValueView(
        value: emp,
        onRetry: () => ref.invalidate(employeeProvider(employeeId)),
        data: (e) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: e.name,
              actions: [
                if (perms.can(Perm.payrollEmployees))
                  OutlinedButton.icon(
                    onPressed: () async {
                      final ok = await showHrForm(
                        context,
                        title: 'Edit ${e.name}',
                        fields: employeeFields(e),
                        onSubmit: (v) => ref.read(hrRepositoryProvider).saveEmployee(e.id, {
                          ...v,
                          'expectedUpdatedAt': e.field('updatedAt'),
                        }),
                      );
                      if (ok) ref.bumpHr();
                    },
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
              ],
            ),
            Expanded(
              child: HrPad(
                children: [
                  _Profile(e: e),
                  if (perms.can(Perm.payrollView) || perms.can(Perm.payrollEmployees))
                    _SalarySection(e: e, canEdit: perms.can(Perm.payrollEmployees)),
                  _Balances(employeeId: e.id, canAdjust: perms.can(Perm.payrollEmployees)),
                  _Slips(employeeId: e.id),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile({required this.e});

  final Employee e;

  @override
  Widget build(BuildContext context) {
    String v(String? s) => (s == null || s.isEmpty) ? '-' : s;
    final rows = <(String, String)>[
      ('Code', e.code),
      ('Status', e.status),
      ('Designation', v([e.designation, e.department].whereType<String>().join(', '))),
      ('Joined', formatDate(e.joiningDate)),
      ('Phone', v(e.field('phone'))),
      ('Email', v(e.field('email'))),
      ('PAN', v(e.field('pan'))),
      ('Aadhaar', v(e.field('aadhaarMasked'))),
      ('UAN', v(e.field('uan'))),
      ('ESI number', v(e.field('esiNumber'))),
      ('Bank', v([e.field('bankName'), e.field('bankAccount')].whereType<String>().join(' '))),
      ('IFSC', v(e.field('bankIfsc'))),
    ];
    return HrCard(
      child: Column(
        children: [for (final r in rows) HrAmountRow(r.$1, null, text: r.$2)],
      ),
    );
  }
}

class _SalarySection extends ConsumerWidget {
  const _SalarySection({required this.e, required this.canEdit});

  final Employee e;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hist = ref.watch(salaryHistoryProvider(e.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HrSection(
          'Salary',
          trailing: canEdit
              ? TextButton.icon(
                  onPressed: () => _revise(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('New revision'),
                )
              : null,
        ),
        InlineAsyncList<SalaryRevision>(
          value: hist,
          empty: 'No salary set. Add a revision before running payroll.',
          item: (r) => HrCard(
            child: Column(
              children: [
                HrAmountRow('From ${formatDate(r.effectiveFrom)}', null,
                    text: '${formatMoney(r.monthlyGross)} a month', bold: true),
                HrAmountRow('Yearly cost to company', r.ctcAnnual),
                for (final l in r.lines)
                  HrAmountRow('${l['name'] ?? l['code'] ?? ''}', (l['amount'] as num?) ?? 0),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _revise(BuildContext context, WidgetRef ref) async {
    final comps = await ref.read(hrRepositoryProvider).components();
    if (!context.mounted) return;
    final earn = comps.where((c) => c.kind == 'earning' && c.calc == 'fixed' && c.isActive).toList();
    final ok = await showHrForm(
      context,
      title: 'Salary revision',
      intro: 'Give the yearly cost to company to split it by the usual shares, '
          'or fill the monthly amounts below.',
      fields: [
        const HrField('effectiveFrom', 'Effective from', kind: HrFieldKind.date, required: true),
        const HrField('ctcAnnual', 'Yearly cost to company', kind: HrFieldKind.number),
        for (final c in earn) HrField('c_${c.id}', '${c.name} a month', kind: HrFieldKind.number),
        const HrField('note', 'Note', kind: HrFieldKind.multiline),
      ],
      onSubmit: (v) {
        final lines = [
          for (final c in earn)
            if (v['c_${c.id}'] != null) {'componentId': c.id, 'amount': v['c_${c.id}']},
        ];
        if (lines.isEmpty && v['ctcAnnual'] == null) {
          throw 'Give the yearly cost or at least one monthly amount.';
        }
        return ref.read(hrRepositoryProvider).addSalary(e.id, {
          'effectiveFrom': v['effectiveFrom'],
          'ctcAnnual': ?v['ctcAnnual'],
          if (lines.isNotEmpty) 'lines': lines,
          'note': ?v['note'],
        });
      },
    );
    if (ok) ref.bumpHr();
  }
}

class _Balances extends ConsumerWidget {
  const _Balances({required this.employeeId, this.canAdjust = false});

  final String employeeId;
  final bool canAdjust;

  Future<void> _adjust(BuildContext context, WidgetRef ref, List<LeaveBalance> balances) async {
    final fy = DateTime.now().month >= 4 ? DateTime.now().year : DateTime.now().year - 1;
    final ok = await showHrForm(
      context,
      title: 'Adjust leave balance',
      action: 'Save',
      intro: 'Use a plus number to add days and a minus number to deduct. The change is kept with your name and reason.',
      fields: [
        HrField('leaveTypeId', 'Leave type', kind: HrFieldKind.choice, required: true,
            options: [for (final b in balances) (b.leaveTypeId, b.name)]),
        const HrField('days', 'Days (+ or -)', kind: HrFieldKind.number, required: true),
        const HrField('reason', 'Reason', kind: HrFieldKind.multiline, required: true),
      ],
      onSubmit: (v) async {
        await ref.read(hrRepositoryProvider).adjustLeave(employeeId, {
          'leaveTypeId': v['leaveTypeId'],
          'fy': fy,
          'days': v['days'],
          'reason': v['reason'],
        });
      },
    );
    if (ok) ref.bumpHr();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      HrSection(
        'Leave balance this year',
        trailing: canAdjust
            ? TextButton(
                onPressed: () async {
                  final list = await ref.read(leaveBalancesProvider(employeeId).future);
                  if (context.mounted) await _adjust(context, ref, list);
                },
                child: const Text('Adjust'),
              )
            : null,
      ),
      InlineAsyncList<LeaveBalance>(
        value: ref.watch(leaveBalancesProvider(employeeId)),
        empty: 'No leave types set up.',
        item: (b) => HrAmountRow(
          b.name,
          null,
          text: b.balance == null ? 'No limit' : '${dayText(b.balance!)} left of ${dayText(b.quota)}',
        ),
      ),
    ],
  );
}

class _Slips extends ConsumerWidget {
  const _Slips({required this.employeeId});

  final String employeeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(permissionsProvider).canAny([Perm.payrollView, Perm.payrollSelf])) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HrSection('Payslips'),
        InlineAsyncList<PayslipItem>(
          value: ref.watch(payslipsProvider((employeeId: employeeId, mine: false))),
          empty: 'No payslips yet.',
          item: (p) => HrCard(
            onTap: () => context.go('/payslip/${p.id}'),
            child: HrAmountRow(monthLabel(p.month), null, text: 'Net ${formatMoney(p.net)}'),
          ),
        ),
      ],
    );
  }
}
