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
import '../documents/document_widgets.dart';
import '../reports/pdf_actions.dart';
import 'purchase_return_model.dart';
import 'purchase_return_pdf.dart';
import 'purchase_returns_repository.dart';

class PurchaseReturnDetailScreen extends ConsumerWidget {
  const PurchaseReturnDetailScreen({super.key, required this.returnId});

  final String returnId;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    PurchaseReturn note,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${note.number}?',
        message:
            'The bill becomes due again'
            '${note.isGoods ? ' and the returned goods come back into stock' : ''}. '
            'This cannot be undone.',
        confirmLabel: 'Cancel debit note',
        keepLabel: 'Keep it',
      ),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref.read(purchaseReturnsRepositoryProvider).cancel(returnId, reason);
      ref.bump(const [
        DataKind.purchaseReturns,
        DataKind.purchases,
        DataKind.stock,
        DataKind.parties,
      ]);
      if (context.mounted) {
        showInfoSnackBar(context, 'Debit note ${note.number} cancelled');
      }
    } catch (e) {
      if (!context.mounted) return;
      if (isCancelBlocked(e)) {
        await showCancelBlocked(context, e, document: 'debit note');
      } else {
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(purchaseReturnProvider(returnId)),
      onRetry: () => ref.invalidate(purchaseReturnProvider(returnId)),
      data: (note) => FormPage(
        maxWidth: 1100,
        children: [
          DocHeader(
            title: note.number,
            pills: Wrap(
              spacing: 6,
              children: [
                DocStatusPill(status: note.status),
                Pill(note.isGoods ? 'Goods returned' : 'Price reduction'),
                if (note.reverseCharge)
                  const Pill('Reverse charge', color: Colors.purple),
              ],
            ),
            actions: [
              ...pdfDocActions(
                context,
                ref,
                fileName: purchaseReturnFileName(note),
                build: (p) async => buildPurchaseReturnPdf(
                  note,
                  p.company,
                  party: await p.party(note.partyId),
                  brand: p.brand,
                  theme: p.theme,
                ),
              ),
              DocAction(
                label: 'Open bill',
                icon: Icons.receipt_long_outlined,
                onPressed: () => context.push('/purchases/${note.purchaseId}'),
              ),
              if (!note.isCancelled && perms.can(Perm.purchasesCancel))
                DocAction(
                  label: 'Cancel debit note',
                  icon: Icons.block,
                  destructive: true,
                  onPressed: () => _cancel(context, ref, note),
                ),
            ],
            facts: [
              LabeledValue('Date', formatDate(note.returnDate)),
              LabeledValue('Bill', note.purchaseNumber),
              LabeledValue('Vendor', note.partyName),
              LabeledValue('Location', note.locationName),
              LabeledValue('Total', formatMoney(note.total)),
              if (note.createdBy != null)
                LabeledValue(
                  'Created by',
                  '${note.createdBy!.name} · ${formatDateTime(note.createdAt)}',
                ),
            ],
          ),
          if (note.isCancelled)
            CancelledBanner(
              cancelledAt: note.cancelledAt,
              reason: note.cancelReason,
            ),
          FormRow(
            breakpoint: 760,
            children: [
              SectionCard(
                title: 'Return',
                child: Wrap(
                  spacing: 32,
                  runSpacing: 12,
                  children: [
                    LabeledValue('Reason', note.reason),
                    LabeledValue(
                      'Stock',
                      note.isGoods
                          ? 'Taken out, ${formatMoney(note.stockValue)} at cost'
                          : 'Not moved',
                    ),
                    LabeledValue(
                      'Set against the bill',
                      formatMoney(note.appliedAmount),
                    ),
                    if (note.tdsReversed > 0)
                      LabeledValue('TDS reversed', formatMoney(note.tdsReversed)),
                    LabeledValue(
                      'Place of supply',
                      stateLabel(note.placeOfSupply),
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Totals',
                child: TaxTotals(summary: note),
              ),
            ],
          ),
          SectionCard(
            title: 'Lines',
            child: TaxLinesView(
              lines: note.taxLines,
              interState: note.isInterState,
            ),
          ),
        ],
      ),
    );
  }
}
