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
import '../models/material_models.dart';

/// Material issued from a site store to work.
class IssuesScreen extends ConsumerStatefulWidget {
  const IssuesScreen({super.key});

  @override
  ConsumerState<IssuesScreen> createState() => _IssuesScreenState();
}

class _IssuesScreenState extends ConsumerState<IssuesScreen> {
  String? _siteId;
  IssueStatus? _status;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.consumptionView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Material issues',
            actions: [
              if (perms.can(CPerm.consumptionCreate))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/issues/new'),
                  icon: const Icon(Icons.outbox_outlined),
                  label: const Text('Issue material'),
                ),
            ],
          ),
          FilterBar(
            children: [
              SiteFilter(
                value: _siteId,
                onChanged: (value) => setState(() => _siteId = value),
              ),
              StatusChips<IssueStatus>(
                value: _status,
                options: {for (final s in IssueStatus.values) s: s.label},
                onChanged: (value) => setState(() => _status = value),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SearchField(
                  hintText: 'Search number or notes',
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            ],
          ),
          Expanded(
            child: IssueList(siteId: _siteId, status: _status, query: _query),
          ),
        ],
      ),
    );
  }
}

/// Paged material issues for the selected filters.
class IssueList extends ConsumerStatefulWidget {
  const IssueList({
    super.key,
    this.siteId,
    this.projectId,
    this.status,
    this.query = '',
  });

  final String? siteId;
  final String? projectId;
  final IssueStatus? status;
  final String query;

  @override
  ConsumerState<IssueList> createState() => _IssueListState();
}

class _IssueListState extends ConsumerState<IssueList> {
  late final PagedController<Issue> _paged = PagedController(
    (offset, limit) => ref
        .read(constructionRepositoryProvider)
        .issues(
          q: widget.query,
          locationId: widget.siteId,
          projectId: widget.projectId,
          status: widget.status,
          offset: offset,
          limit: limit,
        ),
  );

  @override
  void initState() {
    super.initState();
    _paged.refresh();
  }

  @override
  void didUpdateWidget(IssueList old) {
    super.didUpdateWidget(old);
    if (old.siteId != widget.siteId ||
        old.projectId != widget.projectId ||
        old.status != widget.status ||
        old.query != widget.query) {
      _paged.refresh();
    }
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(cRevisionProvider(CKind.issues), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());

    void open(Issue issue) => context.go('/issues/${issue.id}');
    return AdaptiveDataList<Issue>(
      controller: _paged,
      emptyMessage: 'No material issues found.',
      emptyIcon: Icons.outbox_outlined,
      onTap: open,
      columns: [
        TableColumnSpec('Number', (issue) => Text(issue.number)),
        TableColumnSpec('Date', (issue) => Text(formatDate(issue.date))),
        TableColumnSpec(
          'Site',
          (issue) => Text(issue.locationName),
          maxWidth: 200,
        ),
        TableColumnSpec('BOQ', (issue) => Text(issue.boqCode ?? '—')),
        TableColumnSpec(
          'Items',
          (issue) => Text('${issue.lines.length}'),
          numeric: true,
        ),
        TableColumnSpec(
          'Value',
          (issue) => Text(
            issue.totalValue == null ? '—' : formatMoney(issue.totalValue),
          ),
          numeric: true,
        ),
        TableColumnSpec(
          'Status',
          (issue) => issueStatusPill(context, issue.status),
        ),
      ],
      cardBuilder: (context, issue) => CListCard(
        onTap: () => open(issue),
        title: issue.number,
        subtitle: issue.locationName,
        trailing: issue.totalValue == null
            ? null
            : formatMoney(issue.totalValue),
        details: [
          '${formatDate(issue.date)} · ${issue.lines.length} items',
          if (issue.boqCode != null) 'BOQ ${issue.boqCode}',
          if (issue.notes != null && issue.notes!.isNotEmpty) issue.notes!,
        ],
        pills: issueStatusPill(context, issue.status),
      ),
    );
  }
}
