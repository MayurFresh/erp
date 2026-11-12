import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Opens the leave form. [forEmployee] adds an employee choice (for staff
/// who apply on someone's behalf).
Future<bool> applyLeaveDialog(BuildContext context, WidgetRef ref, {bool forEmployee = false}) async {
  final repo = ref.read(hrRepositoryProvider);
  final types = (await repo.leaveTypes()).toList();
  final emps = forEmployee ? await repo.employees(status: 'active') : <Employee>[];
  if (!context.mounted) return false;
  return showHrForm(
    context,
    title: 'Apply for leave',
    action: 'Apply',
    fields: [
      if (forEmployee)
        HrField('employeeId', 'Employee', kind: HrFieldKind.choice, required: true,
            options: [for (final e in emps) (e.id, '${e.name} (${e.code})')]),
      HrField('leaveTypeId', 'Leave type', kind: HrFieldKind.choice, required: true,
          options: [for (final t in types) (t.id, t.name)]),
      const HrField('fromDate', 'From', kind: HrFieldKind.date, required: true),
      const HrField('toDate', 'To', kind: HrFieldKind.date, required: true),
      const HrField('halfDay', 'Half day', kind: HrFieldKind.toggle),
      const HrField('reason', 'Reason', kind: HrFieldKind.multiline),
    ],
    onSubmit: (v) async {
      await repo.applyLeave(v);
      ref.bumpHr();
    },
  );
}

/// One leave application with its actions.
class LeaveCard extends ConsumerWidget {
  const LeaveCard({super.key, required this.leave, this.canDecide = false});

  final LeaveApplication leave;
  final bool canDecide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = leave;
    Future<void> act(String action) async {
      String? note;
      if (action != 'approve') {
        final ok = await showHrForm(
          context,
          title: action == 'reject' ? 'Reject leave' : 'Cancel leave',
          action: action == 'reject' ? 'Reject' : 'Cancel leave',
          fields: const [HrField('note', 'Note', kind: HrFieldKind.multiline)],
          onSubmit: (v) async {
            note = v['note'] as String?;
          },
        );
        if (!ok) return;
      }
      try {
        await ref.read(hrRepositoryProvider).decideLeave(l.id, action, note: note);
        ref.bumpHr();
      } catch (e) {
        if (context.mounted) showErrorSnackBar(context, e);
      }
    }

    final pending = l.status == 'pending';
    return HrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l.employeeName, style: Theme.of(context).textTheme.titleSmall),
              ),
              StatusChip(l.status),
            ],
          ),
          Text('${l.leaveTypeName}: ${formatDate(l.fromDate)} to ${formatDate(l.toDate)}, '
              '${dayText(l.days)} day${l.days == 1 ? '' : 's'}${l.isPaid ? '' : ' (unpaid)'}'),
          if ((l.reason ?? '').isNotEmpty) Text(l.reason!),
          if ((l.decisionNote ?? '').isNotEmpty) Text('Note: ${l.decisionNote}'),
          if (pending || l.status == 'approved')
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  if (pending && canDecide) ...[
                    FilledButton(onPressed: () => act('approve'), child: const Text('Approve')),
                    OutlinedButton(onPressed: () => act('reject'), child: const Text('Reject')),
                  ],
                  TextButton(onPressed: () => act('cancel'), child: const Text('Cancel leave')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// `/leave`
class LeaveScreen extends ConsumerStatefulWidget {
  const LeaveScreen({super.key});

  @override
  ConsumerState<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends ConsumerState<LeaveScreen> {
  String? _status = 'pending';

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final list = ref.watch(leaveListProvider((status: _status, mine: false)));
    return CGate(
      anyOf: const [Perm.payrollLeaveApprove, Perm.payrollEmployees],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Leave',
            actions: [
              if (perms.can(Perm.payrollEmployees))
                FilledButton.icon(
                  onPressed: () async {
                    if (await applyLeaveDialog(context, ref, forEmployee: true)) ref.bumpHr();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Apply for staff'),
                ),
            ],
          ),
          FilterBar(
            children: [
              SegmentedButton<String?>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'pending', label: Text('Waiting')),
                  ButtonSegment(value: 'approved', label: Text('Approved')),
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
              onRetry: () => ref.invalidate(leaveListProvider),
              data: (rows) => rows.isEmpty
                  ? const EmptyView(icon: Icons.event_available_outlined, message: 'No leave applications.')
                  : ListView(
                      padding: EdgeInsets.all(pageGutter(context)),
                      children: [
                        for (final l in rows)
                          LeaveCard(leave: l, canDecide: perms.can(Perm.payrollLeaveApprove)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
