import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/adaptive_data_list.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/paged_controller.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../common/subcontract_widgets.dart';
import '../data/subcontract_repository.dart';
import '../models/common_models.dart';
import '../models/subcontract_models.dart';

/// Labour advances (worker, site and status filters).
class AdvancesScreen extends ConsumerStatefulWidget {
  const AdvancesScreen({super.key, this.initialWorkerId});

  final String? initialWorkerId;

  @override
  ConsumerState<AdvancesScreen> createState() => _AdvancesScreenState();
}

class _AdvancesScreenState extends ConsumerState<AdvancesScreen> {
  String? _workerId;
  String? _siteId;
  LabourAdvanceStatus? _status;

  @override
  void initState() {
    super.initState();
    _workerId = widget.initialWorkerId;
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final workers = ref.watch(workersLookupProvider);
    return CGate(
      anyOf: const [CPerm.wagesView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Labour advances',
            actions: [
              if (perms.can(CPerm.wagesPay))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/labour-advances/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New advance'),
                ),
            ],
          ),
          FilterBar(
            children: [
              StatusChips<LabourAdvanceStatus>(
                value: _status,
                options: {
                  for (final s in LabourAdvanceStatus.values) s: s.label,
                },
                onChanged: (v) => setState(() => _status = v),
              ),
              IdFilter(
                label: 'Worker',
                allLabel: 'All workers',
                icon: Icons.engineering_outlined,
                options: [
                  for (final w in workers.value ?? const [])
                    NamedRef(id: w.id, name: w.name),
                ],
                value: _workerId,
                onChanged: (v) => setState(() => _workerId = v),
              ),
              SiteFilter(
                value: _siteId,
                onChanged: (v) => setState(() => _siteId = v),
              ),
            ],
          ),
          Expanded(
            child: AdvanceList(
              workerId: _workerId,
              siteId: _siteId,
              status: _status,
            ),
          ),
        ],
      ),
    );
  }
}

class AdvanceList extends ConsumerStatefulWidget {
  const AdvanceList({super.key, this.workerId, this.siteId, this.status});

  final String? workerId;
  final String? siteId;
  final LabourAdvanceStatus? status;

  @override
  ConsumerState<AdvanceList> createState() => _AdvanceListState();
}

class _AdvanceListState extends ConsumerState<AdvanceList> {
  late final PagedController<LabourAdvance> _paged = PagedController(
    (offset, limit) => ref
        .read(subcontractRepositoryProvider)
        .labourAdvances(
          workerId: widget.workerId,
          siteId: widget.siteId,
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
  void didUpdateWidget(AdvanceList old) {
    super.didUpdateWidget(old);
    if (old.workerId != widget.workerId ||
        old.siteId != widget.siteId ||
        old.status != widget.status) {
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
    ref.listen(
      cRevisionProvider(CKind.labourAdvances),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    void open(LabourAdvance a) => context.go('/labour-advances/${a.id}');
    return AdaptiveDataList<LabourAdvance>(
      controller: _paged,
      emptyMessage: 'No labour advances found.',
      emptyIcon: Icons.account_balance_wallet_outlined,
      onTap: open,
      columns: [
        TableColumnSpec('Number', (a) => Text(a.number)),
        TableColumnSpec('Date', (a) => Text(formatDate(a.date))),
        TableColumnSpec('Worker', (a) => Text(a.workerName), maxWidth: 200),
        TableColumnSpec('Site', (a) => Text(a.siteName ?? '—'), maxWidth: 180),
        TableColumnSpec(
          'Amount',
          (a) => Text(formatMoney(a.amount)),
          numeric: true,
        ),
        TableColumnSpec(
          'Recovered',
          (a) => Text(formatMoney(a.recovered)),
          numeric: true,
        ),
        TableColumnSpec(
          'Balance',
          (a) => Text(
            formatMoney(a.balance),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          numeric: true,
        ),
        TableColumnSpec(
          'Status',
          (a) => labourAdvanceStatusPill(context, a.status),
        ),
      ],
      cardBuilder: (context, a) => CListCard(
        onTap: () => open(a),
        title: a.workerName,
        subtitle: [a.number, ?a.siteName].join(' · '),
        trailing: formatMoney(a.amount),
        details: [
          '${formatDate(a.date)} · recovered ${formatMoney(a.recovered)} · '
              'balance ${formatMoney(a.balance)}',
        ],
        pills: labourAdvanceStatusPill(context, a.status),
      ),
    );
  }
}
