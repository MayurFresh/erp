import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart';
import 'legal_dialogs.dart';
import 'legal_models.dart';
import 'legal_repository.dart';
import 'legal_widgets.dart';

/// `/legal`: today's and tomorrow's hearings, deadlines and matters that have
/// no next date.
class LegalHomeScreen extends ConsumerWidget {
  const LegalHomeScreen({super.key});

  Future<void> _newMatter(BuildContext context, WidgetRef ref) async {
    final saved = await showFormDialog<Matter>(
      context: context,
      builder: (_) => MatterFormDialog(canManage: ref.legalCanManage),
    );
    if (saved == null) return;
    ref.bumpLegal();
    if (context.mounted) context.go('/legal/matters/${saved.id}');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canWork = ref.legalCanWork;
    return CGate(
      anyOf: const [Perm.legalView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Court diary',
            actions: [
              OutlinedButton(
                onPressed: () => context.go('/legal/matters'),
                child: const Text('All matters'),
              ),
              if (canWork)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => _newMatter(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('New matter'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<LegalHome>(
              value: ref.watch(legalHomeProvider),
              onRetry: () => ref.invalidate(legalHomeProvider),
              data: (home) => _HomeBody(home: home, canWork: canWork),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({required this.home, required this.canWork});

  final LegalHome home;
  final bool canWork;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final left = [
      _hearingsCard(context),
      if (home.pendingOutcome.isNotEmpty) _pendingCard(),
    ];
    final right = [_deadlinesCard(), _noDateCard(context)];
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 900;
        return FormPage(
          maxWidth: 1200,
          children: wide
              ? [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Column(children: left)),
                      const SizedBox(width: 16),
                      Expanded(child: Column(children: right)),
                    ],
                  ),
                ]
              : [...left, ...right],
        );
      },
    );
  }

  Widget _hearingsCard(BuildContext context) {
    final days = [home.today, home.tomorrow];
    return SectionCard(
      title: 'Today and tomorrow',
      icon: Icons.gavel_outlined,
      child: home.hearings.isEmpty
          ? const Text('No hearings today or tomorrow.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final d in days)
                  if (home.hearings.any((h) => h.date == d)) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: Text(
                        d == home.today
                            ? 'Today, ${formatDate(d)}'
                            : 'Tomorrow, ${formatDate(d)}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    for (final h in home.hearings.where((h) => h.date == d))
                      _HearingRow(item: h, canWork: canWork),
                  ],
              ],
            ),
    );
  }

  Widget _pendingCard() => SectionCard(
    title: 'Outcome not recorded',
    icon: Icons.pending_actions_outlined,
    child: Column(
      children: [
        for (final h in home.pendingOutcome)
          _HearingRow(item: h, canWork: canWork, showDate: true),
      ],
    ),
  );

  Widget _deadlinesCard() => SectionCard(
    title: 'Deadlines',
    icon: Icons.event_busy_outlined,
    child: home.deadlines.isEmpty
        ? const Text('Nothing due in the next two weeks.')
        : Column(
            children: [
              for (final t in home.deadlines)
                _TaskRow(task: t, canWork: canWork),
            ],
          ),
  );

  Widget _noDateCard(BuildContext context) => SectionCard(
    title: 'No next date',
    icon: Icons.warning_amber_outlined,
    child: home.withoutNextDate.isEmpty
        ? const Text('Every open matter has a next hearing.')
        : Column(
            children: [
              for (final m in home.withoutNextDate)
                InkWell(
                  key: ValueKey('nodate-${m.id}'),
                  onTap: () => context.go('/legal/matters/${m.id}'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${m.matterNo}  |  ${m.clientName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}

class _HearingRow extends ConsumerWidget {
  const _HearingRow({
    required this.item,
    required this.canWork,
    this.showDate = false,
  });

  final CauseItem item;
  final bool canWork;
  final bool showDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sub = [
      if (showDate) formatDate(item.date),
      item.court,
      item.purpose,
      item.clientName,
    ].whereType<String>().where((s) => s.isNotEmpty).join('  |  ');
    return Padding(
      key: ValueKey('hearing-${item.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => context.go('/legal/matters/${item.matterId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.matterTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          if (canWork)
            TextButton(
              onPressed: () => recordHearingOutcome(
                context,
                ref,
                hearingId: item.id,
                matterTitle: item.matterTitle,
                hearingDate: item.date,
              ),
              child: const Text('Outcome'),
            ),
        ],
      ),
    );
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task, required this.canWork});

  final LegalTask task;
  final bool canWork;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('task-${task.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => context.go('/legal/matters/${task.matterId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    [
                      task.overdue
                          ? 'Overdue since ${formatDate(task.dueDate)}'
                          : 'Due ${formatDate(task.dueDate)}',
                      task.matterTitle,
                      task.assigneeName,
                    ].whereType<String>().join('  |  '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: task.overdue ? theme.colorScheme.error : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (canWork)
            TextButton(
              onPressed: () async {
                try {
                  await ref.read(legalRepositoryProvider).patchTask(task.id, {
                    'status': 'done',
                  });
                  ref.bumpLegal();
                } catch (e) {
                  if (context.mounted) showErrorSnackBar(context, e);
                }
              },
              child: const Text('Done'),
            ),
        ],
      ),
    );
  }
}
