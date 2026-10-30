import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../common/subcontract_widgets.dart';
import '../data/subcontract_repository.dart';
import '../models/subcontract_models.dart';

/// One RA bill: measurements, totals and the review workflow.
class RaBillDetailScreen extends ConsumerStatefulWidget {
  const RaBillDetailScreen({super.key, required this.billId});

  final String billId;

  @override
  ConsumerState<RaBillDetailScreen> createState() => _RaBillDetailScreenState();
}

class _RaBillDetailScreenState extends ConsumerState<RaBillDetailScreen> {
  bool _busy = false;

  Future<void> _run(Future<Object?> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.bumpC(const [CKind.raBills]);
      ref.invalidate(raBillProvider(widget.billId));
      if (mounted) showSuccess(context, done);
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(RaBill b) async {
    final ok = await confirm(
      context,
      title: 'Submit for approval',
      message: 'Submit ${b.number}? It cannot be edited until it is rejected.',
      confirmLabel: 'Submit',
    );
    if (ok && mounted) {
      await _run(
        () => ref.read(subcontractRepositoryProvider).submitRaBill(b.id),
        '${b.number} submitted',
      );
    }
  }

  Future<void> _approve(RaBill b) async {
    final ok = await confirm(
      context,
      title: 'Approve RA bill',
      message:
          'Approve ${b.number} for ${formatMoney(b.netPayable)}? This posts '
          'the journal entry.',
      confirmLabel: 'Approve',
    );
    if (ok && mounted) {
      await _run(
        () => ref.read(subcontractRepositoryProvider).approveRaBill(b.id),
        '${b.number} approved',
      );
    }
  }

  Future<void> _reject(RaBill b) async {
    final reason = await showReasonDialog(
      context,
      title: 'Reject RA bill',
      message: 'Send ${b.number} back to draft with a reason.',
      confirmLabel: 'Reject',
      cancelLabel: 'Keep it',
    );
    if (reason != null && mounted) {
      await _run(
        () =>
            ref.read(subcontractRepositoryProvider).rejectRaBill(b.id, reason),
        '${b.number} sent back',
      );
    }
  }

  Future<void> _cancel(RaBill b) async {
    final reason = await showReasonDialog(
      context,
      title: 'Cancel RA bill',
      message:
          'Cancel ${b.number}? The journal is reversed. Only the latest '
          'approved, unpaid bill can be cancelled.',
      confirmLabel: 'Cancel bill',
      cancelLabel: 'Keep it',
    );
    if (reason != null && mounted) {
      await _run(
        () =>
            ref.read(subcontractRepositoryProvider).cancelRaBill(b.id, reason),
        '${b.number} cancelled',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final manage = perms.can(CPerm.subcontractsManage);
    final approve = perms.can(CPerm.subcontractsApprove);
    return CGate(
      anyOf: const [CPerm.subcontractsView],
      child: AsyncValueView(
        value: ref.watch(raBillProvider(widget.billId)),
        onRetry: () => ref.invalidate(raBillProvider(widget.billId)),
        data: (b) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: b.number,
              subtitle: '${b.contractorName} · ${b.workOrderNumber}',
              actions: [
                raBillPills(context, b),
                if (b.isDraft && manage) ...[
                  FilledButton.icon(
                    style: bigButton,
                    onPressed: _busy ? null : () => _submit(b),
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Submit'),
                  ),
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: () => context.go('/ra-bills/${b.id}/edit'),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
                ],
                if (b.status == RaBillStatus.submitted && approve) ...[
                  FilledButton.icon(
                    style: bigButton,
                    onPressed: _busy ? null : () => _approve(b),
                    icon: const Icon(Icons.check),
                    label: const Text('Approve'),
                  ),
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: _busy ? null : () => _reject(b),
                    icon: const Icon(Icons.undo),
                    label: const Text('Reject'),
                  ),
                ],
                if (b.status == RaBillStatus.approved &&
                    approve &&
                    b.amountPaid == 0)
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: _busy ? null : () => _cancel(b),
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel'),
                  ),
              ],
            ),
            Expanded(
              child: CPage(
                maxWidth: 1000,
                children: [
                  if (b.rejectReason != null && b.isDraft)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text('Rejected: ${b.rejectReason}'),
                      ),
                    ),
                  SectionCard(
                    title: 'Bill',
                    child: FactsWrap(
                      facts: [
                        ('Project', b.projectName),
                        ('Bill no.', '${b.billSeq}'),
                        ('Date', formatDate(b.date)),
                        if (b.periodFrom != null || b.periodTo != null)
                          (
                            'Period',
                            '${formatDate(b.periodFrom)} to '
                                '${formatDate(b.periodTo)}',
                          ),
                        if (b.dueDate != null) ('Due', formatDate(b.dueDate)),
                        if (b.notes != null) ('Notes', b.notes!),
                        if (b.cancelReason != null)
                          ('Cancelled', b.cancelReason!),
                      ],
                    ),
                  ),
                  _Measurements(bill: b),
                  _Totals(bill: b),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Measurements extends StatelessWidget {
  const _Measurements({required this.bill});

  final RaBill bill;

  @override
  Widget build(BuildContext context) {
    final lines = bill.lines ?? const <RaBillLine>[];
    return SectionCard(
      title: 'Measurements',
      child: lines.isEmpty
          ? const Text('No lines.')
          : LayoutBuilder(
              builder: (context, c) {
                if (c.maxWidth >= 720) {
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: c.maxWidth),
                      child: DataTable(
                        columnSpacing: 20,
                        horizontalMargin: 8,
                        columns: const [
                          DataColumn(label: Text('Description')),
                          DataColumn(label: Text('Unit')),
                          DataColumn(label: Text('Rate'), numeric: true),
                          DataColumn(label: Text('Prev qty'), numeric: true),
                          DataColumn(label: Text('Cum qty'), numeric: true),
                          DataColumn(label: Text('This qty'), numeric: true),
                          DataColumn(label: Text('Amount'), numeric: true),
                        ],
                        rows: [
                          for (final l in lines)
                            DataRow(
                              cells: [
                                DataCell(
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 260,
                                    ),
                                    child: Text(
                                      l.description,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                DataCell(Text(l.unit)),
                                DataCell(Text(formatMoney(l.rate))),
                                DataCell(Text(formatQty(l.prevQty))),
                                DataCell(Text(formatQty(l.cumQty))),
                                DataCell(Text(formatQty(l.thisQty))),
                                DataCell(Text(formatMoney(l.amount))),
                              ],
                            ),
                        ],
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final (i, l) in lines.indexed) ...[
                      if (i > 0) const Divider(height: 20),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l.description,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                Text(
                                  'Prev ${formatQty(l.prevQty)} → cum '
                                  '${formatQty(l.cumQty)} = this '
                                  '${formatQty(l.thisQty)} ${l.unit} '
                                  '@ ${formatMoney(l.rate)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(formatMoney(l.amount)),
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.bill});

  final RaBill bill;

  @override
  Widget build(BuildContext context) {
    Widget row(
      String label,
      double amount, {
      bool bold = false,
      bool minus = false,
    }) {
      final style = bold ? const TextStyle(fontWeight: FontWeight.w700) : null;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: style)),
            Text('${minus ? '− ' : ''}${formatMoney(amount)}', style: style),
          ],
        ),
      );
    }

    return SectionCard(
      title: 'Totals',
      child: Column(
        children: [
          row('Gross work value', bill.gross),
          row('GST', bill.gst),
          row('Invoice total', bill.invoiceTotal, bold: true),
          const Divider(),
          row('Retention', bill.retention, minus: true),
          row('Advance recovery', bill.advanceRecovery, minus: true),
          row('TDS', bill.tds, minus: true),
          row('BOCW cess', bill.cess, minus: true),
          row(
            bill.otherDeductionNote == null
                ? 'Other deduction'
                : 'Other deduction (${bill.otherDeductionNote})',
            bill.otherDeduction,
            minus: true,
          ),
          const Divider(),
          row('Net payable', bill.netPayable, bold: true),
          if (bill.amountPaid > 0) row('Paid', bill.amountPaid),
          if (bill.status == RaBillStatus.approved)
            row('Due', bill.amountDue, bold: true),
        ],
      ),
    );
  }
}
