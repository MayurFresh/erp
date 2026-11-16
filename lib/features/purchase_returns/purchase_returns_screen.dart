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
import 'purchase_return_model.dart';
import 'purchase_returns_repository.dart';

class PurchaseReturnsScreen extends ConsumerStatefulWidget {
  const PurchaseReturnsScreen({super.key});

  @override
  ConsumerState<PurchaseReturnsScreen> createState() =>
      _PurchaseReturnsScreenState();
}

class _PurchaseReturnsScreenState extends ConsumerState<PurchaseReturnsScreen> {
  String _query = '';
  DocStatus? _status;
  late final PagedController<PurchaseReturn> _paged = PagedController(
    (offset, limit) => ref
        .read(purchaseReturnsRepositoryProvider)
        .list(q: _query, status: _status, offset: offset, limit: limit),
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
      revisionProvider(DataKind.purchaseReturns),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);

    void open(PurchaseReturn n) => context.go('/purchase-returns/${n.id}');
    String kindLabel(PurchaseReturn n) =>
        n.isGoods ? 'Goods returned' : 'Price reduction';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Debit notes',
          subtitle: 'Goods returned to vendors and price reductions',
          actions: [
            if (perms.can(Perm.purchasesCreate))
              FilledButton.icon(
                onPressed: () => context.go('/purchase-returns/new'),
                icon: const Icon(Icons.add),
                label: const Text('New debit note'),
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
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number, bill or vendor',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<PurchaseReturn>(
            controller: _paged,
            emptyMessage: 'No debit notes found.',
            emptyIcon: Icons.assignment_return_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (n) => Text(n.number)),
              TableColumnSpec('Date', (n) => Text(formatDate(n.returnDate))),
              TableColumnSpec('Bill', (n) => Text(n.purchaseNumber)),
              TableColumnSpec('Vendor', (n) => Text(n.partyName), maxWidth: 200),
              TableColumnSpec('Type', (n) => Text(kindLabel(n))),
              TableColumnSpec('Status', (n) => DocStatusPill(status: n.status)),
              TableColumnSpec(
                'Total',
                (n) => Text(
                  formatMoney(n.total),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: true,
              ),
            ],
            cardBuilder: (context, n) => DocListCard(
              onTap: () => open(n),
              title: n.number,
              details:
                  '${n.partyName} · ${formatDate(n.returnDate)} · '
                  '${kindLabel(n)} on ${n.purchaseNumber}',
              pills: DocStatusPill(status: n.status),
              amount: formatMoney(n.total),
            ),
          ),
        ),
      ],
    );
  }
}
