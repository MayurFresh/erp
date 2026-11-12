import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'mfg_models.dart';
import 'mfg_pdf.dart';
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';
import 'order_dialogs.dart';

/// `/manufacturing/orders/:id`: one production order.
class OrderScreen extends ConsumerWidget {
  const OrderScreen({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [MfgPerm.view],
    child: AsyncValueView(
      value: ref.watch(mfgOrderProvider(orderId)),
      onRetry: () => ref.invalidate(mfgOrderProvider(orderId)),
      data: (o) => _OrderView(order: o),
    ),
  );
}

class _OrderView extends ConsumerStatefulWidget {
  const _OrderView({required this.order});

  final MfgOrder order;

  @override
  ConsumerState<_OrderView> createState() => _OrderViewState();
}

class _OrderViewState extends ConsumerState<_OrderView> {
  bool _busy = false;

  MfgOrder get o => widget.order;

  Future<void> _do(Future<void> Function(MfgRepository r) job, String done) async {
    setState(() => _busy = true);
    final ok = await mfgGuarded(context, () => job(ref.read(mfgRepositoryProvider)));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.bumpMfg();
      mfgToast(context, done);
    }
  }

  Future<void> _dialog(Widget Function() build, String done) async {
    final ok = await showFormDialog<bool>(context: context, builder: (_) => build());
    if (ok == true && mounted) {
      ref.bumpMfg();
      mfgToast(context, done);
    }
  }

  Future<void> _cancel() async {
    final reason = await askReason(context, title: 'Cancel ${o.number}?', action: 'Cancel order');
    if (reason == null) return;
    await _do((r) async => r.cancel(o.id, reason), 'Order cancelled.');
  }

  Future<void> _close() async {
    final note = await askReason(
      context,
      title: 'Close ${o.number}?',
      action: 'Close order',
      label: 'Note (optional)',
      required: false,
    );
    if (note == null) return;
    await _do((r) async => r.close(o.id, note.isEmpty ? null : note), 'Order closed. Unused material went to wastage.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final can = ref.mfgCan;
    final actions = <Widget>[
      if (o.can('release') && can(MfgPerm.orders))
        FilledButton(onPressed: _busy ? null : () => _do((r) async => r.release(o.id), 'Released.'), child: const Text('Release')),
      if (o.can('issue') && can(MfgPerm.issue))
        FilledButton(
          onPressed: _busy ? null : () => _dialog(() => IssueDialog(order: o, returning: false), 'Material issued.'),
          child: const Text('Issue material'),
        ),
      if (o.can('output') && can(MfgPerm.output))
        FilledButton(
          onPressed: _busy ? null : () => _dialog(() => OutputDialog(order: o), 'Output recorded.'),
          child: const Text('Record output'),
        ),
      if (o.can('return') && can(MfgPerm.issue))
        OutlinedButton(
          onPressed: _busy ? null : () => _dialog(() => IssueDialog(order: o, returning: true), 'Material returned.'),
          child: const Text('Return material'),
        ),
      if (o.can('inspect') && can(MfgPerm.inspect))
        OutlinedButton(
          onPressed: _busy ? null : () => _dialog(() => InspectDialog(order: o), 'Inspection saved.'),
          child: const Text('Inspect'),
        ),
      if (o.can('edit') && can(MfgPerm.orders))
        OutlinedButton(
          onPressed: _busy ? null : () => _dialog(() => EditOrderDialog(order: o), 'Saved.'),
          child: const Text('Edit'),
        ),
      if (o.can('close') && can(MfgPerm.manage))
        OutlinedButton(onPressed: _busy ? null : _close, child: const Text('Close order')),
      if (o.can('cancel') && can(MfgPerm.orders))
        TextButton(onPressed: _busy ? null : _cancel, child: const Text('Cancel order')),
      OutlinedButton.icon(
        onPressed: () => printJobSheet(context, ref, o),
        icon: const Icon(Icons.print_outlined),
        label: const Text('Job sheet'),
      ),
    ];
    final editPlan = (o.status == 'draft' || o.isOpen) && can(MfgPerm.orders);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(title: '${o.number} · ${o.itemName}', subtitle: o.locationName, actions: [StatusChip(o.status)]),
        Expanded(
          child: mfgBody(context, [
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: Wrap(spacing: Space.sm, runSpacing: Space.sm, children: actions),
            ),
            MfgCard(
              title: 'Progress',
              child: Column(
                children: [
                  LinearProgressIndicator(value: (o.completionPct / 100).clamp(0, 1)),
                  const SizedBox(height: Space.sm),
                  MfgKv('Planned', qtyUnit(o.qty, o.unit)),
                  MfgKv('Good output', qtyUnit(o.goodQty, o.unit)),
                  MfgKv('Rejected', qtyUnit(o.rejectedQty, o.unit)),
                  if (o.yieldPct != null) MfgKv('Yield', formatPercent(o.yieldPct)),
                  MfgKv('Bill of materials', 'Version ${o.bomVersion}'),
                  if (o.plannedStart != null) MfgKv('Start', formatDate(o.plannedStart)),
                  if (o.plannedEnd != null) MfgKv('Due', formatDate(o.plannedEnd)),
                  if (o.salesOrderNumber != null) MfgKv('Sales order', o.salesOrderNumber!),
                  if ((o.notes ?? '').isNotEmpty) MfgKv('Notes', o.notes!),
                  if ((o.cancelReason ?? '').isNotEmpty) MfgKv('Cancelled because', o.cancelReason!),
                  if ((o.closeNote ?? '').isNotEmpty) MfgKv('Closing note', o.closeNote!),
                ],
              ),
            ),
            MfgCard(
              title: 'Material',
              trailing: editPlan
                  ? TextButton.icon(
                      onPressed: () => _dialog(() => PlanMaterialDialog(order: o), 'Material plan saved.'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                    )
                  : null,
              child: o.materials.isEmpty
                  ? const Text('No material planned.')
                  : Column(
                      children: [
                        for (final m in o.materials)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(m.name),
                            subtitle: Text(
                              'Plan ${qtyUnit(m.plannedQty, m.unit)} · issued ${formatQty(m.issuedQty)}'
                              '${m.returnedQty > 0 ? ' · returned ${formatQty(m.returnedQty)}' : ''}'
                              ' · in stock ${formatQty(m.onHand)}'
                              '${m.issuedValue != null ? ' · ${formatMoney(m.issuedValue)}' : ''}',
                            ),
                            trailing: m.pendingQty > m.onHand && o.status != 'completed' && o.status != 'cancelled'
                                ? const StatusChip('short', tone: StatusTone.warning)
                                : null,
                            onTap: editPlan
                                ? () => _dialog(() => PlanMaterialDialog(order: o, material: m), 'Material plan saved.')
                                : null,
                          ),
                      ],
                    ),
            ),
            if (o.steps.isNotEmpty)
              MfgCard(
                title: 'Operations',
                child: Column(
                  children: [for (final s in o.steps) MfgKv('${s.operation} (${s.workCentre})', '${formatQty(s.plannedMinutes)} min')],
                ),
              ),
            MfgCard(
              title: 'Output',
              child: o.outputs.isEmpty
                  ? const Text('No output recorded.')
                  : Column(
                      children: [
                        for (final x in o.outputs)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${formatDate(x.date)}: ${qtyUnit(x.goodQty, o.unit)} good'
                              '${x.rejectedQty > 0 ? ', ${formatQty(x.rejectedQty)} rejected' : ''}',
                            ),
                            subtitle: Text(
                              [
                                if (x.minutes != null) '${formatQty(x.minutes)} min',
                                if (x.unitCost != null) 'cost ${formatMoney(x.unitCost)} each',
                                if (x.byProducts.isNotEmpty) 'by-products: ${x.byProducts.join(', ')}',
                                if ((x.note ?? '').isNotEmpty) x.note!,
                              ].join(' · '),
                            ),
                          ),
                      ],
                    ),
            ),
            if (o.inspections.isNotEmpty)
              MfgCard(
                title: 'Inspections',
                child: Column(
                  children: [
                    for (final n in o.inspections)
                      MfgKv(
                        '${n.by}${(n.note ?? '').isEmpty ? '' : ': ${n.note}'}',
                        'pass ${formatQty(n.passQty)}, rework ${formatQty(n.reworkQty)}, reject ${formatQty(n.rejectQty)}',
                      ),
                  ],
                ),
              ),
            if (o.cost case final c?)
              MfgCard(
                title: 'Cost',
                child: Column(
                  children: [
                    MfgKv('Material', formatMoney(c.material)),
                    MfgKv('Work centres and overhead', formatMoney(c.conversion)),
                    MfgKv('Total', formatMoney(c.total), bold: true),
                    MfgKv('Cost per ${o.unit}', formatMoney(c.unitCost)),
                    if (c.lossValue > 0) MfgKv('Lost to wastage', formatMoney(c.lossValue)),
                  ],
                ),
              ),
            if (o.variance.isNotEmpty && (o.goodQty > 0 || o.rejectedQty > 0))
              MfgCard(
                title: 'Material used against plan',
                child: Column(
                  children: [
                    for (final v in o.variance)
                      MfgKv(
                        v.name,
                        'expected ${formatQty(v.expectedQty)}, used ${formatQty(v.actualQty)}, '
                        '${v.varianceQty > 0 ? 'over' : 'under'} by ${formatQty(v.varianceQty.abs())}'
                        '${v.varianceValue != null ? ' (${formatMoney(v.varianceValue!.abs())})' : ''}',
                      ),
                  ],
                ),
              ),
            if (o.movements.isNotEmpty)
              MfgCard(
                title: 'Movements',
                child: Column(
                  children: [
                    for (final m in o.movements)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${formatDateTime(m.createdAt)}  ${m.kind.replaceAll('_', ' ')}  ${m.name} ${qtyUnit(m.qty, m.unit)}  by ${m.by}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
          ]),
        ),
      ],
    );
  }
}

/// Header button to go back to the list.
Widget backToOrders(BuildContext context) => TextButton(
  onPressed: () => context.go('/manufacturing/orders'),
  child: const Text('All orders'),
);

Json noBody() => <String, dynamic>{};
