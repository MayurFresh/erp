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
import 'credit_note_model.dart';
import 'credit_notes_repository.dart';

class CreditNotesScreen extends ConsumerStatefulWidget {
  const CreditNotesScreen({super.key});

  @override
  ConsumerState<CreditNotesScreen> createState() => _CreditNotesScreenState();
}

class _CreditNotesScreenState extends ConsumerState<CreditNotesScreen> {
  String _query = '';
  DocStatus? _status;
  late final PagedController<CreditNote> _paged = PagedController(
    (offset, limit) => ref
        .read(creditNotesRepositoryProvider)
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
      revisionProvider(DataKind.creditNotes),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);

    void open(CreditNote n) {
      if (n.id != null) context.go('/credit-notes/${n.id}');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Credit notes',
          subtitle: 'Sales returns against invoices',
          actions: [
            if (perms.can(Perm.creditNotesCreate))
              FilledButton.icon(
                onPressed: () => context.go('/credit-notes/new'),
                icon: const Icon(Icons.add),
                label: const Text('New credit note'),
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
                hintText: 'Search number, invoice or party',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<CreditNote>(
            controller: _paged,
            emptyMessage: 'No credit notes found.',
            emptyIcon: Icons.assignment_return_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (n) => Text(n.number ?? '—')),
              TableColumnSpec('Date', (n) => Text(formatDate(n.noteDate))),
              TableColumnSpec('Invoice', (n) => Text(n.invoiceNumber)),
              TableColumnSpec('Party', (n) => Text(n.partyName), maxWidth: 200),
              TableColumnSpec('Reason', (n) => Text(n.reason), maxWidth: 180),
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
              title: n.number ?? '—',
              details:
                  '${n.partyName} · ${formatDate(n.noteDate)} · '
                  'against ${n.invoiceNumber}',
              pills: DocStatusPill(status: n.status),
              amount: formatMoney(n.total),
            ),
          ),
        ),
      ],
    );
  }
}
