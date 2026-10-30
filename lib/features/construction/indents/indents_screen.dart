import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../core/providers.dart';
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

class IndentsScreen extends ConsumerStatefulWidget {
  const IndentsScreen({super.key, this.initialStatus});

  final String? initialStatus;

  @override
  ConsumerState<IndentsScreen> createState() => _IndentsScreenState();
}

class _IndentsScreenState extends ConsumerState<IndentsScreen> {
  late IndentStatus? _status = widget.initialStatus == null
      ? null
      : IndentStatus.parse(widget.initialStatus);
  String? _locationId;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.indentsView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Material indents',
            actions: [
              if (perms.can(CPerm.indentsCreate))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/indents/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New indent'),
                ),
            ],
          ),
          FilterBar(
            children: [
              StatusChips<IndentStatus>(
                value: _status,
                options: {for (final s in IndentStatus.values) s: s.label},
                onChanged: (s) => setState(() => _status = s),
              ),
              SiteFilter(
                value: _locationId,
                includeStores: true,
                onChanged: (id) => setState(() => _locationId = id),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SearchField(
                  hintText: 'Search number',
                  onChanged: (q) => setState(() => _query = q),
                ),
              ),
            ],
          ),
          Expanded(
            child: IndentList(
              status: _status,
              locationId: _locationId,
              query: _query,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paged indents for the given filters (also used on the project page).
class IndentList extends ConsumerStatefulWidget {
  const IndentList({
    super.key,
    this.projectId,
    this.locationId,
    this.status,
    this.query = '',
  });

  final String? projectId;
  final String? locationId;
  final IndentStatus? status;
  final String query;

  @override
  ConsumerState<IndentList> createState() => _IndentListState();
}

class _IndentListState extends ConsumerState<IndentList> {
  late final PagedController<Indent> _paged = PagedController(
    (offset, limit) => ref
        .read(constructionRepositoryProvider)
        .indents(
          q: widget.query,
          status: widget.status,
          locationId: widget.locationId,
          projectId: widget.projectId,
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
  void didUpdateWidget(IndentList old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId ||
        old.locationId != widget.locationId ||
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
    ref.listen(cRevisionProvider(CKind.indents), (_, _) => _paged.refresh());
    ref.listen(
      revisionProvider(DataKind.transfers),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());

    void open(Indent i) => context.go('/indents/${i.id}');
    String fulfilment(Indent i) =>
        i.status == IndentStatus.approved || i.status == IndentStatus.closed
        ? '${formatQty(roundPct(i.fulfilmentPct))}% fulfilled'
        : '';

    return AdaptiveDataList<Indent>(
      controller: _paged,
      emptyMessage: 'No indents found.',
      emptyIcon: Icons.playlist_add_check_outlined,
      onTap: open,
      columns: [
        TableColumnSpec('Number', (i) => Text(i.number)),
        TableColumnSpec('Date', (i) => Text(formatDate(i.createdAt))),
        TableColumnSpec('Site', (i) => Text(i.locationName), maxWidth: 200),
        TableColumnSpec('Required by', (i) => Text(formatDate(i.requiredBy))),
        TableColumnSpec(
          'Items',
          (i) => Text('${i.lines.length}'),
          numeric: true,
        ),
        TableColumnSpec('Status', (i) => indentStatusPill(context, i.status)),
        TableColumnSpec(
          'Fulfilled',
          (i) => SizedBox(
            width: 120,
            child:
                i.status == IndentStatus.approved ||
                    i.status == IndentStatus.closed
                ? PctBar(i.fulfilmentPct)
                : const Text('—'),
          ),
        ),
      ],
      cardBuilder: (context, i) => CListCard(
        onTap: () => open(i),
        title: i.number,
        subtitle: i.locationName,
        details: [
          [
            '${i.lines.length} items',
            if (i.requiredBy != null) 'needed ${formatDate(i.requiredBy)}',
            if (fulfilment(i).isNotEmpty) fulfilment(i),
          ].join(' · '),
        ],
        pills: indentStatusPill(context, i.status),
      ),
    );
  }
}
