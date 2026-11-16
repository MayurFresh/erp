import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_form.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';
import 'statutory_repository.dart';
import 'statutory_settings_screen.dart' show AsyncBlock, monthLabelOf;
import 'statutory_widgets.dart';

/// `/hr/shifts`: shift definitions and overtime hours by day.
class ShiftsScreen extends ConsumerStatefulWidget {
  const ShiftsScreen({super.key});

  @override
  ConsumerState<ShiftsScreen> createState() => _State();
}

class _State extends ConsumerState<ShiftsScreen> {
  String _month = currentMonth();

  Future<void> _addShift() async {
    final ok = await showHrForm(
      context,
      title: 'Shift',
      fields: const [
        HrField('name', 'Name', required: true),
        HrField('startTime', 'Starts (HH:MM)', required: true, initial: '09:00'),
        HrField('endTime', 'Ends (HH:MM)', required: true, initial: '18:00'),
        HrField('breakMinutes', 'Break in minutes', kind: HrFieldKind.number, initial: 60),
      ],
      onSubmit: (v) => ref.read(statutoryRepositoryProvider).addShift({...v, 'breakMinutes': ((v['breakMinutes'] as num?) ?? 0).toInt()}),
    );
    if (ok) ref.bumpHr();
  }

  Future<void> _addOvertime(List<Json> shifts) async {
    final emps = ref.read(employeesProvider((q: '', status: 'active'))).value ?? const [];
    final ok = await showHrForm(
      context,
      title: 'Overtime',
      intro: 'Compute the payroll run again to add the pay.',
      fields: [
        HrField('employeeId', 'Employee', kind: HrFieldKind.choice, required: true, options: [for (final e in emps) (e.id, '${e.name} (${e.code})')]),
        const HrField('day', 'Date', kind: HrFieldKind.date, required: true),
        HrField('shiftId', 'Shift', kind: HrFieldKind.choice, options: [for (final s in shifts) ('${s['id']}', '${s['name']}')]),
        const HrField('otHours', 'Overtime hours', kind: HrFieldKind.number, required: true),
      ],
      onSubmit: (v) => ref.read(statutoryRepositoryProvider).saveShiftLog({
        'employeeId': v['employeeId'],
        'entries': [
          {'day': v['day'], 'shiftId': v['shiftId'], 'otHours': v['otHours']},
        ],
      }),
    );
    if (ok) ref.bumpHr();
  }

  @override
  Widget build(BuildContext context) {
    final shifts = ref.watch(shiftsProvider);
    final names = {for (final e in ref.watch(employeesProvider((q: '', status: 'active'))).value ?? const []) e.id: e.name};
    return CGate(
      anyOf: const [Perm.payrollView, Perm.payrollRun],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Shifts and overtime'),
          Expanded(
            child: HrPad(
              children: [
                HrSection('Shifts', trailing: TextButton.icon(icon: const Icon(Icons.add), label: const Text('Add'), onPressed: _addShift)),
                InlineAsyncList<Json>(
                  value: shifts,
                  empty: 'No shifts yet.',
                  item: (s) => HrCard(
                    child: StatRow('${s['name']}', null, text: '${s['startTime']} to ${s['endTime']}, break ${s['breakMinutes']} min'),
                  ),
                ),
                HrSection(
                  'Overtime',
                  trailing: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                    onPressed: () => _addOvertime(shifts.value ?? const []),
                  ),
                ),
                StepperBar(
                  label: monthLabelOf(_month),
                  onPrev: () => setState(() => _month = shiftMonth(_month, -1)),
                  onNext: () => setState(() => _month = shiftMonth(_month, 1)),
                ),
                AsyncBlock<Json>(
                  value: ref.watch(shiftLogProvider(_month)),
                  data: (l) {
                    final rows = asJsonList(l['data']).where((r) => ((r['otHours'] as num?) ?? 0) > 0).toList();
                    if (rows.isEmpty) return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No overtime this month.'));
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final r in rows)
                          HrCard(
                            child: StatRow('${names['${r['employeeId']}'] ?? 'Employee'}, ${formatDate(r['day'])}', null, text: '${r['otHours']} hours'),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
