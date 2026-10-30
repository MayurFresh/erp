import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../core/permissions.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../dprs/dprs_screen.dart';
import '../indents/indents_screen.dart';
import '../models/project_models.dart';
import 'boq_tab.dart';
import 'costs_tab.dart';

/// Tabs of the project page; `?tab=` selects one by [name].
enum ProjectTab { overview, boq, costs, dprs, indents }

class ProjectDetailScreen extends ConsumerWidget {
  const ProjectDetailScreen({
    super.key,
    required this.projectId,
    this.initialTab,
  });

  final String projectId;
  final String? initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [CPerm.projectsView],
    child: AsyncValueView(
      value: ref.watch(projectProvider(projectId)),
      onRetry: () => ref.invalidate(projectProvider(projectId)),
      data: (p) => _ProjectTabs(project: p, initialTab: initialTab),
    ),
  );
}

class _ProjectTabs extends ConsumerWidget {
  const _ProjectTabs({required this.project, this.initialTab});

  final Project project;
  final String? initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final p = project;
    final tabs = [
      ProjectTab.overview,
      ProjectTab.boq,
      ProjectTab.costs,
      if (perms.can(CPerm.dprView)) ProjectTab.dprs,
      if (perms.can(CPerm.indentsView)) ProjectTab.indents,
    ];
    final initial = tabs.indexWhere((t) => t.name == initialTab);
    final phone = isPhone(context);
    final theme = Theme.of(context);

    return DefaultTabController(
      length: tabs.length,
      initialIndex: initial < 0 ? 0 : initial,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              phone ? 12 : 16,
              12,
              phone ? 12 : 16,
              4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(p.name, style: theme.textTheme.headlineSmall),
                        projectStatusPill(context, p.status),
                      ],
                    ),
                    if (perms.can(CPerm.projectsManage))
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () => context.go('/projects/${p.id}/edit'),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [p.code, ?p.clientName].join(' · '),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: PctBar(p.progressPct, height: 10),
                ),
              ],
            ),
          ),
          TabBar(
            isScrollable: phone,
            tabAlignment: phone ? TabAlignment.start : null,
            tabs: [
              for (final tab in tabs)
                Tab(
                  height: 48,
                  text: switch (tab) {
                    ProjectTab.overview => 'Overview',
                    ProjectTab.boq => 'BOQ',
                    ProjectTab.costs => 'Costs',
                    ProjectTab.dprs => 'DPRs',
                    ProjectTab.indents => 'Indents',
                  },
                ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final tab in tabs)
                  switch (tab) {
                    ProjectTab.overview => _Overview(project: p),
                    ProjectTab.boq => BoqTab(projectId: p.id),
                    ProjectTab.costs => CostsTab(projectId: p.id),
                    ProjectTab.dprs => DprList(projectId: p.id),
                    ProjectTab.indents => IndentList(projectId: p.id),
                  },
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Overview extends ConsumerWidget {
  const _Overview({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final p = project;
    final single = p.sites.length == 1 ? p.sites.single.id : null;
    String withSite(String path, [String key = 'locationId']) =>
        single == null ? path : '$path?$key=$single';

    final actions = [
      if (perms.can(CPerm.dprCreate))
        (Icons.today_outlined, 'New DPR', withSite('/dprs/new')),
      if (perms.can(CPerm.attendanceMark))
        (
          Icons.how_to_reg_outlined,
          'Attendance',
          withSite('/attendance', 'siteId'),
        ),
      if (perms.can(CPerm.indentsCreate))
        (Icons.playlist_add_outlined, 'New indent', withSite('/indents/new')),
      if (perms.can(CPerm.consumptionCreate))
        (Icons.outbox_outlined, 'Issue material', withSite('/issues/new')),
    ];

    return CPage(
      children: [
        if (actions.isNotEmpty)
          SectionCard(
            title: 'Quick actions',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (icon, label, path) in actions)
                  FilledButton.tonalIcon(
                    style: bigButton,
                    onPressed: () => context.go(path),
                    icon: Icon(icon),
                    label: Text(label),
                  ),
              ],
            ),
          ),
        SectionCard(
          title: 'Details',
          child: FactsWrap(
            facts: [
              ('Code', p.code),
              ('Client', p.clientName ?? ''),
              ('Project manager', p.managerName ?? ''),
              ('Status', p.status.label),
              ('Start', formatDate(p.startDate)),
              ('End', formatDate(p.endDate)),
              ('Contract value', formatMoney(p.contractValue)),
              ('BOQ budget', formatMoney(p.budgetTotal)),
              if (p.address != null) ('Address', p.address!),
            ],
          ),
        ),
        SectionCard(
          title: 'Progress',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PctBar(p.progressPct, height: 14),
              const SizedBox(height: 8),
              Text(
                'Weighted by BOQ amount, from approved daily progress '
                'reports.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Sites',
          child: p.sites.isEmpty
              ? Text(
                  perms.can(CPerm.projectsManage)
                      ? 'No sites linked yet. Edit the project to add sites.'
                      : 'No sites linked yet.',
                )
              : Column(
                  children: [
                    for (final site in p.sites)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        minTileHeight: 56,
                        leading: const Icon(Icons.location_on_outlined),
                        title: Text(site.name, overflow: TextOverflow.ellipsis),
                        trailing: perms.can(Perm.stockView)
                            ? TextButton(
                                style: TextButton.styleFrom(
                                  minimumSize: kTapTarget,
                                ),
                                onPressed: () => context.go(
                                  '/stock/moves?locationId=${site.id}'
                                  '&title=${Uri.encodeComponent(site.name)}',
                                ),
                                child: const Text('Stock'),
                              )
                            : null,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
