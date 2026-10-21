import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'document_models.dart';

class DocStatusPill extends StatelessWidget {
  const DocStatusPill({super.key, required this.status});

  final DocStatus status;

  @override
  Widget build(BuildContext context) => Pill(
    status.label,
    color: status == DocStatus.cancelled
        ? Theme.of(context).colorScheme.error
        : Colors.green,
  );
}

class PaymentStatusPill extends StatelessWidget {
  const PaymentStatusPill({super.key, required this.status});

  final PaymentStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pill(
      status.label,
      color: switch (status) {
        PaymentStatus.paid => Colors.green,
        PaymentStatus.partial => Colors.orange.shade800,
        PaymentStatus.unpaid => scheme.error,
      },
    );
  }
}

/// Status and (for posted documents) payment status side by side.
class DocPills extends StatelessWidget {
  const DocPills({super.key, required this.status, this.paymentStatus});

  final DocStatus status;
  final PaymentStatus? paymentStatus;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      DocStatusPill(status: status),
      if (paymentStatus != null && status == DocStatus.posted)
        PaymentStatusPill(status: paymentStatus!),
    ],
  );
}

/// Taxable value, CGST/SGST or IGST, round-off and total, plus optional
/// paid / due rows.
class TaxTotals extends StatelessWidget {
  const TaxTotals({
    super.key,
    required this.summary,
    this.placeLabel = 'Place of supply',
    this.amountPaid,
    this.amountDue,
  });

  final TaxSummary summary;
  final String placeLabel;
  final double? amountPaid;
  final double? amountDue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = summary;
    final inter = s.isInterState;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${inter ? 'Inter-state' : 'Intra-state'} supply · '
          '$placeLabel ${stateLabel(s.placeOfSupply)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        AmountRow('Taxable value', s.subtotal),
        if (!inter || s.cgst != 0) AmountRow('CGST', s.cgst),
        if (!inter || s.sgst != 0) AmountRow('SGST', s.sgst),
        if (inter || s.igst != 0) AmountRow('IGST', s.igst),
        AmountRow('Total tax', s.taxTotal),
        AmountRow('Round off', s.roundOff),
        const Divider(),
        AmountRow('Total', s.total, emphasize: true),
        if (amountPaid != null) AmountRow('Paid / adjusted', amountPaid!),
        if (amountDue != null) AmountRow('Amount due', amountDue!, bold: true),
      ],
    );
  }
}

class AmountRow extends StatelessWidget {
  const AmountRow(
    this.label,
    this.amount, {
    super.key,
    this.emphasize = false,
    this.bold = false,
  });

  final String label;
  final double amount;
  final bool emphasize;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = emphasize
        ? theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.bodyMedium?.copyWith(
            fontWeight: bold ? FontWeight.w600 : null,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          // Crore-sized totals shrink rather than overflow on phones.
          Expanded(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(formatMoney(amount), style: style),
            ),
          ),
        ],
      ),
    );
  }
}

/// Document lines as a table when there is room and as cards otherwise.
class TaxLinesView extends StatelessWidget {
  const TaxLinesView({
    super.key,
    required this.lines,
    required this.interState,
    this.showReturned = false,
  });

  final List<TaxLine> lines;
  final bool interState;

  /// Adds a "Returned" column (invoice detail).
  final bool showReturned;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const Text('No lines.');
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return Column(
            children: [
              for (final (index, line) in lines.indexed) ...[
                if (index > 0) const Divider(height: 24),
                _LineCard(
                  line: line,
                  interState: interState,
                  showReturned: showReturned,
                ),
              ],
            ],
          );
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: DataTable(
              columnSpacing: 18,
              horizontalMargin: 8,
              columns: [
                const DataColumn(label: Text('#')),
                const DataColumn(label: Text('Item')),
                const DataColumn(label: Text('HSN')),
                const DataColumn(label: Text('Qty'), numeric: true),
                if (showReturned)
                  const DataColumn(label: Text('Returned'), numeric: true),
                const DataColumn(label: Text('Rate'), numeric: true),
                const DataColumn(label: Text('Disc %'), numeric: true),
                const DataColumn(label: Text('Taxable'), numeric: true),
                const DataColumn(label: Text('GST'), numeric: true),
                if (interState)
                  const DataColumn(label: Text('IGST'), numeric: true)
                else ...[
                  const DataColumn(label: Text('CGST'), numeric: true),
                  const DataColumn(label: Text('SGST'), numeric: true),
                ],
                const DataColumn(label: Text('Amount'), numeric: true),
              ],
              rows: [
                for (final (index, line) in lines.indexed)
                  DataRow(
                    cells: [
                      DataCell(Text('${index + 1}')),
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Tooltip(
                            message: line.description,
                            child: Text(
                              line.description,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                      DataCell(Text(line.hsnCode ?? '—')),
                      DataCell(Text('${formatQty(line.qty)} ${line.unit}')),
                      if (showReturned)
                        DataCell(
                          Text(
                            line.returnedQty == 0
                                ? '—'
                                : formatQty(line.returnedQty),
                          ),
                        ),
                      DataCell(Text(formatMoney(line.rate))),
                      DataCell(Text(formatPercent(line.discountPct))),
                      DataCell(Text(formatMoney(line.taxableValue))),
                      DataCell(Text(formatPercent(line.gstRate))),
                      if (interState)
                        DataCell(Text(formatMoney(line.igst)))
                      else ...[
                        DataCell(Text(formatMoney(line.cgst))),
                        DataCell(Text(formatMoney(line.sgst))),
                      ],
                      DataCell(
                        Text(
                          formatMoney(line.lineTotal),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.line,
    required this.interState,
    required this.showReturned,
  });

  final TaxLine line;
  final bool interState;
  final bool showReturned;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final tax = interState
        ? 'IGST ${formatMoney(line.igst)}'
        : 'CGST ${formatMoney(line.cgst)} · SGST ${formatMoney(line.sgst)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(line.description, style: theme.textTheme.titleSmall),
            ),
            const SizedBox(width: 8),
            Text(
              formatMoney(line.lineTotal),
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${formatQty(line.qty)} ${line.unit} × ${formatMoney(line.rate)}'
          '${line.discountPct > 0 ? ' − ${formatPercent(line.discountPct)}' : ''}'
          '${line.hsnCode == null ? '' : ' · HSN ${line.hsnCode}'}',
          style: small,
        ),
        Text(
          'Taxable ${formatMoney(line.taxableValue)} · '
          'GST ${formatPercent(line.gstRate)} · $tax',
          style: small,
        ),
        if (showReturned && line.returnedQty > 0)
          Text(
            'Returned ${formatQty(line.returnedQty)} ${line.unit}',
            style: small?.copyWith(color: theme.colorScheme.tertiary),
          ),
      ],
    );
  }
}

/// Receipts / payments / credit notes applied to a document; tapping one
/// opens it.
class SettlementsList extends StatelessWidget {
  const SettlementsList({
    super.key,
    required this.settlements,
    this.canOpen = _always,
  });

  final List<Settlement> settlements;
  final bool Function(Settlement) canOpen;

  static bool _always(Settlement _) => true;

  @override
  Widget build(BuildContext context) {
    if (settlements.isEmpty) {
      return const Text('Nothing applied yet.');
    }
    return Column(
      children: [
        for (final s in settlements)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              s.kind == 'credit_note'
                  ? Icons.assignment_return_outlined
                  : Icons.payments_outlined,
            ),
            title: Text(s.number, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${s.kindLabel} · ${formatDate(s.date)}',
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(formatMoney(s.amount)),
            onTap: canOpen(s) ? () => context.push(s.route) : null,
          ),
      ],
    );
  }
}

/// Red banner with the cancellation time and reason.
class CancelledBanner extends StatelessWidget {
  const CancelledBanner({super.key, this.cancelledAt, this.reason});

  final DateTime? cancelledAt;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.block, color: scheme.onErrorContainer),
        title: Text(
          'Cancelled ${formatDateTime(cancelledAt)}',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        subtitle: reason == null
            ? null
            : Text(
                'Reason: $reason',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
      ),
    );
  }
}

/// An error from the server in a coloured box, titled by its code.
class ApiErrorBox extends StatelessWidget {
  const ApiErrorBox({super.key, required this.error, this.subject = 'it'});

  final Object error;

  /// Used in the validation title, e.g. "Please check the invoice".
  final String subject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final api = apiError(error);
    final title = switch (api?.code) {
      ApiException.insufficientStock => 'Not enough stock',
      ApiException.validationError => 'Please check $subject',
      ApiException.hasSettlements => 'Payments are applied',
      _ => 'Could not complete',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: scheme.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            errorMessage(error),
            style: TextStyle(color: scheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}

/// Asks for a cancellation reason; pops with the trimmed reason.
class CancelReasonDialog extends StatefulWidget {
  const CancelReasonDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.keepLabel = 'Keep it',
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String keepLabel;

  @override
  State<CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<CancelReasonDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_reason.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.message),
              const SizedBox(height: 16),
              TextFormField(
                controller: _reason,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Reason'),
                maxLines: 2,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'A reason is required'
                    : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.keepLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Explains why a cancel was refused (`409 HAS_SETTLEMENTS` or
/// `INSUFFICIENT_STOCK`) and what to do about it.
Future<void> showCancelBlocked(
  BuildContext context,
  Object error, {
  required String document,
  List<Settlement> settlements = const [],
}) {
  final api = apiError(error);
  final hasSettlements = api?.code == ApiException.hasSettlements;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Cannot cancel this $document'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              hasSettlements
                  ? 'Receipts, payments or credit notes are applied to this '
                        '$document. Cancel them first, then cancel the '
                        '$document.'
                  : 'The stock it brought in has already been used. Reverse '
                        'the later sales or transfers first.',
            ),
            if (api != null && api.message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(api.message, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (hasSettlements && settlements.isNotEmpty) ...[
              const SizedBox(height: 8),
              SettlementsList(settlements: settlements),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Whether [error] is a cancel refusal that [showCancelBlocked] explains.
bool isCancelBlocked(Object error) {
  final code = apiError(error)?.code;
  return code == ApiException.hasSettlements ||
      code == ApiException.insufficientStock;
}

class DocAction {
  const DocAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  /// Stays a visible button on phones; others move to the "More" menu.
  final bool primary;
  final bool destructive;
}

/// Below this width only primary actions stay as buttons.
const double kCompactActions = 600;

/// Action buttons for a detail page. When [compact], only
/// [DocAction.primary] actions are shown; the rest are left to a
/// [DocOverflowMenu].
class DocActions extends StatelessWidget {
  const DocActions({super.key, required this.actions, this.compact = false});

  final List<DocAction> actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final visible = compact
        ? actions.where((a) => a.primary).toList()
        : actions;
    if (visible.isEmpty) return const SizedBox.shrink();
    final error = Theme.of(context).colorScheme.error;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final action in visible)
          action.primary && !action.destructive
              ? FilledButton.tonalIcon(
                  onPressed: action.onPressed,
                  icon: Icon(action.icon),
                  label: Text(action.label),
                )
              : OutlinedButton.icon(
                  onPressed: action.onPressed,
                  icon: Icon(action.icon),
                  label: Text(action.label),
                  style: action.destructive
                      ? OutlinedButton.styleFrom(foregroundColor: error)
                      : null,
                ),
      ],
    );
  }
}

/// "More actions" menu with the non-primary actions (phones).
class DocOverflowMenu extends StatelessWidget {
  const DocOverflowMenu({super.key, required this.actions});

  final List<DocAction> actions;

  @override
  Widget build(BuildContext context) {
    final overflow = actions.where((a) => !a.primary).toList();
    if (overflow.isEmpty) return const SizedBox.shrink();
    final error = Theme.of(context).colorScheme.error;
    return PopupMenuButton<int>(
      tooltip: 'More actions',
      icon: const Icon(Icons.more_vert),
      onSelected: (i) => overflow[i].onPressed(),
      itemBuilder: (context) => [
        for (final (i, action) in overflow.indexed)
          PopupMenuItem<int>(
            value: i,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                action.icon,
                color: action.destructive ? error : null,
              ),
              title: Text(
                action.label,
                style: action.destructive ? TextStyle(color: error) : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// Title + pills on the left, actions on the right (wrapping on phones),
/// then a row of labelled values.
class DocHeader extends StatelessWidget {
  const DocHeader({
    super.key,
    required this.title,
    required this.pills,
    required this.facts,
    this.actions = const [],
  });

  final String title;
  final Widget pills;
  final List<Widget> facts;
  final List<DocAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < kCompactActions;
    final heading = Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        pills,
      ],
    );
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (compact) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: heading),
                DocOverflowMenu(actions: actions),
              ],
            ),
            if (actions.any((a) => a.primary)) ...[
              const SizedBox(height: 12),
              DocActions(actions: actions, compact: true),
            ],
          ] else
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                heading,
                DocActions(actions: actions),
              ],
            ),
          const SizedBox(height: 16),
          Wrap(spacing: 32, runSpacing: 12, children: facts),
        ],
      ),
    );
  }
}

/// Phone card for a document row: number, a details line, pills under it
/// and the amount(s) on the right.
class DocListCard extends StatelessWidget {
  const DocListCard({
    super.key,
    required this.title,
    required this.details,
    required this.pills,
    required this.amount,
    this.secondary,
    this.onTap,
  });

  final String title;
  final String details;
  final Widget pills;
  final String amount;

  /// Smaller line under the amount, e.g. "Due ₹500.00".
  final String? secondary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    pills,
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    amount,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (secondary != null)
                    Text(secondary!, style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
