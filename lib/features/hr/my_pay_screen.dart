import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_models.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';
import 'leave_screen.dart';

/// `/my-pay`: own payslips, leave balance and leave applications.
class MyPayScreen extends ConsumerWidget {
  const MyPayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myEmployeeProvider);
    return CGate(
      anyOf: const [Perm.payrollSelf],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'My pay and leave',
            actions: [
              if (me.value != null)
                FilledButton.icon(
                  onPressed: () async {
                    if (await applyLeaveDialog(context, ref)) ref.bumpHr();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Apply for leave'),
                ),
            ],
          ),
          Expanded(
            child: HrPad(
              children: [
                InlineAsyncList<PayslipItem>(
                  value: ref.watch(payslipsProvider((employeeId: null, mine: true))),
                  empty: 'No payslips yet. If this looks wrong, ask HR to link your login to your employee file.',
                  item: (p) => HrCard(
                    onTap: () => context.go('/payslip/${p.id}'),
                    child: HrAmountRow(monthLabel(p.month), null, text: 'Net ${formatMoney(p.net)}'),
                  ),
                ),
                if (me.value != null) ...[
                  const HrSection('Leave balance'),
                  InlineAsyncList<LeaveBalance>(
                    value: ref.watch(leaveBalancesProvider(me.value!.id)),
                    empty: 'No leave types set up.',
                    item: (b) => HrAmountRow(
                      b.name,
                      null,
                      text: b.balance == null ? 'No limit' : '${dayText(b.balance!)} left of ${dayText(b.quota)}',
                    ),
                  ),
                ],
                const HrSection('My leave'),
                InlineAsyncList<LeaveApplication>(
                  value: ref.watch(leaveListProvider((status: null, mine: true))),
                  empty: 'No leave applied.',
                  item: (l) => LeaveCard(leave: l),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
