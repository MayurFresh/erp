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
import 'payment_model.dart';
import 'payments_repository.dart';

/// Receipts (`kind=receipt`, Sales) or payments (`kind=payment`, Purchases).
class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key, required this.kind});

  final PaymentKind kind;

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  String _query = '';
  DocStatus? _status;
  late final PagedController<Payment> _paged = PagedController(
    (offset, limit) => ref
        .read(paymentsRepositoryProvider)
        .list(
          kind: widget.kind,
          q: _query,
          status: _status,
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
    ref.listen(revisionProvider(DataKind.payments), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);
    final kind = widget.kind;
    final receipts = kind == PaymentKind.receipt;

    void open(Payment p) => context.go('${kind.basePath}/${p.id}');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: kind.plural,
          subtitle: receipts
              ? 'Money received from customers'
              : 'Money paid to vendors',
          actions: [
            if (perms.can(Perm.paymentsCreate))
              FilledButton.icon(
                onPressed: () => context.go('${kind.basePath}/new'),
                icon: const Icon(Icons.add),
                label: Text('Record ${kind.label.toLowerCase()}'),
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
                hintText: 'Search number, party or reference',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Payment>(
            controller: _paged,
            emptyMessage: receipts
                ? 'No receipts recorded.'
                : 'No payments recorded.',
            emptyIcon: Icons.payments_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (p) => Text(p.number)),
              TableColumnSpec('Date', (p) => Text(formatDate(p.date))),
              TableColumnSpec(
                kind.partyLabel,
                (p) => Text(p.partyName),
                maxWidth: 200,
              ),
              TableColumnSpec('Mode', (p) => Text(p.mode.label)),
              TableColumnSpec(
                'Account',
                (p) => Text(p.accountName),
                maxWidth: 150,
              ),
              TableColumnSpec('Status', (p) => DocStatusPill(status: p.status)),
              TableColumnSpec(
                'Amount',
                (p) => Text(
                  formatMoney(p.amount),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: true,
              ),
              TableColumnSpec(
                'Advance',
                (p) =>
                    Text(p.unallocated == 0 ? '—' : formatMoney(p.unallocated)),
                numeric: true,
              ),
            ],
            cardBuilder: (context, p) => DocListCard(
              onTap: () => open(p),
              title: p.number,
              details:
                  '${p.partyName} · ${formatDate(p.date)} · ${p.mode.label}',
              pills: DocStatusPill(status: p.status),
              amount: formatMoney(p.amount),
              secondary: p.unallocated > 0
                  ? 'Advance ${formatMoney(p.unallocated)}'
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}
