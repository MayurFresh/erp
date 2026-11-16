import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/activity_timeline.dart';
import '../../widgets/form_support.dart';
import '../../widgets/key_value_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_sheets.dart';
import 'crm_widgets.dart';

/// `/crm/leads/:id`.
class CrmLeadDetailScreen extends ConsumerWidget {
  const CrmLeadDetailScreen({super.key, required this.leadId});

  final String leadId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CrmGate(
      child: AsyncValueView(
        value: ref.watch(crmLeadProvider(leadId)),
        onRetry: () => ref.invalidate(crmLeadProvider(leadId)),
        data: (d) => _Body(detail: d),
      ),
    );
  }
}

/// Timeline events for activities, newest first.
List<TimelineEvent> activityEvents(List<CrmActivity> list) => [
  for (final a in list)
    TimelineEvent(
      title: a.isDone
          ? [
              crmKindLabel(a.kind),
              if (a.durationMin != null) '${a.durationMin} min',
              if ((a.outcome ?? '').isNotEmpty) a.outcome!,
            ].join(', ')
          : '${crmKindLabel(a.kind)} planned: ${a.subject}',
      detail: [
        if (a.isDone && a.subject.isNotEmpty && a.subject != crmKindLabel(a.kind)) a.subject,
        if ((a.notes ?? '').isNotEmpty) a.notes!,
      ].join('. '),
      when: formatDateTime(a.doneAt ?? a.dueAt ?? a.createdAt),
      tone: !a.isDone && a.overdue ? StatusTone.danger : StatusTone.neutral,
    ),
];

class _Body extends ConsumerWidget {
  const _Body({required this.detail});

  final LeadDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l = detail.lead;
    final canManage = crmCan(ref, Perm.crmManage);
    final gutter = pageGutter(context);
    final pending = detail.activities
        .where((a) => !a.isDone && a.id == l.nextFollowUp?.id)
        .firstOrNull;
    final open = !l.isClosed;

    Future<void> lose() async {
      final reasons = await ref
          .read(crmSettingsProvider.future)
          .then((s) => s.lostReasons, onError: (_) => const <String>[]);
    if (!context.mounted) return;
      final reason = await showReasonPicker(context, reasons: reasons);
      if (reason == null || !context.mounted) return;
      await crmGuarded(
        context,
        ref,
        () => ref.read(crmRepositoryProvider).loseLead(l.id, reason),
        done: 'Lead marked lost.',
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: EdgeInsets.fromLTRB(gutter, Space.md, gutter, Space.xxl),
          children: [
            Text(l.name, style: theme.textTheme.headlineSmall),
            if ((l.companyName ?? '').isNotEmpty)
              Text(l.companyName!, style: theme.textTheme.bodyMedium),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: Space.sm,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusChip(l.status),
                sourceChip(l.source),
                if ((l.estimatedValue ?? 0) > 0)
                  Text(
                    'Estimate ${crmMoney(l.estimatedValue)}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            if ((l.requirement ?? '').isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Text(l.requirement!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: Space.md),
            if (pending != null)
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(Space.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'NEXT STEP · ${dueLabel(pending.dueAt).toUpperCase()}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: pending.overdue
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${crmKindLabel(pending.kind)}: ${pending.subject}',
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: Space.sm),
                      ContactButtons(
                        phone: l.phone,
                        name: l.name,
                        onLog: canManage
                            ? () => showLogOutcome(context, activity: pending)
                            : null,
                      ),
                    ],
                  ),
                ),
              )
            else if (open && canManage) ...[
              ContactButtons(
                phone: l.phone,
                name: l.name,
                onLog: () => showLogOutcome(context, leadId: l.id),
              ),
              const SizedBox(height: Space.sm),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => showAddFollowUp(context, leadId: l.id),
                icon: const Icon(Icons.event_outlined),
                label: const Text('Add follow-up'),
              ),
            ],
            const SizedBox(height: Space.md),
            SectionCard(
              title: 'Details',
              icon: Icons.person_outline,
              child: KeyValueList(
                labelWidth: 120,
                items: [
                  if ((l.phone ?? '').isNotEmpty) KeyValue('Phone', l.phone!),
                  if ((l.email ?? '').isNotEmpty) KeyValue('Email', l.email!),
                  if ((l.city ?? '').isNotEmpty) KeyValue('City', l.city!),
                  KeyValue('Owner', l.ownerName ?? 'Not assigned'),
                  KeyValue('Added', formatDateTime(l.createdAt)),
                  if (l.status == 'lost' && (l.lostReason ?? '').isNotEmpty)
                    KeyValue('Lost because', l.lostReason!),
                  if ((l.partyName ?? '').isNotEmpty)
                    KeyValue('Customer', l.partyName!),
                ],
              ),
            ),
            if (detail.matches.isNotEmpty && open)
              SectionCard(
                title: 'Matching customers',
                icon: Icons.people_outline,
                child: Column(
                  children: [
                    for (final m in detail.matches)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(m.name),
                        subtitle: Text(
                          [
                            if ((m.phone ?? '').isNotEmpty) m.phone!,
                            if (m.balance > 0) 'owes ${crmMoney(m.balance)}',
                          ].join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/crm/customers/${m.partyId}'),
                      ),
                  ],
                ),
              ),
            SectionCard(
              title: 'Activity',
              icon: Icons.history,
              child: detail.activities.isEmpty
                  ? const Text('Nothing logged yet.')
                  : ActivityTimeline(events: activityEvents(detail.activities)),
            ),
            if (canManage && open) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => showConvertLead(context, ref, detail),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Convert to customer and deal'),
              ),
              const SizedBox(height: Space.sm),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: lose,
                child: const Text('Mark lost'),
              ),
            ],
            if (canManage && l.status == 'lost')
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => crmGuarded(
                  context,
                  ref,
                  () => ref.read(crmRepositoryProvider).reopenLead(l.id),
                  done: 'Lead reopened.',
                ),
                child: const Text('Reopen lead'),
              ),
            if (l.dealId != null)
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => context.push('/crm/deals/${l.dealId}'),
                child: const Text('Open deal'),
              ),
            if (l.status == 'converted' && l.partyId != null) ...[
              const SizedBox(height: Space.sm),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => context.push('/crm/customers/${l.partyId}'),
                child: const Text('Open customer'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> showConvertLead(
  BuildContext context,
  WidgetRef ref,
  LeadDetail detail,
) async {
  final result = await showFormDialog<Json>(
    context: context,
    builder: (_) => _ConvertDialog(detail: detail),
  );
  if (result == null || !context.mounted) return;
  ref.bumpCrm();
  final dealId = asStringOrNull(result['dealId']);
  final partyId = asStringOrNull(result['partyId']);
  context.push(
    dealId != null
        ? '/crm/deals/$dealId'
        : partyId != null
        ? '/crm/customers/$partyId'
        : '/crm/leads',
  );
}

class _ConvertDialog extends ConsumerStatefulWidget {
  const _ConvertDialog({required this.detail});

  final LeadDetail detail;

  @override
  ConsumerState<_ConvertDialog> createState() => _ConvertDialogState();
}

class _ConvertDialogState extends ConsumerState<_ConvertDialog> {
  late final CrmLead _lead = widget.detail.lead;
  late final _title = TextEditingController(
    text: (_lead.requirement ?? '').isNotEmpty ? _lead.requirement : _lead.name,
  );
  late final _value = TextEditingController(
    text: (_lead.estimatedValue ?? 0) > 0 ? formatPlain(_lead.estimatedValue) : '',
  );
  String _party = '';
  bool _deal = true;
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (_deal && _title.text.trim().isEmpty) {
      setState(() => _error = 'Give the deal a title.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(crmRepositoryProvider).convertLeadResult(
        _lead.id,
        {
          if (_party.isNotEmpty)
            'partyId': _party
          else
            'party': {
              'name': (_lead.companyName ?? '').isNotEmpty ? _lead.companyName : _lead.name,
              'phone': ?_lead.phone,
              'email': ?_lead.email,
            },
          'deal': _deal
              ? {
                  'title': _title.text.trim(),
                  'value': double.tryParse(_value.text.trim()) ?? 0,
                }
              : null,
        },
      );
      if (mounted) Navigator.of(context).pop(r);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = widget.detail.matches;
    return AlertDialog(
      title: const Text('Convert to customer and deal'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Customer', style: theme.textTheme.titleSmall),
              RadioGroup<String>(
                groupValue: _party,
                onChanged: (v) => setState(() => _party = v ?? ''),
                child: Column(
                  children: [
                    const RadioListTile<String>(
                      value: '',
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Create a new customer'),
                    ),
                    for (final m in matches)
                      RadioListTile<String>(
                        value: m.partyId,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('Use ${m.name}'),
                        subtitle: (m.phone ?? '').isEmpty ? null : Text(m.phone!),
                      ),
                  ],
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Create a deal'),
                value: _deal,
                onChanged: (v) => setState(() => _deal = v),
              ),
              if (_deal) ...[
                TextField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: 'Deal title'),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: _value,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Deal value',
                    prefixText: '₹ ',
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: Space.md),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Converting' : 'Convert'),
        ),
      ],
    );
  }
}
