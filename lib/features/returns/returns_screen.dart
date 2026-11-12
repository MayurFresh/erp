import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../sales_orders/o2c_repository.dart';
import 'return_models.dart';

String returnLabel(String s) => returnStatuses[s] ?? s;

class ReturnsScreen extends ConsumerStatefulWidget {
  const ReturnsScreen({super.key});

  @override
  ConsumerState<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends ConsumerState<ReturnsScreen> {
  String _query = '';
  String? _status;
  late final PagedController<SalesReturn> _paged = PagedController(
    (offset, limit) => ref
        .read(o2cRepositoryProvider)
        .returns(q: _query, status: _status, offset: offset, limit: limit),
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
    ref.listen(o2cRevisionProvider, (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);
    void open(SalesReturn r) => context.go('/sales-returns/${r.id}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Sales returns',
          subtitle: 'Receive, inspect and credit returned goods',
          actions: [
            if (perms.can(Perm.returnsManage))
              FilledButton.icon(
                onPressed: () => context.go('/sales-returns/new'),
                icon: const Icon(Icons.add),
                label: const Text('New return'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 170,
              options: returnStatuses,
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number, order or customer',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<SalesReturn>(
            controller: _paged,
            emptyMessage: 'No returns found.',
            emptyIcon: Icons.assignment_return_outlined,
            onTap: open,
            tableBreakpoint: 900,
            columns: [
              TableColumnSpec('Number', (r) => Text(r.number)),
              TableColumnSpec('Date', (r) => Text(formatDate(r.createdAt))),
              TableColumnSpec('Order', (r) => Text(r.orderNumber ?? '—')),
              TableColumnSpec(
                'Customer',
                (r) => Text(r.partyName),
                maxWidth: 200,
              ),
              TableColumnSpec(
                'Type',
                (r) => Text(r.isRto ? 'Return to origin' : 'Customer return'),
              ),
              TableColumnSpec(
                'Status',
                (r) => StatusChip(r.status, label: returnLabel(r.status)),
              ),
            ],
            cardBuilder: (context, r) => DocListCard(
              onTap: () => open(r),
              title: r.number,
              details:
                  '${r.partyName} · ${r.orderNumber ?? ''} · '
                  '${formatDate(r.createdAt)}',
              pills: StatusChip(r.status, label: returnLabel(r.status)),
              amount: r.isRto ? 'Return to origin' : 'Customer return',
            ),
          ),
        ),
      ],
    );
  }
}
