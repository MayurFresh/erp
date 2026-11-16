import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../reports/pdf_actions.dart';
import 'rfq_compare.dart';
import 'rfq_models.dart';
import 'rfq_pdf.dart';
import 'rfq_quote_dialog.dart';
import 'rfq_repository.dart';

class RfqsScreen extends ConsumerStatefulWidget {
  const RfqsScreen({super.key});

  @override
  ConsumerState<RfqsScreen> createState() => _ListState();
}

class _ListState extends ConsumerState<RfqsScreen> {
  String _query = '';
  String? _status;
  late final PagedController<Rfq> _paged = PagedController(
    (offset, limit) => ref
        .read(rfqRepositoryProvider)
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
    ref.listen(revisionProvider(DataKind.purchases), (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Quotation requests',
          actions: [
            if (perms.can(Perm.purchaseOrdersManage))
              FilledButton.icon(
                onPressed: () => context.go('/rfqs/new'),
                icon: const Icon(Icons.add),
                label: const Text('New request'),
              ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 190,
              options: rfqStatusLabels,
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number or notes',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Rfq>(
            controller: _paged,
            emptyMessage: 'No quotation requests yet.',
            emptyIcon: Icons.request_quote_outlined,
            onTap: (r) => context.go('/rfqs/${r.id}'),
            columns: [
              TableColumnSpec('Number', (r) => Text(r.number)),
              TableColumnSpec('Date', (r) => Text(formatDate(r.rfqDate))),
              TableColumnSpec('Deliver to', (r) => Text(r.locationName)),
              TableColumnSpec(
                'Status',
                (r) => StatusChip(r.status, label: rfqStatusLabels[r.status]),
              ),
              TableColumnSpec('Vendors', (r) => Text('${r.vendorCount}'), numeric: true),
              TableColumnSpec('Items', (r) => Text('${r.lineCount}'), numeric: true),
            ],
            cardBuilder: (context, r) => DocListCard(
              onTap: () => context.go('/rfqs/${r.id}'),
              title: r.number,
              details: '${formatDate(r.rfqDate)} · ${r.locationName}',
              pills: StatusChip(r.status, label: rfqStatusLabels[r.status]),
              amount: '${r.vendorCount} vendors',
              secondary: '${r.lineCount} items',
            ),
          ),
        ),
      ],
    );
  }
}

class RfqDetailScreen extends ConsumerWidget {
  const RfqDetailScreen({super.key, required this.rfqId});

  final String rfqId;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<Object?> Function(RfqRepository r) call,
    String done,
  ) async {
    try {
      await call(ref.read(rfqRepositoryProvider));
      ref.bump(const [DataKind.purchases]);
      if (context.mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(Perm.purchaseOrdersManage);
    return AsyncValueView<Rfq>(
      value: ref.watch(rfqProvider(rfqId)),
      onRetry: () => ref.invalidate(rfqProvider(rfqId)),
      data: (r) => FormPage(
        maxWidth: 1100,
        children: [
          DocHeader(
            title: r.number,
            pills: StatusChip(r.status, label: rfqStatusLabels[r.status]),
            facts: [
              LabeledValue('Date', formatDate(r.rfqDate)),
              LabeledValue('Deliver to', r.locationName),
              if (r.dueDate != null) LabeledValue('Reply by', formatDate(r.dueDate)),
            ],
            actions: [
              ...pdfDocActions(
                context,
                ref,
                fileName: rfqFileName(r),
                build: (p) async => buildRfqPdf(
                  r,
                  p.company,
                  brand: p.brand,
                  theme: p.theme,
                ),
              ),
              if (manage && r.isDraft) ...[
                DocAction(
                  label: 'Edit',
                  icon: Icons.edit_outlined,
                  onPressed: () => context.go('/rfqs/${r.id}/edit'),
                ),
                DocAction(
                  label: 'Send to vendors',
                  icon: Icons.send_outlined,
                  primary: true,
                  onPressed: () => _run(
                    context,
                    ref,
                    (x) => x.send(r.id),
                    'Request ${r.number} marked as sent',
                  ),
                ),
                DocAction(
                  label: 'Delete',
                  icon: Icons.delete_outline,
                  destructive: true,
                  onPressed: () async {
                    await _run(context, ref, (x) => x.delete(r.id), 'Request deleted');
                    if (context.mounted) context.go('/rfqs');
                  },
                ),
              ],
              if (manage && r.canQuote) ...[
                if (r.status == 'quotes_received')
                  DocAction(
                    label: 'Choose lowest',
                    icon: Icons.south,
                    onPressed: () => _run(
                      context,
                      ref,
                      (x) => x.choose(r.id),
                      'Lowest quotes chosen',
                    ),
                  ),
                DocAction(
                  label: 'Create orders',
                  icon: Icons.assignment_turned_in_outlined,
                  primary: true,
                  onPressed: () async {
                    await _run(
                      context,
                      ref,
                      (x) => x.convert(r.id),
                      'Purchase orders created',
                    );
                  },
                ),
                DocAction(
                  label: 'Close',
                  icon: Icons.block,
                  destructive: true,
                  onPressed: () => _run(context, ref, (x) => x.close(r.id), 'Request closed'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Vendors',
            child: Column(
              children: [
                for (final v in r.vendors)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(v.partyName),
                    subtitle: Text(
                      v.sentAt == null ? 'Not sent' : 'Sent ${formatDate(v.sentAt)}',
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (v.total > 0) Text(formatMoney(v.total)),
                        if (!r.isDraft)
                          IconButton(
                            tooltip: 'Copy message for ${v.partyName}',
                            icon: const Icon(Icons.copy_outlined),
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: rfqMessage(r, v.partyName)),
                              );
                              if (context.mounted) {
                                showInfoSnackBar(
                                  context,
                                  'Message copied for WhatsApp or email',
                                );
                              }
                            },
                          ),
                        if (manage && r.canQuote)
                          TextButton(
                            onPressed: () async {
                              final quotes = await showQuoteDialog(context, r, v);
                              if (quotes == null || !context.mounted) return;
                              await _run(
                                context,
                                ref,
                                (x) => x.saveQuotes(r.id, v.partyId, quotes),
                                'Quote saved',
                              );
                            },
                            child: const Text('Enter quote'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: r.status == 'draft' ? 'Items' : 'Compare quotes',
            child: r.status == 'draft'
                ? Column(
                    children: [
                      for (final l in r.lines)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l.itemName),
                          trailing: Text('${formatQty(l.qty)} ${l.unit}'),
                        ),
                    ],
                  )
                : RfqComparison(
                    rfq: r,
                    canChoose: manage && r.status == 'quotes_received',
                    onChoose: (line, partyId) => _run(
                      context,
                      ref,
                      (x) => x.choose(r.id, lineId: line.id, partyId: partyId),
                      partyId == null ? 'Choice cleared' : 'Vendor chosen',
                    ),
                  ),
          ),
          if (r.orders.isNotEmpty) ...[
            const SizedBox(height: 12),
            SectionCard(
              title: 'Purchase orders',
              child: Column(
                children: [
                  for (final o in r.orders)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${o['number']}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.go('/purchase-orders/${o['id']}'),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
