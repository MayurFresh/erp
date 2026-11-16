import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/design_tokens.dart';
import '../../widgets/states.dart';
import 'crm_models.dart';
import 'crm_repository.dart';

const crmOutcomeChips = [
  'Interested',
  'Call back',
  'Not reachable',
  'Sent quotation',
  'Not interested',
];

/// Source of "now" so tests can fix the clock.
DateTime Function() crmClock = DateTime.now;

DateTime _at11(DateTime d) => DateTime(d.year, d.month, d.day, 11);

/// The quick choices for a next follow-up.
({String label, DateTime? at}) _quick(int i, DateTime now) => switch (i) {
  0 => (label: 'Tomorrow 11 am', at: _at11(now.add(const Duration(days: 1)))),
  1 => (label: 'In 3 days', at: _at11(now.add(const Duration(days: 3)))),
  2 => (label: 'Next week', at: _at11(now.add(const Duration(days: 7)))),
  _ => (label: 'Pick date and time', at: null),
};

/// Chips for choosing when something is due; tapping the chosen one clears it.
class WhenPicker extends StatefulWidget {
  const WhenPicker({super.key, required this.value, required this.onChanged});

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  State<WhenPicker> createState() => _WhenPickerState();
}

class _WhenPickerState extends State<WhenPicker> {
  int? _chosen;

  Future<void> _pick() async {
    final now = crmClock();
    final date = await showDatePicker(
      context: context,
      initialDate: widget.value ?? now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 730)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 11, minute: 0),
    );
    if (time == null || !mounted) return;
    setState(() => _chosen = 3);
    widget.onChanged(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = crmClock();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (var i = 0; i < 4; i++)
              ChoiceChip(
                label: Text(_quick(i, now).label),
                selected: _chosen == i && widget.value != null,
                onSelected: (on) {
                  if (i == 3) {
                    _pick();
                  } else if (on) {
                    setState(() => _chosen = i);
                    widget.onChanged(_quick(i, now).at);
                  } else {
                    setState(() => _chosen = null);
                    widget.onChanged(null);
                  }
                },
              ),
          ],
        ),
        if (widget.value != null) ...[
          const SizedBox(height: Space.xs + 2),
          Text(
            DateFormat('EEE d MMM, h:mm a').format(widget.value!),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

Future<bool> _sheet(BuildContext context, Widget child) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => child,
  );
  return r ?? false;
}

/// Outcome of a call or visit. With an [activity] it marks that follow-up
/// done; without one it records what happened on a lead, deal or customer.
Future<bool> showLogOutcome(
  BuildContext context, {
  CrmActivity? activity,
  String? leadId,
  String? dealId,
  String? partyId,
}) => _sheet(
  context,
  _OutcomeSheet(
    activity: activity,
    leadId: leadId ?? activity?.leadId,
    dealId: dealId ?? activity?.dealId,
    partyId: partyId,
  ),
);

/// A planned follow-up on a lead or deal.
Future<bool> showAddFollowUp(
  BuildContext context, {
  String? leadId,
  String? dealId,
  String? partyId,
  String kind = 'call',
}) => _sheet(
  context,
  _FollowUpSheet(leadId: leadId, dealId: dealId, partyId: partyId, kind: kind),
);

Widget _kindField(String value, ValueChanged<String> onChanged, {bool note = false}) =>
    DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(labelText: 'Kind'),
      items: [
        for (final k in crmActivityKinds)
          if (note || k.$1 != 'note')
            DropdownMenuItem(value: k.$1, child: Text(k.$2)),
      ],
      onChanged: (v) => onChanged(v ?? value),
    );

EdgeInsets _sheetPad(BuildContext context) => EdgeInsets.fromLTRB(
  Space.md,
  0,
  Space.md,
  MediaQuery.viewInsetsOf(context).bottom + Space.md,
);

class _OutcomeSheet extends ConsumerStatefulWidget {
  const _OutcomeSheet({this.activity, this.leadId, this.dealId, this.partyId});

  final CrmActivity? activity;
  final String? leadId, dealId, partyId;

  @override
  ConsumerState<_OutcomeSheet> createState() => _OutcomeSheetState();
}

class _OutcomeSheetState extends ConsumerState<_OutcomeSheet> {
  final _outcome = TextEditingController();
  final _notes = TextEditingController();
  final _minutes = TextEditingController();
  final _subject = TextEditingController(text: 'Follow up');
  String _happened = 'call';
  String _nextKind = 'call';
  DateTime? _next;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _outcome.dispose();
    _notes.dispose();
    _minutes.dispose();
    _subject.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final outcome = _outcome.text.trim();
    if (outcome.isEmpty) {
      setState(() => _error = 'Say what happened, or tap one of the choices.');
      return;
    }
    if (_next != null && _subject.text.trim().isEmpty) {
      setState(() => _error = 'Say what to do at the next follow-up.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final notes = _notes.text.trim();
    final mins = int.tryParse(_minutes.text.trim());
    final next = _next == null
        ? null
        : {
            'kind': _nextKind,
            'subject': _subject.text.trim(),
            'dueAt': isoWithOffset(_next!),
          };
    final repo = ref.read(crmRepositoryProvider);
    try {
      final a = widget.activity;
      if (a != null) {
        await repo.markDone(a.id, {
          'outcome': outcome,
          if (notes.isNotEmpty) 'notes': notes,
          'durationMin': ?mins,
          'next': ?next,
        });
      } else {
        final link = {
          'leadId': ?widget.leadId,
          'dealId': ?widget.dealId,
          'partyId': ?widget.partyId,
        };
        await repo.addActivity({
          'kind': _happened,
          'subject': crmKindLabel(_happened),
          'outcome': outcome,
          if (notes.isNotEmpty) 'notes': notes,
          'durationMin': ?mins,
          'doneAt': isoWithOffset(crmClock()),
          ...link,
        });
        if (next != null) await repo.addActivity({...next, ...link});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorMessage(e);
      });
      return;
    }
    ref.bumpCrm();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = widget.activity;
    return SingleChildScrollView(
      padding: _sheetPad(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Log outcome', style: theme.textTheme.titleLarge),
          if (a != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${a.title}: ${crmKindLabel(a.kind)}${a.subject.isEmpty ? '' : ', ${a.subject}'}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: Space.md),
          if (a == null) ...[
            _kindField(_happened, (v) => setState(() => _happened = v)),
            const SizedBox(height: Space.md),
          ],
          TextField(
            controller: _outcome,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'What happened'),
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final c in crmOutcomeChips)
                ActionChip(
                  label: Text(c),
                  onPressed: () => setState(() => _outcome.text = c),
                ),
            ],
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _notes,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _minutes,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Duration in minutes (optional)',
            ),
          ),
          const SizedBox(height: Space.lg),
          Text('Next follow-up', style: theme.textTheme.titleSmall),
          const SizedBox(height: Space.sm),
          WhenPicker(value: _next, onChanged: (v) => setState(() => _next = v)),
          if (_next != null) ...[
            const SizedBox(height: Space.md),
            _kindField(_nextKind, (v) => setState(() => _nextKind = v)),
            const SizedBox(height: Space.md),
            TextField(
              controller: _subject,
              decoration: const InputDecoration(labelText: 'What to do'),
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
          const SizedBox(height: Space.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'Saving' : 'Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FollowUpSheet extends ConsumerStatefulWidget {
  const _FollowUpSheet({this.leadId, this.dealId, this.partyId, required this.kind});

  final String? leadId, dealId, partyId;
  final String kind;

  @override
  ConsumerState<_FollowUpSheet> createState() => _FollowUpSheetState();
}

class _FollowUpSheetState extends ConsumerState<_FollowUpSheet> {
  final _subject = TextEditingController();
  final _notes = TextEditingController();
  late String _kind = widget.kind;
  DateTime? _when;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_subject.text.trim().isEmpty) {
      setState(() => _error = 'Say what to do.');
      return;
    }
    if (_when == null) {
      setState(() => _error = 'Choose when it is due.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(crmRepositoryProvider).addActivity({
        'kind': _kind,
        'subject': _subject.text.trim(),
        if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
        'dueAt': isoWithOffset(_when!),
        'leadId': ?widget.leadId,
        'dealId': ?widget.dealId,
        'partyId': ?widget.partyId,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorMessage(e);
      });
      return;
    }
    ref.bumpCrm();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: _sheetPad(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add follow-up', style: theme.textTheme.titleLarge),
          const SizedBox(height: Space.md),
          _kindField(_kind, (v) => setState(() => _kind = v)),
          const SizedBox(height: Space.md),
          TextField(
            controller: _subject,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'What to do'),
          ),
          const SizedBox(height: Space.md),
          Text('When', style: theme.textTheme.titleSmall),
          const SizedBox(height: Space.sm),
          WhenPicker(value: _when, onChanged: (v) => setState(() => _when = v)),
          const SizedBox(height: Space.md),
          TextField(
            controller: _notes,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.md),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: Space.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'Saving' : 'Add follow-up'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
