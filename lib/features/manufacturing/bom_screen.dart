import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../items/item_picker.dart';
import 'mfg_models.dart';
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

/// `/manufacturing/boms/:id` (and `/new`): a bill of materials with its
/// routing, standard cost and an explode view.
class BomScreen extends ConsumerWidget {
  const BomScreen({super.key, this.bomId});

  final String? bomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CGate(
      anyOf: const [MfgPerm.view],
      child: bomId == null
          ? const _BomEditor(bom: null)
          : AsyncValueView(
              value: ref.watch(mfgBomProvider(bomId!)),
              onRetry: () => ref.invalidate(mfgBomProvider(bomId!)),
              data: (b) => _BomEditor(key: ValueKey('${b.id}${b.updatedAt}'), bom: b),
            ),
    );
  }
}

class _BomEditor extends ConsumerStatefulWidget {
  const _BomEditor({super.key, required this.bom});

  final Bom? bom;

  @override
  ConsumerState<_BomEditor> createState() => _BomEditorState();
}

class _BomEditorState extends ConsumerState<_BomEditor> {
  late String? _itemId = widget.bom?.itemId;
  late String _itemName = widget.bom?.itemName ?? '';
  late String _unit = widget.bom?.unit ?? '';
  late final _output = TextEditingController(text: formatPlain(widget.bom?.outputQty ?? 1));
  late final _note = TextEditingController(text: widget.bom?.note);
  late final List<BomLine> _lines = [...?widget.bom?.lines];
  late final List<BomStep> _steps = [...?widget.bom?.steps];
  final _explodeQty = TextEditingController(text: '1');
  final _form = GlobalKey<FormState>();
  Explosion? _explosion;
  bool _busy = false;

  bool get _editable => widget.bom == null || widget.bom!.isDraft;
  bool get _canEdit => _editable && ref.mfgCan(MfgPerm.bom);

  @override
  void dispose() {
    _output.dispose();
    _note.dispose();
    _explodeQty.dispose();
    super.dispose();
  }

  Future<void> _pickFinished() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null) return;
    setState(() {
      _itemId = item.id;
      _itemName = item.name;
      _unit = item.unit;
    });
  }

  Future<void> _addLine([int? index]) async {
    final line = await showFormDialog<BomLine>(
      context: context,
      builder: (_) => _LineDialog(line: index == null ? null : _lines[index], finishedItemId: _itemId),
    );
    if (line == null) return;
    setState(() => index == null ? _lines.add(line) : _lines[index] = line);
  }

  Future<void> _addStep([int? index]) async {
    final step = await showFormDialog<BomStep>(
      context: context,
      builder: (_) => _StepDialog(step: index == null ? null : _steps[index]),
    );
    if (step == null) return;
    setState(() => index == null ? _steps.add(step) : _steps[index] = step);
  }

  Future<void> _run(Future<void> Function() job, {String? done}) async {
    setState(() => _busy = true);
    final ok = await mfgGuarded(context, job);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.bumpMfg();
      if (done != null) mfgToast(context, done);
    }
  }

  Json _body() => {
    'outputQty': parseNumber(_output.text),
    'note': trimmedOrNull(_note.text),
    'lines': [for (final l in _lines) l.toBody()],
    'steps': [for (final s in _steps) s.toBody()],
  };

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_itemId == null) {
      mfgError(context, 'Choose the finished item.');
      return;
    }
    if (!_lines.any((l) => !l.isByProduct)) {
      mfgError(context, 'Add at least one component.');
      return;
    }
    final repo = ref.read(mfgRepositoryProvider);
    final router = GoRouter.of(context);
    String? newId;
    await _run(() async {
      if (widget.bom == null) {
        newId = (await repo.createBom({'itemId': _itemId, ..._body()}..removeWhere((k, v) => v == null))).id;
      } else {
        await repo.updateBom(widget.bom!.id, {..._body(), 'expectedUpdatedAt': widget.bom!.updatedAt});
      }
    }, done: 'Saved.');
    if (newId != null && mounted) router.go('/manufacturing/boms/$newId');
  }

  Future<void> _activate() async {
    final repo = ref.read(mfgRepositoryProvider);
    await _run(() async {
      await repo.activateBom(widget.bom!.id);
    }, done: 'Version ${widget.bom!.version} is now active.');
  }

  Future<void> _copy() async {
    final repo = ref.read(mfgRepositoryProvider);
    final router = GoRouter.of(context);
    String? id;
    await _run(() async {
      id = (await repo.copyBom(widget.bom!.id)).id;
    }, done: 'New draft version made.');
    if (id != null && mounted) router.go('/manufacturing/boms/$id');
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this draft?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final repo = ref.read(mfgRepositoryProvider);
    final router = GoRouter.of(context);
    var done = false;
    await _run(() async {
      await repo.deleteBom(widget.bom!.id);
      done = true;
    });
    if (done && mounted) router.go('/manufacturing/boms');
  }

  Future<void> _explode() async {
    final qty = parseNumber(_explodeQty.text);
    if (qty == null || qty <= 0) {
      mfgError(context, 'Enter a quantity to make.');
      return;
    }
    try {
      final e = await ref.read(mfgRepositoryProvider).explode(bomId: widget.bom!.id, qty: qty);
      if (mounted) setState(() => _explosion = e);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bom = widget.bom;
    final comps = [for (var i = 0; i < _lines.length; i++) if (!_lines[i].isByProduct) i];
    final bys = [for (var i = 0; i < _lines.length; i++) if (_lines[i].isByProduct) i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: bom == null ? 'New bill of materials' : '${bom.itemName}, version ${bom.version}',
          actions: [
            if (bom != null) StatusChip(bom.status),
            if (bom != null && ref.mfgCan(MfgPerm.bom))
              OutlinedButton(onPressed: _busy ? null : _copy, child: const Text('Copy to new version')),
            if (bom != null && bom.isDraft && ref.mfgCan(MfgPerm.bom))
              OutlinedButton(onPressed: _busy ? null : _activate, child: const Text('Make active')),
            if (_canEdit) FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ],
        ),
        Expanded(
          child: Form(
            key: _form,
            child: mfgBody(context, [
              MfgCard(
                title: 'Finished item',
                child: Column(
                  children: [
                    if (bom == null)
                      PickerFieldBox(label: 'Item', value: _itemId == null ? null : _itemName, onTap: _pickFinished)
                    else
                      MfgKv('Item', bom.itemName, bold: true),
                    const SizedBox(height: Space.sm),
                    if (_editable)
                      FormRow(
                        children: [
                          mfgNumberField(controller: _output, label: 'Makes', suffix: _unit.isEmpty ? null : _unit),
                          TextFormField(controller: _note, decoration: const InputDecoration(labelText: 'Note')),
                        ],
                      )
                    else ...[
                      MfgKv('Makes', qtyUnit(bom!.outputQty, bom.unit)),
                      if ((bom.note ?? '').isNotEmpty) MfgKv('Note', bom.note!),
                    ],
                  ],
                ),
              ),
              MfgCard(
                title: 'Components',
                trailing: _canEdit
                    ? TextButton.icon(onPressed: () => _addLine(), icon: const Icon(Icons.add), label: const Text('Add'))
                    : null,
                child: comps.isEmpty
                    ? const Text('No components yet.')
                    : Column(
                        children: [
                          for (final i in comps)
                            _LineTile(
                              line: _lines[i],
                              onTap: _canEdit ? () => _addLine(i) : null,
                              onDelete: _canEdit ? () => setState(() => _lines.removeAt(i)) : null,
                            ),
                        ],
                      ),
              ),
              if (bys.isNotEmpty || _canEdit)
                MfgCard(
                  title: 'By-products',
                  child: bys.isEmpty
                      ? const Text('None. Add a by-product as a line with the kind By-product.')
                      : Column(
                          children: [
                            for (final i in bys)
                              _LineTile(
                                line: _lines[i],
                                onTap: _canEdit ? () => _addLine(i) : null,
                                onDelete: _canEdit ? () => setState(() => _lines.removeAt(i)) : null,
                              ),
                          ],
                        ),
                ),
              MfgCard(
                title: 'Routing',
                trailing: _canEdit
                    ? TextButton.icon(onPressed: () => _addStep(), icon: const Icon(Icons.add), label: const Text('Add'))
                    : null,
                child: _steps.isEmpty
                    ? const Text('No operations. Add steps to charge work centre time.')
                    : Column(
                        children: [
                          for (var i = 0; i < _steps.length; i++)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: theme.textTheme.labelSmall)),
                              title: Text(_steps[i].operation),
                              subtitle: Text('${_steps[i].workCentreName} · ${formatQty(_steps[i].minutesPerUnit)} min per unit'),
                              onTap: _canEdit ? () => _addStep(i) : null,
                              trailing: _canEdit
                                  ? IconButton(
                                      tooltip: 'Remove step',
                                      icon: const Icon(Icons.close),
                                      onPressed: () => setState(() => _steps.removeAt(i)),
                                    )
                                  : null,
                            ),
                        ],
                      ),
              ),
              if (bom?.standardCost case final c?)
                MfgCard(
                  title: 'Standard cost per ${bom!.unit}',
                  child: Column(
                    children: [
                      MfgKv('Material', formatMoney(c.material)),
                      MfgKv('Work centre time', formatMoney(c.work)),
                      if (c.byProducts > 0) MfgKv('By-product value', '-${formatMoney(c.byProducts)}'),
                      MfgKv('Cost', formatMoney(c.unitCost), bold: true),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Material at purchase price. Overhead is added on each order.', style: theme.textTheme.bodySmall),
                      ),
                    ],
                  ),
                ),
              if (bom != null)
                MfgCard(
                  title: 'Explode',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Total raw material for a quantity, with scrap, against stock on hand.'),
                      const SizedBox(height: Space.sm),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 140, child: mfgNumberField(controller: _explodeQty, label: 'Quantity', suffix: bom.unit)),
                          const SizedBox(width: Space.md),
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: OutlinedButton(onPressed: _explode, child: const Text('Explode')),
                          ),
                        ],
                      ),
                      if (_explosion != null) _ExplosionView(_explosion!),
                    ],
                  ),
                ),
              if (bom != null && bom.isDraft && ref.mfgCan(MfgPerm.bom))
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete draft'),
                  ),
                ),
            ]),
          ),
        ),
      ],
    );
  }
}

/// Read-only looking field that opens a picker.
class PickerFieldBox extends StatelessWidget {
  const PickerFieldBox({super.key, required this.label, required this.value, required this.onTap});

  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: InputDecorator(
      decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.search)),
      child: Text(value ?? 'Choose', overflow: TextOverflow.ellipsis),
    ),
  );
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, this.onTap, this.onDelete});

  final BomLine line;
  final VoidCallback? onTap, onDelete;

  @override
  Widget build(BuildContext context) {
    final bits = [
      qtyUnit(line.qty, line.unit),
      if (line.scrapPct > 0) '${formatPlain(line.scrapPct)}% scrap',
      if (line.isByProduct && line.rate != null) 'value ${formatMoney(line.rate)} per ${line.unit}',
      if (line.hasBom) 'has its own BOM',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(line.name),
      subtitle: Text(bits.join(' · ')),
      onTap: onTap,
      trailing: onDelete == null
          ? null
          : IconButton(tooltip: 'Remove line', icon: const Icon(Icons.close), onPressed: onDelete),
    );
  }
}

class _ExplosionView extends StatelessWidget {
  const _ExplosionView(this.e);

  final Explosion e;

  List<Widget> _nodes(List<ExplodeNode> nodes, int depth, ThemeData theme) => [
    for (final n in nodes) ...[
      Padding(
        padding: EdgeInsets.only(left: depth * 16.0, top: 2, bottom: 2),
        child: Text(
          '${qtyUnit(n.qty, n.unit)}  ${n.name}${n.hasBom ? '  (made in-house)' : ''}',
          style: theme.textTheme.bodyMedium,
        ),
      ),
      ..._nodes(n.children, depth + 1, theme),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Space.md),
        Text('Structure for ${formatQty(e.qty)} of ${e.itemName}', style: theme.textTheme.titleSmall),
        ..._nodes(e.tree, 0, theme),
        const SizedBox(height: Space.md),
        Text('Raw material needed', style: theme.textTheme.titleSmall),
        for (final r in e.raw)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(child: Text(r.name)),
                Text(
                  '${qtyUnit(r.qty, r.unit)} of ${formatQty(r.onHand)} in stock',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: r.short > 0 ? theme.colorScheme.error : null,
                    fontWeight: r.short > 0 ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        if (e.raw.any((r) => r.short > 0))
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text('Short: ${e.raw.where((r) => r.short > 0).map((r) => '${r.name} ${qtyUnit(r.short, r.unit)}').join(', ')}'),
          ),
      ],
    );
  }
}

class _LineDialog extends ConsumerStatefulWidget {
  const _LineDialog({this.line, this.finishedItemId});

  final BomLine? line;
  final String? finishedItemId;

  @override
  ConsumerState<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends ConsumerState<_LineDialog> {
  final _key = GlobalKey<FormState>();
  late String _kind = widget.line?.kind ?? 'component';
  late String? _itemId = widget.line?.itemId;
  late String _name = widget.line?.name ?? '';
  late String _unit = widget.line?.unit ?? '';
  late final _qty = TextEditingController(text: widget.line == null ? '' : formatPlain(widget.line!.qty));
  late final _scrap = TextEditingController(text: widget.line == null || widget.line!.scrapPct == 0 ? '' : formatPlain(widget.line!.scrapPct));
  late final _rate = TextEditingController(text: formatPlain(widget.line?.rate));

  Future<void> _pick() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null) return;
    setState(() {
      _itemId = item.id;
      _name = item.name;
      _unit = item.unit;
    });
  }

  void _save() {
    if (!_key.currentState!.validate()) return;
    if (_itemId == null) {
      mfgError(context, 'Choose an item.');
      return;
    }
    if (_itemId == widget.finishedItemId) {
      mfgError(context, 'An item cannot be its own component.');
      return;
    }
    final byProduct = _kind == 'byproduct';
    Navigator.of(context).pop(
      BomLine(
        kind: _kind,
        itemId: _itemId!,
        name: _name,
        unit: _unit,
        qty: parseNumber(_qty.text)!,
        scrapPct: byProduct ? 0 : parseNumber(_scrap.text) ?? 0,
        rate: byProduct ? parseNumber(_rate.text) ?? 0 : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final byProduct = _kind == 'byproduct';
    return AlertDialog(
      title: Text(widget.line == null ? 'Add line' : 'Edit line'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _key,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'component', label: Text('Component')),
                    ButtonSegment(value: 'byproduct', label: Text('By-product')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                const SizedBox(height: Space.md),
                PickerFieldBox(label: 'Item', value: _itemId == null ? null : _name, onTap: _pick),
                const SizedBox(height: Space.md),
                mfgNumberField(controller: _qty, label: 'Quantity', suffix: _unit.isEmpty ? null : _unit),
                const SizedBox(height: Space.md),
                if (byProduct)
                  mfgNumberField(controller: _rate, label: 'Value per unit', required: false, allowZero: true)
                else
                  mfgNumberField(controller: _scrap, label: 'Scrap', required: false, allowZero: true, max: 100, suffix: '%'),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Done')),
      ],
    );
  }
}

class _StepDialog extends ConsumerStatefulWidget {
  const _StepDialog({this.step});

  final BomStep? step;

  @override
  ConsumerState<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends ConsumerState<_StepDialog> {
  final _key = GlobalKey<FormState>();
  late final _op = TextEditingController(text: widget.step?.operation);
  late final _min = TextEditingController(text: widget.step == null ? '' : formatPlain(widget.step!.minutesPerUnit));
  late String? _centreId = widget.step?.workCentreId;

  @override
  Widget build(BuildContext context) {
    final centres = (ref.watch(mfgWorkCentresProvider).value ?? const <WorkCentre>[]).where((c) => c.isActive).toList();
    return AlertDialog(
      title: Text(widget.step == null ? 'Add operation' : 'Edit operation'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _key,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _op,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Operation'),
                  validator: (v) => requiredField(v, 'Operation'),
                ),
                const SizedBox(height: Space.md),
                DropdownButtonFormField<String>(
                  initialValue: centres.any((c) => c.id == _centreId) ? _centreId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Work centre'),
                  items: [for (final c in centres) DropdownMenuItem(value: c.id, child: Text(c.name))],
                  onChanged: (v) => setState(() => _centreId = v),
                  validator: (v) => v == null ? 'Work centre is required' : null,
                ),
                const SizedBox(height: Space.md),
                mfgNumberField(controller: _min, label: 'Minutes per unit'),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_key.currentState!.validate()) return;
            final c = centres.firstWhere((c) => c.id == _centreId);
            Navigator.of(context).pop(
              BomStep(
                operation: _op.text.trim(),
                workCentreId: c.id,
                workCentreName: c.name,
                minutesPerUnit: parseNumber(_min.text)!,
                hourlyCost: c.hourlyCost,
              ),
            );
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}
