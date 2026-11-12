import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/activity_timeline.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../sales_orders/o2c_repository.dart';
import 'fulfilment_models.dart';

String shipmentLabel(String s) => shipmentStatuses[s] ?? s;

class ShipmentsScreen extends ConsumerStatefulWidget {
  const ShipmentsScreen({super.key});

  @override
  ConsumerState<ShipmentsScreen> createState() => _ShipmentsScreenState();
}

class _ShipmentsScreenState extends ConsumerState<ShipmentsScreen> {
  String _query = '';
  String? _status;
  late final PagedController<Shipment> _paged = PagedController(
    (offset, limit) => ref
        .read(o2cRepositoryProvider)
        .shipments(q: _query, status: _status, offset: offset, limit: limit),
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
    void open(Shipment s) => context.go('/shipments/${s.id}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Shipments',
          subtitle: 'Track parcels from dispatch to delivery',
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Status',
              value: _status,
              width: 220,
              options: shipmentStatuses,
              onChanged: (v) {
                setState(() => _status = v);
                _paged.refresh();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SearchField(
                hintText: 'Search number, order or tracking number',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Shipment>(
            controller: _paged,
            emptyMessage: 'No shipments found.',
            emptyIcon: Icons.local_shipping_outlined,
            onTap: open,
            tableBreakpoint: 1000,
            columns: [
              TableColumnSpec('Number', (s) => Text(s.number)),
              TableColumnSpec('Order', (s) => Text(s.orderNumber)),
              TableColumnSpec(
                'Customer',
                (s) => Text(s.partyName),
                maxWidth: 200,
              ),
              TableColumnSpec('Courier', (s) => Text(s.courier ?? '—')),
              TableColumnSpec('Tracking', (s) => Text(s.awb ?? '—')),
              TableColumnSpec(
                'Status',
                (s) => StatusChip(s.status, label: shipmentLabel(s.status)),
              ),
              TableColumnSpec(
                'Invoice',
                (s) => Text(formatMoney(s.invoiceTotal)),
                numeric: true,
              ),
            ],
            cardBuilder: (context, s) => DocListCard(
              onTap: () => open(s),
              title: s.number,
              details:
                  '${s.partyName} · ${s.orderNumber}'
                  '${s.awb == null ? '' : ' · ${s.awb}'}',
              pills: StatusChip(s.status, label: shipmentLabel(s.status)),
              amount: formatMoney(s.invoiceTotal),
            ),
          ),
        ),
      ],
    );
  }
}

class ShipmentDetailScreen extends ConsumerWidget {
  const ShipmentDetailScreen({super.key, required this.shipmentId});

  final String shipmentId;

  Future<void> _update(BuildContext context, WidgetRef ref, Shipment s) async {
    final result = await showFormDialog<_StatusChange>(
      context: context,
      builder: (_) => _StatusDialog(shipment: s),
    );
    if (result == null || !context.mounted) return;
    try {
      await ref
          .read(o2cRepositoryProvider)
          .shipmentStatus(
            s.id,
            status: result.status,
            note: result.note,
            courier: result.courier,
            awb: result.awb,
          );
      ref.read(o2cRevisionProvider.notifier).bump();
      if (context.mounted) {
        showInfoSnackBar(
          context,
          'Shipment ${s.number} is now ${shipmentLabel(result.status)}',
        );
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(shipmentProvider(shipmentId)),
      onRetry: () => ref.invalidate(shipmentProvider(shipmentId)),
      data: (s) => FormPage(
        maxWidth: 1000,
        children: [
          DocHeader(
            title: s.number,
            pills: StatusChip(s.status, label: shipmentLabel(s.status)),
            actions: [
              if (perms.can(Perm.fulfilmentManage) &&
                  nextShipmentStatuses(s.status).isNotEmpty)
                DocAction(
                  label: 'Update status',
                  icon: Icons.sync_alt,
                  primary: true,
                  onPressed: () => _update(context, ref, s),
                ),
              DocAction(
                label: 'Open order',
                icon: Icons.shopping_bag_outlined,
                onPressed: () => context.go('/sales-orders/${s.orderId}'),
              ),
              if (s.returnId != null)
                DocAction(
                  label: 'Open return',
                  icon: Icons.assignment_return_outlined,
                  onPressed: () => context.go('/sales-returns/${s.returnId}'),
                ),
            ],
            facts: [
              LabeledValue('Order', s.orderNumber),
              LabeledValue('Customer', s.partyName),
              LabeledValue('Courier', s.courier ?? 'Not set'),
              LabeledValue('Tracking number', s.awb ?? 'Not set'),
              LabeledValue(
                'Payment',
                s.mode == 'cod'
                    ? 'Cash on delivery ${formatMoney(s.codAmount)}'
                    : 'Prepaid',
              ),
              if (s.invoiceNumber != null)
                LabeledValue('Invoice', s.invoiceNumber!),
            ],
          ),
          SectionCard(
            title: 'Items',
            child: Column(
              children: [
                for (final l in s.lines)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.itemName),
                    trailing: Text('${formatQty(l.qty)} ${l.unit}'),
                  ),
              ],
            ),
          ),
          SectionCard(
            title: 'Tracking history',
            child: s.history.isEmpty
                ? const Text('No updates yet.')
                : ActivityTimeline(
                    events: [
                      for (final h in s.history.reversed)
                        TimelineEvent(
                          title: shipmentLabel(h.status),
                          detail: [
                            if (h.note != null) h.note!,
                            if (h.by != null) h.by!,
                          ].join(' · '),
                          when: h.at == null ? null : formatDateTime(h.at),
                          tone: switch (h.status) {
                            'delivered' => StatusTone.success,
                            'lost' || 'rto_initiated' => StatusTone.danger,
                            _ => StatusTone.neutral,
                          },
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatusChange {
  const _StatusChange(this.status, this.note, this.courier, this.awb);
  final String status;
  final String? note;
  final String? courier;
  final String? awb;
}

class _StatusDialog extends StatefulWidget {
  const _StatusDialog({required this.shipment});

  final Shipment shipment;

  @override
  State<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<_StatusDialog> {
  late String _status = nextShipmentStatuses(widget.shipment.status).first;
  late final _courier = TextEditingController(text: widget.shipment.courier);
  late final _awb = TextEditingController(text: widget.shipment.awb);
  final _note = TextEditingController();

  @override
  void dispose() {
    _courier.dispose();
    _awb.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Update shipment status'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'New status'),
                items: [
                  for (final s in nextShipmentStatuses(widget.shipment.status))
                    DropdownMenuItem(value: s, child: Text(shipmentLabel(s))),
                ],
                onChanged: (v) => setState(() => _status = v ?? _status),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _courier,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Courier'),
              ),
              TextField(
                controller: _awb,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Tracking number'),
              ),
              TextField(
                controller: _note,
                maxLength: 300,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _StatusChange(
              _status,
              trimmedOrNull(_note.text),
              trimmedOrNull(_courier.text),
              trimmedOrNull(_awb.text),
            ),
          ),
          child: const Text('Update'),
        ),
      ],
    );
  }
}
