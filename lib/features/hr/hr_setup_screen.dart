import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_form.dart';
import 'hr_models.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';

/// `/hr/setup`: salary components, leave types, holidays and pay settings.
class HrSetupScreen extends ConsumerWidget {
  const HrSetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(hrRepositoryProvider);
    Future<void> add(String title, List<HrField> fields, Future<void> Function(Map<String, Object?>) f) async {
      if (await showHrForm(context, title: title, fields: fields, onSubmit: f)) ref.bumpHr();
    }

    return CGate(
      anyOf: const [Perm.payrollEmployees],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'HR setup'),
          Expanded(
            child: HrPad(
              children: [
                HrSection(
                  'Salary components',
                  trailing: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                    onPressed: () => add('Salary component', _componentFields(null),
                        (v) => repo.saveComponent(null, {'sortOrder': 50, ...v})),
                  ),
                ),
                InlineAsyncList<SalaryComponent>(
                  value: ref.watch(componentsProvider),
                  empty: 'None yet.',
                  item: (c) => HrCard(
                    onTap: () => add('Edit ${c.name}', _componentFields(c), (v) => repo.saveComponent(c.id, v)),
                    child: HrAmountRow(
                      '${c.name} (${c.isEarning ? 'earning' : 'deduction'})',
                      null,
                      text: c.calcLabel,
                    ),
                  ),
                ),
                HrSection(
                  'Leave types',
                  trailing: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                    onPressed: () => add('Leave type', _leaveFields(null), (v) => repo.saveLeaveType(null, v)),
                  ),
                ),
                InlineAsyncList<LeaveType>(
                  value: ref.watch(leaveTypesProvider),
                  empty: 'None yet.',
                  item: (t) => HrCard(
                    onTap: () => add('Edit ${t.name}', _leaveFields(t), (v) => repo.saveLeaveType(t.id, v)),
                    child: HrAmountRow(
                      '${t.name}${t.isPaid ? '' : ' (unpaid)'}',
                      null,
                      text: t.yearlyQuota == 0 ? 'No quota' : '${dayText(t.yearlyQuota)} days a year',
                    ),
                  ),
                ),
                HrSection(
                  'Holidays',
                  trailing: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                    onPressed: () => add(
                      'Holiday',
                      const [
                        HrField('date', 'Date', kind: HrFieldKind.date, required: true),
                        HrField('name', 'Name', required: true),
                      ],
                      repo.addHoliday,
                    ),
                  ),
                ),
                InlineAsyncList<Holiday>(
                  value: ref.watch(holidaysProvider),
                  empty: 'No holidays listed for this year.',
                  item: (h) => HrCard(
                    child: Row(
                      children: [
                        Expanded(child: Text('${formatDate(h.date)}  ${h.name}')),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await repo.deleteHoliday(h.id);
                            ref.bumpHr();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const HrSection('Pay settings'),
                OutlinedButton(
                  onPressed: () => _settings(context, ref),
                  child: const Text('PF, ESI, professional tax, loss of pay'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<HrField> _componentFields(SalaryComponent? c) => [
    HrField('code', 'Code', required: true, initial: c?.code, readOnly: c != null),
    HrField('name', 'Name', required: true, initial: c?.name),
    HrField('kind', 'Kind', kind: HrFieldKind.choice, required: true, initial: c?.kind ?? 'earning',
        options: const [('earning', 'Earning'), ('deduction', 'Deduction')]),
    HrField('calc', 'How it is worked out', kind: HrFieldKind.choice, required: true, initial: c?.calc ?? 'fixed',
        options: const [('fixed', 'Fixed amount'), ('pct_basic', 'Percent of basic'), ('pct_gross', 'Percent of earnings')]),
    HrField('percent', 'Percent', kind: HrFieldKind.number, initial: c?.percent),
    HrField('taxable', 'Taxable', kind: HrFieldKind.toggle, initial: c?.taxable ?? true),
    HrField('pfWage', 'Counts for PF', kind: HrFieldKind.toggle, initial: c?.pfWage ?? false),
    HrField('esiWage', 'Counts for ESI', kind: HrFieldKind.toggle, initial: c?.esiWage ?? true),
    HrField('proRata', 'Reduced by loss of pay', kind: HrFieldKind.toggle, initial: c?.proRata ?? true),
  ];

  List<HrField> _leaveFields(LeaveType? t) => [
    HrField('code', 'Code', required: true, initial: t?.code),
    HrField('name', 'Name', required: true, initial: t?.name),
    HrField('isPaid', 'Paid', kind: HrFieldKind.toggle, initial: t?.isPaid ?? true),
    HrField('yearlyQuota', 'Days a year', kind: HrFieldKind.number, initial: t?.yearlyQuota ?? 0),
    HrField('carryForwardLimit', 'Carry forward limit', kind: HrFieldKind.number, initial: t?.carryForwardLimit ?? 0),
  ];

  Future<void> _settings(BuildContext context, WidgetRef ref) async {
    final api = ref.read(hrRepositoryProvider);
    final s = await api.settings();
    if (!context.mounted) return;
    final ok = await showHrForm(
      context,
      title: 'Pay settings',
      fields: [
        HrField('lopDivisor', 'Days used for a day of pay', kind: HrFieldKind.choice, initial: s['lopDivisor'],
            options: const [('calendar', 'Days in the month'), ('30', '30 days'), ('26', '26 days')]),
        HrField('pfEnabled', 'Provident fund', kind: HrFieldKind.toggle, initial: s['pfEnabled']),
        HrField('esiEnabled', 'ESI', kind: HrFieldKind.toggle, initial: s['esiEnabled']),
        HrField('ptEnabled', 'Professional tax', kind: HrFieldKind.toggle, initial: s['ptEnabled']),
        HrField('lwfEnabled', 'Labour welfare fund', kind: HrFieldKind.toggle, initial: s['lwfEnabled']),
        HrField('pfRate', 'PF rate', kind: HrFieldKind.choice, initial: '${s['pfRate'] ?? 12}',
            options: const [('12', '12 percent'), ('10', '10 percent')]),
        HrField('pfCode', 'PF establishment code', initial: s['pfCode']),
        HrField('esiCode', 'ESI code', initial: s['esiCode']),
        HrField('ptRegistration', 'Professional tax registration', initial: s['ptRegistration']),
      ],
      onSubmit: (v) => api.saveSettings({
        ...v,
        if (v['pfRate'] != null) 'pfRate': int.tryParse('${v['pfRate']}') ?? 12,
      }),
    );
    if (ok) ref.bumpHr();
  }
}
