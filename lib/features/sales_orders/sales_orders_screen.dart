import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/business_profile.dart';

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
import 'o2c_repository.dart';
import 'sales_order_models.dart';

class SalesOrdersScreen extends ConsumerStatefulWidget {
  const SalesOrdersScreen({super.key});

  @override
  ConsumerState<SalesOrdersScreen> createState() => _SalesOrdersScreenState();
}

class _SalesOrdersScreenState extends ConsumerState<SalesOrdersScreen> {
  String _query = '';
  String? _status;
  late final PagedController<SalesOrder> _paged = PagedController(
    (offset, limit) => ref
        .read(o2cRepositoryProvider)
        .orders(q: _query, status: _status, offset: offset, limit: limit),
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

    void open(SalesOrder o) => context.go('/sales-orders/${o.id}');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Sales orders',
          subtitle: 'Reserve stock, pick, pack and dispatch',
          actions: [
            if (perms.can(Perm.salesOrdersManage))
              FilledButton.icon(
                onPressed: () => context.go('/sales-orders/new'),
                icon: const Icon(Icons.add),
                label: Text(context.w('New order')),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 180,
              options: salesOrderStatuses,
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number, customer or reference',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<SalesOrder>(
            controller: _paged,
            emptyMessage: 'No sales orders found.',
            emptyIcon: Icons.shopping_bag_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (o) => Text(o.number)),
              TableColumnSpec('Date', (o) => Text(formatDate(o.orderDate))),
              TableColumnSpec(
                'Customer',
                (o) => Text(o.partyName),
                maxWidth: 220,
              ),
              TableColumnSpec('Location', (o) => Text(o.locationName)),
              TableColumnSpec(
                'Status',
                (o) => StatusChip(o.status, label: statusLabel(o.status)),
              ),
              TableColumnSpec(
                'Total',
                (o) => Text(
                  formatMoney(o.total),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: true,
              ),
            ],
            cardBuilder: (context, o) => DocListCard(
              onTap: () => open(o),
              title: o.number,
              details:
                  '${o.partyName} · ${formatDate(o.orderDate)} · '
                  '${o.locationName}',
              pills: StatusChip(o.status, label: statusLabel(o.status)),
              amount: formatMoney(o.total),
            ),
          ),
        ),
      ],
    );
  }
}
