import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'education_repository.dart';
import 'education_widgets.dart';
import 'exam_data.dart';
import 'exam_dialogs.dart';

bool _canManage(WidgetRef ref) {
  final p = ref.watch(permissionsProvider);
  return p.can(Perm.educationExamsManage) || p.can(Perm.educationManage);
}

/// `/education/exams`: the exams of the school, plus (for managers) the
/// subjects of each class and the grading scale.
class ExamsScreen extends ConsumerWidget {
  const ExamsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = _canManage(ref);
    return CGate(
      anyOf: const [
        Perm.educationExams,
        Perm.educationExamsManage,
        Perm.educationManage,
      ],
      child: DefaultTabController(
        length: manage ? 4 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: 'Exams and report cards',
              actions: [
                if (manage)
                  FilledButton.icon(
                    onPressed: () => _add(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Add exam'),
                  ),
              ],
            ),
            if (manage)
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: 'Exams'),
                  Tab(text: 'Subjects'),
                  Tab(text: 'Grading scale'),
                  Tab(text: 'Co-scholastic areas'),
                ],
              ),
            Expanded(
              child: manage
                  ? const TabBarView(
                      children: [
                        _TermList(),
                        SubjectsPanel(),
                        _GradesTab(),
                        CoAreasPanel(),
                      ],
                    )
                  : const _TermList(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final years = await ref.read(eduYearsProvider.future);
    if (years.isEmpty) {
      if (context.mounted) {
        showErrorSnackBar(context, 'Add an academic year first.');
      }
      return;
    }
    final year = years.where((y) => y.isCurrent).firstOrNull ?? years.first;
    if (context.mounted) {
      await showTermDialog(context, ref, yearId: year.id);
    }
  }
}

class _TermList extends ConsumerWidget {
  const _TermList();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      AsyncValueView<List<ExamTerm>>(
        value: ref.watch(examTermsProvider),
        onRetry: () => ref.invalidate(examTermsProvider),
        data: (terms) => terms.isEmpty
            ? const EmptyView(
                icon: Icons.assignment_outlined,
                message: 'No exams yet. Add one such as Unit test 1.',
              )
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  pageGutter(context),
                  8,
                  pageGutter(context),
                  24,
                ),
                children: [
                  for (final t in terms)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        minTileHeight: 64,
                        onTap: () => context.go('/education/exams/${t.id}'),
                        title: Text(t.name),
                        subtitle: Text(
                          '${t.papers} papers in ${t.classCount} classes',
                        ),
                        trailing: _StatusChip(published: t.published),
                      ),
                    ),
                ],
              ),
      );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.published});
  final bool published;

  @override
  Widget build(BuildContext context) => Chip(
    visualDensity: VisualDensity.compact,
    label: Text(published ? 'Published' : 'Marks open'),
  );
}

class _GradesTab extends ConsumerWidget {
  const _GradesTab();

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) => AsyncValueView<ExamSettings>(
    value: ref.watch(examSettingsProvider),
    onRetry: () => ref.invalidate(examSettingsProvider),
    data: (s) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          s.isDefault
              ? 'Default CBSE-style scale. Pass mark is ${fmtMarks(s.passPercent)}% of each paper.'
              : 'Pass mark is ${fmtMarks(s.passPercent)}% of each paper.',
        ),
        const SizedBox(height: 8),
        for (final g in s.grades)
          ListTile(
            dense: true,
            title: Text('Grade ${g.grade}'),
            trailing: Text('from ${fmtMarks(g.minPct)}%'),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => showGradesDialog(context, ref, s),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit grading scale'),
          ),
        ),
        const Divider(height: 32),
        const Text('Co-scholastic grades'),
        for (final g in s.coGrades)
          ListTile(
            dense: true,
            title: Text('Grade ${g.grade}'),
            trailing: Text(g.label),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('edit-co-scale'),
            onPressed: () => showCoScaleDialog(context, ref, s),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit co-scholastic grades'),
          ),
        ),
      ],
    ),
  );
}

/// `/education/exams/:termId`: classes of the exam with how much is entered.
class ExamTermScreen extends ConsumerWidget {
  const ExamTermScreen({super.key, required this.termId});
  final String termId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = _canManage(ref);
    return CGate(
      anyOf: const [
        Perm.educationExams,
        Perm.educationExamsManage,
        Perm.educationManage,
      ],
      child: AsyncValueView<ExamTerm>(
        value: ref.watch(examTermProvider(termId)),
        onRetry: () => ref.invalidate(examTermProvider(termId)),
        data: (t) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: t.name,
              subtitle: t.published
                  ? 'Published. Marks are locked.'
                  : 'Marks are open.',
              actions: [
                if (manage && !t.published)
                  FilledButton(
                    onPressed: () => _publish(context, ref, t),
                    child: const Text('Publish'),
                  ),
                if (manage && t.published)
                  OutlinedButton(
                    onPressed: () => _reopen(context, ref, t),
                    child: const Text('Reopen'),
                  ),
              ],
            ),
            Expanded(
              child: t.classes.isEmpty
                  ? const EmptyView(
                      icon: Icons.groups_outlined,
                      message: 'No classes to show for this exam.',
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        0,
                        pageGutter(context),
                        24,
                      ),
                      children: [
                        for (final c in t.classes)
                          Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.label,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  Text(
                                    c.papers == 0
                                        ? 'No subjects set up'
                                        : '${c.papers} subjects, ${c.entered} of ${c.expected} marks entered',
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      if (manage && !t.published)
                                        OutlinedButton(
                                          key: ValueKey('papers-${c.id}'),
                                          onPressed: () => showPapersDialog(
                                            context,
                                            ref,
                                            termId: t.id,
                                            classId: c.id,
                                            classLabel: c.label,
                                          ),
                                          child: const Text(
                                            'Subjects and marks',
                                          ),
                                        ),
                                      if (c.papers > 0)
                                        FilledButton.tonal(
                                          key: ValueKey('enter-${c.id}'),
                                          onPressed: () => context.go(
                                            '/education/exams/${t.id}/${c.id}/marks',
                                          ),
                                          child: Text(
                                            t.published
                                                ? 'View marks'
                                                : 'Enter marks',
                                          ),
                                        ),
                                      if (c.papers > 0)
                                        OutlinedButton(
                                          key: ValueKey('results-${c.id}'),
                                          onPressed: () => context.go(
                                            '/education/exams/${t.id}/${c.id}/results',
                                          ),
                                          child: const Text('Results'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _publish(BuildContext context, WidgetRef ref, ExamTerm t) async {
    final ok = await confirm(
      context,
      title: 'Publish ${t.name}?',
      message:
          'Marks and subjects are locked once published. Every student needs '
          'a mark, or absent, in every subject.',
      confirmLabel: 'Publish',
    );
    if (!ok) return;
    try {
      await ref.read(examRepositoryProvider).publish(t.id);
      ref.read(examRevisionProvider(ExamKind.setup).notifier).bump();
      if (context.mounted) showSuccess(context, 'Published');
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _reopen(BuildContext context, WidgetRef ref, ExamTerm t) async {
    final ok = await confirm(
      context,
      title: 'Reopen ${t.name}?',
      message: 'Marks can be changed again until you publish.',
      confirmLabel: 'Reopen',
    );
    if (!ok) return;
    try {
      await ref.read(examRepositoryProvider).reopen(t.id);
      ref.read(examRevisionProvider(ExamKind.setup).notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }
}
