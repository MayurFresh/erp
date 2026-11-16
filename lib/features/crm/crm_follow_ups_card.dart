import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import 'crm_repository.dart';
import 'crm_widgets.dart';

/// Dashboard card: follow-ups due today and overdue, linking to `/crm`.
/// Shows nothing without `crm.view` or while the data is loading or failed.
class CrmFollowUpsCard extends ConsumerWidget {
  const CrmFollowUpsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!crmCan(ref, Perm.crmView)) return const SizedBox.shrink();
    final today = ref.watch(crmTodayProvider).value;
    if (today == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Follow-ups',
      icon: Icons.event_available_outlined,
      trailing: TextButton(
        onPressed: () => context.go('/crm'),
        child: const Text('Open'),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Count('${today.dueToday}', 'due today', theme),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: _Count(
              '${today.overdueCount}',
              'overdue',
              theme,
              bad: today.overdueCount > 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.value, this.label, this.theme, {this.bad = false});

  final String value, label;
  final ThemeData theme;
  final bool bad;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: theme.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: bad ? theme.colorScheme.error : null,
        ),
      ),
      Text(label, style: theme.textTheme.bodySmall),
    ],
  );
}
