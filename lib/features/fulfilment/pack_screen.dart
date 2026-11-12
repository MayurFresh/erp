import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../documents/document_widgets.dart';
import '../sales_orders/o2c_repository.dart';
import '../sales_orders/sales_order_models.dart';
import 'scan_panel.dart';

/// Pack station: scan each item going into the parcel, then mark the order
/// packed. Scans count towards `qtyPacked`; the server rejects wrong items
/// and over-packing.
class PackScreen extends ConsumerWidget {
  const PackScreen({super.key, required this.orderId});

  final String orderId;

  Future<void> _markPacked(
    BuildContext context,
    WidgetRef ref,
    SalesOrder o,
  ) async {
    try {
      await ref.read(o2cRepositoryProvider).pack(o.id);
      ref.read(o2cRevisionProvider.notifier).bump();
      if (context.mounted) showInfoSnackBar(context, '${o.number} packed');
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(o2cRepositoryProvider);
    return AsyncValueView(
      value: ref.watch(salesOrderProvider(orderId)),
      onRetry: () => ref.invalidate(salesOrderProvider(orderId)),
      data: (o) {
        final canScan = o.isFulfillable;
        return FormPage(
          maxWidth: 1000,
          children: [
            DocHeader(
              title: 'Pack ${o.number}',
              pills: StatusChip(o.status, label: statusLabel(o.status)),
              actions: [
                DocAction(
                  label: 'Back to order',
                  icon: Icons.arrow_back,
                  onPressed: () => context.go('/sales-orders/${o.id}'),
                ),
                if (canScan && o.toPack > 0)
                  DocAction(
                    label: 'Mark as packed',
                    icon: Icons.inventory_2_outlined,
                    primary: true,
                    onPressed: () => _markPacked(context, ref, o),
                  ),
              ],
              facts: [
                LabeledValue('Customer', o.partyName),
                LabeledValue('Location', o.locationName),
                LabeledValue('To pack', formatQty(o.toPack)),
                LabeledValue('Ready to dispatch', formatQty(o.readyToDispatch)),
              ],
            ),
            if (canScan)
              SectionCard(
                title: 'Scan items into the parcel',
                child: ScanPanel(
                  onScan: (id, code, qty) async {
                    final r = await repo.packScan(
                      o.id,
                      scanId: id,
                      code: code,
                      qty: qty,
                    );
                    ref.read(o2cRevisionProvider.notifier).bump();
                    return r;
                  },
                ),
              )
            else
              const SectionCard(
                child: Text('This order is not open for packing.'),
              ),
            SectionCard(
              title: 'Items',
              child: Column(
                children: [
                  for (final l in o.lines)
                    ListTile(
                      key: ValueKey('pack-line-${l.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.itemName),
                      subtitle: Text(
                        'Picked ${formatQty(l.qtyPicked)} · '
                        'dispatched ${formatQty(l.qtyDispatched)}',
                      ),
                      trailing: Text(
                        'Packed ${formatQty(l.qtyPacked)} / '
                        '${formatQty(l.qtyPicked)} ${l.unit}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
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
