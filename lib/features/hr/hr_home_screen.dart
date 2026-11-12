import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/kpi_tile.dart';
import '../../widgets/layout.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../memberships/inline_async.dart';
import 'hr_models.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';

/// `/hr`: head count, this month's payroll, leave waiting and birthdays.
class HrHomeScreen extends ConsumerWidget {
  const HrHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final summary = ref.watch(hrSummaryProvider);
    return CGate(
      anyOf: const [Perm.payrollEmployees, Perm.payrollView, Perm.payrollLeaveApprove],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'HR',
            actions: [
              if (perms.can(Perm.payrollEmployees))
                OutlinedButton.icon(
                  onPressed: () => context.go('/hr/employees'),
                  icon: const Icon(Icons.badge_outlined),
                  label: const Text('Employees'),
                ),
              if (perms.can(Perm.payrollView))
                FilledButton.icon(
                  onPressed: () => context.go('/payroll'),
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Payroll'),
                ),
            ],
          ),
          Expanded(
            child: HrPad(
              children: [
                InlineAsync<HrSummary>(
                  value: summary,
                  onRetry: () => ref.invalidate(hrSummaryProvider),
                  data: (s) => _Body(summary: s, perms: perms),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.summary, required this.perms});

  final HrSummary summary;
  final PermissionSet perms;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final run = s.runs.isEmpty ? null : s.runs.first;
    final runText = run == null
        ? 'Not started'
        : '${run.status[0].toUpperCase()}${run.status.substring(1)}';
    final tiles = [
      KpiTile(
        label: 'Employees',
        value: '${s.headCount}',
        hint: '${s.joiners} joined, ${s.leavers} left this month',
        onTap: perms.can(Perm.payrollEmployees)
            ? () => context.go('/hr/employees')
            : null,
      ),
      if (perms.can(Perm.payrollView))
        KpiTile(
          label: 'Payroll ${monthLabel(s.month)}',
          value: runText,
          hint: run == null ? 'No run yet' : '${run.count} employees, net ${formatMoney(run.net)}',
          tone: run == null ? StatusTone.warning : StatusTone.neutral,
          onTap: () => context.go(run == null ? '/payroll' : '/payroll/${run.id}'),
        ),
      KpiTile(
        label: 'Leave to approve',
        value: '${s.pendingLeave}',
        hint: '${s.onLeaveToday} on leave today',
        tone: s.pendingLeave > 0 ? StatusTone.warning : StatusTone.neutral,
        onTap: perms.can(Perm.payrollLeaveApprove) ? () => context.go('/leave') : null,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 720 ? tiles.length : (c.maxWidth >= 420 ? 2 : 1);
            final w = (c.maxWidth - 12 * (cols - 1)) / cols;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final t in tiles) SizedBox(width: w, child: t)],
            );
          },
        ),
        const HrSection('Birthdays in the next 14 days'),
        if (s.birthdays.isEmpty)
          const Text('None.')
        else
          for (final b in s.birthdays)
            HrAmountRow('${b['name']}', null, text: formatDate(b['date'])),
        const HrSection('Departments'),
        if (s.departments.isEmpty)
          const Text('No employees yet.')
        else
          for (final d in s.departments)
            HrAmountRow('${d['name']}', null, text: '${d['count']}'),
        const HrSection('Set up'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (perms.can(Perm.payrollEmployees))
              OutlinedButton(
                onPressed: () => context.go('/hr/setup'),
                child: const Text('Salary components, leave types, holidays'),
              ),
            if (perms.can(Perm.payrollLeaveApprove))
              OutlinedButton(
                onPressed: () => context.go('/leave'),
                child: const Text('Leave applications'),
              ),
          ],
        ),
      ],
    );
  }
}
