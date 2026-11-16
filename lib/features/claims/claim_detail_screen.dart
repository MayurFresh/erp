import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/key_value_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import 'claims_models.dart';
import 'claims_repository.dart';
import 'claims_widgets.dart';

/// `/claims/:id`
class ClaimDetailScreen extends ConsumerWidget {
  const ClaimDetailScreen({super.key, required this.claimId});

  final String claimId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(claimProvider(claimId));
    final perms = ref.watch(permissionsProvider);
    final repo = ref.read(claimsRepositoryProvider);
    void bump() => ref.read(claimsRevisionProvider.notifier).bump();

    Future<void> approve(Claim c) async {
      // 'none', 'payroll' or an account id for paying now.
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Approve claim'),
          children: [
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'none'), child: const Text('Approve only')),
            if (perms.can(Perm.claimsManage)) ...[
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'payroll'), child: const Text('Approve and add to next payroll')),
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'pay'), child: const Text('Approve and pay now')),
            ],
          ],
        ),
      );
      if (choice == null || !context.mounted) return;
      final body = <String, Object?>{};
      if (choice == 'payroll') body['mode'] = 'payroll';
      if (choice == 'pay') {
        final accounts = await repo.cashAccounts();
        if (!context.mounted) return;
        final accountId = await pickAccount(context, accounts);
        if (accountId == null) return;
        body.addAll({'mode': 'pay_now', 'accountId': accountId});
      }
      if (context.mounted && await guarded(context, () => repo.approve(c.id, body))) bump();
    }

    Future<void> reject(Claim c) async {
      final note = await askText(context, title: 'Reject claim', label: 'Reason', action: 'Reject');
      if (note == null || !context.mounted) return;
      if (await guarded(context, () => repo.reject(c.id, note))) bump();
    }

    Future<void> settle(Claim c, bool payroll) async {
      final body = <String, Object?>{'mode': payroll ? 'payroll' : 'pay_now'};
      if (!payroll) {
        final accounts = await repo.cashAccounts();
        if (!context.mounted) return;
        final accountId = await pickAccount(context, accounts);
        if (accountId == null) return;
        body['accountId'] = accountId;
      }
      if (context.mounted && await guarded(context, () => repo.settle(c.id, body))) bump();
    }

    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(claimProvider(claimId))),
      data: (c) => ListView(
        padding: EdgeInsets.symmetric(horizontal: pageGutter(context), vertical: Space.md),
        children: [
          PageHeader(
            title: c.number,
            subtitle: c.purpose,
            actions: [
              if (c.editable) ...[
                OutlinedButton(onPressed: () => context.go('/claims/${c.id}/edit'), child: const Text('Edit')),
                FilledButton(
                  onPressed: () async {
                    if (await guarded(context, () => repo.submit(c.id))) bump();
                  },
                  child: const Text('Submit'),
                ),
              ],
              if (c.canApprove) ...[
                FilledButton(onPressed: () => approve(c), child: const Text('Approve')),
                OutlinedButton(onPressed: () => reject(c), child: const Text('Reject')),
              ],
              if (c.status == 'approved' && c.settlement == null && perms.can(Perm.claimsManage)) ...[
                FilledButton(onPressed: () => settle(c, false), child: const Text('Pay now')),
                OutlinedButton(onPressed: () => settle(c, true), child: const Text('Add to payroll')),
              ],
            ],
          ),
          SectionCard(
            child: KeyValueList(items: [
              KeyValue('Status', '', widget: Align(alignment: Alignment.centerLeft, child: StatusChip(c.status))),
              KeyValue('Employee', c.employeeName),
              KeyValue('Claim date', formatDate(c.claimDate)),
              KeyValue('Total', formatMoney(c.total)),
              if (c.gstTotal > 0) KeyValue('GST in bills', formatMoney(c.gstTotal)),
              if (c.settlement != null)
                KeyValue('Settlement', c.settlement == 'payroll' ? 'With payroll' : 'Paid directly'),
              if ((c.decisionNote ?? '').isNotEmpty) KeyValue('Note', c.decisionNote!),
            ]),
          ),
          const SizedBox(height: Space.md),
          for (final l in c.lines)
            Card(
              margin: const EdgeInsets.only(bottom: Space.sm),
              child: ListTile(
                title: Text('${l.categoryName}: ${l.description}'),
                subtitle: Text([
                  formatDate(l.expenseDate),
                  if (l.gstAmount > 0) 'GST ${formatMoney(l.gstAmount)}${l.itcEligible ? ', input credit' : ''}',
                  if (l.receiptFileId != null) 'Receipt attached',
                ].join('  ')),
                trailing: MoneyText(l.amount),
                onTap: l.receiptFileId == null
                    ? null
                    : () async {
                        final bytes = await repo.fileBytes(l.receiptFileId!);
                        if (!context.mounted) return;
                        showDialog<void>(
                          context: context,
                          builder: (_) => Dialog(child: InteractiveViewer(child: Image.memory(bytes, errorBuilder: (_, _, _) => const Padding(padding: EdgeInsets.all(Space.lg), child: Text('This file is not an image.'))))),
                        );
                      },
              ),
            ),
          if (c.status == 'draft')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  if (await guarded(context, () => repo.deleteClaim(c.id))) {
                    bump();
                    if (context.mounted) context.go('/my-claims');
                  }
                },
                child: const Text('Delete draft'),
              ),
            ),
        ],
      ),
    );
  }
}
