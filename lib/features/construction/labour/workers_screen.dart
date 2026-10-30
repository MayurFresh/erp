import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../core/permissions.dart';
import '../../../widgets/adaptive_data_list.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/paged_controller.dart';
import '../../../widgets/search_field.dart';
import '../../auth/session.dart';
import '../../parties/party_model.dart';
import '../../parties/party_picker.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/common_models.dart';
import '../models/labour_models.dart';

/// Worker register for all sites.
class WorkersScreen extends ConsumerStatefulWidget {
  const WorkersScreen({super.key});

  @override
  ConsumerState<WorkersScreen> createState() => _WorkersScreenState();
}

class _WorkersScreenState extends ConsumerState<WorkersScreen> {
  String? _siteId;
  Trade? _trade;

  /// Labour contractor filter (`contractorId`), chosen from vendors.
  NamedRef? _contractor;
  bool _activeOnly = true;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.labourView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Worker register',
            actions: [
              if (perms.can(CPerm.labourManage))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/workers/new'),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Add worker'),
                ),
            ],
          ),
          FilterBar(
            children: [
              SiteFilter(
                value: _siteId,
                onChanged: (value) => setState(() => _siteId = value),
              ),
              if (perms.can(Perm.partiesView))
                InputChip(
                  avatar: const Icon(Icons.engineering_outlined, size: 18),
                  label: Text(_contractor?.name ?? 'Any contractor'),
                  selected: _contractor != null,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onPressed: () async {
                    final party = await pickParty(
                      context,
                      ref,
                      type: PartyType.vendor,
                    );
                    if (party != null) {
                      setState(
                        () => _contractor = NamedRef(
                          id: party.id,
                          name: party.name,
                        ),
                      );
                    }
                  },
                  onDeleted: _contractor == null
                      ? null
                      : () => setState(() => _contractor = null),
                ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: DropdownButtonFormField<Trade?>(
                  isExpanded: true,
                  key: ValueKey('worker-trade-${_trade?.api}'),
                  initialValue: _trade,
                  decoration: const InputDecoration(
                    labelText: 'Trade',
                    isDense: true,
                    prefixIcon: Icon(Icons.handyman_outlined),
                  ),
                  items: [
                    const DropdownMenuItem<Trade?>(
                      value: null,
                      child: Text('All trades'),
                    ),
                    for (final trade in Trade.values)
                      DropdownMenuItem<Trade?>(
                        value: trade,
                        child: Text(trade.label),
                      ),
                  ],
                  onChanged: (value) => setState(() => _trade = value),
                ),
              ),
              FilterChip(
                label: const Text('Active only'),
                selected: _activeOnly,
                onSelected: (value) => setState(() => _activeOnly = value),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SearchField(
                  hintText: 'Search name or phone',
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            ],
          ),
          Expanded(
            child: WorkerList(
              siteId: _siteId,
              contractorId: _contractor?.id,
              trade: _trade,
              activeOnly: _activeOnly,
              query: _query,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paged worker list for the selected register filters.
class WorkerList extends ConsumerStatefulWidget {
  const WorkerList({
    super.key,
    this.siteId,
    this.contractorId,
    this.trade,
    this.activeOnly = true,
    this.query = '',
  });

  final String? siteId;
  final String? contractorId;
  final Trade? trade;
  final bool activeOnly;
  final String query;

  @override
  ConsumerState<WorkerList> createState() => _WorkerListState();
}

class _WorkerListState extends ConsumerState<WorkerList> {
  late final PagedController<Worker> _paged = PagedController(
    (offset, limit) => ref
        .read(constructionRepositoryProvider)
        .workers(
          q: widget.query,
          siteId: widget.siteId,
          contractorId: widget.contractorId,
          trade: widget.trade,
          activeOnly: widget.activeOnly,
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
  void didUpdateWidget(WorkerList old) {
    super.didUpdateWidget(old);
    if (old.siteId != widget.siteId ||
        old.contractorId != widget.contractorId ||
        old.trade != widget.trade ||
        old.activeOnly != widget.activeOnly ||
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
    ref.listen(cRevisionProvider(CKind.workers), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());

    void open(Worker worker) => context.go('/workers/${worker.id}');
    return AdaptiveDataList<Worker>(
      controller: _paged,
      emptyMessage: 'No workers found.',
      emptyIcon: Icons.groups_outlined,
      onTap: open,
      columns: [
        TableColumnSpec('Name', (w) => Text(w.name), maxWidth: 220),
        TableColumnSpec('Trade', (w) => Text(tradeLabel(w.trade.api))),
        TableColumnSpec('Site', (w) => Text(w.siteName ?? '—'), maxWidth: 180),
        TableColumnSpec(
          'Contractor',
          (w) => Text(w.contractorName ?? '—'),
          maxWidth: 180,
        ),
        TableColumnSpec(
          'Rate',
          (w) => Text(formatMoney(w.dailyRate)),
          numeric: true,
        ),
        TableColumnSpec(
          'Status',
          (w) => Pill(w.isActive ? 'Active' : 'Inactive'),
        ),
      ],
      cardBuilder: (context, worker) => CListCard(
        onTap: () => open(worker),
        title: worker.name,
        subtitle: [
          tradeLabel(worker.trade.api),
          if (worker.siteName != null) worker.siteName!,
          if (worker.contractorName != null) worker.contractorName!,
        ].join(' · '),
        trailing: formatMoney(worker.dailyRate),
        details: [
          if (worker.phone != null) worker.phone!,
          if (worker.aadhaarLast4 != null) 'Aadhaar ••••${worker.aadhaarLast4}',
          if (worker.bocwRegNo != null) 'BOCW ${worker.bocwRegNo}',
        ],
        pills: Pill(
          worker.isActive ? 'Active' : 'Inactive',
          color: worker.isActive ? Colors.green.shade700 : Colors.blueGrey,
        ),
      ),
    );
  }
}
