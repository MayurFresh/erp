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
import '../models/subcontract_models.dart';

/// Running-account (RA) bills with status and payment status filters.
class RaBillsScreen extends ConsumerStatefulWidget {
  const RaBillsScreen({super.key, this.initialStatus});

  final String? initialStatus;

  @override
  ConsumerState<RaBillsScreen> createState() => _RaBillsScreenState();
}

class _RaBillsScreenState extends ConsumerState<RaBillsScreen> {
  String? _projectId;
  RaBillStatus? _status;
  RaPaymentStatus? _payment;

  @override
  void initState() {
    super.initState();
    _status = RaBillStatus.values
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
            title: 'RA bills',
            actions: [
              if (perms.can(CPerm.subcontractsManage))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/ra-bills/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New RA bill'),
                ),
            ],
          ),
          FilterBar(
            children: [
              StatusChips<RaBillStatus>(
                value: _status,
                options: {for (final s in RaBillStatus.values) s: s.label},
                onChanged: (v) => setState(() => _status = v),
              ),
              StatusChips<RaPaymentStatus>(
                value: _payment,
                options: {for (final s in RaPaymentStatus.values) s: s.label},
                onChanged: (v) => setState(() => _payment = v),
              ),
              ProjectIdFilter(
                value: _projectId,
                onChanged: (v) => setState(() => _projectId = v),
              ),
            ],
          ),
          Expanded(
            child: RaBillList(
              projectId: _projectId,
              status: _status,
              paymentStatus: _payment,
            ),
          ),
        ],
      ),
    );
  }
}

class RaBillList extends ConsumerStatefulWidget {
  const RaBillList({
    super.key,
    this.projectId,
    this.status,
    this.paymentStatus,
  });

  final String? projectId;
  final RaBillStatus? status;
  final RaPaymentStatus? paymentStatus;

  @override
  ConsumerState<RaBillList> createState() => _RaBillListState();
}

class _RaBillListState extends ConsumerState<RaBillList> {
  late final PagedController<RaBill> _paged = PagedController(
    (offset, limit) => ref
        .read(subcontractRepositoryProvider)
        .raBills(
          projectId: widget.projectId,
          status: widget.status,
          paymentStatus: widget.paymentStatus,
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
  void didUpdateWidget(RaBillList old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId ||
        old.status != widget.status ||
        old.paymentStatus != widget.paymentStatus) {
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
    ref.listen(cRevisionProvider(CKind.raBills), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    void open(RaBill b) => context.go('/ra-bills/${b.id}');
    return AdaptiveDataList<RaBill>(
      controller: _paged,
      emptyMessage: 'No RA bills found.',
      emptyIcon: Icons.receipt_long_outlined,
      onTap: open,
      columns: [
        TableColumnSpec('Number', (b) => Text(b.number)),
        TableColumnSpec('Date', (b) => Text(formatDate(b.date))),
        TableColumnSpec(
          'Work order',
          (b) => Text('${b.workOrderNumber} · bill ${b.billSeq}'),
          maxWidth: 200,
        ),
        TableColumnSpec(
          'Contractor',
          (b) => Text(b.contractorName),
          maxWidth: 180,
        ),
        TableColumnSpec(
          'Gross',
          (b) => Text(formatMoney(b.gross)),
          numeric: true,
        ),
        TableColumnSpec(
          'Net payable',
          (b) => Text(formatMoney(b.netPayable)),
          numeric: true,
        ),
        TableColumnSpec('Status', (b) => raBillPills(context, b)),
      ],
      cardBuilder: (context, b) => CListCard(
        onTap: () => open(b),
        title: b.contractorName,
        subtitle: '${b.number} · ${b.workOrderNumber}',
        trailing: formatMoney(b.netPayable),
        details: [
          b.projectName,
          'Bill ${b.billSeq} · ${formatDate(b.date)}',
          if (b.status == RaBillStatus.approved && b.amountDue > 0)
            'Due ${formatMoney(b.amountDue)}',
        ],
        pills: raBillPills(context, b),
      ),
    );
  }
}
