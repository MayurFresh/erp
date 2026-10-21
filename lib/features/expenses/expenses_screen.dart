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
import 'expense_model.dart';
import 'expenses_repository.dart';

class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  String _query = '';
  DocStatus? _status;
  String? _locationId;
  late final PagedController<Expense> _paged = PagedController(
    (offset, limit) => ref
        .read(expensesRepositoryProvider)
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
    ref.listen(revisionProvider(DataKind.expenses), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) {
      _locationId = null;
      _paged.refresh();
    });
    final perms = ref.watch(permissionsProvider);

    void open(Expense e) => context.go('/expenses/${e.id}');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Expenses',
          subtitle: 'Paid from cash or bank',
          actions: [
            if (perms.can(Perm.expensesCreate))
              FilledButton.icon(
                onPressed: () => context.go('/expenses/new'),
                icon: const Icon(Icons.add),
                label: const Text('New expense'),
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
                hintText: 'Search number or description',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Expense>(
            controller: _paged,
            emptyMessage: 'No expenses found.',
            emptyIcon: Icons.request_quote_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (e) => Text(e.number)),
              TableColumnSpec('Date', (e) => Text(formatDate(e.expenseDate))),
              TableColumnSpec(
                'Head',
                (e) => Text(e.accountName),
                maxWidth: 160,
              ),
              TableColumnSpec(
                'Description',
                (e) => Text(e.description),
                maxWidth: 220,
              ),
              TableColumnSpec(
                'Paid from',
                (e) => Text(e.paidFromAccountName),
                maxWidth: 140,
              ),
              TableColumnSpec('Status', (e) => DocStatusPill(status: e.status)),
              TableColumnSpec(
                'Total',
                (e) => Text(
                  formatMoney(e.total),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: true,
              ),
            ],
            cardBuilder: (context, e) => DocListCard(
              onTap: () => open(e),
              title: e.description,
              details:
                  '${e.number} · ${e.accountName} · ${formatDate(e.expenseDate)}',
              pills: DocStatusPill(status: e.status),
              amount: formatMoney(e.total),
              secondary: e.taxTotal > 0
                  ? 'GST ${formatMoney(e.taxTotal)}'
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}
