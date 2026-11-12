import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../items/item_picker.dart';
import 'bom_screen.dart' show PickerFieldBox;
import 'mfg_models.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

/// Shared shell for the order action dialogs: a form, a busy flag, one save.
abstract class _ActionState<T extends ConsumerStatefulWidget> extends ConsumerState<T> {
  final key = GlobalKey<FormState>();
  bool busy = false;

  String get title;
  String get action;
  List<Widget> fields();
  Future<void> submit(MfgRepository repo);

  Future<void> _save() async {
    if (!key.currentState!.validate()) return;
    setState(() => busy = true);
    final ok = await mfgGuarded(context, () => submit(ref.read(mfgRepositoryProvider)));
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 440,
      child: Form(
        key: key,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: fields())),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
      FilledButton(onPressed: busy ? null : _save, child: Text(action)),
    ],
  );
}

const _gap = SizedBox(height: Space.md);

/// Issue material to the order, or return unused material from it.
class IssueDialog extends ConsumerStatefulWidget {
  const IssueDialog({super.key, required this.order, required this.returning});

  final MfgOrder order;
  final bool returning;

  @override
  ConsumerState<IssueDialog> createState() => _IssueDialogState();
}

class _IssueDialogState extends _ActionState<IssueDialog> {
  late final List<OrderMaterial> _mats = widget.order.materials
      .where((m) => widget.returning ? m.netQty > 0 : m.pendingQty > 0)
      .toList();
  late final _ctl = [
    for (final m in _mats) TextEditingController(text: formatPlain(widget.returning ? 0 : m.pendingQty)),
  ];
  final _note = TextEditingController();

  @override
  String get title => widget.returning ? 'Return material' : 'Issue material';
  @override
  String get action => widget.returning ? 'Return' : 'Issue';

  @override
  List<Widget> fields() => [
    if (_mats.isEmpty)
      Text(widget.returning ? 'No material is out on this order.' : 'All planned material is issued.')
    else ...[
      Text(widget.returning ? 'Quantity to return' : 'Stock at ${widget.order.locationName} is checked when you issue.'),
      _gap,
      for (var i = 0; i < _mats.length; i++) ...[
        TextFormField(
          controller: _ctl[i],
          keyboardType: decimalKeyboard,
          decoration: InputDecoration(
            labelText: _mats[i].name,
            suffixText: _mats[i].unit,
            helperText: widget.returning
                ? 'Out on order ${formatQty(_mats[i].netQty)}'
                : 'Still to issue ${formatQty(_mats[i].pendingQty)}, in stock ${formatQty(_mats[i].onHand)}',
          ),
          validator: (v) {
            final t = v?.trim() ?? '';
            if (t.isEmpty) return null;
            final n = parseNumber(t);
            if (n == null || n < 0) return 'Enter a number';
            if (widget.returning && n > _mats[i].netQty) return 'More than is out on the order';
            return null;
          },
        ),
        _gap,
      ],
      TextFormField(controller: _note, decoration: const InputDecoration(labelText: 'Note')),
    ],
  ];

  @override
  Future<void> submit(MfgRepository repo) {
    final lines = [
      for (var i = 0; i < _mats.length; i++)
        if ((parseNumber(_ctl[i].text) ?? 0) > 0) {'itemId': _mats[i].itemId, 'qty': parseNumber(_ctl[i].text)},
    ];
    if (lines.isEmpty) throw const MfgInputError('Enter a quantity for at least one item.');
    final note = trimmedOrNull(_note.text);
    final body = {'lines': lines, 'note': ?note};
    return widget.returning ? repo.returnMaterial(widget.order.id, body) : repo.issue(widget.order.id, body);
  }
}

/// Record good and rejected output, work centre minutes and by-products.
class OutputDialog extends ConsumerStatefulWidget {
  const OutputDialog({super.key, required this.order});

  final MfgOrder order;

  @override
  ConsumerState<OutputDialog> createState() => _OutputDialogState();
}

class _OutputDialogState extends _ActionState<OutputDialog> {
  final _good = TextEditingController();
  final _rej = TextEditingController();
  final _min = TextEditingController();
  final _note = TextEditingController();
  final List<({String itemId, String name, String unit, TextEditingController qty})> _by = [];

  @override
  String get title => 'Record output';
  @override
  String get action => 'Save output';

  Future<void> _addByProduct() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null) return;
    setState(() => _by.add((itemId: item.id, name: item.name, unit: item.unit, qty: TextEditingController())));
  }

  @override
  List<Widget> fields() {
    final o = widget.order;
    return [
      Text('Left to make: ${qtyUnit((o.qty - o.goodQty).clamp(0, double.infinity), o.unit)}'),
      _gap,
      mfgNumberField(controller: _good, label: 'Good quantity', suffix: o.unit, allowZero: true),
      _gap,
      mfgNumberField(controller: _rej, label: 'Rejected', required: false, allowZero: true, suffix: o.unit),
      _gap,
      mfgNumberField(
        controller: _min,
        label: 'Minutes taken (optional)',
        required: false,
        allowZero: true,
      ),
      _gap,
      for (var i = 0; i < _by.length; i++) ...[
        Row(
          children: [
            Expanded(
              child: mfgNumberField(controller: _by[i].qty, label: 'By-product ${_by[i].name}', suffix: _by[i].unit),
            ),
            IconButton(
              tooltip: 'Remove by-product',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _by.removeAt(i)),
            ),
          ],
        ),
        _gap,
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(onPressed: _addByProduct, icon: const Icon(Icons.add), label: const Text('By-product')),
      ),
      TextFormField(controller: _note, decoration: const InputDecoration(labelText: 'Note')),
    ];
  }

  @override
  Future<void> submit(MfgRepository repo) {
    final good = parseNumber(_good.text) ?? 0;
    final rej = parseNumber(_rej.text) ?? 0;
    if (good <= 0 && rej <= 0) throw const MfgInputError('Enter good or rejected quantity.');
    return repo.output(widget.order.id, {
      'goodQty': good,
      if (rej > 0) 'rejectedQty': rej,
      if ((parseNumber(_min.text) ?? 0) > 0) 'minutes': parseNumber(_min.text),
      if (_by.isNotEmpty) 'byProducts': [for (final b in _by) {'itemId': b.itemId, 'qty': parseNumber(b.qty.text)}],
      if (trimmedOrNull(_note.text) != null) 'note': _note.text.trim(),
    });
  }
}

class InspectDialog extends ConsumerStatefulWidget {
  const InspectDialog({super.key, required this.order});

  final MfgOrder order;

  @override
  ConsumerState<InspectDialog> createState() => _InspectDialogState();
}

class _InspectDialogState extends _ActionState<InspectDialog> {
  final _pass = TextEditingController();
  final _rework = TextEditingController();
  final _reject = TextEditingController();
  final _note = TextEditingController();

  @override
  String get title => 'Quality inspection';
  @override
  String get action => 'Save';

  @override
  List<Widget> fields() => [
    const Text('Records the result. Stock does not change.'),
    _gap,
    mfgNumberField(controller: _pass, label: 'Passed', allowZero: true, suffix: widget.order.unit),
    _gap,
    mfgNumberField(controller: _rework, label: 'Needs rework', required: false, allowZero: true),
    _gap,
    mfgNumberField(controller: _reject, label: 'Rejected', required: false, allowZero: true),
    _gap,
    TextFormField(
      controller: _note,
      decoration: const InputDecoration(labelText: 'Note'),
      validator: (v) => requiredField(v, 'Note'),
    ),
  ];

  @override
  Future<void> submit(MfgRepository repo) {
    final p = parseNumber(_pass.text) ?? 0, w = parseNumber(_rework.text) ?? 0, r = parseNumber(_reject.text) ?? 0;
    if (p + w + r <= 0) throw const MfgInputError('Enter at least one quantity.');
    return repo.inspect(widget.order.id, {'passQty': p, 'reworkQty': w, 'rejectQty': r, 'note': _note.text.trim()});
  }
}

/// Change the quantity, place or dates of a draft or released order.
class EditOrderDialog extends ConsumerStatefulWidget {
  const EditOrderDialog({super.key, required this.order});

  final MfgOrder order;

  @override
  ConsumerState<EditOrderDialog> createState() => _EditOrderDialogState();
}

class _EditOrderDialogState extends _ActionState<EditOrderDialog> {
  late final _qty = TextEditingController(text: formatPlain(widget.order.qty));
  late final _notes = TextEditingController(text: widget.order.notes);
  late String? _loc = widget.order.locationId;

  @override
  String get title => 'Edit ${widget.order.number}';
  @override
  String get action => 'Save';

  @override
  List<Widget> fields() => [
    mfgNumberField(controller: _qty, label: 'Quantity', suffix: widget.order.unit),
    _gap,
    MfgLocationField(value: _loc, onChanged: (v) => setState(() => _loc = v)),
    _gap,
    TextFormField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
  ];

  @override
  Future<void> submit(MfgRepository repo) async {
    final o = widget.order;
    final Json body = {
      'qty': parseNumber(_qty.text),
      if (_loc != o.locationId) 'locationId': _loc,
      'notes': trimmedOrNull(_notes.text),
      'expectedUpdatedAt': o.updatedAt,
    };
    await repo.updateOrder(o.id, body);
  }
}

/// Add a planned material line, or change the quantity of one. 0 removes it.
class PlanMaterialDialog extends ConsumerStatefulWidget {
  const PlanMaterialDialog({super.key, required this.order, this.material});

  final MfgOrder order;
  final OrderMaterial? material;

  @override
  ConsumerState<PlanMaterialDialog> createState() => _PlanMaterialDialogState();
}

class _PlanMaterialDialogState extends _ActionState<PlanMaterialDialog> {
  late String? _itemId = widget.material?.itemId;
  late String? _name = widget.material?.name;
  late String _unit = widget.material?.unit ?? '';
  late final _qty = TextEditingController(text: formatPlain(widget.material?.plannedQty));

  @override
  String get title => widget.material == null ? 'Add material' : widget.material!.name;
  @override
  String get action => 'Save';

  @override
  List<Widget> fields() => [
    if (widget.material == null) ...[
      PickerFieldBox(
        label: 'Item',
        value: _name,
        onTap: () async {
          final item = await pickItem(context, ref, stockOnly: true);
          if (item != null) {
            setState(() {
              _itemId = item.id;
              _name = item.name;
              _unit = item.unit;
            });
          }
        },
      ),
      _gap,
    ],
    mfgNumberField(controller: _qty, label: 'Planned quantity', allowZero: true, suffix: _unit),
    const SizedBox(height: Space.sm),
    const Text('Enter 0 to remove the line. This works only when nothing was issued.'),
  ];

  @override
  Future<void> submit(MfgRepository repo) async {
    if (_itemId == null) throw const MfgInputError('Choose an item.');
    await repo.setMaterial(widget.order.id, _itemId!, parseNumber(_qty.text)!);
  }
}
