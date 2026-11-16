import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_widgets.dart';

/// `₹6.1 L`, `₹1.2 Cr`, below a lakh in full.
String lakhs(num v) {
  final a = v.abs();
  if (a >= 1e7) return '₹${(a / 1e7).toStringAsFixed(1)} Cr';
  if (a >= 1e5) return '₹${(a / 1e5).toStringAsFixed(1)} L';
  return crmMoney(v);
}

/// Wide enough for one column per stage.
const double crmBoardWidth = 1100;

/// `/crm/deals`: the open pipeline, by stage.
class CrmDealsScreen extends ConsumerStatefulWidget {
  const CrmDealsScreen({super.key});

  @override
  ConsumerState<CrmDealsScreen> createState() => _CrmDealsScreenState();
}

class _CrmDealsScreenState extends ConsumerState<CrmDealsScreen> {
  String _status = 'open';
  String? _stageId;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    return CrmGate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Sales', actions: [CrmOwnerFilter()]),
          const CrmTabs(current: '/crm/deals'),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.sm),
            child: Wrap(
              spacing: Space.sm,
              children: [
                for (final (v, l) in const [
                  ('open', 'Open'),
                  ('won', 'Won'),
                  ('lost', 'Lost'),
                ])
                  ChoiceChip(
                    label: Text(l),
                    selected: _status == v,
                    onSelected: (_) => setState(() {
                      _status = v;
                      _stageId = null;
                    }),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(crmDealsProvider(_status)),
              onRetry: () => ref.invalidate(crmDealsProvider(_status)),
              data: (deals) => _status == 'open'
                  ? _OpenView(
                      deals: deals,
                      stageId: _stageId,
                      onStage: (id) => setState(() => _stageId = id),
                    )
                  : _ClosedList(deals: deals, status: _status),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosedList extends StatelessWidget {
  const _ClosedList({required this.deals, required this.status});

  final List<CrmDeal> deals;
  final String status;

  @override
  Widget build(BuildContext context) {
    if (deals.isEmpty) {
      return EmptyView(message: 'No $status deals yet.');
    }
    final gutter = pageGutter(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView.separated(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
          itemCount: deals.length,
          separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
          itemBuilder: (_, i) => DealCard(deal: deals[i]),
        ),
      ),
    );
  }
}

class _OpenView extends ConsumerWidget {
  const _OpenView({required this.deals, required this.stageId, required this.onStage});

  final List<CrmDeal> deals;
  final String? stageId;
  final ValueChanged<String?> onStage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pipeline = ref.watch(crmPipelineProvider).value;
    final gutter = pageGutter(context);
    final wide = MediaQuery.sizeOf(context).width >= crmBoardWidth;
    final shown = stageId == null
        ? deals
        : deals.where((d) => d.stageId == stageId).toList();
    final board = wide && stageId == null && pipeline != null && deals.isNotEmpty;

    final header = <Widget>[
      if (pipeline != null) ...[
        _Funnel(pipeline: pipeline),
        const SizedBox(height: Space.sm),
        _StageChips(pipeline: pipeline, selected: stageId, onSelected: onStage),
        const SizedBox(height: Space.md),
      ],
    ];

    if (deals.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
        children: [
          ...header,
          const SizedBox(height: Space.xl),
          const Center(
            child: Text('No open deals. Convert a lead to start one.'),
          ),
        ],
      );
    }

    if (board) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: _Funnel(pipeline: pipeline),
          ),
          const SizedBox(height: Space.md),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in pipeline.stages)
                    _BoardColumn(
                      stage: s,
                      deals: deals.where((d) => d.stageId == s.stageId).toList(),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
          children: [
            ...header,
            if (shown.isEmpty)
              const Padding(
                padding: EdgeInsets.all(Space.lg),
                child: Center(child: Text('No deals in this stage.')),
              ),
            for (final d in shown) ...[
              DealCard(deal: d),
              const SizedBox(height: Space.sm),
            ],
          ],
        ),
      ),
    );
  }
}

Color _shade(BuildContext context, int i, int n) {
  final p = Theme.of(context).colorScheme.primary;
  final t = n <= 1 ? 1.0 : 0.3 + 0.7 * i / (n - 1);
  return p.withValues(alpha: t);
}

class _Funnel extends StatelessWidget {
  const _Funnel({required this.pipeline});

  final Pipeline pipeline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = pipeline;
    final stages = p.stages.where((s) => s.value > 0).toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: Space.md,
              runSpacing: 2,
              children: [
                Text(
                  'Open pipeline, ${p.openCount} ${p.openCount == 1 ? 'deal' : 'deals'}',
                  style: theme.textTheme.bodySmall,
                ),
                Text.rich(
                  TextSpan(
                    style: theme.textTheme.bodySmall,
                    children: [
                      const TextSpan(text: 'weighted '),
                      TextSpan(
                        text: crmMoney(p.weightedValue),
                        style: theme.textTheme.titleSmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            MoneyText(
              p.openValue,
              decimals: 0,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (stages.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              ClipRRect(
                borderRadius: Radii.smallAll,
                child: SizedBox(
                  height: 10,
                  child: Row(
                    children: [
                      for (var i = 0; i < stages.length; i++)
                        Expanded(
                          flex: (stages[i].value * 100).round().clamp(1, 1 << 30),
                          child: ColoredBox(
                            color: _shade(context, i, stages.length),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.md,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < stages.length; i++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _shade(context, i, stages.length),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${stages[i].name} ${lakhs(stages[i].value)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StageChips extends StatelessWidget {
  const _StageChips({
    required this.pipeline,
    required this.selected,
    required this.onSelected,
  });

  final Pipeline pipeline;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget chip(String? id, String top, String bottom) {
      final on = selected == id;
      return Padding(
        padding: const EdgeInsets.only(right: Space.sm),
        child: Material(
          color: on ? theme.colorScheme.primaryContainer : theme.colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: Radii.mediumAll,
            side: BorderSide(
              color: on ? theme.colorScheme.primary : context.colors.hairline,
            ),
          ),
          child: InkWell(
            borderRadius: Radii.mediumAll,
            onTap: () => onSelected(on ? null : id),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 84),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(top, style: theme.textTheme.bodySmall),
                    Text(bottom, style: theme.textTheme.titleSmall),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final s in pipeline.stages)
            chip(s.stageId, '${s.name} · ${s.count}', lakhs(s.value)),
        ],
      ),
    );
  }
}

class _BoardColumn extends StatelessWidget {
  const _BoardColumn({required this.stage, required this.deals});

  final PipelineStage stage;
  final List<CrmDeal> deals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 300,
      margin: const EdgeInsets.only(right: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    '${stage.name} · ${stage.count}',
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(lakhs(stage.value), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: Space.xxl),
              itemCount: deals.length,
              separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
              itemBuilder: (_, i) => DealCard(deal: deals[i]),
            ),
          ),
        ],
      ),
    );
  }
}

String initials(String? name) {
  final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  if (parts.isEmpty) return '';
  final l = parts.toList();
  return (l.first[0] + (l.length > 1 ? l.last[0] : '')).toUpperCase();
}

class DealCard extends StatelessWidget {
  const DealCard({super.key, required this.deal});

  final CrmDeal deal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = deal;
    final owes = owesText(d.partyBalance, crmMoney);
    final sub = [
      if ((d.partyName ?? '').isNotEmpty && d.partyName != d.title) d.partyName!,
      if (d.quotationCount > 0)
        '${d.quotationCount} ${d.quotationCount == 1 ? 'quotation' : 'quotations'}',
    ].join(' · ');
    final next = d.nextFollowUp;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/crm/deals/${d.id}'),
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      d.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  MoneyText(d.value, decimals: 0, style: theme.textTheme.titleMedium),
                ],
              ),
              if (sub.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(sub, style: theme.textTheme.bodySmall),
                ),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.sm,
                runSpacing: 4,
                children: [
                  if (!d.isOpen)
                    StatusChip(d.status, tone: d.status == 'won' ? StatusTone.success : StatusTone.neutral)
                  else ...[
                    if (d.followUpOverdue)
                      const StatusChip('overdue', label: 'Follow-up overdue'),
                    if (owes != null)
                      StatusChip(
                        'warn',
                        label: owes[0].toUpperCase() + owes.substring(1),
                        tone: StatusTone.warning,
                      ),
                    if (d.daysInStage >= 14)
                      StatusChip(
                        'warn',
                        label: '${d.daysInStage} days in this stage',
                        tone: StatusTone.warning,
                      ),
                    StatusChip(
                      'info',
                      label: '${d.effectiveProbability.round()}%',
                      tone: StatusTone.info,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      !d.isOpen
                          ? (d.lostReason ?? '')
                          : next == null
                          ? 'No next step set'
                          : 'Next: ${next.subject.isEmpty ? crmKindLabel(next.kind).toLowerCase() : next.subject}, ${dueLabel(next.dueAt, prefix: '').trim()}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: next == null && d.isOpen
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (initials(d.ownerName).isNotEmpty)
                    Tooltip(
                      message: d.ownerName ?? '',
                      child: CircleAvatar(
                        radius: 13,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Text(
                          initials(d.ownerName),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
