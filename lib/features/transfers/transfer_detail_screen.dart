import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import 'transfer_model.dart';
import 'transfer_widgets.dart';
import 'transfers_repository.dart';

class TransferDetailScreen extends ConsumerWidget {
  const TransferDetailScreen({super.key, required this.transferId});

  final String transferId;

  Future<void> _receive(
    BuildContext context,
    WidgetRef ref,
    Transfer transfer,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Receive ${transfer.number}?'),
        content: Text('The goods are added to ${transfer.toLocationName}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Receive'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(transfersRepositoryProvider).receive(transferId);
      ref.bump(const [DataKind.transfers, DataKind.stock]);
      if (context.mounted) {
        showInfoSnackBar(context, '${transfer.number} received');
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    Transfer transfer,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${transfer.number}?',
        message:
            'The goods go back to ${transfer.fromLocationName}. This cannot '
            'be undone.',
        confirmLabel: 'Cancel transfer',
        keepLabel: 'Keep it',
      ),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref.read(transfersRepositoryProvider).cancel(transferId, reason);
      ref.bump(const [DataKind.transfers, DataKind.stock]);
      if (context.mounted) {
        showInfoSnackBar(context, '${transfer.number} cancelled');
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(transferProvider(transferId)),
      onRetry: () => ref.invalidate(transferProvider(transferId)),
      data: (t) => FormPage(
        maxWidth: 1000,
        children: [
          DocHeader(
            title: t.number,
            pills: TransferStatusPill(status: t.status),
            actions: [
              if (t.isInTransit && perms.can(Perm.transfersReceive))
                DocAction(
                  label: 'Receive',
                  icon: Icons.move_to_inbox_outlined,
                  primary: true,
                  onPressed: () => _receive(context, ref, t),
                ),
              if (t.isInTransit && perms.can(Perm.transfersCreate))
                DocAction(
                  label: 'Cancel transfer',
                  icon: Icons.block,
                  destructive: true,
                  primary: true,
                  onPressed: () => _cancel(context, ref, t),
                ),
            ],
            facts: [
              LabeledValue('Date', formatDate(t.transferDate)),
              LabeledValue('From', t.fromLocationName),
              LabeledValue('To', t.toLocationName),
              if (t.totalValue != null)
                LabeledValue('Value', formatMoney(t.totalValue)),
              if (t.createdBy != null)
                LabeledValue(
                  'Sent by',
                  '${t.createdBy!.name} · ${formatDateTime(t.createdAt)}',
                ),
              if (t.receivedBy != null)
                LabeledValue(
                  'Received by',
                  '${t.receivedBy!.name} · ${formatDateTime(t.receivedAt)}',
                ),
            ],
          ),
          if (t.status == TransferStatus.cancelled)
            CancelledBanner(cancelledAt: t.cancelledAt, reason: t.cancelReason),
          SectionCard(
            title: 'Items',
            child: t.lines.isEmpty
                ? const Text('No lines.')
                : Column(
                    children: [
                      for (final line in t.lines)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(
                            line.itemName,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: line.sku == null ? null : Text(line.sku!),
                          trailing: Text(
                            '${formatQty(line.qty)} ${line.unit}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                    ],
                  ),
          ),
          if (t.notes != null && t.notes!.isNotEmpty)
            SectionCard(title: 'Notes', child: Text(t.notes!)),
        ],
      ),
    );
  }
}
