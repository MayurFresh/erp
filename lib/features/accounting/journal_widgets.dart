import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart' show CancelReasonDialog;
import '../reports/report_widgets.dart' show tabularFigures;
import 'account_dialog.dart' show dialogInset;
import 'accounting_models.dart';
import 'accounting_repository.dart';

/// Permission needed to open the source document of [voucherType].
String? voucherViewPermission(String voucherType) => switch (voucherType) {
  'sales' => Perm.invoicesView,
  'purchase' => Perm.purchasesView,
  'receipt' || 'payment' => Perm.paymentsView,
  'credit_note' => Perm.creditNotesView,
  'expense' => Perm.expensesView,
  'transfer' => Perm.transfersView,
  _ => null,
};

/// The source document route when the user may open it.
String? openableDocumentRoute(
  PermissionSet permissions,
  String voucherType,
  String? route,
) {
  final permission = voucherViewPermission(voucherType);
  if (route == null || permission == null) return null;
  return permissions.can(permission) ? route : null;
}

/// Voucher type as a coloured pill.
class VoucherPill extends StatelessWidget {
  const VoucherPill(this.voucherType, {super.key, this.reversal = false});

  final String voucherType;
  final bool reversal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        Pill(
          voucherTypeLabel(voucherType),
          color: voucherType == 'journal' ? scheme.tertiary : scheme.primary,
        ),
        if (reversal) Pill('Reversal', color: scheme.error),
      ],
    );
  }
}

/// An entry's lines: account, party, debit and credit, then totals. Stacks
/// to account + "Dr/Cr amount" rows when narrow.
class JournalLinesView extends StatelessWidget {
  const JournalLinesView({super.key, required this.entry});

  final JournalEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final bold = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final number = theme.textTheme.bodyMedium?.merge(tabularFigures);
    final hasParty = entry.lines.any((l) => l.partyName != null);
    String amount(double v) => v == 0 ? '' : formatMoney(v);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final line in entry.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              line.accountLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (line.partyName != null)
                              Text(
                                line.partyName!,
                                style: muted,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        line.debit != 0
                            ? 'Dr ${formatMoney(line.debit)}'
                            : 'Cr ${formatMoney(line.credit)}',
                        style: number,
                      ),
                    ],
                  ),
                ),
              const Divider(height: 12),
              Row(
                children: [
                  Expanded(child: Text('Total', style: bold)),
                  Text(
                    formatMoney(entry.totalDebit),
                    style: bold?.merge(tabularFigures),
                  ),
                ],
              ),
            ],
          );
        }
        TableRow row(List<Widget> cells, {Decoration? decoration}) =>
            TableRow(
              decoration: decoration,
              children: [
                for (final cell in cells)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: cell,
                  ),
              ],
            );
        Widget right(String text, [TextStyle? style]) => Text(
          text,
          textAlign: TextAlign.right,
          style: (style ?? number)?.merge(tabularFigures),
        );
        return Table(
          columnWidths: {
            0: const FlexColumnWidth(3),
            if (hasParty) 1: const FlexColumnWidth(2),
            (hasParty ? 2 : 1): const IntrinsicColumnWidth(flex: 1),
            (hasParty ? 3 : 2): const IntrinsicColumnWidth(flex: 1),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            row(
              [
                Text('Account', style: muted),
                if (hasParty) Text('Party', style: muted),
                right('Debit', muted),
                right('Credit', muted),
              ],
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: theme.dividerColor),
                ),
              ),
            ),
            for (final line in entry.lines)
              row([
                Text(line.accountLabel, overflow: TextOverflow.ellipsis),
                if (hasParty)
                  Text(line.partyName ?? '', overflow: TextOverflow.ellipsis),
                right(amount(line.debit)),
                right(amount(line.credit)),
              ]),
            row(
              [
                Text('Total', style: bold),
                if (hasParty) const SizedBox.shrink(),
                right(formatMoney(entry.totalDebit), bold),
                right(formatMoney(entry.totalCredit), bold),
              ],
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Asks for a reason and cancels a manual journal (posting a reversal).
/// Returns the reversing entry, or `null` if the user backed out or it
/// failed (the error is shown).
Future<JournalEntry?> cancelJournal(
  BuildContext context,
  WidgetRef ref,
  JournalEntry entry,
) async {
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => CancelReasonDialog(
      title: 'Cancel ${entry.number ?? 'journal'}?',
      message:
          'A reversing journal is posted today with the opposite debits and '
          'credits. The original stays in the day book. This cannot be '
          'undone.',
      confirmLabel: 'Cancel journal',
      keepLabel: 'Keep journal',
    ),
  );
  if (reason == null || !context.mounted) return null;
  try {
    final reversal = await ref
        .read(accountingRepositoryProvider)
        .cancelJournal(entry.id, reason);
    ref.bump(const [DataKind.accounts]);
    if (context.mounted) {
      showInfoSnackBar(
        context,
        '${entry.number ?? 'Journal'} cancelled'
        '${reversal.number == null ? '' : ' — reversed by ${reversal.number}'}',
      );
    }
    return reversal;
  } catch (e) {
    if (!context.mounted) return null;
    final api = apiError(e);
    if (api?.code == ApiException.alreadyCancelled) {
      showInfoSnackBar(context, api!.message);
    } else {
      showErrorSnackBar(context, e);
    }
    return null;
  }
}

/// Loads `GET /journals/:id` and shows the entry with its lines.
Future<void> showJournalEntryDialog(BuildContext context, String entryId) =>
    showDialog<void>(
      context: context,
      builder: (_) => _JournalEntryDialog(entryId: entryId),
    );

class _JournalEntryDialog extends ConsumerWidget {
  const _JournalEntryDialog({required this.entryId});

  final String entryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(journalEntryProvider(entryId));
    final perms = ref.watch(permissionsProvider);
    final entry = value.value;
    final route = entry == null
        ? null
        : openableDocumentRoute(perms, entry.voucherType, entry.documentRoute);
    return AlertDialog(
      insetPadding: dialogInset(context),
      title: Text(entry?.number ?? 'Journal entry'),
      scrollable: true,
      content: SizedBox(
        width: 640,
        child: switch (value) {
          AsyncValue(:final error?, hasValue: false) => Text(
            errorMessage(error),
          ),
          AsyncValue(value: final e?) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(formatDate(e.date)),
                  VoucherPill(e.voucherType, reversal: e.isReversal),
                ],
              ),
              if (e.narration != null && e.narration!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(e.narration!),
              ],
              const SizedBox(height: 12),
              JournalLinesView(entry: e),
              if (e.createdBy != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Posted by ${e.createdBy!.name} · '
                  '${formatDateTime(e.createdAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
          _ => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        },
      ),
      actions: [
        if (route != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              context.push(route);
            },
            child: const Text('Open document'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
