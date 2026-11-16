import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton;
import 'helpdesk_models.dart';
import 'helpdesk_repository.dart';

StatusTone priorityTone(String p) => switch (p) {
  'urgent' => StatusTone.danger,
  'high' => StatusTone.warning,
  'medium' => StatusTone.info,
  _ => StatusTone.neutral,
};

StatusTone ticketTone(String s) => switch (s) {
  'new' => StatusTone.info,
  'open' => StatusTone.info,
  'waiting' => StatusTone.warning,
  _ => StatusTone.success,
};

/// `/helpdesk`: tickets with their SLA countdowns, most urgent first.
class TicketListScreen extends ConsumerStatefulWidget {
  const TicketListScreen({super.key});

  @override
  ConsumerState<TicketListScreen> createState() => _TicketListScreenState();
}

class _TicketListScreenState extends ConsumerState<TicketListScreen> {
  String _status = 'open';
  bool _mine = false;
  String _q = '';

  static const _filters = {
    'open': 'Open',
    'breached': 'Breached',
    'resolved': 'Resolved',
    '': 'All',
  };

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final tickets = ref.watch(
      ticketListProvider((status: _status, mine: _mine, q: _q)),
    );
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.helpdeskView, Perm.helpdeskManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Helpdesk',
            actions: [
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => context.go('/helpdesk/reports'),
                icon: const Icon(Icons.bar_chart_outlined),
                label: const Text('Reports'),
              ),
              if (perms.can(Perm.helpdeskManage))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/helpdesk/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New ticket'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
            child: SearchField(
              hintText: 'Search number, subject, customer or serial',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final e in _filters.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _status == e.key,
                    onSelected: (_) => setState(() => _status = e.key),
                  ),
                FilterChip(
                  label: const Text('Assigned to me'),
                  selected: _mine,
                  onSelected: (v) => setState(() => _mine = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView<List<Ticket>>(
              value: tickets,
              onRetry: () => ref.invalidate(ticketListProvider),
              data: (list) => list.isEmpty
                  ? const EmptyView(message: 'No tickets match.')
                  : ListView.separated(
                      padding: EdgeInsets.all(gutter),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => TicketTile(ticket: list[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class TicketTile extends StatelessWidget {
  const TicketTile({super.key, required this.ticket});

  final Ticket ticket;

  @override
  Widget build(BuildContext context) {
    final t = ticket;
    final theme = Theme.of(context);
    final sla = t.status == 'new' && !t.response.breached
        ? t.response
        : t.resolution;
    final slaLabel = t.isOpen
        ? '${t.status == 'new' ? 'Reply' : 'Resolve'}: ${slaText(sla)}'
        : 'Resolution ${slaText(t.resolution).toLowerCase()}';
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => context.go('/helpdesk/${t.id}'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${t.number}  ${t.subject}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusChip(
                      t.status,
                      label: ticketStatusLabel(t.status),
                      tone: ticketTone(t.status),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    t.partyName,
                    if (t.assigneeName != null) t.assigneeName!,
                    if (t.covered) 'Under contract',
                  ].join('  ·  '),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusChip(
                      t.priority,
                      label: sentence(t.priority),
                      tone: priorityTone(t.priority),
                    ),
                    Text(
                      slaLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: t.breached ? theme.colorScheme.error : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
