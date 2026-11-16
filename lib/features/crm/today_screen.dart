import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_widgets.dart';

/// `/crm`: what to do today, grouped as overdue, today and upcoming.
class CrmTodayScreen extends ConsumerWidget {
  const CrmTodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CrmGate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Sales', actions: [CrmOwnerFilter()]),
          const CrmTabs(current: '/crm'),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(crmTodayProvider),
              onRetry: () => ref.invalidate(crmTodayProvider),
              data: (d) => _Body(data: d),
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.data});

  final TodayData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    final d = data;
    final empty = d.overdue.isEmpty && d.today.isEmpty && d.upcoming.isEmpty;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '${d.dueToday}',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Flexible(
                    child: Text(
                      d.dueToday == 1 ? 'follow-up today' : 'follow-ups today',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: Space.sm,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (d.overdueCount > 0)
                  StatusChip('overdue', label: '${d.overdueCount} overdue'),
                if (d.newLeads > 0)
                  Text(
                    '${d.newLeads} new ${d.newLeads == 1 ? 'enquiry' : 'enquiries'} since yesterday',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            if (d.overdue.isNotEmpty) ...[
              CrmGroupHeading('Overdue', d.overdueCount, bad: true),
              CrmGroupCard(
                bad: true,
                children: [
                  for (final a in d.overdue) FollowUpTile(activity: a, overdue: true),
                ],
              ),
            ],
            if (d.today.isNotEmpty) ...[
              CrmGroupHeading('Today', d.today.length),
              CrmGroupCard(children: [for (final a in d.today) FollowUpTile(activity: a)]),
            ],
            if (d.upcoming.isNotEmpty) ...[
              CrmGroupHeading('Upcoming', d.upcoming.length),
              CrmGroupCard(
                children: [for (final a in d.upcoming) FollowUpTile(activity: a)],
              ),
            ],
            if (empty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Space.xl),
                child: Text(
                  'Nothing is due. New enquiries and follow-ups you set will show here.',
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: Space.md),
            MonthCardView(month: d.month),
          ],
        ),
      ),
    );
  }
}

/// Won against target, open deals and weighted value for the month.
class MonthCardView extends StatelessWidget {
  const MonthCardView({super.key, required this.month});

  final MonthCard month;

  String get _name {
    final t = DateTime.tryParse('${month.month}-01');
    return t == null ? month.month : DateFormat('MMMM').format(t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = month;
    final pct = m.target > 0 ? (m.won / m.target).clamp(0.0, 1.0) : 0.0;
    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: theme.textTheme.bodySmall)),
          const SizedBox(width: Space.sm),
          Flexible(child: value),
        ],
      ),
    );
    final bodyEnd = theme.textTheme.bodyMedium;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_name, style: theme.textTheme.titleMedium),
            row(
              'Won',
              Text(
                m.target > 0
                    ? '${crmMoney(m.won)} of ${crmMoney(m.target)}'
                    : '${crmMoney(m.won)}, no target set',
                textAlign: TextAlign.end,
                style: bodyEnd,
              ),
            ),
            if (m.target > 0) ...[
              const SizedBox(height: Space.sm),
              ClipRRect(
                borderRadius: Radii.smallAll,
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 8,
                  backgroundColor: context.colors.hairline,
                ),
              ),
            ],
            row(
              'Open deals',
              Text(
                '${m.openCount} · ${crmMoney(m.openValue)}',
                textAlign: TextAlign.end,
                style: bodyEnd,
              ),
            ),
            row(
              'Likely to close (weighted)',
              Text(
                crmMoney(m.weightedValue),
                textAlign: TextAlign.end,
                style: bodyEnd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
