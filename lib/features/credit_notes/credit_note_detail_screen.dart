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
import 'credit_note_model.dart';
import 'credit_notes_repository.dart';

class CreditNoteDetailScreen extends ConsumerWidget {
  const CreditNoteDetailScreen({super.key, required this.creditNoteId});

  final String creditNoteId;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    CreditNote note,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${note.number ?? 'credit note'}?',
        message:
            'The invoice becomes due again'
            '${note.restock ? ' and the returned stock is removed' : ''}. '
            'This cannot be undone.',
        confirmLabel: 'Cancel credit note',
        keepLabel: 'Keep it',
      ),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref
          .read(creditNotesRepositoryProvider)
          .cancel(creditNoteId, reason);
      ref.bump(const [
        DataKind.creditNotes,
        DataKind.invoices,
        DataKind.stock,
        DataKind.parties,
      ]);
      if (context.mounted) {
        showInfoSnackBar(context, 'Credit note ${note.number} cancelled');
      }
    } catch (e) {
      if (!context.mounted) return;
      if (isCancelBlocked(e)) {
        await showCancelBlocked(context, e, document: 'credit note');
      } else {
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(creditNoteProvider(creditNoteId)),
      onRetry: () => ref.invalidate(creditNoteProvider(creditNoteId)),
      data: (note) => FormPage(
        maxWidth: 1100,
        children: [
          DocHeader(
            title: note.number ?? 'Credit note',
            pills: Wrap(
              spacing: 6,
              children: [
                DocStatusPill(status: note.status),
                if (note.restock) const Pill('Restocked', color: Colors.teal),
              ],
            ),
            actions: [
              if (perms.can(Perm.invoicesView))
                DocAction(
                  label: 'Open invoice',
                  icon: Icons.receipt_long_outlined,
                  onPressed: () => context.push('/invoices/${note.invoiceId}'),
                ),
              if (note.status == DocStatus.posted &&
                  perms.can(Perm.creditNotesCancel))
                DocAction(
                  label: 'Cancel credit note',
                  icon: Icons.block,
                  destructive: true,
                  onPressed: () => _cancel(context, ref, note),
                ),
            ],
            facts: [
              LabeledValue('Date', formatDate(note.noteDate)),
              LabeledValue('Invoice', note.invoiceNumber),
              LabeledValue('Party', note.partyName),
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
                      note.restock ? 'Returned to stock' : 'Not restocked',
                    ),
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
              lines: note.lines ?? const [],
              interState: note.isInterState,
            ),
          ),
        ],
      ),
    );
  }
}
