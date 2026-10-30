import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import '../documents/document_widgets.dart';
import 'purchase_model.dart';
import 'purchases_repository.dart';

class PurchaseDetailScreen extends ConsumerWidget {
  const PurchaseDetailScreen({super.key, required this.purchaseId});

  final String purchaseId;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    Purchase bill,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${bill.number ?? 'bill'}?',
        message:
            'The bill keeps its number and its stock is taken back out of '
            'the location. This cannot be undone.',
        confirmLabel: 'Cancel bill',
        keepLabel: 'Keep bill',
      ),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref.read(purchasesRepositoryProvider).cancel(purchaseId, reason);
      ref.bump(const [DataKind.purchases, DataKind.stock, DataKind.parties]);
      if (context.mounted) {
        showInfoSnackBar(context, 'Bill ${bill.number} cancelled');
      }
    } catch (e) {
      if (!context.mounted) return;
      if (isCancelBlocked(e)) {
        await showCancelBlocked(
          context,
          e,
          document: 'bill',
          settlements: bill.settlements ?? const [],
        );
      } else {
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(purchaseProvider(purchaseId)),
      onRetry: () => ref.invalidate(purchaseProvider(purchaseId)),
      data: (bill) {
        final posted = bill.status == DocStatus.posted;
        final actions = [
          if (posted && bill.amountDue > 0 && perms.can(Perm.paymentsCreate))
            DocAction(
              label: 'Record payment',
              icon: Icons.payments_outlined,
              primary: true,
              onPressed: () => context.push(
                Uri(
                  path: '/payments/new',
                  queryParameters: {
                    'partyId': bill.partyId,
                    'docId': purchaseId,
                    'amount': formatPlain(bill.amountDue),
                  },
                ).toString(),
              ),
            ),
          if (posted && perms.can(Perm.purchasesCancel))
            DocAction(
              label: 'Cancel bill',
              icon: Icons.block,
              destructive: true,
              onPressed: () => _cancel(context, ref, bill),
            ),
        ];
        return FormPage(
          maxWidth: 1100,
          children: [
            DocHeader(
              title: bill.number ?? 'Purchase bill',
              pills: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  DocPills(
                    status: bill.status,
                    paymentStatus: bill.paymentStatus,
                  ),
                  if (bill.msmeCategory != null)
                    Pill(
                      'MSME ${bill.msmeCategory}',
                      color: bill.isMsmeMicroSmall ? Colors.deepOrange : null,
                    ),
                  if (bill.reverseCharge)
                    const Pill('Reverse charge', color: Colors.purple),
                ],
              ),
              actions: actions,
              facts: [
                LabeledValue('Bill date', formatDate(bill.billDate)),
                if (bill.dueDate != null)
                  LabeledValue('Due date', formatDate(bill.dueDate)),
                if (bill.msmeDueDate != null)
                  LabeledValue('MSME due date', formatDate(bill.msmeDueDate)),
                if (bill.tdsSectionCode != null)
                  LabeledValue(
                    'TDS',
                    '${bill.tdsSectionCode} @ ${formatPercent(bill.tdsRate)}'
                        ' = ${formatMoney(bill.tdsAmount)}',
                  ),
                if (bill.rcmSelfInvoiceNo != null)
                  LabeledValue('RCM self-invoice', bill.rcmSelfInvoiceNo!),
                LabeledValue('Supplier invoice', bill.supplierInvoiceNo ?? ''),
                if (bill.supplierInvoiceDate != null)
                  LabeledValue(
                    'Supplier invoice date',
                    formatDate(bill.supplierInvoiceDate),
                  ),
                LabeledValue('Location', bill.locationName),
                LabeledValue('Total', formatMoney(bill.total)),
                if (bill.tdsAmount > 0)
                  LabeledValue('Net payable', formatMoney(bill.payable)),
                if (posted)
                  LabeledValue('Amount due', formatMoney(bill.amountDue)),
                if (bill.createdBy != null)
                  LabeledValue(
                    'Created by',
                    '${bill.createdBy!.name} · '
                        '${formatDateTime(bill.createdAt)}',
                  ),
              ],
            ),
            if (bill.isCancelled)
              CancelledBanner(
                cancelledAt: bill.cancelledAt,
                reason: bill.cancelReason,
              ),
            FormRow(
              breakpoint: 760,
              children: [
                SectionCard(
                  title: 'Vendor',
                  child: Wrap(
                    spacing: 32,
                    runSpacing: 12,
                    children: [
                      LabeledValue('Party', bill.partyName),
                      LabeledValue('GSTIN', bill.partyGstin ?? ''),
                      LabeledValue(
                        'Place of supply',
                        stateLabel(bill.placeOfSupply),
                      ),
                      LabeledValue(
                        'Input tax',
                        bill.isInterState ? 'IGST' : 'CGST + SGST',
                      ),
                    ],
                  ),
                ),
                SectionCard(
                  title: 'Totals',
                  child: TaxTotals(
                    summary: bill,
                    amountPaid: posted ? bill.amountPaid : null,
                    amountDue: posted ? bill.amountDue : null,
                  ),
                ),
              ],
            ),
            if (bill.settlements != null)
              SectionCard(
                title: 'Payments',
                child: SettlementsList(
                  settlements: bill.settlements!,
                  canOpen: (_) => perms.can(Perm.paymentsView),
                ),
              ),
            SectionCard(
              title: 'Lines',
              child: TaxLinesView(
                lines: bill.lines ?? const [],
                interState: bill.isInterState,
              ),
            ),
            if (bill.notes != null && bill.notes!.isNotEmpty)
              SectionCard(title: 'Notes', child: Text(bill.notes!)),
          ],
        );
      },
    );
  }
}
