import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import '../documents/document_widgets.dart';
import '../locations/location_filter.dart';
import 'purchase_model.dart';
import 'purchases_repository.dart';

class PurchasesScreen extends ConsumerStatefulWidget {
  const PurchasesScreen({super.key});

  @override
  ConsumerState<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends ConsumerState<PurchasesScreen> {
  String _query = '';
  DocStatus? _status;
  PaymentStatus? _paymentStatus;
  String? _locationId;
  late final PagedController<Purchase> _paged = PagedController(
    (offset, limit) => ref
        .read(purchasesRepositoryProvider)
        .list(
          q: _query,
          status: _status,
          paymentStatus: _paymentStatus,
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
    ref.listen(revisionProvider(DataKind.payments), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) {
      _locationId = null;
      _paged.refresh();
    });
    final perms = ref.watch(permissionsProvider);

    void open(Purchase p) {
      if (p.id != null) context.go('/purchases/${p.id}');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Purchase bills',
          actions: [
            if (perms.can(Perm.purchasesCreate))
              FilledButton.icon(
                onPressed: () => context.go('/purchases/new'),
                icon: const Icon(Icons.add),
                label: const Text('New bill'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<DocStatus>(
              label: 'Status',
              value: _status,
              width: 160,
              options: {for (final s in DocStatus.values) s: s.label},
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            FilterDropdown<PaymentStatus>(
              label: 'Payment',
              value: _paymentStatus,
              width: 170,
              options: {for (final s in PaymentStatus.values) s: s.label},
              onChanged: (v) {
                setState(() => _paymentStatus = v);
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
                hintText: 'Search number, vendor or bill no.',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Purchase>(
            controller: _paged,
            emptyMessage: 'No purchase bills found.',
            emptyIcon: Icons.shopping_cart_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (p) => Text(p.number ?? '—')),
              TableColumnSpec(
                'Supplier bill',
                (p) => Text(p.supplierInvoiceNo ?? '—'),
                maxWidth: 140,
              ),
              TableColumnSpec('Date', (p) => Text(formatDate(p.billDate))),
              TableColumnSpec(
                'Vendor',
                (p) => Text(p.partyName),
                maxWidth: 200,
              ),
              TableColumnSpec(
                'Status',
                (p) =>
                    DocPills(status: p.status, paymentStatus: p.paymentStatus),
              ),
              TableColumnSpec(
                'Total',
                (p) => Text(
                  formatMoney(p.total),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: true,
              ),
              TableColumnSpec(
                'Due',
                (p) => Text(formatMoney(p.amountDue)),
                numeric: true,
              ),
            ],
            cardBuilder: (context, p) => DocListCard(
              onTap: () => open(p),
              title: p.number ?? '—',
              details: [
                p.partyName,
                formatDate(p.billDate),
                if (p.supplierInvoiceNo != null) 'Bill ${p.supplierInvoiceNo}',
              ].join(' · '),
              pills: DocPills(status: p.status, paymentStatus: p.paymentStatus),
              amount: formatMoney(p.total),
              secondary: p.amountDue > 0 && !p.isCancelled
                  ? 'Due ${formatMoney(p.amountDue)}'
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}
