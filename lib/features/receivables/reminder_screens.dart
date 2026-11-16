import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'receivables_models.dart';
import 'receivables_repository.dart';
import 'receivables_widgets.dart';

/// `/reminders`: the rules for automatic payment reminders.
class ReminderSettingsScreen extends ConsumerWidget {
  const ReminderSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => RGate(
    anyOf: const [Perm.paymentsView],
    child: AsyncValueView<ReminderSettings>(
      value: ref.watch(reminderSettingsProvider),
      onRetry: () => ref.invalidate(reminderSettingsProvider),
      data: (s) => _SettingsForm(
        key: ValueKey('${s.summary}${s.enabled}${s.overdueInterestPct}'),
        initial: s,
      ),
    ),
  );
}

class _SettingsForm extends ConsumerStatefulWidget {
  const _SettingsForm({super.key, required this.initial});

  final ReminderSettings initial;

  @override
  ConsumerState<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends ConsumerState<_SettingsForm> {
  late bool _enabled = widget.initial.enabled;
  late bool _before = widget.initial.daysBefore != null;
  late bool _onDue = widget.initial.onDueDate;
  late final _daysBefore = TextEditingController(
    text: '${widget.initial.daysBefore ?? 3}',
  );
  late final _every = TextEditingController(
    text: '${widget.initial.repeatEveryDays}',
  );
  late final _max = TextEditingController(text: '${widget.initial.maxRepeats}');
  late final _interest = TextEditingController(
    text: widget.initial.overdueInterestPct == 0
        ? ''
        : '${widget.initial.overdueInterestPct}',
  );
  late final Set<String> _channels = widget.initial.channels.toSet();
  bool _saving = false;
  bool _running = false;

  @override
  void dispose() {
    _daysBefore.dispose();
    _every.dispose();
    _max.dispose();
    _interest.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(receivablesRepositoryProvider)
          .saveReminderSettings(
            ReminderSettings(
              enabled: _enabled,
              daysBefore: _before ? int.tryParse(_daysBefore.text) ?? 3 : null,
              onDueDate: _onDue,
              repeatEveryDays: int.tryParse(_every.text) ?? 7,
              maxRepeats: int.tryParse(_max.text) ?? 0,
              channels: _channels.toList(),
              overdueInterestPct: parseNumber(_interest.text) ?? 0,
            ),
          );
      ref.read(receivablesRevisionProvider.notifier).bump();
      if (mounted) showInfoSnackBar(context, 'Reminder settings saved');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _runNow() async {
    setState(() => _running = true);
    try {
      final r = await ref.read(receivablesRepositoryProvider).runReminders();
      ref.read(receivablesRevisionProvider.notifier).bump();
      if (!mounted) return;
      showInfoSnackBar(
        context,
        !r.enabled
            ? 'Reminders are off. Turn them on and save first.'
            : r.parties == 0
            ? 'No reminders are due today'
            : '${r.queued} reminders queued, ${r.skipped} skipped (no email or phone)',
      );
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Widget _number(
    TextEditingController c,
    String label, {
    bool enabled = true,
  }) => TextFormField(
    controller: c,
    enabled: enabled,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(labelText: label),
  );

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(Perm.paymentsCreate);
    final theme = Theme.of(context);
    return FormPage(
      maxWidth: 900,
      bottomBar: manage
          ? FormActionBar(
              children: [
                OutlinedButton.icon(
                  onPressed: _running ? null : _runNow,
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: const Text('Run now'),
                ),
                BusyButton(
                  busy: _saving,
                  onPressed: _save,
                  label: 'Save settings',
                  icon: Icons.check,
                ),
              ],
            )
          : null,
      children: [
        Text('Payment reminders', style: theme.textTheme.headlineSmall),
        SectionCard(
          title: 'Automatic reminders',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Send reminders for unpaid invoices'),
                subtitle: const Text(
                  'Checked once a day at 10:00. One message per customer per day.',
                ),
                value: _enabled,
                onChanged: manage ? (v) => setState(() => _enabled = v) : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Before the due date'),
                value: _before,
                onChanged: manage ? (v) => setState(() => _before = v) : null,
              ),
              if (_before)
                _number(_daysBefore, 'Days before due date', enabled: manage),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('On the due date'),
                value: _onDue,
                onChanged: manage ? (v) => setState(() => _onDue = v) : null,
              ),
              const SizedBox(height: 8),
              FormRow(
                children: [
                  _number(_every, 'Then every (days) after due', enabled: manage),
                  _number(_max, 'Up to (times, 0 for none)', enabled: manage),
                ],
              ),
              const SizedBox(height: 12),
              Text('Send by', style: theme.textTheme.titleSmall),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in const ['email', 'whatsapp'])
                    FilterChip(
                      key: ValueKey('channel-$c'),
                      label: Text(c == 'email' ? 'Email' : 'WhatsApp'),
                      selected: _channels.contains(c),
                      onSelected: manage
                          ? (v) => setState(
                              () => v ? _channels.add(c) : _channels.remove(c),
                            )
                          : null,
                    ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Interest on overdue bills',
          child: TextFormField(
            controller: _interest,
            enabled: manage,
            keyboardType: decimalKeyboard,
            inputFormatters: [decimalInput(decimals: 2)],
            decoration: const InputDecoration(
              labelText: 'Yearly interest % (0 for none)',
              helperText:
                  'Shown on statements for each overdue bill. It is never posted to the books.',
            ),
          ),
        ),
        const _ExcludedCard(),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => context.go('/reminders/log'),
            icon: const Icon(Icons.history),
            label: const Text('See what was sent'),
          ),
        ),
      ],
    );
  }
}

class _ExcludedCard extends ConsumerWidget {
  const _ExcludedCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(excludedPartiesProvider);
    final manage = ref.watch(permissionsProvider).can(Perm.partiesEdit);
    final repo = ref.read(receivablesRepositoryProvider);
    Future<void> set(String id, bool v) async {
      try {
        await repo.setDoNotRemind(id, v);
        ref.read(receivablesRevisionProvider.notifier).bump();
      } catch (e) {
        if (context.mounted) showErrorSnackBar(context, e);
      }
    }

    return SectionCard(
      title: 'Customers who are not reminded',
      trailing: manage
          ? TextButton.icon(
              onPressed: () async {
                final p = await pickParty(
                  context,
                  ref,
                  type: PartyType.customer,
                );
                if (p != null) await set(p.id, true);
              },
              icon: const Icon(Icons.add),
              label: const Text('Add customer'),
            )
          : null,
      child: list.when(
        loading: () => const Text('Loading...'),
        error: (e, _) => const Text('Could not load the list.'),
        data: (rows) => rows.isEmpty
            ? const Text('Every customer gets reminders.')
            : Column(
                children: [
                  for (final r in rows)
                    ListTile(
                      key: ValueKey('excluded-${r.partyId}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(r.name),
                      trailing: manage
                          ? IconButton(
                              tooltip: 'Remind again',
                              icon: const Icon(Icons.close),
                              onPressed: () => set(r.partyId, false),
                            )
                          : null,
                    ),
                ],
              ),
      ),
    );
  }
}

/// `/reminders/log`: what was queued, for which invoice and step.
class ReminderLogScreen extends ConsumerWidget {
  const ReminderLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => RGate(
    anyOf: const [Perm.paymentsView],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Reminder log'),
        Expanded(
          child: AsyncValueView<List<ReminderLogEntry>>(
            value: ref.watch(reminderLogProvider),
            onRetry: () => ref.invalidate(reminderLogProvider),
            data: (rows) => rows.isEmpty
                ? const EmptyView(
                    icon: Icons.notifications_none,
                    message:
                        'No reminders have been sent yet.\nTurn them on in the reminder settings.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      pageGutter(context),
                      0,
                      pageGutter(context),
                      24,
                    ),
                    children: [
                      for (final r in rows)
                        Card(
                          margin: const EdgeInsets.only(bottom: 6),
                          child: ListTile(
                            key: ValueKey('log-${r.id}'),
                            title: Text('${r.partyName}: ${r.invoiceNumber}'),
                            subtitle: Text(
                              [
                                r.stepLabel,
                                formatDate(r.runDate),
                                if (r.channels.isNotEmpty)
                                  r.channels
                                      .map((c) => c == 'email' ? 'Email' : 'WhatsApp')
                                      .join(' and '),
                                if (r.note != null) r.note!,
                              ].join('  |  '),
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(formatMoney(r.amount)),
                                StatusChip(
                                  r.status == 'skipped'
                                      ? 'Skipped'
                                      : switch (r.delivery) {
                                          'sent' => 'Sent',
                                          'failed' => 'Failed',
                                          _ => 'Queued',
                                        },
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    ),
  );
}
