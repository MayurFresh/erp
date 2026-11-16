import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/activity_timeline.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_sheets.dart';
import 'crm_widgets.dart';
import 'deals_screen.dart' show DealCard;

/// `/crm/customers/:partyId`: account summary and everything that happened.
class CrmCustomerScreen extends ConsumerWidget {
  const CrmCustomerScreen({super.key, required this.partyId});

  final String partyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CrmGate(
      child: AsyncValueView(
        value: ref.watch(crmOverviewProvider(partyId)),
        onRetry: () => ref.invalidate(crmOverviewProvider(partyId)),
        data: (o) => _Body(overview: o),
      ),
    );
  }
}

StatusTone _tone(String kind) => switch (kind) {
  'payment' => StatusTone.success,
  'credit_note' => StatusTone.warning,
  'quotation' => StatusTone.info,
  _ => StatusTone.neutral,
};

String _kindWord(String kind) => switch (kind) {
  'credit_note' => 'Credit note',
  'lead' => 'Enquiry',
  final k => k.isEmpty ? k : k[0].toUpperCase() + k.substring(1),
};

class _Body extends ConsumerWidget {
  const _Body({required this.overview});

  final PartyOverview overview;

  Future<void> _newDeal(BuildContext context, WidgetRef ref) async {
    final title = TextEditingController();
    final value = TextEditingController();
    final body = await showDialog<Json>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New deal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Deal title'),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: value,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Value', prefixText: '₹ '),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (title.text.trim().isEmpty) return;
              Navigator.of(context).pop({
                'title': title.text.trim(),
                'partyId': overview.partyId,
                'value': double.tryParse(value.text.trim()) ?? 0,
              });
            },
            child: const Text('Add deal'),
          ),
        ],
      ),
    );
    if (body == null || !context.mounted) return;
    await crmGuarded(
      context,
      ref,
      () => ref.read(crmRepositoryProvider).addDeal(body),
      done: 'Deal added.',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final o = overview;
    final canManage = crmCan(ref, Perm.crmManage);
    final gutter = pageGutter(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: EdgeInsets.fromLTRB(gutter, Space.md, gutter, Space.xxl),
          children: [
            Text(o.name, style: theme.textTheme.headlineSmall),
            Text(
              [
                if ((o.phone ?? '').isNotEmpty) o.phone!,
                if ((o.email ?? '').isNotEmpty) o.email!,
                if ((o.gstin ?? '').isNotEmpty) o.gstin!,
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            ContactButtons(
              phone: o.phone,
              name: o.name,
              logLabel: 'Log outcome',
              onLog: canManage
                  ? () => showLogOutcome(context, partyId: o.partyId)
                  : null,
            ),
            const SizedBox(height: Space.md),
            accountSummary(o),
            const SizedBox(height: Space.md),
            SectionCard(
              title: 'Open deals',
              icon: Icons.handshake_outlined,
              trailing: canManage
                  ? TextButton(
                      onPressed: () => _newDeal(context, ref),
                      child: const Text('New deal'),
                    )
                  : null,
              child: o.openDeals.isEmpty
                  ? const Text('No open deals.')
                  : Column(
                      children: [
                        for (final d in o.openDeals) ...[
                          DealCard(deal: d),
                          const SizedBox(height: Space.sm),
                        ],
                      ],
                    ),
            ),
            if (o.contacts.isNotEmpty)
              SectionCard(
                title: 'Contact persons',
                icon: Icons.people_outline,
                child: Column(
                  children: [
                    for (final c in o.contacts)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(asString(c['name'])),
                        subtitle: Text(
                          [
                            asString(c['designation']),
                            asString(c['phone']),
                          ].where((s) => s.isNotEmpty).join(' · '),
                        ),
                      ),
                  ],
                ),
              ),
            SectionCard(
              title: 'Timeline',
              icon: Icons.history,
              child: o.timeline.isEmpty
                  ? const Text('Nothing recorded yet.')
                  : ActivityTimeline(
                      events: [
                        for (final t in o.timeline)
                          TimelineEvent(
                            title: '${_kindWord(t.kind)}: ${t.title}',
                            detail: [
                              if ((t.detail ?? '').isNotEmpty) t.detail!,
                              if (t.amount != null) formatMoney(t.amount),
                            ].join(' · '),
                            when: formatDateTime(t.at),
                            tone: _tone(t.kind),
                          ),
                      ],
                    ),
            ),
            if (crmCan(ref, Perm.crmView) && o.openDeals.isNotEmpty)
              TextButton(
                onPressed: () => context.push('/crm/deals'),
                child: const Text('All deals'),
              ),
          ],
        ),
      ),
    );
  }
}
