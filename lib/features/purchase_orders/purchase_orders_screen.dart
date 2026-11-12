import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/business_profile.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../locations/location_filter.dart';
import 'po_models.dart';
import 'po_repository.dart';
import 'po_widgets.dart';

class PurchaseOrdersScreen extends ConsumerStatefulWidget {
  const PurchaseOrdersScreen({super.key});

  @override
  ConsumerState<PurchaseOrdersScreen> createState() => _State();
}

class _State extends ConsumerState<PurchaseOrdersScreen> {
  String _query = '';
  String? _status;
  String? _locationId;
  late final PagedController<PurchaseOrder> _paged = PagedController(
    (offset, limit) => ref
        .read(poRepositoryProvider)
        .list(
          q: _query,
          status: _status,
          locationId: _locationId,
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
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      revisionProvider(DataKind.purchases),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) {
      _locationId = null;
      _paged.refresh();
    });
    final perms = ref.watch(permissionsProvider);

    void open(PurchaseOrder p) {
      if (p.id != null) context.go('/purchase-orders/${p.id}');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Purchase orders',
          actions: [
            if (perms.can(Perm.purchaseOrdersManage)) ...[
              OutlinedButton.icon(
                onPressed: () => context.go('/reorder'),
                icon: const Icon(Icons.inventory_2_outlined),
                label: Text(context.w('Reorder suggestions')),
              ),
              FilledButton.icon(
                onPressed: () => context.go('/purchase-orders/new'),
                icon: const Icon(Icons.add),
                label: Text(context.w('New order')),
              ),
            ],
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 190,
              options: poStatusLabels,
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            LocationFilter(
              value: _locationId,
              onChanged: (id) {
                setState(() => _locationId = id);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number, vendor or notes',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<PurchaseOrder>(
            controller: _paged,
            emptyMessage: 'No purchase orders found.',
            emptyIcon: Icons.assignment_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (p) => Text(p.number ?? '—')),
              TableColumnSpec('Date', (p) => Text(formatDate(p.orderDate))),
              TableColumnSpec(
                'Vendor',
                (p) => Text(p.partyName),
                maxWidth: 200,
              ),
              TableColumnSpec(
                'Expected',
                (p) => Text(formatDate(p.expectedDate)),
              ),
              TableColumnSpec('Status', (p) => PoStatusChip(p.status)),
              TableColumnSpec(
                'Received',
                (p) => Text(
                  '${formatQty(p.progress.received)} of '
                  '${formatQty(p.progress.ordered - p.progress.cancelled)}',
                ),
                numeric: true,
              ),
              TableColumnSpec(
                'Total',
                (p) => Text(
                  formatMoney(p.total),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: true,
              ),
            ],
            cardBuilder: (context, p) => DocListCard(
              onTap: () => open(p),
              title: p.number ?? '—',
              details: [
                p.partyName,
                formatDate(p.orderDate),
                if (p.expectedDate != null)
                  'Expected ${formatDate(p.expectedDate)}',
              ].join(' · '),
              pills: PoStatusChip(p.status),
              amount: formatMoney(p.total),
              secondary:
                  'Received ${formatQty(p.progress.received)} of '
                  '${formatQty(p.progress.ordered - p.progress.cancelled)}',
            ),
          ),
        ),
      ],
    );
  }
}
