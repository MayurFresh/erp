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
import 'item_model.dart';
import 'items_repository.dart';

class ItemsScreen extends ConsumerStatefulWidget {
  const ItemsScreen({super.key});

  @override
  ConsumerState<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends ConsumerState<ItemsScreen> {
  String _query = '';
  late final PagedController<Item> _paged = PagedController(
    (offset, limit) => ref
        .read(itemsRepositoryProvider)
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
    ref.listen(revisionProvider(DataKind.items), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);
    final showCost = perms.can(Perm.itemsViewCost);
    final canEdit = perms.can(Perm.itemsEdit);

    void open(Item item) => context.go('/items/${item.id}');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Items',
          actions: [
            if (perms.can(Perm.itemsCreate))
              FilledButton.icon(
                onPressed: () => context.go('/items/new'),
                icon: const Icon(Icons.add),
                label: const Text('New item'),
              ),
          ],
        ),
        FilterBar(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: SearchField(
                hintText: 'Search name, SKU or HSN',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Item>(
            controller: _paged,
            emptyMessage: _query.isEmpty
                ? 'No items yet.'
                : 'No items match "$_query".',
            emptyIcon: Icons.inventory_2_outlined,
            onTap: canEdit ? open : null,
            columns: [
              TableColumnSpec('Name', (i) => Text(i.name)),
              TableColumnSpec('SKU', (i) => Text(i.sku ?? '—')),
              TableColumnSpec('HSN', (i) => Text(i.hsnCode ?? '—')),
              TableColumnSpec('Unit', (i) => Text(i.unit)),
              TableColumnSpec(
                'GST',
                (i) => Text(formatPercent(i.gstRate)),
                numeric: true,
              ),
              TableColumnSpec(
                'Sale price',
                (i) => Text(formatMoney(i.salePrice)),
                numeric: true,
              ),
              if (showCost)
                TableColumnSpec(
                  'Purchase price',
                  (i) => Text(
                    i.purchasePrice == null
                        ? '—'
                        : formatMoney(i.purchasePrice),
                  ),
                  numeric: true,
                ),
              TableColumnSpec(
                'Reorder at',
                (i) => Text(i.trackStock ? formatQty(i.reorderLevel) : '—'),
                numeric: true,
              ),
              TableColumnSpec('Status', (i) => _ItemStatus(item: i)),
            ],
            cardBuilder: (context, i) => ListCard(
              onTap: canEdit ? () => open(i) : null,
              title: Row(
                children: [
                  Flexible(
                    child: Text(i.name, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  _ItemStatus(item: i),
                ],
              ),
              subtitle: Text(
                [
                  if (i.sku != null) i.sku!,
                  if (i.hsnCode != null) 'HSN ${i.hsnCode}',
                  i.unit,
                  'GST ${formatPercent(i.gstRate)}',
                ].join(' · '),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatMoney(i.salePrice)),
                  if (showCost && i.purchasePrice != null)
                    Text(
                      'Cost ${formatMoney(i.purchasePrice)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ItemStatus extends StatelessWidget {
  const _ItemStatus({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!item.isActive) return Pill('Inactive', color: scheme.outline);
    if (!item.trackStock) return Pill('Untracked', color: scheme.tertiary);
    return Pill('Active', color: Colors.green);
  }
}
