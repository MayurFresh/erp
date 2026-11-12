import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';
import 'setup_dialogs.dart';

/// `/education/setup`: academic years, classes and batches, fee heads and
/// fee plans.
class EducationSetupScreen extends ConsumerWidget {
  const EducationSetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.educationManage],
    child: DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Classes and fee plans'),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Classes and batches'),
              Tab(text: 'Fee plans'),
              Tab(text: 'Fee heads'),
              Tab(text: 'Academic years'),
            ],
          ),
          const Expanded(
            child: TabBarView(
              children: [_ClassesTab(), _PlansTab(), _HeadsTab(), _YearsTab()],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _pad(BuildContext context, List<Widget> children) => ListView(
  padding: EdgeInsets.fromLTRB(
    pageGutter(context),
    12,
    pageGutter(context),
    24,
  ),
  children: children,
);

class _YearsTab extends ConsumerWidget {
  const _YearsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> open([EduYear? y]) async {
      final ok = await showFormDialog<bool>(
        context: context,
        builder: (_) => YearDialog(year: y),
      );
      if (ok == true) ref.bumpEdu(const [EduKind.setup]);
    }

    return AsyncValueView<List<EduYear>>(
      value: ref.watch(eduYearsProvider),
      onRetry: () => ref.invalidate(eduYearsProvider),
      data: (years) => _pad(context, [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            style: bigButton,
            onPressed: () => open(),
            icon: const Icon(Icons.add),
            label: const Text('Add academic year'),
          ),
        ),
        const SizedBox(height: 12),
        if (years.isEmpty) const Text('No academic year yet.'),
        for (final y in years)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              onTap: () => open(y),
              title: Text(y.name),
              subtitle: Text(
                '${formatDate(y.startDate)} to ${formatDate(y.endDate)}',
              ),
              trailing: y.isCurrent ? const Pill('Current') : null,
            ),
          ),
      ]),
    );
  }
}

class _ClassesTab extends ConsumerWidget {
  const _ClassesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final years = ref.watch(eduYearsProvider).value ?? const <EduYear>[];
    Future<void> open({EduClass? c, bool batch = false}) async {
      final ok = await showFormDialog<bool>(
        context: context,
        builder: (_) => ClassDialog(cls: c, years: years, batch: batch),
      );
      if (ok == true) ref.bumpEdu(const [EduKind.setup]);
    }

    Future<void> promote(EduClass c) async {
      final ok = await showFormDialog<bool>(
        context: context,
        builder: (_) => PromoteDialog(from: c),
      );
      if (ok == true) ref.bumpEdu(const [EduKind.students, EduKind.setup]);
    }

    return AsyncValueView<List<EduClass>>(
      value: ref.watch(eduClassesProvider),
      onRetry: () => ref.invalidate(eduClassesProvider),
      data: (list) {
        final names = {for (final y in years) y.id: y.name};
        return _pad(context, [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: bigButton,
                onPressed: () => open(),
                icon: const Icon(Icons.add),
                label: const Text('Add class'),
              ),
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => open(batch: true),
                icon: const Icon(Icons.add),
                label: const Text('Add batch'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (list.isEmpty) const Text('No classes or batches yet.'),
          for (final c in list)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                onTap: () => open(c: c),
                title: Text(c.label),
                subtitle: Text(
                  [
                    names[c.yearId] ?? '',
                    '${c.students} students${c.capacity == null ? '' : ' of ${c.capacity}'}',
                    if (c.detail.isNotEmpty) c.detail,
                    if (!c.isActive) 'Inactive',
                  ].where((x) => x.isNotEmpty).join('  |  '),
                ),
                trailing: c.students == 0
                    ? null
                    : TextButton(
                        onPressed: () => promote(c),
                        child: const Text('Promote'),
                      ),
              ),
            ),
        ]);
      },
    );
  }
}

class _HeadsTab extends ConsumerWidget {
  const _HeadsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> open([FeeHead? h]) async {
      final ok = await showFormDialog<bool>(
        context: context,
        builder: (_) => HeadDialog(head: h),
      );
      if (ok == true) ref.bumpEdu(const [EduKind.setup]);
    }

    return AsyncValueView<List<FeeHead>>(
      value: ref.watch(eduHeadsProvider),
      onRetry: () => ref.invalidate(eduHeadsProvider),
      data: (heads) => _pad(context, [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            style: bigButton,
            onPressed: () => open(),
            icon: const Icon(Icons.add),
            label: const Text('Add fee head'),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Each fee head has its own GST rate. School tuition is exempt; coaching fees are usually taxed at 18%.',
        ),
        const SizedBox(height: 12),
        if (heads.isEmpty)
          const Text(
            'No fee heads yet. Add tuition, transport, exam and admission fees.',
          ),
        for (final h in heads)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              onTap: () => open(h),
              title: Text(h.name),
              subtitle: Text(
                h.gstRate == 0 ? 'No GST' : 'GST ${formatPercent(h.gstRate)}',
              ),
              trailing: h.isActive ? null : const Pill('Inactive'),
            ),
          ),
      ]),
    );
  }
}

class _PlansTab extends ConsumerWidget {
  const _PlansTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      AsyncValueView<List<EduClass>>(
        value: ref.watch(eduClassesProvider),
        onRetry: () => ref.invalidate(eduClassesProvider),
        data: (list) => _pad(context, [
          if (list.isEmpty) const Text('Add a class or batch first.'),
          for (final c in list) _PlanRow(cls: c),
        ]),
      );
}

class _PlanRow extends ConsumerWidget {
  const _PlanRow({required this.cls});

  final EduClass cls;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(eduPlanProvider(cls.id));
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(cls.label),
        subtitle: Text(
          plan.when(
            data: (p) => p == null
                ? 'No fee plan yet'
                : '${p.instalments.length} instalments, ${formatMoney(p.yearTotal)} a year'
                      '${p.lateKind == 'none' ? '' : ', late fee on'}',
            loading: () => 'Loading',
            error: (_, _) => 'Could not load',
          ),
        ),
        trailing: TextButton(
          onPressed: plan.isLoading
              ? null
              : () async {
                  final ok = await showFormDialog<bool>(
                    context: context,
                    builder: (_) => PlanDialog(cls: cls, plan: plan.value),
                  );
                  if (ok == true) ref.bumpEdu(const [EduKind.setup]);
                },
          child: Text(plan.value == null ? 'Set up' : 'Edit'),
        ),
      ),
    );
  }
}
