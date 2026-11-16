import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../items/item_picker.dart';
import '../locations/location_filter.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'receivables_models.dart';
import 'receivables_repository.dart';
import 'receivables_widgets.dart';

String _channelText(List<String> c) =>
    c.map((x) => x == 'email' ? 'email' : 'WhatsApp').join(' and ');

/// `/recurring-invoices`.
class RecurringListScreen extends ConsumerStatefulWidget {
  const RecurringListScreen({super.key});

  @override
  ConsumerState<RecurringListScreen> createState() => _RecurringListState();
}

class _RecurringListState extends ConsumerState<RecurringListScreen> {
  String? _status;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final r = await ref.read(receivablesRepositoryProvider).runRecurring();
      ref.read(receivablesRevisionProvider.notifier).bump();
      ref.bump(moneyKinds);
      if (!mounted) return;
      showInfoSnackBar(
        context,
        r.errors.isNotEmpty
            ? '${r.created} invoices created. ${r.errors.first}'
            : r.created == 0
            ? 'Nothing is due to be invoiced'
            : '${r.created} invoices created',
      );
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(Perm.invoicesCreate);
    final list = ref.watch(recurringListProvider(_status));
    return RGate(
      anyOf: const [Perm.invoicesView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Recurring invoices',
            subtitle: 'Rent, retainers and contracts billed on a schedule',
            actions: [
              if (manage)
                OutlinedButton.icon(
                  onPressed: _running ? null : _run,
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: const Text('Run now'),
                ),
              if (manage)
                FilledButton.icon(
                  onPressed: () => context.go('/recurring-invoices/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New recurring invoice'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (v, label) in const [
                  (null, 'All'),
                  ('active', 'Active'),
                  ('paused', 'Paused'),
                  ('ended', 'Ended'),
                ])
                  ChoiceChip(
                    key: ValueKey('filter-${v ?? 'all'}'),
                    label: Text(label),
                    selected: _status == v,
                    onSelected: (_) => setState(() => _status = v),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView<List<RecurringInvoice>>(
              value: list,
              onRetry: () => ref.invalidate(recurringListProvider(_status)),
              data: (rows) => rows.isEmpty
                  ? EmptyView(
                      icon: Icons.event_repeat_outlined,
                      message: _status == null
                          ? 'No recurring invoices yet.\nCreate one for rent, a retainer or a service contract.'
                          : 'No $_status recurring invoices.',
                      action: _status == null && manage
                          ? FilledButton(
                              onPressed: () => context.go('/recurring-invoices/new'),
                              child: const Text('New recurring invoice'),
                            )
                          : null,
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        8,
                        pageGutter(context),
                        24,
                      ),
                      children: [
                        for (final t in rows)
                          Card(
                            margin: const EdgeInsets.only(bottom: 6),
                            child: ListTile(
                              key: ValueKey('rec-${t.id}'),
                              onTap: () => context.go('/recurring-invoices/${t.id}'),
                              title: Text(t.name),
                              subtitle: Text(
                                [
                                  t.partyName,
                                  frequencyLabel(t.frequency),
                                  if (t.nextDate != null) 'Next ${formatDate(t.nextDate)}',
                                  '${t.runsDone} created',
                                ].join('  |  '),
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  StatusChip(t.status),
                                  if (t.lastError != null)
                                    Text(
                                      'Needs attention',
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.error,
                                        fontSize: 12,
                                      ),
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
}

/// `/recurring-invoices/:id`: schedule, lines and the invoices created.
class RecurringDetailScreen extends ConsumerWidget {
  const RecurringDetailScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(Perm.invoicesCreate);
    Future<void> act(String action, String done) async {
      try {
        await ref.read(receivablesRepositoryProvider).action(id, action);
        ref.read(receivablesRevisionProvider.notifier).bump();
        if (context.mounted) showInfoSnackBar(context, done);
      } catch (e) {
        if (context.mounted) showErrorSnackBar(context, e);
      }
    }

    return RGate(
      anyOf: const [Perm.invoicesView],
      child: AsyncValueView<RecurringInvoice>(
        value: ref.watch(recurringProvider(id)),
        onRetry: () => ref.invalidate(recurringProvider(id)),
        data: (t) => FormPage(
          maxWidth: 1000,
          children: [
            DocHeader(
              title: t.name,
              pills: StatusChip(t.status),
              actions: [
                if (manage && t.isActive)
                  DocAction(
                    label: 'Pause',
                    icon: Icons.pause_circle_outline,
                    primary: true,
                    onPressed: () => act('pause', 'Paused. No invoices are created until you resume.'),
                  ),
                if (manage && t.isPaused)
                  DocAction(
                    label: 'Resume',
                    icon: Icons.play_circle_outline,
                    primary: true,
                    onPressed: () => act('resume', 'Resumed. Periods missed while paused are skipped.'),
                  ),
                if (manage && !t.isEnded)
                  DocAction(
                    label: 'Edit',
                    icon: Icons.edit_outlined,
                    onPressed: () => context.go('/recurring-invoices/$id/edit'),
                  ),
                if (manage && !t.isEnded)
                  DocAction(
                    label: 'End',
                    icon: Icons.stop_circle_outlined,
                    destructive: true,
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('End this recurring invoice?'),
                          content: const Text('No more invoices will be created. This cannot be undone.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('End')),
                          ],
                        ),
                      );
                      if (ok == true) await act('end', 'Recurring invoice ended');
                    },
                  ),
              ],
              facts: [
                LabeledValue('Customer', t.partyName),
                LabeledValue('Repeats', frequencyLabel(t.frequency)),
                LabeledValue('Next invoice', t.nextDate == null ? '' : formatDate(t.nextDate)),
                LabeledValue('Created', '${t.runsDone}${t.maxRuns == null ? '' : ' of ${t.maxRuns}'}'),
              ],
            ),
            if (t.lastError != null)
              SectionCard(
                title: 'Last run failed',
                child: Text(t.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            SectionCard(
              title: 'Schedule',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Starts ${formatDate(t.startDate)}'
                      '${t.endDate == null ? '' : ', ends ${formatDate(t.endDate)}'}'),
                  if (t.dayOfMonth != null) Text('Day of month: ${t.dayOfMonth}'),
                  Text(t.autoSend ? 'Sent to the customer by ${_channelText(t.sendChannels)}' : 'Not sent automatically'),
                  if (t.upcoming.isNotEmpty)
                    Text('Coming up: ${t.upcoming.map(formatDate).join(', ')}'),
                ],
              ),
            ),
            SectionCard(
              title: 'Lines',
              child: Column(
                children: [
                  for (final l in t.lines)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.itemName),
                      subtitle: Text('${formatQty(l.qty)} x ${l.rate == null ? "item price" : formatMoney(l.rate)}'
                          '${l.discountPct > 0 ? ", ${l.discountPct}% off" : ""}'),
                    ),
                ],
              ),
            ),
            SectionCard(
              title: 'Invoices created',
              child: t.invoices.isEmpty
                  ? const Text('No invoices yet.')
                  : Column(
                      children: [
                        for (final i in t.invoices)
                          ListTile(
                            key: ValueKey('inv-${i.invoiceId}'),
                            contentPadding: EdgeInsets.zero,
                            onTap: () => context.go('/invoices/${i.invoiceId}'),
                            title: Text(i.number),
                            subtitle: Text('For ${formatDate(i.period)}'),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(formatMoney(i.total)),
                                Text(
                                  i.due <= 0.004 ? 'Paid' : 'Due ${formatMoney(i.due)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineDraft {
  _LineDraft({required this.itemId, required this.itemName, double qty = 1, double? rate, double discount = 0})
    : qty = TextEditingController(text: formatQty(qty)),
      rate = TextEditingController(text: rate == null ? '' : '$rate'),
      discount = TextEditingController(text: discount == 0 ? '' : '$discount');

  final String itemId;
  final String itemName;
  final TextEditingController qty;
  final TextEditingController rate;
  final TextEditingController discount;

  void dispose() {
    qty.dispose();
    rate.dispose();
    discount.dispose();
  }
}

/// `/recurring-invoices/new` and `/recurring-invoices/:id/edit`.
class RecurringFormScreen extends ConsumerWidget {
  const RecurringFormScreen({super.key, this.id});

  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RGate(
      anyOf: const [Perm.invoicesCreate],
      child: id == null
          ? const _RecurringForm()
          : AsyncValueView<RecurringInvoice>(
              value: ref.watch(recurringProvider(id!)),
              onRetry: () => ref.invalidate(recurringProvider(id!)),
              data: (t) => _RecurringForm(existing: t),
            ),
    );
  }
}

class _RecurringForm extends ConsumerStatefulWidget {
  const _RecurringForm({this.existing});

  final RecurringInvoice? existing;

  @override
  ConsumerState<_RecurringForm> createState() => _RecurringFormState();
}

class _RecurringFormState extends ConsumerState<_RecurringForm>
    with DirtyTracking, ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _notes = TextEditingController();
  final _maxRuns = TextEditingController();
  final _dom = TextEditingController();
  final List<_LineDraft> _lines = [];
  String? _partyId;
  String? _partyName;
  String? _locationId;
  String _frequency = 'monthly';
  DateTime _start = DateTime.now();
  DateTime? _end;
  bool _autoSend = false;
  final Set<String> _channels = {'email'};
  bool _saving = false;
  String? _linesError;

  bool get _locked => (widget.existing?.runsDone ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    final t = widget.existing;
    if (t == null) return;
    _name.text = t.name;
    _notes.text = t.notes ?? '';
    _maxRuns.text = t.maxRuns?.toString() ?? '';
    _dom.text = t.dayOfMonth?.toString() ?? '';
    _partyId = t.partyId;
    _partyName = t.partyName;
    _locationId = t.locationId;
    _frequency = t.frequency;
    _start = DateTime.tryParse(t.startDate) ?? _start;
    _end = DateTime.tryParse(t.endDate ?? '');
    _autoSend = t.autoSend;
    _channels
      ..clear()
      ..addAll(t.sendChannels);
    for (final l in t.lines) {
      _lines.add(_LineDraft(itemId: l.itemId, itemName: l.itemName, qty: l.qty, rate: l.rate, discount: l.discountPct));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    _maxRuns.dispose();
    _dom.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _pickParty() async {
    final p = await pickParty(context, ref, type: PartyType.customer);
    if (p == null || !mounted) return;
    setState(() {
      _partyId = p.id;
      _partyName = p.name;
    });
    markDirty();
  }

  Future<void> _addItem() async {
    final item = await pickItem(context, ref);
    if (item == null || !mounted) return;
    setState(() {
      _lines.add(_LineDraft(itemId: item.id, itemName: item.name));
      _linesError = null;
    });
    markDirty();
  }

  Future<void> _save() async {
    if (_saving) return;
    final valid = validateAndReveal(_formKey);
    if (_lines.isEmpty) {
      setState(() => _linesError = 'Add at least one item');
      return;
    }
    if (!valid || _partyId == null || _locationId == null) return;
    setState(() => _saving = true);
    final weekly = _frequency == 'weekly';
    final body = <String, Object?>{
      'name': _name.text.trim(),
      'partyId': _partyId,
      'locationId': _locationId,
      'lines': [
        for (final l in _lines)
          {
            'itemId': l.itemId,
            'qty': parseNumber(l.qty.text) ?? 1,
            if (parseNumber(l.rate.text) != null) 'rate': parseNumber(l.rate.text),
            if ((parseNumber(l.discount.text) ?? 0) > 0) 'discountPct': parseNumber(l.discount.text),
          },
      ],
      if (!_locked) 'frequency': _frequency,
      if (!_locked) 'startDate': apiDate(_start),
      if (!_locked) 'dayOfMonth': weekly ? null : int.tryParse(_dom.text),
      'endDate': _end == null ? null : apiDate(_end!),
      'maxRuns': int.tryParse(_maxRuns.text),
      'autoSend': _autoSend,
      'sendChannels': _channels.toList(),
      'notes': trimmedOrNull(_notes.text),
    };
    try {
      final repo = ref.read(receivablesRepositoryProvider);
      final saved = widget.existing == null
          ? await repo.createRecurring(body)
          : await repo.updateRecurring(widget.existing!.id, body);
      markSaved();
      ref.read(receivablesRevisionProvider.notifier).bump();
      if (!mounted) return;
      showInfoSnackBar(context, '${saved.name} saved');
      context.go('/recurring-invoices/${saved.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _numField(TextEditingController c, String label, {bool decimal = false, VoidCallback? onChanged}) =>
      TextFormField(
        controller: c,
        keyboardType: decimal ? decimalKeyboard : TextInputType.number,
        inputFormatters: decimal
            ? <TextInputFormatter>[decimalInput(decimals: 2)]
            : <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label),
        onChanged: (_) {
          markDirty();
          onChanged?.call();
        },
      );

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final theme = Theme.of(context);
    final past = _start.isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));
    return track(
      Form(
        key: _formKey,
        child: FormPage(
          maxWidth: 1000,
          bottomBar: FormActionBar(
            children: [
              TextButton(
                onPressed: _saving
                    ? null
                    : () => leave(editing ? '/recurring-invoices/${widget.existing!.id}' : '/recurring-invoices'),
                child: const Text('Cancel'),
              ),
              BusyButton(
                busy: _saving,
                onPressed: _save,
                label: editing ? 'Save changes' : 'Save',
                icon: Icons.check,
              ),
            ],
          ),
          children: [
            Text(editing ? 'Edit ${widget.existing!.name}' : 'New recurring invoice', style: theme.textTheme.headlineSmall),
            SectionCard(
              title: 'Invoice',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _name,
                    maxLength: 120,
                    onChanged: (_) => markDirty(),
                    decoration: InputDecoration(labelText: 'Name, for example Shop rent', errorText: serverError('name')),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Give it a name' : null,
                  ),
                  FormRow(
                    children: [
                      PickerField(
                        label: 'Customer',
                        value: _partyName,
                        errorText: serverError('partyId'),
                        onTap: _pickParty,
                        validator: () => _partyId == null ? 'Choose a customer' : null,
                      ),
                      LocationField(
                        value: _locationId,
                        label: 'Location',
                        errorText: serverError('locationId'),
                        onChanged: (v) {
                          setState(() => _locationId = v);
                          markDirty();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SectionCard(
              title: 'Schedule',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_locked)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('The schedule cannot change after an invoice is created.', style: theme.textTheme.bodySmall),
                    ),
                  FormRow(
                    children: [
                      DropdownButtonFormField<String>(
                        key: const ValueKey('frequency'),
                        initialValue: _frequency,
                        decoration: const InputDecoration(labelText: 'Repeats'),
                        items: [
                          for (final f in recurringFrequencies)
                            DropdownMenuItem(value: f, child: Text(frequencyLabel(f))),
                        ],
                        onChanged: _locked
                            ? null
                            : (v) {
                                setState(() => _frequency = v ?? _frequency);
                                markDirty();
                              },
                      ),
                      if (_frequency != 'weekly')
                        _numField(_dom, 'Day of month (blank for the start day)'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FormRow(
                    children: [
                      _locked
                          ? RDateField(label: 'First invoice date', value: _start, onChanged: (_) {})
                          : RDateField(
                              label: 'First invoice date',
                              value: _start,
                              onChanged: (d) {
                                setState(() => _start = d ?? _start);
                                markDirty();
                              },
                            ),
                      RDateField(
                        label: 'Last date (optional)',
                        value: _end,
                        clearable: true,
                        onChanged: (d) {
                          setState(() => _end = d);
                          markDirty();
                        },
                      ),
                      _numField(_maxRuns, 'Number of invoices (optional)'),
                    ],
                  ),
                  if (past && !editing)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'This date has passed. Invoices for the dates already passed are created on the next run, up to 12 at a time.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
            SectionCard(
              title: 'Items',
              trailing: TextButton.icon(onPressed: _addItem, icon: const Icon(Icons.add), label: const Text('Add item')),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_lines.isEmpty) const Text('No items yet. Add what to bill each time.'),
                  for (final (i, l) in _lines.indexed)
                    Padding(
                      key: ObjectKey(l),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(l.itemName, style: theme.textTheme.titleSmall)),
                              IconButton(
                                tooltip: 'Remove item',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () {
                                  setState(() => _lines.removeAt(i).dispose());
                                  markDirty();
                                },
                              ),
                            ],
                          ),
                          FormRow(
                            breakpoint: 480,
                            children: [
                              _numField(l.qty, 'Quantity', decimal: true),
                              _numField(l.rate, 'Rate (blank for item price)', decimal: true),
                              _numField(l.discount, 'Discount %', decimal: true),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (_linesError != null)
                    Text(_linesError!, style: TextStyle(color: theme.colorScheme.error)),
                ],
              ),
            ),
            SectionCard(
              title: 'Sending',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Send each invoice to the customer'),
                    value: _autoSend,
                    onChanged: (v) {
                      setState(() => _autoSend = v);
                      markDirty();
                    },
                  ),
                  if (_autoSend)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final c in const ['email', 'whatsapp'])
                          FilterChip(
                            key: ValueKey('send-$c'),
                            label: Text(c == 'email' ? 'Email' : 'WhatsApp'),
                            selected: _channels.contains(c),
                            onSelected: (v) {
                              setState(() => v ? _channels.add(c) : _channels.remove(c));
                              markDirty();
                            },
                          ),
                      ],
                    ),
                  TextFormField(
                    controller: _notes,
                    maxLines: 2,
                    maxLength: 1000,
                    onChanged: (_) => markDirty(),
                    decoration: const InputDecoration(labelText: 'Note on the invoice (optional)'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
