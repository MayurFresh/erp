import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/activity_timeline.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../fulfilment/fulfilment_models.dart';
import '../returns/return_models.dart';
import 'dispatch_dialog.dart';
import 'o2c_repository.dart';
import 'sales_order_models.dart';
import '../reports/pdf_actions.dart';
import 'sales_order_pdf.dart';
import '../../widgets/form_support.dart';

class SalesOrderDetailScreen extends ConsumerWidget {
  const SalesOrderDetailScreen({super.key, required this.orderId});

  final String orderId;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<Object?> Function() action,
    String done, {
    List<DataKind> also = const [],
  }) async {
    try {
      await action();
      ref.read(o2cRevisionProvider.notifier).bump();
      if (also.isNotEmpty) ref.bump(also);
      if (context.mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    SalesOrder o,
  ) async {
    final reason = await showFormDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${o.number}?',
        message:
            'Reserved stock is released. Anything already dispatched stays '
            'with its invoice.',
        confirmLabel: 'Cancel order',
      ),
    );
    if (reason == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref
          .read(o2cRepositoryProvider)
          .orderAction(o.id, 'cancel', body: {'reason': reason}),
      'Order ${o.number} cancelled',
      also: const [DataKind.stock],
    );
  }

  Future<void> _dispatch(
    BuildContext context,
    WidgetRef ref,
    SalesOrder o,
  ) async {
    final shipment = await showFormDialog<Shipment>(
      context: context,
      builder: (_) => DispatchDialog(order: o),
    );
    if (shipment == null || !context.mounted) return;
    ref.read(o2cRevisionProvider.notifier).bump();
    ref.bump(const [DataKind.stock, DataKind.invoices, DataKind.parties]);
    showInfoSnackBar(context, 'Dispatched as ${shipment.number}');
  }

  Future<void> _pickList(
    BuildContext context,
    WidgetRef ref,
    SalesOrder o,
  ) async {
    try {
      final list = await ref.read(o2cRepositoryProvider).createPickList(
        o.locationId,
        [o.id],
      );
      ref.read(o2cRevisionProvider.notifier).bump();
      if (context.mounted) context.go('/pick-lists/${list.summary.id}');
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final repo = ref.read(o2cRepositoryProvider);
    return AsyncValueView(
      value: ref.watch(salesOrderProvider(orderId)),
      onRetry: () => ref.invalidate(salesOrderProvider(orderId)),
      data: (o) {
        final manage = perms.can(Perm.salesOrdersManage);
        final fulfil = perms.can(Perm.fulfilmentManage);
        final anyDispatched = o.lines.any(
          (l) => l.qtyDispatched - l.qtyReturned > 0,
        );
        return FormPage(
          maxWidth: 1100,
          children: [
            DocHeader(
              title: o.number,
              pills: Wrap(
                spacing: 6,
                children: [
                  StatusChip(o.status, label: statusLabel(o.status)),
                  if (o.totalShort > 0 && o.isFulfillable)
                    const Pill('Short of stock', color: Colors.orange),
                ],
              ),
              actions: [
                ...pdfDocActions(
                  context,
                  ref,
                  fileName: salesOrderFileName(o),
                  build: (p) async => buildSalesOrderPdf(
                    o,
                    p.company,
                    party: await p.party(o.partyId),
                    brand: p.brand,
                    theme: p.theme,
                  ),
                ),
                if (manage && o.isDraft)
                  DocAction(
                    label: 'Confirm order',
                    icon: Icons.check_circle_outline,
                    primary: true,
                    onPressed: () => _run(
                      context,
                      ref,
                      () => repo.orderAction(o.id, 'confirm'),
                      'Order ${o.number} confirmed',
                      also: const [DataKind.stock],
                    ),
                  ),
                if (manage && o.isDraft)
                  DocAction(
                    label: 'Edit',
                    icon: Icons.edit_outlined,
                    onPressed: () => context.go('/sales-orders/${o.id}/edit'),
                  ),
                if (fulfil && o.isFulfillable && o.unpicked > 0)
                  DocAction(
                    label: 'Create pick list',
                    icon: Icons.list_alt_outlined,
                    primary: true,
                    onPressed: () => _pickList(context, ref, o),
                  ),
                if (fulfil && o.isFulfillable && o.toPack > 0)
                  DocAction(
                    label: 'Pack',
                    icon: Icons.inventory_2_outlined,
                    primary: true,
                    onPressed: () => context.go('/sales-orders/${o.id}/pack'),
                  ),
                if (fulfil && o.isFulfillable && o.readyToDispatch > 0)
                  DocAction(
                    label: 'Dispatch',
                    icon: Icons.local_shipping_outlined,
                    primary: true,
                    onPressed: () => _dispatch(context, ref, o),
                  ),
                if (manage && o.isFulfillable && o.totalShort > 0)
                  DocAction(
                    label: 'Reserve stock',
                    icon: Icons.bookmark_add_outlined,
                    onPressed: () => _run(
                      context,
                      ref,
                      () => repo.orderAction(o.id, 'reserve'),
                      'Stock reserved where available',
                      also: const [DataKind.stock],
                    ),
                  ),
                if (perms.can(Perm.returnsManage) && anyDispatched)
                  DocAction(
                    label: 'Raise return',
                    icon: Icons.assignment_return_outlined,
                    onPressed: () =>
                        context.go('/sales-returns/new?orderId=${o.id}'),
                  ),
                if (manage && o.status == 'dispatched')
                  DocAction(
                    label: 'Close order',
                    icon: Icons.lock_outline,
                    onPressed: () => _run(
                      context,
                      ref,
                      () => repo.orderAction(o.id, 'close'),
                      'Order ${o.number} closed',
                    ),
                  ),
                if (manage && o.canCancel)
                  DocAction(
                    label: 'Cancel order',
                    icon: Icons.block,
                    destructive: true,
                    onPressed: () => _cancel(context, ref, o),
                  ),
              ],
              facts: [
                LabeledValue('Customer', o.partyName),
                LabeledValue('Order date', formatDate(o.orderDate)),
                if (o.expectedDate != null)
                  LabeledValue('Expected', formatDate(o.expectedDate)),
                LabeledValue('Location', o.locationName),
                if (o.externalRef != null)
                  LabeledValue('Reference', o.externalRef!),
                LabeledValue('Total', formatMoney(o.total)),
              ],
            ),
            if (o.status == 'cancelled' && o.cancelReason != null)
              SectionCard(title: 'Cancelled', child: Text(o.cancelReason!)),
            if (o.notes != null)
              SectionCard(title: 'Notes', child: Text(o.notes!)),
            SectionCard(
              title: 'Items by stage',
              child: _StageLines(lines: o.lines),
            ),
            if (o.shipments.isNotEmpty || o.returns.isNotEmpty)
              FormRow(
                breakpoint: 760,
                children: [
                  SectionCard(
                    title: 'Shipments',
                    child: _LinkedList(
                      docs: o.shipments,
                      empty: 'Nothing dispatched yet.',
                      pathFor: (d) => '/shipments/${d.id}',
                      labelFor: (s) => shipmentStatuses[s] ?? s,
                    ),
                  ),
                  SectionCard(
                    title: 'Returns',
                    child: _LinkedList(
                      docs: o.returns,
                      empty: 'No returns.',
                      pathFor: (d) => '/sales-returns/${d.id}',
                      labelFor: (s) => returnStatuses[s] ?? s,
                    ),
                  ),
                ],
              ),
            SectionCard(
              title: 'Timeline',
              child: o.events.isEmpty
                  ? const Text('No activity yet.')
                  : ActivityTimeline(
                      events: [
                        for (final e in o.events.reversed)
                          TimelineEvent(
                            title: e.message,
                            detail: e.by,
                            when: e.createdAt == null
                                ? null
                                : formatDateTime(e.createdAt),
                            tone: e.kind.contains('cancel')
                                ? StatusTone.danger
                                : StatusTone.neutral,
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

class _LinkedList extends StatelessWidget {
  const _LinkedList({
    required this.docs,
    required this.empty,
    required this.pathFor,
    required this.labelFor,
  });

  final List<LinkedDoc> docs;
  final String empty;
  final String Function(LinkedDoc) pathFor;
  final String Function(String status) labelFor;

  @override
  Widget build(BuildContext context) {
    if (docs.isEmpty) return Text(empty);
    return Column(
      children: [
        for (final d in docs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(d.number),
            subtitle: (d.detail ?? '').isEmpty ? null : Text(d.detail!),
            trailing: StatusChip(d.status, label: labelFor(d.status)),
            onTap: () => context.go(pathFor(d)),
          ),
      ],
    );
  }
}

/// Quantity at each stage: a table on wide screens, cards on narrow ones.
class _StageLines extends StatelessWidget {
  const _StageLines({required this.lines});

  final List<SalesOrderLine> lines;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 760) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth),
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Item')),
                  DataColumn(label: Text('Ordered'), numeric: true),
                  DataColumn(label: Text('Reserved'), numeric: true),
                  DataColumn(label: Text('Picked'), numeric: true),
                  DataColumn(label: Text('Packed'), numeric: true),
                  DataColumn(label: Text('Dispatched'), numeric: true),
                  DataColumn(label: Text('Returned'), numeric: true),
                  DataColumn(label: Text('Short'), numeric: true),
                  DataColumn(label: Text('Amount'), numeric: true),
                ],
                rows: [
                  for (final l in lines)
                    DataRow(
                      cells: [
                        DataCell(Text(l.itemName)),
                        DataCell(Text(formatQty(l.qtyOrdered))),
                        DataCell(Text(formatQty(l.qtyReserved))),
                        DataCell(Text(formatQty(l.qtyPicked))),
                        DataCell(Text(formatQty(l.qtyPacked))),
                        DataCell(Text(formatQty(l.qtyDispatched))),
                        DataCell(Text(formatQty(l.qtyReturned))),
                        DataCell(Text(formatQty(l.qtyShort))),
                        DataCell(Text(formatMoney(l.amount))),
                      ],
                    ),
                ],
              ),
            ),
          );
        }
        final theme = Theme.of(context);
        return Column(
          children: [
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.itemName, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 20,
                      runSpacing: 8,
                      children: [
                        LabeledValue('Ordered', formatQty(l.qtyOrdered)),
                        LabeledValue('Reserved', formatQty(l.qtyReserved)),
                        LabeledValue('Picked', formatQty(l.qtyPicked)),
                        LabeledValue('Packed', formatQty(l.qtyPacked)),
                        LabeledValue('Dispatched', formatQty(l.qtyDispatched)),
                        if (l.qtyReturned > 0)
                          LabeledValue('Returned', formatQty(l.qtyReturned)),
                        if (l.qtyShort > 0)
                          LabeledValue('Short', formatQty(l.qtyShort)),
                        LabeledValue('Amount', formatMoney(l.amount)),
                      ],
                    ),
                    const Divider(height: 16),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
