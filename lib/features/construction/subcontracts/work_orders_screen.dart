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

/// Subcontract work orders (project, contractor and status filters).
class WorkOrdersScreen extends ConsumerStatefulWidget {
  const WorkOrdersScreen({super.key, this.initialStatus});

  final String? initialStatus;

  @override
  ConsumerState<WorkOrdersScreen> createState() => _WorkOrdersScreenState();
}

class _WorkOrdersScreenState extends ConsumerState<WorkOrdersScreen> {
  String? _projectId;
  NamedRef? _contractor;
  WorkOrderStatus? _status;

  @override
  void initState() {
    super.initState();
    _status = WorkOrderStatus.values
        .where((s) => s.name == widget.initialStatus)
        .firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.subcontractsView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Work orders',
            actions: [
              if (perms.can(CPerm.subcontractsManage))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/work-orders/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New work order'),
                ),
            ],
          ),
          FilterBar(
            children: [
              StatusChips<WorkOrderStatus>(
                value: _status,
                options: {for (final s in WorkOrderStatus.values) s: s.label},
                onChanged: (v) => setState(() => _status = v),
              ),
              ProjectIdFilter(
                value: _projectId,
                onChanged: (v) => setState(() => _projectId = v),
              ),
              ContractorFilter(
                value: _contractor,
                onChanged: (v) => setState(() => _contractor = v),
              ),
            ],
          ),
          Expanded(
            child: WorkOrderList(
              projectId: _projectId,
              contractorId: _contractor?.id,
              status: _status,
            ),
          ),
        ],
      ),
    );
  }
}

class WorkOrderList extends ConsumerStatefulWidget {
  const WorkOrderList({
    super.key,
    this.projectId,
    this.contractorId,
    this.status,
  });

  final String? projectId;
  final String? contractorId;
  final WorkOrderStatus? status;

  @override
  ConsumerState<WorkOrderList> createState() => _WorkOrderListState();
}

class _WorkOrderListState extends ConsumerState<WorkOrderList> {
  late final PagedController<WorkOrder> _paged = PagedController(
    (offset, limit) => ref
        .read(subcontractRepositoryProvider)
        .workOrders(
          projectId: widget.projectId,
          contractorId: widget.contractorId,
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
  void didUpdateWidget(WorkOrderList old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId ||
        old.contractorId != widget.contractorId ||
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
    ref.listen(cRevisionProvider(CKind.workOrders), (_, _) => _paged.refresh());
    ref.listen(cRevisionProvider(CKind.raBills), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    void open(WorkOrder w) => context.go('/work-orders/${w.id}');
    return AdaptiveDataList<WorkOrder>(
      controller: _paged,
      emptyMessage: 'No work orders found.',
      emptyIcon: Icons.handyman_outlined,
      onTap: open,
      columns: [
        TableColumnSpec('Number', (w) => Text(w.number)),
        TableColumnSpec('Title', (w) => Text(w.title), maxWidth: 220),
        TableColumnSpec('Project', (w) => Text(w.projectName), maxWidth: 180),
        TableColumnSpec(
          'Contractor',
          (w) => Text(w.contractorName),
          maxWidth: 180,
        ),
        TableColumnSpec(
          'Value',
          (w) => Text(formatMoney(w.totalValue)),
          numeric: true,
        ),
        TableColumnSpec(
          'Billed',
          (w) => Text(formatMoney(w.billedGross)),
          numeric: true,
        ),
        TableColumnSpec(
          'Status',
          (w) => workOrderStatusPill(context, w.status),
        ),
      ],
      cardBuilder: (context, w) => CListCard(
        onTap: () => open(w),
        title: w.title,
        subtitle: '${w.number} · ${w.contractorName}',
        trailing: formatMoney(w.totalValue),
        details: [
          w.projectName,
          'Billed ${formatMoney(w.billedGross)} (${formatQty(w.billedPct.roundToDouble())}%)',
        ],
        pills: workOrderStatusPill(context, w.status),
        progress: w.billedPct,
      ),
    );
  }
}
