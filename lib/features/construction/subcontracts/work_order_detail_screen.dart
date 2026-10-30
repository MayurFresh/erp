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

/// A work order: lines with billed quantities, advance and retention
/// summaries, lifecycle actions and its RA bills.
class WorkOrderDetailScreen extends ConsumerStatefulWidget {
  const WorkOrderDetailScreen({super.key, required this.workOrderId});

  final String workOrderId;

  @override
  ConsumerState<WorkOrderDetailScreen> createState() =>
      _WorkOrderDetailScreenState();
}

class _WorkOrderDetailScreenState extends ConsumerState<WorkOrderDetailScreen> {
  bool _busy = false;

  SubcontractRepository get _repo => ref.read(subcontractRepositoryProvider);

  Future<void> _run(Future<Object?> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.bumpC(const [CKind.workOrders]);
      ref.invalidate(workOrderProvider(widget.workOrderId));
      if (mounted) showSuccess(context, done);
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate(WorkOrder wo) async {
    final ok = await confirm(
      context,
      title: 'Activate work order',
      message:
          'Activate ${wo.number}? RA bills and advances can then be raised. '
          'Lines and percentages stay editable only until the first RA bill.',
      confirmLabel: 'Activate',
    );
    if (ok && mounted) {
      await _run(
        () => _repo.activateWorkOrder(wo.id),
        '${wo.number} is active',
      );
    }
  }

  Future<void> _close(WorkOrder wo) async {
    final ok = await confirm(
      context,
      title: 'Close work order',
      message:
          'Close ${wo.number}? No more RA bills can be raised. This needs '
          'every RA bill to be approved or cancelled.',
      confirmLabel: 'Close work order',
    );
    if (ok && mounted) {
      await _run(() => _repo.closeWorkOrder(wo.id), '${wo.number} closed');
    }
  }

  Future<void> _cancel(WorkOrder wo) async {
    final reason = await showReasonDialog(
      context,
      title: 'Cancel work order',
      message:
          'Cancel ${wo.number}? This is only possible with no approved RA '
          'bill and no live advance.',
      confirmLabel: 'Cancel work order',
      cancelLabel: 'Keep it',
    );
    if (reason != null && mounted) {
      await _run(
        () => _repo.cancelWorkOrder(wo.id, reason),
        '${wo.number} cancelled',
      );
    }
  }

  Future<void> _payAdvance(WorkOrder wo) async {
    final entry = await showAmountDialog(
      context,
      ref,
      title: 'Pay mobilisation advance',
      message: 'Advance to ${wo.contractorName}, recovered from RA bills.',
      confirmLabel: 'Pay advance',
    );
    if (entry == null || !mounted) return;
    await _run(
      () => _repo.payContractorAdvance(
        wo.id,
        amount: entry.amount,
        paidFromAccountId: entry.accountId!,
        date: apiDate(entry.date),
        notes: entry.notes,
      ),
      'Advance of ${formatMoney(entry.amount)} paid',
    );
  }

  Future<void> _releaseRetention(WorkOrder wo) async {
    final entry = await showAmountDialog(
      context,
      ref,
      title: 'Release retention',
      message:
          'Retention held ${formatMoney(wo.retention.balance)}. The amount '
          'becomes payable to ${wo.contractorName}.',
      confirmLabel: 'Release',
      withAccount: false,
      maxAmount: wo.retention.balance,
      initialAmount: wo.retention.balance,
    );
    if (entry == null || !mounted) return;
    await _run(
      () => _repo.releaseRetention(
        wo.id,
        amount: entry.amount,
        date: apiDate(entry.date),
        notes: entry.notes,
      ),
      'Retention of ${formatMoney(entry.amount)} released',
    );
  }

  Future<void> _cancelAdvance(ContractorAdvance advance) async {
    final reason = await showReasonDialog(
      context,
      title: 'Cancel advance',
      message: 'Cancel ${advance.number} (${formatMoney(advance.amount)})?',
      confirmLabel: 'Cancel advance',
      cancelLabel: 'Keep it',
    );
    if (reason != null && mounted) {
      await _run(
        () => _repo.cancelContractorAdvance(advance.id, reason),
        '${advance.number} cancelled',
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
        value: ref.watch(workOrderProvider(widget.workOrderId)),
        onRetry: () => ref.invalidate(workOrderProvider(widget.workOrderId)),
        data: (wo) {
          final editable = wo.isDraft || wo.isActive;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHeader(
                title: wo.title,
                subtitle:
                    '${wo.number} · ${wo.contractorName} · ${wo.projectName}',
                actions: [
                  workOrderStatusPill(context, wo.status),
                  if (wo.isDraft && manage)
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: _busy ? null : () => _activate(wo),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Activate'),
                    ),
                  if (wo.isActive && manage && !wo.hasFinalBill)
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: () =>
                          context.go('/ra-bills/new?workOrderId=${wo.id}'),
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('New RA bill'),
                    ),
                  if (wo.isActive && approve)
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : () => _payAdvance(wo),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('Pay advance'),
                    ),
                  if (editable && approve && wo.retention.balance > 0)
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : () => _releaseRetention(wo),
                      icon: const Icon(Icons.lock_open_outlined),
                      label: const Text('Release retention'),
                    ),
                  if (wo.status == WorkOrderStatus.closed &&
                      approve &&
                      wo.retention.balance > 0)
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : () => _releaseRetention(wo),
                      icon: const Icon(Icons.lock_open_outlined),
                      label: const Text('Release retention'),
                    ),
                  if (editable && manage)
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: () => context.go('/work-orders/${wo.id}/edit'),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                  if (wo.isActive && approve)
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : () => _close(wo),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Close'),
                    ),
                  if (editable && approve)
                    IconButton(
                      tooltip: 'Cancel work order',
                      onPressed: _busy ? null : () => _cancel(wo),
                      icon: const Icon(Icons.cancel_outlined),
                    ),
                ],
              ),
              Expanded(
                child: CPage(
                  maxWidth: 1000,
                  children: [
                    _Summary(wo: wo),
                    _Lines(wo: wo),
                    _AdvanceCard(
                      wo: wo,
                      canCancel: approve && editable,
                      onCancel: _busy ? null : _cancelAdvance,
                    ),
                    _RetentionCard(wo: wo),
                    _Bills(workOrderId: wo.id),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.wo});

  final WorkOrder wo;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: 'Summary',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FactsWrap(
          facts: [
            ('Date', formatDate(wo.date)),
            ('Contract value', formatMoney(wo.totalValue)),
            ('Billed (approved)', formatMoney(wo.billedGross)),
            ('Retention', formatPercent(wo.retentionPct)),
            ('Advance recovery', formatPercent(wo.advanceRecoveryPct)),
            ('TDS', formatPercent(wo.tdsPct)),
            (
              'GST',
              '${formatPercent(wo.gstPct)}'
                  '${wo.itcEligible ? ' (ITC eligible)' : ' (no ITC)'}',
            ),
            ('BOCW cess', formatPercent(wo.cessPct)),
            if (wo.scope != null) ('Scope', wo.scope!),
            if (wo.cancelReason != null) ('Cancelled', wo.cancelReason!),
          ],
        ),
        const SizedBox(height: 12),
        PctBar(wo.billedPct),
      ],
    ),
  );
}

class _Lines extends StatelessWidget {
  const _Lines({required this.wo});

  final WorkOrder wo;

  @override
  Widget build(BuildContext context) {
    final lines = wo.lines ?? const <WorkOrderLine>[];
    return SectionCard(
      title: 'Work items',
      child: lines.isEmpty
          ? const Text('No work items.')
          : LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 720) {
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: constraints.maxWidth,
                      ),
                      child: DataTable(
                        columnSpacing: 20,
                        horizontalMargin: 8,
                        columns: const [
                          DataColumn(label: Text('#')),
                          DataColumn(label: Text('Description')),
                          DataColumn(label: Text('Unit')),
                          DataColumn(label: Text('Qty'), numeric: true),
                          DataColumn(label: Text('Rate'), numeric: true),
                          DataColumn(label: Text('Amount'), numeric: true),
                          DataColumn(label: Text('Billed qty'), numeric: true),
                        ],
                        rows: [
                          for (final l in lines)
                            DataRow(
                              cells: [
                                DataCell(Text('${l.lineNo}')),
                                DataCell(
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 260,
                                    ),
                                    child: Text(
                                      [
                                        if (l.boqCode != null) '[${l.boqCode}]',
                                        l.description,
                                      ].join(' '),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                DataCell(Text(l.unit)),
                                DataCell(Text(formatQty(l.qty))),
                                DataCell(Text(formatMoney(l.rate))),
                                DataCell(Text(formatMoney(l.amount))),
                                DataCell(
                                  Text(
                                    '${formatQty(l.billedQty)} '
                                    '(${formatQty(l.billedPct.roundToDouble())}%)',
                                  ),
                                ),
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
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            [
                              '${l.lineNo}.',
                              if (l.boqCode != null) '[${l.boqCode}]',
                              l.description,
                            ].join(' '),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            '${formatQty(l.qty)} ${l.unit} × '
                            '${formatMoney(l.rate)} = ${formatMoney(l.amount)}',
                          ),
                          Text(
                            'Billed ${formatQty(l.billedQty)} of '
                            '${formatQty(l.qty)} ${l.unit}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          PctBar(l.billedPct, height: 6),
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

class _AdvanceCard extends ConsumerWidget {
  const _AdvanceCard({
    required this.wo,
    required this.canCancel,
    required this.onCancel,
  });

  final WorkOrder wo;
  final bool canCancel;
  final void Function(ContractorAdvance)? onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final advances = ref.watch(workOrderAdvancesProvider(wo.id));
    return SectionCard(
      title: 'Mobilisation advance',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FactsWrap(
            facts: [
              ('Paid', formatMoney(wo.advance.paid)),
              ('Recovered', formatMoney(wo.advance.recovered)),
              ('Balance', formatMoney(wo.advance.balance)),
            ],
          ),
          for (final a in advances.value ?? const <ContractorAdvance>[])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                a.isCancelled ? '${a.number} (cancelled)' : a.number,
                style: a.isCancelled
                    ? const TextStyle(decoration: TextDecoration.lineThrough)
                    : null,
              ),
              subtitle: Text(
                [
                  formatDate(a.date),
                  if (a.paidFromAccountName != null) a.paidFromAccountName!,
                ].join(' · '),
              ),
              trailing: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(formatMoney(a.amount)),
                  if (canCancel && !a.isCancelled)
                    IconButton(
                      tooltip: 'Cancel advance',
                      onPressed: onCancel == null ? null : () => onCancel!(a),
                      icon: const Icon(Icons.cancel_outlined),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RetentionCard extends ConsumerWidget {
  const _RetentionCard({required this.wo});

  final WorkOrder wo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final releases = ref.watch(workOrderReleasesProvider(wo.id));
    return SectionCard(
      title: 'Retention',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FactsWrap(
            facts: [
              ('Held', formatMoney(wo.retention.held)),
              ('Released', formatMoney(wo.retention.released)),
              ('Balance', formatMoney(wo.retention.balance)),
            ],
          ),
          for (final r in releases.value ?? const <RetentionRelease>[])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r.number),
              subtitle: Text([formatDate(r.date), ?r.notes].join(' · ')),
              trailing: Text(formatMoney(r.amount)),
            ),
        ],
      ),
    );
  }
}

class _Bills extends ConsumerWidget {
  const _Bills({required this.workOrderId});

  final String workOrderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bills = ref.watch(workOrderBillsProvider(workOrderId));
    return SectionCard(
      title: 'RA bills',
      child: bills.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(errorMessage(e)),
        data: (list) => list.isEmpty
            ? const Text('No RA bills yet.')
            : Column(
                children: [
                  for (final b in list)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      onTap: () => context.go('/ra-bills/${b.id}'),
                      title: Text('Bill ${b.billSeq} · ${b.number}'),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: raBillPills(context, b),
                        ),
                      ),
                      trailing: Text(
                        formatMoney(b.netPayable),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
