import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../sales_orders/o2c_repository.dart';
import 'fulfilment_models.dart';
import 'scan_panel.dart';

class PickListsScreen extends ConsumerStatefulWidget {
  const PickListsScreen({super.key});

  @override
  ConsumerState<PickListsScreen> createState() => _PickListsScreenState();
}

class _PickListsScreenState extends ConsumerState<PickListsScreen> {
  String? _status = 'open';
  late final PagedController<PickListSummary> _paged = PagedController(
    (offset, limit) => ref
        .read(o2cRepositoryProvider)
        .pickLists(status: _status, offset: offset, limit: limit),
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
    ref.listen(o2cRevisionProvider, (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    void open(PickListSummary p) => context.go('/pick-lists/${p.id}');
    String progress(PickListSummary p) =>
        '${formatQty(p.totalPicked)} of ${formatQty(p.totalTarget)} picked';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Pick lists',
          subtitle: 'Collect reserved stock from the shelves',
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 160,
              options: const {
                'open': 'Open',
                'completed': 'Completed',
                'cancelled': 'Cancelled',
              },
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<PickListSummary>(
            controller: _paged,
            emptyMessage: 'No pick lists. Create one from a confirmed order.',
            emptyIcon: Icons.list_alt_outlined,
            onTap: open,
            tableBreakpoint: 900,
            columns: [
              TableColumnSpec('Number', (p) => Text(p.number)),
              TableColumnSpec('Location', (p) => Text(p.locationName)),
              TableColumnSpec(
                'Orders',
                (p) => Text(p.orderNumbers.join(', ')),
                maxWidth: 220,
              ),
              TableColumnSpec('Progress', (p) => Text(progress(p))),
              TableColumnSpec('Status', (p) => StatusChip(p.status)),
            ],
            cardBuilder: (context, p) => DocListCard(
              onTap: () => open(p),
              title: p.number,
              details: '${p.locationName} · ${p.orderNumbers.join(', ')}',
              pills: StatusChip(p.status),
              amount: progress(p),
            ),
          ),
        ),
      ],
    );
  }
}

class PickListDetailScreen extends ConsumerWidget {
  const PickListDetailScreen({super.key, required this.pickListId});

  final String pickListId;

  Future<void> _action(
    BuildContext context,
    WidgetRef ref,
    String action,
    String done,
  ) async {
    try {
      await ref.read(o2cRepositoryProvider).pickListAction(pickListId, action);
      ref.read(o2cRevisionProvider.notifier).bump();
      if (context.mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final repo = ref.read(o2cRepositoryProvider);
    return AsyncValueView(
      value: ref.watch(pickListProvider(pickListId)),
      onRetry: () => ref.invalidate(pickListProvider(pickListId)),
      data: (list) {
        final s = list.summary;
        final manage = perms.can(Perm.fulfilmentManage);
        return FormPage(
          maxWidth: 1000,
          children: [
            DocHeader(
              title: s.number,
              pills: StatusChip(s.status),
              actions: [
                if (manage && s.isOpen)
                  DocAction(
                    label: 'Complete pick list',
                    icon: Icons.done_all,
                    primary: true,
                    onPressed: () => _action(
                      context,
                      ref,
                      'complete',
                      'Pick list ${s.number} completed',
                    ),
                  ),
                if (manage && s.isOpen)
                  DocAction(
                    label: 'Cancel pick list',
                    icon: Icons.block,
                    destructive: true,
                    onPressed: () => _action(
                      context,
                      ref,
                      'cancel',
                      'Pick list ${s.number} cancelled',
                    ),
                  ),
              ],
              facts: [
                LabeledValue('Location', s.locationName),
                LabeledValue('Orders', s.orderNumbers.join(', ')),
                LabeledValue(
                  'Picked',
                  '${formatQty(s.totalPicked)} of ${formatQty(s.totalTarget)}',
                ),
              ],
            ),
            if (manage && s.isOpen)
              SectionCard(
                title: 'Scan items as you pick',
                child: ScanPanel(
                  onScan: (id, code, qty) async {
                    final r = await repo.pickScan(
                      pickListId,
                      scanId: id,
                      code: code,
                      qty: qty,
                    );
                    ref.read(o2cRevisionProvider.notifier).bump();
                    return r;
                  },
                ),
              ),
            SectionCard(
              title: 'Lines',
              child: Column(
                children: [
                  for (final l in list.lines)
                    ListTile(
                      key: ValueKey('pick-line-${l.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.itemName),
                      subtitle: Text(
                        [l.orderNumber, if (l.sku != null) l.sku!].join(' · '),
                      ),
                      trailing: Text(
                        '${formatQty(l.qtyPicked)} / ${formatQty(l.qtyTarget)} '
                        '${l.unit}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: l.done
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
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
