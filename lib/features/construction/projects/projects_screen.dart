import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/adaptive_data_list.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/paged_controller.dart';
import '../../../widgets/search_field.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/project_models.dart';

class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  String _query = '';
  ProjectStatus? _status;
  late final PagedController<Project> _paged = PagedController(
    (offset, limit) => ref
        .read(constructionRepositoryProvider)
        .projects(q: _query, status: _status, offset: offset, limit: limit),
  );

  @override
  void initState() {
    super.initState();
    _paged.refresh();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(cRevisionProvider(CKind.projects), (_, _) => _paged.refresh());
    ref.listen(cRevisionProvider(CKind.boq), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);

    void open(Project p) => context.go('/projects/${p.id}');

    return CGate(
      anyOf: const [CPerm.projectsView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Projects',
            actions: [
              if (perms.can(CPerm.projectsManage))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/projects/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New project'),
                ),
            ],
          ),
          FilterBar(
            children: [
              StatusChips<ProjectStatus>(
                value: _status,
                options: {for (final s in ProjectStatus.values) s: s.label},
                onChanged: (s) {
                  setState(() => _status = s);
                  _paged.refresh();
                },
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SearchField(
                  hintText: 'Search code or name',
                  onChanged: (q) {
                    _query = q;
                    _paged.refresh();
                  },
                ),
              ),
            ],
          ),
          Expanded(
            child: AdaptiveDataList<Project>(
              controller: _paged,
              emptyMessage: 'No projects yet.',
              emptyIcon: Icons.apartment_outlined,
              onTap: open,
              columns: [
                TableColumnSpec('Code', (p) => Text(p.code)),
                TableColumnSpec('Project', (p) => Text(p.name), maxWidth: 240),
                TableColumnSpec(
                  'Client',
                  (p) => Text(p.clientName ?? '—'),
                  maxWidth: 180,
                ),
                TableColumnSpec(
                  'Status',
                  (p) => projectStatusPill(context, p.status),
                ),
                TableColumnSpec(
                  'Progress',
                  (p) => SizedBox(width: 140, child: PctBar(p.progressPct)),
                ),
                TableColumnSpec(
                  'BOQ budget',
                  (p) => Text(formatMoney(p.budgetTotal)),
                  numeric: true,
                ),
                TableColumnSpec(
                  'Contract value',
                  (p) => Text(
                    formatMoney(p.contractValue),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  numeric: true,
                ),
              ],
              cardBuilder: (context, p) => CListCard(
                onTap: () => open(p),
                title: p.name,
                subtitle: [p.code, ?p.clientName].join(' · '),
                details: [
                  'Budget ${formatMoney(p.budgetTotal)} · '
                      'Contract ${formatMoney(p.contractValue)}',
                  if (p.sites.isNotEmpty)
                    p.sites.map((s) => s.name).join(', '),
                ],
                pills: projectStatusPill(context, p.status),
                progress: p.progressPct,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
