import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import 'concession_dialog.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';
import 'receipt_pdf.dart';
import 'student_form_dialog.dart';

/// `/education/students/:id`: details, fee ledger and attendance.
class StudentScreen extends ConsumerWidget {
  const StudentScreen({super.key, required this.studentId});

  final String studentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.educationView],
    child: AsyncValueView<Student>(
      value: ref.watch(eduStudentProvider(studentId)),
      onRetry: () => ref.invalidate(eduStudentProvider(studentId)),
      data: (s) => _Body(student: s),
    ),
  );
}

class _Body extends ConsumerWidget {
  const _Body({required this.student});

  final Student student;

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final saved = await showFormDialog<Student>(
      context: context,
      builder: (_) => StudentFormDialog(student: student),
    );
    if (saved != null) ref.bumpEdu(const [EduKind.students]);
  }

  Future<void> _concession(BuildContext context, WidgetRef ref) async {
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (_) => ConcessionDialog(studentId: student.id),
    );
    if (ok == true) ref.bumpEdu(const [EduKind.students, EduKind.fees]);
  }

  Future<void> _removeConcession(
    BuildContext context,
    WidgetRef ref,
    Concession c,
  ) async {
    if (!await confirm(
      context,
      title: 'Remove concession?',
      message: 'The concession on ${c.headName} stops from the next fee bill.',
      confirmLabel: 'Remove',
    )) {
      return;
    }
    try {
      await ref.read(eduRepositoryProvider).removeConcession(c.id);
      ref.bumpEdu(const [EduKind.students, EduKind.fees]);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final perms = ref.watch(permissionsProvider);
    final admit = perms.canAny(const [
      Perm.educationAdmissions,
      Perm.educationManage,
    ]);
    final fees = perms.canAny(const [Perm.educationFees, Perm.educationManage]);
    final manage = perms.can(Perm.educationManage);
    final b = student.brief;
    return FormPage(
      maxWidth: 900,
      children: [
        Row(
          children: [
            Expanded(child: Text(b.name, style: theme.textTheme.headlineSmall)),
            StatusChip(b.status, label: studentStatusName(b.status)),
          ],
        ),
        const SizedBox(height: 4),
        Text(b.line),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (fees)
              FilledButton.icon(
                onPressed: () =>
                    context.go('/education/collect?studentId=${student.id}'),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Collect fee'),
              ),
            if (admit)
              OutlinedButton.icon(
                onPressed: () => _edit(context, ref),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
            if (manage)
              OutlinedButton.icon(
                onPressed: () => _concession(context, ref),
                icon: const Icon(Icons.percent_outlined),
                label: const Text('Add concession'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Details',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Fact('Sex', sexName(b.sex)),
              Fact(
                'Date of birth',
                student.dob == null ? null : formatDate(student.dob),
              ),
              Fact(
                'Admitted on',
                student.admissionDate == null
                    ? null
                    : formatDate(student.admissionDate),
              ),
              Fact(
                'Parent',
                [
                  b.guardianName,
                  if (student.guardianRelation != null)
                    '(${student.guardianRelation})',
                ].join(' '),
              ),
              Fact('Phone', b.guardianPhone),
              Fact('Address', student.address),
              Fact('Notes', student.notes),
            ],
          ),
        ),
        if (fees) ...[const SizedBox(height: 12), _FeesCard(student: student)],
        if (student.concessions.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Concessions',
            child: Column(
              children: [
                for (final c in student.concessions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${c.headName}: ${c.kind == 'percent' ? formatPercent(c.value) : formatMoney(c.value)} off',
                    ),
                    subtitle: Text(c.reason),
                    trailing: manage
                        ? IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close),
                            onPressed: () => _removeConcession(context, ref, c),
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        _AttendanceCard(studentId: student.id),
      ],
    );
  }
}

class _FeesCard extends ConsumerWidget {
  const _FeesCard({required this.student});

  final Student student;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Fees',
      child: AsyncValueView<Ledger>(
        value: ref.watch(eduLedgerProvider(student.id)),
        onRetry: () => ref.invalidate(eduLedgerProvider(student.id)),
        data: (l) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 4,
              children: [
                Text('Billed ${formatMoney(l.billed)}'),
                Text('Paid ${formatMoney(l.paid)}'),
                Text(
                  'Due ${formatMoney(l.due)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: l.due > 0.004 ? theme.colorScheme.error : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (l.bills.isEmpty)
              const Text('No fee bills yet.')
            else
              for (final x in l.bills)
                ListTile(
                  key: ValueKey('bill-${x.number}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('${x.label}  ${x.number}'),
                  subtitle: Text('Due ${formatDate(x.dueDate)}'),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(formatMoney(x.total)),
                      Text(
                        x.status == 'cancelled'
                            ? 'Cancelled'
                            : x.due > 0.004
                            ? '${x.overdue ? 'Overdue ' : 'Due '}${formatMoney(x.due)}'
                            : 'Paid',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: x.overdue ? theme.colorScheme.error : null,
                        ),
                      ),
                    ],
                  ),
                ),
            if (l.receipts.isNotEmpty) ...[
              const Divider(),
              Text('Receipts', style: theme.textTheme.titleSmall),
              for (final r in l.receipts)
                ListTile(
                  key: ValueKey('receipt-${r.number}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('${r.number}  ${formatMoney(r.amount)}'),
                  subtitle: Text('${formatDate(r.date)}  ${modeLabel(r.mode)}'),
                  trailing: r.status == 'cancelled'
                      ? const Text('Cancelled')
                      : TextButton.icon(
                          onPressed: () => printFeeReceipt(context, ref, r.id),
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('Receipt'),
                        ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AttendanceCard extends ConsumerWidget {
  const _AttendanceCard({required this.studentId});

  final String studentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Attendance',
    child: AsyncValueView<StudentAttendance>(
      value: ref.watch(eduStudentAttendanceProvider(studentId)),
      onRetry: () => ref.invalidate(eduStudentAttendanceProvider(studentId)),
      data: (a) => a.overall.marked == 0
          ? const Text('No attendance recorded yet.')
          : Wrap(
              spacing: 24,
              runSpacing: 4,
              children: [
                Text('Overall ${a.overall.percentLabel}'),
                Text('This month ${a.thisMonth.percentLabel}'),
                Text(
                  'Absent ${a.overall.absent} days, late ${a.overall.late} days',
                ),
              ],
            ),
    ),
  );
}
