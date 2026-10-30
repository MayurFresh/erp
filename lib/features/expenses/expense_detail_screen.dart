import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import '../documents/document_widgets.dart';
import 'expense_model.dart';
import 'expenses_repository.dart';

class ExpenseDetailScreen extends ConsumerWidget {
  const ExpenseDetailScreen({super.key, required this.expenseId});

  final String expenseId;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    Expense expense,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${expense.number}?',
        message:
            'A reversing entry puts the money back in '
            '${expense.paidFromAccountName}. This cannot be undone.',
        confirmLabel: 'Cancel expense',
        keepLabel: 'Keep it',
      ),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref.read(expensesRepositoryProvider).cancel(expenseId, reason);
      ref.bump(const [DataKind.expenses, DataKind.accounts]);
      if (context.mounted) {
        showInfoSnackBar(context, '${expense.number} cancelled');
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(expenseProvider(expenseId)),
      onRetry: () => ref.invalidate(expenseProvider(expenseId)),
      data: (e) => FormPage(
        maxWidth: 900,
        children: [
          DocHeader(
            title: e.number,
            pills: Wrap(
              spacing: 6,
              children: [
                DocStatusPill(status: e.status),
                if (e.reverseCharge)
                  const Pill('Reverse charge', color: Colors.purple),
              ],
            ),
            actions: [
              if (e.status == DocStatus.posted &&
                  perms.can(Perm.expensesCancel))
                DocAction(
                  label: 'Cancel expense',
                  icon: Icons.block,
                  destructive: true,
                  primary: true,
                  onPressed: () => _cancel(context, ref, e),
                ),
            ],
            facts: [
              LabeledValue('Date', formatDate(e.expenseDate)),
              LabeledValue('Expense head', e.accountName),
              LabeledValue('Location', e.locationName),
              LabeledValue('Paid from', e.paidFromAccountName),
              LabeledValue('Vendor', e.partyName ?? ''),
              if (e.createdBy != null)
                LabeledValue(
                  'Recorded by',
                  '${e.createdBy!.name} · ${formatDateTime(e.createdAt)}',
                ),
            ],
          ),
          if (e.isCancelled)
            CancelledBanner(cancelledAt: e.cancelledAt, reason: e.cancelReason),
          SectionCard(title: 'Description', child: Text(e.description)),
          SectionCard(
            title: 'Amount',
            child: Column(
              children: [
                AmountRow('Amount before GST', e.amount),
                if (e.igst != 0)
                  AmountRow('IGST @ ${formatPercent(e.gstRate)}', e.igst)
                else ...[
                  AmountRow('CGST @ ${formatPercent(e.gstRate / 2)}', e.cgst),
                  AmountRow('SGST @ ${formatPercent(e.gstRate / 2)}', e.sgst),
                ],
                const Divider(),
                AmountRow('Total', e.total, emphasize: true),
                if (e.tdsAmount > 0) ...[
                  AmountRow(
                    'TDS ${e.tdsSectionCode ?? ''} @ ${formatPercent(e.tdsRate)}',
                    -e.tdsAmount,
                  ),
                  AmountRow('Net paid', e.paid, emphasize: true),
                ],
                if (e.reverseCharge) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Reverse charge: the GST above is paid by you directly, '
                      'not added to the amount paid.'
                      '${e.rcmSelfInvoiceNo == null ? '' : '\nSelf-invoice ${e.rcmSelfInvoiceNo}'}',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
