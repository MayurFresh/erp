import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate, bigButton;
import 'helpdesk_models.dart';
import 'helpdesk_repository.dart';
import 'ticket_list_screen.dart' show priorityTone, ticketTone;

const _nextStatuses = {
  'new': ['open', 'waiting', 'resolved', 'closed'],
  'open': ['waiting', 'resolved', 'closed'],
  'waiting': ['open', 'resolved', 'closed'],
  'resolved': ['open', 'closed'],
  'closed': ['open'],
};

String _actionLabel(String from, String to) => switch (to) {
  'open' => from == 'closed' || from == 'resolved' ? 'Reopen' : 'Mark open',
  'waiting' => 'Wait for customer',
  'resolved' => 'Mark resolved',
  _ => 'Close',
};

/// `/helpdesk/:id`: the ticket as a conversation with replies and internal notes.
class TicketDetailScreen extends ConsumerStatefulWidget {
  const TicketDetailScreen({super.key, required this.ticketId});

  final String ticketId;

  @override
  ConsumerState<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends ConsumerState<TicketDetailScreen> {
  final _body = TextEditingController();
  String _kind = 'reply';
  bool _busy = false;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
      ref.read(helpdeskRevisionProvider.notifier).bump();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final text = _body.text.trim();
    if (text.isEmpty) return;
    await _run(() async {
      await ref.read(helpdeskRepositoryProvider).addMessage(widget.ticketId, {
        'kind': _kind,
        'body': text,
      });
      _body.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(ticketDetailProvider(widget.ticketId));
    final canManage = ref.watch(permissionsProvider).can(Perm.helpdeskManage);
    final staff =
        ref.watch(helpdeskStaffProvider).value ??
        const <({String id, String name})>[];
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.helpdeskView, Perm.helpdeskManage],
      child: AsyncValueView<Ticket>(
        value: async,
        onRetry: () => ref.invalidate(ticketDetailProvider),
        data: (t) => Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(gutter),
                children: [
                  _Header(ticket: t),
                  if (canManage) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      key: ValueKey('assignee-${t.assigneeId}'),
                      initialValue: staff.any((s) => s.id == t.assigneeId)
                          ? t.assigneeId
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Assigned to',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Unassigned'),
                        ),
                        for (final s in staff)
                          DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => _run(
                              () async => ref
                                  .read(helpdeskRepositoryProvider)
                                  .updateTicket(t.id, {'assigneeId': v}),
                            ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final to
                            in _nextStatuses[t.status] ?? const <String>[])
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () async => ref
                                        .read(helpdeskRepositoryProvider)
                                        .setStatus(t.id, to),
                                  ),
                            child: Text(_actionLabel(t.status, to)),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Conversation',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (t.description != null && t.description!.isNotEmpty)
                    _Bubble(
                      kind: 'customer',
                      author: t.partyName,
                      body: t.description!,
                      when: null,
                    ),
                  for (final m in t.messages)
                    _Bubble(
                      kind: m.kind,
                      author: m.author,
                      body: m.body,
                      when: m.createdAt,
                    ),
                ],
              ),
            ),
            if (canManage && t.status != 'closed')
              Material(
                elevation: 4,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'reply', label: Text('Reply')),
                          ButtonSegment(
                            value: 'note',
                            label: Text('Internal note'),
                          ),
                          ButtonSegment(
                            value: 'customer',
                            label: Text('Customer said'),
                          ),
                        ],
                        selected: {_kind},
                        onSelectionChanged: (s) =>
                            setState(() => _kind = s.first),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _body,
                              minLines: 1,
                              maxLines: 5,
                              decoration: InputDecoration(
                                hintText: _kind == 'reply'
                                    ? 'Write a reply to the customer'
                                    : _kind == 'note'
                                    ? 'Write a note for your team'
                                    : 'What did the customer say',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            style: bigButton,
                            onPressed: _busy ? null : _send,
                            child: const Text('Send'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.ticket});

  final Ticket ticket;

  @override
  Widget build(BuildContext context) {
    final t = ticket;
    final theme = Theme.of(context);
    Widget sla(String label, SlaState s) => Text(
      '$label: ${slaText(s)}',
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: s.breached ? theme.colorScheme.error : null,
      ),
    );
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.number, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(t.subject, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => context.go('/parties/${t.partyId}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                t.partyName,
                style: theme.textTheme.bodyLarge?.copyWith(
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              StatusChip(
                t.status,
                label: ticketStatusLabel(t.status),
                tone: ticketTone(t.status),
              ),
              StatusChip(
                t.priority,
                label: sentence(t.priority),
                tone: priorityTone(t.priority),
              ),
              Pill(ticketChannels[t.channel] ?? t.channel),
              if (t.category != null) Pill(t.category!),
            ],
          ),
          const SizedBox(height: 8),
          sla('First response', t.response),
          sla('Resolution', t.resolution),
          if (t.slaPaused)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('The SLA clock is paused while we wait on the customer.'),
            ),
          if (t.serialNo != null) Text('Serial number ${t.serialNo}'),
          if (t.contractNumber != null)
            InkWell(
              onTap: t.contractId == null
                  ? null
                  : () => context.go('/service-contracts/${t.contractId}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  t.covered
                      ? 'Covered by contract ${t.contractNumber}'
                      : 'Contract ${t.contractNumber} has ended',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.kind,
    required this.author,
    required this.body,
    required this.when,
  });

  final String kind;
  final String author;
  final String body;
  final DateTime? when;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (kind == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final reply = kind == 'reply';
    final note = kind == 'note';
    final scheme = theme.colorScheme;
    final bg = note
        ? scheme.tertiaryContainer
        : reply
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final who = note
        ? 'Internal note, $author'
        : kind == 'customer'
        ? author
        : 'You to customer, $author';
    return Align(
      alignment: reply ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              when == null ? who : '$who  ·  ${_stamp(when!)}',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 4),
            Text(body),
          ],
        ),
      ),
    );
  }
}

String _stamp(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
