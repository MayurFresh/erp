import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/business_profile.dart';

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import 'po_models.dart';
import 'po_repository.dart';
import 'po_widgets.dart';
import '../reports/pdf_actions.dart';
import 'po_pdf.dart';

class PoDetailScreen extends ConsumerWidget {
  const PoDetailScreen({super.key, required this.poId});

  final String poId;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<Object?> Function() action,
    String done,
  ) async {
    try {
      await action();
      ref.bump(poKinds);
      if (context.mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder po,
  ) async {
    final received = po.progress.received > 0;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${po.number ?? 'order'}?',
        message: received
            ? 'Goods are already received. Only the quantity still to arrive '
                  'is cancelled; the order stays open for billing what you '
                  'received.'
            : 'The order keeps its number and can no longer be received.',
        confirmLabel: 'Cancel order',
        keepLabel: 'Keep order',
      ),
    );
    if (reason == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(poRepositoryProvider).cancel(poId, reason),
      'Order ${po.number} cancelled',
    );
  }

  Future<void> _cancelReceipt(
    BuildContext context,
    WidgetRef ref,
    GoodsReceipt grn,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${grn.number}?',
        message:
            'The received stock is taken back out of the location and the '
            'goods received entry is reversed. A receipt that has been billed '
            'cannot be cancelled.',
        confirmLabel: 'Cancel receipt',
        keepLabel: 'Keep receipt',
      ),
    );
    if (reason == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(poRepositoryProvider).cancelReceipt(grn.id, reason),
      'Receipt ${grn.number} cancelled',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(purchaseOrderProvider(poId)),
      onRetry: () => ref.invalidate(purchaseOrderProvider(poId)),
      data: (po) {
        final manage = perms.can(Perm.purchaseOrdersManage);
        final receipts =
            ref.watch(goodsReceiptsProvider(poId)).value ?? const [];
        final actions = [
          ...pdfDocActions(
            context,
            ref,
            fileName: poFileName(po),
            build: (p) async => buildPurchaseOrderPdf(
              po,
              p.company,
              vendor: await p.party(po.partyId),
              brand: p.brand,
              theme: p.theme,
            ),
          ),
          if (manage && po.isDraft)
            DocAction(
              label: 'Submit',
              icon: Icons.send_outlined,
              primary: true,
              onPressed: () => _run(
                context,
                ref,
                () => ref.read(poRepositoryProvider).submit(poId),
                'Order submitted',
              ),
            ),
          if (manage && po.status == 'approved')
            DocAction(
              label: 'Mark as sent',
              icon: Icons.outgoing_mail,
              primary: true,
              onPressed: () => _run(
                context,
                ref,
                () => ref.read(poRepositoryProvider).send(poId),
                'Order marked as sent',
              ),
            ),
          if (perms.can(Perm.grnManage) && po.canReceive)
            DocAction(
              label: 'Receive goods',
              icon: Icons.move_to_inbox_outlined,
              primary: po.status != 'approved',
              onPressed: () => context.go('/purchase-orders/$poId/receive'),
            ),
          if (manage && po.isDraft)
            DocAction(
              label: 'Edit',
              icon: Icons.edit_outlined,
              onPressed: () => context.go('/purchase-orders/$poId/edit'),
            ),
          if (manage && po.canCancel)
            DocAction(
              label: 'Cancel order',
              icon: Icons.block,
              destructive: true,
              onPressed: () => _cancel(context, ref, po),
            ),
        ];
        final lines = po.lines ?? const <PoLine>[];
        return FormPage(
          maxWidth: 1100,
          children: [
            DocHeader(
              title: po.number ?? 'Purchase order',
              pills: PoStatusChip(po.status),
              actions: actions,
              facts: [
                LabeledValue('Order date', formatDate(po.orderDate)),
                if (po.expectedDate != null)
                  LabeledValue('Expected', formatDate(po.expectedDate)),
                LabeledValue('Vendor', po.partyName),
                LabeledValue('Deliver to', po.locationName),
                LabeledValue('Total', formatMoney(po.total)),
                if (po.createdBy != null)
                  LabeledValue(
                    'Created by',
                    '${po.createdBy!.name} · ${formatDateTime(po.createdAt)}',
                  ),
              ],
            ),
            if (po.status == 'pending_approval')
              Card(
                margin: const EdgeInsets.only(bottom: 16),
                child: ListTile(
                  leading: const Icon(Icons.hourglass_empty),
                  title: const Text('Waiting for approval'),
                  subtitle: const Text(
                    'The order can be sent once an approver accepts it.',
                  ),
                  trailing: po.approvalRequestId == null
                      ? null
                      : TextButton(
                          onPressed: () =>
                              context.go('/approvals/${po.approvalRequestId}'),
                          child: const Text('View request'),
                        ),
                ),
              ),
            if (po.isCancelled)
              CancelledBanner(
                cancelledAt: po.cancelledAt,
                reason: po.cancelReason,
              ),
            FormRow(
              breakpoint: 760,
              children: [
                SectionCard(
                  title: 'Progress',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      QtyProgress(
                        label: 'Received',
                        done: po.progress.received,
                        total: po.progress.ordered - po.progress.cancelled,
                      ),
                      const SizedBox(height: 12),
                      QtyProgress(
                        label: 'Billed',
                        done: po.progress.billed,
                        total: po.progress.ordered - po.progress.cancelled,
                      ),
                    ],
                  ),
                ),
                SectionCard(
                  title: 'Totals',
                  child: TaxTotals(summary: po),
                ),
              ],
            ),
            SectionCard(
              title: 'Items',
              child: PoLinesProgress(lines: lines),
            ),
            SectionCard(
              title: 'Receipts',
              child: receipts.isEmpty
                  ? const Text('Nothing received yet.')
                  : Column(
                      children: [
                        for (final g in receipts)
                          _ReceiptTile(
                            grn: g,
                            canBill: perms.can(Perm.purchasesCreate),
                            canCancel: perms.can(Perm.grnManage),
                            onCancel: () => _cancelReceipt(context, ref, g),
                          ),
                      ],
                    ),
            ),
            if ((po.bills ?? const []).isNotEmpty)
              SectionCard(
                title: 'Bills',
                child: Column(
                  children: [
                    for (final b in po.bills!)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(b.number),
                        subtitle: Text(formatDate(b.date)),
                        trailing: Text(formatMoney(b.total)),
                        onTap: perms.can(Perm.purchasesView)
                            ? () => context.go('/purchases/${b.id}')
                            : null,
                      ),
                  ],
                ),
              ),
            SectionCard(
              title: 'Vendor',
              child: Wrap(
                spacing: 32,
                runSpacing: 12,
                children: [
                  LabeledValue('Party', po.partyName),
                  LabeledValue('GSTIN', po.partyGstin ?? ''),
                  LabeledValue('Place of supply', stateLabel(po.placeOfSupply)),
                ],
              ),
            ),
            if (po.notes != null && po.notes!.isNotEmpty)
              SectionCard(title: 'Notes', child: Text(po.notes!)),
          ],
        );
      },
    );
  }
}

class _ReceiptTile extends StatelessWidget {
  const _ReceiptTile({
    required this.grn,
    required this.canBill,
    required this.canCancel,
    required this.onCancel,
  });

  final GoodsReceipt grn;
  final bool canBill;
  final bool canCancel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final billable = grn.lines.fold<double>(0, (s, l) => s + l.billableQty);
    final accepted = grn.lines.fold<double>(0, (s, l) => s + l.acceptedQty);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(grn.number, style: theme.textTheme.titleSmall),
              Text(formatDate(grn.receiptDate)),
              Text('${formatQty(accepted)} accepted'),
              if (grn.isCancelled) const Text('Cancelled'),
            ],
          ),
          if (!grn.isCancelled)
            Wrap(
              spacing: 8,
              children: [
                if (canBill && billable > 0)
                  TextButton.icon(
                    onPressed: () =>
                        context.go('/purchase-orders/receipts/${grn.id}/bill'),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: Text(context.w('Create bill')),
                  ),
                if (canCancel)
                  TextButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.block),
                    label: Text(context.w('Cancel receipt')),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
