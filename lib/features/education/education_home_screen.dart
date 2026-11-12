import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/kpi_tile.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';
import 'student_form_dialog.dart';

/// `/education`: today's attendance by class, fees collected today, dues.
class EducationHomeScreen extends ConsumerWidget {
  const EducationHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final fees = perms.canAny(const [Perm.educationFees, Perm.educationManage]);
    final admit = perms.canAny(const [
      Perm.educationAdmissions,
      Perm.educationManage,
    ]);
    final marks = perms.canAny(const [
      Perm.educationAttendance,
      Perm.educationManage,
    ]);
    final manage = perms.can(Perm.educationManage);
    return CGate(
      anyOf: const [Perm.educationView],
      child: AsyncValueView<EduHome>(
        value: ref.watch(eduHomeProvider),
        onRetry: () => ref.invalidate(eduHomeProvider),
        data: (h) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: 'Students and fees',
              subtitle: h.year == null
                  ? null
                  : 'Academic year ${h.year!.name}   ${formatDate(h.today)}',
              actions: [
                if (fees)
                  FilledButton.icon(
                    style: bigButton,
                    onPressed: () => context.go('/education/collect'),
                    icon: const Icon(Icons.payments_outlined),
                    label: const Text('Collect fee'),
                  ),
                if (marks)
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: () => context.go('/education/attendance'),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Attendance'),
                  ),
                if (admit)
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: () async {
                      final s = await showFormDialog<Student>(
                        context: context,
                        builder: (_) => const StudentFormDialog(),
                      );
                      if (s != null && context.mounted) {
                        ref.bumpEdu(const [EduKind.students]);
                        context.go('/education/students/${s.id}');
                      }
                    },
                    icon: const Icon(Icons.person_add_alt_outlined),
                    label: const Text('Admit student'),
                  ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  pageGutter(context),
                  0,
                  pageGutter(context),
                  24,
                ),
                children: [
                  if (fees) _Kpis(home: h),
                  if (fees) const SizedBox(height: 16),
                  if (h.year == null)
                    EmptyView(
                      icon: Icons.school_outlined,
                      message: manage
                          ? 'Start by adding the academic year, then classes.'
                          : 'No academic year is set up yet. Ask the principal.',
                      action: manage
                          ? FilledButton(
                              style: bigButton,
                              onPressed: () => context.go('/education/setup'),
                              child: const Text('Set up'),
                            )
                          : null,
                    )
                  else ...[
                    Text(
                      'Attendance today',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (h.classes.isEmpty)
                      const Text('No classes yet.')
                    else
                      for (final c in _mineFirst(h.classes))
                        _ClassRow(c: c, canMark: marks),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => context.go('/education/students'),
                        icon: const Icon(Icons.groups_outlined),
                        label: const Text('All students'),
                      ),
                      if (fees)
                        TextButton.icon(
                          onPressed: () => context.go('/education/dues'),
                          icon: const Icon(Icons.pending_actions_outlined),
                          label: const Text('Dues and defaulters'),
                        ),
                      if (fees)
                        TextButton.icon(
                          onPressed: () => context.go('/education/demands'),
                          icon: const Icon(Icons.request_quote_outlined),
                          label: const Text('Generate fee bills'),
                        ),
                      if (manage)
                        TextButton.icon(
                          onPressed: () => context.go('/education/setup'),
                          icon: const Icon(Icons.tune_outlined),
                          label: const Text('Classes and fee plans'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<EduClass> _mineFirst(List<EduClass> list) => [
    ...list.where((c) => c.mine),
    ...list.where((c) => !c.mine),
  ];
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.home});

  final EduHome home;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final cols = box.maxWidth >= 720 ? 3 : 2;
      final w = (box.maxWidth - (cols - 1) * 12) / cols;
      Widget tile(KpiTile t) => SizedBox(width: w, child: t);
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          tile(
            KpiTile(
              label: 'Collected today',
              value: formatMoney(home.feesCollectedToday ?? 0),
              icon: Icons.payments_outlined,
            ),
          ),
          tile(
            KpiTile(
              label: 'Fees due',
              value: formatMoney(home.duesTotal),
              icon: Icons.pending_actions_outlined,
            ),
          ),
          tile(
            KpiTile(
              label: 'Defaulters',
              value: '${home.defaultersCount}',
              hint: 'Students with overdue fees',
              icon: Icons.warning_amber_outlined,
              tone: home.defaultersCount > 0
                  ? StatusTone.warning
                  : StatusTone.neutral,
              onTap: () => context.go('/education/dues'),
            ),
          ),
        ],
      );
    },
  );
}

class _ClassRow extends StatelessWidget {
  const _ClassRow({required this.c, required this.canMark});

  final EduClass c;
  final bool canMark;

  @override
  Widget build(BuildContext context) {
    final status = c.attendanceMarked
        ? StatusChip(
            'marked',
            label: '${c.present + c.late} in, ${c.absent} absent',
            tone: StatusTone.success,
          )
        : const StatusChip(
            'pending',
            label: 'Not marked',
            tone: StatusTone.warning,
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          onTap: canMark
              ? () => context.go('/education/attendance/${c.id}')
              : null,
          title: Text(c.label, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              '${c.students} students',
              if (c.mine) 'Your class',
              if (c.detail.isNotEmpty) c.detail,
            ].join('  |  '),
          ),
          trailing: status,
        ),
      ),
    );
  }
}
