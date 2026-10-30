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
import '../models/dpr_models.dart';

/// Daily progress reports for the whole company or one project/site.
class DprsScreen extends ConsumerStatefulWidget {
  const DprsScreen({super.key});

  @override
  ConsumerState<DprsScreen> createState() => _DprsScreenState();
}

class _DprsScreenState extends ConsumerState<DprsScreen> {
  DprStatus? _status;
  String? _locationId;
  String? _projectId;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.dprView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Daily progress reports',
            actions: [
              if (perms.can(CPerm.dprCreate))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/dprs/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New DPR'),
                ),
            ],
          ),
          FilterBar(
            children: [
              StatusChips<DprStatus>(
                value: _status,
                options: {for (final s in DprStatus.values) s: s.label},
                onChanged: (value) => setState(() => _status = value),
              ),
              SiteFilter(
                value: _locationId,
                onChanged: (value) => setState(() => _locationId = value),
              ),
              _ProjectFilter(
                value: _projectId,
                onChanged: (value) => setState(() => _projectId = value),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SearchField(
                  hintText: 'Search summary or site',
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            ],
          ),
          Expanded(
            child: DprList(
              status: _status,
              locationId: _locationId,
              projectId: _projectId,
              query: _query,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paged DPRs for the given filters; also used by the project page.
class DprList extends ConsumerStatefulWidget {
  const DprList({
    super.key,
    this.projectId,
    this.locationId,
    this.status,
    this.query = '',
  });

  final String? projectId;
  final String? locationId;
  final DprStatus? status;
  final String query;

  @override
  ConsumerState<DprList> createState() => _DprListState();
}

class _DprListState extends ConsumerState<DprList> {
  late final PagedController<Dpr> _paged = PagedController(
    (offset, limit) => ref
        .read(constructionRepositoryProvider)
        .dprs(
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
  void didUpdateWidget(DprList old) {
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
    ref.listen(cRevisionProvider(CKind.dprs), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());

    void open(Dpr dpr) => context.go('/dprs/${dpr.id}');
    return AdaptiveDataList<Dpr>(
      controller: _paged,
      emptyMessage: 'No daily progress reports found.',
      emptyIcon: Icons.today_outlined,
      onTap: open,
      columns: [
        TableColumnSpec('Date', (d) => Text(formatDate(d.date))),
        TableColumnSpec('Site', (d) => Text(d.locationName), maxWidth: 220),
        TableColumnSpec(
          'Labour',
          (d) => Text('${d.labourTotal}'),
          numeric: true,
        ),
        TableColumnSpec(
          'Equipment',
          (d) => Text('${formatQty(d.equipmentHours)} h'),
          numeric: true,
        ),
        TableColumnSpec('Status', (d) => dprStatusPill(context, d.status)),
      ],
      cardBuilder: (context, d) => CListCard(
        onTap: () => open(d),
        title: formatDate(d.date),
        subtitle: d.locationName,
        details: [
          '${d.workDone.length} work items · ${d.labourTotal} workers',
          if (d.summary != null && d.summary!.isNotEmpty) d.summary!,
        ],
        pills: dprStatusPill(context, d.status),
      ),
    );
  }
}

class _ProjectFilter extends ConsumerWidget {
  const _ProjectFilter({required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsLookupProvider);
    if (projects.hasError) return const SizedBox.shrink();
    final options = projects.value ?? const [];
    final selected = options.any((p) => p.id == value) ? value : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: DropdownButtonFormField<String?>(
        key: ValueKey('dpr-project-$selected-${options.length}'),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Project',
          isDense: true,
          prefixIcon: Icon(Icons.apartment_outlined),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All projects'),
          ),
          for (final project in options)
            DropdownMenuItem<String?>(
              value: project.id,
              child: Text(project.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}
