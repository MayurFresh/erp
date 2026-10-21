import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../auth/session.dart';
import '../locations/locations_repository.dart';
import 'stock_models.dart';
import 'stock_repository.dart';

/// Movement history for an item (optionally at one location), newest first.
class StockMovesScreen extends ConsumerStatefulWidget {
  const StockMovesScreen({super.key, this.itemId, this.locationId, this.title});

  final String? itemId;
  final String? locationId;
  final String? title;

  @override
  ConsumerState<StockMovesScreen> createState() => _StockMovesScreenState();
}

class _StockMovesScreenState extends ConsumerState<StockMovesScreen> {
  late final PagedController<StockMove> _paged = PagedController(
    (offset, limit) => ref
        .read(stockRepositoryProvider)
        .moves(
          itemId: widget.itemId,
          locationId: widget.locationId,
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
    ref.listen(revisionProvider(DataKind.stock), (_, _) => _paged.refresh());
    final perms = ref.watch(permissionsProvider);
    final locations = ref.watch(locationsLookupProvider).value ?? const [];
    String locationName(String id) =>
        locations.where((l) => l.id == id).map((l) => l.name).firstOrNull ??
        '—';

    /// Opens the source document when the user may see it.
    String? target(StockMove m) {
      final route = m.refRoute;
      if (route == null) return null;
      final permission = switch (route.split('/')[1]) {
        'invoices' => Perm.invoicesView,
        'purchases' => Perm.purchasesView,
        'credit-notes' => Perm.creditNotesView,
        'transfers' => Perm.transfersView,
        _ => null,
      };
      return permission != null && perms.can(permission) ? route : null;
    }

    void open(StockMove m) {
      final route = target(m);
      if (route != null) context.push(route);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(title: 'Stock movements', subtitle: widget.title),
        Expanded(
          // Rebuilt with the rows: the value column appears only when the
          // server sends values (items.view_cost).
          child: ListenableBuilder(
            listenable: _paged,
            builder: (context, _) => AdaptiveDataList<StockMove>(
              controller: _paged,
              emptyMessage: 'No movements recorded.',
              emptyIcon: Icons.swap_vert,
              onTap: open,
              tableBreakpoint: 900,
              columns: [
                TableColumnSpec(
                  'Date',
                  (m) => Text(formatDateTime(m.createdAt)),
                ),
                TableColumnSpec('Type', (m) => Text(m.refLabel)),
                TableColumnSpec(
                  'Location',
                  (m) => Text(locationName(m.locationId)),
                ),
                TableColumnSpec(
                  'Qty',
                  (m) => _SignedQty(qty: m.qty),
                  numeric: true,
                ),
                TableColumnSpec(
                  'Cost rate',
                  (m) => Text(
                    (m.costRate ?? m.rate) == null
                        ? '—'
                        : formatMoney(m.costRate ?? m.rate),
                  ),
                  numeric: true,
                ),
                if (_paged.items.any((m) => m.value != null))
                  TableColumnSpec(
                    'Value',
                    (m) => Text(m.value == null ? '—' : formatMoney(m.value)),
                    numeric: true,
                  ),
                TableColumnSpec(
                  'Note',
                  (m) => Text(m.note ?? ''),
                  maxWidth: 220,
                ),
              ],
              cardBuilder: (context, m) => ListCard(
                onTap: target(m) == null ? null : () => open(m),
                title: Text(m.refLabel),
                subtitle: Text(
                  [
                    formatDateTime(m.createdAt),
                    locationName(m.locationId),
                    if (m.note != null && m.note!.isNotEmpty) m.note!,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _SignedQty(qty: m.qty),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SignedQty extends StatelessWidget {
  const _SignedQty({required this.qty});

  final double qty;

  @override
  Widget build(BuildContext context) {
    final positive = qty > 0;
    return Text(
      '${positive ? '+' : ''}${formatQty(qty)}',
      style: TextStyle(
        fontWeight: FontWeight.w600,
        color: positive ? Colors.green : Theme.of(context).colorScheme.error,
      ),
    );
  }
}
