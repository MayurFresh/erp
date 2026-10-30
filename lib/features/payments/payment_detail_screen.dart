import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_models.dart';
import '../documents/document_widgets.dart';
import 'payment_model.dart';
import 'payments_repository.dart';

/// A receipt or payment with its allocations.
class PaymentDetailScreen extends ConsumerWidget {
  const PaymentDetailScreen({super.key, required this.paymentId});

  final String paymentId;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    Payment payment,
  ) async {
    final docs = payment.kind == PaymentKind.receipt ? 'invoices' : 'bills';
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${payment.number}?',
        message:
            'Its allocations are released and the $docs become due again. '
            'This cannot be undone.',
        confirmLabel: 'Cancel ${payment.kind.label.toLowerCase()}',
        keepLabel: 'Keep it',
      ),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref.read(paymentsRepositoryProvider).cancel(paymentId, reason);
      ref.bump(moneyKinds);
      if (context.mounted) {
        showInfoSnackBar(context, '${payment.number} cancelled');
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(paymentProvider(paymentId)),
      onRetry: () => ref.invalidate(paymentProvider(paymentId)),
      data: (p) {
        final receipt = p.kind == PaymentKind.receipt;
        final canOpenDocs = perms.can(
          receipt ? Perm.invoicesView : Perm.purchasesView,
        );
        return FormPage(
          maxWidth: 1000,
          children: [
            DocHeader(
              title: p.number,
              pills: Wrap(
                spacing: 6,
                children: [
                  Pill(p.kind.label),
                  DocStatusPill(status: p.status),
                ],
              ),
              actions: [
                if (p.status == DocStatus.posted &&
                    perms.can(Perm.paymentsCancel))
                  DocAction(
                    label: 'Cancel ${p.kind.label.toLowerCase()}',
                    icon: Icons.block,
                    destructive: true,
                    primary: true,
                    onPressed: () => _cancel(context, ref, p),
                  ),
              ],
              facts: [
                LabeledValue('Date', formatDate(p.date)),
                LabeledValue(receipt ? 'Customer' : 'Vendor', p.partyName),
                LabeledValue('Amount', formatMoney(p.amount)),
                if (p.tdsAmount > 0)
                  LabeledValue(
                    'TDS deducted by customer',
                    formatMoney(p.tdsAmount),
                  ),
                LabeledValue('Mode', p.mode.label),
                LabeledValue(
                  receipt ? 'Deposited to' : 'Paid from',
                  p.accountName,
                ),
                LabeledValue('Reference', p.reference ?? ''),
                if (p.createdBy != null)
                  LabeledValue(
                    'Recorded by',
                    '${p.createdBy!.name} · ${formatDateTime(p.createdAt)}',
                  ),
              ],
            ),
            if (p.isCancelled)
              CancelledBanner(
                cancelledAt: p.cancelledAt,
                reason: p.cancelReason,
              ),
            FormRow(
              breakpoint: 760,
              children: [
                SectionCard(
                  title: receipt ? 'Invoices settled' : 'Bills settled',
                  child: p.allocations.isEmpty
                      ? const Text('Not allocated; kept as an advance.')
                      : Column(
                          children: [
                            for (final a in p.allocations)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.description_outlined),
                                title: Text(
                                  a.docNumber,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${a.docTypeLabel} · '
                                  '${formatDate(a.docDate)} · '
                                  'total ${formatMoney(a.docTotal)}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Text(formatMoney(a.amount)),
                                onTap: canOpenDocs
                                    ? () => context.push(a.route)
                                    : null,
                              ),
                          ],
                        ),
                ),
                SectionCard(
                  title: 'Amounts',
                  child: Column(
                    children: [
                      AmountRow('Amount', p.amount, bold: true),
                      if (p.tdsAmount > 0) ...[
                        AmountRow('TDS deducted by customer', p.tdsAmount),
                        AmountRow('Settles', p.amount + p.tdsAmount),
                      ],
                      AmountRow('Allocated', p.allocated),
                      AmountRow('Advance (unallocated)', p.unallocated),
                    ],
                  ),
                ),
              ],
            ),
            if (p.notes != null && p.notes!.isNotEmpty)
              SectionCard(title: 'Notes', child: Text(p.notes!)),
          ],
        );
      },
    );
  }
}
