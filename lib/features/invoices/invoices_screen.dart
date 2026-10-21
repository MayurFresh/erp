import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../auth/session.dart';
import '../locations/location_filter.dart';
import 'invoice_model.dart';
import 'invoice_widgets.dart';
import 'invoices_repository.dart';

class InvoicesScreen extends ConsumerStatefulWidget {
  const InvoicesScreen({super.key});

  @override
  ConsumerState<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends ConsumerState<InvoicesScreen> {
  String _query = '';
  InvoiceStatus? _status;
  String? _locationId;
  late final PagedController<Invoice> _paged = PagedController(
    (offset, limit) => ref
        .read(invoicesRepositoryProvider)
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
    ref.listen(revisionProvider(DataKind.invoices), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) {
      _locationId = null;
      _paged.refresh();
    });
    final perms = ref.watch(permissionsProvider);

    void open(Invoice invoice) {
      if (invoice.id != null) context.go('/invoices/${invoice.id}');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Sales invoices',
          actions: [
            if (perms.can(Perm.invoicesCreate))
              FilledButton.icon(
                onPressed: () => context.go('/invoices/new'),
                icon: const Icon(Icons.add),
                label: const Text('New invoice'),
              ),
          ],
        ),
        FilterBar(
          children: [
            SegmentedButton<InvoiceStatus?>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: null, label: Text('All')),
                ButtonSegment(
                  value: InvoiceStatus.posted,
                  label: Text('Posted'),
                ),
                ButtonSegment(
                  value: InvoiceStatus.cancelled,
                  label: Text('Cancelled'),
                ),
              ],
              selected: {_status},
              onSelectionChanged: (s) {
                setState(() => _status = s.first);
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
                hintText: 'Search number or party',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Invoice>(
            controller: _paged,
            emptyMessage: 'No invoices found.',
            emptyIcon: Icons.receipt_long_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (i) => Text(i.number ?? '—')),
              TableColumnSpec('Date', (i) => Text(formatDate(i.invoiceDate))),
              TableColumnSpec('Party', (i) => Text(i.partyName), maxWidth: 220),
              TableColumnSpec(
                'Location',
                (i) => Text(i.locationName),
                maxWidth: 160,
              ),
              TableColumnSpec(
                'Status',
                (i) =>
                    DocPills(status: i.status, paymentStatus: i.paymentStatus),
              ),
              TableColumnSpec(
                'Total',
                (i) => Text(
                  formatMoney(i.total),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: true,
              ),
              TableColumnSpec(
                'Due',
                (i) =>
                    Text(i.amountDue == null ? '—' : formatMoney(i.amountDue)),
                numeric: true,
              ),
            ],
            cardBuilder: (context, i) => DocListCard(
              onTap: () => open(i),
              title: i.number ?? '—',
              details: '${i.partyName} · ${formatDate(i.invoiceDate)}',
              pills: DocPills(status: i.status, paymentStatus: i.paymentStatus),
              amount: formatMoney(i.total),
              secondary: (i.amountDue ?? 0) > 0 && !i.isCancelled
                  ? 'Due ${formatMoney(i.amountDue)}'
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}
