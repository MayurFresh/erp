import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import 'landed_cost_models.dart';
import 'landed_cost_repository.dart';
import 'landed_cost_widgets.dart';

class LandedCostsScreen extends ConsumerStatefulWidget {
  const LandedCostsScreen({super.key});

  @override
  ConsumerState<LandedCostsScreen> createState() => _ListState();
}

class _ListState extends ConsumerState<LandedCostsScreen> {
  String _query = '';
  late final PagedController<LandedCost> _paged = PagedController(
    (offset, limit) => ref
        .read(landedCostRepositoryProvider)
        .list(q: _query, offset: offset, limit: limit),
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
          title: 'Landed cost',
          actions: [
            OutlinedButton.icon(
              onPressed: () => context.go('/landed-costs/report'),
              icon: const Icon(Icons.table_chart_outlined),
              label: const Text('Report'),
            ),
            if (perms.can(Perm.purchasesCreate))
              FilledButton.icon(
                onPressed: () => context.go('/landed-costs/new'),
                icon: const Icon(Icons.add),
                label: const Text('New landed cost'),
              ),
          ],
        ),
        FilterBar(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number or bill',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<LandedCost>(
            controller: _paged,
            emptyMessage: 'No landed cost vouchers yet.',
            emptyIcon: Icons.local_shipping_outlined,
            onTap: (v) => context.go('/landed-costs/${v.id}'),
            columns: [
              TableColumnSpec('Number', (v) => Text(v.number ?? '')),
              TableColumnSpec('Date', (v) => Text(formatDate(v.voucherDate))),
              TableColumnSpec('Basis', (v) => Text(lcBases[v.basis] ?? v.basis)),
              TableColumnSpec('Status', (v) => StatusChip(v.status)),
              TableColumnSpec(
                'Cost added',
                (v) => Text(formatMoney(v.chargesTotal)),
                numeric: true,
              ),
            ],
            cardBuilder: (context, v) => DocListCard(
              onTap: () => context.go('/landed-costs/${v.id}'),
              title: v.number ?? '',
              details: '${formatDate(v.voucherDate)} · ${lcBases[v.basis]}',
              pills: StatusChip(v.status),
              amount: formatMoney(v.chargesTotal),
            ),
          ),
        ),
      ],
    );
  }
}

class LandedCostDetailScreen extends ConsumerWidget {
  const LandedCostDetailScreen({super.key, required this.id});

  final String id;

  Future<void> _cancel(BuildContext context, WidgetRef ref, LandedCost v) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${v.number}?',
        message:
            'The stock value and the journal are reversed in full. This '
            'cannot be undone.',
        confirmLabel: 'Cancel landed cost',
        keepLabel: 'Keep it',
      ),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref.read(landedCostRepositoryProvider).cancel(id, reason);
      ref.bump(const [DataKind.purchases, DataKind.stock]);
      if (context.mounted) showInfoSnackBar(context, '${v.number} cancelled');
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView<LandedCost>(
      value: ref.watch(landedCostProvider(id)),
      onRetry: () => ref.invalidate(landedCostProvider(id)),
      data: (v) => FormPage(
        children: [
          PageHeader(
            title: v.number ?? 'Landed cost',
            subtitle: formatDate(v.voucherDate),
            actions: [
              if (!v.cancelled && perms.can(Perm.purchasesCancel))
                OutlinedButton(
                  onPressed: () => _cancel(context, ref, v),
                  child: const Text('Cancel'),
                ),
            ],
          ),
          SectionCard(
            title: 'Summary',
            trailing: StatusChip(v.status),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Shared ${lcBases[v.basis]?.toLowerCase()}'),
                Text('Cost added ${formatMoney(v.chargesTotal)}'),
                Text('To stock ${formatMoney(v.inventoryTotal)}'),
                Text('To cost of sales ${formatMoney(v.cogsTotal)}'),
                if (v.igstTotal > 0)
                  Text('IGST paid on import ${formatMoney(v.igstTotal)}'),
                if (v.cancelReason != null) Text('Reason: ${v.cancelReason}'),
                if (v.notes != null) Text(v.notes!),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Charges',
            child: Column(
              children: [
                for (final c in v.charges)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(lcKinds[c.kind] ?? c.kind),
                    subtitle: c.igstAmount > 0
                        ? Text('IGST ${formatMoney(c.igstAmount)}')
                        : null,
                    trailing: Text(formatMoney(c.amount)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(title: 'Lines', child: LcLinesView(lines: v.lines)),
        ],
      ),
    );
  }
}

/// Landed cost by bill and item.
class LandedCostReportScreen extends ConsumerWidget {
  const LandedCostReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncValueView<Json>(
      value: ref.watch(landedCostReportProvider),
      onRetry: () => ref.invalidate(landedCostReportProvider),
      data: (r) {
        final rows = asJsonList(r['data']);
        final totals = asJson(r['totals']);
        return FormPage(
          children: [
            const PageHeader(title: 'Landed cost report'),
            SectionCard(
              child: rows.isEmpty
                  ? const Text('No landed cost has been posted yet.')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Cost added ${formatMoney(asDouble(totals['allocated']))} '
                          'on ${formatMoney(asDouble(totals['baseValue']))} of goods.',
                        ),
                        const Divider(),
                        for (final x in rows)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(asString(x['itemName'])),
                            subtitle: Text(
                              '${x['docNumber']} · ${x['voucherNumber']} · '
                              '${formatQty(asDouble(x['qty']))} units · '
                              'landed rate ${formatMoney(asDouble(x['landedUnitCost']))}',
                            ),
                            trailing: Text(formatMoney(asDouble(x['allocated']))),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
