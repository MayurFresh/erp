import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../items/item_picker.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'bom_screen.dart' show PickerFieldBox;
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

const _jwStatuses = <(String, String)>[
  ('', 'All'),
  ('open', 'Open'),
  ('partially_returned', 'Part returned'),
  ('returned', 'Returned'),
  ('cancelled', 'Cancelled'),
];

/// `/manufacturing/jobwork`: challans for goods sent to job workers, and the
/// ITC-04 style summary of what is still with them.
class JobWorkScreen extends ConsumerStatefulWidget {
  const JobWorkScreen({super.key});

  @override
  ConsumerState<JobWorkScreen> createState() => _JobWorkScreenState();
}

class _JobWorkScreenState extends ConsumerState<JobWorkScreen> {
  String _status = '';
  bool _summary = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CGate(
      anyOf: const [MfgPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Job work',
            subtitle: 'Goods sent out for processing',
            actions: [
              if (ref.mfgCan(MfgPerm.issue))
                FilledButton.icon(
                  onPressed: () async {
                    final id = await showFormDialog<String>(
                      context: context,
                      builder: (_) => const _NewChallanDialog(),
                    );
                    if (id != null && context.mounted) {
                      ref.bumpMfg();
                      context.go('/manufacturing/jobwork/$id');
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('New challan'),
                ),
            ],
          ),
          FilterBar(
            children: [
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.xs,
                children: [
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('Challans')),
                      ButtonSegment(
                        value: true,
                        label: Text('With job workers'),
                      ),
                    ],
                    selected: {_summary},
                    onSelectionChanged: (s) =>
                        setState(() => _summary = s.first),
                  ),
                  if (!_summary)
                    for (final s in _jwStatuses)
                      ChoiceChip(
                        label: Text(s.$2),
                        selected: _status == s.$1,
                        onSelected: (_) => setState(() => _status = s.$1),
                      ),
                ],
              ),
            ],
          ),
          Expanded(child: _summary ? const _SummaryList() : _list(theme)),
        ],
      ),
    );
  }

  Widget _list(ThemeData theme) => AsyncValueView(
    value: ref.watch(mfgChallansProvider(_status)),
    onRetry: () => ref.invalidate(mfgChallansProvider(_status)),
    data: (list) {
      if (list.isEmpty) {
        return const EmptyView(
          icon: Icons.local_shipping_outlined,
          message: 'No job work challans here.',
        );
      }
      return ListView.separated(
        padding: EdgeInsets.all(pageGutter(context)),
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
        itemBuilder: (_, i) {
          final c = list[i];
          return Material(
            color: theme.colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: Radii.mediumAll,
              side: BorderSide(color: context.colors.hairline),
            ),
            child: InkWell(
              borderRadius: Radii.mediumAll,
              onTap: () => context.go('/manufacturing/jobwork/${c.id}'),
              child: Padding(
                padding: const EdgeInsets.all(Space.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${c.number} · ${c.partyName}',
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            '${c.process} · sent ${formatDate(c.challanDate)}'
                            '${c.expectedReturn != null ? ' · back by ${formatDate(c.expectedReturn)}' : ''}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    StatusChip(c.status),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class _SummaryList extends ConsumerWidget {
  const _SummaryList();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncValueView(
    value: ref.watch(mfgItc04Provider),
    onRetry: () => ref.invalidate(mfgItc04Provider),
    data: (rows) {
      if (rows.isEmpty) {
        return const EmptyView(message: 'Nothing sent to job workers yet.');
      }
      return mfgBody(context, [
        const Padding(
          padding: EdgeInsets.only(bottom: Space.sm),
          child: Text(
            'A working summary for the ITC-04 return. Check it before filing.',
          ),
        ),
        for (final r in rows)
          MfgCard(
            title: '${r.jobWorker} · ${r.item}',
            trailing: r.overdue
                ? const StatusChip(
                    'overdue',
                    tone: StatusTone.danger,
                    label: 'Over a year',
                  )
                : null,
            child: Column(
              children: [
                MfgKv('Sent', qtyUnit(r.sent, r.unit)),
                MfgKv('Received back', qtyUnit(r.received, r.unit)),
                if (r.scrap > 0) MfgKv('Scrap', qtyUnit(r.scrap, r.unit)),
                MfgKv(
                  'Still with them',
                  qtyUnit(r.pending, r.unit),
                  bold: true,
                ),
                if (r.pending > 0) MfgKv('Oldest challan', '${r.days} days'),
              ],
            ),
          ),
      ]);
    },
  );
}

class _NewChallanDialog extends ConsumerStatefulWidget {
  const _NewChallanDialog();

  @override
  ConsumerState<_NewChallanDialog> createState() => _NewChallanDialogState();
}

class _Row {
  _Row(this.itemId, this.name, this.unit);

  final String itemId, name, unit;
  final qty = TextEditingController();

  /// The item that comes back, when it is not the item sent.
  String? returnItemId, returnName;
}

class _NewChallanDialogState extends ConsumerState<_NewChallanDialog> {
  final _key = GlobalKey<FormState>();
  final _process = TextEditingController();
  final _vehicle = TextEditingController();
  Party? _party;
  String? _locationId;
  DateTime? _back;
  final List<_Row> _rows = [];
  bool _busy = false;

  Future<void> _addItem() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item != null) {
      setState(() => _rows.add(_Row(item.id, item.name, item.unit)));
    }
  }

  Future<void> _pickReturn(_Row r) async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null) return;
    setState(() {
      final same = item.id == r.itemId;
      r.returnItemId = same ? null : item.id;
      r.returnName = same ? null : item.name;
    });
  }

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    if (_party == null) return mfgError(context, 'Choose the job worker.');
    if (_rows.isEmpty) return mfgError(context, 'Add at least one item.');
    setState(() => _busy = true);
    String? id;
    final ok = await mfgGuarded(context, () async {
      id = (await ref.read(mfgRepositoryProvider).createChallan({
        'partyId': _party!.id,
        'locationId': _locationId,
        'process': _process.text.trim(),
        if (_back != null)
          'expectedReturn': _back!.toIso8601String().substring(0, 10),
        if (trimmedOrNull(_vehicle.text) != null)
          'vehicleNo': _vehicle.text.trim(),
        'lines': [
          for (final r in _rows)
            {
              'itemId': r.itemId,
              'qty': parseNumber(r.qty.text),
              if (r.returnItemId != null) 'returnItemId': r.returnItemId,
            },
        ],
      })).id;
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(id);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New job work challan'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _key,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PickerFieldBox(
                label: 'Job worker',
                value: _party?.name,
                onTap: () async {
                  final p = await pickParty(
                    context,
                    ref,
                    type: PartyType.vendor,
                  );
                  if (p != null) setState(() => _party = p);
                },
              ),
              const SizedBox(height: Space.md),
              MfgLocationField(
                value: _locationId,
                onChanged: (v) => setState(() => _locationId = v),
                label: 'Send from',
              ),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _process,
                decoration: const InputDecoration(
                  labelText: 'Process (for example, powder coating)',
                ),
                validator: (v) => requiredField(v, 'Process'),
              ),
              const SizedBox(height: Space.md),
              InkWell(
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate:
                        _back ?? DateTime.now().add(const Duration(days: 15)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (d != null) setState(() => _back = d);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Back by',
                    suffixIcon: Icon(Icons.calendar_today_outlined),
                  ),
                  child: Text(
                    _back == null
                        ? 'Not set'
                        : formatDate(_back!.toIso8601String()),
                  ),
                ),
              ),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _vehicle,
                decoration: const InputDecoration(labelText: 'Vehicle number'),
              ),
              const SizedBox(height: Space.md),
              for (var i = 0; i < _rows.length; i++) ...[
                Row(
                  children: [
                    Expanded(
                      child: mfgNumberField(
                        controller: _rows[i].qty,
                        label: _rows[i].name,
                        suffix: _rows[i].unit,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove item',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _rows.removeAt(i)),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _pickReturn(_rows[i]),
                    child: Text(
                      _rows[i].returnName == null
                          ? 'Comes back as the same item (change)'
                          : 'Comes back as ${_rows[i].returnName} (change)',
                    ),
                  ),
                ),
                const SizedBox(height: Space.sm),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addItem,
                  icon: const Icon(Icons.add),
                  label: const Text('Add item'),
                ),
              ),
              const Text('Stock leaves this location at its average cost.'),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Send')),
    ],
  );
}
