import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/json.dart';
import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../parties/party_model.dart';
import '../../tax/tax_pickers.dart';
import '../../parties/party_picker.dart';
import '../common/boq_picker.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../data/subcontract_repository.dart';
import '../models/common_models.dart';
import '../models/subcontract_models.dart';
import '../../../widgets/busy.dart';

/// Creates or edits a work order (header, percentages and lines).
class WorkOrderFormScreen extends ConsumerWidget {
  const WorkOrderFormScreen({super.key, this.workOrderId});

  final String? workOrderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = workOrderId;
    return CGate(
      anyOf: const [CPerm.subcontractsManage],
      child: id == null
          ? const _WorkOrderForm()
          : AsyncValueView(
              value: ref.watch(workOrderProvider(id)),
              onRetry: () => ref.invalidate(workOrderProvider(id)),
              data: (wo) => _WorkOrderForm(original: wo),
            ),
    );
  }
}

class _LineDraft {
  _LineDraft({
    String description = '',
    String unit = '',
    double? qty,
    double? rate,
    this.boqLineId,
    this.boqCode,
  }) : description = TextEditingController(text: description),
       unit = TextEditingController(text: unit),
       qty = TextEditingController(text: qty == null ? '' : formatPlain(qty)),
       rate = TextEditingController(
         text: rate == null ? '' : formatPlain(rate),
       );

  final TextEditingController description;
  final TextEditingController unit;
  final TextEditingController qty;
  final TextEditingController rate;
  String? boqLineId;
  String? boqCode;

  double get amount =>
      round2((parseNumber(qty.text) ?? 0) * (parseNumber(rate.text) ?? 0));

  void dispose() {
    description.dispose();
    unit.dispose();
    qty.dispose();
    rate.dispose();
  }
}

class _WorkOrderForm extends ConsumerStatefulWidget {
  const _WorkOrderForm({this.original});

  final WorkOrder? original;

  @override
  ConsumerState<_WorkOrderForm> createState() => _WorkOrderFormState();
}

class _WorkOrderFormState extends ConsumerState<_WorkOrderForm>
    with DirtyTracking<_WorkOrderForm> {
  final _formKey = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.original?.title);
  late final _scope = TextEditingController(text: widget.original?.scope);
  late final _retention = _pct(widget.original?.retentionPct);
  late final _advance = _pct(widget.original?.advanceRecoveryPct);
  late final _tds = _pct(widget.original?.tdsPct);
  late final _gst = _pct(widget.original?.gstPct);
  late final _cess = _pct(widget.original?.cessPct);
  final List<_LineDraft> _lines = [];
  String? _projectId;
  NamedRef? _contractor;
  DateTime _date = today();
  bool _itc = true;
  bool _activate = false;
  bool _busy = false;
  String? _contractorError;

  bool get _editing => widget.original != null;

  TextEditingController _pct(double? value) =>
      TextEditingController(text: value == null ? '' : formatPlain(value));

  @override
  void initState() {
    super.initState();
    final wo = widget.original;
    if (wo != null) {
      _projectId = wo.projectId;
      _contractor = NamedRef(id: wo.contractorPartyId, name: wo.contractorName);
      _date = parseApiDate(wo.date) ?? today();
      _itc = wo.itcEligible;
      for (final l in wo.lines ?? const <WorkOrderLine>[]) {
        _lines.add(
          _LineDraft(
            description: l.description,
            unit: l.unit,
            qty: l.qty,
            rate: l.rate,
            boqLineId: l.boqLineId,
            boqCode: l.boqCode,
          ),
        );
      }
    }
    if (_lines.isEmpty) _lines.add(_LineDraft());
  }

  @override
  void dispose() {
    for (final c in [_title, _scope, _retention, _advance, _tds, _gst, _cess]) {
      c.dispose();
    }
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _pickContractor() async {
    final party = await pickParty(context, ref, type: PartyType.vendor);
    if (party != null) {
      setState(() {
        _contractor = NamedRef(id: party.id, name: party.name);
        _contractorError = null;
      });
    }
  }

  Future<void> _pickBoq(_LineDraft line) async {
    final project = _projectId;
    if (project == null) {
      showInfoSnackBar(context, 'Choose the project first.');
      return;
    }
    try {
      final boq = await ref.read(boqProvider(project).future);
      if (!mounted) return;
      final picked = await pickBoqLine(context, ref, lines: boq);
      if (picked == null) return;
      setState(() {
        line.boqLineId = picked.id;
        line.boqCode = picked.code;
        if (line.description.text.trim().isEmpty) {
          line.description.text = picked.description;
        }
        if (line.unit.text.trim().isEmpty) line.unit.text = picked.unit;
        if (line.qty.text.trim().isEmpty) {
          line.qty.text = formatPlain(picked.qty);
        }
        if (line.rate.text.trim().isEmpty) {
          line.rate.text = formatPlain(picked.rate);
        }
      });
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    }
  }

  double get _total => _lines.fold(0.0, (sum, l) => sum + l.amount);

  Json _body() {
    final body = <String, dynamic>{
      'contractorPartyId': _contractor!.id,
      'date': apiDate(_date),
      'title': _title.text.trim(),
      'scope': trimmedOrNull(_scope.text),
      'itcEligible': _itc,
      'lines': [
        for (final l in _lines)
          {
            'boqLineId': ?l.boqLineId,
            'description': l.description.text.trim(),
            'unit': l.unit.text.trim(),
            'qty': parseNumber(l.qty.text),
            'rate': parseNumber(l.rate.text),
          },
      ],
    };
    // A blank percentage is left to the server (TDS: by the contractor's PAN).
    for (final (key, c) in [
      ('retentionPct', _retention),
      ('advanceRecoveryPct', _advance),
      ('tdsPct', _tds),
      ('gstPct', _gst),
      ('cessPct', _cess),
    ]) {
      final v = parseNumber(c.text);
      if (v != null) body[key] = v;
    }
    if (!_editing) {
      body['projectId'] = _projectId;
      if (_activate) body['activate'] = true;
    }
    return body;
  }

  Future<void> _save() async {
    final valid = _formKey.currentState!.validate();
    if (_contractor == null) {
      setState(() => _contractorError = 'Choose a contractor');
      return;
    }
    if (!valid) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(subcontractRepositoryProvider);
      final wo = _editing
          ? await repo.updateWorkOrder(widget.original!.id, _body())
          : await repo.createWorkOrder(_body());
      ref.bumpC(const [CKind.workOrders]);
      ref.invalidate(workOrderProvider(wo.id));
      if (!mounted) return;
      showSuccess(context, '${wo.number} saved');
      markSaved();
      context.go('/work-orders/${wo.id}');
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pctField(TextEditingController c, String label, {String? helper}) =>
      TextFormField(
        controller: c,
        keyboardType: decimalKeyboard,
        inputFormatters: [decimalInput()],
        decoration: InputDecoration(
          labelText: label,
          suffixText: '%',
          helperText: helper,
          helperMaxLines: 3,
        ),
        validator: (v) => optionalNumber(v, min: 0, max: 100),
      );

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final projects = ref.watch(projectsLookupProvider).value ?? const [];
    final wo = widget.original;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(title: _editing ? 'Edit ${wo!.number}' : 'New work order'),
        Expanded(
          child: BottomBarLayout(
            bar: Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  style: bigOutlinedButton,
                  onPressed: _busy
                      ? null
                      : () => context.go(
                          _editing ? '/work-orders/${wo!.id}' : '/work-orders',
                        ),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: bigButton,
                  onPressed: _busy ? null : _save,
                  child: Text(_editing ? 'Save changes' : 'Save work order'),
                ),
              ],
            ),
            child: Form(
              key: _formKey,
              onChanged: markDirty,
              child: CPage(
                maxWidth: 900,
                children: [
                  SectionCard(
                    title: 'Work order',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FormRow(
                          children: [
                            DropdownButtonFormField<String>(
                              key: ValueKey(
                                'wo-project-$_projectId-${projects.length}',
                              ),
                              initialValue:
                                  projects.any((p) => p.id == _projectId)
                                  ? _projectId
                                  : null,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Project',
                                prefixIcon: Icon(Icons.apartment_outlined),
                              ),
                              items: [
                                for (final p in projects)
                                  DropdownMenuItem(
                                    value: p.id,
                                    child: Text(
                                      p.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: _editing
                                  ? null
                                  : (v) => setState(() => _projectId = v),
                              validator: (v) => v == null && !_editing
                                  ? 'Choose a project'
                                  : null,
                            ),
                            InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: _pickContractor,
                              child: InputDecorator(
                                isEmpty: _contractor == null,
                                decoration: InputDecoration(
                                  labelText: 'Contractor',
                                  errorText: _contractorError,
                                  prefixIcon: const Icon(
                                    Icons.handyman_outlined,
                                  ),
                                  suffixIcon: const Icon(Icons.search),
                                ),
                                child: _contractor == null
                                    ? null
                                    : Text(
                                        _contractor!.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        FormRow(
                          children: [
                            TextFormField(
                              controller: _title,
                              maxLength: 200,
                              decoration: const InputDecoration(
                                labelText: 'Title',
                              ),
                              validator: (v) => requiredField(v, 'Title'),
                            ),
                            DateField(
                              label: 'Date',
                              value: _date,
                              onChanged: (v) => setState(() => _date = v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _scope,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Scope of work (optional)',
                          ),
                        ),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Terms',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FormRow(
                          breakpoint: 640,
                          children: [
                            _pctField(_retention, 'Retention'),
                            _pctField(_advance, 'Advance recovery'),
                            _pctField(
                              _tds,
                              'TDS',
                              helper: _editing
                                  ? null
                                  : 'Blank: 1% for individuals / HUF, '
                                        'otherwise 2%',
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        FormRow(
                          breakpoint: 640,
                          children: [
                            GstRatePicker(
                              label: 'GST',
                              kind: 'services',
                              date: apiDate(_date),
                              value: parseNumber(_gst.text),
                              onChanged: (v) => setState(
                                () => _gst.text = v == null ? '' : '$v',
                              ),
                            ),
                            _pctField(_cess, 'BOCW cess'),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('GST is eligible for ITC'),
                              value: _itc,
                              onChanged: (v) => setState(() => _itc = v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Blank percentages use the server defaults. Set TDS '
                          'to 0 where it does not apply.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Work items (${_lines.length})',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, line) in _lines.indexed) ...[
                          _LineEditor(
                            key: ObjectKey(line),
                            index: i,
                            line: line,
                            canRemove: _lines.length > 1,
                            onChanged: () => setState(() {}),
                            onPickBoq: () => _pickBoq(line),
                            onClearBoq: () => setState(() {
                              line.boqLineId = null;
                              line.boqCode = null;
                            }),
                            onRemove: () => setState(() {
                              _lines.removeAt(i).dispose();
                            }),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              style: bigOutlinedButton,
                              onPressed: _lines.length >= 500
                                  ? null
                                  : () => setState(
                                      () => _lines.add(_LineDraft()),
                                    ),
                              icon: const Icon(Icons.add),
                              label: const Text('Add work item'),
                            ),
                            Text(
                              'Total ${formatMoney(_total)}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (!_editing)
                    SwitchListTile(
                      title: const Text('Activate now'),
                      subtitle: const Text(
                        'Only active work orders can take RA bills and advances.',
                      ),
                      value: _activate,
                      onChanged: (v) => setState(() => _activate = v),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LineEditor extends StatelessWidget {
  const _LineEditor({
    super.key,
    required this.index,
    required this.line,
    required this.canRemove,
    required this.onChanged,
    required this.onPickBoq,
    required this.onClearBoq,
    required this.onRemove,
  });

  final int index;
  final _LineDraft line;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onPickBoq;
  final VoidCallback onClearBoq;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Item ${index + 1}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.link, size: 18),
                  label: Text(
                    line.boqCode == null
                        ? 'Link BOQ line'
                        : 'BOQ ${line.boqCode}',
                  ),
                  onPressed: onPickBoq,
                ),
                if (line.boqLineId != null)
                  IconButton(
                    tooltip: 'Unlink BOQ line',
                    onPressed: onClearBoq,
                    icon: const Icon(Icons.link_off),
                  ),
                IconButton(
                  tooltip: 'Remove item',
                  onPressed: canRemove ? onRemove : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            TextFormField(
              controller: line.description,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Description'),
              validator: (v) => requiredField(v, 'Description'),
            ),
            const SizedBox(height: 4),
            FormRow(
              breakpoint: 520,
              children: [
                TextFormField(
                  controller: line.unit,
                  decoration: const InputDecoration(labelText: 'Unit'),
                  validator: (v) => requiredField(v, 'Unit'),
                ),
                TextFormField(
                  controller: line.qty,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput(decimals: 3)],
                  decoration: const InputDecoration(labelText: 'Quantity'),
                  onChanged: (_) => onChanged(),
                  validator: (v) =>
                      requiredNumber(v, label: 'Quantity', min: 0.001),
                ),
                TextFormField(
                  controller: line.rate,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput()],
                  decoration: const InputDecoration(
                    labelText: 'Rate',
                    prefixText: '₹ ',
                  ),
                  onChanged: (_) => onChanged(),
                  validator: (v) => requiredNumber(v, label: 'Rate', min: 0),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Amount ${formatMoney(line.amount)}',
                textAlign: TextAlign.end,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
