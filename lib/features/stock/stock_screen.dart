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
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../locations/location_filter.dart';
import 'adjust_stock_dialog.dart';
import 'stock_models.dart';
import 'stock_repository.dart';

class StockScreen extends ConsumerStatefulWidget {
  const StockScreen({super.key, this.initialLowOnly = false});

  final bool initialLowOnly;

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen> {
  String _query = '';
  String? _locationId;
  late bool _lowOnly = widget.initialLowOnly;
  late final PagedController<StockBalance> _paged = PagedController(
    (offset, limit) => ref
        .read(stockRepositoryProvider)
        .balances(
          locationId: _locationId,
          q: _query,
          lowOnly: _lowOnly,
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

  Future<void> _adjust() async {
    final move = await showDialog<StockMove>(
      context: context,
      builder: (_) => AdjustStockDialog(initialLocationId: _locationId),
    );
    if (move != null && mounted) showInfoSnackBar(context, 'Stock adjusted');
  }

  void _openMoves(StockBalance b) {
    final query = Uri(
      queryParameters: {
        'itemId': b.itemId,
        'locationId': b.locationId,
        'title': '${b.itemName} · ${b.locationName}',
      },
    ).query;
    context.go('/stock/moves?$query');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(revisionProvider(DataKind.stock), (_, _) => _paged.refresh());
    ref.listen(activeCompanyIdProvider, (_, _) {
      _locationId = null;
      _paged.refresh();
    });
    final perms = ref.watch(permissionsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Stock',
          actions: [
            if (perms.can(Perm.stockAdjust))
              FilledButton.icon(
                onPressed: _adjust,
                icon: const Icon(Icons.tune),
                label: const Text('Adjust stock'),
              ),
          ],
        ),
        FilterBar(
          children: [
            LocationFilter(
              value: _locationId,
              onChanged: (id) {
                setState(() => _locationId = id);
                _paged.refresh();
              },
            ),
            FilterChip(
              label: const Text('Low stock only'),
              selected: _lowOnly,
              onSelected: (v) {
                setState(() => _lowOnly = v);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search items',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: _paged,
            builder: (context, _) {
              // The value column appears only when the server sends values
              // (items.view_cost).
              final showValue = _paged.items.any((b) => b.value != null);
              return AdaptiveDataList<StockBalance>(
                controller: _paged,
                emptyMessage: _lowOnly
                    ? 'Nothing is below its reorder level.'
                    : 'No stock movements yet.',
                emptyIcon: Icons.warehouse_outlined,
                onTap: _openMoves,
                columns: [
                  TableColumnSpec('Item', (b) => Text(b.itemName)),
                  TableColumnSpec('SKU', (b) => Text(b.sku ?? '—')),
                  TableColumnSpec('Location', (b) => Text(b.locationName)),
                  TableColumnSpec(
                    'Qty',
                    (b) => _QtyText(balance: b),
                    numeric: true,
                  ),
                  TableColumnSpec(
                    'Reorder at',
                    (b) => Text(formatQty(b.reorderLevel)),
                    numeric: true,
                  ),
                  if (showValue)
                    TableColumnSpec(
                      'Value',
                      (b) => Text(b.value == null ? '—' : formatMoney(b.value)),
                      numeric: true,
                    ),
                ],
                cardBuilder: (context, b) => ListCard(
                  onTap: () => _openMoves(b),
                  title: Text(b.itemName, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      b.locationName,
                      if (b.sku != null) b.sku!,
                      if (b.value != null) 'Value ${formatMoney(b.value)}',
                    ].join(' · '),
                  ),
                  trailing: _QtyText(balance: b),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _QtyText extends StatelessWidget {
  const _QtyText({required this.balance});

  final StockBalance balance;

  @override
  Widget build(BuildContext context) {
    final low = balance.isLow;
    final color = low ? Theme.of(context).colorScheme.error : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (low) ...[
          Icon(Icons.warning_amber_rounded, size: 16, color: color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            '${formatQty(balance.qty)} ${balance.unit}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
