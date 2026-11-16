import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/activity_timeline.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_sheets.dart';
import 'crm_widgets.dart';
import 'lead_detail_screen.dart' show activityEvents;

/// `/crm/deals/:id`.
class CrmDealDetailScreen extends ConsumerWidget {
  const CrmDealDetailScreen({super.key, required this.dealId});

  final String dealId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CrmGate(
      child: AsyncValueView(
        value: ref.watch(crmDealProvider(dealId)),
        onRetry: () => ref.invalidate(crmDealProvider(dealId)),
        data: (d) => _Body(detail: d),
      ),
    );
  }
}

/// Everything that happened on a deal, newest first.
List<TimelineEvent> dealEvents(DealDetail d) {
  final items = <(DateTime, TimelineEvent)>[];
  final acts = activityEvents(d.activities);
  for (var i = 0; i < d.activities.length; i++) {
    final a = d.activities[i];
    final at = a.doneAt ?? a.dueAt ?? a.createdAt;
    if (at != null) items.add((at, acts[i]));
  }
  for (final h in d.history) {
    if (h.changedAt == null) continue;
    items.add((
      h.changedAt!,
      TimelineEvent(
        title: h.fromStage == null
            ? 'Started in ${h.toStage}'
            : 'Moved from ${h.fromStage} to ${h.toStage}',
        detail: h.changedBy,
        when: formatDateTime(h.changedAt),
      ),
    ));
  }
  for (final q in d.quotations) {
    final at = DateTime.tryParse(q.quoteDate ?? '');
    if (at == null) continue;
    items.add((
      at,
      TimelineEvent(
        title: '${q.kind == 'proforma' ? 'Proforma' : 'Quotation'} ${q.number}, ${q.status}',
        detail: formatMoney(q.total),
        when: formatDate(q.quoteDate),
      ),
    ));
  }
  items.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final i in items) i.$2];
}

class _Body extends ConsumerWidget {
  const _Body({required this.detail});

  final DealDetail detail;

  Future<void> _won(BuildContext context, WidgetRef ref) async {
    final d = detail.deal;
    final ctl = TextEditingController(text: formatPlain(d.value));
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark deal won'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Final value',
            prefixText: '₹ ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctl.text.trim());
              if (v != null && v >= 0) Navigator.of(context).pop(v);
            },
            child: const Text('Mark won'),
          ),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).winDeal(d.id, value),
      done: 'Deal marked won.',
    );
  }

  Future<void> _lost(BuildContext context, WidgetRef ref) async {
    final reasons = await ref
          .read(crmSettingsProvider.future)
          .then((s) => s.lostReasons, onError: (_) => const <String>[]);
    if (!context.mounted) return;
    final reason = await showReasonPicker(context, reasons: reasons);
    if (reason == null || !context.mounted) return;
    await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).loseDeal(detail.deal.id, reason),
      done: 'Deal marked lost.',
    );
  }

  Future<void> _closeChoice(BuildContext context, WidgetRef ref) async {
    final pick = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Close this deal'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('won'),
            child: const Text('Mark won'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('lost'),
            child: const Text('Mark lost'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (pick == 'won') {
      await _won(context, ref);
    } else if (pick == 'lost') {
      await _lost(context, ref);
    }
  }

  Future<void> _move(BuildContext context, WidgetRef ref, CrmStage s) async {
    if (s.kind == 'won') return _won(context, ref);
    if (s.kind == 'lost') return _lost(context, ref);
    if (s.id == detail.deal.stageId) return;
    await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).changeStage(detail.deal.id, s.id),
      done: 'Moved to ${s.name}.',
    );
  }

  Future<void> _note(BuildContext context, WidgetRef ref) async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add note'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Note'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (ctl.text.trim().isNotEmpty) {
                Navigator.of(context).pop(ctl.text.trim());
              }
            },
            child: const Text('Save note'),
          ),
        ],
      ),
    );
    if (text == null || !context.mounted) return;
    await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).addActivity({
        'kind': 'note',
        'subject': text,
        'dealId': detail.deal.id,
      }),
      done: 'Note saved.',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final d = detail.deal;
    final canManage = crmCan(ref, Perm.crmManage);
    final canQuote = crmCan(ref, Perm.quotationsManage);
    final stages = (ref.watch(crmStagesProvider).value ?? const <CrmStage>[])
        .where((s) => s.isActive && s.kind != 'lost')
        .toList();
    final overview = d.partyId == null
        ? null
        : ref.watch(crmOverviewProvider(d.partyId!)).value;
    final gutter = pageGutter(context);
    final nextAct = detail.activities
        .where((a) => !a.isDone && a.id == d.nextFollowUp?.id)
        .firstOrNull;
    final phone = overview?.phone;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: EdgeInsets.fromLTRB(gutter, Space.md, gutter, Space.xxl),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(d.title, style: theme.textTheme.headlineSmall),
                ),
                if (canManage && d.isOpen && stages.isNotEmpty)
                  PopupMenuButton<CrmStage>(
                    tooltip: 'Move to stage',
                    icon: const Icon(Icons.more_vert),
                    onSelected: (s) => _move(context, ref, s),
                    itemBuilder: (_) => [
                      for (final s in stages)
                        PopupMenuItem(
                          value: s,
                          enabled: s.id != d.stageId,
                          child: Text(
                            s.kind == 'won' ? 'Mark won' : 'Move to ${s.name}',
                          ),
                        ),
                      const PopupMenuItem(
                        value: CrmStage(id: '', name: 'Lost', probability: 0, kind: 'lost'),
                        child: Text('Mark lost'),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Wrap(
              spacing: Space.sm,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if ((d.partyName ?? '').isNotEmpty)
                  InkWell(
                    onTap: d.partyId == null
                        ? null
                        : () => context.push('/crm/customers/${d.partyId}'),
                    child: Text(
                      d.partyName!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                MoneyText(d.value, decimals: 0, style: theme.textTheme.titleSmall),
                if ((d.ownerName ?? '').isNotEmpty)
                  Text(d.ownerName!, style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: Space.md),
            if (d.isOpen)
              _Steps(
                stages: stages,
                current: d.stageId,
                onTap: canManage ? (s) => _move(context, ref, s) : null,
              )
            else
              Row(
                children: [
                  StatusChip(
                    d.status,
                    tone: d.status == 'won' ? StatusTone.success : StatusTone.neutral,
                  ),
                  if ((d.lostReason ?? '').isNotEmpty) ...[
                    const SizedBox(width: Space.sm),
                    Flexible(child: Text(d.lostReason!)),
                  ],
                  const Spacer(),
                  if (canManage)
                    TextButton(
                      onPressed: () => crmGuarded(
                        context,
                        ref,
                        () => ref.read(crmRepositoryProvider).reopenDeal(d.id),
                        done: 'Deal reopened.',
                      ),
                      child: const Text('Reopen'),
                    ),
                ],
              ),
            if (d.isOpen) ...[
              const SizedBox(height: Space.md),
              _NextStep(
                deal: d,
                activity: nextAct,
                phone: phone,
                canManage: canManage,
              ),
            ],
            const SizedBox(height: Space.md),
            if (overview != null) ...[
              accountSummary(overview),
              const SizedBox(height: Space.md),
            ],
            if (detail.quotations.isNotEmpty)
              SectionCard(
                title: 'Quotations',
                icon: Icons.request_quote_outlined,
                child: Column(
                  children: [
                    for (final q in detail.quotations)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(q.number),
                        subtitle: Text(formatDate(q.quoteDate)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MoneyText(q.total, decimals: 0),
                            const SizedBox(width: Space.sm),
                            StatusChip(q.status),
                          ],
                        ),
                        onTap: () => context.push('/quotations/${q.id}'),
                      ),
                  ],
                ),
              ),
            SectionCard(
              title: 'Timeline',
              icon: Icons.history,
              child: ActivityTimeline(events: dealEvents(detail)),
            ),
            if (canManage && d.isOpen)
              LayoutBuilder(
                builder: (context, c) {
                  final cols = c.maxWidth < 420 ? 2 : 4;
                  final w = (c.maxWidth - Space.sm * (cols - 1)) / cols;
                  Widget b(String label, IconData icon, VoidCallback f) => SizedBox(
                    width: w,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      onPressed: f,
                      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  );
                  return Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [
                      b('Note', Icons.notes, () => _note(context, ref)),
                      b(
                        'Task',
                        Icons.task_alt,
                        () => showAddFollowUp(context, dealId: d.id, kind: 'task'),
                      ),
                      if (canQuote)
                        b(
                          'Quotation',
                          Icons.request_quote_outlined,
                          () => context.push(
                            '/quotations/new?dealId=${d.id}${d.partyId == null ? '' : '&partyId=${d.partyId}'}',
                          ),
                        ),
                      b('Won / lost', Icons.flag_outlined, () => _closeChoice(context, ref)),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.stages, required this.current, this.onTap});

  final List<CrmStage> stages;
  final String current;
  final ValueChanged<CrmStage>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = stages.indexWhere((s) => s.id == current);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stages.length; i++)
          Expanded(
            child: InkWell(
              onTap: onTap == null ? null : () => onTap!(stages[i]),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: i <= at
                              ? theme.colorScheme.primary
                              : context.colors.hairline,
                          borderRadius: Radii.smallAll,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        stages[i].name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: i == at ? FontWeight.w700 : FontWeight.w500,
                          color: i == at
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _NextStep extends StatelessWidget {
  const _NextStep({
    required this.deal,
    required this.activity,
    required this.phone,
    required this.canManage,
  });

  final CrmDeal deal;
  final CrmActivity? activity;
  final String? phone;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = deal.nextFollowUp;
    final late = n != null && n.overdue;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.mediumAll,
        side: BorderSide(
          color: late ? context.colors.danger : context.colors.hairline,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              n == null
                  ? 'NEXT STEP'
                  : 'NEXT STEP · ${late ? 'OVERDUE' : 'DUE'} ${dueLabel(n.dueAt, prefix: '').trim().toUpperCase()}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: late ? context.colors.danger : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              n == null
                  ? 'Nothing planned. Add the next call, visit or task.'
                  : '${crmKindLabel(n.kind)}: ${n.subject}',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: Space.sm + 2),
            if (n == null)
              if (canManage)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                        onPressed: () => showAddFollowUp(context, dealId: deal.id),
                        child: const Text('Add follow-up'),
                      ),
                    ),
                  ],
                )
              else
                const SizedBox.shrink()
            else
              ContactButtons(
                phone: phone,
                name: deal.partyName ?? deal.title,
                onLog: canManage && activity != null
                    ? () => showLogOutcome(context, activity: activity)
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
