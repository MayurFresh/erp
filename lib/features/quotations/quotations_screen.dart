import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import 'quotation_models.dart';
import 'quotation_repository.dart';

/// Status filter: the server states. "Expired" is a word on open documents
/// past their valid date, not a filter.
final Map<String, String> _filterStatuses = {
  for (final e in quotationStatuses.entries)
    if (e.key != 'expired') e.key: e.value,
};

class QuotationsScreen extends ConsumerStatefulWidget {
  const QuotationsScreen({super.key, this.partyId, this.dealId});

  /// Shows only one customer's documents (`/quotations?partyId=`).
  final String? partyId;
  final String? dealId;

  @override
  ConsumerState<QuotationsScreen> createState() => _QuotationsScreenState();
}

class _QuotationsScreenState extends ConsumerState<QuotationsScreen> {
  String _query = '';
  String? _status;
  String? _kind;
  late final PagedController<Quotation> _paged = PagedController(
    (offset, limit) => ref
        .read(quotationRepositoryProvider)
        .list(
          q: _query,
          status: _status,
          kind: _kind,
          partyId: widget.partyId,
          dealId: widget.dealId,
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
    ref.listen(quotationRevisionProvider, (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);
    void open(Quotation q) => context.go('/quotations/${q.id}');
    String word(Quotation q) => quotationStatuses[q.statusWord] ?? q.statusWord;

    final newPath = [
      '/quotations/new',
      if (widget.partyId != null || widget.dealId != null)
        '?${[if (widget.partyId != null) 'partyId=${widget.partyId}', if (widget.dealId != null) 'dealId=${widget.dealId}'].join('&')}',
    ].join();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Quotations',
          subtitle: 'Quotations and proforma invoices before the sale',
          actions: [
            if (perms.can(Perm.quotationsManage))
              FilledButton.icon(
                onPressed: () => context.go(newPath),
                icon: const Icon(Icons.add),
                label: const Text('New quotation'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 180,
              options: _filterStatuses,
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            FilterDropdown<String>(
              label: 'Type',
              value: _kind,
              width: 200,
              options: quotationKinds,
              onChanged: (v) {
                setState(() => _kind = v);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number or customer',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        ListenableBuilder(
          listenable: _paged,
          builder: (context, _) {
            if (_paged.items.isEmpty) return const SizedBox.shrink();
            final live = _paged.items.where(
              (q) => q.status != 'cancelled' && q.status != 'declined',
            );
            final sum = live.fold<double>(0, (a, q) => a + q.total);
            final theme = Theme.of(context);
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: pageGutter(context),
                vertical: 4,
              ),
              child: Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${_paged.total} documents, value excluding declined and cancelled',
                    style: theme.textTheme.bodySmall,
                  ),
                  MoneyText(sum, style: theme.textTheme.labelLarge),
                ],
              ),
            );
          },
        ),
        Expanded(
          child: AdaptiveDataList<Quotation>(
            controller: _paged,
            emptyMessage: _status != null || _kind != null || _query.isNotEmpty
                ? 'No quotations match these filters.'
                : 'No quotations yet. Create your first quotation.',
            emptyIcon: Icons.request_quote_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (q) => Text(q.number)),
              TableColumnSpec('Type', (q) => Text(kindLabel(q.kind))),
              TableColumnSpec('Date', (q) => Text(formatDate(q.quoteDate))),
              TableColumnSpec(
                'Customer',
                (q) => Text(q.partyName),
                maxWidth: 220,
              ),
              TableColumnSpec(
                'Valid until',
                (q) => Text(formatDate(q.validUntil)),
              ),
              TableColumnSpec(
                'Status',
                (q) => StatusChip(q.statusWord, label: word(q)),
              ),
              TableColumnSpec(
                'Total',
                (q) => MoneyText(
                  q.total,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: true,
              ),
            ],
            cardBuilder: (context, q) => DocListCard(
              onTap: () => open(q),
              title: q.number,
              details:
                  '${q.partyName} · ${kindLabel(q.kind)} · '
                  'valid until ${formatDate(q.validUntil)}',
              pills: StatusChip(q.statusWord, label: word(q)),
              amount: formatMoney(q.total),
            ),
          ),
        ),
      ],
    );
  }
}
